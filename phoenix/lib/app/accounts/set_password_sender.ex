defmodule App.Accounts.SetPasswordSender do
  @moduledoc """
  Sends the single-use link for setting the password of a PersonID
  sign-in (docs/design/events-and-person-login.md) as the notification
  `:set_password`: on the channels the user chose for it, e-mail by
  default — never in the app, where whoever has the session could use
  it. The link is forgotten once delivered (`App.Notify.Delivery`).
  In development it is also logged, there being no mail.
  """
  use AshAuthentication.Sender

  require Logger

  alias App.Notify.Emitter

  @impl true
  def send(user, token, _opts) do
    path = "/sign-in/person/password?token=" <> URI.encode_www_form(token)
    Emitter.emit(:set_password, [user.id], %{path: path})

    if Application.get_env(:app, :log_sign_in_links, false),
      do: Logger.info("set-password link for user #{user.id}: #{path}")

    :ok
  end
end
