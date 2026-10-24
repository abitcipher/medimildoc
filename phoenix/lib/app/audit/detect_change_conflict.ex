defmodule App.Audit.DetectChangeConflict do
  @moduledoc """
  last-write-wins stays the resolution strategy
  — this never rejects a write, only logs it as an `App.Audit.ChangeConflict`
  when one is detected. Add `change App.Audit.DetectChangeConflict` to any
  editable resource's `:update` action to get this "for free" — no
  LiveView changes needed, since the comparison uses `changeset.data`
  (whatever `updated_at` the record had when this changeset/form was
  built), not anything the caller has to thread through explicitly.

  A collision is: this changeset was built from a row with `updated_at`
  X, but by the time this write is about to happen, the row in the
  database has some *different* `updated_at` — meaning somebody else's
  write landed in between load and save, and this write is about to
  silently overwrite it.

  `require_atomic? false` is required wherever this is added — it does
  its own `Ash.get/3` before the write, which an atomic SQL UPDATE can't
  express.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      maybe_log_conflict(changeset, context)
      changeset
    end)
  end

  defp maybe_log_conflict(changeset, context) do
    expected_updated_at = changeset.data.updated_at

    with false <- is_nil(expected_updated_at),
         {:ok, %{updated_at: found_updated_at}} <-
           Ash.get(changeset.resource, changeset.data.id, authorize?: false),
         true <- found_updated_at != expected_updated_at do
      log_conflict(changeset, expected_updated_at, found_updated_at, context.actor)
    else
      _ -> :ok
    end
  end

  defp log_conflict(changeset, expected_updated_at, found_updated_at, actor) do
    App.Audit.ChangeConflict
    |> Ash.Changeset.for_create(:create, %{
      resource: inspect(changeset.resource),
      record_id: changeset.data.id,
      actor_id: actor && Map.get(actor, :id),
      actor_email: actor && Map.get(actor, :email) && to_string(actor.email),
      expected_updated_at: expected_updated_at,
      found_updated_at: found_updated_at
    })
    |> Ash.create(authorize?: false)
  end
end
