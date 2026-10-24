defmodule App.Rules.Facts do
  @moduledoc """
  What a rule is given (docs/design/data-consistency.md): the check point
  and subject, the moment of the event, facts about the person, and the
  subject's own fields.

      %{
        "point" => "record.save",
        "subject" => "record:encounter",
        "event" => %{"at" => "2026-09-28T14:05:00Z"},
        "person" => %{"id" => "…", "identityVerifiedAt" => "2026-09-01T10:00:00Z" | nil},
        "data" => %{…}          # the record's or document's fields
      }

  Read as the system (no actor, nothing in the access log). The incident
  keeps everything but `data` (`facts_for_incident/1`): dates, ids and
  codes, never a record's medical content.

  `identityVerifiedAt` is when the person's first identity document or
  national identifier was entered.

  Facts about the subject itself, when there are any (`refs`: its `:id`,
  so it isn't compared with itself, and a document's `:basis_id`):

  - a leave request or a recorded leave: `"leave"` (`App.Leave.facts/3`)
    — requested days, the balance left before it, overlapping leaves;
  - a document with a basis: `"basis"` — `"signedAt"` of the basis;
  - an assignment: `"assignment"` — `"overlaps"`, how many other
    assignments of the person overlap its period.
  """

  require Ash.Query

  alias App.Leave.CalendarData
  alias App.People.{IdentityDocument, PersonIdentifier}

  # The date a record describes (the examination, the measurement…), when
  # it has one; otherwise the moment of saving.
  @event_fields ~w(start measuredAt performed occurrence recordedDate onsetDate effectiveDate)

  @spec context(String.t(), String.t(), String.t() | nil, map(), DateTime.t() | nil, map()) ::
          map()
  def context(point, subject, person_id, data, at \\ nil, refs \\ %{}) do
    %{
      "point" => point,
      "subject" => subject,
      "event" => %{"at" => iso(at || event_at(data))},
      "person" => person(person_id),
      "data" => data || %{}
    }
    |> with_subject_facts(subject, person_id, data || %{}, refs)
  end

  # A leave request also gets how many of the unit are away then
  # (docs/design/leave-calendar.md; rule leave_within_unit_limit).
  defp with_subject_facts(context, "document:leave_request", person_id, data, refs) do
    load = CalendarData.unit_load(person_id, data)

    facts =
      person_id
      |> App.Leave.facts(refs[:id], data)
      |> Map.put("unitOver", load != nil and load.over?)
      |> Map.put("othersAway", load && load.others_away)
      |> Map.put("unitLimit", load && load.limit)

    Map.put(context, "leave", facts)
  end

  # A fitness status and the board conclusion it cites
  # (rule fitness_from_signed_conclusion).
  defp with_subject_facts(context, "record:fitness_for_duty", person_id, data, _refs) do
    Map.put(context, "fitness", %{
      "status" => data["status"],
      "basisSigned" => signed_conclusion?(person_id, data["basis"])
    })
  end

  defp with_subject_facts(context, "record:leave", person_id, data, refs),
    do: Map.put(context, "leave", App.Leave.facts(person_id, refs[:id], data))

  defp with_subject_facts(context, "assignment", person_id, data, refs),
    do:
      Map.put(context, "assignment", %{"overlaps" => assignment_overlaps(person_id, data, refs)})

  defp with_subject_facts(context, "document:" <> _, _person_id, _data, %{basis_id: basis_id})
       when is_binary(basis_id) do
    signed_at =
      case Ash.get(App.Documents.Document, basis_id, authorize?: false) do
        {:ok, basis} -> iso(basis.signed_at)
        _ -> nil
      end

    Map.put(context, "basis", %{"signedAt" => signed_at})
  end

  defp with_subject_facts(context, _subject, _person_id, _data, _refs), do: context

  defp signed_conclusion?(person_id, number) when is_binary(person_id) and is_binary(number) do
    App.Documents.Document
    |> Ash.Query.filter(
      person_id == ^person_id and type == :medical_board_conclusion and state == :signed and
        number == ^number
    )
    |> Ash.exists?(authorize?: false)
  end

  defp signed_conclusion?(_person_id, _number), do: false

  # Other assignments of the person whose period overlaps this one (an
  # open end runs on).
  defp assignment_overlaps(person_id, data, refs) do
    case date(data["startsOn"]) do
      %Date{} = starts ->
        ends = date(data["endsOn"])

        App.People.Assignment
        |> Ash.Query.filter(person_id == ^person_id)
        |> Ash.read!(authorize?: false)
        |> Enum.count(&(&1.id != refs[:id] and overlaps?(&1, starts, ends)))

      nil ->
        0
    end
  end

  defp overlaps?(other, starts, ends) do
    (is_nil(other.ends_on) or Date.compare(other.ends_on, starts) != :lt) and
      (is_nil(ends) or Date.compare(other.starts_on, ends) != :gt)
  end

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp date(_value), do: nil

  @spec facts_for_incident(map()) :: map()
  def facts_for_incident(context), do: Map.delete(context, "data")

  defp event_at(data) do
    Enum.find_value(@event_fields, &parse((data || %{})[&1])) || DateTime.utc_now()
  end

  defp person(nil), do: %{"id" => nil, "identityVerifiedAt" => nil}

  defp person(person_id) do
    %{"id" => person_id, "identityVerifiedAt" => person_id |> identity_verified_at() |> iso()}
  end

  defp identity_verified_at(person_id) do
    [IdentityDocument, PersonIdentifier]
    |> Enum.flat_map(fn resource ->
      resource
      |> Ash.Query.filter(person_id == ^person_id)
      |> Ash.Query.select([:inserted_at])
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.inserted_at)
    end)
    |> Enum.min(DateTime, fn -> nil end)
  end

  # "2026-09-28", "2026-09-28T14:05" (local form) or a full ISO timestamp.
  defp parse(value) when is_binary(value) do
    cond do
      match?({:ok, _, _}, DateTime.from_iso8601(value)) ->
        {:ok, dt, _} = DateTime.from_iso8601(value)
        dt

      match?({:ok, _}, NaiveDateTime.from_iso8601(pad(value))) ->
        {:ok, naive} = NaiveDateTime.from_iso8601(pad(value))
        DateTime.from_naive!(naive, "Etc/UTC")

      match?({:ok, _}, Date.from_iso8601(value)) ->
        {:ok, date} = Date.from_iso8601(value)
        DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

      true ->
        nil
    end
  end

  defp parse(_value), do: nil

  defp pad(value), do: if(String.length(value) == 16, do: value <> ":00", else: value)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(DateTime.shift_zone!(dt, "Etc/UTC"))
end
