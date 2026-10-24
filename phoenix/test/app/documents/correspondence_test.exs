defmodule App.Documents.CorrespondenceTest do
  @moduledoc "docs/design/correspondence.md: incoming and outgoing letters, instructions."
  use App.DataCase, async: false

  import App.Fixtures

  require Ash.Query

  alias App.Documents.{Document, Drafts, Files, Instruction, Instructions, Queries, Reminders}
  alias App.Records.FilePlan

  setup do
    App.Access.put_admin_full_data_access_override(false)
    company = org_fixture("A Company", org_fixture("1st Brigade"))

    %{
      company: company,
      records: user_fixture(:viewer, [:records_officer]),
      commander: unit_user_fixture(:viewer, [:commander], company),
      other_commander: unit_user_fixture(:viewer, [:commander], org_fixture("B Company")),
      hr: user_fixture(:hr),
      hr2: user_fixture(:hr)
    }
  end

  defp create(type, data, actor, extra \\ %{}) do
    Document
    |> Ash.Changeset.for_create(:create, Map.merge(%{type: type, data: data}, extra),
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  defp run(document, action, actor, args \\ %{}) do
    document |> Ash.Changeset.for_update(action, args, actor: actor) |> Ash.update(actor: actor)
  end

  defp pdf_file do
    path = Path.join(System.tmp_dir!(), "scan-#{System.unique_integer([:positive])}.pdf")
    File.write!(path, "%PDF-1.4\n% scan\n")
    path
  end

  defp registered_letter(ctx) do
    {:ok, letter} =
      create(
        :incoming_letter,
        %{
          "sender" => "Regional military administration",
          "senderNumber" => "12/345",
          "senderDate" => Date.to_iso8601(Date.add(Date.utc_today(), -3)),
          "receivedOn" => Date.to_iso8601(Date.utc_today()),
          "summary" => "Request for a list of staff on leave",
          "unit" => ctx.company.id
        },
        ctx.records
      )

    {:ok, _file} = Files.attach(ctx.records, letter, pdf_file(), "scan.pdf")
    assert Drafts.registers_directly?(ctx.records, letter)
    {:ok, letter} = run(letter, :submit, ctx.records, %{assignees: [[ctx.records.id]]})
    {:ok, letter} = run(letter, :sign, ctx.records)
    letter
  end

  defp give(ctx, letter, actor, executor, due_on) do
    Instruction
    |> Ash.Changeset.for_create(
      :give,
      %{
        document_id: letter.id,
        text: "Prepare a reply",
        executor_id: executor.id,
        due_on: due_on
      },
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  test "letters are about no person; other documents need one", ctx do
    assert {:error, _} =
             create(:incoming_letter, %{"sender" => "X"}, ctx.records, %{
               person_id: ctx.commander.person_id
             })

    assert {:error, _} =
             create(:personnel_order_grade, %{"grade" => "OR-4"}, ctx.hr)
  end

  test "the records officer registers a letter with its scan; heads of its unit read it", ctx do
    FilePlan.copy(:template, Date.utc_today().year, ctx.records)
    letter = registered_letter(ctx)

    assert letter.state == :signed and letter.number =~ "-вх"
    assert letter.case_id
    assert [%{file_name: "scan.pdf"}] = Files.list(letter)
    assert {:ok, _url} = Files.link(ctx.commander, letter.id, hd(Files.list(letter)).id)

    assert {:ok, _} = Ash.get(Document, letter.id, actor: ctx.commander)
    assert {:error, _} = Ash.get(Document, letter.id, actor: ctx.other_commander)
    assert {:error, _} = Files.link(ctx.other_commander, letter.id, hd(Files.list(letter)).id)
  end

  test "a head gives an instruction; the executor reads the letter, replies, and the reply closes it",
       ctx do
    letter = registered_letter(ctx)
    tomorrow = Date.add(Date.utc_today(), 1)

    # Not a head of the letter's unit.
    assert {:error, %Ash.Error.Forbidden{}} =
             give(ctx, letter, ctx.other_commander, ctx.hr, tomorrow)

    {:ok, instruction} = give(ctx, letter, ctx.commander, ctx.hr, tomorrow)
    assert instruction.issued_by_id == ctx.commander.id

    # The executor: the letter in their tasks, readable.
    assert [%{id: id, due: ^tomorrow}] = Queries.inbox(ctx.hr).instructions
    assert id == letter.id
    assert %{count: 1, overdue: 0} = Queries.waiting_count(ctx.hr)
    assert {:ok, _} = Ash.get(Document, letter.id, actor: ctx.hr)

    # Only the executor (or the records officer) writes a reply.
    reply_data = %{
      "addressee" => "Regional military administration",
      "subject" => "Reply",
      "text" => "The list is enclosed.",
      "unit" => ctx.company.id
    }

    assert {:error, _} = create(:outgoing_letter, reply_data, ctx.hr2, %{basis_id: letter.id})
    {:ok, reply} = create(:outgoing_letter, reply_data, ctx.hr, %{basis_id: letter.id})
    assert Drafts.editable?(ctx.hr, reply)

    {:ok, reply} =
      run(reply, :submit, ctx.hr, %{assignees: [[], [ctx.records.id], [ctx.commander.id]]})

    {:ok, reply} = run(reply, :approve, ctx.records)
    {:ok, reply} = run(reply, :sign, ctx.commander)
    assert reply.number =~ "-вих"

    assert [%{status: :done, reply_id: reply_id}] = Instructions.for_document(letter)
    assert reply_id == reply.id
    assert Queries.inbox(ctx.hr).instructions == []
  end

  test "the executor closes an instruction with a note; an overdue one is reminded once", ctx do
    letter = registered_letter(ctx)
    {:ok, late} = give(ctx, letter, ctx.records, ctx.hr, Date.add(Date.utc_today(), -1))
    {:ok, other} = give(ctx, letter, ctx.records, ctx.hr2, nil)

    assert %{overdue: 1} = Queries.waiting_count(ctx.hr)
    assert Reminders.run() == 1
    assert Reminders.run() == 0

    # Someone else can't close it; the executor can.
    assert {:error, _} = run(other, :complete, ctx.hr, %{done_note: "x"})
    assert {:ok, done} = run(other, :complete, ctx.hr2, %{done_note: "Taken into account"})
    assert done.status == :done and done.done_at
    assert late.status == :open
  end

  test "co-approvers decide in parallel; the next stage starts when all have; one return ends it",
       ctx do
    letter = registered_letter(ctx)

    data = %{
      "addressee" => "Regional military administration",
      "subject" => "Reply",
      "text" => "Text",
      "unit" => ctx.company.id
    }

    {:ok, reply} = create(:outgoing_letter, data, ctx.records, %{basis_id: letter.id})

    {:ok, reply} =
      run(reply, :submit, ctx.records, %{
        assignees: [[ctx.hr.id, ctx.hr2.id], [ctx.records.id], [ctx.commander.id]]
      })

    pending = fn ->
      App.Documents.Step
      |> Ash.Query.filter(document_id == ^reply.id and status == :pending)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.assignee_id)
      |> Enum.sort()
    end

    # Both co-approvers at once; the records officer waits.
    assert pending.() == Enum.sort([ctx.hr.id, ctx.hr2.id])
    assert [_] = Queries.inbox(ctx.hr2).to_decide
    assert {:error, _} = run(reply, :approve, ctx.records)

    {:ok, reply} = run(reply, :approve, ctx.hr2)
    assert pending.() == [ctx.hr.id]
    {:ok, reply} = run(reply, :approve, ctx.hr)
    assert pending.() == [ctx.records.id]

    # Sent again after a return: a co-approver's return ends the round.
    {:ok, other} = create(:outgoing_letter, data, ctx.records, %{basis_id: letter.id})

    {:ok, other} =
      run(other, :submit, ctx.records, %{
        assignees: [[ctx.hr.id, ctx.hr2.id], [ctx.records.id], [ctx.commander.id]]
      })

    {:ok, other} = run(other, :return, ctx.hr, %{comment: "Fix the address"})
    assert other.state == :draft
    assert {:error, _} = run(other, :approve, ctx.hr2)

    # The co-approval stage may be left empty.
    {:ok, third} = create(:outgoing_letter, data, ctx.records, %{basis_id: letter.id})

    assert {:ok, _} =
             run(third, :submit, ctx.records, %{
               assignees: [[], [ctx.records.id], [ctx.commander.id]]
             })

    _ = reply
  end
end
