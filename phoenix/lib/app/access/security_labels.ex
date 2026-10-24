defmodule App.Access.SecurityLabels do
  @moduledoc """
  Security labels carried by records (docs/design/access-control-phase1.md), 
  modelled on FHIR `meta.security` and kept as two separate axes:

  - **confidentiality** — HL7 v3 Confidentiality, how privacy-sensitive the
    data is (`u` unrestricted, `l` low, `m` moderate, `n` normal,
    `r` restricted, `v` very restricted). Code system
    `http://terminology.hl7.org/CodeSystem/v3-Confidentiality`.
  - **classification** — NATO security marking, how secret the data is.
    `nil` means not classified.

  Both lists are ordered from least to most restrictive. Phase 1 stores
  labels and prevents lowering them below a kind's default; phase 2
  compares classification with the reader's clearance.
  """

  @confidentiality [:u, :l, :m, :n, :r, :v]

  @classifications [
    :nato_unclassified,
    :nato_restricted,
    :nato_confidential,
    :nato_secret,
    :cosmic_top_secret
  ]

  @confidentiality_system "http://terminology.hl7.org/CodeSystem/v3-Confidentiality"

  @doc "HL7 v3 Confidentiality codes, least to most restrictive."
  @spec confidentiality_levels() :: [atom()]
  def confidentiality_levels, do: @confidentiality

  @doc "NATO security markings, least to most restrictive."
  @spec classifications() :: [atom()]
  def classifications, do: @classifications

  @doc "The FHIR code system URI for confidentiality codes."
  @spec confidentiality_system() :: String.t()
  def confidentiality_system, do: @confidentiality_system

  @doc """
  Whether `level` is at least as restrictive as `minimum` on the
  confidentiality axis. A `nil` minimum is always satisfied.
  """
  @spec confidentiality_at_least?(atom() | nil, atom() | nil) :: boolean()
  def confidentiality_at_least?(_level, nil), do: true
  def confidentiality_at_least?(nil, _minimum), do: false

  def confidentiality_at_least?(level, minimum),
    do: rank(@confidentiality, level) >= rank(@confidentiality, minimum)

  @doc """
  Whether `classification` is at least `minimum`. `nil` (not classified)
  only satisfies a `nil` minimum.
  """
  @spec classification_at_least?(atom() | nil, atom() | nil) :: boolean()
  def classification_at_least?(_classification, nil), do: true
  def classification_at_least?(nil, _minimum), do: false

  def classification_at_least?(classification, minimum),
    do: rank(@classifications, classification) >= rank(@classifications, minimum)

  defp rank(list, value), do: Enum.find_index(list, &(&1 == value)) || -1
end
