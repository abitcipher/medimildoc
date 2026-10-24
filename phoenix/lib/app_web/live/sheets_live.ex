defmodule AppWeb.SheetsLive do
  @moduledoc """
  Mounted inside the Apps Script sidebar `<iframe>`
  (`apps_script/src/sidebar.html`).

  - M1: the browser side holds the LiveSocket
    connect until it has received `{spreadsheetId, sheetName, a1, email,
    token, googleAccessToken}` from the parent sidebar via postMessage
    (`assets/js/sheets_bridge.js`), then supplies `token` as the
    `sheets_token` connect param. `mount/3` verifies it here — not in a
    Plug — since connect_params don't exist before the socket connects.
  - M2: once authenticated, reads a default
    range via `App.Google.Sheets` using the forwarded `google_access_token`
    (the user's own OAuth token — never verified by us, only by Google when
    we use it) and subscribes to `App.Sheets` edit notifications for this
    spreadsheet, so the shim's onEdit webhook can nudge a live re-fetch.
  - SHEETS-UI (docs/design/sheets-ui.md): the Data tab
    (`AppWeb.SheetsDataComponent`) writes assignments, people or a record
    kind into a tab laid out like the app's form and checks the edited tab
    back; the selected row opens as the app's form
    (`AppWeb.SheetsSelectionComponent`). Sheets stays a view, never the
    source of truth : nothing is written to the app before a
    preview is confirmed, and everything goes through the resources'
    actions and policies. (It replaced the first "People roster" of
     which imported without a preview.)

  Only `sub` (email) and `ssid` (spreadsheet id) inside `sheets_token` are
  cryptographically covered by its signature — that's the entire
  authorization boundary. `sheet_name`/`a1` ride unsigned and are
  informational only (which range to display by default), never used for
  authorization.

  `sheets_token`'s `sub` is *not* itself an Ash actor — it's just an email
  claim from `Session.getActiveUser()` inside the Apps Script sandbox
  's own moduledoc note). To do anything against `App.People`
  (which needs a real `App.Accounts.User` with a `:role` for its policies), 
  that email is looked up against `App.Accounts.User`
  (`@actor` below) — found only if this same Google account has already
  signed into the standalone forms UI at least once (that's the only path
  that actually provisions a `User` row, via `register_with_google`'s real
  OAuth callback — this module deliberately does not auto-provision one
  itself, matching 's "no auto-promote/auto-create user
  heuristic" stance). Until then, the Data tab stays empty with an
  explanatory message; the range demo above is unaffected either way,
  since it never touches Ash at all.
  """
  use AppWeb, :live_view

  require Ash.Query

  # Same locale handling as the main app's live sessions: /sheets is not in
  # one (no user session), so the hook is declared here.
  on_mount {AppWeb.LocaleHook, :default}

  @default_range_a1 "A1:E20"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        ticks: 0,
        auth: :pending,
        range: nil,
        range_error: nil,
        actor: nil,
        visible: MapSet.new()
      )

    socket =
      if connected?(socket) do
        :timer.send_interval(1000, self(), :tick)
        socket |> assign(:auth, authenticate(socket)) |> after_authenticate()
      else
        socket
      end

    {:ok, socket}
  end

  defp authenticate(socket) do
    case {fetch_connect_param(socket, "sheets_token"),
          fetch_connect_param(socket, "sheets_error")} do
      {token, _} when is_binary(token) -> App.SheetsToken.verify(token, shared_secret())
      {nil, "timeout"} -> {:error, :no_answer}
      {nil, message} when is_binary(message) -> {:error, sidebar_error(message)}
      {nil, nil} -> {:error, :missing_token}
    end
  end

  # Google's own error when the browser is signed in to several Google
  # accounts and the spreadsheet isn't open under the first one: the
  # sidebar's google.script.run calls go out as the first account, and
  # nothing in the script can route them. The text is
  # translated by Google; the code in it isn't.
  defp sidebar_error(message) do
    if String.contains?(message, "PERMISSION_DENIED"),
      do: :multiple_accounts,
      else: {:sidebar_error, message}
  end

  # connect_params don't change across `assign/3` calls, so it's safe to
  # keep reading them off `socket` after the auth assign above.
  defp after_authenticate(%{assigns: %{auth: {:ok, claims}}} = socket) do
    App.Sheets.subscribe(claims.spreadsheet_id)

    socket
    |> assign(:google_access_token, fetch_connect_param(socket, "google_access_token"))
    |> assign(:sheet_name, fetch_connect_param(socket, "sheet_name"))
    |> assign(:actor, find_actor(claims.sub))
    |> then(&assign(&1, :visible, AppWeb.SidebarLayout.visible(&1.assigns.actor)))
    |> fetch_range()
  end

  defp after_authenticate(socket), do: socket

  # see this module's own moduledoc for why this reads
  # rather than provisions: `authorize?: false` is deliberate here, not an
  # oversight — there is no actor yet to authorize this lookup against,
  # the same bootstrapping situation `AppWeb.LiveUserAuth`'s own
  # session/JWT resolution is in. It never returns more than the one row
  # matching this cryptographically-verified email.
  defp find_actor(email) do
    App.Accounts.User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, user} -> user
      {:error, _} -> nil
    end
  end

  defp fetch_connect_param(socket, key) do
    case get_connect_params(socket) do
      %{^key => value} when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp fetch_range(%{assigns: %{google_access_token: nil}} = socket) do
    assign(socket, range_error: :missing_google_access_token)
  end

  defp fetch_range(socket) do
    %{auth: {:ok, claims}, google_access_token: token, sheet_name: sheet_name} = socket.assigns
    range = a1_range(sheet_name, @default_range_a1)

    case App.Google.Sheets.get_values(token, claims.spreadsheet_id, range) do
      {:ok, rows} -> assign(socket, range: rows, range_error: nil)
      {:error, reason} -> assign(socket, range: nil, range_error: reason)
    end
  end

  defp a1_range(nil, cell), do: cell
  defp a1_range(sheet_name, cell), do: "#{sheet_name}!#{cell}"

  defp shared_secret, do: Application.fetch_env!(:app, :sheets_shared_secret)

  @impl true
  def handle_info(:tick, socket) do
    {:noreply, update(socket, :ticks, &(&1 + 1))}
  end

  # Best-effort nudge — re-fetch the same default range, and
  # read the selected row again if the edit touched it (SHEETS-UI.20; a
  # hint only: onEdit isn't guaranteed, the polling stays). Over-fetching
  # here is harmless, just wasted API calls.
  def handle_info({:sheets_edit, attrs}, socket) do
    if socket.assigns.actor,
      do: send_update(AppWeb.SheetsSelectionComponent, id: "sheets-selection", edited: attrs)

    {:noreply, fetch_range(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, fetch_range(socket)}
  end

  def handle_event("save_cell", %{"value" => value}, socket) do
    %{auth: {:ok, claims}, google_access_token: token, sheet_name: sheet_name} = socket.assigns
    range = a1_range(sheet_name, "A1")

    socket =
      case App.Google.Sheets.update_values(token, claims.spreadsheet_id, range, [[value]]) do
        {:ok, _} -> fetch_range(socket)
        {:error, reason} -> assign(socket, :range_error, reason)
      end

    {:noreply, socket}
  end

  # tab switch is pure client-side Phoenix.LiveView.JS:
  # hide every panel and every tab's tool icons, show the chosen ones, move
  # `tab-active`/`aria-selected`. Plain Tailwind `hidden` add/remove, not
  # `JS.show`/`JS.hide` (those act only on elements whose current size is
  # zero/nonzero, which made them silently no-op here, confirmed live).
  # Targets of hidden tabs simply don't exist; JS commands skip them.
  @tabs ~w(sheet data)

  defp select_tab(tab) do
    js =
      Enum.reduce(@tabs, %JS{}, fn other, js ->
        js
        |> JS.add_class("hidden", to: "#panel-#{dom(other)}")
        |> JS.add_class("hidden", to: "#tools-#{other}")
        |> JS.remove_class("tab-active", to: "#tab-#{dom(other)}")
        |> JS.set_attribute({"aria-selected", "false"}, to: "#tab-#{dom(other)}")
      end)

    js
    |> JS.remove_class("hidden", to: "#panel-#{dom(tab)}")
    |> JS.remove_class("hidden", to: "#tools-#{tab}")
    |> JS.add_class("tab-active", to: "#tab-#{dom(tab)}")
    |> JS.set_attribute({"aria-selected", "true"}, to: "#tab-#{dom(tab)}")
  end

  defp dom(tab), do: tab

  # A tool icon's click: its event, and the component it goes to.
  defp tool_click("sheet.refresh"), do: JS.push("refresh")
  defp tool_click("data.export"), do: JS.push("export", target: "#sheets-data")
  defp tool_click("data.check"), do: JS.push("import", target: "#sheets-data")
  defp tool_click("data.new"), do: JS.push("new", target: "#sheets-data")

  defp tool_click("data.find"),
    do: JS.toggle_class("hidden", to: "#find-box") |> JS.focus(to: "#find-input")

  defp close_menu(js \\ %JS{}), do: JS.add_class(js, "hidden", to: "#sidebar-menu-menu")

  # Help on the sheet format, opened from the menu.
  defp toggle_help, do: JS.toggle_class("hidden", to: "#help-data")

  @impl true
  def render(assigns) do
    tabs =
      if match?({:ok, _}, assigns.auth), do: AppWeb.SidebarLayout.tabs(assigns.visible), else: []

    assigns =
      assign(assigns,
        tabs: tabs,
        first: tabs |> List.first() |> then(&(&1 && &1.id))
      )

    ~H"""
    <%!-- SHEETS-UI.6: compact for the ~300 px sidebar — smaller fields
    (daisyUI sizes them from --size-field) and tighter spacing; the theme
    follows the system unless the user picks one. --%>
    <div class="min-h-screen bg-base-100 text-sm text-base-content [--size-field:0.1875rem] [--size-selector:0.1875rem]">
      <header class="sticky top-0 z-10 flex items-center gap-1 border-b border-base-300 bg-base-100 px-2 py-1.5">
        <span
          class={[
            "tooltip tooltip-right mx-1 size-2.5 shrink-0 rounded-full",
            if(connected?(@socket), do: "bg-success", else: "bg-base-300")
          ]}
          data-tip={
            if connected?(@socket),
              do: gettext("Connected for %{seconds} s", seconds: @ticks),
              else: gettext("Connecting…")
          }
          aria-label={gettext("Connection status")}
        />
        <%!-- Opens to the right of the button: the shared Floating menu
        centres itself and ran past the ~285 px sidebar's edge (seen live).
        Toggled by JS commands, which survive the header's re-render every
        second (the connection timer). --%>
        <%!-- Click-away on the wrapper: a click on the button isn't "away". --%>
        <div
          :if={match?({:ok, _}, @auth)}
          id="sidebar-menu"
          phx-click-away={close_menu()}
          class="relative"
        >
          <button
            type="button"
            id="sidebar-menu-button"
            phx-click={JS.toggle_class("hidden", to: "#sidebar-menu-menu")}
            class="btn btn-ghost btn-circle btn-sm size-9 min-h-9"
            aria-label={gettext("Menu")}
            title={gettext("Menu")}
            aria-haspopup="menu"
            aria-controls="sidebar-menu-menu"
          >
            <.icon name="hero-bars-3" class="size-5" />
          </button>
          <div
            id="sidebar-menu-menu"
            role="menu"
            class="absolute top-full left-0 z-50 mt-1 hidden w-56 max-w-[calc(100vw-2.5rem)] rounded-box border border-base-300 bg-base-100 p-1 text-base-content shadow-lg"
          >
            <div class="flex flex-col gap-0.5 px-3 py-2 text-xs">
              <span class="truncate font-medium">{elem(@auth, 1).sub}</span>
              <span class="truncate opacity-60">
                {gettext("Spreadsheet %{id}", id: elem(@auth, 1).spreadsheet_id)}
              </span>
            </div>
            <div class="my-1 border-t border-base-300"></div>
            <button
              :if={MapSet.member?(@visible, "data")}
              type="button"
              role="menuitem"
              id="menu-help-data"
              phx-click={toggle_help() |> close_menu()}
              class="menu-row w-full"
            >
              <.icon name="hero-question-mark-circle" class="size-4 shrink-0 opacity-70" />
              <span class="grow text-left">{gettext("Sheet format")}</span>
            </button>
            <a
              :if={@actor && AppWeb.Authz.can?(@actor, "settings.manage")}
              href={~p"/sidebar-layout"}
              target="_blank"
              rel="noopener"
              role="menuitem"
              class="menu-row"
            >
              <.icon name="hero-adjustments-horizontal" class="size-4 shrink-0 opacity-70" />
              <span class="grow">{gettext("Sidebar layout")}</span>
            </a>
            <a
              href={~p"/"}
              phx-click={close_menu()}
              target="_blank"
              rel="noopener"
              role="menuitem"
              class="menu-row"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-4 shrink-0 opacity-70" />
              <span class="grow">{gettext("Open the app")}</span>
            </a>
            <%!-- Theme and language: always last, under a slim line, as
            rows of smaller buttons that wrap in a narrow menu. --%>
            <div class="mt-1 flex flex-col gap-1 border-t border-base-300 px-2 pt-2 pb-1">
              <AppWeb.HeaderControls.theme_row />
              <AppWeb.HeaderControls.language_row />
            </div>
          </div>
        </div>

        <div class="flex min-w-0 grow items-center gap-0.5">
          <div
            :for={tab <- @tabs}
            id={"tools-#{tab.id}"}
            class={["flex items-center gap-0.5", tab.id != @first && "hidden"]}
          >
            <button
              :for={tool <- AppWeb.SidebarLayout.tools(@visible, tab.id)}
              type="button"
              id={"tool-#{tool.id}"}
              phx-click={tool_click(tool.id)}
              class="btn btn-ghost btn-sm btn-square"
              aria-label={tool.label}
              title={tool.label}
              data-float-tip={tool.label}
            >
              <.icon name={tool.icon} class="size-5" />
            </button>
          </div>
        </div>

        <span
          :if={match?({:ok, _}, @auth)}
          class="tooltip tooltip-left"
          data-tip={
            gettext("%{email} · spreadsheet %{id}",
              email: elem(@auth, 1).sub,
              id: elem(@auth, 1).spreadsheet_id
            )
          }
        >
          <span class={[
            "inline-flex size-8 items-center justify-center rounded-full text-sm font-medium text-white",
            AppWeb.HeaderControls.avatar_color(%{email: elem(@auth, 1).sub})
          ]}>
            {AppWeb.HeaderControls.initials(%{email: elem(@auth, 1).sub})}
          </span>
        </span>
      </header>

      <main class="flex flex-col gap-2 p-2">
        <div :if={@auth == :pending} class="flex items-center gap-2 opacity-80">
          <span class="loading loading-spinner loading-sm" aria-hidden="true" />
          {gettext("Waiting for Sheets context…")}
        </div>

        <div :if={match?({:error, _}, @auth)} role="alert" class="alert alert-error alert-soft">
          <.icon name="hero-exclamation-circle" class="size-5" />
          <div>
            <p>{auth_error_message(elem(@auth, 1))}</p>
            <p class="text-xs opacity-70">
              {gettext("Code: %{code}", code: error_code(elem(@auth, 1)))}
            </p>
            <%!-- A full page load asks the sidebar for a new context. --%>
            <a href={~p"/sheets"} class="btn btn-sm mt-2">
              <.icon name="hero-arrow-path" class="size-4" /> {gettext("Try again")}
            </a>
          </div>
        </div>

        <div :if={match?({:ok, _}, @auth)} class="flex flex-col gap-2">
          <div
            :if={is_nil(@actor)}
            role="alert"
            class="alert alert-warning alert-soft text-xs"
          >
            <.icon name="hero-information-circle" class="size-4" />
            {gettext(
              "No account matches %{email} in the main app yet. Sign in there first with the same Google account to use the People tools.",
              email: elem(@auth, 1).sub
            )}
          </div>

          <%!-- Sheet format help, opened from the menu. --%>
          <div
            :if={MapSet.member?(@visible, "data")}
            id="help-data"
            class="hidden rounded-box border border-base-300 p-3 text-xs"
          >
            <div class="mb-1 flex items-center justify-between gap-2">
              <span class="font-medium">{gettext("Sheet format")}</span>
              <button
                type="button"
                phx-click={toggle_help()}
                class="btn btn-ghost btn-xs btn-square"
                aria-label={gettext("Close")}
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
            <p class="opacity-80">{help_text()}</p>
          </div>

          <%!-- tabs switch client-side (JS commands). The
          sidebar is phone-width or narrower, so the tab list scrolls rather
          than wraps. One tab: no tab list. --%>
          <div
            :if={length(@tabs) > 1}
            role="tablist"
            class="tabs tabs-box w-full flex-nowrap overflow-x-auto"
          >
            <button
              :for={tab <- @tabs}
              type="button"
              id={"tab-#{dom(tab.id)}"}
              role="tab"
              aria-selected={to_string(tab.id == @first)}
              aria-controls={"panel-#{dom(tab.id)}"}
              phx-click={select_tab(tab.id)}
              class={["tab gap-1 whitespace-nowrap", tab.id == @first && "tab-active"]}
            >
              <.icon name={tab.icon} class="size-4" />
              {tab.label}
            </button>
          </div>

          <section
            :if={MapSet.member?(@visible, "sheet")}
            id="panel-sheet"
            role="tabpanel"
            aria-labelledby="tab-sheet"
            class={["flex-col gap-2 [&:not(.hidden)]:flex", @first != "sheet" && "hidden"]}
          >
            <div :if={@range_error} role="alert" class="alert alert-error alert-soft text-xs">
              <.icon name="hero-exclamation-circle" class="size-4" />
              {gettext("Sheets error: %{reason}", reason: inspect(@range_error))}
            </div>

            <div :if={@range} class="overflow-x-auto rounded-box border border-base-300">
              <table class="table table-xs table-zebra">
                <tbody>
                  <tr :for={row <- @range}>
                    <td :for={cell <- row}>{cell}</td>
                  </tr>
                </tbody>
              </table>
            </div>

            <form
              :if={MapSet.member?(@visible, "sheet.cell_editor")}
              phx-submit="save_cell"
              class="flex gap-2"
            >
              <label class="sr-only" for="cell-value">{gettext("New value for A1")}</label>
              <input
                id="cell-value"
                type="text"
                name="value"
                placeholder={gettext("New value for A1")}
                class="input input-sm w-full"
              />
              <button type="submit" class="btn btn-primary btn-sm">
                <.icon name="hero-check" class="size-4" />
                {gettext("Save to A1")}
              </button>
            </form>
          </section>

          <section
            :if={MapSet.member?(@visible, "data")}
            id="panel-data"
            role="tabpanel"
            aria-labelledby="tab-data"
            class={["flex-col gap-2 [&:not(.hidden)]:flex", @first != "data" && "hidden"]}
          >
            <.live_component
              :if={@actor}
              module={AppWeb.SheetsDataComponent}
              id="sheets-data"
              actor={@actor}
              can_write={AppWeb.Authz.can?(@actor, "people.write")}
              steps?={MapSet.member?(@visible, "data.steps")}
              token={@google_access_token}
              spreadsheet_id={elem(@auth, 1).spreadsheet_id}
            />
            <.live_component
              :if={@actor && MapSet.member?(@visible, "data.row_form")}
              module={AppWeb.SheetsSelectionComponent}
              id="sheets-selection"
              actor={@actor}
              can_write={AppWeb.Authz.can?(@actor, "people.write")}
              token={@google_access_token}
              spreadsheet_id={elem(@auth, 1).spreadsheet_id}
            />
          </section>
        </div>
      </main>
    </div>
    """
  end

  defp help_text,
    do:
      gettext(
        "The app writes each kind of data into its own tab, laid out like the app's form: row 2 holds the field names (hover for help), grey columns are read-only, a changed cell turns amber and an emptied one red, and a required field left empty turns red. Choose from the lists, tick the boxes, double-click a date for a calendar. Add a row for a new person or record (a new record needs the person's PersonID). Check writes each row's finding into the Status column; nothing reaches the app until you carry it out. On the Assignments tab an empty post ends the assignment, and changes become draft orders."
      )

  # What to do about an authentication failure, in the user's words. The
  # code stays visible in small print for support.
  defp auth_error_message(:missing_token),
    do:
      gettext("Google Sheets did not pass a sign-in token. Close the sidebar and open it again.")

  defp auth_error_message(:multiple_accounts),
    do:
      gettext(
        "Google could not run the script for this account. This happens when the browser is signed in to several Google accounts and this spreadsheet is not open under the first one. Open it in a window where only this account is signed in (a separate Chrome profile or an incognito window), or sign in to this account first."
      )

  defp auth_error_message(:no_answer),
    do:
      gettext(
        "Google Sheets did not answer in time. Close the sidebar and open it again; if it keeps happening, check the script's executions in the Apps Script editor."
      )

  # The shim's own error text (English, from Apps Script), e.g. a missing
  # SHARED_SECRET script property: shown so whoever set up the script can
  # fix it.
  defp auth_error_message({:sidebar_error, message}),
    do:
      gettext(
        "The Apps Script of this spreadsheet failed: %{message}. Check its setup (apps_script/README.md).",
        message: message
      )

  defp auth_error_message(:expired),
    do: gettext("The sidebar session expired. Close the sidebar and open it again.")

  defp auth_error_message(_reason),
    do: gettext("The sidebar could not be verified. Close it and open it again.")

  # The code in small print: the reason without the message text.
  defp error_code({:sidebar_error, _message}), do: :sidebar_error
  defp error_code(reason), do: reason
end
