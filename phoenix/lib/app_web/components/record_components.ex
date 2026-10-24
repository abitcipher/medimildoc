defmodule AppWeb.RecordComponents do
  @moduledoc """
  Readable rendering of `PersonRecord`s (docs/design/ui-plan.md items 1, 2,
  4 and 5): each record is a card with its kind's icon and name, the date,
  its security labels, and its fields as label/value pairs in the order of
  the kind's UI Schema. Field and kind names, help texts and choice values
  are translated through `AppWeb.SchemaText`.

  Classified records carry a NATO marking band above and below the card,
  in the app's current colours (ui-plan item 4: a selectable colour scheme
  is future work).
  """
  use Phoenix.Component
  use Gettext, backend: AppWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: AppWeb.Endpoint,
    router: AppWeb.Router,
    statics: AppWeb.static_paths()

  import AppWeb.CoreComponents, only: [icon: 1]

  require Ash.Query

  alias App.Clinical.{AllergyCheck, Vitals}
  alias App.Clinical.Changes.CodeMedication
  alias App.People.PersonRecordSchema
  alias AppWeb.{FormPanels, JsonSchemaForm, SchemaText}

  @category_order [
    :personnel,
    :personnel_private,
    :readiness,
    :care,
    :medical,
    :clearance,
    :vetting
  ]

  @doc "Record categories in display order."
  @spec categories() :: [atom()]
  def categories, do: @category_order

  @doc "Translated name of a record category."
  @spec category_label(atom()) :: String.t()
  def category_label(:personnel), do: gettext("Personnel")
  def category_label(:personnel_private), do: gettext("Pay & family")
  def category_label(:readiness), do: gettext("Readiness")
  def category_label(:clearance), do: gettext("Clearance")
  def category_label(:care), do: gettext("Point of care")
  def category_label(:medical), do: gettext("Medical")
  def category_label(:vetting), do: gettext("Vetting")

  @doc "Icon of a record category."
  @spec category_icon(atom()) :: String.t()
  def category_icon(:personnel), do: "hero-identification"
  def category_icon(:personnel_private), do: "hero-home"
  def category_icon(:readiness), do: "hero-check-badge"
  def category_icon(:clearance), do: "hero-shield-check"
  def category_icon(:care), do: "hero-plus-circle"
  def category_icon(:medical), do: "hero-heart"
  def category_icon(:vetting), do: "hero-finger-print"

  @doc "Translated name of a record kind."
  @spec kind_label(atom()) :: String.t()
  def kind_label(kind), do: kind |> PersonRecordSchema.label() |> SchemaText.translate()

  @doc "NATO marking as written on documents, e.g. \"NATO RESTRICTED\"."
  @spec marking(atom()) :: String.t()
  def marking(classification),
    do: classification |> to_string() |> String.replace("_", " ") |> String.upcase()

  @doc "Translated name of an HL7 v3 confidentiality code."
  @spec confidentiality_label(atom()) :: String.t()
  def confidentiality_label(:u), do: gettext("Unrestricted")
  def confidentiality_label(:l), do: gettext("Low")
  def confidentiality_label(:m), do: gettext("Moderate")
  def confidentiality_label(:n), do: gettext("Normal")
  def confidentiality_label(:r), do: gettext("Restricted")
  def confidentiality_label(:v), do: gettext("Very restricted")

  @doc "A classified-content marking band (NATO style), current palette."
  attr :classification, :atom, required: true

  def marking_band(assigns) do
    ~H"""
    <div
      role="note"
      class="bg-warning text-warning-content text-center text-[0.7rem] font-bold tracking-[0.2em] py-0.5"
    >
      {marking(@classification)}
    </div>
    """
  end

  @doc """
  One record as a card. `writable` shows the edit and delete buttons
  (the resource policy is still what decides).
  """
  attr :record, :map, required: true
  attr :writable, :boolean, default: false

  def record_card(assigns) do
    assigns =
      assigns
      |> assign(:fields, filled_fields(assigns.record))
      |> assign(vitals_assessment(assigns.record))

    ~H"""
    <article
      id={"record-#{@record.id}"}
      class="rounded-box border border-base-300 bg-base-100 overflow-hidden"
    >
      <.marking_band :if={@record.classification} classification={@record.classification} />
      <header class="flex items-start gap-3 p-3">
        <span class="grid size-9 shrink-0 place-items-center rounded-full bg-base-200">
          <.icon name={PersonRecordSchema.icon(@record.kind)} class="size-5" />
        </span>
        <div class="min-w-0 grow">
          <h3 class="flex flex-wrap items-center gap-2 font-medium leading-tight">
            {kind_label(@record.kind)}
            <.news2_badge :if={@news2} result={@news2} />
          </h3>
          <p class="text-xs opacity-70">
            <time datetime={record_date(@record)}>
              {AppWeb.DateFormat.display(record_date(@record))}
            </time>
            <span :if={part_of(@record)}>
              · {gettext("part of %{record}", record: part_of_label(part_of(@record)))}
            </span>
          </p>
        </div>
        <span
          class="tooltip tooltip-left badge badge-sm badge-outline font-mono shrink-0"
          data-tip={
            gettext("Confidentiality: %{level}",
              level: confidentiality_label(@record.confidentiality)
            )
          }
          aria-label={
            gettext("Confidentiality: %{level}",
              level: confidentiality_label(@record.confidentiality)
            )
          }
        >
          {@record.confidentiality |> to_string() |> String.upcase()}
        </span>
        <div :if={@writable} class="flex shrink-0 gap-1">
          <button
            type="button"
            phx-click="edit_record"
            phx-value-id={@record.id}
            class="tooltip tooltip-left btn btn-ghost btn-xs btn-square"
            data-tip={gettext("Edit")}
            aria-label={gettext("Edit %{kind}", kind: kind_label(@record.kind))}
          >
            <.icon name="hero-pencil-square" class="size-4" />
          </button>
          <button
            type="button"
            phx-click="delete_record"
            phx-value-id={@record.id}
            data-confirm={gettext("Remove this record?")}
            class="tooltip tooltip-left btn btn-ghost btn-xs btn-square text-error"
            data-tip={gettext("Delete")}
            aria-label={gettext("Delete %{kind}", kind: kind_label(@record.kind))}
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </div>
      </header>
      <p
        :for={{label, text} <- alerts(@record)}
        role="alert"
        class="mx-3 mb-3 flex items-start gap-2 rounded-box bg-warning/15 px-3 py-2 text-sm"
      >
        <.icon name="hero-exclamation-triangle" class="size-4 shrink-0 text-warning" />
        <span><span class="font-medium">{SchemaText.translate(label)}:</span> {text}</span>
      </p>
      <dl
        :if={@fields != []}
        class="grid grid-cols-1 gap-x-6 gap-y-2 px-3 pb-3 text-sm sm:grid-cols-2"
      >
        <div :for={{field, value} <- @fields} class={field.multi && "sm:col-span-2"}>
          <dt class="flex items-center gap-1 text-xs opacity-70">
            {SchemaText.translate(field.label)}
            <span
              :if={field.help}
              class="tooltip tooltip-right"
              data-tip={SchemaText.translate(field.help)}
            >
              <.icon name="hero-information-circle" class="size-3.5" />
            </span>
          </dt>
          <dd class={["break-words", field.multi && "whitespace-pre-line"]}>
            <AppWeb.ReferenceComponents.reference
              :if={field.reference}
              kind={field.reference}
              code={value}
            />
            <span
              :if={!field.reference}
              class={@flags[hd(field.path)] && "font-semibold text-error"}
            >
              {format_value(field, value)}
              <.flag_mark flag={@flags[hd(field.path)]} />
            </span>
          </dd>
        </div>
      </dl>
      <ul
        :if={files(@record) != []}
        class="flex flex-wrap gap-1.5 px-3 pb-3"
        aria-label={gettext("Files")}
      >
        <li :for={file <- files(@record)}>
          <a
            href={
              ~p"/files/#{file.id}?#{[inline: if(App.People.Files.inline?(file.content_type), do: "1", else: "0")]}"
            }
            target="_blank"
            rel="noopener"
            class="badge badge-outline gap-1 hover:badge-primary"
          >
            <.icon name="hero-paper-clip" class="size-3.5" />
            <span class="max-w-48 truncate">{file.file_name}</span>
          </a>
        </li>
      </ul>
      <.marking_band :if={@record.classification} classification={@record.classification} />
    </article>
    """
  end

  @doc """
  While a medication is being entered: a warning when the drug matches one
  of the person's recorded allergies (`App.Clinical.AllergyCheck`;
  docs/design/clinical-medications.md). Saving stays possible; the record
  notes the match. `allergies` are the allergy records the viewer can read.
  """
  attr :kind, :atom, required: true
  attr :data, :map, required: true
  attr :allergies, :list, required: true

  def medication_allergy_warning(assigns) do
    matches =
      if CodeMedication.medication_kind?(assigns.kind),
        do:
          AllergyCheck.matches(
            get_in(assigns.data, ["medication", "text"]),
            Enum.map(assigns.allergies, & &1.data)
          ),
        else: []

    assigns = assign(assigns, :matches, matches)

    ~H"""
    <div
      :if={@matches != []}
      id="medication-allergy-warning"
      role="alert"
      class="alert alert-warning mb-2 text-sm"
    >
      <.icon name="hero-exclamation-triangle" class="size-5" />
      <div>
        <p class="font-semibold">{gettext("This drug matches a recorded allergy")}</p>
        <ul>
          <li :for={match <- @matches}>
            {AllergyCheck.describe(match)}
            <span :if={match.criticality == "high"} class="badge badge-error badge-sm">
              {gettext("high risk")}
            </span>
          </li>
        </ul>
        <p class="text-xs opacity-80">
          {gettext("You can still save; the record will show this warning.")}
        </p>
      </div>
    </div>
    """
  end

  @doc """
  Kinds the actor may add, grouped by category, as tiles: icon, name and
  a one-line summary. Clicking one sends `select_record_kind`.
  """
  attr :kinds, :list, required: true

  def kind_picker(assigns) do
    groups =
      @category_order
      |> Enum.map(fn category ->
        {category, Enum.filter(assigns.kinds, &(PersonRecordSchema.category(&1) == category))}
      end)
      |> Enum.reject(fn {_category, kinds} -> kinds == [] end)

    assigns = assign(assigns, :groups, groups)

    ~H"""
    <div class="flex flex-col gap-4">
      <section :for={{category, kinds} <- @groups}>
        <h4 class="mb-2 flex items-center gap-2 text-xs font-semibold uppercase tracking-wide opacity-70">
          <.icon name={category_icon(category)} class="size-4" />
          {category_label(category)}
        </h4>
        <div class="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-3">
          <button
            :for={kind <- kinds}
            type="button"
            phx-click="select_record_kind"
            phx-value-kind={kind}
            class="flex items-start gap-3 rounded-box border border-base-300 p-3 text-left hover:border-primary hover:bg-base-200 focus-visible:outline-2 focus-visible:outline-primary"
          >
            <.icon name={PersonRecordSchema.icon(kind)} class="mt-0.5 size-5 shrink-0" />
            <span>
              <span class="block font-medium">{kind_label(kind)}</span>
              <span class="block text-xs opacity-70">
                {kind |> PersonRecordSchema.summary() |> SchemaText.translate()}
              </span>
            </span>
          </button>
        </div>
      </section>
    </div>
    """
  end

  defp record_date(record) do
    (record.effective_on || DateTime.to_date(record.recorded_at)) |> Date.to_iso8601()
  end

  @doc """
  A record's fields with a value, in UI Schema order (`[{field, value}]`);
  a number with a unit field (a dose) shows that unit — the record card's,
  also the sheet's Record card (SHEETS-UI.3).
  """
  @spec filled_fields(map()) :: [{map(), term()}]
  def filled_fields(record) do
    data = record.data || %{}

    for field <- PersonRecordSchema.fields(record.kind),
        field.card?,
        value = get_in(data, field.path),
        value not in [nil, ""],
        do: {with_unit(field, data), value}
  end

  defp with_unit(%{unit_field: {path, labels}} = field, data) do
    case get_in(data, path) do
      nil -> field
      unit -> %{field | unit: SchemaText.choice(unit, labels)}
    end
  end

  defp with_unit(field, _data), do: field

  # Warnings the server noted on the record (`x-system: "alert"`).
  defp alerts(record) do
    for {key, label} <- PersonRecordSchema.alert_fields(record.kind),
        value = (record.data || %{})[key],
        value not in [nil, ""],
        do: {label, value}
  end

  @vital_rows ~w(systolic diastolic heartRate respiratoryRate spo2 temperature gcs pain)

  @doc """
  The latest vital signs of a person with their trends
  (docs/design/clinical-module.md): each parameter's latest value, flagged
  when outside its normal band, next to a sparkline of the recent sets;
  NEWS2 of the latest set. `vitals` are records, newest first
  (`AppWeb.PersonSummary`), already read through the policies.
  """
  attr :vitals, :list, required: true

  def vitals_panel(assigns) do
    latest = hd(assigns.vitals)
    chronological = Enum.reverse(assigns.vitals)
    fields = Map.new(PersonRecordSchema.fields(:vital_signs), &{hd(&1.path), &1})
    flags = Vitals.flags(latest.data)

    rows =
      for key <- @vital_rows,
          field = fields[key],
          series = for(r <- chronological, is_number(r.data[key]), do: r.data[key]),
          series != [] do
        %{
          key: key,
          label: SchemaText.translate(field.label),
          unit: field.unit,
          latest: latest.data[key],
          series: series,
          band: Vitals.normal_band(key),
          flag: flags[key]
        }
      end

    assigns =
      assign(assigns,
        latest: latest,
        rows: rows,
        news2: Vitals.news2(latest.data),
        count: length(assigns.vitals)
      )

    ~H"""
    <section
      id="vitals-panel"
      class="rounded-box border border-base-300 bg-base-100 p-3"
      aria-labelledby="vitals-panel-heading"
    >
      <h3 id="vitals-panel-heading" class="mb-2 flex flex-wrap items-center gap-2 font-semibold">
        <.icon name="hero-chart-bar" class="size-5" /> {gettext("Vital signs")}
        <.news2_badge result={@news2} />
        <span class="text-xs font-normal opacity-60">
          {AppWeb.DateFormat.display_datetime(@latest.data["measuredAt"])} · {ngettext(
            "%{count} set",
            "%{count} sets",
            @count
          )}
        </span>
      </h3>
      <table class="w-full text-sm">
        <tbody>
          <tr :for={row <- @rows} class="border-b border-base-200 last:border-b-0">
            <th scope="row" class="py-1 pe-2 text-start font-normal opacity-70">{row.label}</th>
            <td class={["py-1 pe-2 text-end tabular-nums", row.flag && "font-semibold text-error"]}>
              {if(is_nil(row.latest), do: "—", else: row.latest)}
              <span :if={row.unit && row.latest} class="text-xs opacity-60">{row.unit}</span>
              <.flag_mark flag={row.flag} />
            </td>
            <td class="w-24 py-1">
              <AppWeb.Sparkline.sparkline values={row.series} band={row.band} flag={row.flag} />
            </td>
          </tr>
        </tbody>
      </table>
      <p class="mt-2 text-xs opacity-60">
        {gettext(
          "Shaded: normal adult range (NEWS2 zero-score band). Supports clinical judgement; not a diagnosis."
        )}
      </p>
    </section>
    """
  end

  @doc """
  For a record kind that can belong to another record (`x-part-of`, e.g.
  vital signs within an encounter): a select of the person's records of
  those kinds, newest first. `options` from `part_of_options/3`.
  """
  attr :options, :list, required: true
  attr :value, :any, default: nil

  def part_of_select(assigns) do
    ~H"""
    <label :if={@options != []} class="fieldset mb-2">
      <span class="label mb-1">{gettext("Part of")}</span>
      <select name="record_part_of" class="select w-full">
        <option value="">{gettext("— none —")}</option>
        <option :for={{label, id} <- @options} value={id} selected={id == @value}>{label}</option>
      </select>
    </label>
    """
  end

  @doc """
  `{label, id}` of the records of `person` that a new record of `kind` may
  belong to, read as `actor` (so only readable ones), newest first.
  """
  @spec part_of_options(map(), atom() | nil, map()) :: [{String.t(), String.t()}]
  def part_of_options(_person, nil, _actor), do: []

  def part_of_options(person, kind, actor) do
    case PersonRecordSchema.part_of(kind) do
      [] ->
        []

      parents ->
        App.People.PersonRecord
        |> Ash.Query.filter(person_id == ^person.id and kind in ^parents)
        |> Ash.Query.sort(recorded_at: :desc)
        |> Ash.read!(actor: actor)
        |> Enum.sort_by(&(&1.data["start"] || ""), :desc)
        |> Enum.map(&{part_of_label(&1), &1.id})
    end
  end

  # Vital signs: out-of-range flags and NEWS2 (App.Clinical.Vitals).
  defp vitals_assessment(%{kind: :vital_signs, data: %{} = data}),
    do: %{flags: Vitals.flags(data), news2: Vitals.news2(data)}

  defp vitals_assessment(_record), do: %{flags: %{}, news2: nil}

  attr :flag, :atom, default: nil

  defp flag_mark(%{flag: nil} = assigns), do: ~H""

  defp flag_mark(assigns) do
    ~H"""
    <.icon
      name={if @flag == :high, do: "hero-arrow-up", else: "hero-arrow-down"}
      class="size-3.5"
    />
    <span class="sr-only">
      {if @flag == :high, do: gettext("(above normal)"), else: gettext("(below normal)")}
    </span>
    """
  end

  attr :result, :any, required: true

  defp news2_badge(%{result: {:ok, %{score: score, risk: risk}}} = assigns) do
    assigns = assign(assigns, score: score, risk: risk)

    ~H"""
    <span
      class={["badge badge-sm", AppWeb.PersonSummary.risk_tone(@risk)]}
      data-float-tip={AppWeb.PersonSummary.risk_label(@risk)}
      aria-label={"NEWS2 #{@score}: " <> AppWeb.PersonSummary.risk_label(@risk)}
    >
      NEWS2 {@score}
    </span>
    """
  end

  defp news2_badge(assigns) do
    ~H"""
    <span
      class="badge badge-sm badge-ghost"
      data-float-tip={gettext("NEWS2 needs all seven parameters")}
    >
      NEWS2 —
    </span>
    """
  end

  defp part_of(%{part_of: %{kind: _} = parent}), do: parent
  defp part_of(_record), do: nil

  # "Encounter · 27.09.2026 14:05"
  defp part_of_label(record) do
    started = record.data && (record.data["start"] || record.data["measuredAt"])

    Enum.join(
      Enum.reject(
        [kind_label(record.kind), started && AppWeb.DateFormat.display_datetime(started)],
        &is_nil/1
      ),
      " · "
    )
  end

  defp files(%{attachments: files}) when is_list(files), do: files
  defp files(_record), do: []

  @doc "A field's value as the record card shows it."
  @spec format_value(map(), term()) :: String.t()
  def format_value(%{enum: [_ | _]} = field, values) when is_list(values),
    do: Enum.map_join(values, ", ", &SchemaText.choice(&1, field.enum_labels))

  def format_value(%{enum: [_ | _]} = field, value),
    do: SchemaText.choice(value, field.enum_labels)

  def format_value(_field, true), do: gettext("Yes")
  def format_value(_field, false), do: gettext("No")
  def format_value(%{format: "date"}, value), do: AppWeb.DateFormat.display(value)
  def format_value(%{format: "date-time"}, value), do: AppWeb.DateFormat.display_datetime(value)

  def format_value(%{unit: unit}, value) when is_binary(unit) and is_number(value),
    do: "#{value} #{unit}"

  def format_value(_field, value), do: to_string(value)

  @doc """
  The record form (new or edit) in a panel shown as the viewer's interface
  settings say (`AppWeb.FormPanels`): the parent record, the kind's fields,
  an allergy warning for medications, errors, Save and Cancel. Events
  `validate_record`, `save_record`, `cancel_edit_record` go to the page.
  """
  attr :kind, :atom, default: nil
  attr :editing?, :boolean, default: false
  attr :prefs, :map, default: %{}
  attr :part_of_options, :list, default: []
  attr :part_of, :any, default: nil
  attr :data, :map, default: %{}
  attr :errors, :list, default: []
  attr :allergies, :list, default: []

  def record_form_panel(assigns) do
    ~H"""
    <FormPanels.form_panel
      id="record-form-panel"
      kind={:edit}
      open={@kind != nil}
      prefs={@prefs}
      icon={@kind && PersonRecordSchema.icon(@kind)}
      title={record_form_title(@kind, @editing?)}
      close="cancel_edit_record"
      form_id="record-form"
      submit_label={gettext("Save")}
    >
      <form id="record-form" phx-change="validate_record" phx-submit="save_record">
        <.part_of_select options={@part_of_options} value={@part_of} />
        <JsonSchemaForm.json_schema_form
          schema={PersonRecordSchema.schema(@kind)}
          ui_schema={PersonRecordSchema.ui_schema(@kind)}
          values={@data}
          name="record_data"
        />
        <.medication_allergy_warning kind={@kind} data={@data} allergies={@allergies} />
        <p :for={error <- @errors} class="text-sm text-error">{error}</p>
        <div class="form-actions mt-3 flex gap-2">
          <button type="submit" class="btn btn-primary btn-sm">
            <.icon name="hero-check" class="size-4" />
            {gettext("Save")}
          </button>
          <button type="button" phx-click="cancel_edit_record" class="btn btn-ghost btn-sm">
            {gettext("Cancel")}
          </button>
        </div>
      </form>
    </FormPanels.form_panel>
    """
  end

  defp record_form_title(nil, _editing?), do: ""

  defp record_form_title(kind, true),
    do: gettext("Edit: %{kind}", kind: kind_label(kind))

  defp record_form_title(kind, false),
    do: gettext("New: %{kind}", kind: kind_label(kind))
end
