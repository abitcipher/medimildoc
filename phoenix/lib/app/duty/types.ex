defmodule App.Duty.Types do
  @moduledoc """
  Duty types from `priv/duty_types.json` (docs/design/duty-roster.md): id,
  label (translated by the web layer), how many people a day, and the
  rest days a person needs between two duties. Checked at compile time.
  """

  @path Path.join(:code.priv_dir(:app), "duty_types.json")
  @external_resource @path

  %{"types" => types, "min_rest_days" => rest} = @path |> File.read!() |> Jason.decode!()

  for type <- types,
      not (is_binary(type["id"]) and is_binary(type["label"]) and is_integer(type["per_day"]) and
             type["per_day"] > 0),
      do: raise("duty_types.json: each type needs id, label and per_day > 0")

  @types types
  @rest rest
  @ids Enum.map(types, & &1["id"])

  @spec all() :: [map()]
  def all, do: @types

  @spec ids() :: [String.t()]
  def ids, do: @ids

  @spec get(String.t()) :: map() | nil
  def get(id), do: Enum.find(@types, &(&1["id"] == id))

  @doc "Days of rest a person needs between two duties (1: never two days running)."
  @spec min_rest_days() :: non_neg_integer()
  def min_rest_days, do: @rest
end
