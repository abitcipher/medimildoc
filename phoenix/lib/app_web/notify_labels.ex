defmodule AppWeb.NotifyLabels do
  @moduledoc """
  Titles of notifications (`App.Notify.Events`, written in English) in the
  viewer's language on the notifications page.
  """
  use Gettext, backend: AppWeb.Gettext

  @doc false
  def texts,
    do: [
      gettext_noop("A document waits for your decision"),
      gettext_noop("A document waiting for your decision is overdue"),
      gettext_noop("You have a new instruction"),
      gettext_noop("An instruction to you is overdue"),
      gettext_noop("An instruction you gave is done"),
      gettext_noop("Your document was returned"),
      gettext_noop("A document was signed"),
      gettext_noop("An order awaits your acknowledgement"),
      gettext_noop("New data-consistency incident"),
      gettext_noop("Your account was registered"),
      gettext_noop("Set your password")
    ]

  @doc "A stored title, translated."
  @spec title(String.t()) :: String.t()
  def title(title), do: Gettext.gettext(AppWeb.Gettext, title)
end
