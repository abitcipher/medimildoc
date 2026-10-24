defmodule App.IHDSStub do
  @moduledoc """
  Stands in for the IHDS service in tests (config/test.exs): answers the
  same list, lookup and search requests from the real seed files in
  `../ihds/seed`, so tests see real names. Search is a plain substring
  match on the label (the real ranking is tested in the Rust service); the
  seeds are read once, on first use.
  """
  @behaviour Plug

  import Plug.Conn

  @seed_dir Path.expand("../../../ihds/seed", __DIR__)
  @max_list 10_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)
    lang = conn.query_params["lang"] || "en"

    case conn.path_info do
      ["v1", "learned", category] -> learn(conn, category)
      ["v1", "learned", _category, "search"] -> reply(conn, learned(conn.query_params))
      ["v1", dataset] -> reply(conn, list(dataset, lang))
      ["v1", dataset, "search"] -> reply(conn, search(dataset, conn.query_params, lang))
      ["v1", dataset, "entries", code] -> reply(conn, entry(dataset, code, lang))
      _ -> send_resp(conn, 404, "{}")
    end
  end

  # Learning runs synchronously in tests (config/test.exs) and in the test
  # process itself, so a test can `assert_received` what was sent.
  defp learn(conn, category) do
    {:ok, body, conn} = read_body(conn)
    send(self(), {:ihds_learned, category, Jason.decode!(body)["value"]})
    send_resp(conn, 204, "")
  end

  # Two canned suggestions echoing the query.
  defp learned(%{"q" => q}),
    do: [%{"value" => "#{q} Authority", "count" => 2}, %{"value" => "#{q} Office", "count" => 1}]

  defp learned(_params), do: []

  defp reply(conn, nil), do: send_resp(conn, 404, ~s({"error":"not found"}))
  defp reply(conn, :too_large), do: send_resp(conn, 400, ~s({"error":"use search"}))

  defp reply(conn, entries) when is_list(entries),
    do: json(conn, %{"version" => "test", "entries" => entries})

  defp reply(conn, entry), do: json(conn, entry)

  defp json(conn, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
  end

  defp list(dataset, lang) do
    case datasets()[dataset] do
      nil -> nil
      all when length(all) > @max_list -> :too_large
      all -> all |> Enum.map(&labelled(&1, lang)) |> Enum.sort_by(&String.downcase(&1["label"]))
    end
  end

  defp entry(dataset, code, lang) do
    with %{} = index <- by_code()[dataset],
         %{} = entry <- index[code] || index[String.upcase(code)] || index[String.downcase(code)] do
      entry |> labelled(lang) |> with_context(lang)
    end
  end

  defp search(dataset, params, lang) do
    query = String.downcase(params["q"] || "")
    limit = String.to_integer(params["limit"] || "20")
    country = params["country"] && String.upcase(params["country"])

    (datasets()[dataset] || [])
    |> Stream.filter(&(country in [nil, ""] or &1["country"] == country))
    |> Stream.map(&labelled(&1, lang))
    |> Stream.filter(&String.contains?(String.downcase(&1["label"]), query))
    |> Enum.take(limit)
    |> Enum.map(&with_context(&1, lang))
  end

  defp labelled(entry, lang) do
    names = entry["names"] || %{}
    Map.put(entry, "label", names[lang] || names["en"] || entry["code"])
  end

  defp with_context(entry, lang) do
    region = entry["region"] && entry("regions", entry["region"], lang)
    district = entry["district"] && (entry["district"][lang] || entry["district"]["en"])
    parts = Enum.reject([district, region && region["label"]], &(&1 in [nil, "", entry["label"]]))
    if parts == [], do: entry, else: Map.put(entry, "context_label", Enum.join(parts, ", "))
  end

  defp datasets do
    case :persistent_term.get({__MODULE__, :datasets}, nil) do
      nil ->
        loaded =
          for file <- Path.wildcard(Path.join(@seed_dir, "*.json")), into: %{} do
            seed = file |> File.read!() |> Jason.decode!()
            {seed["dataset"], seed["entries"]}
          end

        :persistent_term.put({__MODULE__, :datasets}, loaded)
        loaded

      loaded ->
        loaded
    end
  end

  defp by_code do
    case :persistent_term.get({__MODULE__, :by_code}, nil) do
      nil ->
        index =
          Map.new(datasets(), fn {name, entries} ->
            {name, Map.new(entries, &{&1["code"], &1})}
          end)

        :persistent_term.put({__MODULE__, :by_code}, index)
        index

      index ->
        index
    end
  end
end
