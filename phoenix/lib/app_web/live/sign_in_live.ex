defmodule AppWeb.SignInLive do
  @moduledoc """
  Signing in (docs/design/events-and-person-login.md), in place of
  AshAuthentication's generated page:

  - `:sign_in` (`/sign-in`) — Google, and PersonID + password;
  - `:person` (`/sign-in/person`) — PersonID + password only;
  - `:request` (`/sign-in/person/request`) — first sign-in or a forgotten
    password: a PersonID, always the same answer (`App.Accounts.PersonLogin`);
  - `:password` (`/sign-in/person/password?token=…`) — the e-mailed
    link: the new password twice, which signs the person in.

  The password inputs are `phx-update="ignore"`: a re-render (the
  checks appearing) would otherwise empty what was typed.

  The password forms post to the strategy's routes
  (`/auth/user/password/sign_in`, `/auth/user/password/reset`); their
  outcome — events, lockout, the session — is `AppWeb.AuthController`.
  The PersonID parts are hidden while `auth.person_login` is off.
  """
  use AppWeb, :live_view

  alias App.Accounts.PersonLogin

  @min_length 12

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:person_login?, App.Settings.get("auth.person_login") == true)
     |> assign(:ip, if(connected?(socket), do: AppWeb.ClientIp.of_socket(socket)))
     |> assign(:requested?, false)
     |> assign(:trigger?, false)
     |> assign(:errors, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    title =
      case socket.assigns.live_action do
        :request -> gettext("Set or reset password")
        :password -> gettext("Set your password")
        _ -> gettext("Sign in")
      end

    {:noreply,
     socket
     |> assign(:page_title, title)
     |> assign(:token, params["token"])
     |> assign(
       :password_form,
       to_form(%{"password" => "", "password_confirmation" => ""}, as: :user)
     )}
  end

  @impl true
  def handle_event("request", %{"login_id" => login_id}, socket) do
    if socket.assigns.person_login?,
      do: PersonLogin.request(login_id, socket.assigns.ip || "unknown")

    {:noreply, assign(socket, :requested?, true)}
  end

  def handle_event("check_password", %{"user" => params}, socket),
    do: {:noreply, assign(socket, :errors, password_errors(params))}

  # Checked here first, so the strategy refuses only a bad link.
  def handle_event("set_password", %{"user" => params}, socket) do
    case password_errors(params) do
      [] -> {:noreply, assign(socket, trigger?: true, errors: [])}
      errors -> {:noreply, assign(socket, :errors, errors)}
    end
  end

  defp password_errors(%{"password" => password, "password_confirmation" => again}) do
    Enum.reject(
      [
        String.length(password) < @min_length &&
          gettext("At least %{count} characters.", count: @min_length),
        (again != "" and again != password) && gettext("The two passwords differ.")
      ],
      &(&1 in [false, nil])
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="flex min-h-dvh items-center justify-center bg-base-200 p-4">
      <Layouts.flash_group flash={@flash} />
      <div class="w-full max-w-sm rounded-box border border-base-300 bg-base-100 p-6 shadow-sm">
        <h1 class="mb-4 text-xl font-semibold">{@page_title}</h1>
        {render_action(assigns)}
      </div>
    </main>
    """
  end

  defp render_action(%{live_action: :request} = assigns) do
    ~H"""
    <div :if={not @person_login?} id="person-login-off" class="text-sm">
      {gettext("Signing in with a PersonID is switched off.")}
    </div>
    <div :if={@person_login? and @requested?} id="request-sent" class="flex flex-col gap-3 text-sm">
      <p>
        {gettext(
          "If this PersonID can sign in, a link to set the password was sent to the contact address on its record. The link works once, for 30 minutes."
        )}
      </p>
      <.link navigate={~p"/sign-in/person"} class="link">{gettext("Back to sign-in")}</.link>
    </div>
    <form
      :if={@person_login? and not @requested?}
      id="request-form"
      phx-submit="request"
      class="flex flex-col gap-3"
    >
      <p class="text-sm opacity-80">
        {gettext(
          "For the first sign-in, or if you forgot the password: a link to set it goes to the e-mail address on your contact record."
        )}
      </p>
      <label class="flex flex-col gap-1 text-sm">
        <span>{gettext("PersonID")}</span>
        <input
          type="text"
          name="login_id"
          id="request-login-id"
          required
          autocomplete="username"
          autocapitalize="characters"
          class="input w-full font-mono"
        />
      </label>
      <button type="submit" class="btn btn-primary">{gettext("Send the link")}</button>
      <.link navigate={~p"/sign-in/person"} class="link text-sm">{gettext("Back to sign-in")}</.link>
    </form>
    """
  end

  defp render_action(%{live_action: :password} = assigns) do
    ~H"""
    <.form
      for={@password_form}
      id="set-password-form"
      action={~p"/auth/user/password/reset"}
      method="post"
      phx-change="check_password"
      phx-submit="set_password"
      phx-trigger-action={@trigger?}
      class="flex flex-col gap-3"
    >
      <input type="hidden" name="user[reset_token]" value={@token} />
      <label class="flex flex-col gap-1 text-sm">
        <span>{gettext("New password")}</span>
        <input
          type="password"
          name="user[password]"
          id="set-password"
          phx-update="ignore"
          required
          minlength="12"
          autocomplete="new-password"
          class="input w-full"
        />
      </label>
      <label class="flex flex-col gap-1 text-sm">
        <span>{gettext("The same password again")}</span>
        <input
          type="password"
          name="user[password_confirmation]"
          id="set-password-again"
          phx-update="ignore"
          required
          autocomplete="new-password"
          class="input w-full"
        />
      </label>
      <ul :if={@errors != []} id="password-errors" class="text-sm text-error">
        <li :for={error <- @errors}>{error}</li>
      </ul>
      <button type="submit" class="btn btn-primary">{gettext("Set password and sign in")}</button>
    </.form>
    """
  end

  defp render_action(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <a
        :if={@live_action == :sign_in}
        href={~p"/auth/user/google"}
        id="sign-in-google"
        class="btn w-full"
      >
        <.icon name="hero-globe-alt" class="size-5" />
        {gettext("Sign in with Google")}
      </a>
      <div :if={@live_action == :sign_in and @person_login?} class="divider my-0 text-xs opacity-70">
        {gettext("or")}
      </div>
      <.form
        :if={@person_login?}
        for={%{}}
        as={:user}
        id="person-sign-in-form"
        action={~p"/auth/user/password/sign_in"}
        method="post"
        class="flex flex-col gap-3"
      >
        <label class="flex flex-col gap-1 text-sm">
          <span>{gettext("PersonID")}</span>
          <input
            type="text"
            name="user[login_id]"
            id="sign-in-login-id"
            required
            autocomplete="username"
            autocapitalize="characters"
            class="input w-full font-mono"
          />
        </label>
        <label class="flex flex-col gap-1 text-sm">
          <span>{gettext("Password")}</span>
          <input
            type="password"
            name="user[password]"
            id="sign-in-password"
            required
            autocomplete="current-password"
            class="input w-full"
          />
        </label>
        <button type="submit" class="btn btn-primary">{gettext("Sign in with PersonID")}</button>
        <.link navigate={~p"/sign-in/person/request"} id="request-link" class="link text-sm">
          {gettext("First sign-in or forgot the password?")}
        </.link>
      </.form>
      <.link
        :if={@live_action == :person}
        navigate={~p"/sign-in"}
        class="link text-sm"
      >
        {gettext("Other ways to sign in")}
      </.link>
    </div>
    """
  end
end
