defmodule App.Cache do
  @moduledoc """
  A small ETS cache with per-entry expiry (reference data from IHDS,
  signed photo links). The process only owns the table; reads and writes
  go straight to ETS from the caller. Keys are namespaced by the caller.
  """
  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec fetch(term()) :: {:ok, term()} | :miss
  def fetch(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, expires_at, value}] when expires_at > now -> {:ok, value}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @spec put(term(), term(), non_neg_integer()) :: :ok
  def put(key, value, ttl_ms) do
    :ets.insert(@table, {key, System.monotonic_time(:millisecond) + ttl_ms, value})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Empties the cache (tests; after a new seed version is deployed)."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
