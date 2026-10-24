defmodule App.Sheets do
  @moduledoc """
  Context boundary for real-time Sheets edit notifications (M2, 
  Broadcast-only — no persistence yet (that's M3/Ash territory).
  Sheets stays a view, never the source of truth : this only tells
  already-subscribed LiveViews "something changed here, go re-fetch"; it
  never carries the edited value itself, and delivery isn't guaranteed
  (`onEdit` isn't transactional).
  """

  @pubsub App.PubSub

  @spec topic(String.t()) :: String.t()
  def topic(spreadsheet_id), do: "sheets:#{spreadsheet_id}"

  @doc "Subscribes the calling process to edit notifications for one spreadsheet."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(spreadsheet_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(spreadsheet_id))
  end

  @doc """
  Notifies subscribers that a cell/range changed. `attrs` is informational
  only (e.g. `%{sheet_name: ..., a1: ...}`, straight from the Apps Script
  onEdit event) — never trusted for authorization.
  """
  @spec notify_edit(String.t(), map()) :: :ok
  def notify_edit(spreadsheet_id, attrs) do
    Phoenix.PubSub.broadcast(@pubsub, topic(spreadsheet_id), {:sheets_edit, attrs})
  end
end
