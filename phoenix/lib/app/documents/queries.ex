defmodule App.Documents.Queries do
  @moduledoc """
  Reads over documents used by the resources' changes and the screens:
  the current route step, a document's trail, the inbox. Kept out of the
  domain module so resources and their domain don't depend on each other
  in a cycle.
  """

  require Ash.Query

  alias App.Access.Unit
  alias App.Documents.{Deputies, Document, Inbox, Instructions, Step, Types}

  @doc "The pending step of `document`'s current round, or nil (read as the system)."
  @spec current_step(map()) :: Step.t() | nil
  def current_step(%{id: document_id}) do
    Step
    |> Ash.Query.filter(document_id == ^document_id and status == :pending)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  @doc """
  The pending step `actor` decides on `document`: their own, or — as an
  active deputy holding its permission — one waiting for someone they
  stand in for (docs/design/inbox-first.md); nil if none. Read as the
  system. In a parallel stage several steps are pending at once
  (docs/design/parallel-approval.md), so this picks the actor's.
  """
  @spec step_for(map() | nil, map()) :: Step.t() | nil
  def step_for(nil, _document), do: nil

  def step_for(actor, %{id: document_id} = document) do
    pending =
      Step
      |> Ash.Query.filter(document_id == ^document_id and status == :pending)
      |> Ash.Query.sort(position: :asc)
      |> Ash.read!(authorize?: false)

    Enum.find(pending, &(&1.assignee_id == actor.id)) ||
      Enum.find(pending, &Deputies.may_act?(actor, &1, document))
  end

  @doc """
  A document's steps (all rounds) and history, for a viewer who has
  already read the document itself (so it is theirs to see).
  """
  @spec load_trail(map()) :: map()
  def load_trail(document) do
    Ash.load!(
      document,
      [
        steps:
          Ash.Query.sort(Step, round: :asc, position: :asc)
          |> Ash.Query.load([:assignee, :decided_by]),
        events: Ash.Query.sort(App.Documents.Event, inserted_at: :asc)
      ],
      authorize?: false
    )
  end

  @doc """
  What waits for `actor` (the inbox, docs/design/documents-core.md), read
  through the policies and without decrypting any fields:

  - `to_decide` — documents whose current step is theirs (approve / sign),
    or waits for someone they stand in for and whose permission they hold
    (`on_behalf_of` — that user), each with `due` (`App.Documents.Inbox`)
    and `step_action`;
  - `my_drafts` — their own drafts, `returned` ones first (sent back with a
    comment);
  - `instructions` — letters with an open instruction to them
    (`instruction`, `due`; docs/design/correspondence.md);
  - `team` — drafts opened by the system for types they may write (a
    conclusion for the board, a scheduled referral), soonest due first.
  """
  @spec inbox(map()) :: map()
  def inbox(actor) do
    step_days = App.Settings.get("documents.step_days")
    # Own steps win over a principal's step on the same document.
    pending_by_document =
      Map.new(delegated_steps(actor) ++ own_steps(actor), &{&1.document_id, &1})

    to_decide =
      Document
      |> Ash.Query.filter(id in ^Map.keys(pending_by_document))
      |> Ash.Query.load(:person)
      |> Ash.Query.sort(updated_at: :asc)
      |> Ash.read!(actor: actor)
      |> Enum.flat_map(fn document ->
        step = Map.fetch!(pending_by_document, document.id)
        own? = step.assignee_id == actor.id

        if own? or Deputies.holds_step?(actor, step, document) do
          step_due = Inbox.step_due(step.pending_since || step.updated_at, step_days)

          [
            document
            |> Map.put(:due, Inbox.earliest(document.due_on, step_due))
            |> Map.put(:step_action, step.action)
            |> Map.put(:on_behalf_of, if(own?, do: nil, else: step.assignee))
          ]
        else
          []
        end
      end)

    drafts =
      Document
      |> Ash.Query.filter(state == :draft)
      |> Ash.Query.load(:person)
      |> Ash.read!(actor: actor)

    returned = returned_ids(drafts)
    writable = App.Documents.Access.writable_types(actor)

    %{
      mine: mine(actor),
      to_decide: to_decide,
      instructions: instructions(actor),
      my_drafts:
        drafts
        |> Enum.filter(&(&1.author_id == actor.id))
        |> Enum.map(&Map.put(&1, :returned?, &1.id in returned))
        |> Enum.sort_by(&{not &1.returned?, &1.updated_at}, :asc),
      team:
        drafts
        |> Enum.filter(&(is_nil(&1.author_id) and &1.type in writable))
        |> Enum.sort_by(&(&1.due_on || ~D[9999-12-31]), Date)
    }
  end

  @doc """
  How many documents wait for the actor's decision (their own steps and
  those of users they stand in for) plus orders to acknowledge, and how
  many of the steps are overdue — for the count next to "Tasks"
  (docs/design/inbox-first.md). Lighter than `inbox/1`: no drafts.
  """
  @spec waiting_count(map()) :: %{count: non_neg_integer(), overdue: non_neg_integer()}
  def waiting_count(actor) do
    delegated =
      actor
      |> delegated_steps()
      |> Ash.load!(:document, authorize?: false)
      |> Enum.filter(&Deputies.holds_step?(actor, &1, &1.document))

    steps = Enum.uniq_by(own_steps(actor) ++ delegated, & &1.document_id)
    days = App.Settings.get("documents.step_days")
    today = Date.utc_today()

    overdue =
      Enum.count(steps, fn step ->
        Inbox.urgency(Inbox.step_due(step.pending_since || step.updated_at, days), today) ==
          :overdue
      end)

    instructions = Instructions.open_for(actor)

    late =
      Enum.count(instructions, &(&1.due_on && Inbox.urgency(&1.due_on, today) == :overdue))

    %{
      count: length(steps) + length(instructions) + length(to_acknowledge(actor)),
      overdue: overdue + late
    }
  end

  # Letters with an open instruction to the actor, each with the
  # instruction and its due date (docs/design/correspondence.md).
  defp instructions(actor) do
    actor
    |> Instructions.open_for()
    |> Enum.map(fn instruction ->
      instruction.document
      |> Map.put(:due, instruction.due_on)
      |> Map.put(:instruction, instruction)
    end)
  end

  defp own_steps(actor) do
    Step
    |> Ash.Query.filter(assignee_id == ^actor.id and status == :pending)
    |> Ash.read!(actor: actor)
  end

  # Steps waiting for users the actor stands in for today (read as the
  # system: only documents the actor may act on are kept).
  defp delegated_steps(actor) do
    case Deputies.principals(actor.id) do
      [] ->
        []

      principals ->
        Step
        |> Ash.Query.filter(assignee_id in ^principals and status == :pending)
        |> Ash.Query.load(:assignee)
        |> Ash.read!(authorize?: false)
    end
  end

  # The actor's own self-service documents on their way or decided
  # (drafts are under their drafts), newest first.
  defp mine(%{person_id: person_id} = actor) when is_binary(person_id) do
    Document
    |> Ash.Query.filter(
      person_id == ^person_id and type in ^Types.self_service_types() and
        state in [:in_review, :signed]
    )
    |> Ash.Query.load(:person)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.Query.limit(20)
    |> Ash.read!(actor: actor)
  end

  defp mine(_actor), do: []

  @doc """
  Acknowledgements of `document_ids` (docs/design/acknowledgements.md),
  keyed by document id. Read as the system: call it only for documents
  the viewer has already read.
  """
  @spec acknowledgements([String.t()]) :: %{String.t() => App.Documents.Acknowledgement.t()}
  def acknowledgements([]), do: %{}

  def acknowledgements(document_ids) do
    App.Documents.Acknowledgement
    |> Ash.Query.filter(document_id in ^document_ids)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.document_id, &1})
  end

  @doc "Signed orders about the actor's own person that they have not acknowledged yet, oldest first."
  @spec to_acknowledge(map()) :: [Document.t()]
  def to_acknowledge(%{person_id: person_id} = actor) when is_binary(person_id) do
    Document
    |> Ash.Query.filter(
      person_id == ^person_id and state == :signed and type in ^Types.acknowledge_types()
    )
    |> Ash.Query.load(:person)
    |> Ash.Query.sort(signed_at: :asc)
    |> Ash.read!(actor: actor)
    |> without_acknowledgement()
  end

  def to_acknowledge(_actor), do: []

  @doc """
  Signed orders awaiting acknowledgement that `actor` may record on the
  person's behalf (the Acknowledgements page), oldest first. `filters`:
  `unit` (an organization id — people currently in it or below), `type`,
  `signed_from` (a date). At most `limit` (default 500).
  """
  @spec pending_acknowledgements(map(), map(), pos_integer()) :: [Document.t()]
  def pending_acknowledgements(actor, filters \\ %{}, limit \\ 500) do
    types =
      case filters[:type] do
        nil -> Types.acknowledge_types()
        type -> Enum.filter(Types.acknowledge_types(), &(&1 == type))
      end

    Document
    |> Ash.Query.filter(state == :signed and type in ^types)
    |> filter_unit(filters[:unit])
    |> filter_signed_from(filters[:signed_from])
    |> Ash.Query.load(:person)
    |> Ash.Query.sort(signed_at: :asc)
    |> Ash.read!(actor: actor)
    |> without_acknowledgement()
    |> Enum.filter(&App.Documents.Access.can_record_acknowledgement?(actor, &1))
    |> Enum.take(limit)
  end

  defp filter_unit(query, nil), do: query

  defp filter_unit(query, org_id) do
    in_unit = Unit.person_in_unit(Unit.subtree_ids(org_id))
    Ash.Query.filter(query, ^in_unit)
  end

  defp filter_signed_from(query, nil), do: query

  defp filter_signed_from(query, %Date{} = from) do
    since = DateTime.new!(from, ~T[00:00:00], "Etc/UTC")
    Ash.Query.filter(query, signed_at >= ^since)
  end

  defp without_acknowledgement(documents) do
    done = acknowledgements(Enum.map(documents, & &1.id))
    Enum.reject(documents, &Map.has_key?(done, &1.id))
  end

  # Drafts whose latest decided step was a return.
  defp returned_ids([]), do: MapSet.new()

  defp returned_ids(drafts) do
    Step
    |> Ash.Query.filter(document_id in ^Enum.map(drafts, & &1.id) and status == :returned)
    |> Ash.read!(authorize?: false)
    |> MapSet.new(& &1.document_id)
  end
end
