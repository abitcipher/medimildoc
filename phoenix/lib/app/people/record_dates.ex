defmodule App.People.RecordDates do
  @moduledoc """
  The date a person record is about (docs/design/search-timeline-notifications.md
  §Timeline), kept in plain `effective_on` so a timeline can order records
  without decrypting them (and without an access-log entry per record).
  Only the date is plain; the content stays encrypted, and the record's
  kind is plain already.

  Taken from the first date-like field of the record's data that is set;
  a date entered explicitly (`effective_on` in the action) wins.
  `backfill/0` fills records saved before this existed.
  """

  require Ash.Query

  alias App.People.PersonRecord

  @fields ~w(effectiveDate startDate start measuredAt collectedAt performed occurrence onsetDate
             recordedDate effectiveStart issuedOn assessmentDate dateOfBirth)

  @doc "The date a record's data is about, or nil."
  @spec from_data(map() | nil) :: Date.t() | nil
  def from_data(data) when is_map(data), do: Enum.find_value(@fields, &date(data[&1]))
  def from_data(_data), do: nil

  defp date(value) when is_binary(value) and byte_size(value) >= 10 do
    case Date.from_iso8601(binary_part(value, 0, 10)) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp date(_value), do: nil

  @doc "Fills `effective_on` of records that have a date in their data; returns how many."
  @spec backfill() :: non_neg_integer()
  def backfill do
    PersonRecord
    |> Ash.Query.filter(is_nil(effective_on))
    |> Ash.Query.load(:data)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(0, fn record, count ->
      case from_data(record.data) do
        nil ->
          count

        date ->
          App.Repo.query!("UPDATE person_records SET effective_on = $1 WHERE id = $2", [
            date,
            Ecto.UUID.dump!(record.id)
          ])

          count + 1
      end
    end)
  end
end
