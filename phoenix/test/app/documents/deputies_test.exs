defmodule App.Documents.DeputiesTest do
  @moduledoc "docs/design/inbox-first.md: stand-ins, overdue reminders and the task count."
  use App.DataCase, async: false

  import App.Fixtures
  import Ecto.Query

  require Ash.Query

  alias App.Documents.{Deputies, Deputy, Document, Queries, Reminders, Step}
  alias App.Notify.{Notification, Subscription}

  setup do
    App.Access.put_admin_full_data_access_override(false)
    company = org_fixture("A Company", org_fixture("1st Brigade"))

    %{
      company: company,
      soldier: unit_user_fixture(:viewer, [], company, nil),
      hr: unit_user_fixture(:hr, [], company, nil),
      hr2: user_fixture(:hr),
      commander: unit_user_fixture(:viewer, [:commander], company),
      outsider: user_fixture(:viewer)
    }
  end

  # A grade order waiting for `ctx.hr` to approve (then the commander signs).
  defp order(ctx) do
    Document
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: :personnel_order_grade,
        person_id: ctx.soldier.person_id,
        data: %{"grade" => "OR-4", "effectiveDate" => Date.to_iso8601(Date.utc_today())}
      },
      actor: ctx.hr
    )
    |> Ash.create!(actor: ctx.hr)
    |> Ash.Changeset.for_update(:submit, %{assignees: [[ctx.hr.id], [ctx.commander.id]]},
      actor: ctx.hr
    )
    |> Ash.update!(actor: ctx.hr)
  end

  defp deputy(user, deputy, attrs \\ %{}) do
    Deputy
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{user_id: user.id, deputy_id: deputy.id}, attrs),
      actor: user
    )
    |> Ash.create(actor: user)
  end

  defp on_leave(user) do
    today = Date.utc_today()

    record_fixture(%{id: user.person_id}, :leave, %{
      "leaveType" => "annual",
      "startDate" => Date.to_iso8601(Date.add(today, -2)),
      "endDate" => Date.to_iso8601(Date.add(today, 5)),
      "days" => 8
    })
  end

  defp approve(document, actor) do
    document
    |> Ash.Changeset.for_update(:approve, %{}, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp backdate(document, days) do
    {1, _} =
      App.Repo.update_all(
        from(s in "document_steps",
          where: s.document_id == type(^document.id, :binary_id) and s.status == "pending"
        ),
        set: [pending_since: DateTime.add(DateTime.utc_now(), -days, :day)]
      )
  end

  test "active: between the dates, or without dates whenever the user is away" do
    dated = %{starts_on: ~D[2026-11-01], ends_on: ~D[2026-11-05]}
    assert Deputies.active?(dated, ~D[2026-11-01], false)
    assert Deputies.active?(dated, ~D[2026-11-05], false)
    refute Deputies.active?(dated, ~D[2026-11-06], true)

    away = %{starts_on: nil, ends_on: nil}
    assert Deputies.active?(away, ~D[2026-11-06], true)
    refute Deputies.active?(away, ~D[2026-11-06], false)
  end

  test "a deputy for when away acts only while the user is on leave; the step records them",
       ctx do
    document = order(ctx)
    {:ok, _} = deputy(ctx.hr, ctx.hr2)

    # Not away: nothing for the deputy, and they may not decide.
    assert Deputies.principals(ctx.hr2.id) == []
    assert Queries.inbox(ctx.hr2).to_decide == []
    assert {:error, _} = approve(document, ctx.hr2)

    on_leave(ctx.hr)
    assert Deputies.principals(ctx.hr2.id) == [ctx.hr.id]

    assert [%{id: id, on_behalf_of: %{id: hr_id}}] = Queries.inbox(ctx.hr2).to_decide
    assert id == document.id and hr_id == ctx.hr.id

    assert {:ok, _} = approve(document, ctx.hr2)

    [approved, next] =
      Step
      |> Ash.Query.filter(document_id == ^document.id)
      |> Ash.Query.sort(position: :asc)
      |> Ash.read!(authorize?: false)

    assert approved.status == :approved and approved.assignee_id == ctx.hr.id
    assert approved.decided_by_id == ctx.hr2.id
    assert next.status == :pending and next.pending_since
  end

  test "a deputy acts only where they hold the step's permission", ctx do
    document = order(ctx)
    today = Date.utc_today()

    # Nobody without a route permission may be named.
    assert {:error, error} = deputy(ctx.hr, ctx.outsider, %{starts_on: today, ends_on: today})
    assert Exception.message(error) =~ "holds none of the permissions"

    # A commander of another unit holds orders.sign, but not for this person.
    other = unit_user_fixture(:viewer, [:commander], org_fixture("B Company"))
    {:ok, _} = deputy(ctx.commander, other, %{starts_on: today, ends_on: today})
    {:ok, document} = approve(document, ctx.hr)

    assert Deputies.principals(other.id) == [ctx.commander.id]
    assert Queries.inbox(other).to_decide == []
    assert {:error, _} = Ash.get(Document, document.id, actor: other)

    assert {:error, _} =
             document
             |> Ash.Changeset.for_update(:sign, %{}, actor: other)
             |> Ash.update(actor: other)
  end

  test "dates are checked: both or neither, in order, not oneself", ctx do
    today = Date.utc_today()
    assert {:error, _} = deputy(ctx.hr, ctx.hr)
    assert {:error, _} = deputy(ctx.hr, ctx.hr2, %{starts_on: today})

    assert {:error, _} =
             deputy(ctx.hr, ctx.hr2, %{starts_on: today, ends_on: Date.add(today, -1)})

    {:ok, _} =
      deputy(ctx.hr, ctx.hr2, %{starts_on: Date.add(today, 1), ends_on: Date.add(today, 3)})

    assert Deputies.principals(ctx.hr2.id) == []
  end

  test "an overdue step is reminded once, to the assignee and their deputy; its deadline stays",
       ctx do
    document = order(ctx)
    today = Date.utc_today()
    {:ok, _} = deputy(ctx.hr, ctx.hr2, %{starts_on: today, ends_on: today})

    for user <- [ctx.hr, ctx.hr2] do
      Subscription
      |> Ash.Changeset.for_create(
        :create,
        %{user_id: user.id, event: :document_overdue, channel: :in_app},
        actor: user
      )
      |> Ash.create!(actor: user)
    end

    assert Reminders.run() == 0
    backdate(document, 5)
    [%{due: due}] = Queries.inbox(ctx.hr).to_decide

    assert Reminders.run() == 1
    assert Reminders.run() == 0

    reminded =
      Notification
      |> Ash.Query.filter(event == :document_overdue)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.user_id)
      |> Enum.sort()

    assert reminded == Enum.sort([ctx.hr.id, ctx.hr2.id])
    assert [%{due: ^due}] = Queries.inbox(ctx.hr).to_decide

    # The count next to "Tasks": one waiting, overdue.
    assert %{count: 1, overdue: 1} = Queries.waiting_count(ctx.hr)
    assert %{count: 1, overdue: 1} = Queries.waiting_count(ctx.hr2)
  end
end
