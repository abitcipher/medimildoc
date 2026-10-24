defmodule AppWeb.SheetCard do
  @moduledoc """
  SHEETS-UI.3 (docs/design/sheets-ui.md): one person as a "label | value"
  tab, like the person's page in the app, for reading and printing — the
  tab "Card", rewritten for whoever is asked for. Not imported: a view only.

  What it shows is read as the viewer, through the policies: the person,
  their current post, then every record they may read, newest first, by
  kind, with the fields the app's record card shows
  (`AppWeb.RecordComponents.filled_fields/1`). Reading a sensitive record
  is in the access log as everywhere (the record's `on_decrypt`).

  With `own: true` (`/me`, docs/design/events-and-person-login.md) the
  person is the viewer's own: everything about them is read, past the
  category policies (as the personal FHIR token), still as the viewer,
  so sensitive reads are logged.

  `rows/3` builds the cells and their kinds (pure but for the reads);
  `write/4` writes them with the formatting.
  """
  use Gettext, backend: AppWeb.Gettext

  require Ash.Query

  alias App.Access.RecordAccess
  alias App.Google.LaidOutTab
  alias App.People.{Assignment, Person, PersonId, PersonRecord, PersonRecordSchema}
  alias AppWeb.{FormSchemas, RecordComponents, SchemaText}

  @tab "Card"

  @colors %{header: "#51515c", header_text: "#ffffff", band: "#f2f2f2", muted: "#71717a"}

  @doc "The tab's title (stable; in English like the other tabs)."
  @spec tab() :: String.t()
  def tab, do: @tab

  @doc """
  The card's rows as `{kind, label, value}`: `:title`, `:subtitle`,
  `:section` (a heading), `:record` (a record's heading), `:field`,
  `:blank`.
  """
  @spec rows(Person.t(), map(), keyword()) :: [{atom(), String.t(), String.t()}]
  def rows(person, actor, opts \\ []) do
    read = read_as(actor, opts[:own] == true)

    [
      {:title, Person.full_name(person), ""},
      {:subtitle, PersonId.format(person.person_id), post(person, read)},
      {:blank, "", ""},
      {:section, gettext("Person"), ""}
    ] ++ person_fields(person) ++ records(person, actor, read, opts[:own] == true)
  end

  defp read_as(actor, true), do: &Ash.read!(&1, actor: actor, authorize?: false)
  defp read_as(actor, false), do: &Ash.read!(&1, actor: actor)

  defp post(person, read) do
    Assignment
    |> Ash.Query.filter(person_id == ^person.id and is_nil(ends_on))
    |> Ash.Query.sort(starts_on: :asc)
    |> Ash.Query.load(position: :organization)
    |> read.()
    |> case do
      [%{position: position} = a | _] ->
        Enum.join(
          Enum.filter(
            [
              position.title,
              position.organization && position.organization.name,
              gettext("since %{date}", date: AppWeb.DateFormat.display(a.starts_on))
            ],
            & &1
          ),
          ", "
        )

      [] ->
        gettext("No current post.")
    end
  end

  defp person_fields(person) do
    ui = FormSchemas.ui_schema(:person)

    for %{"type" => "Control", "scope" => "#/properties/" <> key} = control <-
          ui["elements"] || [],
        value = Map.get(person, String.to_existing_atom(key)),
        value not in [nil, ""] do
      {:field, SchemaText.translate(control["label"]), display(value)}
    end
  end

  defp display(%Date{} = date), do: AppWeb.DateFormat.display(date)
  defp display(value), do: to_string(value)

  defp records(person, actor, read, own?) do
    readable = if own?, do: PersonRecordSchema.kinds(), else: RecordAccess.readable_kinds(actor)

    PersonRecord
    |> Ash.Query.filter(person_id == ^person.id and kind in ^readable)
    |> read.()
    |> Enum.group_by(& &1.kind)
    |> Enum.sort_by(fn {kind, _} ->
      Enum.find_index(PersonRecordSchema.kinds(), &(&1 == kind))
    end)
    |> Enum.flat_map(fn {kind, records} ->
      [{:blank, "", ""}, {:section, RecordComponents.kind_label(kind), ""}] ++
        Enum.flat_map(Enum.sort_by(records, &date/1, {:desc, Date}), &record_rows/1)
    end)
  end

  defp record_rows(record) do
    [{:record, AppWeb.DateFormat.display(date(record)), ""}] ++
      for {field, value} <- RecordComponents.filled_fields(record) do
        {:field, SchemaText.translate(field.label), RecordComponents.format_value(field, value)}
      end
  end

  defp date(record), do: record.effective_on || DateTime.to_date(record.recorded_at)

  @doc """
  Writes the card of the person with `person_id` (read as `actor`) into
  the tab "Card" (created when missing).
  """
  @spec open(String.t(), String.t(), map(), Ash.UUID.t()) :: :ok | {:error, term()}
  def open(token, ssid, actor, person_id) do
    case Ash.get(Person, person_id, actor: actor) do
      {:ok, person} -> write(token, ssid, actor, person)
      {:error, error} -> {:error, error}
    end
  end

  @doc "Writes `person`'s card into the tab \"Card\" (created when missing)."
  @spec write(String.t(), String.t(), map(), Person.t()) :: :ok | {:error, term()}
  def write(token, ssid, actor, person) do
    rows = rows(person, actor)
    cells = Enum.map(rows, fn {_kind, label, value} -> [label, value] end)

    case LaidOutTab.write(token, ssid, @tab, cells, &requests(&1, rows)) do
      {:ok, _id} -> :ok
      error -> error
    end
  end

  # Formatting from scratch each time: the old card's formats are reset,
  # then title, headings, muted labels, wrapped values, no gridlines.
  defp requests(sheet, rows) do
    id = sheet["properties"]["sheetId"]
    count = length(rows) + 50

    [
      %{
        repeatCell: %{
          range: range(id, 0, count, 0, 2),
          cell: %{userEnteredFormat: %{}},
          fields: "userEnteredFormat"
        }
      },
      %{
        updateSheetProperties: %{
          properties: %{sheetId: id, gridProperties: %{hideGridlines: true, frozenRowCount: 2}},
          fields: "gridProperties.hideGridlines,gridProperties.frozenRowCount"
        }
      },
      width(id, 0, 240),
      width(id, 1, 480),
      format(id, 0, count, 0, 2, %{
        verticalAlignment: "TOP",
        wrapStrategy: "WRAP",
        textFormat: %{fontSize: 10}
      })
    ] ++
      (rows
       |> Enum.with_index()
       |> Enum.flat_map(fn {{kind, _, _}, i} -> row_format(kind, id, i) end))
  end

  defp row_format(:title, id, i),
    do: [format(id, i, i + 1, 0, 2, %{textFormat: %{bold: true, fontSize: 16}})]

  defp row_format(:subtitle, id, i),
    do: [format(id, i, i + 1, 0, 2, %{textFormat: %{foregroundColor: color(@colors.muted)}})]

  defp row_format(:section, id, i),
    do: [
      format(id, i, i + 1, 0, 2, %{
        backgroundColor: color(@colors.header),
        textFormat: %{bold: true, foregroundColor: color(@colors.header_text)}
      })
    ]

  defp row_format(:record, id, i),
    do: [
      format(id, i, i + 1, 0, 2, %{
        backgroundColor: color(@colors.band),
        textFormat: %{bold: true}
      })
    ]

  defp row_format(:field, id, i),
    do: [format(id, i, i + 1, 0, 1, %{textFormat: %{foregroundColor: color(@colors.muted)}})]

  defp row_format(:blank, _id, _i), do: []

  defp format(id, r1, r2, c1, c2, format) do
    fields =
      format
      |> Map.keys()
      |> Enum.map_join(",", &"userEnteredFormat.#{&1}")

    %{
      repeatCell: %{
        range: range(id, r1, r2, c1, c2),
        cell: %{userEnteredFormat: format},
        fields: fields
      }
    }
  end

  defp width(id, col, px) do
    %{
      updateDimensionProperties: %{
        range: %{sheetId: id, dimension: "COLUMNS", startIndex: col, endIndex: col + 1},
        properties: %{pixelSize: px},
        fields: "pixelSize"
      }
    }
  end

  defp range(id, r1, r2, c1, c2),
    do: %{
      sheetId: id,
      startRowIndex: r1,
      endRowIndex: r2,
      startColumnIndex: c1,
      endColumnIndex: c2
    }

  defp color("#" <> hex) do
    [r, g, b] = for <<pair::binary-size(2) <- hex>>, do: String.to_integer(pair, 16) / 255
    %{red: r, green: g, blue: b}
  end
end
