defmodule App.Accounts.Throttle do
  @moduledoc """
  Failed-attempt counters for PersonID sign-in
  (docs/design/events-and-person-login.md): `fail/3` counts a failure
  for a key within a window and locks the key once the limit is reached;
  `locked_until/1` says whether (and until when) a key is locked. Keys
  are `{:login, digest}` and `{:ip, address}`.

  In memory (ETS), for the one application server we run: a restart
  forgets the counters, which only shortens a lock.
  """
  use GenServer

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end

  @doc """
  Counts a failure for `key`. With `limit` failures inside the window
  (`window_s` seconds since the first) the key is locked for the window:
  returns `{:locked, until}`; otherwise `:ok`.
  """
  @spec fail(term(), pos_integer(), pos_integer()) :: :ok | {:locked, DateTime.t()}
  def fail(key, limit, window_s) do
    now = System.system_time(:second)

    {count, first} =
      case :ets.lookup(@table, key) do
        [{^key, count, first, _until}] when now - first < window_s -> {count + 1, first}
        _ -> {1, now}
      end

    if count >= limit do
      until = now + window_s
      :ets.insert(@table, {key, count, first, until})
      {:locked, DateTime.from_unix!(until)}
    else
      :ets.insert(@table, {key, count, first, nil})
      :ok
    end
  end

  @doc "Until when `key` is locked, or nil."
  @spec locked_until(term()) :: DateTime.t() | nil
  def locked_until(key) do
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, _count, _first, until}] when is_integer(until) and until > now ->
        DateTime.from_unix!(until)

      _ ->
        nil
    end
  end

  @doc "Forgets the failures of `key` (after a successful sign-in)."
  @spec reset(term()) :: :ok
  def reset(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc "Forgets every counter (tests)."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end
end
