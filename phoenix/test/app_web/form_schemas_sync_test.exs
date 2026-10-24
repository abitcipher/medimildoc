defmodule AppWeb.FormSchemasSyncTest do
  @moduledoc """
  Verifies `priv/form_schemas/*.schema.json` hasn't drifted from what the
  underlying Ash resource actually accepts/requires on `:create` — the
  project's "automated mechanism for synchronizing data types to a single
  source of truth in declarative JSON" (`App.AshJsonSchema`). DB-free: pure
  `Ash.Resource.Info` introspection, no `Ash.create`/`Ash.read` involved.

  A hand-authored file may deliberately show *fewer* fields than Ash
  accepts (e.g. `Assignment`'s `person_id` is contextual — set by the
  LiveView, never a visible form field; `Organization`'s `parent_id` isn't
  exposed in the UI yet) — that's a documented simplification, not drift,
  so this only asserts a *subset* relationship: every field the
  hand-authored file *does* claim must match Ash exactly on type/required.
  """
  use ExUnit.Case, async: true

  alias AppWeb.FormSchemas

  @cases [
    {:person, App.People.Person, :create},
    {:organization, App.People.Organization, :create},
    {:position, App.People.Position, :create},
    {:assignment, App.People.Assignment, :create},
    {:assignment_edit, App.People.Assignment, :update},
    {:care_provider, App.Care.Provider, :create},
    {:deputy, App.Documents.Deputy, :create},
    {:file_plan_case, App.Records.Case, :create},
    {:instruction, App.Documents.Instruction, :give},
    {:instruction_done, App.Documents.Instruction, :complete},
    {:deputy_admin, App.Documents.Deputy, :create},
    {:duty_shift, App.Duty.Shift, :create}
  ]

  for {id, resource, action} <- @cases do
    test "#{id}: priv/form_schemas/#{id}.schema.json matches #{inspect(resource)}'s :#{action} action" do
      id = unquote(id)
      resource = unquote(resource)
      action = unquote(action)
      hand_authored = FormSchemas.schema(id)
      derived = App.AshJsonSchema.derive(resource, action)

      for {field, hand_field_schema} <- hand_authored["properties"] do
        derived_field_schema = derived.properties[field]

        assert derived_field_schema,
               "#{id}.schema.json declares #{inspect(field)}, but #{inspect(resource)}'s " <>
                 ":#{action} action doesn't accept it (renamed/removed attribute?)"

        assert compatible?(hand_field_schema, derived_field_schema),
               "#{id}.schema.json's #{inspect(field)} (#{inspect(hand_field_schema)}) doesn't " <>
                 "match #{inspect(resource)}'s actual type/constraints (#{inspect(derived_field_schema)})"
      end

      hand_required = MapSet.new(hand_authored["required"] || [])
      derived_required = MapSet.new(derived.required)
      missing = MapSet.difference(hand_required, derived_required)

      assert MapSet.subset?(hand_required, derived_required),
             "#{id}.schema.json requires #{inspect(MapSet.to_list(missing))}, but " <>
               "#{inspect(resource)} allows #{inspect(MapSet.to_list(missing))} to be nil"
    end
  end

  # The hand-authored schema is allowed to be *more* restrictive than Ash
  # (e.g. a minLength Ash doesn't enforce) but must never contradict it.
  #
  # "format" is asymmetric on purpose: Ash's :string type has no concept of
  # format at all (App.AshJsonSchema only ever derives one for :date-typed
  # attributes), so a hand-authored "format": "email" is a UI-only widget
  # hint with nothing on the Ash side to check it against — only enforce
  # agreement when Ash actually derived a format (e.g. a real date field
  # secretly becoming a plain string would still be caught).
  defp compatible?(hand, derived) do
    hand["type"] == derived["type"] and
      (hand["enum"] == nil or hand["enum"] == derived["enum"]) and
      (derived["format"] == nil or hand["format"] == derived["format"])
  end
end
