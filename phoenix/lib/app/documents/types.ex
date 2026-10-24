defmodule App.Documents.Types do
  @moduledoc """
  Document types (docs/design/documents-core.md), declared in
  `priv/document_types/<type>.json` like person record kinds: label,
  icon, category (sensitivity: reads of sensitive categories are logged),
  access (`read`: any of these permissions; `write`: this one; `self`:
  the person's own account may file and read them too), register
  (`code` and display `format`, docs/design/documents-core.md §Registers), fields (JSON Schema + UI
  Schema), route, Typst template, effects, retention, and the types a
  document may be based on. Read and checked at compile time: a type with
  a missing key, an unknown category, effect or permission fails the
  build.
  """

  @dir Path.expand("../../../priv/document_types", __DIR__)
  @effects ~w(open_conclusion fitness_for_duty schedule_reexamination
              assignment_start assignment_transfer assignment_end rank_record
              leave_order_draft leave_record open_discharge_summary sick_leave
              business_trip_record business_trip_order_draft close_instructions)
  @actions ~w(approve sign)
  # Certificates: what the system states at signing (App.Documents.Certificates).
  @facts ~w(service pay family leave_balance trip_settlement)

  files = @dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()
  for file <- files, do: @external_resource(file)

  permissions = App.Access.permissions()

  types =
    for file <- files, into: %{} do
      type = file |> File.read!() |> Jason.decode!()
      id = type["id"]
      name = Path.basename(file, ".json")

      required =
        ~w(id version label icon summary category access register retention_years template route effects basis schema ui)

      missing = Enum.reject(required, &Map.has_key?(type, &1))

      cond do
        id != name ->
          raise "#{file}: id must be #{inspect(name)}"

        missing != [] ->
          raise "#{file}: missing #{Enum.join(missing, ", ")}"

        String.to_atom(type["category"]) not in App.Access.record_categories() ->
          raise "#{file}: category must be one of #{inspect(App.Access.record_categories())}"

        not (is_list(type["access"]["read"]) and type["access"]["read"] != [] and
               Enum.all?(type["access"]["read"], &(&1 in permissions)) and
                 type["access"]["write"] in permissions) ->
          raise "#{file}: access needs read (a list of known permissions) and write (a known permission)"

        type["access"]["self"] not in [nil, true, false] ->
          raise "#{file}: access.self is true or false"

        not (is_binary(type["register"]["code"]) and
                 String.contains?(type["register"]["format"] || "", "{seq}")) ->
          raise "#{file}: register needs a code and a format with {seq}"

        type["route"] == [] or List.last(type["route"])["action"] != "sign" ->
          raise "#{file}: the route must end with a sign step"

        Enum.any?(type["route"], &(&1["action"] not in @actions)) ->
          raise "#{file}: route actions are #{inspect(@actions)}"

        Enum.any?(type["route"], &(&1["permission"] not in permissions)) ->
          raise "#{file}: every route step needs a known permission"

        Enum.any?(
          type["route"],
          &(&1["parallel"] == true and (&1["multiple"] != true or &1["action"] != "approve"))
        ) ->
          raise "#{file}: parallel steps are approvals with multiple assignees"

        Enum.any?(type["route"], &(&1["optional"] == true and &1["action"] == "sign")) ->
          raise "#{file}: the signature can't be optional"

        Enum.any?(type["effects"], &(&1 not in @effects)) ->
          raise "#{file}: effects are #{inspect(@effects)}"

        type["facts"] not in [nil | @facts] ->
          raise "#{file}: facts are #{inspect(@facts)}"

        type["acknowledge"] not in [nil, true, false] ->
          raise "#{file}: acknowledge is true or false"

        type["files"] not in [nil, true, false] ->
          raise "#{file}: files is true or false"

        type["instructions"] not in [nil, true, false] ->
          raise "#{file}: instructions is true or false"

        type["reply_by_executor"] not in [nil, true, false] ->
          raise "#{file}: reply_by_executor is true or false"

        type["subject"] not in [nil, "person", "none"] ->
          raise ~s[#{file}: subject is "person" (the default) or "none"]

        type["subject"] == "none" and type["access"]["self"] == true ->
          raise "#{file}: a document about no person can't be self-service"

        true ->
          {String.to_atom(id), type}
      end
    end

  for {id, type} <- types, basis <- type["basis"], String.to_atom(basis) not in Map.keys(types) do
    raise "#{id}: unknown basis type #{basis}"
  end

  @types types

  @spec ids() :: [atom()]
  def ids, do: @types |> Map.keys() |> Enum.sort()

  @doc "The whole declaration of `type` (the JSON object)."
  @spec get!(atom()) :: map()
  def get!(type), do: Map.fetch!(@types, type)

  @spec label(atom()) :: String.t()
  def label(type), do: get!(type)["label"]

  @spec icon(atom()) :: String.t()
  def icon(type), do: get!(type)["icon"]

  @doc "Permissions that let an actor read documents of `type` (any one of them)."
  @spec read_permissions(atom()) :: [String.t()]
  def read_permissions(type), do: get!(type)["access"]["read"]

  @doc "The permission to write documents of `type`."
  @spec write_permission(atom()) :: String.t()
  def write_permission(type), do: get!(type)["access"]["write"]

  @doc """
  Whether documents of `type` are about a person (the default); `false` for
  types with `"subject": "none"`, such as letters (docs/design/correspondence.md).
  """
  @spec about_person?(atom()) :: boolean()
  def about_person?(type), do: get!(type)["subject"] != "none"

  @doc """
  Whether signing a document of `type` only registers it: a document about
  no person whose route is one signature (an incoming letter) — shown as
  "Registered" rather than "Signed" (docs/design/correspondence.md).
  """
  @spec registration_only?(atom()) :: boolean()
  def registration_only?(type) do
    not about_person?(type) and match?([%{"action" => "sign"}], route(type))
  end

  @doc "Whether documents of `type` carry files (a letter's scan, enclosures)."
  @spec files?(atom()) :: boolean()
  def files?(type), do: get!(type)["files"] == true

  @doc "Whether registered documents of `type` take instructions (incoming letters)."
  @spec instructions?(atom()) :: boolean()
  def instructions?(type), do: get!(type)["instructions"] == true

  @doc """
  Whether the executor of an open instruction on the basis document may
  write a document of `type` (a reply, docs/design/correspondence.md).
  """
  @spec reply_by_executor?(atom()) :: boolean()
  def reply_by_executor?(type), do: get!(type)["reply_by_executor"] == true

  @doc "Whether the person's own account may file and read documents of `type` (self-service)."
  @spec self_service?(atom()) :: boolean()
  def self_service?(type), do: get!(type)["access"]["self"] == true

  @doc "The self-service types."
  @spec self_service_types() :: [atom()]
  def self_service_types, do: Enum.filter(ids(), &self_service?/1)

  @spec category(atom()) :: atom()
  def category(type), do: String.to_existing_atom(get!(type)["category"])

  @spec schema(atom()) :: map()
  def schema(type), do: get!(type)["schema"]

  @spec ui_schema(atom()) :: map()
  def ui_schema(type), do: get!(type)["ui"]

  @spec route(atom()) :: [map()]
  def route(type), do: get!(type)["route"]

  @spec effects(atom()) :: [String.t()]
  def effects(type), do: get!(type)["effects"]

  @doc """
  What a certificate states, computed and frozen when it is signed
  (`App.Documents.Certificates`); nil for other types.
  """
  @spec facts(atom()) :: String.t() | nil
  def facts(type), do: get!(type)["facts"]

  @doc """
  Whether the person a signed document of `type` is about acknowledges it
  (docs/design/acknowledgements.md; `"acknowledge": true`).
  """
  @spec acknowledge?(atom()) :: boolean()
  def acknowledge?(type), do: get!(type)["acknowledge"] == true

  @doc "The types whose signed documents are acknowledged."
  @spec acknowledge_types() :: [atom()]
  def acknowledge_types, do: Enum.filter(ids(), &acknowledge?/1)

  @spec template(atom()) :: String.t()
  def template(type), do: get!(type)["template"]

  @doc "Types a document of `type` may be based on."
  @spec basis(atom()) :: [atom()]
  def basis(type), do: Enum.map(get!(type)["basis"], &String.to_existing_atom/1)

  @doc """
  The register a type numbers in (its code, e.g. `"ос"` for personnel
  orders): types with the same code share one sequence per year.
  """
  @spec register(atom()) :: String.t()
  def register(type), do: get!(type)["register"]["code"]

  @doc """
  The human number for sequence `seq` of `type`'s register, e.g. `15-ос`
  (Ukrainian record-keeping style: the year is not part of the number, the
  registration date is shown next to it; numbering restarts every year).
  """
  @spec number(atom(), integer(), pos_integer()) :: String.t()
  def number(type, year, seq) do
    %{"code" => code, "format" => format} = get!(type)["register"]

    format
    |> String.replace("{seq}", Integer.to_string(seq))
    |> String.replace("{code}", code)
    |> String.replace("{year}", Integer.to_string(year))
  end

  @doc """
  A signed document's identifiers in FHIR form: `masterIdentifier` is the
  stable `urn:uuid:…`; `identifier` is the register number, unique within
  its register and year (`system` `urn:hrda:register:<code>:<year>`).
  """
  @spec identifiers(map()) :: map()
  def identifiers(document) do
    %{
      "masterIdentifier" => %{
        "system" => "urn:ietf:rfc:3986",
        "value" => "urn:uuid:#{document.id}"
      },
      "identifier" =>
        document.number &&
          [
            %{
              "system" => "urn:hrda:register:#{document.register}:#{document.register_year}",
              "value" => document.number
            }
          ]
    }
  end

  @doc """
  Normalizes and validates a draft's fields: types and formats are
  checked, required fields and the conditional rule are not (a draft may
  be incomplete; `cast/2` checks everything when it is sent).
  """
  @spec cast_draft(atom(), map()) :: {:ok, map()} | {:error, [String.t()]}
  def cast_draft(type, data) do
    schema = schema(type)
    data = App.JsonData.normalize(schema, data)

    case App.JsonData.validate(relaxed(schema), data) do
      :ok -> {:ok, data}
      error -> error
    end
  end

  defp relaxed(%{} = schema) do
    schema
    |> Map.drop(["required", "if", "then"])
    |> Map.new(fn {key, value} -> {key, relaxed(value)} end)
  end

  defp relaxed(other), do: other

  @doc """
  Normalizes and validates form data for `type`; errors are readable,
  including the schema's `x-then-message` for its conditional rule.
  """
  @spec cast(atom(), map()) :: {:ok, map()} | {:error, [String.t()]}
  def cast(type, data) do
    schema = schema(type)
    data = App.JsonData.normalize(schema, data)

    case App.JsonData.validate(schema, data) do
      :ok ->
        {:ok, data}

      {:error, errors} ->
        {:error,
         Enum.map(errors, fn error ->
           if String.contains?(error, "then branch"), do: schema["x-then-message"], else: error
         end)}
    end
  end
end
