defmodule App.AshJsonSchemaTest do
  use ExUnit.Case, async: true

  alias App.AshJsonSchema

  test "derives string type/maxLength/minLength (from allow_empty?) and required from allow_nil?" do
    derived = AshJsonSchema.derive(App.People.Person, :create)

    assert derived.properties["given_name"] == %{
             "type" => "string",
             "maxLength" => 255,
             "minLength" => 1
           }

    assert derived.properties["email"] == %{
             "type" => "string",
             "maxLength" => 255,
             "minLength" => 1
           }

    assert derived.properties["date_of_birth"] == %{"type" => "string", "format" => "date"}

    assert Enum.sort(derived.required) == ["family_name", "given_name"]
    refute "email" in derived.required
    refute "date_of_birth" in derived.required
  end

  test "derives an enum from an atom attribute's one_of constraint" do
    derived = AshJsonSchema.derive(App.People.Organization, :create)

    assert derived.properties["kind"] == %{
             "type" => "string",
             "enum" => [
               "company",
               "department",
               "team",
               "unit",
               "brigade",
               "battalion",
               "division"
             ]
           }
  end

  test "derives a plain string type for UUID-typed (belongs_to FK) attributes" do
    derived = AshJsonSchema.derive(App.People.Position, :create)

    assert derived.properties["organization_id"] == %{"type" => "string"}
    assert "organization_id" in derived.required
    assert derived.properties["reports_to_id"] == %{"type" => "string"}
    refute "reports_to_id" in derived.required
  end

  test "only includes attributes actually in the action's accept list" do
    derived = AshJsonSchema.derive(App.People.Assignment, :create)

    assert Map.keys(derived.properties) |> Enum.sort() ==
             ["ends_on", "person_id", "position_id", "starts_on"]
  end
end
