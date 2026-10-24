defmodule App.Search do
  @moduledoc """
  Global search (docs/design/search-timeline-notifications.md). Every group
  is read as the actor, so policies decide what appears: a result never
  shows what the viewer may not read.

  - people: every word of the query matches a name part or the e-mail,
    or the query is a Person ID;
  - documents by number (`15-ос`, `1-вип`);
  - units, posts, care providers by name;
  - a national ID or identity-document number, exact match through its
    keyed hash (`App.Search.Digest`), for actors who can read them; each
    match goes to the access log.
  """

  require Ash.Query

  alias App.Audit.AccessLogger
  alias App.Care.Provider
  alias App.Documents.Document
  alias App.People.{IdentityDocument, Organization, Person, PersonId, PersonIdentifier, Position}
  alias App.Search.Digest

  @limit 8

  @type results :: %{
          people: list(),
          identified: list(),
          documents: list(),
          organizations: list(),
          positions: list(),
          providers: list()
        }

  @doc "Searches everything for `text` as `actor`; empty groups when the text is under 2 characters."
  @spec run(map(), String.t()) :: results()
  def run(actor, text) do
    text = String.trim(text || "")

    if String.length(text) < 2 do
      %{
        people: [],
        identified: [],
        documents: [],
        organizations: [],
        positions: [],
        providers: []
      }
    else
      %{
        people: people(actor, text),
        identified: identified(actor, text),
        documents: documents(actor, text),
        organizations: named(Organization, :name, actor, text),
        positions: positions(actor, text),
        providers: named(Provider, :name, actor, text)
      }
    end
  end

  @doc "Whether any group found something."
  @spec any?(results()) :: boolean()
  def any?(results), do: Enum.any?(Map.values(results), &(&1 != []))

  @doc """
  People whose names or e-mail contain every word of `text`, or whose
  PersonID it is — as `actor`, sorted by name (also the sidebar's Find,
  SHEETS-UI.18).
  """
  @spec people(map(), String.t()) :: [Person.t()]
  def people(actor, text) do
    code = PersonId.unformat(text)

    query =
      if PersonId.valid?(code) do
        Ash.Query.filter(Person, person_id == ^code)
      else
        text
        |> String.split(~r/\s+/u, trim: true)
        |> Enum.reduce(Person, fn word, query ->
          pattern = "%" <> like_escape(word) <> "%"

          Ash.Query.filter(
            query,
            ilike(given_name, ^pattern) or ilike(family_name, ^pattern) or
              ilike(patronymic, ^pattern) or ilike(email, ^pattern)
          )
        end)
      end

    query
    |> Ash.Query.sort(family_name: :asc, given_name: :asc)
    |> Ash.Query.limit(@limit)
    |> Ash.read!(actor: actor)
  end

  # A national ID or document number: exact, only when it looks like one.
  defp identified(actor, text) do
    digest = Digest.digest(text)

    if digest && identifier_like?(text) do
      actor |> identifier_matches(digest) |> people_logged(actor)
    else
      []
    end
  end

  defp identifier_like?(text),
    do: String.match?(text, ~r/\d/) and String.length(Digest.normalize(text)) >= 5

  defp identifier_matches(actor, digest) do
    Enum.flat_map(
      [{PersonIdentifier, :value_digest}, {IdentityDocument, :number_digest}],
      fn {resource, field} -> readable_matches(resource, field, digest, actor) end
    )
  end

  # Not allowed to read identifiers: no identifier search.
  defp readable_matches(resource, field, digest, actor) do
    resource
    |> Ash.Query.filter(^Ash.Expr.ref(field) == ^digest)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, rows} -> Enum.map(rows, &{resource, &1})
      {:error, %Ash.Error.Forbidden{}} -> []
    end
  end

  defp people_logged([], _actor), do: []

  # Fail closed: nothing is shown unless the access log was written.
  defp people_logged(matches, actor) do
    ids = matches |> Enum.map(fn {_, row} -> row.person_id end) |> Enum.uniq()

    case AccessLogger.log_identifier_search(actor, matches) do
      :ok -> Person |> Ash.Query.filter(id in ^ids) |> Ash.read!(actor: actor)
      _ -> []
    end
  end

  defp documents(actor, text) do
    pattern = like_escape(String.downcase(text)) <> "%"

    Document
    |> Ash.Query.filter(not is_nil(number) and ilike(number, ^pattern))
    |> Ash.Query.load(:person)
    |> Ash.Query.sort(registered_on: :desc)
    |> Ash.Query.limit(@limit)
    |> Ash.read!(actor: actor)
  end

  defp positions(actor, text) do
    pattern = "%" <> like_escape(text) <> "%"

    Position
    |> Ash.Query.filter(ilike(title, ^pattern))
    |> Ash.Query.load(:organization)
    |> Ash.Query.sort(title: :asc)
    |> Ash.Query.limit(@limit)
    |> Ash.read!(actor: actor)
  end

  defp named(resource, field, actor, text) do
    pattern = "%" <> like_escape(text) <> "%"

    resource
    |> Ash.Query.filter(ilike(^Ash.Expr.ref(field), ^pattern))
    |> Ash.Query.sort([{field, :asc}])
    |> Ash.Query.limit(@limit)
    |> Ash.read!(actor: actor)
  end

  defp like_escape(text), do: String.replace(text, ~r/([\\%_])/, "\\\\\\1")
end
