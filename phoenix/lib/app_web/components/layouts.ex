defmodule AppWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AppWeb, :html

  alias App.Documents.Queries
  alias AppWeb.Components.Navbar, as: MishkaNavbar
  alias AppWeb.Components.Sidebar, as: MishkaSidebar

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates("layouts/*")

  # root.html.heex's dev-sign-in banner needs this as a
  # plain function call (`dev_routes?()`), not `@dev_routes`: inside `~H`,
  # `@foo` always means a socket/conn assign, never a module attribute of
  # the same name, even in the same module (the exact same gotcha as
  # `Application.get_env/3` (runtime), not
  # `compile_env/2` — the latter, captured into a module attribute, made
  # HEEx's compiler fold `:if={dev_routes?()}` into a constant and warn
  # ("will always evaluate to: dynamic(true)"), failing
  # `--warnings-as-errors`; router.ex's route-registration guard still
  # needs the compile-time form (routes can't be added at runtime), this
  # banner doesn't.
  def dev_routes?, do: Application.get_env(:app, :dev_routes, false)

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :current_user, :map,
    default: nil,
    doc: "the signed-in App.Accounts.User, for nav visibility and the account menu"

  slot :inner_block, required: true

  # Mishka Chelekom-based chrome: a top bar (brand,
  # hamburger, locale, theme, account) plus a collapsible left sidebar
  # that now carries the actual primary navigation (chosen nav
  # shell — "sidebar + slim top bar"), fed declaratively from
  # AppWeb.NavSchema/priv/nav_schema.json rather than one <:list> per
  # link. The sidebar's own hide/minimize behavior (mobile show-hide,
  # desktop icon-rail collapse) is entirely Mishka's built-in JS hook —
  # see assets/vendor/sidebar.js and app.css's #app-main margin rule.
  def app(assigns) do
    assigns =
      assigns
      |> assign(:nav_items, AppWeb.NavSchema.visible_items(assigns.current_user))
      |> assign(:badges, nav_badges(assigns.current_user))

    ~H"""
    <MishkaNavbar.navbar
      id="app-nav"
      color="dark"
      variant="shadow"
      padding="small"
      link={~p"/"}
      name="HR Admin"
      nav_wrapper_class="flex flex-nowrap items-center gap-2 [&>a]:mb-0 [&>div:last-child]:ml-auto"
    >
      <:start_content :if={@current_user}>
        <button
          type="button"
          class="btn btn-ghost btn-sm btn-square md:hidden"
          aria-label={gettext("Toggle navigation")}
          phx-click={MishkaSidebar.show_sidebar("app-sidebar", "left")}
        >
          <.icon name="hero-bars-3" class="size-5" />
        </button>
      </:start_content>

      <%!-- Own flex wrapper: the Mishka navbar reads the slot class as
      @end_content[:class] on a list of slot entries, which is always nil. --%>
      <:end_content>
        <div class="flex items-center gap-1">
          <AppWeb.HeaderControls.search_menu :if={@current_user} />
          <AppWeb.HeaderControls.language_menu />
          <AppWeb.HeaderControls.theme_menu />
          <AppWeb.HeaderControls.account_menu :if={@current_user} user={@current_user} />
          <.link :if={!@current_user} navigate={~p"/sign-in"} class="btn btn-sm btn-primary ml-1">
            {gettext("Sign in")}
          </.link>
        </div>
      </:end_content>
    </MishkaNavbar.navbar>

    <MishkaSidebar.sidebar
      :if={@current_user}
      id="app-sidebar"
      variant="default"
      color="dark"
      size="extra_small"
      hide_position="left"
      minimize
      data-expanded-width="16rem"
      data-collapsed-width="4.5rem"
    >
      <ul class="px-2 py-3 flex flex-col gap-1" role="list">
        <.nav_items items={@nav_items} badges={@badges} />
      </ul>
    </MishkaSidebar.sidebar>

    <%!-- data-sections: how content sections look (the viewer's interface
         settings; assets/css/app.css "Content sections", js/section_glow.js). --%>
    <main
      id="app-main"
      class="px-4 py-8 sm:px-6 lg:px-8 transition-[margin]"
      data-sections={
        App.Accounts.UiPreferences.section_style(@current_user && @current_user.ui_preferences)
      }
    >
      <div class="mx-auto max-w-5xl space-y-4">
        {render_slot(@inner_block)}
      </div>
      <%!-- Attribution required by the reference data licences
           (ihds/seed/SOURCES.md): GeoNames is CC BY 4.0. --%>
      <footer class="mx-auto mt-12 max-w-5xl text-xs opacity-60">
        {gettext("Reference data:")}
        <a href="https://www.geonames.org" target="_blank" rel="noopener" class="link">GeoNames</a>
        (CC BY 4.0), <a href="https://cldr.unicode.org" target="_blank" rel="noopener" class="link">Unicode CLDR</a>, {gettext(
          "KATOTTH codifier of Ukraine"
        )}, <a href="https://flagicons.lipis.dev" target="_blank" rel="noopener" class="link">flag-icons</a>.
        <br />
        {gettext("Clinical:")}
        <a href="https://loinc.org" target="_blank" rel="noopener" class="link">LOINC®</a>
        (© Regenstrief Institute, Inc.),
        <a
          href="https://www.rcp.ac.uk/improving-care/resources/national-early-warning-score-news-2/"
          target="_blank"
          rel="noopener"
          class="link"
        >NEWS2</a>
        (© Royal College of Physicians).
      </footer>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  # docs/design/inbox-first.md: how many tasks wait, next to "Tasks";
  # red when any is overdue.
  defp nav_badges(nil), do: %{}

  defp nav_badges(user) do
    case Queries.waiting_count(user) do
      %{count: 0} -> %{}
      badge -> %{"tasks" => badge}
    end
  end

  attr :badge, :map, required: true

  defp nav_badge(assigns) do
    ~H"""
    <span
      id="tasks-badge"
      class={[
        "badge badge-xs absolute -top-1.5 -right-2 min-w-4 px-1 font-semibold",
        if(@badge.overdue > 0, do: "badge-error", else: "badge-primary")
      ]}
      aria-label={
        ngettext("%{count} task waiting", "%{count} tasks waiting", @badge.count) <>
          if(@badge.overdue > 0,
            do: ", " <> ngettext("%{count} overdue", "%{count} overdue", @badge.overdue),
            else: ""
          )
      }
    >
      {@badge.count}
    </span>
    """
  end

  @doc """
  Renders one level of `AppWeb.NavSchema.visible_items/1` items —
  recurses one level deep for `"children"` (this app's route tree never
  needs more, see the schema's own moduledoc). A leaf item (has `"path"`)
  is a real link; a parent-only item (children, no `"path"` of its own)
  renders as a small, non-interactive section label above its children —
  hidden along with the icon-only-collapsed state via the same
  `data-item-label` convention Mishka's own sidebar items use, so the
  built-in JS hook's show/hide-on-minimize logic covers these too, even
  though they're hand-rendered here rather than via the `:item` slot
  (slots can't recurse/nest, which a hierarchical menu needs).

  `title={AppWeb.NavSchema.label(item)}` on every link is the collapsed
  state's tooltip — plain native `title`, not the Mishka `Tooltip`
  component: nav labels are short one-liners, not the "long description
  that needs its own scroll container" case `Tooltip` is
  for on form fields.
  """
  attr :items, :list, required: true

  attr :badges, :map,
    default: %{},
    doc: "nav item id → %{count, overdue}: a count over the item's icon"

  def nav_items(assigns) do
    ~H"""
    <li :for={item <- @items}>
      <.link
        :if={item["path"]}
        navigate={item["path"]}
        title={AppWeb.NavSchema.label(item)}
        class="sidebar-item-link flex items-center gap-2 rounded px-2 py-1.5 hover:bg-white/10"
      >
        <span class="relative shrink-0">
          <.icon name={item["icon"]} class="size-5" />
          <.nav_badge :if={@badges[item["id"]]} badge={@badges[item["id"]]} />
        </span>
        <span class="sidebar-text truncate" data-item-label>{AppWeb.NavSchema.label(item)}</span>
      </.link>

      <div :if={!item["path"] && item["children"] not in [nil, []]}>
        <span
          class="sidebar-text block px-2 pt-2 pb-1 text-xs font-semibold uppercase opacity-60"
          data-item-label
        >
          {AppWeb.NavSchema.label(item)}
        </span>
        <ul class="flex flex-col gap-1">
          <.nav_items items={item["children"]} badges={@badges} />
        </ul>
      </div>
    </li>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
