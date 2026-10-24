defmodule App.Fixtures do
  @moduledoc """
  Small builders for tests. Record data comes from
  `App.Demo.sample_record_data/1`, so tests and the synthetic data
  generator agree on what a valid record of each kind looks like.
  """

  require Ash.Query

  alias App.Accounts.User
  alias App.People.{Person, PersonRecord}

  @doc "A user with `role` and access `profiles`, created without authorization."
  def user_fixture(role, profiles \\ []) do
    Ash.Seed.seed!(User, %{
      email: "user-#{Ash.UUIDv7.generate()}@example.test",
      role: role,
      profiles: profiles
    })
  end

  @doc "A person, created through the real create action without authorization."
  def person_fixture(attrs \\ %{}) do
    Person
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{given_name: "Test", family_name: "Person"}, attrs),
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  @doc "A record of `kind` for `person`; `data` defaults to the kind's sample."
  def record_fixture(person, kind, data \\ nil) do
    PersonRecord
    |> Ash.Changeset.for_create(
      :create,
      %{person_id: person.id, kind: kind, data: data || App.Demo.sample_record_data(kind)},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  @doc "An organization, optionally under `parent`."
  def org_fixture(name \\ "Unit", parent \\ nil) do
    App.People.Organization
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, kind: :unit, parent_id: parent && parent.id},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  @doc """
  Gives `person` a current assignment to a new post in `org`. Options:
  `title` (default "Post"), `reports_to` (a position), `grade`.
  """
  def assign_fixture(person, org, opts \\ []) do
    attrs = %{
      title: Keyword.get(opts, :title, "Post"),
      organization_id: org.id,
      reports_to_id: opts[:reports_to] && opts[:reports_to].id,
      authorised_grade: opts[:grade]
    }

    position = post_fixture(attrs)

    App.People.Assignment
    |> Ash.Changeset.for_create(
      :create,
      %{
        person_id: person.id,
        position_id: position.id,
        starts_on: Date.add(Date.utc_today(), -30)
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)

    person
  end

  # Identical posts are one post with a strength (App.People.Position):
  # reuse it and make room for one more holder.
  defp post_fixture(attrs) do
    existing =
      App.People.Position
      |> Ash.Query.filter(title == ^attrs.title and organization_id == ^attrs.organization_id)
      |> Ash.read!(authorize?: false)
      |> Enum.find(
        &(&1.reports_to_id == attrs.reports_to_id and
            &1.authorised_grade == attrs.authorised_grade)
      )

    case existing do
      nil ->
        App.People.Position
        |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
        |> Ash.create!(authorize?: false)

      post ->
        post
        |> Ash.Changeset.for_update(:update, %{strength: post.strength + 1}, authorize?: false)
        |> Ash.update!(authorize?: false)
    end
  end

  @doc """
  A user linked to a new person who is currently assigned in `org`, so
  unit-scoped profiles (docs/design/access-control-phase2.md) apply to
  that unit, with a valid clearance at `clearance` (`nil` for none).
  """
  def unit_user_fixture(role, profiles, org, clearance \\ "NATO_SECRET") do
    person = person_fixture(%{given_name: "Staff"}) |> assign_fixture(org)

    if clearance do
      record_fixture(person, :security_clearance, %{
        "clearanceLevel" => clearance,
        "status" => "granted",
        "expiryDate" => Date.to_iso8601(Date.add(Date.utc_today(), 365))
      })
    end

    Ash.Seed.seed!(User, %{
      email: "user-#{Ash.UUIDv7.generate()}@example.test",
      role: role,
      profiles: profiles,
      person_id: person.id
    })
  end
end
