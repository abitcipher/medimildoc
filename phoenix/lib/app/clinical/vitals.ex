defmodule App.Clinical.Vitals do
  @moduledoc """
  Assessing a set of vital signs (`vital_signs` records;
  docs/design/clinical-module.md): which values are outside adult
  reference ranges, and the NEWS2 early-warning score.

  **NEWS2** (National Early Warning Score 2, Royal College of Physicians,
  2017) scores seven parameters 0–3 and adds them up; this uses SpO₂
  scale 1 (scale 2, for patients with hypercapnic respiratory failure, is
  a clinical decision this record doesn't capture). The score is only
  computed when all seven are present. Clinical risk: 0–4 low (a single
  parameter scoring 3 raises it to low–medium), 5–6 medium, 7+ high.

  Reference ranges are the NEWS2 zero-score bands (adult), used for the
  "low"/"high" marks next to values. Neither is a diagnosis; both support
  clinical judgement.
  """

  @type flag :: :low | :high
  @type risk :: :low | :low_medium | :medium | :high

  # Parameters NEWS2 needs, in chart order.
  @news2 ~w(respiratoryRate spo2 onOxygen systolic heartRate consciousness temperature)

  # Zero-score (normal) bands for the "low"/"high" marks.
  @normal %{
    "respiratoryRate" => {12, 20},
    "spo2" => {96, 100},
    "systolic" => {111, 219},
    "diastolic" => {60, 90},
    "heartRate" => {51, 90},
    "temperature" => {36.1, 38.0},
    "gcs" => {15, 15}
  }

  @doc "The normal band `{low, high}` of a numeric parameter, or nil."
  @spec normal_band(String.t()) :: {number(), number()} | nil
  def normal_band(key), do: @normal[key]

  @doc """
  Vital-sign sets newest first, by the time they were measured (the
  record's `measuredAt`, a local ISO date and time that sorts as text).
  """
  @spec newest_first([map()]) :: [map()]
  def newest_first(records), do: Enum.sort_by(records, &(&1.data["measuredAt"] || ""), :desc)

  @doc "Values outside their normal band: `%{\"heartRate\" => :high, …}`."
  @spec flags(map()) :: %{String.t() => flag()}
  def flags(data) do
    for {key, {low, high}} <- @normal,
        value = data[key],
        is_number(value),
        value < low or value > high,
        into: %{} do
      {key, if(value < low, do: :low, else: :high)}
    end
    |> Map.merge(consciousness_flag(data["consciousness"]))
  end

  defp consciousness_flag(value) when value in [nil, "alert"], do: %{}
  defp consciousness_flag(_value), do: %{"consciousness" => :low}

  @doc """
  NEWS2 for a set of vital signs: `{:ok, %{score, risk, parts}}` where
  `parts` maps each parameter to its 0–3 score, or `{:incomplete, missing}`
  listing the parameters that aren't recorded.
  """
  @spec news2(map()) ::
          {:ok, %{score: non_neg_integer(), risk: risk(), parts: %{String.t() => 0..3}}}
          | {:incomplete, [String.t()]}
  def news2(data) do
    case Enum.filter(@news2, &(data[&1] in [nil, ""])) do
      [] ->
        parts = Map.new(@news2, &{&1, score(&1, data[&1])})
        total = parts |> Map.values() |> Enum.sum()
        {:ok, %{score: total, risk: risk(total, parts), parts: parts}}

      missing ->
        {:incomplete, missing}
    end
  end

  defp risk(total, _parts) when total >= 7, do: :high
  defp risk(total, _parts) when total >= 5, do: :medium

  defp risk(_total, parts),
    do: if(Enum.any?(parts, fn {_k, v} -> v == 3 end), do: :low_medium, else: :low)

  defp score("respiratoryRate", v) when v <= 8, do: 3
  defp score("respiratoryRate", v) when v <= 11, do: 1
  defp score("respiratoryRate", v) when v <= 20, do: 0
  defp score("respiratoryRate", v) when v <= 24, do: 2
  defp score("respiratoryRate", _v), do: 3

  defp score("spo2", v) when v <= 91, do: 3
  defp score("spo2", v) when v <= 93, do: 2
  defp score("spo2", v) when v <= 95, do: 1
  defp score("spo2", _v), do: 0

  defp score("onOxygen", true), do: 2
  defp score("onOxygen", _air), do: 0

  defp score("systolic", v) when v <= 90, do: 3
  defp score("systolic", v) when v <= 100, do: 2
  defp score("systolic", v) when v <= 110, do: 1
  defp score("systolic", v) when v <= 219, do: 0
  defp score("systolic", _v), do: 3

  defp score("heartRate", v) when v <= 40, do: 3
  defp score("heartRate", v) when v <= 50, do: 1
  defp score("heartRate", v) when v <= 90, do: 0
  defp score("heartRate", v) when v <= 110, do: 1
  defp score("heartRate", v) when v <= 130, do: 2
  defp score("heartRate", _v), do: 3

  defp score("consciousness", "alert"), do: 0
  defp score("consciousness", _cvpu), do: 3

  defp score("temperature", v) when v <= 35.0, do: 3
  defp score("temperature", v) when v <= 36.0, do: 1
  defp score("temperature", v) when v <= 38.0, do: 0
  defp score("temperature", v) when v <= 39.0, do: 1
  defp score("temperature", _v), do: 2
end
