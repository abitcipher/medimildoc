defmodule App.Documents.Effects do
  @moduledoc """
  What a signed document does (docs/design/documents-core.md), declared per
  type in `effects`. Each runs in the signing transaction, as the system
  (`authorize?: false`: the signer's authority is the signature itself),
  and is recorded in the document's history.

  - `open_conclusion` — a referral opens a draft conclusion for the
    medical board, based on it, due on the planned date.
  - `fitness_for_duty` — a conclusion sets the person's fitness for duty:
    status, duty restrictions (never a diagnosis), review date, assessed
    by the board, basis = the conclusion's number.
  - `schedule_reexamination` — a conclusion with a re-examination date
    schedules a referral due then.
  - Personnel orders: `assignment_start` (appointment), `assignment_transfer`
    (the current assignment ends the day before, the new one starts),
    `assignment_end` (release), `rank_record` (a rank history record).
    Assignments remember the order (`basis_document_id`,
    `end_document_id`); `check/1` tells, when the order is sent and again
    when it is signed, whether its effects can still be applied.
  - Leave (docs/design/leave.md): `leave_order_draft` — an accepted
    request drafts the leave order, based on it; `leave_record` — a signed
    leave order records the leave (person record `leave`).
  - Care (docs/design/referral-discharge.md): `open_discharge_summary` —
    a signed referral opens a draft discharge summary for the provider,
    based on it; `business_trip_record` — the trip as a `business_trip`
  record (docs/design/business-trips.md); `sick_leave` — a signed summary with a sick-leave period
    records it as the person's absence (person record `leave`, type
    `sick`, basis = the summary's number, never the diagnosis).
  """

  alias App.Documents.{Certificates, Document, Instructions, Labels, Types}
  alias App.Documents.Changes.RecordEvent
  alias App.People.{Assignment, PersonRecord}

  require Ash.Query

  @print_locale "uk"

  # Writes run inside the signing transaction. The rule check's
  # after-transaction hook (App.Rules.Changes.Check) therefore runs inside
  # it too, so an incident it records commits or rolls back with the
  # signature — intended; Ash's warning about it is switched off here.
  @system_write %{warn_on_transaction_hooks?: false}

  @spec apply_all(map(), map()) :: :ok | {:error, term()}
  def apply_all(document, actor) do
    Enum.reduce_while(Types.effects(document.type), :ok, fn effect, :ok ->
      effect |> run(document) |> recorded(document, actor)
    end)
  end

  defp recorded({:ok, nil}, _document, _actor), do: {:cont, :ok}

  defp recorded({:ok, note}, document, actor) do
    RecordEvent.write(document, :effect_applied, actor, note)
    {:cont, :ok}
  end

  defp recorded({:error, _} = error, _document, _actor), do: {:halt, error}

  # A signed reply closes the instructions on its incoming letter
  # (docs/design/correspondence.md).
  defp run("close_instructions", document) do
    case Instructions.close_by_reply(document) do
      {:ok, 0} -> {:ok, nil}
      {:ok, _closed} -> {:ok, "instructions"}
    end
  end

  defp run("open_conclusion", document) do
    with {:ok, _} <-
           create_document(%{
             type: :medical_board_conclusion,
             person_id: document.person_id,
             basis_id: document.id,
             due_on: parse_date(document.data["plannedDate"]),
             data: %{}
           }) do
      {:ok, "medical_board_conclusion"}
    end
  end

  defp run("fitness_for_duty", document) do
    data = document.data

    record =
      %{
        "status" => fitness_status(data["conclusion"]),
        "restrictions" => restrictions(data),
        "reviewDate" => data["reexaminationDate"],
        "assessedBy" => Labels.impl().text("Medical board", @print_locale),
        "basis" => document.number
      }
      |> Map.reject(fn {_k, v} -> v in [nil, ""] end)

    PersonRecord
    |> Ash.Changeset.for_create(
      :create,
      %{person_id: document.person_id, kind: :fitness_for_duty, data: record},
      authorize?: false,
      context: @system_write
    )
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _} -> {:ok, "fitness_for_duty"}
      error -> error
    end
  end

  defp run("schedule_reexamination", %{data: %{"reexaminationDate" => date}} = document)
       when is_binary(date) do
    with {:ok, _} <-
           create_document(%{
             type: :medical_board_referral,
             person_id: document.person_id,
             basis_id: document.id,
             due_on: parse_date(date),
             data: %{"reason" => "reexamination", "plannedDate" => date}
           }) do
      {:ok, "medical_board_referral"}
    end
  end

  defp run("schedule_reexamination", _document), do: {:ok, nil}

  defp run("assignment_start", document) do
    with {:ok, _} <-
           create_assignment(document, document.data["position"], effective_date(document)),
         do: {:ok, "assignment"}
  end

  defp run("assignment_transfer", document) do
    date = effective_date(document)

    with {:ok, _} <- end_assignment(current(document), document, Date.add(date, -1)),
         {:ok, _} <- create_assignment(document, document.data["position"], date),
         do: {:ok, "assignment"}
  end

  defp run("assignment_end", document) do
    with {:ok, _} <- end_assignment(current(document), document, effective_date(document)),
         do: {:ok, "assignment"}
  end

  defp run("leave_order_draft", document) do
    with {:ok, _} <-
           create_document(%{
             type: :personnel_order_leave,
             person_id: document.person_id,
             basis_id: document.id,
             data: Map.take(document.data, ~w(leaveType startDate endDate destination))
           }) do
      {:ok, "personnel_order_leave"}
    end
  end

  # docs/design/business-trips.md: an accepted request drafts the order.
  defp run("business_trip_order_draft", document) do
    with {:ok, _} <-
           create_document(%{
             type: :personnel_order_business_trip,
             person_id: document.person_id,
             basis_id: document.id,
             data:
               Map.take(document.data, ~w(destination purpose startDate endDate transport note))
           }) do
      {:ok, "personnel_order_business_trip"}
    end
  end

  defp run("leave_record", document) do
    data = document.data

    record =
      %{
        "leaveType" => data["leaveType"],
        "startDate" => data["startDate"],
        "endDate" => data["endDate"],
        "days" => App.Leave.days(data["startDate"], data["endDate"]),
        "destination" => data["destination"],
        "basis" => document.number
      }
      |> Map.reject(fn {_k, v} -> v in [nil, ""] end)

    PersonRecord
    |> Ash.Changeset.for_create(
      :create,
      %{person_id: document.person_id, kind: :leave, data: record},
      authorize?: false,
      context: @system_write
    )
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _} -> {:ok, "leave"}
      error -> error
    end
  end

  # docs/design/business-trips.md: the trip as a person record.
  defp run("business_trip_record", document) do
    data = document.data

    record =
      %{
        "destination" => data["destination"],
        "purpose" => data["purpose"],
        "startDate" => data["startDate"],
        "endDate" => data["endDate"],
        "days" => App.Leave.days(data["startDate"], data["endDate"]),
        "transport" => data["transport"],
        "note" => data["note"],
        "basis" => document.number
      }
      |> Map.reject(fn {_k, v} -> v in [nil, ""] end)

    PersonRecord
    |> Ash.Changeset.for_create(
      :create,
      %{person_id: document.person_id, kind: :business_trip, data: record},
      authorize?: false,
      context: @system_write
    )
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _} -> {:ok, "business trip"}
      error -> error
    end
  end

  defp run("open_discharge_summary", document) do
    with {:ok, _} <-
           create_document(%{
             type: :discharge_summary,
             person_id: document.person_id,
             basis_id: document.id,
             due_on: parse_date(document.data["plannedDate"]),
             data: Map.take(document.data, ["provider"])
           }) do
      {:ok, "discharge_summary"}
    end
  end

  defp run("sick_leave", %{data: %{"sickLeaveFrom" => from, "sickLeaveTo" => to}} = document)
       when is_binary(from) and is_binary(to) do
    PersonRecord
    |> Ash.Changeset.for_create(
      :create,
      %{
        person_id: document.person_id,
        kind: :leave,
        data: %{
          "leaveType" => "sick",
          "startDate" => from,
          "endDate" => to,
          "days" => App.Leave.days(from, to),
          "basis" => document.number
        }
      },
      authorize?: false,
      context: @system_write
    )
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _} -> {:ok, "leave"}
      error -> error
    end
  end

  defp run("sick_leave", _document), do: {:ok, nil}

  defp run("rank_record", document) do
    data =
      Map.reject(
        %{
          "grade" => document.data["grade"],
          "gradeTitle" => document.data["gradeTitle"],
          "effectiveDate" => document.data["effectiveDate"],
          "note" => document.number
        },
        fn {_k, v} -> v in [nil, ""] end
      )

    PersonRecord
    |> Ash.Changeset.for_create(
      :create,
      %{person_id: document.person_id, kind: :rank_history, data: data},
      authorize?: false,
      context: @system_write
    )
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _} -> {:ok, "rank_history"}
      error -> error
    end
  end

  @doc """
  Whether `document`'s effects can be applied now: `:ok`, or the reason
  they can't (English; the page translates it). Checked when the document
  is sent and again when it is signed. Certificates need a valid period or
  year (`App.Documents.Certificates.check/2`).
  """
  @spec check(map()) :: :ok | {:error, String.t()}
  def check(document) do
    with :ok <- Certificates.check(document.type, document.data) do
      check_effects(document)
    end
  end

  defp check_effects(document) do
    Enum.reduce_while(Types.effects(document.type), :ok, fn effect, :ok ->
      case precheck(effect, document) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp precheck("assignment_start", document) do
    if current(document),
      do: {:error, "The person already holds a post; use a transfer order."},
      else: position_exists(document)
  end

  defp precheck("assignment_transfer", document) do
    current = current(document)
    date = effective_date(document)

    cond do
      is_nil(current) ->
        {:error, "The person holds no post; use an appointment order."}

      current.position_id == document.data["position"] ->
        {:error, "The person already holds this post."}

      date && Date.compare(date, current.starts_on) != :gt ->
        {:error, "The transfer must be after the current post started."}

      true ->
        position_exists(document)
    end
  end

  defp precheck("assignment_end", document) do
    current = current(document)
    date = effective_date(document)

    cond do
      is_nil(current) ->
        {:error, "The person holds no post to be released from."}

      date && Date.compare(date, current.starts_on) == :lt ->
        {:error, "The release date is before the current post started."}

      true ->
        :ok
    end
  end

  defp precheck(effect, document) when effect in ["leave_order_draft", "leave_record"] do
    if App.Leave.days(document.data["startDate"], document.data["endDate"]),
      do: :ok,
      else: {:error, "The last day of leave is before the first day."}
  end

  defp precheck(effect, document)
       when effect in ["business_trip_record", "business_trip_order_draft"] do
    if App.Leave.days(document.data["startDate"], document.data["endDate"]),
      do: :ok,
      else: {:error, "The last day of the trip is before the first day."}
  end

  defp precheck("sick_leave", %{data: data}) do
    cond do
      App.Leave.days(data["admissionDate"], data["dischargeDate"]) == nil ->
        {:error, "The discharge date is before the admission date."}

      data["sickLeaveFrom"] == nil != (data["sickLeaveTo"] == nil) ->
        {:error, "Sick leave needs both its first and last day."}

      data["sickLeaveFrom"] && App.Leave.days(data["sickLeaveFrom"], data["sickLeaveTo"]) == nil ->
        {:error, "The last day of sick leave is before the first day."}

      true ->
        :ok
    end
  end

  defp precheck(_effect, _document), do: :ok

  defp position_exists(document) do
    case document.data["position"] &&
           Ash.get(App.People.Position, document.data["position"], authorize?: false) do
      {:ok, _} -> :ok
      _ -> {:error, "The post does not exist."}
    end
  end

  defp current(document) do
    Assignment
    |> Ash.Query.filter(person_id == ^document.person_id and is_nil(ends_on))
    |> Ash.Query.sort(starts_on: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  defp effective_date(document), do: parse_date(document.data["effectiveDate"])

  defp create_assignment(document, position_id, starts_on) do
    Assignment
    |> Ash.Changeset.for_create(
      :from_order,
      %{
        person_id: document.person_id,
        position_id: position_id,
        starts_on: starts_on,
        basis_document_id: document.id
      },
      authorize?: false,
      context: @system_write
    )
    |> Ash.create(authorize?: false)
  end

  defp end_assignment(assignment, document, ends_on) do
    assignment
    |> Ash.Changeset.for_update(
      :end_by_order,
      %{ends_on: ends_on, end_document_id: document.id},
      authorize?: false,
      context: @system_write
    )
    |> Ash.update(authorize?: false)
  end

  defp create_document(attrs) do
    Document
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false, context: @system_write)
    |> Ash.create(authorize?: false)
  end

  defp fitness_status("fit"), do: "fit_for_duty"
  defp fitness_status("fit_with_restrictions"), do: "downgraded"
  defp fitness_status(_unfit), do: "non_effective"

  # The chosen restrictions in the print language, then the free text.
  defp restrictions(data) do
    labels =
      Types.schema(:medical_board_conclusion)["properties"]["restrictions"][
        "x-enum-labels"
      ]

    chosen =
      Enum.map(data["restrictions"] || [], &Labels.impl().choice(&1, labels, @print_locale))

    Enum.join(chosen ++ List.wrap(data["restrictionsText"]), "; ")
  end

  defp parse_date(nil), do: nil

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end
end
