defmodule App.IHDS do
  @moduledoc """
  Client for IHDS, the reference-data service (`ihds/`,
  docs/design/reference-data-and-files.md): country names in the
  user's language, flags, search.

  Reference data is optional for the app to work: every function returns
  `{:error, _}` (never raises) when IHDS is down or misconfigured, and
  callers fall back to showing the stored code. Full dataset lists are
  cached per `{dataset, lang}` for `:ihds_cache_ttl_ms` (a failure for a
  short time, so a down service isn't hammered on every render).

  Configuration: `:ihds_url` (the service base URL) and
  `:ihds_req_options` (merged into every request; tests swap in a plug).
  """

  alias App.Cache

  @type entry :: %{String.t() => term()}

  # Small datasets are fetched whole and cached; the big ones (places,
  # regions) are looked up one code at a time and only searched.
  @listed ~w(countries languages currencies)

  @default_ttl_ms :timer.minutes(10)
  @failure_ttl_ms :timer.seconds(30)

  @doc "Every entry of `dataset`, sorted by label in `lang`."
  @spec list(String.t(), String.t()) :: {:ok, [entry()]} | {:error, term()}
  def list(dataset, lang) do
    case cached(dataset, lang) do
      {:ok, %{entries: entries}} -> {:ok, entries}
      error -> error
    end
  end

  @doc "One entry by code (as stored in the main database), or `nil`."
  @spec lookup(String.t(), String.t() | nil, String.t()) :: entry() | nil
  def lookup(_dataset, code, _lang) when code in [nil, ""], do: nil

  def lookup(dataset, code, lang) when dataset not in @listed do
    cache({dataset, lang, code}, fn ->
      case get("/v1/#{dataset}/entries/#{URI.encode(code, &URI.char_unreserved?/1)}", lang: lang) do
        {:ok, %{} = entry} -> {:ok, entry}
        error -> error
      end
    end)
    |> case do
      {:ok, entry} -> entry
      _ -> nil
    end
  end

  def lookup(dataset, code, lang) do
    case cached(dataset, lang) do
      # Codes are matched as stored, then case-insensitively (country and
      # currency codes are upper case, language codes lower case).
      {:ok, %{by_code: by_code}} ->
        by_code[code] || by_code[String.upcase(code)] || by_code[String.downcase(code)]

      _ ->
        nil
    end
  end

  @doc """
  Search-as-you-type through IHDS itself (not cached). `country` (ISO
  alpha-2) restricts places and regions to one country.
  """
  @spec search(String.t(), String.t(), String.t(), pos_integer(), String.t() | nil) ::
          {:ok, [entry()]} | {:error, term()}
  def search(dataset, query, lang, limit \\ 20, country \\ nil) do
    params = [q: query, lang: lang, limit: limit] ++ if(country, do: [country: country], else: [])

    case get("/v1/#{dataset}/search", params) do
      {:ok, %{"entries" => entries}} -> {:ok, entries}
      {:ok, _} -> {:error, :bad_response}
      error -> error
    end
  end

  # Learned values (docs/design/reference-data-and-files.md, step 3): only
  # these categories, all organisational names, never medical or personal
  # free text. IHDS stores the bare value and a count, no link to a person.
  @learned_categories ~w(issuing_authority vetting_authority)

  @doc "Categories of values the app lets IHDS learn."
  @spec learned_categories() :: [String.t()]
  def learned_categories, do: @learned_categories

  @doc """
  Tells IHDS a value of `category` was saved, so it is suggested next time.
  In the background (`:ihds_learn_async`, default true): a slow or failing
  IHDS never delays or fails the save. Blank values are ignored.
  """
  @spec learn(String.t(), String.t() | nil) :: :ok
  def learn(category, value) when category in @learned_categories and is_binary(value) do
    value = String.trim(value)

    if value != "" do
      post = fn -> post("/v1/learned/#{category}", %{value: value}) end

      if Application.get_env(:app, :ihds_learn_async, true),
        do: Task.Supervisor.start_child(App.TaskSupervisor, post),
        else: post.()
    end

    :ok
  end

  def learn(_category, _value), do: :ok

  @doc "Earlier values of `category` matching `query`, most used first."
  @spec suggest(String.t(), String.t(), pos_integer()) :: {:ok, [String.t()]} | {:error, term()}
  def suggest(category, query, limit \\ 10) when category in @learned_categories do
    case get("/v1/learned/#{category}/search", q: query, limit: limit) do
      {:ok, %{"entries" => entries}} -> {:ok, Enum.map(entries, & &1["value"])}
      {:ok, _} -> {:error, :bad_response}
      error -> error
    end
  end

  defp cached(dataset, lang), do: cache({dataset, lang}, fn -> fetch_list(dataset, lang) end)

  defp cache(key, fetch) do
    case Cache.fetch(key) do
      {:ok, value} ->
        value

      :miss ->
        value = fetch.()
        ttl = if match?({:ok, _}, value), do: ttl_ms(), else: @failure_ttl_ms
        Cache.put(key, value, ttl)
        value
    end
  end

  defp fetch_list(dataset, lang) do
    case get("/v1/#{dataset}", lang: lang) do
      {:ok, %{"entries" => entries}} when is_list(entries) ->
        {:ok, %{entries: entries, by_code: Map.new(entries, &{&1["code"], &1})}}

      {:ok, _} ->
        {:error, :bad_response}

      error ->
        error
    end
  end

  defp get(path, params), do: request(method: :get, url: path, params: params)

  defp post(path, body), do: request(method: :post, url: path, json: body)

  defp request(options) do
    [
      base_url: Application.get_env(:app, :ihds_url, "http://localhost:4100"),
      retry: false,
      connect_options: [timeout: 1_000],
      receive_timeout: 3_000
    ]
    |> Keyword.merge(options)
    |> Keyword.merge(Application.get_env(:app, :ihds_req_options, []))
    |> Req.request()
    |> case do
      {:ok, %{status: 204}} -> {:ok, nil}
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    # A missing test stub or a malformed URL must not take a page down.
    error -> {:error, error}
  end

  defp ttl_ms, do: Application.get_env(:app, :ihds_cache_ttl_ms, @default_ttl_ms)
end
