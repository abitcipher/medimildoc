defmodule AppWeb.DateFormat do
  @moduledoc """
  How dates are shown and typed in the UI (docs/design/reference-data-and-files.md
  `dd.mm.yyyy`. Values are still stored and exchanged as ISO
  `yyyy-mm-dd`; only the UI uses this format.

  The format lives here alone so a later per-user setting (dd.mm.yyyy,
  yyyy-mm-dd, mm/dd/yyyy) is a change to `pattern/0` and its callers, not
  to every template. The date input's JavaScript hook reads the same
  pattern from a data attribute.
  """

  @pattern "dd.mm.yyyy"
  @datetime_pattern "dd.mm.yyyy HH:MM"

  @doc "The display/input pattern, e.g. \"dd.mm.yyyy\"."
  @spec pattern() :: String.t()
  def pattern, do: @pattern

  @doc """
  The pattern for a date and time (24 h), e.g. \"dd.mm.yyyy HH:MM\". Such
  values are local wall-clock times, stored as ISO `yyyy-mm-ddTHH:MM`
  (docs/design/clinical-module.md).
  """
  @spec datetime_pattern() :: String.t()
  def datetime_pattern, do: @datetime_pattern

  @doc "A date and time for display: `27.09.2026 14:05`; a bare date as `display/1`."
  @spec display_datetime(DateTime.t() | NaiveDateTime.t() | String.t() | nil) :: String.t()
  def display_datetime(nil), do: ""
  def display_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%d.%m.%Y %H:%M")

  # A moment stored in UTC (a signature, a decision): shown as UTC, said so.
  def display_datetime(%DateTime{} = dt),
    do: Calendar.strftime(DateTime.shift_zone!(dt, "Etc/UTC"), "%d.%m.%Y %H:%M UTC")

  def display_datetime(value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(
           if String.length(value) == 16, do: value <> ":00", else: value
         ) do
      {:ok, dt} -> display_datetime(dt)
      _ -> display(value)
    end
  end

  def display_datetime(value), do: display(value)

  @doc """
  Formats a `Date`, `DateTime`, `NaiveDateTime` or ISO date string for
  display. Anything else (nil, invalid) is returned as a string unchanged.
  """
  @spec display(Date.t() | DateTime.t() | NaiveDateTime.t() | String.t() | nil) :: String.t()
  def display(nil), do: ""
  def display(%Date{} = date), do: Calendar.strftime(date, "%d.%m.%Y")
  def display(%DateTime{} = datetime), do: display(DateTime.to_date(datetime))
  def display(%NaiveDateTime{} = datetime), do: display(NaiveDateTime.to_date(datetime))

  def display(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> display(date)
      _ -> value
    end
  end

  def display(value), do: to_string(value)

  @doc "Parses input in the display pattern into a `Date`."
  @spec parse(String.t()) :: {:ok, Date.t()} | :error
  def parse(value) when is_binary(value) do
    with [_, day, month, year] <- Regex.run(~r/^\s*(\d{1,2})\.(\d{1,2})\.(\d{4})\s*$/, value),
         {:ok, date} <-
           Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day)) do
      {:ok, date}
    else
      _ -> :error
    end
  end
end
