defmodule AppWeb.MyDataLive do
  @moduledoc """
  `/me` — what the system holds about the signed-in person
  (docs/design/events-and-person-login.md): their person, current post
  and every record, read as their own (`AppWeb.MyData`), and downloads as
  PDF, Markdown or JSON.

  Downloading needs a fresh confirmation: the password (an account with
  one) or a sign-in within the last five minutes (also the way for a
  Google-only account). Five wrong passwords in 15 minutes stop
  confirming for 15 minutes. Once confirmed, the links carry a signed
  token valid for five minutes (`AppWeb.MyDataController`).
  """
  use AppWeb, :live_view

  alias App.Accounts.Throttle
  alias AppWeb.MyData

  @fresh_s 300

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user
    person = MyData.person(user)
    signed_in_at = session["signed_in_at"]

    confirmed_until =
      if is_integer(signed_in_at) and System.system_time(:second) - signed_in_at < @fresh_s,
        do: signed_in_at + @fresh_s

    {:ok,
     socket
     |> assign(:page_title, gettext("My data"))
     |> assign(:person, person)
     |> assign(:rows, if(person && connected?(socket), do: MyData.rows(user, person), else: []))
     |> assign(:password?, not is_nil(user.hashed_password))
     |> assign(:confirm_error, nil)
     |> confirmed(confirmed_until)}
  end

  defp confirmed(socket, nil), do: assign(socket, confirmed_until: nil, links: %{})

  defp confirmed(socket, until) do
    user = socket.assigns.current_user

    links =
      Map.new(MyData.formats(), fn format ->
        token = Phoenix.Token.sign(AppWeb.Endpoint, "my-data", {user.id, format})
        {format, ~p"/me/export/#{format}?#{[token: token]}"}
      end)

    assign(socket, confirmed_until: until, links: links)
  end

  @impl true
  def handle_event("confirm", %{"password" => password}, socket) do
    user = socket.assigns.current_user

    cond do
      Throttle.locked_until({:confirm, user.id}) ->
        {:noreply, assign(socket, :confirm_error, gettext("Too many attempts. Try later."))}

      AshAuthentication.BcryptProvider.valid?(password, user.hashed_password) ->
        App.EventLog.emit(
          "hrda.auth.confirmation.succeeded",
          %{method: "password", purpose: "export"},
          actor: user,
          subject: "user/#{user.id}"
        )

        {:noreply,
         socket
         |> assign(:confirm_error, nil)
         |> confirmed(System.system_time(:second) + @fresh_s)}

      true ->
        App.EventLog.emit(
          "hrda.auth.confirmation.failed",
          %{method: "password", purpose: "export"},
          actor: user,
          subject: "user/#{user.id}"
        )

        Throttle.fail({:confirm, user.id}, 5, 900)
        {:noreply, assign(socket, :confirm_error, gettext("Wrong password."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-3xl flex-col gap-4 p-4">
        <h1 class="flex items-center gap-2 text-xl font-semibold">
          {gettext("My data")}
          <.field_description description={
            gettext(
              "Everything the system holds about you: your details, posts and records of every kind. Opening sensitive records here is in the access log, as anywhere. Downloads need a fresh confirmation."
            )
          } />
        </h1>

        <p :if={is_nil(@person)} id="not-linked" class="text-sm">
          {gettext("Your account is not linked to a person.")}
        </p>

        <section :if={@person} id="my-data-download" class="flex flex-col gap-2">
          <h2 class="font-semibold">{gettext("Download")}</h2>
          <div :if={@confirmed_until} id="download-links" class="flex flex-wrap items-center gap-2">
            <a
              :for={format <- MyData.formats()}
              href={@links[format]}
              id={"download-#{format}"}
              class="btn btn-sm"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" />
              {format_label(format)}
            </a>
            <span class="text-xs opacity-70">
              {gettext("The links work for five minutes.")}
            </span>
          </div>
          <form
            :if={is_nil(@confirmed_until) and @password?}
            id="confirm-form"
            phx-submit="confirm"
            class="flex flex-wrap items-end gap-2"
          >
            <label class="flex flex-col gap-1 text-sm">
              <span>{gettext("Confirm with your password")}</span>
              <input
                type="password"
                name="password"
                id="confirm-password"
                required
                autocomplete="current-password"
                class="input input-sm w-64"
              />
            </label>
            <button type="submit" class="btn btn-sm btn-primary">{gettext("Confirm")}</button>
            <span :if={@confirm_error} class="text-sm text-error">{@confirm_error}</span>
          </form>
          <div :if={is_nil(@confirmed_until) and not @password?} class="text-sm">
            <a href={~p"/me/confirm-google"} id="confirm-google" class="btn btn-sm">
              {gettext("Confirm by signing in with Google again")}
            </a>
          </div>
        </section>

        <section :if={@person} id="my-data-card" class="flex flex-col gap-1 text-sm">
          <.row :for={row <- @rows} row={row} />
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :row, :any, required: true

  defp row(%{row: {:title, _, _}} = assigns) do
    ~H"""
    <h2 class="text-lg font-semibold">{elem(@row, 1)}</h2>
    """
  end

  defp row(%{row: {:subtitle, _, _}} = assigns) do
    ~H"""
    <p class="opacity-70">{elem(@row, 1)} — {elem(@row, 2)}</p>
    """
  end

  defp row(%{row: {:section, _, _}} = assigns) do
    ~H"""
    <h3 class="mt-3 rounded bg-base-200 px-2 py-1 font-semibold">{elem(@row, 1)}</h3>
    """
  end

  defp row(%{row: {:record, _, _}} = assigns) do
    ~H"""
    <p class="mt-1 text-xs font-semibold opacity-70">{elem(@row, 1)}</p>
    """
  end

  defp row(%{row: {:field, _, _}} = assigns) do
    ~H"""
    <div class="grid grid-cols-[minmax(8rem,14rem)_1fr] gap-2">
      <span class="opacity-70">{elem(@row, 1)}</span><span>{elem(@row, 2)}</span>
    </div>
    """
  end

  defp row(assigns), do: ~H""

  defp format_label("pdf"), do: "PDF"
  defp format_label("markdown"), do: "Markdown"
  defp format_label("json"), do: "JSON"
end
