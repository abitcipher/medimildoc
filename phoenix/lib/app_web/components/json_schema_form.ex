defmodule AppWeb.JsonSchemaForm do
  @moduledoc """
  Renders `<.input>`s from a JSON Forms-style UI Schema + JSON Schema pair
  (JSON Schema/UI Schema are mandatory for every form) —
  `AppWeb.FormSchemas` for the plain Ash-attribute resources
  (Person/Organization/Position/Assignment), `App.People.PersonRecordSchema`
  for the polymorphic `PersonRecord.data`.

  Two binding modes, picked by which attr is set:

    * `form` — an `AshPhoenix.Form`/`Phoenix.HTML.Form`. Used for the plain
      resources: Ash owns validation/errors, this only decides widget +
      label per field. Only handles top-level (unnested) `scope`s, which is
      all `AppWeb.FormSchemas` ever produces.

    * `values` (a plain, possibly-nested map, e.g. a `PersonRecord.data` in
      progress) + `name` (the top-level param key, e.g. `"record_data"`).
      `PersonRecord.data` is one JSONB attribute, not a set of Ash
      attributes Phoenix's form machinery understands, so field
      names/ids/values here are built by hand from the UI Schema's JSON
      Pointer `scope`s (`record_data[code][text]`) instead. `values` must
      use string keys throughout (matches both `Jason.decode!` output and
      Phoenix's params after a submit round-trip).

  `field_options`, keyed by field name (atom for `form` mode, string for
  `values` mode), overrides the schema-derived widget with a `select`
  listing the given `{label, value}` options — for fields whose valid
  values are data (existing organizations/positions), not something a
  static JSON Schema file can express (`organization_id`, `position_id`,
  `reports_to_id`).

  Only handles `VerticalLayout` + `Control` — every UI Schema this app
  ships is that shape (see `priv/*/*.ui.json`). No arrays, groups, or
  `HorizontalLayout`; extend `element/1` here if a future schema needs one.

  ## Sliders

  A numeric field whose schema declares BOTH `minimum` and `maximum`
  renders as a slider (`AppWeb.Components.RangeField`, Mishka Chelekom)
  instead of a plain `<input type="number">` — "wherever logical", per
  the user's brief, is read here as "the range is actually bounded on
  both ends". An unbounded numeric field (e.g. `compensation.amount` —
  no sane upper bound on a payment) stays a plain number input; adding a
  `maximum` to a schema is therefore also an explicit UI decision, not
  just a validation tweak (see `family_status.schema.json`'s
  `dependentsCount`, given a practical `maximum` for exactly this reason).

  ## Reference data (docs/design/reference-data-and-files.md)

  A string field with `"x-reference"` stores a code and renders as a
  picker: `"country"` (ISO 3166-1 alpha-2, with flags), `"language"`
  (ISO 639-1), `"currency"` (ISO 4217) — names in the user's language,
  searchable in any language, `<.input type="country">` etc.

  `"place"` and `"region"` are free text with suggestions: the schema
  property names its sibling code field (`x-code-field`), and optionally
  the country field narrowing suggestions (`x-country-field`) and, for a
  place, the region field it fills (`x-region-field`). Form mode only.

  `"x-format": "date-time"` (with a `pattern` for `yyyy-mm-ddTHH:MM`) is a
  local date and time, typed as dd.mm.yyyy HH:MM; `"x-widget": "number"`
  keeps a bounded number as a typed field instead of a slider.

  Layouts: besides `Control`, JSON Forms `Group` (a titled, collapsible
  section; `"options": {"collapsed": true}`) and `HorizontalLayout`
  (side by side from `sm` up; `"options": {"widths": [2, 1]}`).

  An array of choices (`"type": "array"`, `"items": {"enum": [...]}`)
  renders as toggle chips, one checkbox each (`<.input type="tags">`).

  A string field with `"x-suggest-list": "drugs"` is free text with a
  fixed list of suggestions (`App.Clinical.Drugs`, in the user's language),
  `<.input type="datalist">`.

  A string field with `"x-suggest": "<category>"` is free text with
  suggestions from values saved before in that category (learned by IHDS,
  `App.People.Changes.LearnSuggestedValues`); both modes.

  ## Field help (docs/design/ui-plan.md)

  A field whose schema property has an `x-help` text gets an "i" icon next
  to its label showing that text as a tooltip
  (`AppWeb.CoreComponents.field_description/1`). The property's
  `description` is developer documentation and is not shown. Labels,
  help and choice values are translated through `AppWeb.SchemaText`.
  """
  use Phoenix.Component
  use Gettext, backend: AppWeb.Gettext

  import AppWeb.CoreComponents, only: [input: 1, field_description: 1]

  alias App.Clinical.Drugs
  alias AppWeb.Components.RangeField, as: MishkaRangeField

  # `x-reference` values with a picker (AppWeb.ReferenceComponents), and
  # those with free text plus suggestions and a code field.
  @reference_kinds ~w(country language currency)
  @autocomplete_kinds ~w(place region)

  attr :schema, :map, required: true
  attr :ui_schema, :map, required: true
  attr :form, Phoenix.HTML.Form, default: nil
  attr :values, :map, default: nil
  attr :name, :string, default: nil
  attr :field_options, :map, default: %{}

  def json_schema_form(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <.element
        :for={element <- @ui_schema["elements"] || []}
        element={element}
        schema={@schema}
        form={@form}
        values={@values}
        name={@name}
        field_options={@field_options}
      />
    </div>
    """
  end

  attr :element, :map, required: true
  attr :schema, :map, required: true
  attr :form, Phoenix.HTML.Form, default: nil
  attr :values, :map, default: nil
  attr :name, :string, default: nil
  attr :field_options, :map, default: %{}

  # JSON Forms "Group": a titled section of elements, collapsible
  # (`"options": {"collapsed": true}` starts it closed).
  defp element(%{element: %{"type" => "Group"}} = assigns) do
    ~H"""
    <details
      class="rounded-box border border-base-300 bg-base-100 px-3 py-2"
      open={get_in(@element, ["options", "collapsed"]) != true}
    >
      <summary class="cursor-pointer select-none py-1 font-medium">
        {AppWeb.SchemaText.translate(@element["label"])}
      </summary>
      <div class="flex flex-col gap-2 pt-2">
        <.element
          :for={child <- @element["elements"] || []}
          element={child}
          schema={@schema}
          form={@form}
          values={@values}
          name={@name}
          field_options={@field_options}
        />
      </div>
    </details>
    """
  end

  # JSON Forms "HorizontalLayout": side by side from `sm` up, stacked on a
  # phone; `"options": {"widths": [2, 1]}` gives relative widths (up to 4
  # columns in all).
  defp element(%{element: %{"type" => "HorizontalLayout"}} = assigns) do
    children = assigns.element["elements"] || []
    widths = get_in(assigns.element, ["options", "widths"]) || List.duplicate(1, length(children))

    assigns =
      assign(assigns,
        columns: grid_columns(Enum.sum(widths)),
        children: Enum.zip(children, Enum.map(widths, &column_span/1))
      )

    ~H"""
    <div class={["grid grid-cols-1 gap-x-3", @columns]}>
      <div :for={{child, span} <- @children} class={span}>
        <.element
          element={child}
          schema={@schema}
          form={@form}
          values={@values}
          name={@name}
          field_options={@field_options}
        />
      </div>
    </div>
    """
  end

  defp element(%{element: %{"type" => "Control"}} = assigns) do
    path = scope_path(assigns.element["scope"])
    field_schema = resolve_schema(assigns.schema, path)
    multi? = get_in(assigns.element, ["options", "multi"]) == true
    parent_schema = resolve_schema(assigns.schema, Enum.drop(path, -1)) || %{}
    required? = List.last(path) in (parent_schema["required"] || [])
    label = AppWeb.SchemaText.translate(assigns.element["label"] || humanize(List.last(path)))

    assigns =
      assigns
      |> assign(:path, path)
      |> assign(:required?, required?)
      # Required fields are marked with an asterisk (and the input carries
      # `required`), the common convention users recognise.
      |> assign(:label, if(required?, do: label <> " *", else: label))
      |> assign(:field_schema, field_schema)
      |> assign(:multi?, multi?)

    ~H"""
    <.form_bound_input
      :if={@form}
      form={@form}
      path={@path}
      label={@label}
      field_schema={@field_schema}
      multi?={@multi?}
      field_options={@field_options}
      required?={@required?}
    />
    <.value_bound_input
      :if={@values}
      values={@values}
      name={@name}
      path={@path}
      label={@label}
      field_schema={@field_schema}
      multi?={@multi?}
      field_options={@field_options}
      required?={@required?}
    />
    """
  end

  # AppWeb.FormSchemas only ever produces single-segment scopes (plain Ash
  # attributes), so `hd(path)` is safe here.
  attr :form, Phoenix.HTML.Form, required: true
  attr :path, :list, required: true
  attr :label, :string, required: true
  attr :field_schema, :map, default: nil
  attr :multi?, :boolean, required: true
  attr :field_options, :map, required: true
  attr :required?, :boolean, default: false

  defp form_bound_input(assigns) do
    field_name = path_atom(hd(assigns.path))
    options = Map.get(assigns.field_options, field_name)

    assigns =
      assigns
      |> assign(:field, assigns.form[field_name])
      |> assign(:options, options)
      |> assign(:prompt, select_prompt(options, assigns.field_schema, assigns.required?))
      |> assign(:input_type, input_type(assigns.field_schema, assigns.multi?, options))
      |> assign(:description, description(assigns.field_schema))
      |> assign(reference_links(assigns.form, assigns.field_schema))

    ~H"""
    <.range_input
      :if={@input_type == "range"}
      field={@field}
      label={@label}
      description={@description}
      field_schema={@field_schema}
    />
    <.input
      :if={@input_type != "range"}
      field={@field}
      type={@input_type}
      label={@label}
      description={@description}
      options={@options || enum_options(@field_schema) || suggest_list(@field_schema)}
      prompt={@prompt}
      required={@required?}
      min={@field_schema["minimum"]}
      max={@field_schema["maximum"]}
      step={step(@field_schema)}
      code_field={@code_field}
      country_input={@country_input}
      region_input={@region_input}
      suggest={@field_schema["x-suggest"]}
    />
    """
  end

  attr :values, :map, required: true
  attr :name, :string, required: true
  attr :path, :list, required: true
  attr :label, :string, required: true
  attr :field_schema, :map, default: nil
  attr :multi?, :boolean, required: true
  attr :field_options, :map, required: true
  attr :required?, :boolean, default: false

  defp value_bound_input(assigns) do
    options = Map.get(assigns.field_options, Enum.join(assigns.path, "."))

    assigns =
      assigns
      |> assign(:field_id, html_id(assigns.name, assigns.path))
      |> assign(:field_name, html_name(assigns.name, assigns.path))
      |> assign(:field_value, get_in(assigns.values, assigns.path))
      |> assign(:options, options)
      |> assign(:prompt, select_prompt(options, assigns.field_schema, assigns.required?))
      |> assign(:input_type, input_type(assigns.field_schema, assigns.multi?, options))
      |> assign(:description, description(assigns.field_schema))

    ~H"""
    <.range_input
      :if={@input_type == "range"}
      id={@field_id}
      name={@field_name}
      value={@field_value}
      label={@label}
      description={@description}
      field_schema={@field_schema}
    />
    <.input
      :if={@input_type != "range"}
      id={@field_id}
      name={@field_name}
      value={@field_value}
      type={@input_type}
      label={@label}
      description={@description}
      options={@options || enum_options(@field_schema) || suggest_list(@field_schema)}
      prompt={@prompt}
      required={@required?}
      min={@field_schema["minimum"]}
      max={@field_schema["maximum"]}
      step={step(@field_schema)}
      suggest={@field_schema["x-suggest"]}
    />
    """
  end

  # Dual-mode like `.input` itself: `field` (form mode) or `id`+`name`+
  # `value` (values mode). Renders its own label + `field_description/1`
  # (not through `.input`, which has no "range" type — see moduledoc)
  # then a native `<input type="range">` (`AppWeb.Components.RangeField`)
  # bounded by the schema's own `minimum`/`maximum`. `step` is "1" for an
  # integer-typed field (every current bounded numeric field is one —
  # STANAG 6001 SLP scores, dependentsCount), else the schema's
  # `multipleOf` if given, else "any" (free continuous drag).
  attr :field, Phoenix.HTML.FormField, default: nil
  attr :id, :any, default: nil
  attr :name, :any, default: nil
  attr :value, :any, default: nil
  attr :label, :string, required: true
  attr :description, :string, default: nil
  attr :field_schema, :map, required: true

  defp range_input(assigns) do
    step =
      case assigns.field_schema do
        %{"type" => "integer"} -> "1"
        %{"multipleOf" => m} -> to_string(m)
        _ -> "any"
      end

    assigns =
      assigns
      |> assign(:min, assigns.field_schema["minimum"])
      |> assign(:max, assigns.field_schema["maximum"])
      |> assign(:step, step)

    ~H"""
    <div class="fieldset mb-2">
      <span class="label mb-1">
        {@label}
        <.field_description description={@description} />
      </span>
      <MishkaRangeField.range_field
        :if={@field}
        field={@field}
        min={@min}
        max={@max}
        step={@step}
      >
        <:range_value position="middle">{@field.value}</:range_value>
      </MishkaRangeField.range_field>
      <MishkaRangeField.range_field
        :if={!@field}
        id={@id}
        name={@name}
        value={@value}
        min={@min}
        max={@max}
        step={@step}
      >
        <:range_value position="middle">{@value}</:range_value>
      </MishkaRangeField.range_field>
    </div>
    """
  end

  # Free text with a code (`x-reference` place/region): the schema names
  # the sibling fields — `x-code-field` stores the code, `x-country-field`
  # narrows suggestions, `x-region-field` is filled when a place is picked.
  defp reference_links(form, field_schema) do
    sibling = fn key -> (name = field_schema[key]) && form[path_atom(name)] end
    country = sibling.("x-country-field")
    region = sibling.("x-region-field")

    %{
      code_field: sibling.("x-code-field"),
      country_input: country && country.id,
      region_input: region && region.id
    }
  end

  # A `field_options`-driven select (an existing-row picker: organizations,
  # positions, ...) has no schema-derived "correct" value to fall back to —
  # unlike an `enum`-driven select, where the first listed option is a real,
  # intentional choice. Without an explicit blank option, a native <select>
  # with no matching value silently *displays* (and, unless the user
  # notices and changes it, *submits*) whatever option happens to be first.
  # Confirmed live: editing a Position whose reports_to_id was nil, without
  # touching that field, silently set it to the first listed position — in
  # that case, itself. A prompt makes "nothing chosen" an explicit,
  # submittable state instead.
  # An empty first entry for any select that may be left unset: injected
  # option lists (see above) and optional choice fields. Without it an
  # optional choice silently takes its first value — an allergy nobody
  # assessed would be saved with criticality "low".
  defp select_prompt(options, _field_schema, _required?) when not is_nil(options),
    do: gettext("— select —")

  defp select_prompt(nil, %{"enum" => [_ | _]}, false), do: gettext("— select —")
  defp select_prompt(nil, _field_schema, _required?), do: nil

  # "#/properties/code/properties/text" -> ["code", "text"]
  defp scope_path("#/properties/" <> rest), do: String.split(rest, "/properties/")

  defp resolve_schema(schema, path) do
    Enum.reduce(path, schema, fn
      _key, nil -> nil
      key, acc -> get_in(acc, ["properties", key])
    end)
  end

  # Literal class names, so Tailwind finds them.
  defp grid_columns(2), do: "sm:grid-cols-2"
  defp grid_columns(3), do: "sm:grid-cols-3"
  defp grid_columns(4), do: "sm:grid-cols-4"
  defp grid_columns(_total), do: ""

  defp column_span(2), do: "sm:col-span-2"
  defp column_span(3), do: "sm:col-span-3"
  defp column_span(_width), do: ""

  defp input_type(_field_schema, _multi?, options) when is_list(options), do: "select"

  defp input_type(%{"type" => "array", "items" => %{"enum" => [_ | _]}}, _multi?, _options),
    do: "tags"

  defp input_type(%{"x-suggest" => category}, _multi?, _options) when is_binary(category),
    do: "suggest"

  defp input_type(%{"x-suggest-list" => list}, _multi?, _options) when is_binary(list),
    do: "datalist"

  defp input_type(%{"x-reference" => kind}, _multi?, _options)
       when kind in @reference_kinds or kind in @autocomplete_kinds,
       do: kind

  defp input_type(%{"enum" => _}, _multi?, _options), do: "select"
  defp input_type(_field_schema, true, _options), do: "textarea"
  defp input_type(%{"type" => "boolean"}, _multi?, _options), do: "checkbox"

  # A bounded number that is typed rather than dragged (vital signs).
  defp input_type(%{"x-widget" => "number"}, _multi?, _options), do: "number"

  # A slider only when BOTH ends are bounded — an unbounded numeric field
  # (no maximum, e.g. a currency amount) stays a plain number input, see
  # moduledoc "Sliders".
  defp input_type(
         %{"type" => type, "minimum" => min, "maximum" => max},
         _multi?,
         _options
       )
       when type in ["integer", "number"] and is_number(min) and is_number(max),
       do: "range"

  defp input_type(%{"type" => type}, _multi?, _options) when type in ["integer", "number"],
    do: "number"

  defp input_type(%{"format" => "date"}, _multi?, _options), do: "date"

  # Local date and time (JSON Schema's own "date-time" needs a time zone).
  defp input_type(%{"x-format" => "date-time"}, _multi?, _options), do: "datetime-local"
  defp input_type(%{"format" => "email"}, _multi?, _options), do: "email"
  defp input_type(_field_schema, _multi?, _options), do: "text"

  # Number inputs: whole numbers step by 1, others by `multipleOf` or freely.
  defp step(%{"type" => "integer"}), do: "1"
  defp step(%{"type" => "number", "multipleOf" => m}), do: to_string(m)
  defp step(%{"type" => "number"}), do: "any"
  defp step(_field_schema), do: nil

  # Tooltip text: the user-facing `x-help` only. A property's JSON Schema
  # `description` is developer documentation (standards notes) and is never shown to users.
  # A fixed suggestion list named by `x-suggest-list`, in the user's language.
  defp suggest_list(%{"x-suggest-list" => "drugs"}),
    do: Drugs.names(Gettext.get_locale(AppWeb.Gettext))

  defp suggest_list(_field_schema), do: nil

  defp description(%{"x-help" => help}), do: AppWeb.SchemaText.translate(help)
  defp description(_field_schema), do: nil

  defp enum_options(%{"enum" => values} = field_schema),
    do: Enum.map(values, &{AppWeb.SchemaText.choice(&1, field_schema["x-enum-labels"]), &1})

  # A list of choices (tags): the choices are in `items`, their labels on
  # the property itself.
  defp enum_options(%{"items" => %{"enum" => values}} = field_schema),
    do: Enum.map(values, &{AppWeb.SchemaText.choice(&1, field_schema["x-enum-labels"]), &1})

  defp enum_options(_field_schema), do: nil

  # `to_existing_atom` looked appealing here (the segment always names a
  # real Ash attribute in `form` mode) but isn't actually safe: nothing
  # guarantees the owning resource module has been *loaded* yet (loading,
  # not just compiling, is what registers its attribute names as atoms) —
  # confirmed by a real intermittent failure in
  # test/app_web/components/json_schema_form_test.exs, order-dependent on
  # what else happened to load `App.People.Person` first. `to_atom` is fine
  # instead: the input is our own small, fixed set of `priv/form_schemas/`
  # JSON files, not user input, so there's no unbounded-atom-creation risk.
  defp path_atom(segment), do: String.to_atom(segment)

  defp html_id(name, path), do: Enum.join([name | path], "_")
  defp html_name(name, [head]), do: "#{name}[#{head}]"
  defp html_name(name, [head | rest]), do: "#{name}[#{head}]" <> Enum.map_join(rest, &"[#{&1}]")

  defp humanize(nil), do: nil

  defp humanize(term) do
    term
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
