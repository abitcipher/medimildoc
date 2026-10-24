defmodule App.People.SheetSync do
  @moduledoc """
  SHEETS-UI stage 2 (docs/design/sheets-ui.md): people and personnel
  records as spreadsheet rows — the same export → edit → check → carry out
  as `App.People.AssignmentSync`, for any dataset other than assignments:

  - `"people"` — one row per person, the fields of the person form;
  - `"record:<kind>"` — one row per record of a `PersonRecord` kind whose
    fields fit in cells (`sheet_kinds/0`), one column per top-level field.

  `export/2` builds the rows (header first, every value a string),
  `plan/4` reads an edited sheet into creates, updates and errors (nothing
  written), `apply/2` carries them out. Everything runs as the actor,
  through the resource policies: a record the actor may not read is never
  exported (and every read of a sensitive one is in the access log, by the
  resource's `on_decrypt`), one they may not write fails on Carry out.

  A row whose cells still hold the exported values (the hidden
  `Exported<key>` copies the sheet keeps) is never a change: `stale` when
  the app changed it after the export, otherwise unchanged. Deleting a
  row in the sheet deletes nothing.

  Columns are found by their key (row 1 of the tab), never by position.
  """
  require Ash.Query

  alias App.Access.{RecordAccess, Unit}

  alias App.People.{
    Assignment,
    AssignmentSync,
    Person,
    PersonId,
    PersonRecord,
    PersonRecordSchema
  }

  @person_schema_path Path.expand("../../../priv/form_schemas/person.schema.json", __DIR__)
  @external_resource @person_schema_path
  @person_schema @person_schema_path |> File.read!() |> Jason.decode!()

  # The person form's fields that fit in a cell (region and locality need
  # their codes from the reference picker: in the app only).
  @person_fields ~w(given_name patronymic family_name email date_of_birth birth_country)

  @flat_types ["string", "integer", "number", "boolean"]

  @type field :: %{key: String.t(), schema: map(), required?: boolean()}

  @type change :: %{
          row: pos_integer(),
          kind: :create | :update,
          person: Person.t() | nil,
          target: struct() | nil,
          attrs: map(),
          changed: [String.t()],
          conflict?: boolean(),
          new_id: String.t() | nil
        }

  @typedoc """
  Why a row is skipped: `:unknown_person`, `:unknown_record`,
  `:duplicate_row`, `:no_person`, `{:missing_columns, keys}`,
  `{:invalid, message}`.
  """
  @type error :: atom() | {atom(), term()}

  @type plan :: %{
          dataset: String.t(),
          changes: [change()],
          errors: [{pos_integer(), error()}],
          unchanged: non_neg_integer(),
          stale: [pos_integer()]
        }

  @typedoc """
  What `apply/2` did with a row: created (its id and its key — PersonID
  or RecordID, as the tab shows it), updated (its key), or failed.
  """
  @type outcome ::
          {:created, Ash.UUID.t(), String.t()} | {:updated, String.t()} | {:failed, String.t()}

  # --- datasets -----------------------------------------------------------

  @doc """
  The record kinds that can be a sheet: not kept inside another record
  (`x-part-of`), and every required field fits in a cell.
  """
  @spec sheet_kinds() :: [atom()]
  def sheet_kinds do
    Enum.filter(PersonRecordSchema.kinds(), fn kind ->
      schema = PersonRecordSchema.schema(kind)
      keys = MapSet.new(record_fields(kind), & &1.key)

      PersonRecordSchema.part_of(kind) in [nil, []] and
        Enum.all?(schema["required"] || [], &MapSet.member?(keys, &1))
    end)
  end

  @doc "The datasets `actor` may export: people, then the record kinds they can read."
  @spec datasets(map()) :: [String.t()]
  def datasets(actor) do
    readable = MapSet.new(RecordAccess.readable_kinds(actor))

    people = if App.Access.can?(actor, "people.read"), do: ["people"], else: []

    people ++
      for kind <- sheet_kinds(), MapSet.member?(readable, kind), do: "record:#{kind}"
  end

  @doc "A dataset's record kind, or nil for people."
  @spec kind(String.t()) :: atom() | nil
  def kind("record:" <> kind), do: String.to_existing_atom(kind)
  def kind("people"), do: nil

  @doc "The JSON Schema the dataset's fields come from."
  @spec schema(String.t()) :: map()
  def schema("people"), do: @person_schema
  def schema(dataset), do: PersonRecordSchema.schema(kind(dataset))

  @doc "The dataset's editable fields, in form order."
  @spec fields(String.t()) :: [field()]
  def fields("people") do
    required = @person_schema["required"] || []

    for key <- @person_fields,
        do: %{key: key, schema: @person_schema["properties"][key], required?: key in required}
  end

  def fields(dataset), do: record_fields(kind(dataset))

  defp record_fields(kind) do
    schema = PersonRecordSchema.schema(kind)
    required = schema["required"] || []

    for %{path: [key]} <- PersonRecordSchema.fields(kind),
        property = schema["properties"][key],
        property["type"] in @flat_types,
        property["x-system"] == nil,
        do: %{key: key, schema: property, required?: key in required}
  end

  @doc "The columns before the fields (read-only context) and after them."
  @spec context_keys(String.t()) :: {[String.t()], [String.t()]}
  def context_keys("people"), do: {["PersonID"], ["Unit", "Position", "Version"]}
  def context_keys(_record), do: {["PersonID", "Name", "RecordID"], ["Version"]}

  @doc "The key row an export starts with."
  @spec header(String.t()) :: [String.t()]
  def header(dataset) do
    {before, later} = context_keys(dataset)
    before ++ Enum.map(fields(dataset), & &1.key) ++ later
  end

  # --- export -------------------------------------------------------------

  @doc """
  The dataset as rows (key row first), every value a string. Option
  `unit` (SHEETS-UI.17): only people currently posted in that
  organization or below, and their records.
  """
  @spec export(map(), String.t(), keyword()) :: [[String.t()]]
  def export(actor, dataset, opts \\ [])

  def export(actor, "people" = dataset, opts) do
    people =
      Person
      |> in_unit(opts[:unit])
      |> Ash.Query.sort(family_name: :asc, given_name: :asc)
      |> Ash.read!(actor: actor)

    # The earliest started open assignment (as the Assignments tab).
    current =
      Assignment
      |> Ash.Query.filter(is_nil(ends_on))
      |> Ash.Query.sort(starts_on: :desc)
      |> Ash.Query.load(position: :organization)
      |> Ash.read!(actor: actor)
      |> Map.new(&{&1.person_id, &1})

    rows =
      for person <- people do
        post = current[person.id] && current[person.id].position

        [PersonId.format(person.person_id)] ++
          Enum.map(fields(dataset), &text(Map.get(person, String.to_existing_atom(&1.key)))) ++
          [
            (post && post.organization && post.organization.name) || "",
            (post && post.title) || "",
            version(person)
          ]
      end

    [header(dataset) | rows]
  end

  def export(actor, dataset, opts) do
    kind = kind(dataset)

    records =
      PersonRecord
      |> Ash.Query.filter(kind == ^kind)
      |> records_in_unit(opts[:unit])
      |> Ash.Query.load(:person)
      |> Ash.read!(actor: actor)
      |> Enum.sort_by(
        &{&1.person.family_name, &1.person.given_name, &1.effective_on || ~D[0001-01-01]}
      )

    rows =
      for record <- records do
        [PersonId.format(record.person.person_id), Person.full_name(record.person), record.id] ++
          Enum.map(fields(dataset), &text(record.data[&1.key])) ++ [version(record)]
      end

    [header(dataset) | rows]
  end

  defp in_unit(query, nil), do: query

  defp in_unit(query, unit),
    do: Ash.Query.filter(query, ^Unit.assigned_in(Unit.subtree_ids(unit)))

  defp records_in_unit(query, nil), do: query

  defp records_in_unit(query, unit),
    do: Ash.Query.filter(query, ^Unit.person_in_unit(Unit.subtree_ids(unit)))

  defp text(nil), do: ""
  defp text(true), do: "true"
  defp text(false), do: "false"
  defp text(%Date{} = date), do: Date.to_iso8601(date)
  defp text(value), do: to_string(value)

  @doc "A row's version, as the hidden Version column holds it."
  @spec version(struct()) :: String.t()
  def version(%{updated_at: updated_at}), do: DateTime.to_iso8601(updated_at)

  # --- plan ---------------------------------------------------------------

  @doc """
  Reads an edited sheet of `dataset` (`rows`, the key row first) into
  creates, updates and errors. Writes nothing. Option `first_row`: the
  sheet row of the first data row (default 2), for row numbers.

  Values are read as the sheet shows them: dates as dd.mm.yyyy (or a
  serial number, or ISO), yes/no as TRUE/FALSE; choices already as their
  stored values (the caller maps translated labels back).
  """
  @spec plan(map(), String.t(), [[term()]], keyword()) :: plan()
  def plan(actor, dataset, rows, opts \\ [])

  def plan(_actor, dataset, [], _opts),
    do: empty(dataset, [{1, {:missing_columns, ["PersonID"]}}])

  def plan(actor, dataset, [header | rows], opts) do
    keys = Enum.map(header, &cell/1)
    needed = if kind(dataset), do: ["PersonID", "RecordID"], else: ["PersonID"]

    case Enum.reject(needed, &(&1 in keys)) do
      [] ->
        ctx = %{actor: actor, dataset: dataset, fields: fields(dataset), keys: keys}

        rows
        |> Enum.with_index(Keyword.get(opts, :first_row, 2))
        |> Enum.map(fn {row, n} -> {pick(keys, row), n} end)
        |> Enum.reject(fn {row, _n} -> blank?(row, ctx.fields) end)
        |> Enum.reduce({empty(dataset, []), MapSet.new()}, fn {row, n}, {acc, seen} ->
          plan_row(row, n, ctx, acc, seen)
        end)
        |> elem(0)
        |> then(fn plan ->
          %{
            plan
            | changes: Enum.reverse(plan.changes),
              errors: Enum.reverse(plan.errors),
              stale: Enum.reverse(plan.stale)
          }
        end)

      missing ->
        empty(dataset, [{1, {:missing_columns, missing}}])
    end
  end

  # Nothing in the row: no PersonID or RecordID and no field set — an
  # unticked checkbox reads FALSE in every row below the data (seen live
  # 2026-10-09: 199 empty rows checked as new ones).
  defp blank?(row, fields) do
    Map.get(row, "PersonID", "") == "" and Map.get(row, "RecordID", "") == "" and
      Enum.all?(fields, &(value(&1, Map.get(row, &1.key, "")) == nil))
  end

  defp empty(dataset, errors),
    do: %{dataset: dataset, changes: [], errors: errors, unchanged: 0, stale: []}

  defp plan_row(row, n, ctx, acc, seen) do
    case find_target(row, ctx) do
      {:error, error} ->
        {error(acc, n, error), seen}

      {:ok, person, target} ->
        id = target && target.id

        if id && MapSet.member?(seen, id),
          do: {error(acc, n, :duplicate_row), seen},
          else: {plan_target(row, n, person, target, ctx, acc), MapSet.put(seen, id)}
    end
  end

  # People: by PersonID (blank: a new person). Records: by RecordID
  # (blank: a new record for the PersonID's person).
  # A PersonID the app doesn't know, on a row that was never exported
  # (no Version, no exported copies): a new person with the PersonID the
  # sidebar proposed (SHEETS-UI, "New").
  defp find_target(row, %{dataset: "people"} = ctx) do
    case row["PersonID"] do
      "" -> {:ok, nil, nil}
      code -> code |> find_person(ctx.actor) |> person_or_new(row, ctx)
    end
  end

  defp find_target(row, ctx) do
    case {row["RecordID"], row["PersonID"]} do
      {"", ""} ->
        {:error, :no_person}

      {"", code} ->
        with {:ok, person} <- find_person(code, ctx.actor), do: {:ok, person, nil}

      {id, _code} ->
        find_record(id, kind(ctx.dataset), ctx.actor)
    end
  end

  defp person_or_new({:ok, person}, _row, _ctx), do: {:ok, person, person}

  defp person_or_new(error, row, ctx),
    do: if(new_row?(row, ctx), do: {:ok, nil, nil}, else: error)

  defp find_person(code, actor) do
    case Person
         |> Ash.Query.filter(person_id == ^PersonId.unformat(code))
         |> Ash.read_one(actor: actor) do
      {:ok, %Person{} = person} -> {:ok, person}
      _ -> {:error, :unknown_person}
    end
  end

  defp find_record(id, kind, actor) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         {:ok, %PersonRecord{kind: ^kind} = record} <-
           PersonRecord
           |> Ash.Query.filter(id == ^id)
           |> Ash.Query.load(:person)
           |> Ash.read_one(actor: actor) do
      {:ok, record.person, record}
    else
      _ -> {:error, :unknown_record}
    end
  end

  defp plan_target(row, n, person, target, ctx, acc) do
    case {target, edited(row, target, ctx)} do
      {nil, _} -> plan_change(row, n, person, nil, ctx, acc)
      {_, :edited} -> plan_change(row, n, person, target, ctx, acc)
      {_, :unchanged} -> %{acc | unchanged: acc.unchanged + 1}
      {_, :stale} -> %{acc | stale: [n | acc.stale]}
    end
  end

  # Without the exported copies (a tab written another way) every row
  # counts as edited.
  defp edited(row, target, ctx) do
    copies = Enum.map(ctx.fields, &{&1, "Exported" <> &1.key})

    cond do
      not Enum.all?(copies, fn {_f, copy} -> copy in ctx.keys end) -> :edited
      Enum.any?(copies, fn {f, copy} -> !same?(f, row[f.key], row[copy]) end) -> :edited
      row["Version"] == version(target) -> :unchanged
      true -> :stale
    end
  end

  defp same?(field, a, b), do: value(field, a) == value(field, b)

  defp plan_change(row, n, person, target, ctx, acc) do
    values = Map.new(ctx.fields, &{&1.key, value(&1, row[&1.key])})
    conflict? = target != nil and row["Version"] not in ["", version(target)]

    built =
      if ctx.dataset == "people" and target == nil,
        do: build_new_person(proposed_id(row), values, ctx.actor),
        else: build(ctx.dataset, person, target, values, ctx.actor)

    case built do
      {:ok, _attrs, []} when target != nil ->
        %{acc | unchanged: acc.unchanged + 1}

      {:ok, attrs, changed} ->
        change = %{
          row: n,
          kind: if(target, do: :update, else: :create),
          person: person,
          target: target,
          attrs: attrs,
          changed: changed,
          conflict?: conflict?,
          new_id: attrs[:proposed_person_id] && PersonId.format(attrs[:proposed_person_id])
        }

        %{acc | changes: [change | acc.changes]}

      {:error, message} ->
        error(acc, n, {:invalid, message})
    end
  end

  # A new person's PersonID: the one in the row (proposed by the
  # sidebar), or one generated now — shown in the preview and the Status,
  # and given to the person on Carry out.
  defp proposed_id(%{"PersonID" => ""}), do: PersonId.generate_unique()
  defp proposed_id(%{"PersonID" => code}), do: PersonId.unformat(code)

  defp new_row?(row, ctx) do
    row["Version"] in ["", nil] and
      Enum.all?(ctx.fields, &(Map.get(row, "Exported" <> &1.key, "") == ""))
  end

  defp build_new_person(code, values, actor) do
    with {:ok, attrs, changed} <- build("people", nil, nil, values, actor),
         attrs = Map.put(attrs, :proposed_person_id, code),
         changeset = Ash.Changeset.for_create(Person, :create, attrs, actor: actor),
         {:ok, attrs, _} <- validated(changeset, attrs, changed) do
      {:ok, attrs, changed}
    end
  end

  # The attributes to write, which fields change, and whether the action
  # would accept them (validated now, written only by apply/2).
  defp build("people", _person, target, values, actor) do
    attrs = Map.new(values, fn {key, value} -> {String.to_existing_atom(key), value} end)

    changed =
      for {key, value} <- values,
          if(target,
            do: text(Map.get(target, String.to_existing_atom(key))) != text(value),
            else: value != nil
          ),
          do: key

    changeset =
      if target,
        do: Ash.Changeset.for_update(target, :update, attrs, actor: actor),
        else: Ash.Changeset.for_create(Person, :create, attrs, actor: actor)

    validated(changeset, attrs, changed)
  end

  defp build(dataset, person, target, values, actor) do
    kind = kind(dataset)
    data = PersonRecordSchema.normalize(kind, merged(target, values))

    changed =
      for {key, _} <- values,
          Map.get((target && target.data) || %{}, key) != Map.get(data, key),
          do: key

    changeset =
      if target,
        do: Ash.Changeset.for_update(target, :update, %{data: data}, actor: actor),
        else:
          Ash.Changeset.for_create(
            PersonRecord,
            :create,
            %{person_id: person.id, kind: kind, data: data},
            actor: actor
          )

    validated(changeset, %{data: data}, changed)
  end

  # The record's other data (fields not in the sheet) is kept.
  defp merged(nil, values), do: values |> Enum.reject(&(elem(&1, 1) == nil)) |> Map.new()

  defp merged(record, values) do
    Enum.reduce(values, record.data || %{}, fn
      {key, nil}, data -> Map.delete(data, key)
      {key, value}, data -> Map.put(data, key, value)
    end)
  end

  defp validated(changeset, attrs, changed) do
    if changeset.valid?,
      do: {:ok, attrs, changed},
      else: {:error, App.AshErrors.summarize(changeset)}
  end

  # A cell's value as the field stores it; "" → nil.
  defp value(_field, ""), do: nil
  defp value(_field, nil), do: nil

  defp value(%{schema: %{"format" => "date"}}, text) do
    case AssignmentSync.parse_date(text) do
      {:ok, %Date{} = date} -> Date.to_iso8601(date)
      _ -> text
    end
  end

  # A checkbox: an unticked box reads as FALSE whether it was ever set
  # or not, so unticked means "not set" (seen live 2026-10-09: every
  # record without the field looked changed).
  defp value(%{schema: %{"type" => "boolean"}}, text) do
    case String.downcase(text) do
      t when t in ["true", "yes", "1"] -> true
      f when f in ["false", "no", "0"] -> nil
      _ -> text
    end
  end

  defp value(%{schema: %{"type" => type}}, text) when type in ["integer", "number"] do
    case Float.parse(String.replace(text, ",", ".")) do
      {number, ""} when type == "integer" and number == trunc(number) ->
        trunc(number)

      {number, ""} when type == "number" ->
        if number == trunc(number), do: trunc(number), else: number

      _ ->
        text
    end
  end

  defp value(_field, text), do: text

  defp error(acc, n, error), do: %{acc | errors: [{n, error} | acc.errors]}

  # --- apply --------------------------------------------------------------

  @doc """
  Carries out a plan as `actor`: creates and updates through the
  resources' own actions (validations, rules, conflict log, access log).
  Returns `%{created: n, updated: n, failed: [{row, message}], outcomes:
  %{row => outcome}}`.
  """
  @spec apply(map(), plan()) :: map()
  def apply(actor, %{changes: changes, dataset: dataset}) do
    Enum.reduce(changes, %{created: 0, updated: 0, failed: [], outcomes: %{}}, fn change, acc ->
      case write(dataset, change, actor) do
        {:ok, record} when change.kind == :create ->
          %{
            acc
            | created: acc.created + 1,
              outcomes: Map.put(acc.outcomes, change.row, {:created, record.id, key(record)})
          }

        {:ok, record} ->
          %{
            acc
            | updated: acc.updated + 1,
              outcomes: Map.put(acc.outcomes, change.row, {:updated, key(record)})
          }

        {:error, error} ->
          message = App.AshErrors.summarize(error)

          %{
            acc
            | failed: acc.failed ++ [{change.row, message}],
              outcomes: Map.put(acc.outcomes, change.row, {:failed, message})
          }
      end
    end)
  end

  defp write("people", %{kind: :create, attrs: attrs}, actor),
    do: Person |> Ash.Changeset.for_create(:create, attrs, actor: actor) |> Ash.create()

  defp write("people", %{target: person, attrs: attrs}, actor),
    do: person |> Ash.Changeset.for_update(:update, attrs, actor: actor) |> Ash.update()

  defp write(dataset, %{kind: :create, person: person, attrs: %{data: data}}, actor) do
    PersonRecord
    |> Ash.Changeset.for_create(
      :create,
      %{person_id: person.id, kind: kind(dataset), data: data},
      actor: actor
    )
    |> Ash.create()
  end

  defp write(_dataset, %{target: record, attrs: attrs}, actor),
    do: record |> Ash.Changeset.for_update(:update, attrs, actor: actor) |> Ash.update()

  @doc "The column that identifies a row of `dataset`: PersonID or RecordID."
  @spec key_column(String.t()) :: String.t()
  def key_column("people"), do: "PersonID"
  def key_column(_records), do: "RecordID"

  defp key(%Person{person_id: person_id}), do: PersonId.format(person_id)
  defp key(%PersonRecord{id: id}), do: id

  # --- cells --------------------------------------------------------------

  defp pick(keys, row) do
    keys
    |> Enum.with_index()
    |> Map.new(fn {key, i} -> {key, cell(Enum.at(row, i))} end)
  end

  defp cell(nil), do: ""
  defp cell(value) when is_binary(value), do: String.trim(value)
  defp cell(value), do: value |> to_string() |> String.trim()
end
