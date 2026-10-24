defmodule App.People.PositionLabelTest do
  use ExUnit.Case, async: true

  alias App.People.PositionLabel

  defp short(title, unit, grade),
    do: PositionLabel.short(%{title: title, organization: unit, grade: grade})

  test "the user's examples" do
    assert short("Physician", "Role 3 Field Hospital", "OF-3") == "Physician R.3¦F.H.¦OF-3"
    assert short("Rifleman", "A Company, 1 Bn", "OR-3") == "Rifleman A.Co¦1Bn¦OR-3"
    assert short("Rifleman", "A Company, 2 Bn", "OR-3") == "Rifleman A.Co¦2Bn¦OR-3"
  end

  test "other units, missing parts, one delimiter constant" do
    assert short("Battalion Commander", "2nd Battalion", "OF-4") ==
             "Battalion Commander 2ndBn¦OF-4"

    assert short("Nurse", "Role 2 Medical Company", nil) == "Nurse R.2¦M.Co"
    assert short("Clerk", nil, nil) == "Clerk"
    assert PositionLabel.delimiter() == "¦"
  end
end
