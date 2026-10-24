defmodule App.People.PositionStrengthTest do
  use App.DataCase, async: true

  import App.Fixtures

  alias App.People.Position

  defp create(attrs) do
    Position
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create(authorize?: false)
  end

  test "an identical post can't be created twice, even without grade or manager" do
    org = org_fixture("A Company")
    attrs = %{title: "Rifleman", organization_id: org.id}

    assert {:ok, %{strength: 1}} = create(attrs)
    assert {:error, error} = create(attrs)
    assert Exception.message(error) =~ "raise its strength"

    # A different grade is a different post.
    assert {:ok, _} = create(Map.put(attrs, :authorised_grade, "OR-4"))
  end

  test "strength is at least 1" do
    org = org_fixture("B Company")
    assert {:error, _} = create(%{title: "Medic", organization_id: org.id, strength: 0})
    assert {:ok, %{strength: 5}} = create(%{title: "Medic", organization_id: org.id, strength: 5})
  end
end
