defmodule AppWeb.InterfaceLive do
  @moduledoc """
  The user's own interface settings (`App.Accounts.UiPreferences`,
  docs/design/ui-preferences.md): how edit and "New …" forms are shown,
  set separately for narrow screens (phones) and wide screens. Saved on
  every change through `User`'s `:update_preferences`, which only lets a
  user change their own.

  The controls themselves adapt to the screen: on a narrow screen each
  choice is a full-width row stacked under the other (easy to tap), on a
  wide screen a row of segmented buttons; the row for the screen in use is
  marked. Below, each form with an add control can follow the general
  choice or have its own (a select per screen width).
  """
  use AppWeb, :live_view

  @window_settings ~w(window_controls form_buttons window_border)

  alias App.Accounts.{UiPreferences, User}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: gettext("Interface"), window_settings: @window_settings)}
  end

  @impl true
  def handle_event("save", params, socket) do
    user = socket.assigns.current_user
    prefs = Enum.reduce(choices(params), user.ui_preferences, &choose/2)

    user
    |> Ash.Changeset.for_update(:update_preferences, %{ui_preferences: prefs}, actor: user)
    |> Ash.update(actor: user)
    |> case do
      {:ok, %User{} = updated} ->
        {:noreply,
         socket
         |> assign(:current_user, %{user | ui_preferences: updated.ui_preferences})
         |> put_flash(:info, gettext("Interface settings saved"))}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save the settings."))}
    end
  end

  # Every choice the form sends, tagged by kind.
  defp choices(params) do
    general =
      for {setting, by_width} <- params["prefs"] || %{},
          {width, value} <- by_width,
          do: {:general, setting, width, value}

    per_form =
      for {form, by_width} <- params["forms"] || %{},
          {width, value} <- by_width,
          do: {:form, form, width, value}

    sections = for value <- List.wrap(params["sections"]), do: {:sections, value}
    singles = for {key, value} <- params["singles"] || %{}, do: {:single, key, value}
    general ++ per_form ++ sections ++ singles
  end

  # One choice from the form; anything unknown is ignored.
  defp choose({:general, setting, width, value}, prefs),
    do: keep_if_ok(UiPreferences.put(prefs, setting, width, value), prefs)

  defp choose({:sections, value}, prefs),
    do: keep_if_ok(UiPreferences.put_section_style(prefs, value), prefs)

  defp choose({:single, key, value}, prefs) when key in @window_settings,
    do: keep_if_ok(UiPreferences.put_single(prefs, key, value), prefs)

  defp choose({:single, _key, _value}, prefs), do: prefs

  defp choose({:form, form, width, value}, prefs),
    do: keep_if_ok(UiPreferences.put_form(prefs, form, width, value), prefs)

  defp keep_if_ok({:ok, prefs}, _old), do: prefs
  defp keep_if_ok(:error, old), do: old

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-3xl flex-col gap-6 p-4">
        <h1 class="text-xl font-semibold">{gettext("Interface")}</h1>

        <form id="interface-form" phx-change="save" class="flex flex-col gap-6">
          <section
            :for={{setting, values} <- UiPreferences.settings()}
            id={"setting-#{setting}"}
            class="flex flex-col gap-3 rounded-box border border-base-300 p-4"
          >
            <h2 class="flex items-center gap-2 font-semibold">
              {setting_label(setting)}
              <.field_description description={setting_help(setting)} />
            </h2>
            <div class="flex flex-col gap-4">
              <fieldset
                :for={width <- UiPreferences.widths()}
                class={[
                  "flex flex-col gap-2",
                  length(values) <= 2 && "md:flex-row md:items-center md:justify-between"
                ]}
              >
                <legend class="float-left mb-1 flex items-center gap-2 text-sm font-medium md:mb-0">
                  <.icon name={width_icon(width)} class="size-4 opacity-70" />
                  {width_label(width)}
                  <span class={["badge badge-sm badge-primary badge-soft", this_screen(width)]}>
                    {gettext("this screen")}
                  </span>
                </legend>
                <div class="join join-vertical w-full md:join-horizontal md:w-auto">
                  <input
                    :for={value <- values}
                    type="radio"
                    id={"#{setting}-#{width}-#{value}"}
                    name={"prefs[#{setting}][#{width}]"}
                    value={value}
                    checked={UiPreferences.get(@current_user.ui_preferences, setting, width) == value}
                    class="join-item btn btn-sm justify-start md:justify-center"
                    aria-label={value_label(value)}
                  />
                </div>
              </fieldset>
            </div>
          </section>

          <section id="setting-sections" class="flex flex-col gap-3">
            <h2 class="flex items-center gap-2 font-semibold">
              {gettext("Sections")}
              <.field_description description={
                gettext(
                  "Blocks of a page (lists, settings, panels) are framed. With the glow, the frame lights up in colour where the mouse is — not on touch screens, and not when the device asks for reduced motion."
                )
              } />
            </h2>
            <div class="join join-vertical w-full md:join-horizontal md:w-auto">
              <input
                :for={value <- UiPreferences.section_styles()}
                type="radio"
                id={"sections-#{value}"}
                name="sections"
                value={value}
                checked={UiPreferences.section_style(@current_user.ui_preferences) == value}
                class="join-item btn btn-sm justify-start md:justify-center"
                aria-label={section_label(value)}
              />
            </div>
          </section>

          <section id="setting-windows" class="flex flex-col gap-3">
            <h2 class="flex items-center gap-2 font-semibold">
              {gettext("Windows")}
              <.field_description description={
                gettext(
                  "For forms shown in a window (see Edit forms). The title bar always stays in place while the form scrolls."
                )
              } />
            </h2>
            <fieldset
              :for={key <- @window_settings}
              id={"single-#{key}"}
              class="flex flex-col gap-2 md:flex-row md:items-center md:justify-between"
            >
              <legend class="float-left mb-1 text-sm font-medium md:mb-0">{single_label(key)}</legend>
              <div class="join join-vertical w-full md:join-horizontal md:w-auto">
                <input
                  :for={value <- UiPreferences.singles()[key]}
                  type="radio"
                  id={"#{key}-#{value}"}
                  name={"singles[#{key}]"}
                  value={value}
                  checked={UiPreferences.single(@current_user.ui_preferences, key) == value}
                  class="join-item btn btn-sm justify-start md:justify-center"
                  aria-label={single_value_label(key, value)}
                />
              </div>
            </fieldset>
          </section>

          <section
            id="setting-forms"
            class="flex flex-col gap-3 rounded-box border border-base-300 p-4"
          >
            <h2 class="flex items-center gap-2 font-semibold">
              {gettext("Add controls per form")}
              <.field_description description={
                gettext(
                  "Each form can follow the setting for new entry forms above, or have its own."
                )
              } />
            </h2>
            <div class="hidden grid-cols-[1fr_13rem_13rem] gap-3 text-sm font-medium md:grid">
              <span></span>
              <span :for={width <- UiPreferences.widths()} class="flex items-center gap-2">
                <.icon name={width_icon(width)} class="size-4 opacity-70" />
                {width_label(width)}
              </span>
            </div>
            <div
              :for={form <- UiPreferences.forms()}
              id={"form-setting-#{form}"}
              class="grid grid-cols-1 gap-2 border-t border-base-200 pt-3 md:grid-cols-[1fr_13rem_13rem] md:items-center md:gap-3"
            >
              <span class="font-medium">{form_label(form)}</span>
              <label :for={width <- UiPreferences.widths()} class="flex flex-col gap-1">
                <span class="flex items-center gap-2 text-xs opacity-70 md:sr-only">
                  <.icon name={width_icon(width)} class="size-4" />
                  {width_label(width)}
                </span>
                <select
                  id={"forms-#{form}-#{width}"}
                  name={"forms[#{form}][#{width}]"}
                  class="select select-sm w-full"
                >
                  <option
                    value="default"
                    selected={
                      is_nil(UiPreferences.form_override(@current_user.ui_preferences, form, width))
                    }
                  >
                    {gettext("General: %{choice}",
                      choice:
                        short_label(
                          UiPreferences.get(@current_user.ui_preferences, "create_form", width)
                        )
                    )}
                  </option>
                  <option
                    :for={value <- create_values()}
                    value={value}
                    selected={
                      UiPreferences.form_override(@current_user.ui_preferences, form, width) == value
                    }
                  >
                    {short_label(value)}
                  </option>
                </select>
              </label>
            </div>
          </section>
        </form>
      </div>
    </Layouts.app>
    """
  end

  # Which column is the screen in use (the breakpoint is `md`, as in
  # AppWeb.FormPanels).
  defp this_screen("narrow"), do: "md:hidden"
  defp this_screen("wide"), do: "hidden md:inline-flex"

  defp width_icon("narrow"), do: "hero-device-phone-mobile"
  defp width_icon("wide"), do: "hero-computer-desktop"

  defp width_label("narrow"), do: gettext("Narrow screens (phones)")
  defp width_label("wide"), do: gettext("Wide screens")

  defp setting_label("edit_form"), do: gettext("Edit forms")
  defp setting_label("create_form"), do: gettext("New entry forms")

  defp setting_help("edit_form"),
    do: gettext("How a form for changing an entry opens: in the page, or in a window over it.")

  defp setting_help("create_form"),
    do:
      gettext(
        "Where the control for adding an entry is (New organization, Add an identifier and others): the form always shown under the list, a button above it, a compact icon button, or the ⋮ menu. An opened form appears as set for edit forms. Single forms can differ — see below."
      )

  defp value_label("inline"), do: gettext("In the page")
  defp value_label("modal"), do: gettext("In a window")
  defp value_label("visible"), do: gettext("Always shown")
  defp value_label("toolbar"), do: gettext("Button above the table")
  defp value_label("compact"), do: gettext("Compact icon button")
  defp value_label("menu"), do: gettext("In the ⋮ menu")

  defp single_label("window_controls"), do: gettext("Window buttons")
  defp single_label("form_buttons"), do: gettext("Save and Cancel")
  defp single_label("window_border"), do: gettext("Window frame")

  defp single_value_label("window_controls", "left"),
    do: gettext("Left, form buttons on the right")

  defp single_value_label("window_controls", "right"),
    do: gettext("Right, form buttons on the left")

  defp single_value_label("form_buttons", "form"), do: gettext("At the end of the form")
  defp single_value_label("form_buttons", "header"), do: gettext("In the title bar")
  defp single_value_label("window_border", "colour"), do: gettext("Colourful")
  defp single_value_label("window_border", "contrast"), do: gettext("Contrast with the theme")

  defp section_label("glow"), do: gettext("Frame with glow near the pointer")
  defp section_label("static"), do: gettext("Frame only")
  defp section_label("off"), do: gettext("Off")

  # Shorter names for the per-form selects.
  defp short_label("visible"), do: gettext("Always shown")
  defp short_label("toolbar"), do: gettext("Button")
  defp short_label("compact"), do: gettext("Icon button")
  defp short_label("menu"), do: gettext("⋮ menu")

  defp create_values,
    do: UiPreferences.settings() |> List.keyfind!("create_form", 0) |> elem(1)

  defp form_label("organization"), do: gettext("New organization")
  defp form_label("position"), do: gettext("New position")
  defp form_label("provider"), do: gettext("New provider")
  defp form_label("assignment"), do: gettext("Person: assign to a position")
  defp form_label("identifier"), do: gettext("Person: add an identifier")
  defp form_label("identity_document"), do: gettext("Person: add an identity document")
  defp form_label("deputy"), do: gettext("Tasks: add a deputy")
  defp form_label("case"), do: gettext("File plan: add a case")
end
