defmodule App.Documents.MedicalBoardTest do
  @moduledoc "docs/design/documents-core.md: the medical board process end to end."
  use App.DataCase, async: false

  alias App.Documents.Queries

  import App.Fixtures

  require Ash.Query

  alias App.Documents.{Document, Types}
  alias App.People.PersonRecord

  setup do
    App.Access.put_admin_full_data_access_override(false)
    unit = org_fixture("A Company")
    patient = person_fixture(%{given_name: "Newcomer"}) |> assign_fixture(unit)

    %{
      unit: unit,
      patient: patient,
      hr: user_fixture(:hr),
      hr_head: user_fixture(:hr),
      member1: unit_user_fixture(:viewer, [:clinician], unit),
      member2: unit_user_fixture(:viewer, [:clinician], unit),
      chair: unit_user_fixture(:viewer, [:clinician], unit)
    }
  end

  defp act(document, action, actor, args \\ %{}) do
    document
    |> Ash.Changeset.for_update(action, args, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp reload(document, actor), do: Ash.get!(Document, document.id, actor: actor, load: [:data])

  defp signed_referral(%{patient: patient, hr: hr, hr_head: hr_head}) do
    {:ok, referral} =
      Document
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: :medical_board_referral,
          person_id: patient.id,
          data: %{"reason" => "entry", "plannedDate" => "2026-10-05"}
        },
        actor: hr
      )
      |> Ash.create(actor: hr)

    # Sent and signed as read without its fields (not every caller loads them).
    referral = Ash.get!(Document, referral.id, actor: hr)
    {:ok, referral} = act(referral, :submit, hr, %{assignees: [[hr_head.id]]})

    # Signed as read without its fields (not every caller loads them).
    {:ok, referral} =
      act(Ash.get!(Document, referral.id, actor: hr_head), :sign, hr_head)

    referral
  end

  defp open_conclusion(referral) do
    Document
    |> Ash.Query.filter(basis_id == ^referral.id and type == :medical_board_conclusion)
    |> Ash.read_one!(authorize?: false)
  end

  @conclusion %{
    "examinations" => %{
      "therapist" => %{"findings" => "BP 150/95", "opinion" => "fit_with_restrictions"}
    },
    "mainDiagnosis" => %{
      "text" => "Essential hypertension",
      "icd10" => "I10",
      "severity" => "mild"
    },
    "functionalLimitation" => "mild",
    "conclusion" => "fit_with_restrictions",
    "restrictions" => ["no_heavy_lifting"],
    "restrictionsText" => "No duty over 12 hours",
    "reexaminationDate" => "2027-03-01"
  }

  test "referral → conclusion → fitness for duty, re-examination scheduled", ctx do
    referral = signed_referral(ctx)

    assert referral.state == :signed
    assert referral.number == "1-нвлк"
    assert referral.register == "нвлк" and referral.register_seq == 1

    # FHIR form: the stable UUID, and the number within its register and year.
    year = Date.utc_today().year

    assert %{
             "masterIdentifier" => %{"value" => "urn:uuid:" <> _},
             "identifier" => [%{"system" => system, "value" => "1-нвлк"}]
           } = Types.identifiers(referral)

    assert system == "urn:hrda:register:нвлк:#{year}"
    assert byte_size(referral.content_sha256) == 64
    assert App.StorageStub.object(referral.pdf_key) =~ "%PDF"

    # The referral opened a draft conclusion for the board.
    conclusion = open_conclusion(referral)
    assert conclusion.state == :draft and conclusion.author_id == nil
    %{member1: m1, member2: m2, chair: chair} = ctx

    {:ok, conclusion} = act(reload(conclusion, m1), :update_fields, m1, %{data: @conclusion})

    {:ok, conclusion} =
      act(reload(conclusion, m1), :submit, m1, %{assignees: [[m1.id, m2.id], [chair.id]]})

    # Board members decide in parallel, in any order
    # (docs/design/parallel-approval.md); the chair signs after all of them.
    assert {:error, %Ash.Error.Forbidden{}} = act(conclusion, :sign, chair)
    {:ok, conclusion} = act(conclusion, :approve, m2, %{comment: "Agree"})
    assert {:error, %Ash.Error.Forbidden{}} = act(conclusion, :sign, chair)
    assert {:error, _} = act(conclusion, :approve, m2)
    {:ok, conclusion} = act(conclusion, :approve, m1)
    {:ok, conclusion} = act(reload(conclusion, chair), :sign, chair)

    assert conclusion.number == "1-влк"
    assert App.StorageStub.object(conclusion.pdf_key) =~ "%PDF"

    # Effect: fitness for duty (no diagnosis in it), based on the conclusion.
    [fitness] =
      PersonRecord
      |> Ash.Query.filter(person_id == ^ctx.patient.id and kind == :fitness_for_duty)
      |> Ash.read!(authorize?: false)

    assert %{"status" => "downgraded", "reviewDate" => "2027-03-01", "basis" => number} =
             fitness.data

    assert number == conclusion.number
    assert fitness.data["restrictions"] =~ "No duty over 12 hours"
    refute inspect(fitness.data) =~ "hypertension"

    # Effect: a referral scheduled for the re-examination.
    scheduled =
      Document |> Ash.Query.filter(basis_id == ^conclusion.id) |> Ash.read_one!(authorize?: false)

    assert scheduled.type == :medical_board_referral and scheduled.state == :draft
    assert scheduled.due_on == ~D[2027-03-01]

    # History: sent, approved twice, signed, two effects.
    trail = Queries.load_trail(conclusion)
    assert Enum.count(trail.events, &(&1.action == :approved)) == 2
    assert Enum.count(trail.events, &(&1.action == :effect_applied)) == 2
  end

  test "HR reads the referral and the fitness status, never the conclusion", ctx do
    referral = signed_referral(ctx)
    conclusion = open_conclusion(referral)

    readable = Document |> Ash.read!(actor: ctx.hr) |> Enum.map(& &1.id)
    assert referral.id in readable
    refute conclusion.id in readable
  end

  test "a returned conclusion goes back as a draft; sent again, a new round", ctx do
    %{member1: m1, chair: chair} = ctx
    conclusion = ctx |> signed_referral() |> open_conclusion()

    {:ok, conclusion} = act(reload(conclusion, m1), :update_fields, m1, %{data: @conclusion})

    {:ok, conclusion} =
      act(reload(conclusion, m1), :submit, m1, %{assignees: [[m1.id], [chair.id]]})

    {:ok, conclusion} = act(conclusion, :approve, m1)

    assert {:error, _} = act(conclusion, :return, chair, %{comment: ""})
    {:ok, conclusion} = act(conclusion, :return, chair, %{comment: "Add the ENT findings"})
    assert conclusion.state == :draft

    {:ok, conclusion} =
      act(reload(conclusion, m1), :submit, m1, %{assignees: [[m1.id], [chair.id]]})

    assert Queries.current_step(conclusion).round == 2
  end

  test "sending checks every rule; a wrong assignee changes nothing", ctx do
    %{member1: m1, chair: chair, hr: hr} = ctx
    conclusion = ctx |> signed_referral() |> open_conclusion()

    {:ok, conclusion} =
      act(reload(conclusion, m1), :update_fields, m1, %{
        data: %{"conclusion" => "temporarily_unfit"}
      })

    assert {:error, error} =
             act(reload(conclusion, m1), :submit, m1, %{assignees: [[m1.id], [chair.id]]})

    assert Exception.message(error) =~ "Temporarily unfit needs a re-examination date"

    {:ok, conclusion} =
      act(reload(conclusion, m1), :update_fields, m1, %{data: @conclusion})

    # HR can't be a board member (no medical.write).
    assert {:error, error} =
             act(reload(conclusion, m1), :submit, m1, %{assignees: [[hr.id], [chair.id]]})

    assert Exception.message(error) =~ "does not hold the permission"
    assert reload(conclusion, m1).state == :draft
  end

  test "reading a conclusion is in the access log", ctx do
    conclusion = ctx |> signed_referral() |> open_conclusion()
    reload(conclusion, ctx.member1)

    assert Enum.any?(
             Ash.read!(App.Audit.AccessLog, authorize?: false),
             &(&1.record_id == conclusion.id and &1.kind == "document:medical_board_conclusion")
           )
  end

  # docs/design/acknowledgements.md: the person acknowledges their conclusion.
  test "the person acknowledges their conclusion; a board member may record it, a commander can't",
       ctx do
    referral = signed_referral(ctx)
    conclusion = open_conclusion(referral)
    %{member1: m1, member2: m2, chair: chair} = ctx

    {:ok, conclusion} = act(reload(conclusion, m1), :update_fields, m1, %{data: @conclusion})

    {:ok, conclusion} =
      act(reload(conclusion, m1), :submit, m1, %{assignees: [[m1.id, m2.id], [chair.id]]})

    {:ok, conclusion} = act(conclusion, :approve, m1)
    {:ok, conclusion} = act(conclusion, :approve, m2)
    {:ok, conclusion} = act(reload(conclusion, chair), :sign, chair)

    patient_account =
      Ash.Seed.seed!(App.Accounts.User, %{
        email: "patient-#{Ash.UUIDv7.generate()}@example.test",
        role: :viewer,
        person_id: ctx.patient.id
      })

    commander = unit_user_fixture(:viewer, [:commander], ctx.unit)

    # Theirs to read once signed, and waiting in their tasks.
    assert {:ok, _} = Ash.get(Document, conclusion.id, actor: patient_account)
    assert [%{id: id}] = Queries.to_acknowledge(patient_account)
    assert id == conclusion.id

    # A commander signs orders but can't read the conclusion: can't record it.
    refute App.Documents.Access.can_record_acknowledgement?(commander, conclusion)
    assert Queries.pending_acknowledgements(commander) == []
    # A board member (medical.write) can.
    assert App.Documents.Access.can_record_acknowledgement?(m1, conclusion)

    assert {:ok, %{method: :self}} =
             App.Documents.Acknowledgement
             |> Ash.Changeset.for_create(:acknowledge, %{document_id: conclusion.id},
               actor: patient_account
             )
             |> Ash.create(actor: patient_account)
  end
end
