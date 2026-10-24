defmodule App.AshJsonSchema do
  @moduledoc """
  Derives the JSON Schema an Ash resource's action actually accepts/requires
  — the "automated mechanism for synchronizing data types to a single
  source of truth in declarative JSON" the project's requirements call
  for. This does *not* render forms or validate input; `AppWeb.JsonSchemaForm`
  renders from the hand-authored, UI-labeled files in `priv/form_schemas/`
  (and `priv/person_record_schemas/` for `PersonRecord`'s polymorphic
  `data`, which has no Ash attributes to derive from — that one stays
  entirely hand-authored and *is* the validation source of truth, see
  `App.People.PersonRecordSchema`). This module exists only so those
  hand-authored files for the plain resources can be mechanically checked
  against Ash rather than drifting silently — see
  `test/app/ash_json_schema_test.exs` and
  `test/app_web/form_schemas_sync_test.exs`.
  """

  @type schema :: %{properties: %{String.t() => map()}, required: [String.t()]}

  @doc "The JSON Schema shape for `resource`'s `action_name` action's accepted attributes."
  @spec derive(Ash.Resource.t(), atom()) :: schema()
  def derive(resource, action_name) do
    action = Ash.Resource.Info.action(resource, action_name)

    fields =
      for name <- action.accept,
          attr = Ash.Resource.Info.attribute(resource, name),
          attr do
        {to_string(name), property_schema(attr), not attr.allow_nil?}
      end

    %{
      properties: Map.new(fields, fn {name, prop_schema, _required?} -> {name, prop_schema} end),
      required: for({name, _prop_schema, true} <- fields, do: name)
    }
  end

  defp property_schema(%{type: Ash.Type.String, constraints: constraints}) do
    schema = %{"type" => "string"}

    schema =
      case Keyword.get(constraints, :max_length) do
        nil -> schema
        max -> Map.put(schema, "maxLength", max)
      end

    case Keyword.get(constraints, :allow_empty?, true) do
      false -> Map.put(schema, "minLength", 1)
      true -> schema
    end
  end

  defp property_schema(%{type: Ash.Type.Atom, constraints: constraints}) do
    case Keyword.get(constraints, :one_of) do
      nil -> %{"type" => "string"}
      values -> %{"type" => "string", "enum" => Enum.map(values, &to_string/1)}
    end
  end

  defp property_schema(%{type: Ash.Type.Integer, constraints: constraints}) do
    %{"type" => "integer"}
    |> maybe_put("minimum", constraints[:min])
    |> maybe_put("maximum", constraints[:max])
  end

  defp property_schema(%{type: Ash.Type.Date}), do: %{"type" => "string", "format" => "date"}

  defp property_schema(%{type: Ash.Type.Boolean}), do: %{"type" => "boolean"}

  defp property_schema(%{type: type}) when type in [Ash.Type.UUID, Ash.Type.UUIDv7],
    do: %{"type" => "string"}

  # A list (its items are described by the hand-authored schema).
  defp property_schema(%{type: {:array, _item}}), do: %{"type" => "array"}

  defp property_schema(_attr), do: %{}

  defp maybe_put(schema, _key, nil), do: schema
  defp maybe_put(schema, key, value), do: Map.put(schema, key, value)
end
