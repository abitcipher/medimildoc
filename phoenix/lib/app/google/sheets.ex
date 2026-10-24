defmodule App.Google.Sheets do
  @moduledoc """
  Thin Sheets API v4 client (M2).

  Auth is OAuth per-user : every call takes the caller's own Google
  access token as an explicit argument — forwarded from
  `ScriptApp.getOAuthToken()` in the Apps Script shim, through the sidebar
  postMessage bridge, to `AppWeb.SheetsLive`'s connect_params, same path as
  the session token from M1. Never a shared service account / `goth` token;
  `goth` only re-enters the picture if we add server-initiated calls outside
  a user's request context.

  This is the only place that talks to the Sheets API
  — LiveViews call these functions, never `Req` directly.
  """

  @base_url "https://sheets.googleapis.com/v4"

  @type row :: [String.t()]

  @doc """
  Reads a range (A1 notation, e.g. `"Sheet1!A1:C10"`) as a list of rows.
  Returns `{:ok, []}` if the range has no values yet (Sheets omits the
  `"values"` key entirely rather than returning an empty list).
  """
  @spec get_values(String.t(), String.t(), String.t()) :: {:ok, [row()]} | {:error, term()}
  def get_values(access_token, spreadsheet_id, range) do
    access_token
    |> request_options(
      method: :get,
      url: "/spreadsheets/#{spreadsheet_id}/values/#{encode_range(range)}",
      # Safe: a read, so retrying transient failures can't duplicate an effect.
      retry: :transient
    )
    |> Req.request()
    |> handle_response()
    |> case do
      {:ok, %{"values" => values}} -> {:ok, values}
      {:ok, _no_values_key} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  Overwrites a range (A1 notation) with `rows`, `valueInputOption=USER_ENTERED`
  (so e.g. `"=A1+1"` is parsed as a formula, matching what a human typing
  into the sheet would get — not stored as a literal string).

  No automatic retry: unlike `get_values/3`, a failed write's actual
  server-side effect is unknown, so blind retry risks stacking writes.
  """
  @spec update_values(String.t(), String.t(), String.t(), [row()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_values(access_token, spreadsheet_id, range, rows, opts \\ []) do
    access_token
    |> request_options(
      method: :put,
      url: "/spreadsheets/#{spreadsheet_id}/values/#{encode_range(range)}",
      # `raw: true` stores values exactly as given: no formulas, no dates
      # parsed in the sheet's locale (exports of data, not typing).
      params: [valueInputOption: if(opts[:raw], do: "RAW", else: "USER_ENTERED")],
      json: %{range: range, majorDimension: "ROWS", values: rows}
    )
    |> Req.request()
    |> handle_response()
  end

  @doc """
  Writes several ranges in one request (`values:batchUpdate`), RAW:
  `data` is `[{range, rows}]`. One request instead of one per row keeps
  within the per-user write quota.
  """
  @spec batch_update_values(String.t(), String.t(), [{String.t(), [row()]}]) ::
          {:ok, map()} | {:error, term()}
  def batch_update_values(_access_token, _spreadsheet_id, []), do: {:ok, %{}}

  def batch_update_values(access_token, spreadsheet_id, data) do
    access_token
    |> request_options(
      method: :post,
      url: "/spreadsheets/#{spreadsheet_id}/values:batchUpdate",
      json: %{
        valueInputOption: "RAW",
        data:
          for({range, rows} <- data, do: %{range: range, majorDimension: "ROWS", values: rows})
      }
    )
    |> Req.request()
    |> handle_response()
  end

  @doc "Empties a range (values only; formatting and validation stay)."
  @spec clear_values(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def clear_values(access_token, spreadsheet_id, range) do
    access_token
    |> request_options(
      method: :post,
      url: "/spreadsheets/#{spreadsheet_id}/values/#{encode_range(range)}:clear",
      json: %{}
    )
    |> Req.request()
    |> handle_response()
  end

  @doc "The spreadsheet's tabs: their `properties` maps (`title`, `sheetId`)."
  @spec sheets(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def sheets(access_token, spreadsheet_id) do
    access_token
    |> request_options(
      method: :get,
      url: "/spreadsheets/#{spreadsheet_id}",
      params: [fields: "sheets.properties(sheetId,title)"],
      retry: :transient
    )
    |> Req.request()
    |> handle_response()
    |> case do
      {:ok, %{"sheets" => sheets}} -> {:ok, Enum.map(sheets, & &1["properties"])}
      {:ok, _} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  The spreadsheet's tabs with what a formatted tab carries (SHEETS-UI,
  docs/design/sheets-ui.md): `properties` (`title`, `sheetId`), band ids,
  conditional format rules, protected ranges and column groups — so they can be replaced
  rather than stacked when a tab is written again.
  """
  @spec sheet_details(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def sheet_details(access_token, spreadsheet_id) do
    access_token
    |> request_options(
      method: :get,
      url: "/spreadsheets/#{spreadsheet_id}",
      params: [
        fields:
          "sheets(properties(sheetId,title),bandedRanges(bandedRangeId)," <>
            "conditionalFormats(ranges(sheetId)),protectedRanges(protectedRangeId,description)," <>
            "columnGroups(range,depth))"
      ],
      retry: :transient
    )
    |> Req.request()
    |> handle_response()
    |> case do
      {:ok, %{"sheets" => sheets}} -> {:ok, sheets}
      {:ok, _} -> {:ok, []}
      error -> error
    end
  end

  @doc "A column's letter (0 → A … 25 → Z, 26 → AA)."
  @spec column_letter(non_neg_integer()) :: String.t()
  def column_letter(i) when i < 26, do: <<?A + i>>
  def column_letter(i), do: column_letter(div(i, 26) - 1) <> column_letter(rem(i, 26))

  @doc """
  `spreadsheets.batchUpdate` with `requests` (add tabs, data validation,
  hidden columns, …). Returns the replies.
  """
  @spec batch_update(String.t(), String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def batch_update(access_token, spreadsheet_id, requests) do
    access_token
    |> request_options(
      method: :post,
      url: "/spreadsheets/#{spreadsheet_id}:batchUpdate",
      json: %{requests: requests}
    )
    |> Req.request()
    |> handle_response()
  end

  # Base client, overridable per-call (`extra`) and per-environment
  # (`:sheets_req_options`, e.g. config/test.exs swaps in a Req.Test plug —
  # see test/app/google/sheets_test.exs) rather than a single module-level
  # constant, since the bearer token is per-call, not fixed.
  defp request_options(access_token, extra) do
    [
      base_url: @base_url,
      headers: [{"authorization", "Bearer #{access_token}"}],
      receive_timeout: 10_000
    ]
    |> Keyword.merge(extra)
    |> Keyword.merge(Application.get_env(:app, :sheets_req_options, []))
  end

  defp encode_range(range), do: URI.encode(range, &URI.char_unreserved?/1)

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_response({:ok, %{status: 401}}), do: {:error, :unauthorized}
  defp handle_response({:ok, %{status: 403}}), do: {:error, :forbidden}
  defp handle_response({:ok, %{status: 404}}), do: {:error, :not_found}
  defp handle_response({:ok, %{status: 429}}), do: {:error, :rate_limited}
  defp handle_response({:ok, %{status: status}}) when status >= 500, do: {:error, :server_error}

  defp handle_response({:ok, %{status: status, body: body}}),
    do: {:error, {:unexpected_status, status, body}}

  defp handle_response({:error, reason}), do: {:error, reason}
end
