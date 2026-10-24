defmodule AppWeb.FormSchemas do
  @moduledoc """
  Loads the JSON Schema + UI Schema pair for each standard resource form
  (`:person`, `:organization`, `:position`, `:assignment`,
  `:assignment_edit` — the editable subset of `Assignment` shown on its
  inline edit form, since `position_id`/`person_id` are set once at
  creation; `:person_identifier`, `:identity_document`) from 
  `priv/form_schemas/` — "JSON Schema/UI Schema mandatory
  for every form" applied to the ordinary Ash-attribute resources, the
  counterpart to `App.People.PersonRecordSchema` (which covers the
  polymorphic `PersonRecord.data`).

  Deliberately *not* the validation source of truth here, unlike
  `PersonRecordSchema`: these resources already have full Ash-level
  attribute constraints (`allow_nil?`, `max_length`, ...), so duplicating
  that as a second, separately-maintained JSON Schema would just create two
  sources of truth that can drift. These schemas exist purely to drive
  `AppWeb.JsonSchemaForm`'s widget/label choices; real validation errors
  always come from Ash via `AshPhoenix.Form`.

  Ash stays authoritative even so: `App.AshJsonSchema` derives the JSON
  Schema an action actually accepts/requires by introspection, and
  `test/app_web/form_schemas_sync_test.exs` asserts every field these files
  declare agrees with it (type, `enum`, `required`) — the "automated
  mechanism for synchronizing data types to a single source of truth"
  hand-copied fields like `organization.schema.json`'s `kind` enum used to
  risk drifting from `App.People.Organization`'s `constraints one_of:
  [...]` without one. A field can still be hand-omitted here on purpose
  (contextual/deferred fields, e.g. `Assignment`'s `person_id`) — the sync
  test only checks a subset relationship, not full equality.

  Loaded at compile time, same as `PersonRecordSchema` — see there for why.
  """

  @schemas_dir Path.expand("../../priv/form_schemas", __DIR__)

  @ids [
    :person,
    :organization,
    :position,
    :assignment,
    :assignment_edit,
    :person_identifier,
    :identity_document,
    :care_provider,
    :deputy,
    :file_plan_case,
    :instruction,
    :instruction_done,
    :deputy_admin,
    :duty_shift
  ]

  loaded =
    for id <- @ids, into: %{} do
      schema_path = Path.join(@schemas_dir, "#{id}.schema.json")
      ui_path = Path.join(@schemas_dir, "#{id}.ui.json")
      @external_resource schema_path
      @external_resource ui_path

      {id,
       %{
         schema: Jason.decode!(File.read!(schema_path)),
         ui_schema: Jason.decode!(File.read!(ui_path))
       }}
    end

  @loaded loaded

  @doc "The form ids with a schema defined."
  @spec ids() :: [atom()]
  def ids, do: @ids

  @doc "The JSON Schema for `id`, or `nil` if `id` is unknown."
  @spec schema(atom()) :: map() | nil
  def schema(id), do: get_in(@loaded, [id, :schema])

  @doc "The JSON Forms UI Schema for `id`, or `nil` if `id` is unknown."
  @spec ui_schema(atom()) :: map() | nil
  def ui_schema(id), do: get_in(@loaded, [id, :ui_schema])
end
