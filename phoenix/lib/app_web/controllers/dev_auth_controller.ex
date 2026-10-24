if Application.compile_env(:app, :dev_routes) do
  defmodule AppWeb.DevAuthController do
    @moduledoc """
    Dev-only sign-in bypass — the whole module only
    compiles when `config :app, dev_routes: true` (`config/dev.exs` only;
    `test`/`prod` never set it, same guard `mix phx.new` already used for
    `LiveDashboard`/the mailbox preview, see `router.ex`). Exists so a
    local `mix phx.server` can be clicked through end to end without real
    Google OAuth credentials configured — the real `/sign-in` (Google)
    is untouched and still the only way to sign in anywhere else
    (staging/production).

    Picks an existing `App.Accounts.User` by email, or creates one on the
    fly with the chosen role — `Ash.Seed.seed!/2` (`authorize?: false`),
    the same bootstrap technique this project has used from a remote
    console since (there's no actor yet to authorize
    against; this tool exists specifically to get one).

    Signs in by minting a real JWT (`AshAuthentication.Jwt.
    token_for_user/1`) and writing it into the session under the exact
    key (`"user_token"`) the rest of the app already expects — the same
    hand-mint technique this project has used from a remote console/test
    helper since  just reachable from a browser now.
    **Not** `AshAuthentication.Plug.Helpers.store_in_session/2`: that
    helper reads the token back off `user.__metadata__.token`, which only
    a real sign-in-producing Ash action (`register_with_google`)
    populates — confirmed live, a plain `Ash.read_one`/`Ash.Seed.seed!`
    record has no such metadata and crashes it with `KeyError: key
    :token not found`.
    """
    use AppWeb, :controller

    alias App.Accounts.User

    require Ash.Query

    @roles App.Access.roles()

    def new(conn, _params) do
      users = User |> Ash.Query.sort(email: :asc) |> Ash.read!(authorize?: false)
      render(conn, :new, users: users, roles: @roles)
    end

    def create(conn, %{"email" => email, "role" => role}) when email != "" do
      role = String.to_existing_atom(role)

      user =
        case Ash.Query.filter(User, email == ^email) |> Ash.read_one(authorize?: false) do
          {:ok, %User{} = existing} -> existing
          _ -> Ash.Seed.seed!(User, %{email: email, role: role})
        end

      {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

      conn
      |> put_session("user_token", token)
      |> put_flash(:info, "Signed in as #{user.email} (dev-only, no Google OAuth).")
      |> redirect(to: ~p"/")
    end

    def create(conn, _params) do
      conn
      |> put_flash(:error, "Pick or type an email first.")
      |> redirect(to: ~p"/dev/sign-in")
    end
  end
end
