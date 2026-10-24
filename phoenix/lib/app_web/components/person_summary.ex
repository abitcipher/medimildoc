defmodule AppWeb.PersonSummary do
  @moduledoc """
  The person page header (docs/design/ui-plan.md item 3): initials avatar,
  name, current position, and a strip of status chips — fitness for duty,
  security clearance, allergy alert.

  Each chip is built from records the viewer could read anyway: the
  records are loaded through the normal `PersonRecord` read policy
  (`summary_records/2`), so a chip for a category the viewer may not see
  never appears. Chip colours carry meaning (green fit / amber downgraded
  or expiring / red non-effective, expired or high-risk allergy) and every
  chip has an icon and a tooltip, so colour is never the only signal.
  """
  use Phoenix.Component
  use Gettext, backend: AppWeb.Gettext

  import AppWeb.CoreComponents, only: [icon: 1]

  require Ash.Query

  alias App.Clinical.{Drugs, Vitals}
  alias App.People.{PersonRecord, PersonRecordSchema}
  alias AppWeb.SchemaText

  @summary_kinds [
    :fitness_for_duty,
    :security_clearance,
    :allergy_intolerance,
    :medication_statement
  ]
  @expiry_warning_days 90

  @doc """
  The records the summary needs, read as `actor`: the latest fitness and
  clearance record and all active allergies. Kinds the actor may not read
  are simply absent.
  """
  @spec summary_records(map(), map()) :: map()
  def summary_records(person, actor) do
    records =
      PersonRecord
      |> Ash.Query.filter(person_id == ^person.id and kind in ^@summary_kinds)
      |> Ash.Query.sort(recorded_at: :desc)
      |> Ash.read!(actor: actor)

    %{
      vitals: latest_vitals(person, actor),
      fitness: Enum.find(records, &(&1.kind == :fitness_for_duty)),
      clearance: Enum.find(records, &(&1.kind == :security_clearance)),
      allergies:
        Enum.filter(
          records,
          &(&1.kind == :allergy_intolerance and &1.data["clinicalStatus"] == "active")
        ),
      medications:
        Enum.filter(
          records,
          &(&1.kind == :medication_statement and &1.data["adherence"] in ["taking", "on-hold"])
        )
    }
  end

  # The latest vital-sign sets (point-of-care data, so each read is in the
  # access log): newest first by when they were measured.
  @vitals_shown 20

  defp latest_vitals(person, actor) do
    PersonRecord
    |> Ash.Query.filter(person_id == ^person.id and kind == :vital_signs)
    |> Ash.Query.sort(recorded_at: :desc)
    |> Ash.Query.limit(@vitals_shown)
    |> Ash.read!(actor: actor)
    |> Vitals.newest_first()
  end

  attr :summary, :map, required: true
  attr :today, Date, default: nil

  def status_chips(assigns) do
    assigns = assign(assigns, :today, assigns.today || Date.utc_today())

    ~H"""
    <ul class="flex flex-wrap gap-2" aria-label={gettext("Status")}>
      <li :if={@summary.fitness}><.fitness_chip record={@summary.fitness} /></li>
      <li :if={@summary.clearance}>
        <.clearance_chip record={@summary.clearance} today={@today} />
      </li>
      <li :if={@summary.allergies != []}><.allergy_chip records={@summary.allergies} /></li>
      <li :if={@summary[:medications] not in [nil, []]}>
        <.medications_chip records={@summary.medications} />
      </li>
      <li :if={@summary[:vitals] not in [nil, []]}><.news2_chip record={hd(@summary.vitals)} /></li>
    </ul>
    """
  end

  attr :record, :map, required: true

  defp fitness_chip(assigns) do
    status = assigns.record.data["status"]

    assigns =
      assign(assigns,
        status: status,
        tone:
          case status do
            "fit_for_duty" -> "badge-success"
            "downgraded" -> "badge-warning"
            _ -> "badge-error"
          end,
        icon:
          if(status == "fit_for_duty", do: "hero-check-badge", else: "hero-exclamation-circle"),
        tip:
          [
            assigns.record.data["restrictions"],
            assigns.record.data["reviewDate"] &&
              gettext("Review: %{date}",
                date: AppWeb.DateFormat.display(assigns.record.data["reviewDate"])
              )
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" · ")
      )

    ~H"""
    <span
      class={["badge gap-1", @tone, @tip != "" && "tooltip tooltip-bottom"]}
      data-tip={@tip != "" && @tip}
    >
      <.icon name={@icon} class="size-4" />
      {SchemaText.choice(@status)}
    </span>
    """
  end

  attr :record, :map, required: true
  attr :today, Date, required: true

  defp clearance_chip(assigns) do
    data = assigns.record.data
    state = clearance_state(data, assigns.today)

    assigns =
      assign(assigns,
        level: SchemaText.choice(data["clearanceLevel"]),
        tone: clearance_tone(state),
        note: clearance_note(state, data),
        tip: clearance_tip(data)
      )

    ~H"""
    <span
      class={["badge gap-1", @tone, @tip != "" && "tooltip tooltip-bottom"]}
      data-tip={@tip != "" && @tip}
    >
      <.icon name="hero-shield-check" class="size-4" />
      {@level}<span :if={@note}>· {@note}</span>
    </span>
    """
  end

  defp clearance_state(%{"status" => "granted"} = data, today) do
    case parse_date(data["expiryDate"]) do
      nil -> :valid
      expiry -> expiry_state(expiry, today)
    end
  end

  defp clearance_state(_data, _today), do: :inactive

  defp expiry_state(expiry, today) do
    cond do
      Date.compare(expiry, today) == :lt -> :expired
      Date.diff(expiry, today) <= @expiry_warning_days -> :expiring
      true -> :valid
    end
  end

  defp clearance_tone(:valid), do: "badge-info"
  defp clearance_tone(:expiring), do: "badge-warning"
  defp clearance_tone(_state), do: "badge-error"

  defp clearance_note(:valid, _data), do: nil
  defp clearance_note(:expiring, _data), do: gettext("expires soon")
  defp clearance_note(:expired, _data), do: gettext("expired")
  defp clearance_note(:inactive, data), do: SchemaText.choice(data["status"])

  defp clearance_tip(data) do
    [
      data["grantedDate"] &&
        gettext("Granted: %{date}", date: AppWeb.DateFormat.display(data["grantedDate"])),
      data["expiryDate"] &&
        gettext("Valid until: %{date}", date: AppWeb.DateFormat.display(data["expiryDate"]))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  attr :record, :map, required: true

  # NEWS2 of the latest vital signs (App.Clinical.Vitals).
  defp news2_chip(assigns) do
    measured = AppWeb.DateFormat.display_datetime(assigns.record.data["measuredAt"])

    assigns =
      case Vitals.news2(assigns.record.data) do
        {:ok, %{score: score, risk: risk}} ->
          assign(assigns,
            text: "NEWS2 #{score}",
            tone: risk_tone(risk),
            tip: "#{risk_label(risk)} · #{measured}"
          )

        {:incomplete, _missing} ->
          assign(assigns,
            text: "NEWS2 —",
            tone: "badge-ghost",
            tip: gettext("Incomplete vital signs") <> " · " <> measured
          )
      end

    ~H"""
    <span class={["badge gap-1 tooltip tooltip-bottom", @tone]} data-tip={@tip}>
      <.icon name="hero-chart-bar" class="size-4" />
      <span>{@text}</span>
    </span>
    """
  end

  @doc "Badge colour for a NEWS2 risk level."
  @spec risk_tone(atom()) :: String.t()
  def risk_tone(:high), do: "badge-error"
  def risk_tone(:medium), do: "badge-warning"
  def risk_tone(:low_medium), do: "badge-warning"
  def risk_tone(:low), do: "badge-success"

  @doc "The NEWS2 clinical risk level, in words."
  @spec risk_label(atom()) :: String.t()
  def risk_label(:high), do: gettext("High clinical risk")
  def risk_label(:medium), do: gettext("Medium clinical risk")
  def risk_label(:low_medium), do: gettext("Low–medium clinical risk (a single red score)")
  def risk_label(:low), do: gettext("Low clinical risk")

  attr :records, :list, required: true

  defp allergy_chip(assigns) do
    high? = Enum.any?(assigns.records, &(&1.data["criticality"] == "high"))

    assigns =
      assign(assigns,
        high?: high?,
        names: Enum.map_join(assigns.records, ", ", & &1.data["code"]["text"]),
        tip:
          Enum.map_join(assigns.records, " · ", fn record ->
            [record.data["code"]["text"], record.data["reactionManifestation"]]
            |> Enum.reject(&is_nil/1)
            |> Enum.join(": ")
          end)
      )

    ~H"""
    <span
      role="alert"
      class={[
        "badge gap-1 tooltip tooltip-bottom",
        if(@high?, do: "badge-error", else: "badge-warning")
      ]}
      data-tip={@tip}
    >
      <.icon name="hero-exclamation-triangle" class="size-4" />
      <span>{gettext("Allergies:")} {@names}</span>
    </span>
    """
  end

  # Current medicines (docs/design/clinical-medications.md): how many, the
  # list in the tooltip, and a warning tone when one thins the blood — what
  # a medic must know before a procedure or giving a drug.
  @bleeding_risk ["anticoagulant", "antiplatelet"]

  attr :records, :list, required: true

  defp medications_chip(assigns) do
    thinners = Enum.filter(assigns.records, &bleeding_risk?/1)

    assigns =
      assign(assigns,
        thinners: thinners,
        tip: Enum.map_join(assigns.records, " · ", &medication_line/1)
      )

    ~H"""
    <span
      class={[
        "badge gap-1 tooltip tooltip-bottom",
        if(@thinners != [], do: "badge-warning", else: "badge-info badge-soft")
      ]}
      data-tip={@tip}
    >
      <.icon name="hero-clipboard-document-list" class="size-4" />
      <span>
        {ngettext("%{count} medication", "%{count} medications", length(@records))}
        <span :if={@thinners != []}>· {gettext("blood thinner")}</span>
      </span>
    </span>
    """
  end

  defp bleeding_risk?(record) do
    case get_in(record.data, ["medication", "coding"]) do
      [%{"code" => code} | _] ->
        case Drugs.get(code) do
          nil ->
            false

          drug ->
            Enum.any?(Drugs.with_parents(drug["classes"]), &(&1 in @bleeding_risk))
        end

      _ ->
        false
    end
  end

  # "Apixaban 5 mg, Twice a day", in the viewer's language: a listed drug
  # by its name in that language, units and frequency translated.
  defp medication_line(record) do
    data = record.data
    unit = data["dose"] && SchemaText.choice(data["dose"]["unit"], unit_labels())
    dose = data["dose"] && "#{data["dose"]["value"]} #{unit}"
    frequency = data["frequency"] && SchemaText.choice(data["frequency"], frequency_labels())

    [Enum.join(Enum.reject([drug_name(data), dose], &is_nil/1), " "), frequency]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
  end

  defp drug_name(data) do
    with [%{"code" => code} | _] <- get_in(data, ["medication", "coding"]),
         %{} = drug <- Drugs.get(code) do
      Drugs.name(drug, Gettext.get_locale(AppWeb.Gettext))
    else
      _ -> get_in(data, ["medication", "text"])
    end
  end

  defp unit_labels,
    do:
      PersonRecordSchema.schema(:medication_statement)["properties"]["dose"]["properties"][
        "unit"
      ]["x-enum-labels"]

  defp frequency_labels,
    do:
      PersonRecordSchema.schema(:medication_statement)["properties"]["frequency"][
        "x-enum-labels"
      ]

  defp parse_date(nil), do: nil

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end
end
