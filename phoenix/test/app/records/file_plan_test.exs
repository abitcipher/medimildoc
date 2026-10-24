defmodule App.Records.FilePlanTest do
  @moduledoc "docs/design/registers-file-plan.md: the file plan, filing, registers."
  use App.DataCase, async: false

  import App.Fixtures

  alias App.Documents.{Document, Print, Queries}
  alias App.Records.{Case, DisposalAct, FilePlan, Inventory, Registers}

  setup do
    App.Access.put_admin_full_data_access_override(false)
    company = org_fixture("A Company", org_fixture("1st Brigade"))

    %{
      company: company,
      soldier: unit_user_fixture(:viewer, [], company, nil),
      hr: user_fixture(:hr),
      commander: unit_user_fixture(:viewer, [:commander], company),
      records: user_fixture(:viewer, [:records_officer]),
      year: Date.utc_today().year
    }
  end

  defp signed_order(ctx) do
    ctx.hr
    |> then(fn hr ->
      Document
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: :personnel_order_grade,
          person_id: ctx.soldier.person_id,
          data: %{"grade" => "OR-4", "effectiveDate" => Date.to_iso8601(Date.utc_today())}
        },
        actor: hr
      )
      |> Ash.create!(actor: hr)
    end)
    |> run(:submit, ctx.hr, %{assignees: [[ctx.hr.id], [ctx.commander.id]]})
    |> run(:approve, ctx.hr)
    |> run(:sign, ctx.commander)
  end

  defp run(document, action, actor, args \\ %{}) do
    document |> Ash.Changeset.for_update(action, args, actor: actor) |> Ash.update!(actor: actor)
  end

  defp new_case(ctx, attrs) do
    Case
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{year: ctx.year, title: "Orders", retention: "75 р."}, attrs),
      actor: ctx.records
    )
    |> Ash.create(actor: ctx.records)
  end

  test "the template gives a year's plan; a signed order is filed into its type's case", ctx do
    assert FilePlan.copy(:template, ctx.year, ctx.records) == length(FilePlan.template())
    # Again: nothing new.
    assert FilePlan.copy(:template, ctx.year, ctx.records) == 0

    order = signed_order(ctx)
    [kase] = Enum.filter(FilePlan.cases(ctx.year, ctx.records), &(&1.id == order.case_id))
    assert kase.index == "03-01"
    assert FilePlan.counts([kase.id]) == %{kase.id => 1}

    # Not empty: can't be removed.
    assert FilePlan.delete(kase, ctx.records) == {:error, :not_empty}

    # Next year from this one.
    assert FilePlan.copy(ctx.year, ctx.year + 1, ctx.records) == length(FilePlan.template())
  end

  test "documents signed before their case existed are filed when it is created", ctx do
    order = signed_order(ctx)
    assert order.case_id == nil

    {:ok, kase} = new_case(ctx, %{index: "03-01", document_types: ["personnel_order_grade"]})
    assert FilePlan.file_backlog(kase) == 1
    assert Ash.get!(Document, order.id, authorize?: false).case_id == kase.id
  end

  test "a type goes into one case a year; unknown types are refused; only the records officer edits",
       ctx do
    {:ok, _} = new_case(ctx, %{index: "03-01", document_types: ["personnel_order_grade"]})

    assert {:error, error} =
             new_case(ctx, %{index: "03-02", document_types: ["personnel_order_grade"]})

    assert Exception.message(error) =~ "already filed into case 03-01"
    assert {:error, _} = new_case(ctx, %{index: "03-03", document_types: ["no_such_type"]})
    assert {:error, _} = new_case(ctx, %{index: "03-01", document_types: []})

    assert {:error, %Ash.Error.Forbidden{}} =
             Case
             |> Ash.Changeset.for_create(
               :create,
               %{year: ctx.year, index: "09-01", title: "X", retention: "1 р."},
               actor: ctx.hr
             )
             |> Ash.create(actor: ctx.hr)

    # HR reads the plan.
    assert [_] = FilePlan.cases(ctx.year, ctx.hr)
  end

  test "a register lists numbers to everyone allowed; the person only to who may read the document",
       ctx do
    order = signed_order(ctx)
    code = order.register
    assert Enum.any?(Registers.codes(), &(elem(&1, 0) == code))

    filters = %{code: code, year: ctx.year}
    assert %{total: 1, entries: [entry]} = Registers.entries(filters, ctx.hr)
    assert entry.number == order.number and entry.readable?
    assert entry.person =~ "Staff"

    # A commander of another unit can't read this order: number yes, name no.
    other = unit_user_fixture(:viewer, [:commander], org_fixture("B Company"))
    assert %{entries: [hidden]} = Registers.entries(filters, other)
    assert hidden.number == order.number and not hidden.readable? and hidden.person == nil
  end

  describe "closing, inventory, disposal (§Closing)" do
    test "a closed case takes no new documents; reopened, it takes them", ctx do
      {:ok, kase} =
        new_case(ctx, %{
          index: "03-01",
          document_types: ["personnel_order_grade"],
          retention_years: 75
        })

      assert FilePlan.close_year(ctx.year, ctx.records) == 1
      assert FilePlan.close_year(ctx.year, ctx.records) == 0

      order = signed_order(ctx)
      assert order.case_id == nil

      kase = Ash.get!(Case, kase.id, actor: ctx.records)
      assert kase.closed_on == Date.utc_today()
      assert FilePlan.file_backlog(kase) == 0

      # HR reads the plan but doesn't close or reopen cases.
      assert {:error, %Ash.Error.Forbidden{}} =
               kase |> Ash.Changeset.for_update(:reopen, %{}, actor: ctx.hr) |> Ash.update()

      {:ok, kase} =
        kase |> Ash.Changeset.for_update(:reopen, %{}, actor: ctx.records) |> Ash.update()

      assert FilePlan.file_backlog(kase) == 1
    end

    test "the inventory lists the closed cases of a class with their dates; the PDF prints them",
         ctx do
      {:ok, kase} =
        new_case(ctx, %{
          index: "03-01",
          document_types: ["personnel_order_grade"],
          retention_years: 75
        })

      order = signed_order(ctx)
      assert order.case_id == kase.id

      # The case index is on the printed document.
      payload =
        order
        |> Queries.load_trail()
        |> Ash.load!([:person, :basis, :data], authorize?: false)
        |> Print.payload()

      assert payload["case"] == "03-01"

      # Open cases aren't in the inventory yet.
      assert FilePlan.inventory(ctx.year, :long, ctx.records) == []
      FilePlan.close_year(ctx.year, ctx.records)

      today = Date.utc_today()

      assert [%{case: %{index: "03-01"}, first: ^today, last: ^today, documents: 1}] =
               FilePlan.inventory(ctx.year, :long, ctx.records)

      assert FilePlan.inventory(ctx.year, :temporary, ctx.records) == []

      assert {:ok, <<"%PDF", _::binary>>} =
               Inventory.pdf(ctx.year, :long, ctx.records)
    end

    test "closed temporary cases past their period are due for disposal; permanent never", ctx do
      old = %{year: 2020, title: "Old", retention: "3 р."}

      {:ok, short} = new_case(ctx, Map.merge(old, %{index: "01-01", retention_years: 3}))
      {:ok, _long} = new_case(ctx, Map.merge(old, %{index: "01-02", retention_years: 75}))

      {:ok, _forever} =
        new_case(ctx, Map.merge(old, %{index: "01-03", permanent: true, retention_years: 3}))

      {:ok, _open} = new_case(ctx, %{index: "01-04", retention_years: 1, year: 2020})

      FilePlan.close_year(2020, ctx.records)
      # The open one was closed too; reopen it to check open cases aren't listed.
      FilePlan.cases(2020, ctx.records)
      |> Enum.find(&(&1.index == "01-04"))
      |> Ash.Changeset.for_update(:reopen, %{}, actor: ctx.records)
      |> Ash.update!()

      assert [%{id: id}] = FilePlan.due_for_disposal(~D[2026-10-07], ctx.records)
      assert id == short.id

      assert {:ok, <<"%PDF", _::binary>>} =
               DisposalAct.pdf(~D[2026-10-07], ctx.records)

      assert FilePlan.due_for_disposal(~D[2023-06-01], ctx.records) == []
      assert FilePlan.category(short) == :temporary
    end
  end
end
