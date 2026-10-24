defmodule App.Notify.Events do
  @moduledoc """
  The events users can subscribe to, and their messages
  (docs/design/search-timeline-notifications.md). A message says what
  happened and names the document type and number — never a person's
  name or any personal or medical detail. Texts are in English; the web
  layer translates them in the app (`AppWeb.NotifyLabels`).
  """

  @subscribable [
    :document_waiting,
    :document_overdue,
    :document_returned,
    :document_signed,
    :document_to_acknowledge,
    :instruction_given,
    :instruction_overdue,
    :instruction_done,
    :incident,
    # The single-use link for a PersonID password (never in the app).
    :set_password
  ]

  @doc "Events a user may subscribe to."
  @spec subscribable() :: [atom()]
  def subscribable, do: @subscribable

  @doc "Channels a notification can go to."
  @spec channels() :: [atom()]
  def channels, do: [:in_app, :email, :telegram, :signal, :matrix]

  @doc "Title and body of an event's message."
  @spec message(atom(), map()) :: {String.t(), String.t()}
  def message(:document_waiting, p),
    do: {"A document waits for your decision", document(p)}

  def message(:document_overdue, p),
    do: {"A document waiting for your decision is overdue", document(p)}

  def message(:document_returned, p), do: {"Your document was returned", document(p)}
  def message(:document_signed, p), do: {"A document was signed", document(p)}

  def message(:document_to_acknowledge, p),
    do: {"An order awaits your acknowledgement", document(p)}

  def message(:instruction_given, p), do: {"You have a new instruction", document(p)}
  def message(:instruction_overdue, p), do: {"An instruction to you is overdue", document(p)}
  def message(:instruction_done, p), do: {"An instruction you gave is done", document(p)}

  def message(:incident, p),
    do: {"New data-consistency incident", "Rule: #{p[:rule] || "?"}. Review it in Incidents."}

  def message(:set_password, _p),
    do:
      {"Set your password",
       "Open the link to set the password for signing in with your PersonID. It works once, for 30 minutes. If you did not ask for it, ignore this message."}

  def message(:registration, _p),
    do:
      {"Your account was registered",
       "You can now sign in. An administrator gives you access to the data you need."}

  defp document(p), do: Enum.join(Enum.reject([p[:type], p[:number]], &is_nil/1), " ")
end
