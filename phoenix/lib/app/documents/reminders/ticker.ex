defmodule App.Documents.Reminders.Ticker do
  @moduledoc """
  Runs `App.Documents.Reminders.run/0` a minute after start and then every
  `interval` (an hour by default). Started by `App.Application` on the
  server only (not in tests or release tasks).
  """
  use GenServer

  require Logger

  alias App.Documents.Reminders

  @hour 60 * 60 * 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @hour)
    Process.send_after(self(), :run, Keyword.get(opts, :first, 60_000))
    {:ok, interval}
  end

  @impl true
  def handle_info(:run, interval) do
    try do
      Reminders.run()
    rescue
      error -> Logger.error("Overdue reminders failed: " <> Exception.message(error))
    end

    Process.send_after(self(), :run, interval)
    {:noreply, interval}
  end
end
