defmodule App.FakeSheets do
  @moduledoc """
  An in-memory spreadsheet behind `Req.Test` for the sidebar's tests
  (SHEETS-UI): tabs as grids of cells, enough of the Sheets API v4 for
  `App.Google.Sheets` — read and write ranges in A1 notation, clear, add
  tabs, batch writes; formatting requests are only recorded. Values come
  back as written (no formatting), which the readers accept.

      fake = App.FakeSheets.start("ss-1")
      App.FakeSheets.put(fake, "People", rows)
      App.FakeSheets.rows(fake, "People")
  """
  alias App.Google.Sheets

  @doc "Starts an empty spreadsheet `ssid` and routes the Sheets API to it."
  def start(ssid) do
    {:ok, fake} = Agent.start_link(fn -> %{tabs: %{}, ids: %{}, requests: []} end)

    Req.Test.stub(Sheets, fn conn -> handle(conn, fake, ssid) end)
    fake
  end

  @doc "Puts `rows` into `tab` from A1 (creating the tab)."
  def put(fake, tab, rows) do
    Agent.update(fake, fn state ->
      state |> add_tab(tab) |> put_in([:tabs, tab], grid(rows))
    end)
  end

  @doc "The rows of `tab` (trailing empty cells dropped)."
  def rows(fake, tab), do: Agent.get(fake, &to_rows(&1.tabs[tab] || %{}))

  @doc "The formatting requests sent (batchUpdate), oldest first."
  def requests(fake), do: Agent.get(fake, &Enum.reverse(&1.requests))

  defp handle(conn, fake, ssid) do
    body = conn |> Req.Test.raw_body() |> decode()
    base = "/v4/spreadsheets/#{ssid}"

    path = String.replace_prefix(conn.request_path, base, "")

    case {conn.method, path} do
      {"GET", ""} ->
        Req.Test.json(conn, %{"sheets" => Agent.get(fake, &sheets/1)})

      {"POST", ":batchUpdate"} ->
        replies = Agent.get_and_update(fake, &batch(&1, body["requests"] || []))
        Req.Test.json(conn, %{"replies" => replies})

      {"POST", "/values:batchUpdate"} ->
        Agent.update(fake, &write_all(&1, body["data"]))

        Req.Test.json(conn, %{})

      {"GET", "/values/" <> range} ->
        Req.Test.json(conn, %{"values" => Agent.get(fake, &read(&1, URI.decode(range)))})

      {"PUT", "/values/" <> range} ->
        Agent.update(fake, &write(&1, URI.decode(range), body["values"]))
        Req.Test.json(conn, %{})

      {"POST", "/values/" <> rest} ->
        range = rest |> URI.decode() |> String.replace_suffix(":clear", "")
        Agent.update(fake, &clear(&1, range))
        Req.Test.json(conn, %{})
    end
  end

  defp sheets(state) do
    for {title, id} <- state.ids, do: %{"properties" => %{"title" => title, "sheetId" => id}}
  end

  defp write_all(state, data),
    do: Enum.reduce(data, state, &write(&2, &1["range"], &1["values"]))

  defp decode(""), do: %{}
  defp decode(body), do: Jason.decode!(body)

  defp batch(state, requests) do
    state = %{state | requests: Enum.reverse(requests) ++ state.requests}

    Enum.map_reduce(requests, state, fn
      %{"addSheet" => %{"properties" => %{"title" => title}}}, state ->
        state = add_tab(state, title)

        {%{"addSheet" => %{"properties" => %{"title" => title, "sheetId" => state.ids[title]}}},
         state}

      _request, state ->
        {%{}, state}
    end)
  end

  defp add_tab(state, tab) do
    if Map.has_key?(state.ids, tab),
      do: state,
      else: %{
        state
        | ids: Map.put(state.ids, tab, map_size(state.ids) + 1),
          tabs: Map.put(state.tabs, tab, %{})
      }
  end

  # "Tab!A1:ZZ", "'Two words'!F3:F4", "Tab!A:A", "Tab!A5".
  defp parse(range) do
    [tab, a1] =
      case Regex.run(~r/^'((?:[^']|'')*)'!(.*)$/, range) do
        [_, tab, a1] -> [String.replace(tab, "''", "'"), a1]
        nil -> String.split(range, "!", parts: 2)
      end

    [from | to] = String.split(a1, ":")
    {c1, r1} = cell(from)
    {c2, r2} = if to == [], do: {c1, r1}, else: cell(hd(to))
    {tab, {c1 || 0, r1 || 1}, {c2 || 10_000, r2 || 100_000}}
  end

  defp cell(ref) do
    [_, letters, digits] = Regex.run(~r/^([A-Z]*)(\d*)$/, ref)

    col =
      if letters == "",
        do: nil,
        else:
          letters
          |> String.to_charlist()
          |> Enum.reduce(0, &(&2 * 26 + &1 - ?A + 1))
          |> Kernel.-(1)

    {col, if(digits == "", do: nil, else: String.to_integer(digits))}
  end

  defp read(state, range) do
    {tab, {c1, r1}, {c2, r2}} = parse(range)
    grid = state.tabs[tab] || %{}

    grid
    |> Map.filter(fn {{r, c}, _} -> r >= r1 and r <= r2 and c >= c1 and c <= c2 end)
    |> Map.new(fn {{r, c}, v} -> {{r - r1 + 1, c - c1}, v} end)
    |> to_rows()
  end

  defp write(state, range, values) do
    {tab, {c1, r1}, _} = parse(range)
    state = add_tab(state, tab)

    cells =
      for {row, i} <- Enum.with_index(values), {value, j} <- Enum.with_index(row), into: %{} do
        {{r1 + i, c1 + j}, value}
      end

    update_in(state, [:tabs, tab], &Map.merge(&1, cells))
  end

  defp clear(state, range) do
    {tab, {c1, r1}, {c2, r2}} = parse(range)

    update_in(state, [:tabs, tab], fn grid ->
      Map.reject(grid || %{}, fn {{r, c}, _} -> r >= r1 and r <= r2 and c >= c1 and c <= c2 end)
    end)
  end

  defp grid(rows) do
    for {row, i} <- Enum.with_index(rows, 1),
        {value, j} <- Enum.with_index(row),
        into: %{},
        do: {{i, j}, value}
  end

  defp to_rows(grid) when map_size(grid) == 0, do: []

  defp to_rows(grid) do
    last_row = grid |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.max()

    for r <- 1..last_row do
      cols = for {{^r, c}, v} <- grid, v not in [nil, ""], do: c
      last = Enum.max(cols, fn -> -1 end)
      for c <- 0..last//1, do: Map.get(grid, {r, c}, "")
    end
  end
end
