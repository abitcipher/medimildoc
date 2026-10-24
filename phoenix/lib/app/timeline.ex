defmodule App.Timeline do
  @moduledoc """
  One chronological list of what happened to a person
  (docs/design/search-timeline-notifications.md §Timeline): assignments
  (start and end, with the order when the viewer may read it), signed
  documents, acknowledgements of orders (docs/design/acknowledgements.md;
  of orders the viewer may read), and person records by the date they are about
  (`effective_on`, `App.People.RecordDates`). Every source is read as the
  viewer, so what they may not read doesn't appear; records are not
  decrypted (no content, no access-log entry). Records inside another
  record (vital signs within an encounter) appear through their parent.
  """

  require Ash.Query

  alias App.Documents.{Document, Queries}
  alias App.People.{Assignment, PersonRecord}

  @type entry :: %{
          date: Date.t(),
          kind: :assignment_start | :assignment_end | :document | :acknowledgement | :record,
          subject: struct(),
          document: struct() | nil
        }

  @doc "The person's timeline for `actor`, newest first."
  @spec for_person(String.t(), map()) :: [entry()]
  def for_person(person_id, actor) do
    (assignments(person_id, actor) ++ documents(person_id, actor) ++ records(person_id, actor))
    |> Enum.sort_by(&{&1.date, rank(&1.kind)}, fn {d1, r1}, {d2, r2} ->
      case Date.compare(d1, d2) do
        :gt -> true
        :lt -> false
        :eq -> r1 <= r2
      end
    end)
  end

  defp rank(:assignment_end), do: 0
  defp rank(:acknowledgement), do: 1
  defp rank(:document), do: 2
  defp rank(:assignment_start), do: 3
  defp rank(:record), do: 4

  defp assignments(person_id, actor) do
    Assignment
    |> Ash.Query.filter(person_id == ^person_id)
    |> Ash.Query.load(position: [:organization], basis_document: [], end_document: [])
    |> Ash.read!(actor: actor)
    |> Enum.flat_map(fn assignment ->
      start = %{
        date: assignment.starts_on,
        kind: :assignment_start,
        subject: assignment,
        document: loaded(assignment.basis_document)
      }

      case assignment.ends_on do
        nil ->
          [start]

        ends_on ->
          [
            start,
            %{
              date: ends_on,
              kind: :assignment_end,
              subject: assignment,
              document: loaded(assignment.end_document)
            }
          ]
      end
    end)
  end

  defp documents(person_id, actor) do
    documents =
      Document
      |> Ash.Query.filter(person_id == ^person_id and state == :signed)
      |> Ash.read!(actor: actor)

    signed =
      Enum.map(
        documents,
        &%{date: DateTime.to_date(&1.signed_at), kind: :document, subject: &1, document: &1}
      )

    # Of the orders just read through the viewer's policies only.
    by_id = Map.new(documents, &{&1.id, &1})

    acknowledged =
      documents
      |> Enum.map(& &1.id)
      |> Queries.acknowledgements()
      |> Enum.map(fn {document_id, acknowledgement} ->
        %{
          date: acknowledgement.acknowledged_on,
          kind: :acknowledgement,
          subject: acknowledgement,
          document: by_id[document_id]
        }
      end)

    signed ++ acknowledged
  end

  defp records(person_id, actor) do
    PersonRecord
    |> Ash.Query.filter(person_id == ^person_id and is_nil(part_of_id))
    |> Ash.read!(actor: actor)
    |> Enum.map(
      &%{
        date: &1.effective_on || DateTime.to_date(&1.recorded_at),
        kind: :record,
        subject: &1,
        document: nil
      }
    )
  end

  # A relationship the viewer may not read comes back nil or not loaded.
  defp loaded(%Document{} = document), do: document
  defp loaded(_other), do: nil
end
