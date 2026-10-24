defmodule AppWeb.FormPanels do
  @moduledoc """
  Edit and "New …" forms shown the way the user's interface settings say
  (`App.Accounts.UiPreferences`, docs/design/ui-preferences.md), each
  chosen for narrow screens (below `md`) and wide screens separately:

  - `form_panel/1` — the form in the page (inline) or in a modal window;
    a "New …" form may also be always visible (the earlier layout).
  - `create_actions/1` — the buttons that open "New …" forms: in a
    toolbar above the table, or behind one ⋮ menu button.

  One DOM for both widths: the server knows the settings, not the screen,
  so each choice becomes Tailwind classes with and without the `md:`
  prefix (all written out literally, so Tailwind finds them).
  """
  use Phoenix.Component
  use Gettext, backend: AppWeb.Gettext

  import AppWeb.CoreComponents, only: [icon: 1]

  alias App.Accounts.UiPreferences
  alias Phoenix.LiveView.JS

  @doc """
  How a form shows on each width: `:hidden`, `:inline` or `:modal`.
  An edit form shows while it is open, as `edit_form` says. A "New …"
  form set to `visible` always shows inline; otherwise it shows while
  opened by its button, as `edit_form` says.
  """
  @spec presentation(map() | nil, :edit | :create, boolean(), String.t(), String.t() | nil) ::
          :hidden | :inline | :modal
  def presentation(prefs, kind, open?, width, form \\ nil) do
    edit = String.to_existing_atom(UiPreferences.get(prefs, "edit_form", width))

    cond do
      kind == :create and UiPreferences.create_mode(prefs, form, width) == "visible" -> :inline
      open? -> edit
      true -> :hidden
    end
  end

  @doc """
  A form in a panel: `title`, the form in the inner block. `close` is the
  event that closes it (the backdrop, the close buttons, Escape and
  Cancel).

  Where the form is a window, the title bar stays in place and only the
  form scrolls under it; the interface settings decide on which side the
  window buttons are (the form buttons go to the other corner), whether
  Save and Cancel are in the title bar (`form_id` and `submit_label` say
  which form they submit; the form's own row of buttons, marked
  `form-actions`, is then hidden in the window), and the window's frame.
  """
  attr :id, :string, required: true
  attr :prefs, :map, default: %{}
  attr :kind, :atom, values: [:edit, :create], required: true

  attr :form, :string,
    default: nil,
    doc: "the form's own add-control setting (UiPreferences.forms/0)"

  attr :open, :boolean, default: false
  attr :title, :string, required: true
  attr :icon, :string, default: nil
  attr :close, :any, required: true, doc: "event name, or a JS command (inside a live component)"
  attr :form_id, :string, default: nil, doc: "id of the form, for Save in the title bar"
  attr :submit_label, :string, default: nil
  slot :inner_block, required: true

  def form_panel(assigns) do
    narrow = presentation(assigns.prefs, assigns.kind, assigns.open, "narrow", assigns.form)
    wide = presentation(assigns.prefs, assigns.kind, assigns.open, "wide", assigns.form)
    prefs = assigns.prefs

    assigns =
      assign(assigns,
        narrow: narrow,
        wide: wide,
        modal?: :modal in [narrow, wide],
        shown?: narrow != :hidden or wide != :hidden,
        closable?: assigns.open,
        controls: UiPreferences.single(prefs, "window_controls"),
        header_actions?:
          assigns.form_id != nil and UiPreferences.single(prefs, "form_buttons") == "header",
        border: UiPreferences.single(prefs, "window_border"),
        submit_label: assigns.submit_label || gettext("Save")
      )

    ~H"""
    <div
      :if={@shown?}
      id={@id}
      class={[
        outer(:narrow, @narrow),
        outer(:wide, @wide),
        @narrow == :modal && "window-narrow",
        @wide == :modal && "window-wide",
        "window-border-#{@border}",
        @header_actions? && "actions-in-header"
      ]}
      role={@modal? && "dialog"}
      aria-labelledby={"#{@id}-title"}
      phx-window-keydown={@closable? && @close}
      phx-key="Escape"
      phx-mounted={@closable? && JS.focus_first(to: "##{@id}-body")}
    >
      <div
        :if={@modal? and @closable?}
        class={["absolute inset-0", backdrop(:narrow, @narrow), backdrop(:wide, @wide)]}
        phx-click={@close}
        aria-hidden="true"
      >
      </div>
      <div class={[
        "window-box relative w-full rounded-box border border-base-300 bg-base-100 p-4",
        box(:narrow, @narrow),
        box(:wide, @wide)
      ]}>
        <div class={[
          "mb-2 flex shrink-0 items-center gap-3",
          direction(:narrow, @narrow, @controls),
          direction(:wide, @wide, @controls)
        ]}>
          <%!-- Window buttons where the form is a window: close and zoom to
               the full screen and back (a class, kept by LiveView across
               updates). On the right, close is the outermost. --%>
          <div
            :if={@closable?}
            class={[
              "group items-center gap-2",
              @controls == "right" && "flex-row-reverse",
              window_only(:narrow, @narrow),
              window_only(:wide, @wide)
            ]}
          >
            <button
              type="button"
              phx-click={@close}
              class="grid size-3.5 place-items-center rounded-full bg-[#ff5f57] text-black/60"
              aria-label={gettext("Close")}
              title={gettext("Close")}
            >
              <.icon name="hero-x-mark-mini" class="size-2.5 opacity-0 group-hover:opacity-100" />
            </button>
            <button
              type="button"
              phx-click={JS.toggle_class("window-zoomed", to: "##{@id}")}
              class="grid size-3.5 place-items-center rounded-full bg-[#28c840] text-black/60"
              aria-label={gettext("Full screen")}
              title={gettext("Full screen")}
            >
              <.icon
                name="hero-arrows-pointing-out-mini"
                class="size-2.5 opacity-0 group-hover:opacity-100"
              />
            </button>
          </div>
          <h2 id={"#{@id}-title"} class="flex min-w-0 grow items-center gap-2 font-semibold">
            <.icon :if={@icon} name={@icon} class="size-5 shrink-0" />
            <span class="truncate">{@title}</span>
          </h2>
          <%!-- Save and Cancel in the title bar (outside the form: `form`
               names the form they submit). --%>
          <div
            :if={@closable? and @header_actions?}
            class={[
              "shrink-0 items-center gap-2",
              @controls == "right" && "flex-row-reverse",
              window_only(:narrow, @narrow),
              window_only(:wide, @wide)
            ]}
          >
            <button type="button" phx-click={@close} class="btn btn-ghost btn-sm">
              {gettext("Cancel")}
            </button>
            <button type="submit" form={@form_id} class="btn btn-primary btn-sm">
              {@submit_label}
            </button>
          </div>
          <button
            :if={@closable?}
            type="button"
            phx-click={@close}
            class={[
              "btn btn-ghost btn-sm btn-square",
              inline_only(:narrow, @narrow),
              inline_only(:wide, @wide)
            ]}
            aria-label={gettext("Close")}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
        <div id={"#{@id}-body"} class={[body(:narrow, @narrow), body(:wide, @wide)]}>
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  # The title bar mirrored when the window buttons are on the right
  # (only where the form is a window).
  defp direction(:narrow, :modal, "right"), do: "flex-row-reverse"
  defp direction(:narrow, _presentation, _controls), do: nil
  defp direction(:wide, :modal, "right"), do: "md:flex-row-reverse"
  defp direction(:wide, _presentation, _controls), do: "md:flex-row"

  # The title-bar buttons where the panel is a window; the × where it is inline.
  defp window_only(:narrow, :modal), do: "flex"
  defp window_only(:narrow, _other), do: "hidden"
  defp window_only(:wide, :modal), do: "md:flex"
  defp window_only(:wide, _other), do: "md:hidden"

  defp inline_only(:narrow, :modal), do: "hidden"
  defp inline_only(:narrow, _other), do: "inline-flex"
  defp inline_only(:wide, :modal), do: "md:hidden"
  defp inline_only(:wide, _other), do: "md:inline-flex"

  defp outer(:narrow, :hidden), do: "hidden"
  defp outer(:narrow, :inline), do: "block"

  defp outer(:narrow, :modal),
    do: "fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-2"

  defp outer(:wide, :hidden), do: "md:hidden"

  defp outer(:wide, :inline),
    do: "md:static md:inset-auto md:z-auto md:block md:bg-transparent md:p-0"

  defp outer(:wide, :modal),
    do:
      "md:fixed md:inset-0 md:z-50 md:flex md:items-center md:justify-center md:bg-black/40 md:p-4"

  defp backdrop(:narrow, :modal), do: "block"
  defp backdrop(:narrow, _other), do: "hidden"
  defp backdrop(:wide, :modal), do: "md:block"
  defp backdrop(:wide, _other), do: "md:hidden"

  # A window is a column: the title bar stays, the body scrolls.
  defp box(:narrow, :modal), do: "flex max-h-[90vh] max-w-2xl flex-col overflow-hidden shadow-xl"
  defp box(:narrow, _other), do: nil

  defp box(:wide, :modal),
    do: "md:flex md:max-h-[90vh] md:max-w-2xl md:flex-col md:overflow-hidden md:shadow-xl"

  defp box(:wide, _other),
    do: "md:block md:max-h-none md:max-w-none md:overflow-visible md:shadow-none"

  # Room for focus rings at the sides of the scrolling body.
  defp body(:narrow, :modal), do: "-mx-1 min-h-0 flex-1 overflow-y-auto px-1"
  defp body(:narrow, _other), do: nil

  defp body(:wide, :modal),
    do: "md:-mx-1 md:min-h-0 md:flex-1 md:overflow-y-auto md:px-1"

  defp body(:wide, _other), do: "md:mx-0 md:flex-none md:overflow-visible md:px-0"

  @doc """
  The controls that open "New …" forms, where the settings put them for
  `form` (`App.Accounts.UiPreferences.create_mode/3`): labelled buttons
  in a toolbar, compact icon buttons (the label on hover and for screen
  readers), or one ⋮ button with a menu. `actions` are `%{label, event}`
  with optional `icon` and `values` (sent with the event); nothing shows on
  widths where the forms are always visible.
  """
  attr :id, :string, required: true
  attr :prefs, :map, default: %{}
  attr :form, :string, default: nil
  attr :actions, :list, required: true

  def create_actions(assigns) do
    narrow = UiPreferences.create_mode(assigns.prefs, assigns.form, "narrow")
    wide = UiPreferences.create_mode(assigns.prefs, assigns.form, "wide")
    visible = fn mode -> [show(:narrow, narrow == mode), show(:wide, wide == mode)] end

    assigns =
      assign(assigns,
        toolbar: visible.("toolbar"),
        compact: visible.("compact"),
        menu: visible.("menu")
      )

    ~H"""
    <div :if={@actions != []} class="flex items-center justify-end gap-1">
      <div id={"#{@id}-toolbar"} class={["flex-wrap items-center gap-2" | @toolbar]}>
        <button
          :for={action <- @actions}
          type="button"
          phx-click={push(action)}
          class="btn btn-sm btn-primary"
        >
          <.icon name={action[:icon] || "hero-plus"} class="size-4" /> {action.label}
        </button>
      </div>
      <div id={"#{@id}-compact"} class={["items-center gap-1" | @compact]}>
        <button
          :for={action <- @actions}
          type="button"
          phx-click={push(action)}
          class="btn btn-sm btn-square btn-primary"
          aria-label={action.label}
          title={action.label}
        >
          <.icon name={action[:icon] || "hero-plus"} class="size-4" />
        </button>
      </div>
      <div id={"#{@id}-menu"} class={["dropdown dropdown-end" | @menu]}>
        <div
          tabindex="0"
          role="button"
          class="btn btn-sm btn-square btn-ghost"
          aria-label={gettext("Actions")}
          title={gettext("Actions")}
        >
          <.icon name="hero-ellipsis-vertical" class="size-5" />
        </div>
        <ul
          tabindex="0"
          class="menu dropdown-content z-40 mt-1 w-56 rounded-box border border-base-300 bg-base-100 p-1 shadow"
        >
          <li :for={action <- @actions}>
            <button type="button" phx-click={push(action) |> JS.focus(to: "##{@id}-after-menu")}>
              <.icon name={action[:icon] || "hero-plus"} class="size-4" /> {action.label}
            </button>
          </li>
        </ul>
      </div>
      <%!-- Focus moves here after a choice, which closes the menu (daisyUI
           keeps a dropdown open while focus is inside it). --%>
      <span id={"#{@id}-after-menu"} tabindex="-1" class="sr-only"></span>
    </div>
    """
  end

  defp push(action), do: JS.push(action.event, value: action[:values] || %{})

  defp show(:narrow, true), do: "flex"
  defp show(:narrow, false), do: "hidden"
  defp show(:wide, true), do: "md:flex"
  defp show(:wide, false), do: "md:hidden"
end
