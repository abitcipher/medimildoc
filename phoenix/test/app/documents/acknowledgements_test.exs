defmodule App.Documents.AcknowledgementsTest do
  @moduledoc "docs/design/acknowledgements.md: orders acknowledged by the person or recorded for them."
  use App.DataCase, async: false

  import App.Fixtures

  require Ash.Query

  alias App.Documents.{Acknowledgement, Document, Queries, Types}

  setup do
    App.Access.put_admin_full_data_access_override(false)
    brigade = org_fixture("1st Brigade")
    company = org_fixture("A Company", brigade)
    other_company = org_fixture("B Company", brigade)
    soldier = unit_user_fixture(:viewer, [], company, nil)

    %{
      brigade: brigade,
      company: company,
      soldier: soldier,
      other: unit_user_fixture(:viewer, [], other_company, nil),
      hr: user_fixture(:hr),
      commander: unit_user_fixture(:viewer, [:commander], company),
      other_commander: unit_user_fixture(:viewer, [:commander], other_company)
    }
  end

  # A signed grade order about `person_id` (no effect on assignments).
  defp signed_order(ctx, person_id, commander \\ nil) do
    ctx = if commander, do: %{ctx | commander: commander}, else: ctx

    {:ok, order} =
      Document
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: :personnel_order_grade,
          person_id: person_id,
          data: %{"grade" => "OR-4", "effectiveDate" => Date.to_iso8601(Date.utc_today())}
        },
        actor: ctx.hr
      )
      |> Ash.create(actor: ctx.hr)

    {:ok, order} = run(order, :submit, ctx.hr, %{assignees: route(order, ctx)})
    sign_through(order, ctx)
  end

  defp route(order, ctx) do
    for entry <- Types.route(order.type) do
      [if(entry["permission"] == "orders.sign", do: ctx.commander.id, else: ctx.hr.id)]
    end
  end

  defp sign_through(order, ctx) do
    case Queries.current_step(order) do
      nil ->
        order

      step ->
        actor = if step.assignee_id == ctx.hr.id, do: ctx.hr, else: ctx.commander
        action = if step.action == :sign, do: :sign, else: :approve
        {:ok, order} = run(order, action, actor)
        sign_through(order, ctx)
    end
  end

  defp run(document, action, actor, args \\ %{}) do
    document
    |> Ash.Changeset.for_update(action, args, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp acknowledge(document, actor) do
    Acknowledgement
    |> Ash.Changeset.for_create(:acknowledge, %{document_id: document.id}, actor: actor)
    |> Ash.create(actor: actor)
  end

  defp record(document, actor, args \\ %{}) do
    Acknowledgement
    |> Ash.Changeset.for_create(
      :record,
      Map.merge(%{document_id: document.id, method: :paper}, args),
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  test "the person reads their signed order and acknowledges it once, in the app", ctx do
    order = signed_order(ctx, ctx.soldier.person_id)
    assert order.state == :signed

    # Theirs to read now, and waiting in their tasks.
    assert {:ok, _} = Ash.get(Document, order.id, actor: ctx.soldier)
    assert [%{id: id}] = Queries.to_acknowledge(ctx.soldier)
    assert id == order.id

    # Not someone else's order.
    assert {:error, _} = acknowledge(order, ctx.other)

    assert {:ok, ack} = acknowledge(order, ctx.soldier)
    assert ack.method == :self and ack.acknowledged_on == Date.utc_today()
    assert ack.person_id == ctx.soldier.person_id
    assert Queries.to_acknowledge(ctx.soldier) == []

    # Once only.
    assert {:error, _} = acknowledge(order, ctx.soldier)

    # In the order's history.
    order = Queries.load_trail(order)
    assert Enum.any?(order.events, &(&1.action == :acknowledged))
  end

  test "HR or the person's own commander records it; another unit's commander can't", ctx do
    order = signed_order(ctx, ctx.soldier.person_id)

    assert {:error, %Ash.Error.Forbidden{}} = record(order, ctx.other_commander)
    assert {:error, %Ash.Error.Forbidden{}} = record(order, ctx.other)

    # Not before the order was signed, not in the future.
    assert {:error, error} =
             record(order, ctx.hr, %{acknowledged_on: Date.add(Date.utc_today(), 1)})

    assert Exception.message(error) =~ "in the future"

    assert {:error, error} =
             record(order, ctx.hr, %{acknowledged_on: Date.add(Date.utc_today(), -30)})

    assert Exception.message(error) =~ "before the order was signed"

    # Only in person or on paper on someone's behalf.
    assert {:error, _} = record(order, ctx.hr, %{method: :self})

    assert {:ok, ack} = record(order, ctx.commander, %{method: :in_person, note: "Formation"})
    assert ack.method == :in_person and ack.recorded_by_email == to_string(ctx.commander.email)
  end

  test "a draft or a document that isn't acknowledged can't be", ctx do
    {:ok, draft} =
      Document
      |> Ash.Changeset.for_create(
        :create,
        %{type: :personnel_order_grade, person_id: ctx.soldier.person_id, data: %{}},
        actor: ctx.hr
      )
      |> Ash.create(actor: ctx.hr)

    assert {:error, error} = record(draft, ctx.hr)
    assert Exception.message(error) =~ "Only a signed order"
  end

  test "the pending list for recording: by unit, type and date; only what the actor covers",
       ctx do
    mine = signed_order(ctx, ctx.soldier.person_id)
    theirs = signed_order(ctx, ctx.other.person_id, ctx.other_commander)

    ids = fn docs -> docs |> Enum.map(& &1.id) |> Enum.sort() end

    assert ids.(Queries.pending_acknowledgements(ctx.hr)) == Enum.sort([mine.id, theirs.id])
    assert ids.(Queries.pending_acknowledgements(ctx.hr, %{unit: ctx.company.id})) == [mine.id]

    assert ids.(Queries.pending_acknowledgements(ctx.hr, %{unit: ctx.brigade.id})) |> length() ==
             2

    assert Queries.pending_acknowledgements(ctx.hr, %{type: :personnel_order_leave}) == []

    assert Queries.pending_acknowledgements(ctx.hr, %{signed_from: Date.add(Date.utc_today(), 1)}) ==
             []

    # A commander sees only their unit's.
    assert ids.(Queries.pending_acknowledgements(ctx.commander)) == [mine.id]

    {:ok, _} = record(mine, ctx.hr)
    assert ids.(Queries.pending_acknowledgements(ctx.hr)) == [theirs.id]
  end

  test "signing notifies the person; the timeline shows the acknowledgement", ctx do
    {:ok, _} =
      App.Notify.Subscription
      |> Ash.Changeset.for_create(
        :create,
        %{user_id: ctx.soldier.id, event: :document_to_acknowledge, channel: :in_app},
        actor: ctx.soldier
      )
      |> Ash.create(actor: ctx.soldier)

    order = signed_order(ctx, ctx.soldier.person_id)

    assert [_] =
             App.Notify.Notification
             |> Ash.Query.filter(user_id == ^ctx.soldier.id)
             |> Ash.read!(authorize?: false)

    {:ok, _} = acknowledge(order, ctx.soldier)

    assert Enum.any?(
             App.Timeline.for_person(ctx.soldier.person_id, ctx.hr),
             &(&1.kind == :acknowledgement and &1.document.id == order.id)
           )
  end
end
