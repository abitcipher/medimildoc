defmodule App.Clinical.LabTests do
  @moduledoc """
  The app's list of common laboratory tests (`priv/clinical/lab_tests.json`,
  docs/design/lab-results.md): LOINC code, names, unit, an adult reference
  range (a placeholder: each laboratory reports its own). Checked at
  compile time against the `lab_result` kind's choices.
  """

  @path Path.join(:code.priv_dir(:app), "clinical/lab_tests.json")
  @external_resource @path
  @schema_path Path.join(:code.priv_dir(:app), "person_record_schemas/lab_result.schema.json")
  @external_resource @schema_path

  %{"tests" => tests} = @path |> File.read!() |> Jason.decode!()

  schema_ids =
    @schema_path |> File.read!() |> Jason.decode!() |> get_in(["properties", "test", "enum"])

  if Enum.map(tests, & &1["id"]) != schema_ids,
    do: raise("lab_tests.json and lab_result.schema.json list different tests")

  @tests tests
  @by_id Map.new(tests, &{&1["id"], &1})

  @spec all() :: [map()]
  def all, do: @tests

  @spec get(String.t() | nil) :: map() | nil
  def get(nil), do: nil
  def get(id), do: Map.get(@by_id, id)

  @doc "`low` or `high` outside the reference range, `normal` inside, nil without a value."
  @spec interpret(map(), number() | nil) :: String.t() | nil
  def interpret(_test, nil), do: nil
  def interpret(%{"low" => low}, value) when value < low, do: "low"
  def interpret(%{"high" => high}, value) when value > high, do: "high"
  def interpret(_test, _value), do: "normal"

  @doc "The reference range as written on the record: \"3.5–5.1\"."
  @spec range(map()) :: String.t()
  def range(test), do: "#{number(test["low"])}–#{number(test["high"])}"

  @doc "A number as people write it: 5, 5.1 (no trailing .0)."
  @spec number(number()) :: String.t()
  def number(value) when is_integer(value), do: Integer.to_string(value)

  def number(value) when is_float(value) do
    # Round off float noise (4.1 + 0.3 is 4.3999999999999995).
    rounded = Float.round(value, 6)

    if rounded == Float.round(rounded),
      do: rounded |> trunc() |> Integer.to_string(),
      else: Float.to_string(rounded)
  end
end
