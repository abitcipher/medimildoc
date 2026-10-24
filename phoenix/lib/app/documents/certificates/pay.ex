defmodule App.Documents.Certificates.Pay do
  @moduledoc """
  Pay for each month of a period from `compensation` records
  (docs/design/certificates.md): the monthly rate in force each day
  (base pay, promotion and cost-of-living records set the rate from their
  date), prorated by days of the month, plus one-off payments (any other
  reason) dated in the month. Per currency; amounts as strings with two
  decimals, so the stored facts and their hash are exact. Pure.
  """

  @rate_reasons ~w(base_pay promotion cola_adjustment)

  @doc "Whether a compensation reason sets the monthly rate (otherwise it is a one-off payment)."
  @spec rate?(String.t()) :: boolean()
  def rate?(reason), do: reason in @rate_reasons

  @doc """
  The pay facts for `from`..`to` (both included) from compensation record
  data: `rates` (the rate in force at the start and every change in the
  period), `payments` (one-offs in the period), `months` (per month the
  pay at the rate, the one-offs and their total, by currency) and
  `totals`.
  """
  @spec compute([map()], Date.t(), Date.t()) :: map()
  def compute(records, from, to) do
    entries =
      records
      |> Enum.map(&entry/1)
      |> Enum.reject(&is_nil/1)

    rates = entries |> Enum.filter(&rate?(&1.reason)) |> Enum.sort_by(& &1.date, Date)

    payments =
      entries
      |> Enum.reject(&rate?(&1.reason))
      |> Enum.filter(&in_period?(&1.date, from, to))
      |> Enum.sort_by(& &1.date, Date)

    months =
      for month <- months(from, to) do
        first = Enum.max([month, from], Date)
        last = Enum.min([Date.end_of_month(month), to], Date)
        at_rate = at_rate(rates, first, last)

        one_off =
          payments
          |> Enum.filter(&in_period?(&1.date, first, last))
          |> sum_by_currency()

        %{
          "month" => Calendar.strftime(month, "%Y-%m"),
          "atRate" => money(at_rate),
          "oneOff" => money(one_off),
          "total" => money(add(at_rate, one_off))
        }
      end

    %{
      "from" => Date.to_iso8601(from),
      "to" => Date.to_iso8601(to),
      "rates" => Enum.map(rates_in_period(rates, from, to), &out/1),
      "payments" => Enum.map(payments, &out/1),
      "months" => months,
      "totals" =>
        months
        |> Enum.map(&parse(&1["total"]))
        |> Enum.reduce(%{}, &add/2)
        |> money()
    }
  end

  @doc "The first day of every month that `from`..`to` touches."
  @spec months(Date.t(), Date.t()) :: [Date.t()]
  def months(from, to) do
    from
    |> Date.beginning_of_month()
    |> Stream.iterate(&(&1 |> Date.end_of_month() |> Date.add(1)))
    |> Enum.take_while(&(Date.compare(&1, to) != :gt))
  end

  # Each day of first..last earns rate / days in the month.
  defp at_rate(rates, first, last) do
    days_in_month = Date.days_in_month(first)

    Date.range(first, last)
    |> Enum.reduce(%{}, fn day, acc ->
      case rate_on(rates, day) do
        nil ->
          acc

        rate ->
          share = Decimal.div(rate.amount, days_in_month)
          Map.update(acc, rate.currency, share, &Decimal.add(&1, share))
      end
    end)
  end

  defp rate_on(rates, day),
    do: rates |> Enum.filter(&(Date.compare(&1.date, day) != :gt)) |> List.last()

  # The rate in force when the period starts, then every change inside it.
  defp rates_in_period(rates, from, to) do
    Enum.reject([rate_on(rates, from)], &is_nil/1) ++
      Enum.filter(rates, &(Date.compare(&1.date, from) == :gt and in_period?(&1.date, from, to)))
  end

  defp entry(%{"amount" => amount, "currency" => currency, "effectiveDate" => date} = data)
       when is_number(amount) and is_binary(currency) do
    case Date.from_iso8601(date) do
      {:ok, date} ->
        %{
          amount: decimal(amount),
          currency: currency,
          date: date,
          reason: data["reason"] || "other"
        }

      _ ->
        nil
    end
  end

  defp entry(_data), do: nil

  defp decimal(n) when is_integer(n), do: Decimal.new(n)
  defp decimal(n) when is_float(n), do: Decimal.from_float(n)

  defp in_period?(date, from, to),
    do: Date.compare(date, from) != :lt and Date.compare(date, to) != :gt

  defp sum_by_currency(entries) do
    Enum.reduce(entries, %{}, fn e, acc ->
      Map.update(acc, e.currency, e.amount, &Decimal.add(&1, e.amount))
    end)
  end

  defp add(a, b), do: Map.merge(a, b, fn _currency, x, y -> Decimal.add(x, y) end)

  defp money(by_currency) do
    Map.new(by_currency, fn {currency, amount} ->
      {currency, amount |> Decimal.round(2) |> Decimal.to_string(:normal)}
    end)
  end

  defp parse(by_currency), do: Map.new(by_currency, fn {c, a} -> {c, Decimal.new(a)} end)

  defp out(entry),
    do: %{
      "date" => Date.to_iso8601(entry.date),
      "amount" => entry.amount |> Decimal.round(2) |> Decimal.to_string(:normal),
      "currency" => entry.currency,
      "reason" => entry.reason
    }
end
