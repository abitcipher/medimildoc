defmodule App.Clinical.Interactions do
  @moduledoc """
  Interactions and therapeutic duplicates between a drug being recorded
  and the person's current ones (docs/design/clinical-medications.md
  §Interactions), from `priv/clinical/interactions.json` — an illustrative
  short list, not a clinical knowledge base: a warning helps, its absence
  means nothing. Pure; checked against `App.Clinical.Drugs` at compile time.
  """

  alias App.Clinical.Drugs

  @path Path.join(:code.priv_dir(:app), "clinical/interactions.json")
  @external_resource @path

  %{"groups" => groups, "duplicate_classes" => duplicates, "interactions" => interactions} =
    @path |> File.read!() |> Jason.decode!()

  drug_ids = MapSet.new(Drugs.all(), & &1["id"])
  class_ids = Drugs.all() |> Enum.flat_map(& &1["classes"]) |> MapSet.new()

  for {group, ids} <- groups,
      id <- ids,
      id not in drug_ids,
      do: raise("interactions.json: group #{group} names unknown drug #{id}")

  for class <- duplicates,
      class not in class_ids,
      do: raise("interactions.json: unknown duplicate class #{class}")

  for %{"a" => a, "b" => b} <- interactions, term <- [a, b] do
    case String.split(term, ":", parts: 2) do
      ["drug", id] ->
        if id not in drug_ids, do: raise("interactions.json: unknown drug #{id}")

      ["class", c] ->
        if c not in class_ids, do: raise("interactions.json: unknown class #{c}")

      ["group", g] ->
        if not Map.has_key?(groups, g), do: raise("interactions.json: unknown group #{g}")

      _ ->
        raise "interactions.json: bad term #{term}"
    end
  end

  @groups groups
  @duplicates duplicates
  @interactions interactions
  @severity_rank %{"major" => 0, "moderate" => 1, "minor" => 2}

  @type finding :: %{
          with: String.t(),
          kind: :interaction | :same_drug | {:same_class, String.t()},
          severity: String.t(),
          note: String.t()
        }

  @doc """
  What `drug_id` meets among `current_ids` (drug ids the person takes or
  was just given): interactions, the same drug again, another drug of a
  class where one is enough. Most severe first.
  """
  @spec check(String.t() | nil, [String.t()]) :: [finding()]
  def check(nil, _current), do: []

  def check(drug_id, current_ids) do
    current_ids
    |> Enum.uniq()
    |> Enum.flat_map(&findings(drug_id, &1))
    |> Enum.sort_by(&{Map.fetch!(@severity_rank, &1.severity), &1.with})
  end

  @doc "The findings as one line for the record's warning field (English), or nil."
  @spec note([finding()]) :: String.t() | nil
  def note([]), do: nil

  def note(findings) do
    Enum.map_join(findings, "; ", fn f ->
      "#{name(f.with)} — #{f.note} (#{f.severity})"
    end)
  end

  defp findings(id, id),
    do: [%{with: id, kind: :same_drug, severity: "moderate", note: "same drug again"}]

  defp findings(drug_id, other) do
    duplicate(drug_id, other) ++ interactions(drug_id, other)
  end

  defp duplicate(a, b) do
    case Enum.find(@duplicates, &(&1 in classes(a) and &1 in classes(b))) do
      nil ->
        []

      class ->
        [
          %{
            with: b,
            kind: {:same_class, class},
            severity: "moderate",
            note: "two of the same class (#{Drugs.class_name(class)})"
          }
        ]
    end
  end

  defp interactions(a, b) do
    terms_a = terms(a)
    terms_b = terms(b)

    @interactions
    |> Enum.filter(fn %{"a" => x, "b" => y} ->
      (x in terms_a and y in terms_b) or (y in terms_a and x in terms_b)
    end)
    |> Enum.uniq_by(& &1["note"]["en"])
    |> Enum.map(fn i ->
      %{with: b, kind: :interaction, severity: i["severity"], note: i["note"]["en"]}
    end)
  end

  defp terms(id) do
    ["drug:" <> id] ++
      Enum.map(classes(id), &("class:" <> &1)) ++
      for {group, ids} <- @groups, id in ids, do: "group:" <> group
  end

  defp classes(id) do
    case Drugs.get(id) do
      nil -> []
      drug -> Drugs.with_parents(drug["classes"])
    end
  end

  defp name(id) do
    case Drugs.get(id) do
      nil -> id
      drug -> Drugs.name(drug, "en")
    end
  end
end
