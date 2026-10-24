defmodule AppWeb.SchemaText do
  @moduledoc """
  Translation of user-facing text that lives in JSON Schema files rather
  than in Elixir source: field labels (`*.ui.json`), record kind names,
  summaries and field help (`x-label`, `x-summary`, `x-help`), and choice
  values (`enum`, shown humanized: `fit_for_duty` → "Fit for duty", or
  the property's explicit `x-enum-labels` where humanizing isn't good
  enough, e.g. acronyms like `rnokpp`). NATO markings (`NATO_SECRET`) are
  shown as written and never translated; single-value enums are internal
  (e.g. FHIR `resourceType`) and never shown.

  `mix gettext.extract` only sees literal strings in code, so at compile
  time this module reads every schema file and generates one literal
  `gettext_noop/1` call per string (`texts/0`); the strings land in the
  catalogs like any other. JSON Schema `description`s are developer
  documentation and are deliberately not included — they are never shown
  to users.
  """
  use Gettext, backend: AppWeb.Gettext

  @dirs [
    Path.expand("../../priv/person_record_schemas", __DIR__),
    Path.expand("../../priv/form_schemas", __DIR__),
    Path.expand("../../priv/document_types", __DIR__),
    # SHEETS-UI layouts (docs/design/sheets-ui.md): column labels.
    Path.expand("../../priv/sheet_layouts", __DIR__)
  ]

  files = Enum.flat_map(@dirs, &Path.wildcard(Path.join(&1, "*.json")))
  for file <- files, do: @external_resource(file)

  humanize = fn value ->
    value |> to_string() |> String.replace(["_", "-"], " ") |> String.capitalize()
  end

  marking? = fn value -> String.starts_with?(to_string(value), ["NATO_", "COSMIC_"]) end

  collect = fn collect, node ->
    case node do
      %{} = map ->
        explicit = map["x-enum-labels"] || %{}

        choices =
          case map["enum"] do
            [_, _ | _] = values ->
              values
              |> Enum.reject(&(Map.has_key?(explicit, &1) or marking?.(&1)))
              |> Enum.map(humanize)

            _ ->
              []
          end

        own =
          [
            map["label"],
            map["x-label"],
            map["x-summary"],
            map["x-help"],
            map["x-then-message"],
            # Document types (priv/document_types): their own summary.
            is_map(map["register"]) && map["summary"]
          ] ++
            Map.values(explicit) ++ choices

        own ++ Enum.flat_map(Map.values(map), &collect.(collect, &1))

      list when is_list(list) ->
        Enum.flat_map(list, &collect.(collect, &1))

      _ ->
        []
    end
  end

  texts =
    files
    |> Enum.flat_map(&collect.(collect, &1 |> File.read!() |> Jason.decode!()))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()

  @doc "Every schema string marked for extraction, sorted."
  @spec texts() :: [String.t()]
  def texts do
    unquote(Enum.map(texts, fn text -> quote(do: gettext_noop(unquote(text))) end))
  end

  @doc "Translates a schema string into the current locale; `nil` stays `nil`."
  @spec translate(String.t() | nil) :: String.t() | nil
  def translate(nil), do: nil
  def translate(text), do: Gettext.gettext(AppWeb.Gettext, text)

  @doc """
  A choice value as translated, readable text: the property's explicit
  label from `x-enum-labels` if it has one, otherwise the value humanized
  (`"fit_for_duty"` → "Fit for duty"). NATO security markings are shown as
  written on documents ("NATO SECRET") and never translated.
  """
  @spec choice(String.t() | atom(), map() | nil) :: String.t()
  def choice(value, labels \\ nil) do
    value = to_string(value)

    cond do
      is_map(labels) and is_binary(labels[value]) -> translate(labels[value])
      String.starts_with?(value, ["NATO_", "COSMIC_"]) -> String.replace(value, "_", " ")
      true -> value |> String.replace(["_", "-"], " ") |> String.capitalize() |> translate()
    end
  end
end
