defmodule App.Rules.ReferenceTest do
  @moduledoc "docs/design/data-consistency.md: the reference dataset."
  use App.DataCase, async: false

  alias App.Rules.{Library, Reference, RuleSet}

  setup do
    Library.sync()
    :ok
  end

  test "the synthetic data plants 1–3 % invalid records and the rules find exactly those" do
    reference = Reference.load()
    opts = [people: reference["people"], seed: reference["seed"]]
    {:ok, counts} = App.Demo.seed(opts)

    # The stored labels are what the generator plants (regenerate with
    # `mix app.rules.reference` after changing it).
    assert Reference.build(opts, counts) == reference
    assert reference["invalid"] / reference["items"] >= 0.01
    assert reference["invalid"] / reference["items"] <= 0.03
    assert Enum.any?(reference["expected"], &(&1["code"] == "identity_missing"))
    assert Enum.any?(reference["expected"], &(&1["code"] == "identity_after_examination"))

    # Every shipped rule has planted violations, except those checked only
    # when documents are sent or signed (the reference checks what is stored).
    shipped = MapSet.new(Library.files(), & &1["key"])

    assert MapSet.new(reference["expected"], & &1["rule"]) ==
             MapSet.difference(
               shipped,
               MapSet.new(["signed_after_basis", "leave_within_unit_limit"])
             )

    # FSDC is off: the reference check runs anyway, and records nothing.
    refute App.Settings.fsdc?()
    assert {:ok, %{missing: [], unexpected: [], expected: expected}} = Reference.verify()
    assert expected == reference["invalid"]
    assert Ash.read!(App.Audit.Incident, authorize?: false) == []

    # A rule that stops finding violations fails the check.
    rule = Ash.get!(RuleSet, "identity_before_examination", authorize?: false)

    lenient =
      update_in(rule.graph, ["nodes"], fn nodes ->
        Enum.map(nodes, fn
          %{"type" => "expressionNode"} = node ->
            put_in(node, ["content", "expressions"], [
              %{"id" => "e1", "key" => "valid", "value" => "true"}
            ])

          node ->
            node
        end)
      end)

    rule
    |> Ash.Changeset.for_update(:update_graph, %{graph: lenient}, authorize?: false)
    |> Ash.update!(authorize?: false)

    assert {:ok, %{missing: missing, unexpected: []}} = Reference.verify()
    assert missing == Enum.filter(reference["expected"], &(&1["rule"] == rule.key))
  end

  test "without the reference's synthetic data there is nothing to verify" do
    assert {:error, :not_seeded} = Reference.verify()
  end
end
