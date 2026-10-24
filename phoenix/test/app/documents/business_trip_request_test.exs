defmodule App.Documents.BusinessTripRequestTest do
  @moduledoc "docs/design/business-trips.md: the person asks for a business trip."
  use App.DataCase, async: false

  import App.Fixtures

  require Ash.Query

  alias App.Documents.{Document, Types}
  alias App.Leave.CalendarData

  setup do
    App.Access.put_admin_full_data_access_override(false)
    company = org_fixture("A Company", org_fixture("1st Brigade"))

    %{
      company: company,
      soldier: unit_user_fixture(:viewer, [], company, nil),
      hr: user_fixture(:hr),
      commander: unit_user_fixture(:viewer, [:commander], company)
    }
  end

  defp run(document, action, actor, args \\ %{}) do
    document
    |> Ash.Changeset.for_update(action, args, actor: actor)
    |> Ash.update(actor: actor)
  end

  test "request → commander approves → HR accepts → a draft trip order based on it", ctx do
    assert :business_trip_request in Types.self_service_types()
    first = Date.add(Date.utc_today(), 10)

    data = %{
      "destination" => "Lviv, training centre",
      "purpose" => "Instructor course",
      "startDate" => Date.to_iso8601(first),
      "endDate" => Date.to_iso8601(Date.add(first, 4)),
      "transport" => "public_transport"
    }

    {:ok, request} =
      Document
      |> Ash.Changeset.for_create(
        :create,
        %{type: :business_trip_request, person_id: ctx.soldier.person_id, data: data},
        actor: ctx.soldier
      )
      |> Ash.create(actor: ctx.soldier)

    {:ok, request} =
      run(request, :submit, ctx.soldier, %{assignees: [[ctx.commander.id], [ctx.hr.id]]})

    # On its way: away (dashed) on the leave calendar.
    assert %{absences: [%{type: "trip", pending?: true}]} =
             CalendarData.load(ctx.company.id, first, first, :system)

    {:ok, request} = run(request, :approve, ctx.commander)
    {:ok, request} = run(request, :sign, ctx.hr)
    assert request.number =~ "-рап"

    [order] =
      Document
      |> Ash.Query.filter(type == :personnel_order_business_trip)
      |> Ash.Query.load(:data)
      |> Ash.read!(authorize?: false)

    assert order.state == :draft and order.basis_id == request.id
    assert order.data == data

    # The draft order is pending now, not the request: counted once.
    assert %{absences: [%{type: "trip", pending?: true}]} =
             CalendarData.load(ctx.company.id, first, first, :system)
  end
end
