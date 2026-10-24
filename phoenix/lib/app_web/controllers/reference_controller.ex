defmodule AppWeb.ReferenceController do
  @moduledoc """
  Reference data for the browser-side pickers (`ReferencePicker` hook):
  `GET /reference/:dataset` returns every entry of a small dataset with
  its label in the current locale and pre-normalized search words, so the
  picker filters instantly without a round trip per key press. The data
  comes from IHDS through `App.IHDS`; browsers never talk to IHDS.

  `?lang=` picks the language (falls back to the session's).
  Signed-in users only. Only datasets listed in `@datasets` are served.
  """
  use AppWeb, :controller

  @datasets ~w(countries languages currencies)
  # Too big to send whole: searched through IHDS on every key press.
  @searched ~w(places regions)
  @search_limit 10

  def show(conn, %{"dataset" => dataset} = params) when dataset in @datasets do
    lang = lang(params)

    with %{} <- conn.assigns[:current_user] || :unauthorized,
         {:ok, entries} <- App.IHDS.list(dataset, lang) do
      conn
      |> put_resp_header("cache-control", "private, max-age=600")
      |> json(%{entries: Enum.map(entries, &compact/1)})
    else
      :unauthorized ->
        conn |> put_status(:unauthorized) |> json(%{error: "sign in first"})

      {:error, _} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "reference data unavailable"})
    end
  end

  def show(conn, _params), do: conn |> put_status(:not_found) |> json(%{error: "unknown dataset"})

  @doc """
  `GET /reference/:dataset/search?q=&lang=&country=` for the big datasets
  (places, regions), used by the `ReferenceAutocomplete` hook: up to
  #{@search_limit} matches with label, context ("raion, region"), flag and
  the region's own code and label (so picking a place can fill the region).
  """
  def search(conn, %{"dataset" => dataset} = params) when dataset in @searched do
    lang = lang(params)
    query = String.trim(params["q"] || "")
    country = if params["country"] in [nil, ""], do: nil, else: params["country"]

    with %{} <- conn.assigns[:current_user] || :unauthorized,
         {:ok, entries} <- search_entries(dataset, query, lang, country) do
      json(conn, %{entries: Enum.map(entries, &suggestion(&1, lang))})
    else
      :unauthorized ->
        conn |> put_status(:unauthorized) |> json(%{error: "sign in first"})

      {:error, _} ->
        conn |> put_status(:service_unavailable) |> json(%{error: "reference data unavailable"})
    end
  end

  def search(conn, _params),
    do: conn |> put_status(:not_found) |> json(%{error: "unknown dataset"})

  @doc """
  `GET /reference/learned/:category/search?q=` — values entered before
  (`App.IHDS.learned_categories/0`), for `<.input type="suggest">`.
  """
  def learned(conn, %{"category" => category} = params) do
    query = String.trim(params["q"] || "")

    with %{} <- conn.assigns[:current_user] || :unauthorized,
         true <- category in App.IHDS.learned_categories() || :not_found,
         {:ok, values} <- if(query == "", do: {:ok, []}, else: App.IHDS.suggest(category, query)) do
      json(conn, %{entries: Enum.map(values, &%{code: nil, label: &1})})
    else
      :unauthorized -> conn |> put_status(:unauthorized) |> json(%{error: "sign in first"})
      :not_found -> conn |> put_status(:not_found) |> json(%{error: "unknown category"})
      {:error, _} -> conn |> put_status(:service_unavailable) |> json(%{error: "unavailable"})
    end
  end

  defp search_entries(_dataset, "", _lang, _country), do: {:ok, []}

  defp search_entries(dataset, query, lang, country),
    do: App.IHDS.search(dataset, query, lang, @search_limit, country)

  defp suggestion(entry, lang) do
    region = entry["region"] && App.IHDS.lookup("regions", entry["region"], lang)

    %{
      code: entry["code"],
      label: entry["label"],
      context: entry["context_label"],
      country: entry["country"],
      flag: entry["country"] && String.downcase(entry["country"]),
      region: region && region["code"],
      region_label: region && region["label"]
    }
  end

  # `lang` is in the URL (not only in the session) so that a browser-cached
  # list in one language is never reused for another.
  defp lang(%{"lang" => lang}) do
    if lang in Gettext.known_locales(AppWeb.Gettext),
      do: lang,
      else: Gettext.get_locale(AppWeb.Gettext)
  end

  defp lang(_params), do: Gettext.get_locale(AppWeb.Gettext)

  defp compact(entry) do
    exact = Enum.reject([entry["code"], entry["alpha3"] | entry["alt_names"] || []], &is_nil/1)
    names = Map.values(entry["names"] || %{})

    %{
      code: entry["code"],
      label: entry["label"],
      flag: entry["flag"],
      exact: exact |> Enum.map(&normalize/1) |> Enum.uniq(),
      words: (names ++ exact) |> Enum.flat_map(&words/1) |> Enum.uniq()
    }
  end

  defp words(text), do: text |> normalize() |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)

  # Same folding as the picker's JavaScript: lowercase, accents removed.
  defp normalize(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
  end
end
