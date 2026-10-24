defmodule AppWeb.ReferenceComponents do
  @moduledoc """
  Reference-data display and pickers (docs/design/reference-data-and-files.md
  The main database stores codes — ISO 3166-1 alpha-2 countries,
  ISO 639-1 languages, ISO 4217 currencies; names in the user's language
  (and flags for countries) come from IHDS via `App.IHDS`. When IHDS is
  unavailable, codes are shown as they are and the picker falls back to a
  plain text field, so forms keep working.

  Does not use `AppWeb.CoreComponents` (which calls into this module for
  `<.input type="country">` etc.), to keep the dependency one-way.
  """
  use Phoenix.Component
  use Gettext, backend: AppWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: AppWeb.Endpoint,
    router: AppWeb.Router,
    statics: AppWeb.static_paths()

  # Flag SVGs (priv/static/flags), plain paths: the browser-side picker
  # builds the same URLs from this base.
  @flag_base "/flags/4x3"

  # Reference kind (JSON Schema `x-reference`, `<.input type=...>`) →
  # IHDS dataset and the code length for the fallback text field.
  @kinds %{
    "country" => %{dataset: "countries", maxlength: 2},
    "language" => %{dataset: "languages", maxlength: 2},
    "currency" => %{dataset: "currencies", maxlength: 3}
  }

  @doc "Reference kinds with a picker: the `x-reference` values forms accept."
  @spec kinds() :: [String.t()]
  def kinds, do: Map.keys(@kinds)

  @doc """
  A country code shown as flag + name in the current language; the code
  itself is in the tooltip. `nil` shows a dash; an unknown code (or IHDS
  down) shows the code.
  """
  attr :code, :string, default: nil
  attr :class, :any, default: nil

  def country(assigns), do: reference(Map.put(assigns, :kind, "country"))

  @doc """
  Any reference code (`kind`: `"country"`, `"language"`, `"currency"`)
  shown by its name in the current language, the code in the tooltip.
  """
  attr :kind, :string, required: true
  attr :code, :string, default: nil
  attr :class, :any, default: nil

  def reference(assigns) do
    assigns = assign(assigns, :entry, lookup(assigns.kind, assigns.code))

    ~H"""
    <span :if={@entry} class={["inline-flex items-center gap-1.5", @class]} title={@entry["code"]}>
      <.flag :if={@entry["flag"]} flag={@entry["flag"]} />
      <span>{@entry["label"]}</span>
    </span>
    <span :if={!@entry} class={@class}>{if @code in [nil, ""], do: "—", else: @code}</span>
    """
  end

  attr :flag, :string, required: true

  defp flag(assigns) do
    assigns = assign(assigns, :flag_base, @flag_base)

    ~H"""
    <img
      src={"#{@flag_base}/#{@flag}.svg"}
      alt=""
      loading="lazy"
      class="h-[0.9em] w-auto shrink-0 rounded-[2px] ring-1 ring-base-content/10"
    />
    """
  end

  @doc """
  The picker widget used by `<.input type="country">` (and `"language"`,
  `"currency"`): a button showing the chosen entry, opening a searchable
  list (the `ReferencePicker` hook, data from `/reference/:dataset`). The
  chosen code travels in a hidden input named like the field.
  """
  attr :kind, :string, required: true
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :required, :boolean, default: false
  attr :invalid, :boolean, default: false

  def picker(assigns) do
    lang = Gettext.get_locale(AppWeb.Gettext)
    %{dataset: dataset, maxlength: maxlength} = Map.fetch!(@kinds, assigns.kind)

    assigns =
      assigns
      |> assign(:flag_base, @flag_base)
      |> assign(:source, ~p"/reference/#{dataset}?#{[lang: lang]}")
      |> assign(:maxlength, maxlength)
      |> assign(:texts, texts(assigns.kind))
      |> assign(:value, if(assigns.value in [nil, ""], do: nil, else: to_string(assigns.value)))
      |> assign(:available?, match?({:ok, _}, App.IHDS.list(dataset, lang)))

    ~H"""
    <input
      :if={!@available?}
      type="text"
      id={"#{@id}-button"}
      name={@name}
      value={@value}
      maxlength={@maxlength}
      required={@required}
      class={["input w-full", @invalid && "input-error"]}
    />
    <div
      :if={@available?}
      id={"#{@id}-picker"}
      phx-hook="ReferencePicker"
      data-source={@source}
      data-flag-base={@flag_base}
      data-allow-clear={!@required && "true"}
      data-clear-label={@texts.none}
      data-empty-label={gettext("No matches")}
      data-error-label={gettext("Could not load the list")}
      class="relative"
    >
      <input type="hidden" id={@id} name={@name} value={@value} data-picker-value />
      <button
        type="button"
        id={"#{@id}-button"}
        class={[
          "input w-full justify-between cursor-pointer text-start",
          @invalid && "input-error"
        ]}
        aria-haspopup="listbox"
        aria-expanded="false"
        aria-controls={"#{@id}-panel"}
        data-picker-toggle
      >
        <span data-picker-current class="flex min-w-0 items-center gap-2 truncate">
          <.reference :if={@value} kind={@kind} code={@value} />
          <span :if={!@value} class="opacity-60">{@texts.choose}</span>
        </span>
        <span class="hero-chevron-up-down size-4 shrink-0 opacity-60" aria-hidden="true"></span>
      </button>
      <div
        id={"#{@id}-panel"}
        phx-update="ignore"
        hidden
        data-picker-panel
        class="absolute z-40 mt-1 w-full min-w-64 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg"
      >
        <input
          type="text"
          role="combobox"
          aria-expanded="true"
          aria-autocomplete="list"
          aria-controls={"#{@id}-listbox"}
          aria-label={@texts.search}
          autocomplete="off"
          placeholder={gettext("Name or code, any language")}
          class="input input-sm mb-2 w-full"
          data-picker-search
        />
        <ul
          id={"#{@id}-listbox"}
          role="listbox"
          aria-label={@texts.list}
          class="max-h-64 overflow-y-auto"
          data-picker-list
        >
        </ul>
      </div>
    </div>
    """
  end

  @doc """
  Free text with suggestions from a big dataset (`kind`: `"place"` or
  `"region"`), used by `<.input type="place">` / `"region"`: the text field
  keeps whatever is typed; picking a suggestion also fills the hidden code
  field. Editing the text again clears the code (the text no longer names
  that entry). Below the field, a status line says whether the value is
  linked to a known entry (flag and "raion, region") or kept as text.

  `country_input`: id of a country field whose value narrows the
  suggestions. `region_input`: id of the region text field that picking a
  place fills (text and code) when it is still empty.
  """
  attr :kind, :string, required: true, values: ~w(place region)
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :code_id, :string, required: true
  attr :code_name, :string, required: true
  attr :code_value, :any, default: nil
  attr :country_input, :string, default: nil
  attr :region_input, :string, default: nil
  attr :required, :boolean, default: false
  attr :invalid, :boolean, default: false

  def autocomplete(assigns) do
    lang = Gettext.get_locale(AppWeb.Gettext)
    dataset = if assigns.kind == "place", do: "places", else: "regions"
    code = if assigns.code_value in [nil, ""], do: nil, else: to_string(assigns.code_value)

    assigns =
      assigns
      |> assign(:source, ~p"/reference/#{dataset}/search?#{[lang: lang]}")
      |> assign(:flag_base, @flag_base)
      |> assign(:code_value, code)
      |> assign(:entry, code && App.IHDS.lookup(dataset, code, lang))

    ~H"""
    <div
      id={"#{@id}-auto"}
      phx-hook="ReferenceAutocomplete"
      data-source={@source}
      data-flag-base={@flag_base}
      data-country-input={@country_input}
      data-region-input={@region_input}
      data-empty-label={gettext("No matches — the text is kept as typed")}
      data-error-label={gettext("Suggestions are unavailable")}
      class="relative"
    >
      <input
        type="text"
        id={@id}
        name={@name}
        value={@value}
        role="combobox"
        aria-autocomplete="list"
        aria-expanded="false"
        aria-controls={"#{@id}-listbox"}
        aria-describedby={"#{@id}-status"}
        autocomplete="off"
        required={@required}
        class={["input w-full", @invalid && "input-error"]}
        data-auto-text
      />
      <input type="hidden" id={@code_id} name={@code_name} value={@code_value} data-auto-code />
      <p id={"#{@id}-status"} class="mt-1 flex min-h-4 items-center gap-1 text-xs opacity-70">
        <%= cond do %>
          <% @entry -> %>
            <span class="hero-map-pin size-3.5 shrink-0" aria-hidden="true"></span>
            <.flag :if={@entry["country"]} flag={String.downcase(@entry["country"])} />
            <span class="truncate">
              {[@entry["label"], @entry["context_label"]]
              |> Enum.reject(&is_nil/1)
              |> Enum.join(" · ")}
            </span>
          <% @code_value -> %>
            <span class="hero-map-pin size-3.5 shrink-0" aria-hidden="true"></span>
            <span class="font-mono">{@code_value}</span>
          <% @value not in [nil, ""] -> %>
            <span class="hero-pencil-square size-3.5 shrink-0" aria-hidden="true"></span>
            <span>{gettext("Not from the list — kept as text")}</span>
          <% true -> %>
        <% end %>
      </p>
      <ul
        id={"#{@id}-listbox"}
        role="listbox"
        hidden
        phx-update="ignore"
        class="absolute top-10 z-40 mt-1 max-h-72 w-full min-w-64 overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 shadow-lg"
        data-auto-list
      >
      </ul>
    </div>
    """
  end

  @doc """
  Free text with suggestions from values entered before in `category`
  (`<.input type="suggest">`, JSON Schema `x-suggest`): organisational
  names such as issuing authorities. Nothing is enforced; the suggestions
  only save typing and keep spellings consistent.
  """
  attr :category, :string, required: true
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :required, :boolean, default: false
  attr :invalid, :boolean, default: false

  def suggest(assigns) do
    assigns = assign(assigns, :source, ~p"/reference/learned/#{assigns.category}/search")

    ~H"""
    <div
      id={"#{@id}-auto"}
      phx-hook="ReferenceAutocomplete"
      data-source={@source}
      data-empty-label=""
      data-error-label={gettext("Suggestions are unavailable")}
      class="relative"
    >
      <input
        type="text"
        id={@id}
        name={@name}
        value={@value}
        role="combobox"
        aria-autocomplete="list"
        aria-expanded="false"
        aria-controls={"#{@id}-listbox"}
        autocomplete="off"
        required={@required}
        class={["input w-full", @invalid && "input-error"]}
        data-auto-text
      />
      <ul
        id={"#{@id}-listbox"}
        role="listbox"
        hidden
        phx-update="ignore"
        class="absolute top-10 z-40 mt-1 max-h-72 w-full min-w-64 overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 shadow-lg"
        data-auto-list
      >
      </ul>
    </div>
    """
  end

  defp texts("country"),
    do: %{
      choose: gettext("Choose a country"),
      none: gettext("No country"),
      search: gettext("Search countries"),
      list: gettext("Countries")
    }

  defp texts("language"),
    do: %{
      choose: gettext("Choose a language"),
      none: gettext("No language"),
      search: gettext("Search languages"),
      list: gettext("Languages")
    }

  defp texts("currency"),
    do: %{
      choose: gettext("Choose a currency"),
      none: gettext("No currency"),
      search: gettext("Search currencies"),
      list: gettext("Currencies")
    }

  defp lookup(kind, code) do
    case @kinds[kind] do
      %{dataset: dataset} -> App.IHDS.lookup(dataset, code, Gettext.get_locale(AppWeb.Gettext))
      nil -> nil
    end
  end
end
