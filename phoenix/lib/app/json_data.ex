defmodule App.JsonData do
  @moduledoc """
  Form data against a JSON Schema, for anything whose fields a schema
  declares (person record kinds, document types): `normalize/2` turns
  submitted form values into the schema's JSON types, `validate/2` checks
  them.

  `normalize/2`:

  - a blank string drops the field: a form submits an untouched optional
    field as `""` (a blank number input, a select left on "— select —"),
    which JSON Schema would reject for a number or a choice and store as an
    empty string for text. "Not provided" is fine for an optional field and
    a clear "required property missing" for a required one;
  - `"integer"`/`"number"` fields: `"3"` → `3`, `"2.5"` → `2.5` (sliders
    and number inputs submit strings);
  - `"boolean"` fields: `"true"`/`"false"` → `true`/`false` (checkboxes);
  - lists (checkbox groups): empty markers removed, each item cast by the
    schema's `items`; an empty list drops the field;
  - nested objects (`code.text`) are handled the same way.

  A value that doesn't parse is left as it is, so validation reports it.
  """

  @spec normalize(map(), map()) :: map()
  def normalize(schema, data) when is_map(schema) and is_map(data), do: cast_object(data, schema)

  @doc "Validates `data`; errors as human-readable `path: message` strings."
  @spec validate(map(), map()) :: :ok | {:error, [String.t()]}
  def validate(schema, data) when is_map(schema) and is_map(data) do
    case ExJsonSchema.Validator.validate(schema, data) do
      :ok ->
        :ok

      {:error, errors} ->
        {:error, Enum.map(errors, fn {message, path} -> "#{path}: #{message}" end)}
    end
  end

  defp cast_object(data, schema) do
    properties = schema["properties"] || %{}

    data
    |> Enum.map(fn {key, value} -> {key, cast(value, properties[key] || %{})} end)
    |> Enum.reject(fn {_key, value} -> value in ["", []] end)
    |> Map.new()
  end

  defp cast(value, %{"type" => "object"} = schema) when is_map(value),
    do: cast_object(value, schema)

  # Checkbox groups submit a list with an empty marker (so that clearing
  # every box still sends the field); a list left empty counts as not
  # provided.
  defp cast(values, %{"type" => "array"} = schema) when is_list(values) do
    items = schema["items"] || %{}
    for value <- values, value != "", do: cast(value, items)
  end

  defp cast(value, %{"type" => "integer"}) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp cast(value, %{"type" => "number"}) when is_binary(value) do
    trimmed = String.trim(value)

    case {Integer.parse(trimmed), Float.parse(trimmed)} do
      {{int, ""}, _} -> int
      {_, {float, ""}} -> float
      _ -> value
    end
  end

  defp cast("true", %{"type" => "boolean"}), do: true
  defp cast("false", %{"type" => "boolean"}), do: false
  defp cast(value, _schema), do: value
end
