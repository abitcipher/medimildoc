defmodule App.LeaveTest do
  @moduledoc "docs/design/leave.md: leave requests, orders, balances and rules."
  use App.DataCase, async: false

  import App.Fixtures

  require Ash.Query

  alias App.Documents.Document
  alias App.People.PersonRecord
  alias App.Rules.{Facts, Library}

  setup do
    App.Access.put_admin_full_data_access_override(false)
    brigade = org_fixture("1st Brigade")
    company = org_fixture("A Company", brigade)
    requester = unit_user_fixture(:viewer, [], company, nil)

    %{
      requester: requester,
      person_id: requester.person_id,
      bystander: unit_user_fixture(:viewer, [], company, nil),
      hr: user_fixture(:hr),
      hr_head: user_fixture(:hr),
      commander: unit_user_fixture(:viewer, [:commander], brigade)
    }
  end

  defp request(ctx, actor, data) do
    Document
    |> Ash.Changeset.for_create(
      :create,
      %{type: :leave_request, person_id: ctx.person_id, data: data},
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  defp run(document, action, actor, args \\ %{}) do
    document
    |> Ash.Changeset.for_update(action, args, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp annual(first, last),
    do: %{
      "leaveType" => "annual",
      "startDate" => first,
      "endDate" => last,
      "destination" => "Lviv"
    }

  defp leave_records(person_id) do
    PersonRecord
    |> Ash.Query.filter(person_id == ^person_id and kind == :leave)
    |> Ash.Query.load(:data)
    |> Ash.read!(authorize?: false)
  end

  test "the person files a request; the commander approves, HR accepts, the order records the leave",
       ctx do
    assert {:ok, request} = request(ctx, ctx.requester, annual("2026-11-02", "2026-11-15"))

    # Their own request only: not someone else's, and nobody else in the unit reads it.
    assert {:error, %Ash.Error.Forbidden{}} =
             Document
             |> Ash.Changeset.for_create(
               :create,
               %{
                 type: :leave_request,
                 person_id: ctx.bystander.person_id,
                 data: annual("2026-11-02", "2026-11-03")
               },
               actor: ctx.requester
             )
             |> Ash.create(actor: ctx.requester)

    assert [_] = Ash.read!(Document, actor: ctx.requester)
    assert [] = Ash.read!(Document, actor: ctx.bystander)

    {:ok, request} =
      run(request, :submit, ctx.requester, %{assignees: [[ctx.commander.id], [ctx.hr.id]]})

    {:ok, request} = run(request, :approve, ctx.commander)
    assert {:ok, request} = run(request, :sign, ctx.hr)
    assert request.number == "1-рап"

    [order] =
      Document
      |> Ash.Query.filter(type == :personnel_order_leave)
      |> Ash.Query.load(:data)
      |> Ash.read!(authorize?: false)

    assert order.state == :draft and order.basis_id == request.id
    assert order.data["startDate"] == "2026-11-02"

    # Pending: the order on its way counts against the balance.
    assert App.Leave.balance(App.Leave.periods(ctx.person_id), "annual", 2026) == 16

    {:ok, order} =
      run(order, :submit, ctx.hr, %{assignees: [[ctx.hr_head.id], [ctx.commander.id]]})

    {:ok, order} = run(order, :approve, ctx.hr_head)
    assert {:ok, order} = run(order, :sign, ctx.commander)

    assert [%{data: %{"days" => 14, "leaveType" => "annual", "basis" => number}}] =
             leave_records(ctx.person_id)

    assert number == order.number
    assert App.Leave.balance(App.Leave.periods(ctx.person_id), "annual", 2026) == 16

    # The order's rule facts carry when its basis (the request) was signed.
    facts =
      Facts.context(
        "document.sign",
        "document:personnel_order_leave",
        ctx.person_id,
        %{},
        order.signed_at,
        %{id: order.id, basis_id: request.id}
      )

    assert facts["basis"]["signedAt"] == DateTime.to_iso8601(request.signed_at)
  end

  test "HR files for the person; a reversed period is refused when sent", ctx do
    {:ok, request} = request(ctx, ctx.hr, annual("2026-11-10", "2026-11-02"))

    assert {:error, error} =
             run(request, :submit, ctx.hr, %{assignees: [[ctx.commander.id], [ctx.hr.id]]})

    assert Exception.message(error) =~ "last day of leave is before the first day"
  end

  test "rules flag a request over the balance or overlapping another leave", ctx do
    Library.sync()
    :ok = App.Settings.put("fsdc.enabled", true, user_fixture(:admin))

    record_fixture(%{id: ctx.person_id}, :leave, %{
      "leaveType" => "annual",
      "startDate" => "2026-03-01",
      "endDate" => "2026-03-20",
      "days" => 20
    })

    # 20 used of 30: 14 more days are over the balance and overlap nothing.
    {:ok, over} = request(ctx, ctx.requester, annual("2026-11-02", "2026-11-15"))

    assert {:ok, _} =
             run(over, :submit, ctx.requester, %{assignees: [[ctx.commander.id], [ctx.hr.id]]})

    # Overlaps the recorded leave; within the family balance.
    {:ok, overlapping} =
      request(ctx, ctx.requester, %{
        "leaveType" => "family",
        "startDate" => "2026-03-10",
        "endDate" => "2026-03-12"
      })

    assert {:ok, _} =
             run(overlapping, :submit, ctx.requester, %{
               assignees: [[ctx.commander.id], [ctx.hr.id]]
             })

    incidents =
      App.Audit.Incident
      |> Ash.read!(authorize?: false)
      |> Enum.map(&{&1.subject_id, &1.code})
      |> Enum.sort()

    assert incidents ==
             Enum.sort([{over.id, "leave_over_balance"}, {overlapping.id, "leave_overlap"}])
  end

  test "days, entitlement and overlaps" do
    assert App.Leave.days("2026-11-02", "2026-11-02") == 1
    assert App.Leave.days("2026-12-30", "2027-01-02") == 4
    assert App.Leave.days("2026-11-02", "2026-11-01") == nil
    assert App.Leave.entitlement("annual") == 30
    assert App.Leave.entitlement("sick") == nil

    periods = [%{type: "annual", first: ~D[2026-03-01], last: ~D[2026-03-10], days: 10}]
    assert App.Leave.overlaps(periods, ~D[2026-03-10], ~D[2026-03-12]) == 1
    assert App.Leave.overlaps(periods, ~D[2026-03-11], ~D[2026-03-12]) == 0
  end
end
