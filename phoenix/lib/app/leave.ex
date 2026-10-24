defmodule App.Leave do
  @moduledoc """
  Leave (docs/design/leave.md): types and yearly entitlement
  (`priv/leave_types.json`, placeholder numbers), days, balances and
  overlaps. Recorded leave is the person record `leave` (written by a
  signed leave order); leave on its way is a request in review or a leave
  order not yet signed.

  Read as the system (no actor): used for the rule facts and for the
  balance shown next to a request.
  """

  require Ash.Query

  alias App.Documents.Document
  alias App.People.{PersonRecord, PersonRecordSchema}

  @path Path.expand("../../priv/leave_types.json", __DIR__)
  @external_resource @path
  @types @path |> File.read!() |> Jason.decode!() |> Map.fetch!("types")

  @ids Enum.map(@types, & &1["id"])
  if @ids != PersonRecordSchema.schema(:leave)["properties"]["leaveType"]["enum"] do
    raise "priv/leave_types.json: types must match the leaveType enum of the leave record"
  end

  @pending_types [:leave_request, :personnel_order_leave]

  @spec types() :: [String.t()]
  def types, do: @ids

  @doc "Days per year for a leave type; nil when it isn't counted against a balance."
  @spec entitlement(String.t()) :: pos_integer() | nil
  def entitlement(type), do: Enum.find_value(@types, &(&1["id"] == type && &1["days_per_year"]))

  @doc "Calendar days from `first` to `last`, both included; nil for an invalid period."
  @spec days(Date.t() | String.t() | nil, Date.t() | String.t() | nil) :: pos_integer() | nil
  def days(first, last) do
    with %Date{} = first <- date(first),
         %Date{} = last <- date(last),
         diff when diff >= 0 <- Date.diff(last, first) do
      diff + 1
    else
      _ -> nil
    end
  end

  @doc """
  Every leave of a person, recorded or on its way, as
  `%{source, id, type, first, last, days}`; `except` leaves one out (the
  request or record being checked).
  """
  @spec periods(String.t(), String.t() | nil) :: [map()]
  def periods(person_id, except \\ nil) do
    recorded =
      PersonRecord
      |> Ash.Query.filter(person_id == ^person_id and kind == :leave)
      |> Ash.Query.load(:data)
      |> Ash.read!(authorize?: false)
      |> Enum.reject(&(&1.id == except))
      |> Enum.map(&period(:recorded, &1.id, &1.data))

    pending =
      Document
      |> Ash.Query.filter(
        person_id == ^person_id and type in ^@pending_types and
          ((type == :leave_request and state == :in_review) or
             (type == :personnel_order_leave and state in [:draft, :in_review]))
      )
      |> Ash.Query.load(:data)
      |> Ash.read!(authorize?: false)
      |> Enum.reject(&(&1.id == except))
      |> Enum.map(&period(:pending, &1.id, &1.data))

    Enum.reject(recorded ++ pending, &is_nil(&1.days))
  end

  @doc """
  Days left of `type` in `year` after recorded and pending leave starting
  that year; nil when the type has no yearly entitlement.
  """
  @spec balance([map()], String.t(), integer()) :: integer() | nil
  def balance(periods, type, year) do
    case entitlement(type) do
      nil ->
        nil

      days ->
        used =
          periods
          |> Enum.filter(&(&1.type == type and &1.first.year == year))
          |> Enum.map(& &1.days)
          |> Enum.sum()

        days - used
    end
  end

  @doc "How many of `periods` overlap `first`..`last`."
  @spec overlaps([map()], Date.t(), Date.t()) :: non_neg_integer()
  def overlaps(periods, first, last) do
    Enum.count(
      periods,
      &(Date.compare(&1.first, last) != :gt and Date.compare(&1.last, first) != :lt)
    )
  end

  @doc """
  The facts a rule gets about a leave request (`App.Rules.Facts`):
  requested days, the balance left for its type and year before it (nil:
  no yearly limit), and how many other leaves overlap it.
  """
  @spec facts(String.t() | nil, String.t() | nil, map()) :: map()
  def facts(person_id, document_id, data) do
    first = date(data["startDate"])
    last = date(data["endDate"])
    requested = days(first, last)

    if person_id && requested do
      periods = periods(person_id, document_id)

      %{
        "type" => data["leaveType"],
        "requestedDays" => requested,
        "balance" => balance(periods, data["leaveType"], first.year),
        "overlaps" => overlaps(periods, first, last)
      }
    else
      %{
        "type" => data["leaveType"],
        "requestedDays" => requested,
        "balance" => nil,
        "overlaps" => 0
      }
    end
  end

  defp period(source, id, data) do
    first = date(data["startDate"])
    last = date(data["endDate"])

    %{
      source: source,
      id: id,
      type: data["leaveType"],
      first: first,
      last: last,
      days: days(first, last)
    }
  end

  defp date(%Date{} = date), do: date

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp date(_value), do: nil
end
