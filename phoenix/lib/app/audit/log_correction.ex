defmodule App.Audit.LogCorrection do
  @moduledoc """
  Records a direct change to an assignment as an `App.Audit.Correction`,
  after it succeeded and in its transaction. Used on the direct actions
  only; a signed order's effects use their own actions. Changes without
  an actor (demo data, maintenance) are not logged, like the access log.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: %{id: _} = actor}) do
    Ash.Changeset.after_action(changeset, fn changeset, record ->
      write(changeset, record, actor)
      {:ok, record}
    end)
  end

  def change(changeset, _opts, _context), do: changeset

  defp write(changeset, record, actor) do
    App.Audit.Correction
    |> Ash.Changeset.for_create(
      :create,
      %{
        resource: inspect(changeset.resource),
        record_id: record.id,
        person_id: Map.get(record, :person_id),
        action: changeset.action_type,
        actor_id: actor.id,
        actor_email: to_string(actor.email),
        changes: changes(changeset)
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp changes(%{action_type: :destroy, data: data}),
    do: %{
      "removed" => %{
        "position_id" => data.position_id,
        "starts_on" => to_string(data.starts_on),
        "ends_on" => data.ends_on && to_string(data.ends_on)
      }
    }

  defp changes(changeset) do
    Map.new(changeset.attributes, fn {key, value} ->
      {to_string(key), %{"from" => json(Map.get(changeset.data, key)), "to" => json(value)}}
    end)
  end

  defp json(%Date{} = date), do: Date.to_iso8601(date)
  defp json(value), do: value
end
