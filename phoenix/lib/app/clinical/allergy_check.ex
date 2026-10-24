defmodule App.Clinical.AllergyCheck do
  @moduledoc """
  Does a drug match a recorded allergy (docs/design/clinical-medications.md)?
  Decided by the user: a match warns and the record notes it; saving is
  never blocked (an emergency may need the drug anyway).

  A drug matches an allergy when the allergy's substance text names

  - the drug itself (any of its names, in any language), or
  - one of its drug classes ("penicillin" for amoxicillin), or
  - another listed drug sharing a class with it (an amoxicillin allergy
    and ceftriaxone: both beta-lactams — possible cross-reactivity).

  Classes include the wider class they belong to (`class_parents` in the
  drug list): a penicillin allergy matches ceftriaxone as a beta-lactam.

  Words match whole, or by prefix for words of five letters or more, so
  inflected forms count ("пеніциліну", "pénicillines"). Only allergies that
  are not resolved, refuted or entered in error are considered. A drug not
  on the list (free text) matches by its own text only.
  """

  alias App.Clinical.Drugs

  @min_prefix 5

  @typedoc "Why a drug matched: the same drug or a shared class."
  @type reason :: :same_drug | {:same_class, String.t()}

  @type match :: %{substance: String.t(), criticality: String.t() | nil, reason: reason()}

  @doc """
  The allergies (`allergy_intolerance` record data) that `medication_text`
  matches, in the order given.
  """
  @spec matches(String.t() | nil, [map()]) :: [match()]
  def matches(medication_text, allergies) when is_binary(medication_text) do
    drug = Drugs.resolve(medication_text)

    for allergy <- allergies,
        relevant?(allergy),
        substance = get_in(allergy, ["code", "text"]),
        is_binary(substance),
        reason = reason(drug, medication_text, substance),
        do: %{substance: substance, criticality: allergy["criticality"], reason: reason}
  end

  def matches(_medication_text, _allergies), do: []

  @doc """
  The warning noted on a medication record: the matching allergies'
  substances (`describe/1`) — "Penicillin; Amoxicillin (beta-lactam)".
  """
  @spec note([match()]) :: String.t() | nil
  def note([]), do: nil
  def note(matches), do: Enum.map_join(matches, "; ", &describe/1)

  @doc """
  One match as text: the substance, and the shared class when the
  substance doesn't already name it ("Amoxicillin (beta-lactam)", but just
  "Penicillin").
  """
  @spec describe(match()) :: String.t()
  def describe(%{substance: s, reason: {:same_class, class}}) do
    if class_mentioned?(s, class), do: s, else: "#{s} (#{Drugs.class_name(class)})"
  end

  def describe(%{substance: s}), do: s

  defp relevant?(allergy) do
    allergy["clinicalStatus"] not in ["inactive", "resolved"] and
      allergy["verificationStatus"] not in ["refuted", "entered-in-error"]
  end

  # A drug not on the list: its own text only.
  defp reason(nil, text, substance), do: if(mentions?(substance, text), do: :same_drug)

  defp reason(drug, _text, substance) do
    if Enum.any?(Drugs.own_names(drug), &mentions?(substance, &1)) do
      :same_drug
    else
      named = named_classes(substance)
      # The drug's own classes first, then the wider ones: the most
      # specific shared class is the one reported.
      drug["classes"] |> Drugs.with_parents() |> Enum.find(&(&1 in named)) |> same_class()
    end
  end

  defp same_class(nil), do: nil
  defp same_class(class), do: {:same_class, class}

  # Classes the allergy names: directly ("penicillin"), or through a listed
  # drug it names (amoxicillin → penicillin), with their wider classes.
  defp named_classes(substance) do
    direct = Enum.filter(Drugs.all_classes(), &class_mentioned?(substance, &1))

    via_drugs =
      Enum.flat_map(Drugs.all(), fn drug ->
        if Enum.any?(Drugs.own_names(drug), &mentions?(substance, &1)),
          do: drug["classes"],
          else: []
      end)

    Drugs.with_parents(direct ++ via_drugs)
  end

  defp class_mentioned?(substance, class),
    do: Enum.any?(Drugs.class_terms(class), &mentions?(substance, &1))

  @doc false
  # Does `text` contain `term` as consecutive words (prefix rule above)?
  @spec mentions?(String.t(), String.t()) :: boolean()
  def mentions?(text, term) do
    words = words(text)
    term_words = words(term)
    n = length(term_words)

    n > 0 and
      words
      |> Enum.chunk_every(n, 1, :discard)
      |> Enum.any?(fn chunk -> Enum.zip(chunk, term_words) |> Enum.all?(&word_match?/1) end)
  end

  defp words(text), do: text |> Drugs.normalize() |> String.split(" ", trim: true)

  defp word_match?({word, term}),
    do: word == term or (String.length(term) >= @min_prefix and String.starts_with?(word, term))
end
