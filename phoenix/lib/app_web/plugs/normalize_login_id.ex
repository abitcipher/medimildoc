defmodule AppWeb.Plugs.NormalizeLoginId do
  @moduledoc """
  The PersonID typed into the password sign-in form, as stored
  (docs/design/events-and-person-login.md): the app shows it as
  `AAAA-BBBB-CCCC`, the account holds the bare code, and the strategy
  compares them as they are. Only for the sign-in POST.
  """
  @behaviour Plug

  alias App.Accounts.PersonLogin

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "POST", path_info: ["auth", "user", "password", "sign_in"]} = conn, _opts) do
    case conn.params do
      %{"user" => %{"login_id" => login_id}} when is_binary(login_id) ->
        login_id = PersonLogin.normalize(login_id)

        %{
          conn
          | params: put_in(conn.params, ["user", "login_id"], login_id),
            body_params: put_login_id(conn.body_params, login_id)
        }

      _ ->
        conn
    end
  end

  def call(conn, _opts), do: conn

  defp put_login_id(%{"user" => %{} = user} = params, login_id),
    do: %{params | "user" => Map.put(user, "login_id", login_id)}

  defp put_login_id(params, _login_id), do: params
end
