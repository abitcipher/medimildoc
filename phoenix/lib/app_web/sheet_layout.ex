defmodule AppWeb.SheetLayout do
  @moduledoc """
  SHEETS-UI (docs/design/sheets-ui.md): a spreadsheet tab laid out from the
  same JSON Schema and UI Schema as the app's form. A layout
  (`priv/sheet_layouts/<id>.json`) lists the tab's columns; a column with a
  `field` takes its label, format and help (`x-help`) from the form schema
  named in `form` (`AppWeb.FormSchemas`), the rest are read-only context.

  The tab gets two header rows: row 1 holds the column keys (the file
  format `App.People.AssignmentSync` reads; hidden), row 2 the labels in
  the user's language, with the help as a note. Then the sheet is
  formatted like the app: theme colours, dates as real dates (dd.mm.yyyy,
  with Google's date picker), a dropdown where the form has a choice,
  read-only columns muted and protected (a warning when edited), and a
  changed cell highlighted against its hidden exported copy (`copyOf`) —
  amber when changed, red when emptied.

  Pure: `rows/2` and `requests/3` build data; `App.Google.AssignmentSheets`
  sends it.
  """
  use Gettext, backend: AppWeb.Gettext

  alias App.People.{AssignmentSync, PersonRecordSchema, SheetSync}
  alias AppWeb.{FormSchemas, SchemaText}

  @dir Path.expand("../../priv/sheet_layouts", __DIR__)
  @files Path.wildcard(Path.join(@dir, "*.json"))
  for file <- @files, do: @external_resource(file)

  @layouts Map.new(@files, fn file ->
             layout = file |> File.read!() |> Jason.decode!()
             {layout["id"], layout}
           end)

  # Written into the label row (in its first hidden column) so a reader
  # can tell the label row from data (`App.Google.AssignmentSheets.read/2`
  # looks for the same text).
  @label_marker "#labels"

  # Our protected ranges carry this description, so writing the tab again
  # replaces them instead of adding more.
  @protection "SHEETS-UI"

  # The app's light theme (assets/css/app.css), as sRGB.
  @colors %{
    header: "#51515c",
    header_text: "#ffffff",
    band: "#f2f2f2",
    # Read-only text: zinc-500, visibly lighter than the editable cells.
    muted: "#71717a",
    changed: "#df6f00",
    emptied: "#ea003e",
    # Label cells of a column group (SHEETS-UI.4), alternating.
    group: "#3f4a7a",
    group_alt: "#3d6b62",
    # The Status column (AppWeb.SheetStatus), by its first sign.
    ok: "#00a43b",
    planned: "#0082ce"
  }

  @status_signs [
    {"✓", :ok},
    {"→", :planned},
    {"!", :changed},
    {"↻", :changed},
    {"✗", :emptied}
  ]

  @date_epoch ~D[1899-12-30]

  @type column :: %{
          key: String.t(),
          label: String.t(),
          help: String.t() | nil,
          type: :text | :date | :choice | :enum | :boolean | :number | :email,
          read_only?: boolean(),
          hidden?: boolean(),
          width: pos_integer() | nil,
          copy_of: String.t() | nil,
          options: String.t() | nil,
          status?: boolean(),
          field: map() | nil,
          required?: boolean()
        }

  @doc "What marks the label row (row 2) in a written tab, before the dataset id."
  @spec label_marker() :: String.t()
  def label_marker, do: @label_marker

  @doc """
  The label row's marker for `id` (`App.Google.LaidOutTab` reads it back),
  with the export's options (`unit: id`, SHEETS-UI.17).
  """
  @spec marker(String.t(), keyword()) :: String.t()
  def marker(id, opts \\ []) do
    Enum.join([@label_marker, id | for({k, v} <- opts, v != nil, do: "#{k}=#{v}")], " ")
  end

  @doc """
  The datasets `actor` can open as a tab, in the sidebar's order:
  assignments, people, then record kinds (SHEETS-UI.12).
  """
  @spec datasets(map()) :: [String.t()]
  def datasets(actor) do
    assignments = if App.Access.can?(actor, "people.read"), do: ["assignments"], else: []
    assignments ++ SheetSync.datasets(actor)
  end

  @doc "A dataset's name for people (the kind's label for a record kind)."
  @spec label(String.t()) :: String.t()
  def label("assignments"), do: gettext("Assignments")
  def label("people"), do: gettext("People")

  def label(id),
    do: SchemaText.translate(PersonRecordSchema.label(SheetSync.kind(id)))

  @doc """
  The layout's tab title — in English and stable (it is how the app finds
  the tab again; labels inside are translated).
  """
  @spec tab(String.t()) :: String.t()
  def tab(id), do: id |> layout() |> Map.fetch!("tab")

  # A layout: from `priv/sheet_layouts` (assignments), or built from the
  # dataset's fields (`App.People.SheetSync`): context columns read-only,
  # one column per field, Status, then the hidden keys and copies.
  defp layout(id) when is_map_key(@layouts, id), do: Map.fetch!(@layouts, id)

  defp layout(id) do
    {before, later} = SheetSync.context_keys(id)
    fields = SheetSync.fields(id)
    hidden = ["RecordID", "Version"]
    record? = SheetSync.kind(id) != nil

    context = fn key ->
      %{
        "key" => key,
        "label" => key,
        # A new record's row names its person: PersonID is typed then.
        "readOnly" => not (record? and key == "PersonID"),
        "width" => if(key == "PersonID", do: 130, else: 200)
      }
    end

    %{
      "id" => id,
      "tab" => tab_title(id),
      "columns" =>
        Enum.map(before -- hidden, context) ++
          Enum.map(fields, &%{"key" => &1.key, "field" => &1.key, "width" => width(&1)}) ++
          Enum.map(later -- hidden, context) ++
          [
            %{
              "key" => "Status",
              "label" => "Status",
              "readOnly" => true,
              "status" => true,
              "width" => 320
            }
          ] ++
          for(key <- before ++ later, key in hidden, do: %{"key" => key, "hidden" => true}) ++
          Enum.map(
            fields,
            &%{"key" => "Exported" <> &1.key, "copyOf" => &1.key, "hidden" => true}
          )
    }
  end

  defp tab_title("people"), do: "People"
  defp tab_title(id), do: PersonRecordSchema.label(SheetSync.kind(id))

  defp width(%{schema: %{"type" => type}}) when type in ["integer", "number", "boolean"], do: 110
  defp width(%{schema: %{"format" => "date"}}), do: 110
  defp width(_field), do: 200

  # The JSON Schema and UI Schema a layout's fields come from.
  defp schemas(%{"form" => form}) do
    form = String.to_existing_atom(form)
    {FormSchemas.schema(form), FormSchemas.ui_schema(form)}
  end

  defp schemas(%{"id" => "people"}),
    do: {FormSchemas.schema(:person), FormSchemas.ui_schema(:person)}

  defp schemas(%{"id" => id}) do
    kind = SheetSync.kind(id)
    {PersonRecordSchema.schema(kind), PersonRecordSchema.ui_schema(kind)}
  end

  @doc """
  The form for the selected row of dataset `id` (SHEETS-UI.13): the
  dataset's JSON Schema and its UI Schema cut down to the fields the tab
  has, in form order.
  """
  @spec form(String.t()) :: {map(), map()}
  def form(id) do
    {schema, ui} = id |> layout() |> schemas()
    keys = MapSet.new(SheetSync.fields(id), & &1.key)

    controls =
      for %{"type" => "Control", "scope" => "#/properties/" <> key} = control <-
            flatten(ui["elements"] || []),
          MapSet.member?(keys, key),
          do: control

    {schema, %{"type" => "VerticalLayout", "elements" => controls}}
  end

  @doc "The layout's columns, labels and help translated into the current locale."
  @spec columns(String.t()) :: [column()]
  def columns(id) do
    layout = layout(id)
    {schema, ui} = schemas(layout)
    ui_labels = ui_labels(ui)
    required = MapSet.new(schema["required"] || [])
    by_key = Map.new(layout["columns"], &{&1["key"], &1})

    Enum.map(layout["columns"], fn col ->
      source = by_key[col["copyOf"]] || col
      field = source["field"] && schema["properties"][source["field"]]

      %{
        key: col["key"],
        label: SchemaText.translate(col["label"] || ui_labels[source["field"]] || col["key"]),
        help: field && SchemaText.translate(field["x-help"]),
        type: type(source, field),
        read_only?: col["readOnly"] == true,
        hidden?: col["hidden"] == true,
        width: col["width"],
        copy_of: col["copyOf"],
        options: col["options"],
        status?: col["status"] == true,
        field: field,
        # Not on the assignments tab: an empty post there means "no post".
        required?:
          not Map.has_key?(@layouts, id) and col["field"] != nil and
            MapSet.member?(required, col["field"])
      }
    end)
  end

  defp ui_labels(ui) do
    for %{"type" => "Control", "scope" => "#/properties/" <> field} = control <-
          flatten(ui["elements"] || []),
        into: %{},
        do: {field, control["label"]}
  end

  defp flatten(elements),
    do: Enum.flat_map(elements, &[&1 | flatten(&1["elements"] || [])])

  defp type(%{"options" => _}, _field), do: :choice
  defp type(_col, %{"enum" => [_ | _]}), do: :enum
  defp type(_col, %{"format" => "date"}), do: :date
  defp type(_col, %{"format" => "email"}), do: :email
  defp type(_col, %{"type" => "boolean"}), do: :boolean
  defp type(_col, %{"type" => type}) when type in ["integer", "number"], do: :number
  defp type(_col, _field), do: :text

  @doc """
  The tab's rows: the key row, the label row, then `export` rows (header
  first, as the dataset's sync module writes them) in the layout's column
  order — dates as spreadsheet serial numbers, yes/no as checkboxes,
  choices as their labels, copies filled in.
  """
  @spec rows(String.t(), [[String.t()]], keyword()) :: [[term()]]
  def rows(id, [header | data], marker_opts \\ []) do
    columns = columns(id)
    index = header |> Enum.with_index() |> Map.new()
    first_hidden = Enum.find_index(columns, & &1.hidden?)

    labels =
      columns
      |> Enum.with_index()
      |> Enum.map(fn {col, i} ->
        if i == first_hidden, do: marker(id, marker_opts), else: col.label
      end)

    [Enum.map(columns, & &1.key), labels | Enum.map(data, &cells(&1, columns, index))]
  end

  @doc "One export row in the layout's column order (as `rows/2` writes it)."
  @spec row(String.t(), [String.t()], [String.t()]) :: [term()]
  def row(id, header, values) do
    cells(values, columns(id), header |> Enum.with_index() |> Map.new())
  end

  defp cells(values, columns, index) do
    Enum.map(columns, fn col ->
      # A column the export doesn't have (Status) stays empty.
      value =
        case index[col.copy_of || col.key] do
          nil -> ""
          i -> Enum.at(values, i, "") || ""
        end

      cell(col, value)
    end)
  end

  @doc "A stored value (as exported, a string) as the column's cell."
  @spec cell(column(), String.t()) :: term()
  def cell(_col, ""), do: ""
  def cell(%{type: :date}, value), do: serial(value)
  def cell(%{type: :boolean}, value), do: value in ["true", true]

  def cell(%{type: :number}, value) do
    case Float.parse(value) do
      {number, ""} -> if number == trunc(number), do: trunc(number), else: number
      _ -> value
    end
  end

  def cell(%{type: :enum, field: field}, value),
    do: SchemaText.choice(value, field["x-enum-labels"])

  def cell(_col, value), do: value

  @doc """
  The rows read back from a tab (key row first) with choice labels turned
  back into the values they stand for, so the sync module sees what it
  exported. A cell that matches no label stays as typed.
  """
  @spec unlabel(String.t(), [[term()]]) :: [[term()]]
  def unlabel(_id, []), do: []

  def unlabel(id, [keys | data]) do
    by_key = Map.new(columns(id), &{&1.key, &1})

    lookups =
      Enum.map(keys, fn key ->
        case by_key[key] do
          %{type: :enum, field: field} ->
            Map.new(field["enum"], &{SchemaText.choice(&1, field["x-enum-labels"]), &1})

          _ ->
            nil
        end
      end)

    [
      keys
      | Enum.map(data, fn row ->
          row
          |> Enum.with_index()
          |> Enum.map(fn {value, i} ->
            case Enum.at(lookups, i) do
              nil -> value
              lookup -> Map.get(lookup, value, value)
            end
          end)
        end)
    ]
  end

  @doc "A dd.mm.yyyy or ISO date as a spreadsheet serial number; anything else as given."
  @spec serial(String.t() | Date.t()) :: integer() | String.t()
  def serial(%Date{} = date), do: Date.diff(date, @date_epoch)

  def serial(value) when is_binary(value) do
    case AssignmentSync.parse_date(value) do
      {:ok, %Date{} = date} -> serial(date)
      _ -> value
    end
  end

  @doc """
  The `batchUpdate` requests that format the tab: `sheet` is the tab as
  `App.Google.Sheets.sheet_details/2` returns it (what to replace), `rows`
  how many data rows were written, `options` the size of each options tab
  (`%{"Positions" => rows}`).
  """
  @spec requests(String.t(), map(), keyword()) :: [map()]
  def requests(id, sheet, opts) do
    columns = columns(id)
    sheet_id = sheet["properties"]["sheetId"]
    last = Keyword.fetch!(opts, :rows) + 2 + 200
    visible = Enum.count(columns, &(not &1.hidden?))
    indexed = Enum.with_index(columns)

    List.flatten([
      clear(sheet),
      [
        dimension(sheet_id, "ROWS", 0, 1, %{hiddenByUser: true}, "hiddenByUser"),
        %{
          updateSheetProperties: %{
            properties: %{
              sheetId: sheet_id,
              gridProperties: %{frozenRowCount: 2, frozenColumnCount: 2}
            },
            fields: "gridProperties.frozenRowCount,gridProperties.frozenColumnCount"
          }
        },
        label_row(sheet_id, columns),
        group_requests(id, sheet_id, columns),
        banding(sheet_id, last, visible),
        protect(sheet_id, 0, 2, 0, length(columns))
      ],
      for {col, i} <- indexed do
        column(col, i, sheet_id, last, opts, indexed)
      end
    ])
  end

  defp clear(sheet) do
    sheet_id = sheet["properties"]["sheetId"]

    bands =
      for %{"bandedRangeId" => band} <- sheet["bandedRanges"] || [],
          do: %{deleteBanding: %{bandedRangeId: band}}

    # Highest index first: each delete shifts the ones after it.
    rules =
      for index <- (length(sheet["conditionalFormats"] || []) - 1)..0//-1,
          do: %{deleteConditionalFormatRule: %{sheetId: sheet_id, index: index}}

    protected =
      for %{"protectedRangeId" => range, "description" => @protection} <-
            sheet["protectedRanges"] || [],
          do: %{deleteProtectedRange: %{protectedRangeId: range}}

    # Deepest first, so a group inside another goes before it.
    groups =
      for %{"range" => range} <- Enum.sort_by(sheet["columnGroups"] || [], & &1["depth"], :desc),
          do: %{deleteDimensionGroup: %{range: range}}

    bands ++ rules ++ protected ++ groups
  end

  @doc """
  SHEETS-UI.4: the column groups of a tab — the form's `Group` and
  `HorizontalLayout` elements whose fields sit side by side in the tab:
  `[%{label, from, to}]` (column indexes, `to` inclusive; `label` nil for
  a layout without one).
  """
  @spec groups(String.t()) :: [map()]
  def groups(id) do
    {_schema, ui} = id |> layout() |> schemas()
    index = id |> columns() |> Enum.with_index() |> Map.new(fn {col, i} -> {col.key, i} end)

    for %{"type" => type} = element <- flatten(ui["elements"] || []),
        type in ["Group", "HorizontalLayout"],
        cols = group_columns(element, index),
        length(cols) > 1,
        Enum.max(cols) - Enum.min(cols) == length(cols) - 1 do
      %{label: element["label"], from: Enum.min(cols), to: Enum.max(cols)}
    end
  end

  defp group_columns(element, index) do
    for %{"type" => "Control", "scope" => "#/properties/" <> key} <-
          flatten(element["elements"] || []),
        i = index[key],
        i != nil,
        do: i
  end

  # A group's columns: folded together (Sheets' +/- above the columns),
  # their labels in a tint of their own, alternating, and the group's
  # name in the first label's note.
  defp group_requests(id, sheet_id, columns) do
    id
    |> groups()
    |> Enum.with_index()
    |> Enum.flat_map(fn {group, n} ->
      tint = if rem(n, 2) == 0, do: @colors.group, else: @colors.group_alt
      first = Enum.at(columns, group.from)

      [
        group.label &&
          %{
            updateCells: %{
              range: range(sheet_id, 1, 2, group.from, group.from + 1),
              rows: [
                %{
                  values: [
                    %{
                      note:
                        [SchemaText.translate(group.label), first.help]
                        |> Enum.filter(& &1)
                        |> Enum.join("\n")
                    }
                  ]
                }
              ],
              fields: "note"
            }
          },
        %{
          addDimensionGroup: %{
            range: %{
              sheetId: sheet_id,
              dimension: "COLUMNS",
              startIndex: group.from,
              endIndex: group.to + 1
            }
          }
        },
        %{
          repeatCell: %{
            range: range(sheet_id, 1, 2, group.from, group.to + 1),
            cell: %{userEnteredFormat: %{backgroundColor: color(tint)}},
            fields: "userEnteredFormat.backgroundColor"
          }
        }
      ]
      |> Enum.filter(& &1)
    end)
  end

  defp label_row(sheet_id, columns) do
    [
      %{
        repeatCell: %{
          range: range(sheet_id, 1, 2, 0, length(columns)),
          cell: %{
            userEnteredFormat: %{
              backgroundColor: color(@colors.header),
              textFormat: %{bold: true, foregroundColor: color(@colors.header_text)},
              verticalAlignment: "MIDDLE",
              wrapStrategy: "WRAP"
            }
          },
          fields: "userEnteredFormat(backgroundColor,textFormat,verticalAlignment,wrapStrategy)"
        }
      },
      # The field's help, as in the app's ⓘ, as a note on its label.
      %{
        updateCells: %{
          range: range(sheet_id, 1, 2, 0, length(columns)),
          rows: [%{values: Enum.map(columns, &%{note: &1.help || ""})}],
          fields: "note"
        }
      }
    ]
  end

  defp banding(sheet_id, last, visible) do
    %{
      addBanding: %{
        bandedRange: %{
          range: range(sheet_id, 2, last, 0, visible),
          rowProperties: %{
            firstBandColor: color("#ffffff"),
            secondBandColor: color(@colors.band)
          }
        }
      }
    }
  end

  defp column(col, i, sheet_id, last, opts, indexed) do
    [
      col.width &&
        dimension(sheet_id, "COLUMNS", i, i + 1, %{pixelSize: col.width}, "pixelSize"),
      # Shown or hidden either way: a column hidden by an older layout of
      # the tab (Status took Version's place) must come back (seen live).
      dimension(sheet_id, "COLUMNS", i, i + 1, %{hiddenByUser: col.hidden?}, "hiddenByUser"),
      col.type == :date && date_column(sheet_id, i, last, not col.hidden?),
      not col.hidden? && validation(col, sheet_id, i, last, opts),
      col.read_only? && read_only_column(sheet_id, i, last),
      changed_rules(col, i, sheet_id, last, indexed),
      col.required? && required_rule(sheet_id, i, last, indexed),
      col.status? && status_rules(sheet_id, i, last)
    ]
    |> List.flatten()
    |> Enum.filter(& &1)
  end

  defp date_column(sheet_id, i, last, validate?) do
    [
      %{
        repeatCell: %{
          range: range(sheet_id, 2, last, i, i + 1),
          cell: %{userEnteredFormat: %{numberFormat: %{type: "DATE", pattern: "dd.mm.yyyy"}}},
          fields: "userEnteredFormat.numberFormat"
        }
      },
      validate? &&
        %{
          setDataValidation: %{
            range: range(sheet_id, 2, last, i, i + 1),
            rule: %{condition: %{type: "DATE_IS_VALID"}, strict: true, showCustomUi: true}
          }
        }
    ]
  end

  defp choice_column(sheet_id, i, last, col, opts) do
    count = max(Map.get(Keyword.get(opts, :options, %{}), col.options, 1), 2)

    %{
      setDataValidation: %{
        range: range(sheet_id, 2, last, i, i + 1),
        rule: %{
          condition: %{
            type: "ONE_OF_RANGE",
            values: [%{userEnteredValue: "=#{col.options}!$A$2:$A$#{count}"}]
          },
          strict: true,
          showCustomUi: true
        }
      }
    }
  end

  # SHEETS-UI.14: the field's schema as the cell's data validation.
  defp validation(%{type: :choice} = col, sheet_id, i, last, opts),
    do: choice_column(sheet_id, i, last, col, opts)

  defp validation(col, sheet_id, i, last, _opts), do: validation(col, sheet_id, i, last)

  defp validation(%{type: :enum, field: field}, sheet_id, i, last) do
    values =
      for value <- field["enum"],
          do: %{userEnteredValue: SchemaText.choice(value, field["x-enum-labels"])}

    validate(sheet_id, i, last, %{type: "ONE_OF_LIST", values: values})
  end

  defp validation(%{type: :boolean}, sheet_id, i, last),
    do: validate(sheet_id, i, last, %{type: "BOOLEAN"})

  defp validation(%{type: :email}, sheet_id, i, last),
    do: validate(sheet_id, i, last, %{type: "TEXT_IS_EMAIL"})

  defp validation(%{type: :number, field: field}, sheet_id, i, last) do
    case {field["minimum"], field["maximum"]} do
      {nil, nil} ->
        nil

      {min, nil} ->
        validate(sheet_id, i, last, %{type: "NUMBER_GREATER_THAN_EQ", values: [number(min)]})

      {nil, max} ->
        validate(sheet_id, i, last, %{type: "NUMBER_LESS_THAN_EQ", values: [number(max)]})

      {min, max} ->
        validate(sheet_id, i, last, %{type: "NUMBER_BETWEEN", values: [number(min), number(max)]})
    end
  end

  defp validation(_col, _sheet_id, _i, _last), do: nil

  defp number(value), do: %{userEnteredValue: to_string(value)}

  defp validate(sheet_id, i, last, condition) do
    %{
      setDataValidation: %{
        range: range(sheet_id, 2, last, i, i + 1),
        rule: %{condition: condition, strict: true, showCustomUi: true}
      }
    }
  end

  # A required field left empty on a row that has data: red, like the
  # app's form marks a missing required field. Data = text or numbers:
  # an unticked checkbox holds FALSE, which COUNTA would count, painting
  # every empty row below (seen live 2026-10-09).
  defp required_rule(sheet_id, i, last, indexed) do
    visible = Enum.count(indexed, fn {col, _} -> not col.hidden? end)
    row = "$A3:$#{letter(visible - 1)}3"

    rule(
      sheet_id,
      i,
      last,
      "=AND(COUNTIF(#{row},\"?*\")+COUNT(#{row})>0,#{letter(i)}3=\"\")",
      @colors.emptied
    )
  end

  defp read_only_column(sheet_id, i, last) do
    [
      %{
        repeatCell: %{
          range: range(sheet_id, 2, last, i, i + 1),
          cell: %{userEnteredFormat: %{textFormat: %{foregroundColor: color(@colors.muted)}}},
          fields: "userEnteredFormat.textFormat.foregroundColor"
        }
      },
      protect(sheet_id, 2, last, i, i + 1)
    ]
  end

  # On an edited column with a hidden exported copy: red when emptied,
  # amber when changed (the first matching rule wins).
  defp changed_rules(col, i, sheet_id, last, indexed) do
    case Enum.find(indexed, fn {other, _} -> other.copy_of == col.key end) do
      # A checkbox: unticked reads FALSE, its copy of an unset value is
      # empty — N() makes both 0 (seen live: every unticked box amber).
      {_copy, j} when col.type == :boolean ->
        [rule(sheet_id, i, last, "=N($#{letter(i)}3)<>N($#{letter(j)}3)", @colors.changed)]

      {_copy, j} ->
        here = "$#{letter(i)}3"
        there = "$#{letter(j)}3"

        [
          rule(sheet_id, i, last, "=AND(#{here}=\"\",#{there}<>\"\")", @colors.emptied),
          rule(sheet_id, i, last, "=#{here}<>#{there}", @colors.changed)
        ]

      nil ->
        []
    end
  end

  defp rule(sheet_id, i, last, formula, hex) do
    %{
      addConditionalFormatRule: %{
        index: 0,
        rule: %{
          ranges: [range(sheet_id, 2, last, i, i + 1)],
          booleanRule: %{
            condition: %{type: "CUSTOM_FORMULA", values: [%{userEnteredValue: formula}]},
            format: %{backgroundColor: soft(hex), textFormat: %{bold: true}}
          }
        }
      }
    }
  end

  # The Status column: the row's tone by the sign it starts with.
  defp status_rules(sheet_id, i, last) do
    for {sign, tone} <- @status_signs do
      %{
        addConditionalFormatRule: %{
          index: 0,
          rule: %{
            ranges: [range(sheet_id, 2, last, i, i + 1)],
            booleanRule: %{
              condition: %{type: "TEXT_STARTS_WITH", values: [%{userEnteredValue: sign}]},
              format: %{backgroundColor: soft(@colors[tone])}
            }
          }
        }
      }
    end
  end

  defp protect(sheet_id, from_row, to_row, from_col, to_col) do
    %{
      addProtectedRange: %{
        protectedRange: %{
          range: range(sheet_id, from_row, to_row, from_col, to_col),
          description: @protection,
          warningOnly: true
        }
      }
    }
  end

  defp dimension(sheet_id, dimension, from, to, properties, fields) do
    %{
      updateDimensionProperties: %{
        range: %{sheetId: sheet_id, dimension: dimension, startIndex: from, endIndex: to},
        properties: properties,
        fields: fields
      }
    }
  end

  defp range(sheet_id, from_row, to_row, from_col, to_col) do
    %{
      sheetId: sheet_id,
      startRowIndex: from_row,
      endRowIndex: to_row,
      startColumnIndex: from_col,
      endColumnIndex: to_col
    }
  end

  @doc "A column's letter (0 → A … 25 → Z, 26 → AA)."
  @spec letter(non_neg_integer()) :: String.t()
  defdelegate letter(i), to: App.Google.Sheets, as: :column_letter

  defp color("#" <> hex) do
    [r, g, b] = for <<pair::binary-size(2) <- hex>>, do: String.to_integer(pair, 16) / 255
    %{red: r, green: g, blue: b}
  end

  # A colour mixed with white, like daisyUI's soft alerts.
  defp soft(hex) do
    hex |> color() |> Map.new(fn {k, v} -> {k, v * 0.2 + 0.8} end)
  end
end
