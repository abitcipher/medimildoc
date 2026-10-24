defmodule App.Rules.ShippedRulesTest do
  @moduledoc "docs/design/data-consistency.md: the shipped rules at their check points."
  use App.DataCase, async: false

  import App.Fixtures

  alias App.People.{Assignment, Position}
  alias App.Rules.{Engine, Library}

  setup do
    Library.sync()
    :ok = App.Settings.put("fsdc.enabled", true, user_fixture(:admin))
    %{person: person_fixture(), hr: user_fixture(:hr)}
  end

  defp incidents do
    App.Audit.Incident |> Ash.read!(authorize?: false) |> Enum.map(&{&1.rule_key, &1.code})
  end

  defp graph(key), do: Ash.get!(App.Rules.RuleSet, key, authorize?: false).graph

  test "a diagnosis code in fitness restrictions is flagged, plain restrictions are not", ctx do
    record_fixture(ctx.person, :fitness_for_duty, %{
      "status" => "downgraded",
      "restrictions" => "No heavy lifting over 20 kg"
    })

    # (Without a board conclusion behind it: only that rule speaks.)
    assert incidents() == [{"fitness_from_signed_conclusion", "fitness_without_conclusion"}]

    record_fixture(ctx.person, :fitness_for_duty, %{
      "status" => "downgraded",
      "restrictions" => "Knee M23.2: no running"
    })

    assert {"no_diagnosis_in_restrictions", "diagnosis_in_restrictions"} in incidents()
  end

  test "an assignment overlapping another of the person is flagged; a transfer is not", ctx do
    org = org_fixture("A Company")

    position =
      Position
      |> Ash.Changeset.for_create(:create, %{title: "Rifleman", organization_id: org.id},
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    create = fn starts_on, ends_on ->
      Assignment
      |> Ash.Changeset.for_create(
        :create,
        %{
          person_id: ctx.person.id,
          position_id: position.id,
          starts_on: starts_on,
          ends_on: ends_on
        },
        actor: ctx.hr
      )
      |> Ash.create!(actor: ctx.hr)
    end

    create.(~D[2025-01-01], ~D[2025-12-31])
    create.(~D[2026-01-01], nil)
    assert incidents() == []

    create.(~D[2026-03-01], nil)
    assert incidents() == [{"assignments_no_overlap", "assignment_overlap"}]
  end

  test "a document signed before its basis is a violation" do
    context = fn at, basis ->
      %{"event" => %{"at" => at}, "basis" => %{"signedAt" => basis}}
    end

    graph = graph("signed_after_basis")

    assert {:ok, %{"valid" => true}} =
             Engine.evaluate(graph, context.("2026-09-29T10:00:00Z", "2026-09-28T10:00:00Z"))

    assert {:ok, %{"valid" => true}} =
             Engine.evaluate(graph, context.("2026-09-29T10:00:00Z", nil))

    assert {:ok, %{"valid" => false, "code" => "signed_before_basis"}} =
             Engine.evaluate(graph, context.("2026-09-27T10:00:00Z", "2026-09-28T10:00:00Z"))

    # A document without a basis has no "basis" fact at all.
    assert {:ok, %{"valid" => true}} =
             Engine.evaluate(graph, %{"event" => %{"at" => "2026-09-29T10:00:00Z"}})
  end

  test "recorded leave: overlaps and the yearly balance", ctx do
    leave = fn first, last, days ->
      record_fixture(ctx.person, :leave, %{
        "leaveType" => "annual",
        "startDate" => first,
        "endDate" => last,
        "days" => days
      })
    end

    leave.("2025-03-01", "2025-03-20", 20)
    assert incidents() == []

    leave.("2025-03-15", "2025-03-19", 5)
    assert incidents() == [{"leave_no_overlap", "leave_overlap"}]

    leave.("2025-06-01", "2025-06-10", 10)
    assert {"leave_within_balance", "leave_over_balance"} in incidents()
  end

  test "seeding plants violations without raising incidents while FSDC is on" do
    {:ok, %{invalid: invalid}} = App.Demo.seed(people: 40, seed: 3)
    assert invalid > 0
    assert incidents() == []
  end

  test "a leave request taking the unit over its limit is flagged, not blocked", ctx do
    company = org_fixture("A Company")
    soldier = unit_user_fixture(:viewer, [], company, nil)
    commander = unit_user_fixture(:viewer, [:commander], company)
    away = person_fixture(%{given_name: "Away"}) |> assign_fixture(company)

    record_fixture(away, :leave, %{
      "leaveType" => "annual",
      "startDate" => "2026-11-02",
      "endDate" => "2026-11-06",
      "days" => 5
    })

    request = fn first, last ->
      App.Documents.Document
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: :leave_request,
          person_id: soldier.person_id,
          data: %{"leaveType" => "annual", "startDate" => first, "endDate" => last}
        },
        actor: soldier
      )
      |> Ash.create!(actor: soldier)
      |> Ash.Changeset.for_update(:submit, %{assignees: [[commander.id], [ctx.hr.id]]},
        actor: soldier
      )
      |> Ash.update(actor: soldier)
    end

    # Nobody else away then: fine.
    assert {:ok, _} = request.("2026-12-01", "2026-12-03")
    refute {"leave_within_unit_limit", "leave_over_unit_limit"} in incidents()

    # Three in the unit, 30 % → one may be away, and one already is.
    assert {:ok, _} = request.("2026-11-04", "2026-11-05")
    assert {"leave_within_unit_limit", "leave_over_unit_limit"} in incidents()
  end

  test "a downgraded status needs a signed board conclusion of the person; fit for duty doesn't",
       ctx do
    record_fixture(ctx.person, :fitness_for_duty, %{"status" => "fit_for_duty"})
    assert incidents() == []

    conclusion =
      App.Documents.Document
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: :medical_board_conclusion,
          person_id: ctx.person.id,
          data: %{"conclusion" => "fit_with_restrictions"}
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)
      |> Ash.Seed.update!(%{state: :signed, number: "7-влк"})

    record_fixture(ctx.person, :fitness_for_duty, %{
      "status" => "downgraded",
      "basis" => conclusion.number
    })

    assert incidents() == []

    # Someone else's conclusion doesn't count.
    other = person_fixture()
    record_fixture(other, :fitness_for_duty, %{"status" => "non_effective", "basis" => "7-влк"})
    assert incidents() == [{"fitness_from_signed_conclusion", "fitness_without_conclusion"}]
  end
end
