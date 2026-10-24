defmodule App.Notify.Changes.Registration do
  @moduledoc """
  The registration confirmation (user, 2026-09-30): the first sign-in of
  a new account sends `:registration` to it — in the app and to its
  sign-in e-mail — without any subscription — and writes the event
  `hrda.accounts.user.created`. Later sign-ins (the same upsert) send
  nothing.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias App.Notify.Emitter

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      email = Ash.Changeset.get_attribute(changeset, :email)

      existing? =
        App.Accounts.User
        |> Ash.Query.filter(email == ^email)
        |> Ash.exists?(authorize?: false)

      Ash.Changeset.set_context(changeset, %{new_account?: not existing?})
    end)
    |> Ash.Changeset.after_action(fn changeset, user ->
      if changeset.context[:new_account?] do
        Emitter.emit(:registration, [user.id])

        # docs/design/events-and-person-login.md: a new account is an event.
        App.EventLog.emit("hrda.accounts.user.created", %{method: "google", role: user.role},
          subject: "user/#{user.id}"
        )
      end

      {:ok, user}
    end)
  end
end
