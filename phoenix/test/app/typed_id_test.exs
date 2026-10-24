defmodule App.TypedIdTest do
  use ExUnit.Case, async: true

  alias App.TypedId

  @uuid "01a08cd8-c353-75e2-a1c3-e8d3b73e07ba"

  test "format/2 and parse/1 round-trip for every registered resource" do
    for {resource, prefix} <- TypedId.prefixes() do
      typed = TypedId.format(resource, @uuid)
      assert typed == "#{prefix}_#{@uuid}"
      assert {:ok, ^resource, @uuid} = TypedId.parse(typed)
    end
  end

  test "format/2 raises for an unregistered resource" do
    assert_raise ArgumentError, ~r/no App.TypedId prefix registered/, fn ->
      TypedId.format(NotARealResource, @uuid)
    end
  end

  test "parse/1 rejects an unknown prefix" do
    assert {:error, :unknown_prefix} = TypedId.parse("nope_#{@uuid}")
  end

  test "parse/1 rejects a malformed uuid even with a known prefix" do
    assert {:error, :invalid_uuid} = TypedId.parse("person_not-a-uuid")
  end

  test "parse/1 rejects input with no separator at all" do
    assert {:error, :unknown_prefix} = TypedId.parse("garbage")
  end
end
