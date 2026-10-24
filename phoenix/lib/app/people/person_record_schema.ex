defmodule App.People.PersonRecordSchema do
  @moduledoc """
  Loads the JSON Schema + UI Schema pair for each `App.People.PersonRecord`
  `kind` from `priv/person_record_schemas/`, and validates record data
  against it.

  JSON Schema/UI Schema are mandatory for every form and data
  type — these files are the single source of truth a future form renderer
  and this module's own validation both read from, so schema and validation
  can never drift apart. Adding a new `kind` ("modular growth")
  means dropping in two new files here and adding the atom to `@kinds`
  below — no resource/migration change needed, `data` is just JSONB.

  Loaded at compile time (`@external_resource` triggers recompilation when a
  schema file changes) rather than read from disk per call — pure lookups
  once compiled, no runtime file I/O on the request path.
  """

  alias App.Access.SecurityLabels

  @schemas_dir Path.expand("../../../priv/person_record_schemas", __DIR__)

  @kinds [
    :medical_condition,
    :status_change,
    # — illustrative placeholders for NATO STANAG-adjacent
    # standards (APERSP-01, STANAG 5046, STANAG 6001). Explicitly NOT
    # verified against the primary standards texts — see each schema
    # file's "description" and for exactly what's
    # unverified in each.
    :rank_history,
    :contact_info,
    :language_proficiency,
    # — two of :status_change's own enum cases
    # (marital_status_change, pay_change) promoted to first-class kinds,
    # demonstrating the modular-growth mechanism :status_change's own
    # description names as the reason it exists.
    :family_status,
    :compensation,
    # — the follow-up :family_status's own description
    # flagged: one dependent per PersonRecord, not a nested list inside
    # :family_status's dependentsCount.
    :dependent,
    # — AC/35-D/2000-flavored (illustrative, unverified, see
    # /), now that a real role model () exists to eventually
    # build finer access rules on top of, if that's ever actually needed.
    :security_clearance,
    # docs/design/access-control-phase1.md: readiness status for line
    # commanders, allergies (FHIR AllergyIntolerance), and the restricted
    # half of the old security_clearance.
    :fitness_for_duty,
    :allergy_intolerance,
    :vetting_record,
    # docs/design/clinical-module.md: point-of-care encounters and vital
    # signs (FHIR Encounter / vital-signs Observations).
    :encounter,
    :vital_signs,
    # docs/design/clinical-medications.md: given medications and
    # procedures, within an encounter (FHIR MedicationAdministration /
    # Procedure).
    :medication_administration,
    :procedure,
    # docs/design/clinical-medications.md §Long-term list: what a person
    # takes (FHIR MedicationStatement).
    :medication_statement,
    # docs/design/lab-results.md: one laboratory test (FHIR Observation,
    # category laboratory).
    :lab_result,
    # docs/design/leave.md: leave granted by an order, the source of
    # leave balances.
    :leave,
    # docs/design/business-trips.md: a business trip ordered for a period.
    :business_trip
  ]

  loaded =
    for kind <- @kinds, into: %{} do
      schema_path = Path.join(@schemas_dir, "#{kind}.schema.json")
      ui_path = Path.join(@schemas_dir, "#{kind}.ui.json")
      @external_resource schema_path
      @external_resource ui_path

      {kind,
       %{
         schema: Jason.decode!(File.read!(schema_path)),
         ui_schema: Jason.decode!(File.read!(ui_path))
       }}
    end

  @loaded loaded

  # Access metadata declared in each schema file (docs/design/
  # access-control-phase1.md): the kind's record category and default
  # security labels, plus the schema version new records are stamped with.
  # A kind with missing or unknown values fails the build.
  collect_controls = fn collect, element ->
    case element do
      %{"type" => "Control", "scope" => _scope} = control -> [control]
      %{"elements" => elements} -> Enum.flat_map(elements, &collect.(collect, &1))
      _ -> []
    end
  end

  # Values the server sets (`"x-system": "value"`, e.g. a lab result's
  # reference range): on the record card after the form's fields, never
  # in the form (docs/design/lab-results.md).
  system_controls = fn schema ->
    for {key, %{"x-system" => "value"} = property} <- schema["properties"] || %{},
        do: %{
          "type" => "Control",
          "scope" => "#/properties/" <> key,
          "label" => property["x-label"]
        }
  end

  field_list = fn schema, ui_schema ->
    for control <-
          collect_controls.(collect_controls, ui_schema) ++ system_controls.(schema) do
      path =
        control["scope"]
        |> String.split("/")
        |> Enum.reject(&(&1 in ["#", "properties"]))

      property =
        Enum.reduce(path, schema, fn key, acc -> get_in(acc, ["properties", key]) || %{} end)

      # A number whose unit is a sibling choice (`x-unit-field`, a dose).
      unit_field = property["x-unit-field"]

      unit_labels =
        unit_field &&
          Enum.reduce(Enum.drop(path, -1) ++ [unit_field], schema, fn key, acc ->
            get_in(acc, ["properties", key]) || %{}
          end)["x-enum-labels"]

      %{
        path: path,
        label: control["label"] || List.last(path),
        help: property["x-help"],
        type: property["type"],
        format: property["format"] || property["x-format"],
        unit: property["x-unit"],
        # A list of choices keeps its choices in `items`.
        enum: property["enum"] || get_in(property, ["items", "enum"]),
        enum_labels: property["x-enum-labels"],
        reference: property["x-reference"],
        # Short visual badges for choice values: %{value => %{"symbol", "color"}}.
        badges: property["x-enum-badges"],
        unit_field: unit_field && {Enum.drop(path, -1) ++ [unit_field], unit_labels || %{}},
        # Shown in the form only, not on the record card (`"x-card": false`).
        card?: property["x-card"] != false,
        multi: get_in(control, ["options", "multi"]) == true
      }
    end
  end

  meta =
    for {kind, %{schema: schema, ui_schema: ui_schema}} <- loaded, into: %{} do
      category = String.to_atom(schema["x-category"] || "")
      confidentiality = String.to_atom(schema["x-confidentiality"] || "")
      classification = schema["x-classification"] && String.to_atom(schema["x-classification"])
      version = schema["x-version"]

      cond do
        category not in App.Access.record_categories() ->
          raise "#{kind}.schema.json: x-category must be one of " <>
                  inspect(App.Access.record_categories())

        confidentiality not in SecurityLabels.confidentiality_levels() ->
          raise "#{kind}.schema.json: x-confidentiality must be one of " <>
                  inspect(SecurityLabels.confidentiality_levels())

        classification not in [nil | SecurityLabels.classifications()] ->
          raise "#{kind}.schema.json: x-classification must be null or one of " <>
                  inspect(SecurityLabels.classifications())

        not is_binary(version) ->
          raise "#{kind}.schema.json: x-version must be a string"

        not Enum.all?(~w(x-label x-icon x-summary), &is_binary(schema[&1])) ->
          raise "#{kind}.schema.json: x-label, x-icon and x-summary are required strings"

        true ->
          {kind,
           %{
             category: category,
             confidentiality: confidentiality,
             classification: classification,
             version: version,
             label: schema["x-label"],
             part_of: Enum.map(schema["x-part-of"] || [], &String.to_atom/1),
             icon: schema["x-icon"],
             summary: schema["x-summary"],
             fields: field_list.(schema, ui_schema)
           }}
      end
    end

  @meta meta

  @doc "The `PersonRecord` kinds with a schema defined."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "The record category `kind` belongs to."
  @spec category(atom()) :: atom()
  def category(kind), do: @meta |> Map.fetch!(kind) |> Map.fetch!(:category)

  @doc "Kinds in `category`."
  @spec kinds_in_category(atom()) :: [atom()]
  def kinds_in_category(category), do: Enum.filter(@kinds, &(category(&1) == category))

  @doc "The minimum confidentiality label for records of `kind`."
  @spec default_confidentiality(atom()) :: atom()
  def default_confidentiality(kind), do: @meta |> Map.fetch!(kind) |> Map.fetch!(:confidentiality)

  @doc "The minimum classification for records of `kind` (`nil` = not classified)."
  @spec default_classification(atom()) :: atom() | nil
  def default_classification(kind), do: @meta |> Map.fetch!(kind) |> Map.fetch!(:classification)

  @doc "The current schema version for `kind`; new and updated records are stamped with it."
  @spec version(atom()) :: String.t()
  def version(kind), do: @meta |> Map.fetch!(kind) |> Map.fetch!(:version)

  @doc """
  Kinds a record of `kind` may belong to (`x-part-of`, e.g. vital signs
  within an encounter; `PersonRecord.part_of_id`). Empty for most kinds.
  """
  @spec part_of(atom()) :: [atom()]
  def part_of(kind), do: @meta |> Map.fetch!(kind) |> Map.fetch!(:part_of)

  @doc "The user-facing name of `kind` (English; also its Gettext msgid)."
  @spec label(atom()) :: String.t()
  def label(kind), do: @meta |> Map.fetch!(kind) |> Map.fetch!(:label)

  @doc "The Heroicons name shown for `kind`."
  @spec icon(atom()) :: String.t()
  def icon(kind), do: @meta |> Map.fetch!(kind) |> Map.fetch!(:icon)

  @doc "One user-facing sentence about what a `kind` record holds."
  @spec summary(atom()) :: String.t()
  def summary(kind), do: @meta |> Map.fetch!(kind) |> Map.fetch!(:summary)

  @doc """
  The fields of `kind` in display order, from its UI Schema: `path` into
  `data`, `label`, user-facing `help` (the property's `x-help`; the JSON
  Schema `description` is developer documentation and is never shown),
  and the property's `type`, `format`, `enum` and `x-enum-labels` for
  formatting values.
  """
  @spec fields(atom()) :: [map()]
  def fields(kind), do: @meta |> Map.fetch!(kind) |> Map.fetch!(:fields)

  @doc """
  Top-level fields the server sets as warnings (`"x-system": "alert"`, e.g.
  a medication's allergy warning): not in the form, shown on the record.
  `[{key, label}]`.
  """
  @spec alert_fields(atom()) :: [{String.t(), String.t()}]
  def alert_fields(kind) do
    for {key, %{"x-system" => "alert"} = property} <- schema(kind)["properties"] || %{},
        do: {key, property["x-label"] || key}
  end

  @doc """
  The badge (`%{"symbol" => "+", "color" => "success"}`) declared for a
  choice value of a top-level `field` of `kind` (`x-enum-badges`), or nil.
  """
  @spec badge(atom(), String.t(), String.t() | nil) :: map() | nil
  def badge(kind, field, value) do
    Enum.find_value(fields(kind), fn
      %{path: [^field], badges: %{} = badges} -> badges[value]
      _ -> nil
    end)
  end

  @doc "The JSON Schema for `kind`, or `nil` if `kind` is unknown."
  @spec schema(atom()) :: map() | nil
  def schema(kind), do: get_in(@loaded, [kind, :schema])

  @doc "The JSON Forms UI Schema for `kind`, or `nil` if `kind` is unknown."
  @spec ui_schema(atom()) :: map() | nil
  def ui_schema(kind), do: get_in(@loaded, [kind, :ui_schema])

  @doc """
  Turns submitted form values into the JSON types the kind's schema
  declares, before validation and storage:

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
  @spec normalize(atom(), map()) :: map()
  def normalize(kind, data) when is_map(data) do
    case schema(kind) do
      nil -> data
      schema -> App.JsonData.normalize(schema, data)
    end
  end

  @doc """
  Validates `data` against the JSON Schema for `kind`. Returns human-readable
  `"path: message"` strings on failure.
  """
  @spec validate(atom(), map()) :: :ok | {:error, [String.t()]}
  def validate(kind, data) when is_map(data) do
    case schema(kind) do
      nil ->
        {:error, ["unknown PersonRecord kind: #{inspect(kind)}"]}

      schema ->
        App.JsonData.validate(schema, data)
    end
  end
end
