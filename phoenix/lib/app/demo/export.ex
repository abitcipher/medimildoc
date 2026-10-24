defmodule App.Demo.Export do
  @moduledoc """
  Writes the synthetic data (`App.Demo`) to JSON files, one per table,
  so a seeded reference set can be kept outside the database and compared
  later (docs/design/data-consistency.md §Reference dataset). Only rows
  of the synthetic set: synthetic organizations and people, their posts,
  assignments, identifiers, identity documents, records and documents,
  and the demo users. Encrypted values are written decrypted (they are
  synthetic); read as the system, so nothing goes to the access log.

  Also writes `reference.json` (the planted-violation labels) and
  `manifest.json` (counts and when it was written).
  """

  require Ash.Query

  alias App.Accounts.User
  alias App.Documents.Document

  alias App.People.{
    Assignment,
    IdentityDocument,
    Organization,
    Person,
    PersonIdentifier,
    PersonRecord,
    Position
  }

  alias Ash.Resource.Info

  @spec write(Path.t()) :: {:ok, map()}
  def write(dir) do
    File.mkdir_p!(dir)
    orgs = rows(Organization |> Ash.Query.filter(synthetic == true))
    org_ids = Enum.map(orgs, & &1["id"])
    people = rows(Person |> Ash.Query.filter(synthetic == true))
    person_ids = Enum.map(people, & &1["id"])
    of_people = &(&1 |> Ash.Query.filter(person_id in ^person_ids))

    tables = %{
      "organizations" => orgs,
      "positions" => rows(Position |> Ash.Query.filter(organization_id in ^org_ids)),
      "people" => people,
      "assignments" => rows(of_people.(Assignment)),
      "person_identifiers" => rows(of_people.(PersonIdentifier), [:value]),
      "identity_documents" => rows(of_people.(IdentityDocument), [:number]),
      "person_records" => rows(of_people.(PersonRecord), [:data]),
      "documents" => rows(of_people.(Document), [:data]),
      "care_providers" => rows(App.Care.Provider |> Ash.Query.filter(synthetic == true)),
      "users" =>
        rows(
          User
          |> Ash.Query.filter(contains(type(email, :string), ^"@#{App.Demo.email_domain()}"))
        )
    }

    for {name, list} <- tables do
      File.write!(Path.join(dir, "#{name}.json"), Jason.encode_to_iodata!(list, pretty: true))
    end

    File.cp!(
      Application.app_dir(:app, "priv/reference/rules.json"),
      Path.join(dir, "reference.json")
    )

    counts = Map.new(tables, fn {name, list} -> {name, length(list)} end)

    manifest = %{
      "written_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "counts" => counts
    }

    File.write!(Path.join(dir, "manifest.json"), Jason.encode_to_iodata!(manifest, pretty: true))
    {:ok, counts}
  end

  # Every attribute but the ciphertexts, plus the decrypted fields (entry
  # times included: the planted violations depend on them), sorted by id.
  defp rows(query, decrypted \\ []) do
    fields =
      query.resource
      |> Info.attributes()
      |> Enum.map(& &1.name)
      |> Enum.reject(&String.starts_with?(to_string(&1), "encrypted_"))

    query
    |> Ash.Query.load(decrypted)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn row ->
      Map.new(fields ++ decrypted, fn field -> {to_string(field), plain(Map.get(row, field))} end)
    end)
    |> Enum.sort_by(& &1["id"])
  end

  defp plain(%Ash.CiString{} = value), do: to_string(value)
  defp plain(value), do: value
end
