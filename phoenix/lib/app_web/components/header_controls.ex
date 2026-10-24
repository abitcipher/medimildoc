defmodule AppWeb.HeaderControls do
  @moduledoc """
  The top-right controls, one icon slot each, in the style of Google's
  apps: language, colour theme and account. Each is a round icon button
  that opens a small menu (`header_menu/1`) built on the Mishka `Floating`
  hook, which already handles outside clicks, Escape (focus returns to the
  button), arrow-key navigation between `role="menuitem"` entries and
  `aria-expanded`.

  - **Language** — a globe icon; the menu lists languages by their own
    name, current one checked. Items are plain links (`?locale=`), so the
    change reloads the page and both `AppWeb.Plugs.SetLocale` and the
    LiveView locale hook pick it up.
  - **Theme** — the icon shows the current mode: sun, moon, or monitor for
    "device default". Switching is client-side (`phx:set-theme`, see
    `root.html.heex`); which icon and which check mark show is pure CSS on
    `<html data-theme data-theme-source>`, so it reacts instantly, with no
    server round trip.
  - **Account** — an avatar with the user's initials in a colour derived
    from their email; the menu is an account card with name, email, role
    and access profiles, and sign-out.

  Used by `AppWeb.Layouts.app/1` and the home page.
  """
  use Phoenix.Component
  use Gettext, backend: AppWeb.Gettext

  import AppWeb.CoreComponents, only: [icon: 1, role_label: 1, profile_label: 1, text_badge: 1]

  alias Phoenix.LiveView.JS

  # Languages by their own name, not translated: a user looking for their
  # language recognises it written in that language.
  @native_names %{"en" => "English", "uk" => "Українська", "fr" => "Français"}

  @avatar_colors ~w(bg-sky-700 bg-emerald-700 bg-violet-700 bg-rose-700
                    bg-amber-700 bg-teal-700 bg-indigo-700 bg-fuchsia-700)

  @doc """
  A round icon button that opens a menu. The trigger slot is the icon;
  the inner block is the menu body, whose actionable entries should carry
  `role="menuitem"` for keyboard navigation.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true, doc: "Accessible name and tooltip of the button"
  attr :menu_class, :any, default: "w-56"
  slot :trigger, required: true
  slot :inner_block, required: true

  def header_menu(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="Floating"
      data-floating-type="dropdown"
      data-clickable="true"
      data-position="bottom"
      data-smart-position="true"
      class="relative"
    >
      <button
        id={"#{@id}-button"}
        type="button"
        data-floating-trigger
        aria-label={@label}
        title={@label}
        aria-haspopup="menu"
        aria-expanded="false"
        aria-controls={"#{@id}-menu"}
        class="btn btn-ghost btn-circle btn-sm size-9 min-h-9"
      >
        {render_slot(@trigger)}
      </button>
      <div
        id={"#{@id}-menu"}
        data-floating-content
        role="menu"
        aria-labelledby={"#{@id}-button"}
        hidden
        class={[
          "dropdown-content absolute z-50 rounded-box border border-base-300 bg-base-100",
          "text-base-content shadow-lg p-1 transition-opacity",
          @menu_class
        ]}
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Global search (docs/design/search-timeline-notifications.md): magnifier
  icon, a field that opens the search page with the text.
  """
  attr :id, :string, default: "search-menu"

  def search_menu(assigns) do
    ~H"""
    <.header_menu id={@id} label={gettext("Search")} menu_class="w-72 p-2">
      <:trigger><.icon name="hero-magnifying-glass" class="size-5" /></:trigger>
      <form id="header-search" action="/search" method="get" role="search" class="flex gap-1">
        <input
          type="search"
          name="q"
          class="input input-sm grow"
          placeholder={gettext("Name, Person ID, document number…")}
          aria-label={gettext("Search")}
          autocomplete="off"
        />
        <button type="submit" class="btn btn-sm btn-primary" aria-label={gettext("Search")}>
          <.icon name="hero-arrow-right" class="size-4" />
        </button>
      </form>
    </.header_menu>
    """
  end

  @doc "Language picker: globe icon, menu of languages by their own name."
  attr :id, :string, default: "language-menu"

  def language_menu(assigns) do
    current = Gettext.get_locale(AppWeb.Gettext)

    assigns =
      assigns
      |> assign(:current, current)
      |> assign(:locales, Gettext.known_locales(AppWeb.Gettext))
      |> assign(:current_name, native_name(current))

    ~H"""
    <.header_menu id={@id} label={gettext("Language: %{language}", language: @current_name)}>
      <:trigger><.icon name="hero-language" class="size-5" /></:trigger>
      <a
        :for={locale <- @locales}
        href={"?locale=#{locale}"}
        role="menuitem"
        lang={locale}
        aria-current={locale == @current && "true"}
        class="menu-row"
      >
        <.icon
          name="hero-check"
          class={["size-4 shrink-0", locale != @current && "invisible"]}
        />
        <span class="grow">{native_name(locale)}</span>
        <span class="text-xs uppercase opacity-50">{locale}</span>
      </a>
    </.header_menu>
    """
  end

  @doc """
  Theme picker. The button's icon and the check marks follow
  `<html data-theme data-theme-source>` through CSS, so they update the
  moment the theme changes, in this tab or on load.
  """
  attr :id, :string, default: "theme-menu"

  def theme_menu(assigns) do
    ~H"""
    <.header_menu id={@id} label={gettext("Theme")} menu_class="w-52">
      <:trigger>
        <.icon name="hero-computer-desktop" class="size-5 hidden theme-shows-system" />
        <.icon name="hero-sun" class="size-5 hidden theme-shows-light" />
        <.icon name="hero-moon" class="size-5 hidden theme-shows-dark" />
        <.icon name="hero-moon-solid" class="size-5 hidden theme-shows-sheets-black" />
      </:trigger>
      <button
        :for={{theme, icon, label} <- theme_options()}
        type="button"
        role="menuitem"
        data-phx-theme={theme}
        phx-click={JS.dispatch("phx:set-theme") |> JS.dispatch("click", to: "##{@id}-button")}
        class="menu-row w-full"
      >
        <.icon name="hero-check" class={"size-4 shrink-0 invisible theme-checks-#{theme}"} />
        <.icon name={icon} class="size-4 shrink-0 opacity-70" />
        <span class="grow text-left">{label}</span>
      </button>
    </.header_menu>
    """
  end

  @doc """
  The theme as one row of small icon buttons with tooltips, for inside a
  menu (the Sheets sidebar's ☰). The current theme is marked through CSS
  (`.theme-pick-<theme>`, app.css), like the theme menu's checks.
  """
  attr :id, :string, default: "theme-row"

  def theme_row(assigns) do
    assigns = assign(assigns, :options, theme_options())

    ~H"""
    <div id={@id} role="group" aria-label={gettext("Theme")} class="flex flex-wrap gap-1">
      <button
        :for={{theme, icon, label} <- @options}
        type="button"
        data-phx-theme={theme}
        phx-click={JS.dispatch("phx:set-theme")}
        class={"theme-pick theme-pick-#{theme} btn btn-ghost btn-xs btn-square"}
        aria-label={label}
        title={label}
      >
        <.icon name={icon} class="size-3.5" />
      </button>
    </div>
    """
  end

  @doc """
  The languages as one row of small buttons (their codes; the language's
  own name as the tooltip), wrapping when the menu is narrow.
  """
  attr :id, :string, default: "language-row"

  def language_row(assigns) do
    current = Gettext.get_locale(AppWeb.Gettext)

    assigns =
      assigns
      |> assign(:current, current)
      |> assign(:locales, Gettext.known_locales(AppWeb.Gettext))

    ~H"""
    <div id={@id} role="group" aria-label={gettext("Language")} class="flex flex-wrap gap-1">
      <a
        :for={locale <- @locales}
        href={"?locale=#{locale}"}
        lang={locale}
        aria-current={locale == @current && "true"}
        aria-label={native_name(locale)}
        title={native_name(locale)}
        class={[
          "btn btn-xs h-6 min-h-6 px-1.5 font-mono text-[0.65rem] uppercase",
          if(locale == @current, do: "btn-active", else: "btn-ghost")
        ]}
      >
        {locale}
      </a>
    </div>
    """
  end

  defp theme_options do
    [
      {"light", "hero-sun", gettext("Light")},
      {"dark", "hero-moon", gettext("Dark")},
      # The high-contrast black theme first made for the Sheets sidebar
      # selectable everywhere.
      {"sheets-black", "hero-moon-solid", gettext("Black")},
      {"system", "hero-computer-desktop", gettext("Device default")}
    ]
  end

  @doc "Account button (avatar) and account card."
  attr :id, :string, default: "account-menu"
  attr :user, :map, required: true

  def account_menu(assigns) do
    ~H"""
    <.header_menu
      id={@id}
      label={gettext("Account: %{email}", email: to_string(@user.email))}
      menu_class="w-72"
    >
      <:trigger><.avatar user={@user} size="sm" /></:trigger>
      <div class="flex flex-col items-center gap-2 px-3 pt-4 pb-3 text-center">
        <span class="text-xs opacity-70 break-all">{@user.email}</span>
        <.avatar user={@user} size="lg" />
        <span :if={@user.name} class="font-medium">{@user.name}</span>
        <div class="flex flex-wrap justify-center gap-1">
          <.text_badge text={role_label(@user.role)} class="badge-sm badge-neutral" />
          <.text_badge
            :for={profile <- @user.profiles}
            text={profile_label(profile)}
            class="badge-sm badge-outline"
          />
        </div>
      </div>
      <div class="border-t border-base-300 pt-1">
        <.link
          :if={@user.person_id}
          navigate={"/people/#{@user.person_id}"}
          role="menuitem"
          class="menu-row"
        >
          <.icon name="hero-identification" class="size-4 shrink-0 opacity-70" />
          <span>{gettext("My page")}</span>
        </.link>
        <.link navigate="/notifications" role="menuitem" class="menu-row">
          <.icon name="hero-bell" class="size-4 shrink-0 opacity-70" />
          <span>{gettext("Notifications")}</span>
        </.link>
        <.link navigate="/interface" role="menuitem" class="menu-row">
          <.icon name="hero-adjustments-horizontal" class="size-4 shrink-0 opacity-70" />
          <span>{gettext("Interface")}</span>
        </.link>
        <.link navigate="/api-access" role="menuitem" class="menu-row">
          <.icon name="hero-key" class="size-4 shrink-0 opacity-70" />
          <span>{gettext("API access")}</span>
        </.link>
        <.link navigate="/sign-out" method="delete" role="menuitem" class="menu-row">
          <.icon name="hero-arrow-right-on-rectangle" class="size-4 shrink-0 opacity-70" />
          <span>{gettext("Sign out")}</span>
        </.link>
      </div>
    </.header_menu>
    """
  end

  attr :user, :map, required: true
  attr :size, :string, values: ~w(sm lg), default: "sm"

  defp avatar(assigns) do
    assigns =
      assigns
      |> assign(:initials, initials(assigns.user))
      |> assign(:color, avatar_color(assigns.user))

    ~H"""
    <span
      aria-hidden="true"
      class={[
        "inline-flex shrink-0 items-center justify-center rounded-full font-medium text-white select-none",
        @color,
        @size == "sm" && "size-8 text-sm",
        @size == "lg" && "size-16 text-2xl"
      ]}
    >
      {@initials}
    </span>
    """
  end

  @doc false
  @spec native_name(String.t()) :: String.t()
  def native_name(locale), do: Map.get(@native_names, locale, String.upcase(locale))

  @doc false
  @spec initials(map()) :: String.t()
  def initials(%{name: name}) when is_binary(name) and name != "" do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  def initials(%{email: email}), do: email |> to_string() |> String.first() |> String.upcase()

  @doc false
  @spec avatar_color(map()) :: String.t()
  def avatar_color(%{email: email}),
    do: Enum.at(@avatar_colors, :erlang.phash2(to_string(email), length(@avatar_colors)))
end
