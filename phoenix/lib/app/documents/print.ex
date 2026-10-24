defmodule App.Documents.Print do
  @moduledoc """
  What a printed document shows (the JSON the Typst template reads), in the
  print language: title, number and date, the person, the fields as
  label/value rows in the UI Schema's order, a certificate's facts as
  sections (`App.Documents.Certificates.sections/4`), the route with who
  approved and signed when, and the content hash. Pure given the loaded
  document, except that a post or care provider is looked up by its id.
  """

  alias App.Documents.{Certificates, Labels, Types}
  alias App.People.{Person, PersonId, Position, PositionLabel}

  @locale "uk"

  @doc "The print payload of a signed (or preview) document with :person, :basis, :signed_by and trail loaded."
  @spec payload(map()) :: map()
  def payload(document) do
    labels = Labels.impl()
    type = document.type

    %{
      "title" => labels.text(Types.label(type), @locale),
      "number" => document.number,
      "date" => date(document.registered_on),
      "person" => person(document.person),
      "basis" => basis(document),
      "rows" => rows(type, document.data || %{}, labels),
      "sections" => sections(type, document.data || %{}, labels),
      "route" => route(document, labels),
      "signed_at" => datetime(document.signed_at),
      "content_sha256" => document.content_sha256,
      "document_id" => document.id,
      "case" => case_index(Map.get(document, :case_id)),
      # An incoming letter is registered, not signed (docs/design/correspondence.md).
      "registration" => Types.registration_only?(type),
      "letter" => letter(type, document.data || %{})
    }
  end

  @doc "A certificate's sections from the facts in its fields; [] for other documents or before signing."
  @spec sections(atom(), map(), module(), String.t()) :: [map()]
  def sections(type, data, labels, locale \\ @locale) do
    case {Types.facts(type), data["facts"]} do
      {kind, %{} = facts} when is_binary(kind) ->
        Certificates.sections(kind, facts, labels, locale)

      _ ->
        []
    end
  end

  # The file plan case's index, printed as "№".
  defp case_index(nil), do: nil

  defp case_index(case_id) do
    case Ash.get(App.Records.Case, case_id, authorize?: false) do
      {:ok, kase} -> kase.index
      _ -> nil
    end
  end

  defp person(nil), do: nil

  defp person(%{} = person) do
    %{
      "name" => Person.full_name(person),
      "person_id" => person.person_id && PersonId.format(person.person_id),
      "birth_date" => date(person.date_of_birth)
    }
  end

  defp basis(%{basis: %{number: number}}) when is_binary(number), do: number
  defp basis(_document), do: nil

  # One row per UI Schema control with a value, in its order.
  @doc """
  The fields as `%{"label", "value"}` rows in UI Schema order, in `locale`
  through `labels` (the document page shows them the same way).
  """
  @spec rows(atom(), map(), module(), String.t()) :: [map()]
  def rows(type, data, labels, locale \\ @locale) do
    schema = Types.schema(type)

    for %{"scope" => scope} = control <- controls(Types.ui_schema(type)),
        path = scope |> String.split("/") |> Enum.reject(&(&1 in ["#", "properties"])),
        value = get_in(data, path),
        value not in [nil, "", []] do
      property = Enum.reduce(path, schema, &(get_in(&2, ["properties", &1]) || %{}))

      %{
        "label" => labels.text(control["label"] || List.last(path), locale),
        "value" => value(value, property, labels, locale)
      }
    end
  end

  defp controls(%{"elements" => elements}), do: Enum.flat_map(elements, &controls/1)
  defp controls(%{"type" => "Control"} = control), do: [control]
  defp controls(_other), do: []

  defp value(values, %{"items" => items} = property, labels, locale) when is_list(values) do
    items = Map.merge(items, Map.take(property, ["x-enum-labels"]))
    Enum.map_join(values, "; ", &value(&1, items, labels, locale))
  end

  # A reference to a post (personnel orders): its short label.
  defp value(id, %{"x-entity" => "position"}, _labels, _locale) when is_binary(id) do
    case Ash.get(Position, id, authorize?: false, load: [:organization]) do
      {:ok, position} -> PositionLabel.for_position(position)
      _ -> id
    end
  end

  defp value(id, %{"x-entity" => "provider"}, _labels, _locale) when is_binary(id) do
    case Ash.get(App.Care.Provider, id, authorize?: false) do
      {:ok, provider} -> provider.name
      _ -> id
    end
  end

  # A unit (letters, docs/design/correspondence.md): its name.
  defp value(id, %{"x-entity" => "organization"}, _labels, _locale) when is_binary(id) do
    case Ash.get(App.People.Organization, id, authorize?: false) do
      {:ok, unit} -> unit.name
      _ -> id
    end
  end

  defp value(value, %{"enum" => _} = property, labels, locale) when is_binary(value),
    do: labels.choice(value, property["x-enum-labels"], locale)

  defp value(value, %{"format" => "date"}, _labels, _locale) when is_binary(value),
    do: date(value)

  defp value(true, _property, labels, locale), do: labels.text("Yes", locale)
  defp value(false, _property, labels, locale), do: labels.text("No", locale)
  defp value(value, _property, _labels, _locale), do: to_string(value)

  # An outgoing letter on letterhead (docs/design/correspondence.md):
  # the sending unit, the addressee, the subject and the text as written.
  defp letter(:outgoing_letter, data) do
    %{
      "unit" => unit_name(data["unit"]),
      "addressee" => data["addressee"],
      "address" => data["address"],
      "subject" => data["subject"],
      "text" => data["text"] || ""
    }
  end

  defp letter(_type, _data), do: nil

  defp unit_name(id) when is_binary(id) do
    case Ash.get(App.People.Organization, id, authorize?: false) do
      {:ok, unit} -> unit.name
      _ -> nil
    end
  end

  defp unit_name(_id), do: nil

  defp route(document, labels) do
    for step <- document.steps || [], step.status in [:approved, :signed] do
      %{
        "label" => labels.text(step.label, @locale),
        "name" => step.assignee && (step.assignee.name || to_string(step.assignee.email)),
        "at" => datetime(step.decided_at),
        "action" => to_string(step.status)
      }
    end
  end

  defp date(nil), do: nil
  defp date(%Date{} = d), do: Calendar.strftime(d, "%d.%m.%Y")

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, d} -> date(d)
      _ -> value
    end
  end

  defp datetime(nil), do: nil
  defp datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%d.%m.%Y %H:%M UTC")
end
