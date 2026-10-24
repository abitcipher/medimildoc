defmodule App.Documents.Certificates.TripSettlement do
  @moduledoc """
  The settlement of a business-trip report (docs/design/business-trips.md
  §Report), pure: days from the actual dates, the per-diem allowance at the
  rate for the destination (`priv/trip_allowances.json`, placeholders), the
  costs claimed, the advance, and what is left to pay out or to return.
  Amounts are strings with two decimals (`Decimal`), never floats.
  """

  @path Path.join(:code.priv_dir(:app), "trip_allowances.json")
  @external_resource @path

  %{"currency" => currency, "per_diem" => rates} = @path |> File.read!() |> Jason.decode!()
  @currency currency
  @rates rates

  @costs ~w(travelCost accommodationCost otherCost)

  @doc "The facts frozen when the report is signed (and shown as a preview before)."
  @spec compute(map()) :: map()
  def compute(data) do
    days = days(data["startDate"], data["endDate"])
    rate = Decimal.new(Map.get(@rates, data["destinationType"], @rates["domestic"]))
    per_diem = Decimal.mult(rate, days || 0)
    costs = Map.new(@costs, &{&1, money(data[&1])})
    total = Enum.reduce(Map.values(costs), per_diem, &Decimal.add/2)
    advance = money(data["advance"])
    balance = Decimal.sub(total, advance)

    %{
      "currency" => @currency,
      "days" => days,
      "rate" => string(rate),
      "perDiem" => string(per_diem),
      "costs" => Map.new(costs, fn {key, value} -> {key, string(value)} end),
      "total" => string(total),
      "advance" => string(advance),
      "balance" => string(balance)
    }
  end

  @doc "Valid actual dates, the last not before the first; `:ok` or the reason (English)."
  @spec check(map()) :: :ok | {:error, String.t()}
  def check(data) do
    if days(data["startDate"], data["endDate"]),
      do: :ok,
      else: {:error, "Give the trip's actual first and last day, the last not before the first."}
  end

  defp days(first, last) do
    with {:ok, first} <- Date.from_iso8601(first || ""),
         {:ok, last} <- Date.from_iso8601(last || ""),
         diff when diff >= 0 <- Date.diff(last, first) do
      diff + 1
    else
      _ -> nil
    end
  end

  defp money(value) when is_number(value),
    do: value |> to_string() |> Decimal.new() |> Decimal.round(2)

  defp money(value) when is_binary(value) do
    case Decimal.parse(String.replace(value, ",", ".")) do
      {decimal, ""} -> Decimal.round(decimal, 2)
      _ -> Decimal.new("0.00")
    end
  end

  defp money(_value), do: Decimal.new("0.00")

  defp string(decimal), do: decimal |> Decimal.round(2) |> Decimal.to_string(:normal)
end
