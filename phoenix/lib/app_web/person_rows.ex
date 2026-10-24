defmodule AppWeb.PersonRows do
  @moduledoc """
  Rows for people lists (`AppWeb.PeopleListComponent`): who, their current
  position and, where the list has one, a status. Everything is read
  through the normal policies with the viewer as actor, so a row only
  holds what the viewer may see (unit scope and clearance included).

  A row: `%{id, name, person_id, photo_url, position, status}` — `position` is
  `%{title, organization, grade}` or nil; `status` is
  `%{value, label, badge, details}` or nil.
  """
  use Gettext, backend: AppWeb.Gettext

  require Ash.Query

  alias App.People.{Assignment, Files, Person, PersonId, PersonRecord, PersonRecordSchema}
  alias AppWeb.{DateFormat, SchemaText}

  @doc "People whose current position reports to `person`'s current position."
  @spec direct_reports(Person.t(), map() | nil) :: [map()]
  def direct_reports(person, actor) do
    case App.People.current_assignment(person, actor: actor) do
      %{position_id: position_id} ->
        Assignment
        |> Ash.Query.filter(is_nil(ends_on) and position.reports_to_id == ^position_id)
        |> Ash.Query.load([:person, position: :organization])
        |> Ash.read!(actor: actor)
        |> Enum.map(&row(&1.person, &1.position))
        |> with_photos(actor)

      nil ->
        []
    end
  end

  @doc """
  Everyone with a fitness-for-duty assessment the viewer may see, with the
  latest status. Record data is encrypted, so the latest record per person
  is picked here, not in SQL.
  """
  @spec readiness(map()) :: [map()]
  def readiness(actor) do
    PersonRecord
    |> Ash.Query.filter(kind == :fitness_for_duty)
    |> Ash.Query.sort(recorded_at: :desc)
    |> Ash.Query.load(person: [assignments: [position: :organization]])
    |> Ash.read!(actor: actor)
    |> Enum.uniq_by(& &1.person_id)
    |> Enum.map(fn record ->
      record.person
      |> row(current_position(record.person))
      |> Map.put(:status, fitness_status(record.data || %{}))
    end)
    |> with_photos(actor)
  end

  @doc "The portrait photo link of `person` the viewer may see, or nil."
  @spec photo_url(Person.t(), map() | nil) :: String.t() | nil
  def photo_url(person, actor), do: Files.photo_urls(actor, [person.id])[person.id]

  # Portrait photos (where there is one the viewer may see), one query.
  defp with_photos(rows, actor) do
    photos = Files.photo_urls(actor, Enum.map(rows, & &1.id))
    Enum.map(rows, &Map.put(&1, :photo_url, photos[&1.id]))
  end

  defp current_position(%{assignments: assignments}) when is_list(assignments) do
    Enum.find_value(assignments, fn a -> is_nil(a.ends_on) && a.position end)
  end

  defp current_position(_person), do: nil

  defp row(person, position) do
    %{
      id: person.id,
      name: Person.full_name(person),
      person_id: person.person_id && PersonId.format(person.person_id),
      position: position && position_summary(position),
      status: nil
    }
  end

  @doc "A position as the badge shows it: `%{title, organization, grade}`."
  @spec position_summary(map()) :: map()
  def position_summary(position) do
    %{
      title: position.title,
      organization: organization_name(position.organization),
      grade: position.authorised_grade
    }
  end

  defp organization_name(%{name: name}), do: name
  defp organization_name(_), do: nil

  defp fitness_status(data) do
    value = data["status"]

    %{
      value: value,
      label: if(value, do: SchemaText.choice(value), else: "—"),
      badge: value && PersonRecordSchema.badge(:fitness_for_duty, "status", value),
      details: [
        data["reviewDate"] &&
          gettext("review %{date}", date: DateFormat.display(data["reviewDate"])),
        data["restrictions"]
      ]
    }
  end
end
