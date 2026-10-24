defmodule App.Clinical.DrugsTest do
  @moduledoc "docs/design/clinical-medications.md: the app's own drug list."
  use ExUnit.Case, async: true

  alias App.Clinical.{AllergyCheck, Drugs}
  alias App.People.PersonRecordSchema

  test "every entry is complete and fits the medication schema" do
    schema = PersonRecordSchema.schema(:medication_administration)
    routes = schema["properties"]["route"]["enum"]
    units = schema["properties"]["dose"]["properties"]["unit"]["enum"]
    ids = Enum.map(Drugs.all(), & &1["id"])

    assert length(ids) == length(Enum.uniq(ids))

    for drug <- Drugs.all() do
      assert Enum.all?(~w(en uk fr), &(drug["names"][&1] not in [nil, ""])), drug["id"]
      assert drug["routes"] -- routes == [], drug["id"]
      assert drug["unit"] in units, drug["id"]
      assert Enum.all?(drug["classes"], &(Drugs.class_terms(&1) != [])), drug["id"]
    end

    # One name can't stand for two drugs (a drug may share a name across
    # languages).
    names =
      Enum.flat_map(Drugs.all(), fn drug ->
        drug |> Drugs.own_names() |> Enum.map(&Drugs.normalize/1) |> Enum.uniq()
      end)

    assert length(names) == length(Enum.uniq(names))
  end

  test "a name in any language, case or accents resolves to the drug" do
    for text <- ["Ketamine", "кетамін", "KÉTAMINE", " ketamine "],
        do: assert(Drugs.resolve(text)["id"] == "ketamine")

    assert Drugs.resolve("adrenaline")["id"] == "epinephrine"
    assert Drugs.resolve("Something else") == nil
    assert "Кетамін" in Drugs.names("uk")
  end

  describe "allergy matching" do
    defp allergy(text, extra \\ %{}),
      do: Map.merge(%{"code" => %{"text" => text}, "clinicalStatus" => "active"}, extra)

    defp reasons(drug, allergies),
      do: drug |> AllergyCheck.matches(allergies) |> Enum.map(& &1.reason)

    test "the drug, its class and drugs sharing a class, across languages" do
      assert reasons("Amoxicillin", [allergy("Amoxicillin")]) == [:same_drug]
      assert reasons("Amoxicillin", [allergy("Penicillins")]) == [{:same_class, "penicillin"}]

      assert reasons("амоксицилін", [allergy("алергія на пеніцилін")]) == [
               {:same_class, "penicillin"}
             ]

      assert reasons("Ceftriaxone", [allergy("Amoxicillin")]) == [{:same_class, "beta_lactam"}]
      # A class within a wider one.
      assert reasons("Ceftriaxone", [allergy("Penicillin")]) == [{:same_class, "beta_lactam"}]
      assert reasons("Ibuprofen", [allergy("Aspirin")]) == [{:same_class, "nsaid"}]
      assert reasons("Ibuprofen", [allergy("НПЗЗ")]) == [{:same_class, "nsaid"}]
      assert reasons("Adrenaline", [allergy("epinephrine")]) == [:same_drug]
      assert reasons("Fentanyl", [allergy("морфін")]) == [{:same_class, "opioid"}]
    end

    test "unrelated, resolved or refuted allergies don't match" do
      assert reasons("Ketamine", [allergy("Penicillin"), allergy("Peanuts")]) == []

      assert reasons("Amoxicillin", [allergy("Penicillin", %{"clinicalStatus" => "resolved"})]) ==
               []

      assert reasons("Amoxicillin", [allergy("Penicillin", %{"verificationStatus" => "refuted"})]) ==
               []

      # Short words match whole only.
      assert reasons("Ketamine", [allergy("Ket")]) == []
    end

    test "a drug not on the list matches its own text" do
      assert reasons("Novamab", [allergy("novamab rash")]) == [:same_drug]
    end

    test "the note names each allergy and the shared class" do
      matches =
        AllergyCheck.matches("Ceftriaxone", [allergy("Ceftriaxone"), allergy("Amoxicillin")])

      assert AllergyCheck.note(matches) == "Ceftriaxone; Amoxicillin (beta-lactam)"
      assert AllergyCheck.note([]) == nil
    end
  end
end
