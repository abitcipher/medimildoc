defmodule AppWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: AppWeb.Gettext

  alias AppWeb.Components.Tooltip, as: MishkaTooltip
  alias AppWeb.DateFormat
  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil

  attr :description, :string,
    default: nil,
    doc:
      "Shown as an info-icon tooltip next to the label — " <>
        "typically a JSON Schema field's own `description`, wired through by " <>
        "AppWeb.JsonSchemaForm. A long description scrolls inside the tooltip " <>
        "rather than growing past the visible area, see field_description/1."

  attr :value, :any

  attr :type, :string,
    default: "text",
    values:
      ~w(checkbox color country currency date datetime-local email file month number password
               search select tel text textarea time url week hidden language)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :code_field, Phoenix.HTML.FormField,
    default: nil,
    doc: ~s(type "place"/"region": the field storing the picked entry's code)

  attr :country_input, :string,
    default: nil,
    doc: ~s(type "place"/"region": id of the country field narrowing suggestions)

  attr :region_input, :string,
    default: nil,
    doc: ~s(type "place": id of the region field filled when a place is picked)

  attr :suggest, :string,
    default: nil,
    doc: ~s(type "suggest": the category of earlier values to suggest)

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  # Dates are typed and shown as dd.mm.yyyy (AppWeb.DateFormat); a hidden
  # native date input next to the text field carries the ISO value the form
  # submits and opens the browser's calendar (the DateInput JS hook).
  # Also "datetime-local": dd.mm.yyyy HH:MM (docs/design/clinical-module.md).
  def input(%{type: type} = assigns) when type in ["date", "datetime-local"] do
    assigns =
      assigns
      |> assign(:iso, Form.normalize_value(type, assigns.value))
      |> assign(:required?, assigns.rest[:required] in [true, "true", "required"])
      |> assign(:rest, Map.delete(assigns.rest, :required))
      |> assign(
        :pattern,
        if(type == "date", do: DateFormat.pattern(), else: DateFormat.datetime_pattern())
      )
      |> assign(:display, date_display(type, assigns.value))

    ~H"""
    <div class="fieldset mb-2">
      <label for={"#{@id}-display"}>
        <span :if={@label} class="label mb-1">
          {@label}
          <.field_description description={@description} />
        </span>
      </label>
      <div
        id={"#{@id}-date"}
        phx-hook="DateInput"
        data-format={@pattern}
        data-invalid-message={gettext("Enter a real date as %{pattern}", pattern: @pattern)}
        class="join w-full"
      >
        <input
          type="text"
          id={"#{@id}-display"}
          inputmode="numeric"
          autocomplete="off"
          placeholder={@pattern}
          value={@display}
          required={@required?}
          aria-invalid={@errors != [] && "true"}
          class={["input join-item w-full", @errors != [] && (@error_class || "input-error")]}
          data-date-display
          phx-update="ignore"
        />
        <input
          type={@type}
          name={@name}
          id={@id}
          value={@iso}
          tabindex="-1"
          aria-hidden="true"
          class="sr-only"
          data-date-value
          {@rest}
        />
        <button
          type="button"
          class="btn join-item"
          aria-label={gettext("Open calendar")}
          title={gettext("Open calendar")}
          data-date-calendar
        >
          <.icon name="hero-calendar-days" class="size-5" />
        </button>
      </div>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Reference codes — ISO 3166-1 alpha-2 country, ISO 639-1 language,
  # ISO 4217 currency — picked by name in the user's language
  # (docs/design/reference-data-and-files.md).
  def input(%{type: type} = assigns) when type in ~w(country language currency) do
    assigns =
      assign(assigns, :required?, assigns.rest[:required] in [true, "true", "required"])

    ~H"""
    <div class="fieldset mb-2">
      <label for={"#{@id}-button"}>
        <span :if={@label} class="label mb-1">
          {@label}
          <.field_description description={@description} />
        </span>
      </label>
      <AppWeb.ReferenceComponents.picker
        kind={@type}
        id={@id}
        name={@name}
        value={@value}
        required={@required?}
        invalid={@errors != []}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Free text with suggestions and an optional code: places and regions
  # (docs/design/reference-data-and-files.md, step 3). `code_field` is the
  # form field that stores the code.
  def input(%{type: type} = assigns) when type in ~w(place region) do
    code = assigns.code_field

    assigns =
      assigns
      |> assign(:required?, assigns.rest[:required] in [true, "true", "required"])
      |> assign(:code_id, if(code, do: code.id, else: "#{assigns.id}_code"))
      |> assign(:code_name, if(code, do: code.name, else: "#{assigns.name}_code"))
      |> assign(:code_value, code && code.value)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">
          {@label}
          <.field_description description={@description} />
        </span>
      </label>
      <AppWeb.ReferenceComponents.autocomplete
        kind={@type}
        id={@id}
        name={@name}
        value={@value}
        code_id={@code_id}
        code_name={@code_name}
        code_value={@code_value}
        country_input={@country_input}
        region_input={@region_input}
        required={@required?}
        invalid={@errors != []}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Several choices from a fixed list, shown as toggle chips: one real
  # checkbox each (keyboard and screen readers work as for any checkbox).
  # The empty marker keeps the field in the params when every chip is off.
  def input(%{type: "tags"} = assigns) do
    assigns =
      assign(assigns, :selected, assigns.value |> List.wrap() |> Enum.map(&to_string/1))

    ~H"""
    <fieldset class="fieldset mb-2">
      <legend :if={@label} class="label mb-1">
        {@label}
        <.field_description description={@description} />
      </legend>
      <input type="hidden" name={@name <> "[]"} value="" />
      <div class="flex flex-wrap gap-2">
        <label
          :for={{label, value} <- @options}
          class={[
            "btn btn-sm rounded-full font-normal",
            "has-checked:btn-primary has-focus-visible:outline-2 has-focus-visible:outline-offset-2"
          ]}
        >
          <input
            type="checkbox"
            id={"#{@id}-#{value}"}
            name={@name <> "[]"}
            value={value}
            checked={to_string(value) in @selected}
            class="peer sr-only"
          />
          <.icon name="hero-check" class="hidden size-4 peer-checked:inline" />
          {label}
        </label>
      </div>
      <.error :for={msg <- @errors}>{msg}</.error>
    </fieldset>
    """
  end

  # Free text with a fixed list of suggestions (`options`, JSON Schema
  # `x-suggest-list`, e.g. the drug list): a native <datalist>, so any
  # other text can still be typed.
  def input(%{type: "datalist"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">
          {@label}
          <.field_description description={@description} />
        </span>
      </label>
      <input
        type="text"
        id={@id}
        name={@name}
        value={Form.normalize_value("text", @value)}
        list={"#{@id}-list"}
        autocomplete="off"
        class={["w-full input", @errors != [] && "input-error"]}
        {@rest}
      />
      <datalist id={"#{@id}-list"}>
        <option :for={option <- @options} value={option} />
      </datalist>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Free text with suggestions from values entered before (`category`,
  # JSON Schema `x-suggest`).
  def input(%{type: "suggest"} = assigns) do
    assigns =
      assign(assigns, :required?, assigns.rest[:required] in [true, "true", "required"])

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">
          {@label}
          <.field_description description={@description} />
        </span>
      </label>
      <AppWeb.ReferenceComponents.suggest
        category={@suggest}
        id={@id}
        name={@name}
        value={@value}
        required={@required?}
        invalid={@errors != []}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
          <.field_description description={@description} />
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">
          {@label}
          <.field_description description={@description} />
        </span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">
          {@label}
          <.field_description description={@description} />
        </span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">
          {@label}
          <.field_description description={@description} />
        </span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # the "i" info icon + hover tooltip every input field
  # gets when its JSON Schema has a `description` (wired through by
  # AppWeb.JsonSchemaForm; nil here for fields with none, which renders
  # nothing). `content_class` caps the bubble at a fixed size with its
  # own scrollbar rather than letting a long description grow past the
  # visible area — exactly the "must fit within the visible area and
  # include a scrollbar" requirement, not just a long unbounded popup.
  #
  # Public (not `defp`) — AppWeb.JsonSchemaForm's range-slider branch
  # calls it directly too, since a slider doesn't go through `input/1`'s
  # own label markup (see json_schema_form.ex's `range_input/1`).
  attr :description, :string, required: true

  def field_description(assigns) do
    ~H"""
    <MishkaTooltip.tooltip
      :if={@description}
      inline
      position="top"
      color="natural"
      content_class="max-h-40 max-w-xs overflow-y-auto text-left whitespace-normal"
    >
      <:trigger>
        <.icon
          name="hero-information-circle"
          class="size-4 opacity-60 hover:opacity-100 align-text-bottom"
        />
      </:trigger>
      <:content>{@description}</:content>
    </MishkaTooltip.tooltip>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Human, translated label for an `App.Accounts.User.role` value
  (full UI translation) — the raw atom (`:admin`/
  `:hr`/`:viewer`) was displayed directly in three places
  (`Layouts.app`'s account badge, `UsersLive.Index`'s role `<select>`,
  `home.html.heex`'s signed-in line); a `Gettext.PO`-catalog string,
  same as everything else user-facing.
  """
  @spec role_label(:admin | :hr | :viewer | :person | atom() | nil) :: String.t()
  def role_label(:admin), do: gettext("Administrator")
  def role_label(:hr), do: gettext("HR staff")
  def role_label(:viewer), do: gettext("Viewer")
  def role_label(:person), do: gettext("Person (own data)")
  def role_label(other), do: to_string(other)

  @doc """
  Marks generated test data (`App.Demo`, docs/design/access-control-phase1.md
  so it can't be mistaken for a real person or unit.
  """
  def synthetic_badge(assigns) do
    ~H"""
    <span
      class="badge badge-sm badge-ghost align-middle"
      title={gettext("Generated test data, not a real person or unit")}
    >
      {gettext("Synthetic")}
    </span>
    """
  end

  @doc """
  A badge with a text label that never overflows: on one line, cut off
  with an ellipsis when its container is narrower, the full text then in
  a tooltip on hover (`data-float-tip-truncated`, assets/js/float_tip.js).

      <.text_badge text={profile_label(p)} class="badge-sm badge-outline" />
  """
  attr :text, :string, required: true
  attr :class, :any, default: nil

  def text_badge(assigns) do
    ~H"""
    <span class={["badge", @class]} data-float-tip={@text} data-float-tip-truncated>
      <span class="badge-text">{@text}</span>
    </span>
    """
  end

  @doc """
  Human, translated label for an access profile
  (docs/design/access-control-phase1.md). The English label comes from
  `priv/access_profiles.json` and doubles as the Gettext msgid.
  """
  @spec profile_label(atom()) :: String.t()
  def profile_label(profile),
    do: Gettext.gettext(AppWeb.Gettext, App.Access.profile_label(profile))

  @doc """
  Every UI label that lives in JSON config (`priv/access_profiles.json`:
  profile labels and permission descriptions; `priv/nav_schema.json`)
  rather than in Elixir source. `gettext_noop/1`
  marks each one for `mix gettext.extract`, which can't see into JSON;
  `test/app_web/json_config_labels_test.exs` fails when a label in either
  file is missing here.
  """
  @spec json_config_labels() :: [String.t()]
  def json_config_labels do
    [
      gettext_noop("Tasks"),
      gettext_noop("Care providers"),
      gettext_noop("Organizations providing medical care; our own units first."),
      gettext_noop("Head of department"),
      gettext_noop("Health data reader (integrations)"),
      gettext_noop("Sign discharge summaries (head of department)"),
      gettext_noop("Register of medical care providers"),
      gettext_noop("My data"),
      gettext_noop("What the system holds about you, to read and download."),
      gettext_noop("Event log"),
      gettext_noop("Sign-ins and other system events; publishing them to subscribers."),
      gettext_noop("Incidents"),
      gettext_noop("Data that broke a consistency rule, to review."),
      gettext_noop("Rules"),
      gettext_noop("Data consistency rules: what is checked, where, and how strictly."),
      gettext_noop("Settings"),
      gettext_noop("System settings."),
      gettext_noop("Documents waiting for you: to approve, sign or complete."),
      gettext_noop("People"),
      gettext_noop("Organizations"),
      gettext_noop("Positions"),
      gettext_noop("Admin"),
      gettext_noop("Users"),
      gettext_noop("Change conflicts"),
      gettext_noop("Access log"),
      # Navigation descriptions (start page cards)
      gettext_noop("Personnel files: identity, assignments and records."),
      gettext_noop("Units and their hierarchy."),
      gettext_noop("Posts, their grades and who fills them."),
      gettext_noop("Import / export"),
      gettext_noop("Assignments as a spreadsheet, offline or in Google Sheets."),
      gettext_noop("Acknowledgements"),
      gettext_noop("Leave calendar"),
      gettext_noop("Who of a unit is away when; days with too many away."),
      gettext_noop("Signed orders still to be acknowledged; record them in bulk."),
      gettext_noop("Registers"),
      gettext_noop("Signed documents by register and year, with their numbers and cases."),
      gettext_noop("File plan"),
      gettext_noop(
        "Cases for each year: index, retention period, the documents filed into them."
      ),
      gettext_noop("Records officer"),
      # Nav: the Sheets sidebar layout (docs/design/sheets-ui.md)
      gettext_noop("Sidebar layout"),
      gettext_noop("What the Google Sheets sidebar shows to each role."),
      # Nav: the org graph (docs/design/org-graph.md, ORG-GRAPH)
      gettext_noop("Org graph"),
      gettext_noop(
        "The structure as a graph: units, posts, people, reporting lines, deputies, care providers and places."
      ),
      # Nav and duty types (priv/duty_types.json, docs/design/duty-roster.md)
      gettext_noop("Duty roster"),
      gettext_noop(
        "Who of a unit is on which duty which day; duties while away, without rest, days short of people."
      ),
      gettext_noop("Duty officer"),
      gettext_noop("Assistant duty officer"),
      gettext_noop("Orderly"),
      gettext_noop("Medic on duty"),
      gettext_noop("Driver on duty"),
      gettext_noop("Registers and the file plan (номенклатура справ)"),
      gettext_noop("Who can sign in, and what each person may see and change."),
      gettext_noop("Edits that overwrote someone else's newer change."),
      gettext_noop("Who opened sensitive records, and when."),
      gettext_noop("Registrar"),
      gettext_noop("Line commander"),
      gettext_noop("Commander"),
      gettext_noop("Clinician"),
      gettext_noop("Command surgeon"),
      gettext_noop("Nurse"),
      gettext_noop("Combat medic"),
      gettext_noop("Security officer"),
      gettext_noop("CISO"),
      # Permission descriptions (priv/access_profiles.json)
      gettext_noop("People, units, positions, ordinary personnel records"),
      gettext_noop("People, units, positions, assignments"),
      gettext_noop("National IDs, identity documents, biometrics"),
      gettext_noop("Pay, family status, dependants"),
      gettext_noop("Fitness for duty"),
      gettext_noop("Security clearance status"),
      gettext_noop("Point of care: allergies, encounters, vital signs"),
      gettext_noop("Clinical history (conditions, diagnoses)"),
      gettext_noop("Vetting records"),
      gettext_noop("Access log, change conflicts"),
      gettext_noop("Users and their access"),
      gettext_noop("Emergency access to allergies outside the unit"),
      gettext_noop("Sign personnel orders"),
      gettext_noop("System settings"),
      gettext_noop("Data consistency rules")
    ]
  end

  defp date_display("date", value), do: DateFormat.display(Form.normalize_value("date", value))
  defp date_display(_datetime, value), do: DateFormat.display_datetime(value)

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  A Cinder table with its page navigation also above it (the hook
  `PagerTop` mirrors the control Cinder renders below). `id` is the table's
  Cinder id; the table goes in the inner block.

      <.top_pager id={@table_id}>
        <Cinder.collection id={@table_id} ...>...</Cinder.collection>
      </.top_pager>
  """
  attr :id, :string, required: true
  slot :inner_block, required: true

  def top_pager(assigns) do
    ~H"""
    <div id={"#{@id}-pager"} phx-hook="PagerTop" class="flex flex-col gap-2">
      <div id={"#{@id}-pager-top"} data-pager-slot phx-update="ignore"></div>
      <div data-pager-table>{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(AppWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(AppWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
