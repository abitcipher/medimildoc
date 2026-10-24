defmodule AppWeb.AuthController do
  @moduledoc """
  Handles the outcome of every `AshAuthentication.Phoenix` auth route
  (`/auth/user/google`, `/auth/user/password/...`, `/sign-out`) —
  installer-generated, extended for docs/design/events-and-person-login.md:

  - every sign-in, failure and sign-out is an access event
    (`App.EventLog`), with the client address (`AppWeb.ClientIp`);
  - PersonID + password: five failures for one PersonID in 15
    minutes, or 30 from one address, lock it for 15 minutes
    (`App.Accounts.Throttle`); while locked even the right password does
    not sign in, and the answer is the same as for a wrong one;
  - setting the password through the e-mailed link signs the person in
    (`{:password, :reset}`, event `hrda.auth.password.set`);
  - the session remembers when it signed in (`:signed_in_at`), which tells
    a fresh sign-in for confirming an action.
  """
  use AppWeb, :controller
  use AshAuthentication.Phoenix.Controller

  alias App.Accounts.{PersonLogin, Throttle}
  alias App.Search.Digest

  @login_limit 5
  @ip_limit 30
  @window_s 15 * 60

  def success(conn, {:password, :sign_in} = activity, user, token) do
    ip = AppWeb.ClientIp.of(conn)
    digest = login_digest(conn)

    if Throttle.locked_until({:login, digest}) || Throttle.locked_until({:ip, ip}) do
      App.EventLog.emit("hrda.auth.sign_in.failed", %{
        method: "person_id",
        reason: "locked",
        ip: ip,
        login_digest: digest
      })

      locked(conn)
    else
      Throttle.reset({:login, digest})
      sign_in(conn, activity, user, token)
    end
  end

  def success(conn, {:password, :reset} = activity, user, token) do
    App.EventLog.emit("hrda.auth.password.set", %{ip: AppWeb.ClientIp.of(conn)},
      actor: user,
      subject: "user/#{user.id}"
    )

    sign_in(conn, activity, user, token)
  end

  def success(conn, activity, user, token), do: sign_in(conn, activity, user, token)

  defp sign_in(conn, activity, user, _token) do
    return_to = get_session(conn, :return_to) || ~p"/"

    message =
      case activity do
        {:password, :reset} -> gettext("Your password is set. You are signed in.")
        _ -> gettext("You are now signed in")
      end

    App.EventLog.emit(
      "hrda.auth.session.started",
      %{method: method(activity), ip: AppWeb.ClientIp.of(conn)},
      actor: user,
      subject: "user/#{user.id}"
    )

    user
    |> Ash.Changeset.for_update(:signed_in, %{})
    |> Ash.update(authorize?: false)

    conn
    |> delete_session(:return_to)
    |> put_session(:signed_in_at, System.system_time(:second))
    |> store_in_session(user)
    |> assign(:current_user, user)
    |> put_flash(:info, message)
    |> redirect(to: return_to)
  end

  def failure(conn, {:password, :sign_in}, _reason) do
    ip = AppWeb.ClientIp.of(conn)
    digest = login_digest(conn)

    App.EventLog.emit("hrda.auth.sign_in.failed", %{
      method: "person_id",
      reason: "bad_credentials",
      ip: ip,
      login_digest: digest
    })

    login = Throttle.fail({:login, digest}, @login_limit, @window_s)
    address = Throttle.fail({:ip, ip}, @ip_limit, @window_s)

    for {scope, {:locked, until}} <- [login: login, ip: address] do
      App.EventLog.emit("hrda.auth.sign_in.locked", %{
        scope: to_string(scope),
        ip: ip,
        login_digest: digest,
        until: DateTime.to_iso8601(until)
      })
    end

    if login != :ok or address != :ok do
      locked(conn)
    else
      conn
      |> put_flash(:error, gettext("Wrong PersonID or password."))
      |> redirect(to: ~p"/sign-in/person")
    end
  end

  # The set-password link: expired, used already, or the password refused.
  def failure(conn, {:password, :reset}, _reason) do
    App.EventLog.emit("hrda.auth.sign_in.failed", %{
      method: "person_id",
      reason: "bad_link",
      ip: AppWeb.ClientIp.of(conn)
    })

    conn
    |> put_flash(
      :error,
      gettext("The link has expired or was used already. Ask for a new one.")
    )
    |> redirect(to: ~p"/sign-in/person/request")
  end

  def failure(conn, activity, _reason) do
    App.EventLog.emit("hrda.auth.sign_in.failed", %{
      method: method(activity),
      reason: "provider_error",
      ip: AppWeb.ClientIp.of(conn)
    })

    conn
    |> put_flash(:error, gettext("Sign-in failed. Please try again."))
    |> redirect(to: ~p"/sign-in")
  end

  def sign_out(conn, _params) do
    return_to = get_session(conn, :return_to) || ~p"/"

    if user = conn.assigns[:current_user] do
      App.EventLog.emit("hrda.auth.session.ended", %{ip: AppWeb.ClientIp.of(conn)},
        actor: user,
        subject: "user/#{user.id}"
      )
    end

    conn
    |> clear_session(:app)
    |> put_flash(:info, gettext("You are now signed out"))
    |> redirect(to: return_to)
  end

  defp locked(conn) do
    conn
    |> put_flash(
      :error,
      gettext("Too many failed attempts. Try again in 15 minutes.")
    )
    |> redirect(to: ~p"/sign-in/person")
  end

  # The attempted PersonID, as its digest (never stored as typed).
  defp login_digest(conn) do
    conn.params
    |> get_in(["user", "login_id"])
    |> PersonLogin.normalize()
    |> Digest.digest()
  end

  # The sign-in method in access events: Google, or PersonID + password.
  defp method({:password, _phase}), do: "person_id"
  defp method({strategy, _phase}), do: to_string(strategy)
  defp method(_activity), do: "unknown"
end
