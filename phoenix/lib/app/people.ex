defmodule App.People do
  @moduledoc """
  Ash domain for personnel data: people, the org/position
  structure they're assigned into (NATO-style decomposition — company,
  battalion, brigade, ... alongside plain civilian department/team), the
  history of those assignments, and an extensible, JSON-Schema-validated
  record type (`PersonRecord`) for whatever structured data accrues around
  a person over time (medical, status changes, ...) that doesn't yet
  warrant its own first-class resource.

  Reporting chains 
  attach to `Position`, not directly to `Person` — a post's chain of command
  doesn't change when its current holder rotates out. `current_manager/2`
  below (and `AppWeb.PersonRows.direct_reports/2`) derive the answer for a
  given person by following their *current* `Assignment` rather than
  storing it redundantly.
  """
  use Ash.Domain

  require Ash.Query

  resources do
    resource(App.People.Organization)
    resource(App.People.Position)
    resource(App.People.Person)
    resource(App.People.Assignment)
    resource(App.People.PersonRecord)
    resource(App.People.PersonIdentifier)
    resource(App.People.IdentityDocument)
    resource(App.People.BiometricRecord)
    resource(App.People.Attachment)
  end

  @doc "`person`'s currently active assignment (`ends_on` nil), with `:position` loaded. `nil` if none."
  @spec current_assignment(App.People.Person.t(), keyword()) :: App.People.Assignment.t() | nil
  def current_assignment(%App.People.Person{} = person, opts \\ []) do
    App.People.Assignment
    |> Ash.Query.filter(person_id == ^person.id and is_nil(ends_on))
    |> Ash.Query.load(:position)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: Keyword.get(opts, :actor))
    |> List.first()
  end

  @doc "The currently active assignment to `position_id`, with `:person` loaded. `nil` if vacant."
  @spec current_assignment_for_position(Ash.UUID.t(), keyword()) ::
          App.People.Assignment.t() | nil
  def current_assignment_for_position(position_id, opts \\ []) do
    App.People.Assignment
    |> Ash.Query.filter(position_id == ^position_id and is_nil(ends_on))
    |> Ash.Query.load(:person)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: Keyword.get(opts, :actor))
    |> List.first()
  end

  @doc """
  The person currently occupying the position that `person`'s current
  position reports to — i.e. `person`'s direct manager. `nil` if `person`
  has no current assignment, their position has no `reports_to`, or nobody
  currently occupies that position.
  """
  @spec current_manager(App.People.Person.t(), keyword()) :: App.People.Person.t() | nil
  def current_manager(%App.People.Person{} = person, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    with %{position: %{reports_to_id: reports_to_id}} when not is_nil(reports_to_id) <-
           current_assignment(person, actor: actor),
         %{person: manager} <- current_assignment_for_position(reports_to_id, actor: actor) do
      manager
    else
      _ -> nil
    end
  end
end
