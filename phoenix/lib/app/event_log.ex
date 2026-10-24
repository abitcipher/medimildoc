defmodule App.EventLog do
  @moduledoc """
  The way into the general event log (docs/design/events-and-person-login.md):
  `emit/3` writes an event declared in `priv/events.json`; the switches
  `events.logging` and `events.publishing` (`App.Settings`) are changed
  only through `set_logging/2` and `set_publishing/2`, which always record
  the change — even with the log off.

  The sink today is a Postgres row (`App.Events.Event`), which is also the
  publishing outbox (`App.Events.Publisher`). Moving the log to its own
  service changes this module only: callers and the packet
  (`App.Events.Envelope`) stay.
  """
  alias App.Events.{Catalog, Event}

  @doc """
  Writes the event `type` with `data` (only fields declared for it).

  Options: `actor` (a user, or its id), `subject` (`"<kind>/<id>"`).
  Returns `:ok` also when the log is off and nothing is written; an
  undeclared type or field raises.
  """
  @spec emit(String.t(), map(), keyword()) :: :ok
  def emit(type, data \\ %{}, opts \\ []) do
    spec = Catalog.fetch!(type)
    data = Map.new(data, fn {key, value} -> {to_string(key), value} end)

    case Map.keys(data) -- spec.data do
      [] ->
        :ok

      extra ->
        raise ArgumentError, "#{type}: undeclared data #{inspect(extra)} (priv/events.json)"
    end

    meta? = Catalog.domain(type) == "events"

    if meta? or logging?() do
      write(type, spec, data, opts)
    end

    :ok
  end

  defp write(type, spec, data, opts) do
    Event
    |> Ash.Changeset.for_create(
      :record,
      %{
        type: type,
        severity: spec.severity,
        source: "/hrda/#{instance()}/#{Catalog.domain(type)}",
        subject: opts[:subject],
        actor_id: actor_id(opts[:actor]),
        correlation_id: Logger.metadata()[:request_id],
        data: Map.reject(data, fn {_key, value} -> is_nil(value) end),
        # Switching publishing off is written (and so published) before
        # the switch, as the last packet (switch/4).
        publish: spec.publish? and publishing?()
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  @doc "Is the general event log on?"
  @spec logging?() :: boolean()
  def logging?, do: App.Settings.get("events.logging") == true

  @doc "Are events published to external subscribers? (Needs the log on.)"
  @spec publishing?() :: boolean()
  def publishing?, do: logging?() and App.Settings.get("events.publishing") == true

  @doc "Switches the log on or off as `actor` (`settings.manage`); always recorded."
  @spec set_logging(boolean(), map()) :: :ok | {:error, term()}
  def set_logging(on?, actor), do: switch("events.logging", "logging", on?, actor)

  @doc "Switches publishing on or off as `actor` (`settings.manage`); always recorded."
  @spec set_publishing(boolean(), map()) :: :ok | {:error, term()}
  def set_publishing(on?, actor), do: switch("events.publishing", "publishing", on?, actor)

  # The "off" event is written before switching, so that it is still
  # published; the "on" event after.
  defp switch(key, name, on?, actor) do
    type = "hrda.events.#{name}.#{if on?, do: "enabled", else: "disabled"}"

    if App.Access.can?(actor, "settings.manage") do
      App.Repo.transaction(fn -> put_recorded(key, type, on?, actor) end)
      |> case do
        {:ok, _} -> :ok
        error -> error
      end
    else
      {:error, :forbidden}
    end
  end

  defp put_recorded(key, type, on?, actor) do
    unless on?, do: emit(type, %{}, actor: actor)

    case App.Settings.put(key, on?, actor) do
      :ok -> if on?, do: emit(type, %{}, actor: actor)
      {:error, error} -> App.Repo.rollback(error)
    end
  end

  @doc "Which instance this is, in the event source (`config :app, :events_instance`)."
  @spec instance() :: String.t()
  def instance, do: Application.get_env(:app, :events_instance) || "local"

  defp actor_id(nil), do: nil
  defp actor_id(%{id: id}), do: id
  defp actor_id(id) when is_binary(id), do: id
end
