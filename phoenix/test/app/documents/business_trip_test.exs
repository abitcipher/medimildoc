defmodule App.Documents.BusinessTripTest do
  @moduledoc "docs/design/business-trips.md: a business trip order records the trip when signed."
  use App.DataCase, async: false

  import App.Fixtures

  require Ash.Query

  alias App.Documents.{Acknowledgement, Document}
  alias App.Leave.{Calendar, CalendarData}
  alias App.People.PersonRecord

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

  defp order(ctx, first, last) do
    Document
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: :personnel_order_business_trip,
        person_id: ctx.soldier.person_id,
        data: %{
          "destination" => "Lviv, training centre",
          "purpose" => "Instructor course",
          "startDate" => Date.to_iso8601(first),
          "endDate" => Date.to_iso8601(last),
          "transport" => "public_transport"
        }
      },
      actor: ctx.hr
    )
    |> Ash.create!(actor: ctx.hr)
  end

  defp run(document, action, actor, args \\ %{}) do
    document
    |> Ash.Changeset.for_update(action, args, actor: actor)
    |> Ash.update(actor: actor)
  end

  test "signing records the trip; it is away on the calendar but not leave", ctx do
    first = Date.add(Date.utc_today(), 3)
    order = order(ctx, first, Date.add(first, 4))

    {:ok, order} = run(order, :submit, ctx.hr, %{assignees: [[ctx.hr.id], [ctx.commander.id]]})

    # On its way: away (dashed) on the calendar already.
    %{absences: [pending]} = CalendarData.load(ctx.company.id, first, first, :system)
    assert pending.type == "trip" and pending.pending?

    {:ok, order} = run(order, :approve, ctx.hr)
    {:ok, order} = run(order, :sign, ctx.commander)
    assert order.number =~ "-ос"

    [record] =
      PersonRecord
      |> Ash.Query.filter(person_id == ^ctx.soldier.person_id and kind == :business_trip)
      |> Ash.Query.load(:data)
      |> Ash.read!(authorize?: false)

    assert %{
             "destination" => "Lviv, training centre",
             "days" => 5,
             "transport" => "public_transport",
             "basis" => number
           } = record.data

    assert number == order.number

    # Recorded: away, not pending; no leave taken.
    %{members: members, absences: [away]} =
      CalendarData.load(ctx.company.id, first, Date.add(first, 4), :system)

    assert away.type == "trip" and not away.pending?
    assert [%{away: 1}] = Calendar.days(members, [away], [first], 30)
    assert App.Leave.periods(ctx.soldier.person_id) == []

    # The person acknowledges it like any order.
    assert {:ok, _} =
             Acknowledgement
             |> Ash.Changeset.for_create(:acknowledge, %{document_id: order.id},
               actor: ctx.soldier
             )
             |> Ash.create(actor: ctx.soldier)
  end

  test "a trip ending before it starts is refused when sent", ctx do
    first = Date.add(Date.utc_today(), 3)
    order = order(ctx, first, Date.add(first, -1))

    assert {:error, error} =
             run(order, :submit, ctx.hr, %{assignees: [[ctx.hr.id], [ctx.commander.id]]})

    assert Exception.message(error) =~ "last day of the trip is before the first day"
  end

  test "the person reports on their signed trip; the settlement is frozen when HR signs", ctx do
    first = Date.add(Date.utc_today(), -10)
    order = order(ctx, first, Date.add(first, 2))
    {:ok, order} = run(order, :submit, ctx.hr, %{assignees: [[ctx.hr.id], [ctx.commander.id]]})
    {:ok, order} = run(order, :approve, ctx.hr)
    {:ok, order} = run(order, :sign, ctx.commander)

    {:ok, report} =
      Document
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: :business_trip_report,
          person_id: ctx.soldier.person_id,
          basis_id: order.id,
          data: %{
            "destination" => "Lviv",
            "destinationType" => "domestic",
            "startDate" => Date.to_iso8601(first),
            "endDate" => Date.to_iso8601(Date.add(first, 2)),
            "results" => "Course completed",
            "travelCost" => 800,
            "advance" => 1000
          }
        },
        actor: ctx.soldier
      )
      |> Ash.create(actor: ctx.soldier)

    {:ok, report} =
      run(report, :submit, ctx.soldier, %{assignees: [[ctx.commander.id], [ctx.hr.id]]})

    {:ok, report} = run(report, :approve, ctx.commander)
    {:ok, report} = run(report, :sign, ctx.hr)
    assert report.number =~ "-ав"

    data = Ash.get!(Document, report.id, authorize?: false, load: [:data]).data
    # 3 days × 300 + 800 travel − 1000 advance.
    assert %{"days" => 3, "perDiem" => "900.00", "total" => "1700.00", "balance" => "700.00"} =
             data["facts"]
  end
end
