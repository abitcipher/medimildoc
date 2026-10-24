defmodule App.Documents.TripSettlementTest do
  @moduledoc "docs/design/business-trips.md §Report: the settlement (pure)."
  use ExUnit.Case, async: true

  alias App.Documents.Certificates.TripSettlement

  test "days × rate plus costs, less the advance" do
    facts =
      TripSettlement.compute(%{
        "startDate" => "2026-11-02",
        "endDate" => "2026-11-06",
        "destinationType" => "domestic",
        "travelCost" => 1200,
        "accommodationCost" => "2000,50",
        "advance" => 3000
      })

    assert %{
             "currency" => "UAH",
             "days" => 5,
             "rate" => "300.00",
             "perDiem" => "1500.00",
             "total" => "4700.50",
             "advance" => "3000.00",
             "balance" => "1700.50"
           } = facts

    assert facts["costs"] == %{
             "travelCost" => "1200.00",
             "accommodationCost" => "2000.50",
             "otherCost" => "0.00"
           }
  end

  test "abroad rate; more advance than spent gives a negative balance (to return)" do
    assert %{"perDiem" => "3000.00", "balance" => "-2000.00"} =
             TripSettlement.compute(%{
               "startDate" => "2026-11-02",
               "endDate" => "2026-11-03",
               "destinationType" => "abroad",
               "advance" => 5000
             })
  end

  test "the dates must make a period" do
    assert TripSettlement.check(%{"startDate" => "2026-11-02", "endDate" => "2026-11-02"}) == :ok

    assert {:error, _} =
             TripSettlement.check(%{"startDate" => "2026-11-03", "endDate" => "2026-11-02"})

    assert {:error, _} = TripSettlement.check(%{})
  end
end
