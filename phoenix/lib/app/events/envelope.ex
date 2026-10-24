defmodule App.Events.Envelope do
  @moduledoc """
  The packet of an event (docs/design/events-and-person-login.md): a
  CloudEvents 1.0 structured JSON object, the same for the event log page
  and external subscribers. Extension attributes: `severity`, `actorid`,
  `correlationid` (lower-case alphanumerics, as CloudEvents requires).
  """

  @doc "The CloudEvents map of an event row."
  @spec build(map()) :: map()
  def build(event) do
    %{
      "specversion" => "1.0",
      "id" => event.id,
      "type" => event.type,
      "source" => event.source,
      "time" => DateTime.to_iso8601(event.occurred_at),
      "datacontenttype" => "application/json",
      "dataschema" => "urn:hrda:event:#{event.type}:1",
      "severity" => event.severity,
      "data" => event.data
    }
    |> put("subject", event.subject)
    |> put("actorid", event.actor_id)
    |> put("correlationid", event.correlation_id)
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
