defmodule App.Clinical.Drugs do
  @moduledoc """
  The app's own list of common field and emergency drugs
  (`priv/clinical/drugs.json`, docs/design/clinical-medications.md): WHO
  International Nonproprietary Names in English, Ukrainian and French,
  drug classes (used only to match allergies), usual routes and dose unit.
  Not a formulary and not a licensed coding system.

  Medication records store the drug as FHIR-style text plus, when the text
  names a listed drug, a coding in `system/0` with the drug's id — for
  given medications now and a medication list later.
  """

  @path Path.join(:code.priv_dir(:app), "clinical/drugs.json")
  @external_resource @path

  %{"drugs" => drugs, "classes" => classes, "class_parents" => parents} =
    @path |> File.read!() |> Jason.decode!()

  @drugs drugs
  @classes classes
  @parents parents
  @by_id Map.new(drugs, &{&1["id"], &1})

  @system "urn:hrda:drug"

  @typedoc "One entry of the list (the JSON object)."
  @type drug :: map()

  @doc "The coding system of drug ids in stored records."
  @spec system() :: String.t()
  def system, do: @system

  @spec all() :: [drug()]
  def all, do: @drugs

  @spec get(String.t()) :: drug() | nil
  def get(id), do: Map.get(@by_id, id)

  @doc "The drug's name in `locale` (English when there is none)."
  @spec name(drug(), String.t()) :: String.t()
  def name(drug, locale), do: drug["names"][locale] || drug["names"]["en"]

  @doc "Names in `locale`, alphabetical in that language, for a suggestion list."
  @spec names(String.t()) :: [String.t()]
  def names(locale), do: @drugs |> Enum.map(&name(&1, locale)) |> Enum.sort()

  @doc """
  The listed drug a free-text name refers to: any of its names in any
  language or another usual name (`also`), ignoring case and accents.
  """
  @spec resolve(String.t() | nil) :: drug() | nil
  def resolve(text) when is_binary(text) do
    key = normalize(text)
    Enum.find(@drugs, fn drug -> key in Enum.map(own_names(drug), &normalize/1) end)
  end

  def resolve(_text), do: nil

  @doc "Every name of the drug: its names in each language and other usual names."
  @spec own_names(drug()) :: [String.t()]
  def own_names(drug), do: Map.values(drug["names"]) ++ drug["also"]

  @doc "Every class id."
  @spec all_classes() :: [String.t()]
  def all_classes, do: Map.keys(@classes)

  @doc "The words naming a drug class in any language (allergy matching)."
  @spec class_terms(String.t()) :: [String.t()]
  def class_terms(class), do: @classes |> Map.fetch!(class) |> Map.values() |> List.flatten()

  @doc "The classes with the wider classes they belong to (a penicillin is a beta-lactam)."
  @spec with_parents([String.t()]) :: [String.t()]
  def with_parents(classes) do
    parents = classes |> Enum.map(&@parents[&1]) |> Enum.reject(&is_nil/1)
    Enum.uniq(classes ++ if(parents == [], do: [], else: with_parents(parents)))
  end

  @doc "The class's name in English (shown in a warning; the id otherwise)."
  @spec class_name(String.t()) :: String.t()
  def class_name(class), do: hd(@classes[class]["en"])

  @doc "Lower case, without accents, single spaces — for comparing names."
  @spec normalize(String.t()) :: String.t()
  def normalize(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.join(" ")
  end
end
