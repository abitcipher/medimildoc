defmodule App.Clinical.InteractionsTest do
  @moduledoc "docs/design/clinical-medications.md §Interactions: the checker (pure)."
  use ExUnit.Case, async: true

  alias App.Clinical.Interactions

  test "a known pair by class, by group and by drug; most severe first" do
    assert [%{with: "warfarin", severity: "major", note: "bleeding risk"}] =
             Interactions.check("ibuprofen", ["warfarin"])

    assert [%{with: "sertraline", note: "serotonin syndrome"}] =
             Interactions.check("tramadol", ["sertraline"])

    assert [%{severity: "major"} | _] =
             Interactions.check("ketorolac", ["paracetamol", "warfarin"])

    assert Interactions.check("paracetamol", ["warfarin"]) == []
  end

  test "duplicates: the same drug again, two of a class where one is enough" do
    assert [%{kind: :same_drug}] = Interactions.check("ibuprofen", ["ibuprofen"])
    assert [%{kind: {:same_class, "nsaid"}}] = Interactions.check("ibuprofen", ["ketorolac"])
    # Different classes without a listed pair: nothing.
    assert Interactions.check("amoxicillin", ["omeprazole"]) == []
  end

  test "no coded drug, no findings; the note names the other drug and the severity" do
    assert Interactions.check(nil, ["warfarin"]) == []
    assert Interactions.note([]) == nil

    assert Interactions.note(Interactions.check("ibuprofen", ["warfarin"])) ==
             "Warfarin — bleeding risk (major)"
  end
end
