defmodule App.Events.Catalog do
  @moduledoc """
  The declared events (docs/design/events-and-person-login.md), from
  `priv/events.json`, checked when compiling: every type is
  `hrda.<domain>.<subject>.<action>` (four lower-case segments), has a
  severity, says whether it is published and lists the fields its data
  may carry. Emitting an undeclared type, or data with an undeclared
  field, raises.
  """

  @path Path.join(:code.priv_dir(:app), "events.json")
  @external_resource @path

  @severities ~w(info notice warning critical)
  @name ~r/^hrda(\.[a-z][a-z0-9_]*){3}$/

  @events (fn ->
             events = @path |> File.read!() |> Jason.decode!()

             for {type, spec} <- events do
               unless Regex.match?(@name, type),
                 do: raise("priv/events.json: #{type} is not hrda.<domain>.<subject>.<action>")

               unless spec["severity"] in @severities,
                 do: raise("priv/events.json: #{type} has no valid severity")

               unless is_boolean(spec["publish"]) and is_list(spec["data"]) and
                        is_binary(spec["description"]),
                      do: raise("priv/events.json: #{type} needs publish, data and description")
             end

             Map.new(events, fn {type, spec} ->
               {type,
                %{
                  severity: spec["severity"],
                  publish?: spec["publish"],
                  data: spec["data"],
                  description: spec["description"]
                }}
             end)
           end).()

  @type spec :: %{
          severity: String.t(),
          publish?: boolean(),
          data: [String.t()],
          description: String.t()
        }

  @doc "Every declared event type, sorted."
  @spec types() :: [String.t()]
  def types, do: @events |> Map.keys() |> Enum.sort()

  @doc "The severities, from routine to critical."
  @spec severities() :: [String.t()]
  def severities, do: @severities

  @doc "The declaration of `type`; raises for an undeclared one."
  @spec fetch!(String.t()) :: spec()
  def fetch!(type) do
    case Map.fetch(@events, type) do
      {:ok, spec} -> spec
      :error -> raise ArgumentError, "undeclared event #{inspect(type)} (priv/events.json)"
    end
  end

  @doc "The domain segment of a type (`hrda.auth.session.started` → `auth`)."
  @spec domain(String.t()) :: String.t()
  def domain(type), do: type |> String.split(".") |> Enum.at(1)
end
