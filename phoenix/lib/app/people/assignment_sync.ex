defmodule App.People.AssignmentSync do
  @moduledoc """
  Current assignments as sheet rows, for Google Sheets and offline .xlsx
  (docs/design/assignments-sheets.md): `export/1` builds the Assignments,
  Positions and History sheets; `plan/2` reads an edited Assignments sheet
  into a list of changes and errors (nothing written); `apply/2` turns the
  personnel changes into draft orders and applies start-date corrections.
  Everything runs as the actor, through the resource policies.

  Row semantics (current assignments only; history is never rewritten):

  - Position changed → the current assignment ends the day before
    "Since" and a new one starts on it (a "Since" not after the current
    start means today);
  - Position set, none before → a new assignment starts on "Since"
    (default today);
  - Position cleared → the current assignment ends today;
  - same Position, other "Since" → the current start date is corrected.

  A row the user didn't edit (where the sheet keeps the exported values,
  `ExportedPosition`/`ExportedSince`, docs/design/sheets-ui.md) is never a
  change: if the app changed that person after the export it is `stale`
  (export again), not undone.

  Columns are found by their header, so their order doesn't matter.
  Headers are English on purpose: they are the file format, not UI text.
  """
  require Ash.Query

  alias App.Access.Unit
  alias App.Audit.ChangeConflict
  alias App.People.{Assignment, Person, PersonId, Position, PositionLabel}

  @assignment_headers ["PersonID", "Name", "Unit", "Position", "Since", "Version"]
  @position_headers ["Position", "Unit", "Title", "Grade", "Holders"]
  @history_headers ["PersonID", "Name", "Position", "Unit", "Started", "Ended"]

  @type change :: %{
          row: pos_integer(),
          kind: :move | :start | :end | :redate,
          person: Person.t(),
          current: Assignment.t() | nil,
          to: Position.t() | nil,
          on: Date.t(),
          conflict?: boolean(),
          notes: [String.t()]
        }

  @typedoc """
  Why a row is skipped (translated for display by `AppWeb.AssignmentPlan`):
  `:empty`, `{:missing_columns, names}`, `:unknown_person`,
  `:duplicate_person`, `{:unknown_position, label}`, `:not_a_date`,
  `:not_a_real_date`, `:since_not_after_start`, `:starts_in_future`,
  `{:overlaps_previous, ended_on}`.
  """
  @type error :: atom() | {atom(), term()}

  @type plan :: %{
          changes: [change()],
          errors: [{pos_integer(), error()}],
          unchanged: non_neg_integer(),
          stale: [pos_integer()]
        }

  @typedoc """
  What `apply/2` did with a change's row: a draft order (its kind and id),
  a corrected start date, skipped (`:order_pending`) or failed.
  """
  @type outcome ::
          {:drafted, :move | :start | :end, Ash.UUID.t()}
          | :corrected
          | :order_pending
          | {:failed, String.t()}

  @doc "Column headers of the Assignments sheet (the Version column is hidden)."
  @spec assignment_headers() :: [String.t()]
  def assignment_headers, do: @assignment_headers

  # --- export -------------------------------------------------------------

  @doc """
  The three sheets as rows (header first), every value a string:
  `%{assignments: rows, positions: rows, history: rows}`. The Position
  column's valid values are the first column of `positions`. Option
  `unit`: only people currently posted in that organization or below.
  """
  @spec export(map(), keyword()) :: %{
          assignments: [[String.t()]],
          positions: [[String.t()]],
          history: [[String.t()]]
        }
  def export(actor, opts \\ []) do
    positions = load_positions(actor)
    labels = labels(positions)

    people =
      Person
      |> in_unit(opts[:unit])
      |> Ash.Query.sort(family_name: :asc, given_name: :asc)
      |> Ash.read!(actor: actor)

    ids = Enum.map(people, & &1.id)

    assignments =
      Assignment
      |> Ash.Query.filter(person_id in ^ids)
      |> Ash.Query.load(position: :organization)
      |> Ash.Query.sort(starts_on: :asc)
      |> Ash.read!(actor: actor)

    by_person = Enum.group_by(assignments, & &1.person_id)
    people_by_id = Map.new(people, &{&1.id, &1})

    %{
      assignments: [
        @assignment_headers | Enum.map(people, &assignment_row(&1, by_person, labels))
      ],
      positions: [
        @position_headers
        | positions
          |> Enum.map(&position_row(&1, labels))
          |> Enum.sort()
      ],
      history: [
        @history_headers
        | for(
            a <- assignments,
            a.ends_on,
            person = people_by_id[a.person_id],
            do: history_row(a, person, labels)
          )
      ]
    }
  end

  # SHEETS-UI.17: only the people currently posted in `unit` or below
  # (all the actor may see without one). Positions stay complete: a
  # transfer may go to another unit.
  defp in_unit(query, nil), do: query

  defp in_unit(query, unit),
    do: Ash.Query.filter(query, ^Unit.assigned_in(Unit.subtree_ids(unit)))

  defp assignment_row(person, by_person, labels) do
    current = current(by_person[person.id])

    [
      PersonId.format(person.person_id),
      Person.full_name(person),
      (current && unit(current.position)) || "",
      (current && labels[current.position_id]) || "",
      (current && date(current.starts_on)) || "",
      (current && version(current)) || ""
    ]
  end

  defp position_row(position, labels) do
    [
      labels[position.id],
      unit(position) || "",
      position.title,
      position.authorised_grade || "",
      "#{position.holders}/#{position.strength}"
    ]
  end

  defp history_row(assignment, person, labels) do
    [
      PersonId.format(person.person_id),
      Person.full_name(person),
      labels[assignment.position_id] || "",
      unit(assignment.position) || "",
      date(assignment.starts_on),
      date(assignment.ends_on)
    ]
  end

  # --- plan ---------------------------------------------------------------

  @doc """
  Reads an edited Assignments sheet (`rows`, header first) into changes and
  errors. Writes nothing. `today` is for tests. Option `first_row`: the
  sheet row the first data row is on (default 2, right under the header;
  3 under a label row, docs/design/sheets-ui.md), for the row numbers in
  changes and errors.
  """
  @spec plan(map(), [[term()]], Date.t(), keyword()) :: plan()
  def plan(actor, rows, today \\ Date.utc_today(), opts \\ [])

  def plan(_actor, [], _today, _opts),
    do: %{changes: [], errors: [{1, :empty}], unchanged: 0, stale: []}

  def plan(actor, [header | rows], today, opts) do
    case columns(header) do
      {:ok, cols} ->
        positions = load_positions(actor)
        by_label = Map.new(labels(positions), fn {id, label} -> {label, id} end)
        positions_by_id = Map.new(positions, &{&1.id, &1})

        context = %{
          actor: actor,
          today: today,
          by_label: by_label,
          positions: positions_by_id,
          people: people_by_person_id(actor),
          current: current_by_person(actor),
          last_ended: last_ended_by_person(actor)
        }

        rows
        |> Enum.with_index(Keyword.get(opts, :first_row, 2))
        |> Enum.reject(fn {row, _n} -> Enum.all?(row, &(cell(&1) == "")) end)
        |> Enum.reduce(
          {%{changes: [], errors: [], unchanged: 0, stale: []}, MapSet.new()},
          fn {row, n}, {acc, seen} -> plan_row(pick(row, cols), n, context, acc, seen) end
        )
        |> elem(0)
        |> then(
          &%{
            &1
            | changes: Enum.reverse(&1.changes),
              errors: Enum.reverse(&1.errors),
              stale: Enum.reverse(&1.stale)
          }
        )
        |> warn_over_strength(positions_by_id)

      {:error, missing} ->
        %{
          changes: [],
          errors: [{1, {:missing_columns, missing}}],
          unchanged: 0,
          stale: []
        }
    end
  end

  defp plan_row(row, n, ctx, acc, seen) do
    code = PersonId.unformat(row["PersonID"])

    case find_person(ctx.people, code) do
      {:error, message} ->
        {error(acc, n, message), seen}

      {:ok, person} ->
        # Seen from here on, even if this row has an error: a second row
        # for the same person is a mistake either way.
        {plan_person_row(row, n, person, ctx, acc, seen), MapSet.put(seen, person.id)}
    end
  end

  defp plan_person_row(row, n, person, ctx, acc, seen) do
    current = ctx.current[person.id]

    case edited(row, current) do
      :edited -> plan_edited_row(row, n, person, ctx, acc, seen)
      :unchanged -> %{acc | unchanged: acc.unchanged + 1}
      :stale -> %{acc | stale: [n | acc.stale]}
    end
  end

  # Without the exported copies (an .xlsx, a tab from before SHEETS-UI)
  # every row counts as edited, as before.
  defp edited(%{"ExportedPosition" => position, "ExportedSince" => since} = row, current) do
    cond do
      row["Position"] != position or parse_date(row["Since"]) != parse_date(since) -> :edited
      row["Version"] == ((current && version(current)) || "") -> :unchanged
      true -> :stale
    end
  end

  defp edited(_row, _current), do: :edited

  defp plan_edited_row(row, n, person, ctx, acc, seen) do
    with :ok <- once(seen, person),
         {:ok, to} <- find_position(ctx, row["Position"]),
         {:ok, since} <- parse_date(row["Since"]) do
      current = ctx.current[person.id]
      conflict? = current != nil and row["Version"] not in ["", version(current)]

      case current |> decide(to, since, ctx.today) |> after_previous(ctx.last_ended[person.id]) do
        :unchanged ->
          %{acc | unchanged: acc.unchanged + 1}

        {:error, message} ->
          error(acc, n, message)

        {kind, on, notes} ->
          change = %{
            row: n,
            kind: kind,
            person: person,
            current: current,
            to: to,
            on: on,
            conflict?: conflict?,
            notes: notes
          }

          %{acc | changes: [change | acc.changes]}
      end
    else
      {:error, message} -> error(acc, n, message)
    end
  end

  defp once(seen, person),
    do:
      if(MapSet.member?(seen, person.id),
        do: {:error, :duplicate_person},
        else: :ok
      )

  defp error(acc, n, message), do: %{acc | errors: [{n, message} | acc.errors]}

  # No current post, none wanted.
  defp decide(nil, nil, _since, _today), do: :unchanged
  defp decide(nil, _to, since, today), do: {:start, since || today, []}

  defp decide(current, nil, _since, today) do
    if Date.compare(today, current.starts_on) == :lt,
      do: {:error, :starts_in_future},
      else: {:end, today, []}
  end

  defp decide(%{position_id: same} = current, %{id: same}, since, _today) do
    if since == nil or since == current.starts_on,
      do: :unchanged,
      else: {:redate, since, []}
  end

  defp decide(current, _to, since, today) do
    cond do
      since && Date.compare(since, current.starts_on) == :gt -> {:move, since, []}
      Date.compare(today, current.starts_on) == :gt -> {:move, today, ["starts today"]}
      true -> {:error, :since_not_after_start}
    end
  end

  # A new start (a start date corrected, or a first assignment) must come
  # after the person's previous assignment ended, or history would overlap
  # — e.g. a sheet exported before a move, imported again after it.
  defp after_previous({kind, on, _notes} = decision, %Date{} = ended_on)
       when kind in [:redate, :start] do
    if Date.compare(on, ended_on) == :gt,
      do: decision,
      else: {:error, {:overlaps_previous, ended_on}}
  end

  defp after_previous(decision, _ended_on), do: decision

  # A note (not an error) when a post would have more holders than its
  # strength after the plan.
  defp warn_over_strength(plan, positions) do
    arriving =
      plan.changes
      |> Enum.filter(&(&1.kind in [:move, :start]))
      |> Enum.frequencies_by(& &1.to.id)

    leaving =
      plan.changes
      |> Enum.filter(&(&1.kind in [:move, :end]))
      |> Enum.frequencies_by(& &1.current.position_id)

    changes =
      Enum.map(plan.changes, fn change ->
        with %{kind: kind, to: %{id: id}} when kind in [:move, :start] <- change,
             %{} = post <- positions[id],
             true <- post.holders + arriving[id] - Map.get(leaving, id, 0) > post.strength do
          %{change | notes: change.notes ++ ["post over strength"]}
        else
          _ -> change
        end
      end)

    %{plan | changes: changes}
  end

  # --- apply --------------------------------------------------------------

  # Personnel changes become draft orders (docs/design/assignments-sheets.md
  # §Draft orders): who holds which post changes only when an order is
  # signed.
  @order_types %{
    start: :personnel_order_appointment,
    move: :personnel_order_transfer,
    end: :personnel_order_dismissal
  }

  @doc """
  Carries out a plan as `actor`:

  - an appointment, a transfer or a release becomes a **draft order** of
    that type (the post and the date filled in; the actor is its author),
    to be completed and sent along the order route — a person who already
    has a personnel order open (a draft or in approval) is skipped, so an
    import twice drafts nothing twice;
  - a corrected start date is applied directly (a correction of the
    record, audited like any direct change; last write wins, ADR-8, and a
    row changed since export is logged as a `ChangeConflict`).

  Returns `%{drafted: n, corrected: n, documents: [id], skipped: [{row,
  :order_pending}], failed: [{row, message}], conflicts: n, outcomes:
  %{row => outcome}}`.
  """
  @spec apply(map(), plan()) :: map()
  def apply(actor, %{changes: changes}) do
    pending = people_with_open_orders(actor, Enum.map(changes, & &1.person.id))

    Enum.reduce(
      changes,
      %{
        drafted: 0,
        corrected: 0,
        documents: [],
        skipped: [],
        failed: [],
        conflicts: 0,
        outcomes: %{}
      },
      &apply_change(&1, &2, actor, pending)
    )
    |> Map.update!(:documents, &Enum.reverse/1)
  end

  @doc """
  Cancels the draft orders an import created (`apply/2`'s `documents`)
  that are still drafts — one sent for approval or signed since stays.
  Returns `%{cancelled: n, kept: n}`.
  """
  @spec cancel_drafts(map(), [Ash.UUID.t()]) :: %{
          cancelled: non_neg_integer(),
          kept: non_neg_integer()
        }
  def cancel_drafts(_actor, []), do: %{cancelled: 0, kept: 0}

  def cancel_drafts(actor, ids) do
    drafts =
      App.Documents.Document
      |> Ash.Query.filter(id in ^ids and state == :draft)
      |> Ash.read!(actor: actor)

    cancelled =
      Enum.count(drafts, fn document ->
        result =
          document
          |> Ash.Changeset.for_update(:cancel, %{}, actor: actor)
          |> Ash.update()

        match?({:ok, _}, result)
      end)

    %{cancelled: cancelled, kept: length(ids) - cancelled}
  end

  defp apply_change(%{kind: :redate} = change, acc, actor, _pending) do
    case App.Repo.transaction(fn ->
           update(change.current, %{starts_on: change.on}, actor)
         end) do
      {:ok, notifications} ->
        Ash.Notifier.notify(notifications)
        if change.conflict?, do: log_conflict(change, actor)

        %{
          acc
          | corrected: acc.corrected + 1,
            conflicts: acc.conflicts + if(change.conflict?, do: 1, else: 0),
            outcomes: Map.put(acc.outcomes, change.row, :corrected)
        }

      {:error, error} ->
        failed(acc, change, error)
    end
  end

  defp apply_change(change, acc, actor, pending) do
    if change.person.id in pending do
      %{
        acc
        | skipped: acc.skipped ++ [{change.row, :order_pending}],
          outcomes: Map.put(acc.outcomes, change.row, :order_pending)
      }
    else
      case draft_order(change, actor) do
        {:ok, document} ->
          %{
            acc
            | drafted: acc.drafted + 1,
              documents: [document.id | acc.documents],
              outcomes: Map.put(acc.outcomes, change.row, {:drafted, change.kind, document.id})
          }

        {:error, error} ->
          failed(acc, change, error)
      end
    end
  end

  defp failed(acc, change, error) do
    message = App.AshErrors.summarize(error)

    %{
      acc
      | failed: acc.failed ++ [{change.row, message}],
        outcomes: Map.put(acc.outcomes, change.row, {:failed, message})
    }
  end

  defp draft_order(change, actor) do
    data =
      case change.kind do
        :end -> %{"effectiveDate" => Date.to_iso8601(change.on)}
        _ -> %{"position" => change.to.id, "effectiveDate" => Date.to_iso8601(change.on)}
      end

    App.Documents.Document
    |> Ash.Changeset.for_create(
      :create,
      %{type: @order_types[change.kind], person_id: change.person.id, data: data},
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  # People with a personnel order open (a draft or in approval) the actor
  # can see.
  defp people_with_open_orders(_actor, []), do: []

  defp people_with_open_orders(actor, person_ids) do
    types = Map.values(@order_types)

    App.Documents.Document
    |> Ash.Query.filter(
      person_id in ^person_ids and type in ^types and state in [:draft, :in_review]
    )
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.person_id)
    |> Enum.uniq()
  end

  defp update(assignment, attrs, actor) do
    assignment
    |> Ash.Changeset.for_update(:update, attrs, actor: actor)
    |> Ash.update(actor: actor, return_notifications?: true)
    |> notifications_or_rollback()
  end

  defp notifications_or_rollback({:ok, _record, notifications}), do: notifications
  defp notifications_or_rollback({:error, error}), do: App.Repo.rollback(error)

  defp log_conflict(%{current: current}, actor) do
    found =
      Assignment
      |> Ash.get!(current.id, authorize?: false)
      |> Map.get(:updated_at)

    ChangeConflict
    |> Ash.Changeset.for_create(:create, %{
      resource: inspect(Assignment),
      record_id: current.id,
      actor_id: actor.id,
      actor_email: to_string(actor.email),
      expected_updated_at: current.updated_at,
      found_updated_at: found
    })
    |> Ash.create(authorize?: false)
  end

  # --- lookups and cells --------------------------------------------------

  @doc "Every post's label (as in the Position column), sorted — the choices of the row form."
  @spec position_labels(map()) :: [String.t()]
  def position_labels(actor), do: actor |> label_map() |> Map.values() |> Enum.sort()

  @doc "`%{position_id => label}` of the posts `actor` can see (`labels/1`)."
  @spec label_map(map()) :: %{Ash.UUID.t() => String.t()}
  def label_map(actor), do: actor |> load_positions() |> labels()

  defp load_positions(actor) do
    Position
    |> Ash.Query.load([:organization, :holders])
    |> Ash.read!(actor: actor)
  end

  @doc """
  `%{position_id => label}`: each post's short label; two posts that would
  share a label get " #1", " #2" (oldest first), so labels stay unique.
  """
  @spec labels([Position.t()]) :: %{Ash.UUID.t() => String.t()}
  def labels(positions) do
    positions
    |> Enum.group_by(&PositionLabel.for_position/1)
    |> Enum.flat_map(fn
      {label, [post]} ->
        [{post.id, label}]

      {label, posts} ->
        posts
        |> Enum.sort_by(&{&1.inserted_at, &1.id})
        |> Enum.with_index(1)
        |> Enum.map(fn {post, i} -> {post.id, "#{label} ##{i}"} end)
    end)
    |> Map.new()
  end

  defp people_by_person_id(actor),
    do: Person |> Ash.read!(actor: actor) |> Map.new(&{&1.person_id, &1})

  # One open assignment per person: the earliest started, as `export/1`
  # shows it — two open ones (an overlap the rules report) must not make
  # the row look changed after the export (seen live 2026-10-09).
  defp current_by_person(actor) do
    Assignment
    |> Ash.Query.filter(is_nil(ends_on))
    |> Ash.Query.sort(starts_on: :desc)
    |> Ash.Query.load(position: :organization)
    |> Ash.read!(actor: actor)
    |> Map.new(&{&1.person_id, &1})
  end

  # The latest end date of each person's past assignments.
  defp last_ended_by_person(actor) do
    Assignment
    |> Ash.Query.filter(not is_nil(ends_on))
    |> Ash.read!(actor: actor)
    |> Enum.group_by(& &1.person_id, & &1.ends_on)
    |> Map.new(fn {person_id, dates} -> {person_id, Enum.max(dates, Date)} end)
  end

  defp current(nil), do: nil
  defp current(assignments), do: Enum.find(assignments, &is_nil(&1.ends_on))

  defp find_person(people, code) do
    case people[code] do
      nil -> {:error, :unknown_person}
      person -> {:ok, person}
    end
  end

  defp find_position(ctx, value) do
    case cell(value) do
      "" ->
        {:ok, nil}

      label ->
        case ctx.by_label[label] do
          nil -> {:error, {:unknown_position, label}}
          id -> {:ok, ctx.positions[id]}
        end
    end
  end

  @doc """
  A date from a sheet cell: dd.mm.yyyy, yyyy-mm-dd, or a spreadsheet date
  serial number (days since 1899-12-30). `{:ok, nil}` when empty.
  """
  @spec parse_date(term()) :: {:ok, Date.t() | nil} | {:error, error()}
  def parse_date(value) do
    text = cell(value)

    cond do
      text == "" ->
        {:ok, nil}

      match = Regex.run(~r/^(\d{1,2})\.(\d{1,2})\.(\d{4})$/, text) ->
        dmy(match)

      match?({:ok, _}, Date.from_iso8601(text)) ->
        Date.from_iso8601(text)

      text =~ ~r/^\d{5}(\.0+)?$/ ->
        {:ok, Date.add(~D[1899-12-30], text |> Float.parse() |> elem(0) |> trunc())}

      true ->
        {:error, :not_a_date}
    end
  end

  defp dmy([_, d, m, y]) do
    case Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :not_a_real_date}
    end
  end

  defp columns(header) do
    names = Enum.map(header, &cell/1)
    index = names |> Enum.with_index() |> Map.new()
    missing = Enum.reject(["PersonID", "Position", "Since"], &Map.has_key?(index, &1))
    if missing == [], do: {:ok, index}, else: {:error, missing}
  end

  defp pick(row, cols), do: Map.new(cols, fn {name, i} -> {name, cell(Enum.at(row, i))} end)

  defp cell(nil), do: ""
  defp cell(value) when is_binary(value), do: String.trim(value)
  defp cell(value) when is_float(value), do: value |> Float.round(6) |> to_string()
  defp cell(value), do: value |> to_string() |> String.trim()

  defp unit(%{organization: %{name: name}}), do: name
  defp unit(_), do: nil

  defp date(%Date{} = d), do: Calendar.strftime(d, "%d.%m.%Y")

  @doc "An assignment's version as the hidden Version column holds it."
  @spec version(Assignment.t()) :: String.t()
  def version(assignment), do: DateTime.to_iso8601(assignment.updated_at)
end
