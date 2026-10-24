defmodule AppWeb.RegistersLive do
  @moduledoc """
  Registers (docs/design/registers-file-plan.md): the signed documents of a
  register and year in number order, or of one file plan case
  (`?case=`), with export to .xlsx. Names of the people documents are
  about show only where the viewer may read the document
  (`App.Records.Registers`). Everything is in the URL.
  """
  use AppWeb, :live_view

  alias App.Documents.{Document, Types}
  alias App.Records.{Case, Registers}
  alias AppWeb.{DataList, DateFormat, DocumentUI}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Registers"),
       codes: Registers.codes(),
       letters?: App.Access.can?(socket.assigns.current_user, "records.manage")
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    viewer = socket.assigns.current_user
    page = parse_int(params["page"], 1)

    {filters, kase} =
      case params["case"] && Ash.get(Case, params["case"], actor: viewer) do
        {:ok, kase} ->
          {%{case_id: kase.id}, kase}

        _ ->
          code = valid_code(params["code"], socket.assigns.codes)
          {%{code: code, year: parse_int(params["year"], Date.utc_today().year)}, nil}
      end

    type = valid_type(params["type"], filters)
    result = Registers.entries(Map.put(filters, :type, type), viewer, page)

    {:noreply,
     assign(socket,
       filters: filters,
       kase: kase,
       type: type,
       page: page,
       entries: result.entries,
       total: result.total,
       years: years(filters)
     )}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query =
      %{"code" => params["code"], "year" => params["year"], "type" => params["type"]}
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/registers?#{query}")}
  end

  # A new letter, as a draft (docs/design/correspondence.md).
  def handle_event("new_letter", %{"type" => type}, socket)
      when type in ["incoming_letter", "outgoing_letter"] do
    actor = socket.assigns.current_user

    Document
    |> Ash.Changeset.for_create(:create, %{type: String.to_existing_atom(type), data: %{}},
      actor: actor
    )
    |> Ash.create(actor: actor)
    |> case do
      {:ok, document} -> {:noreply, push_navigate(socket, to: ~p"/documents/#{document.id}")}
      {:error, error} -> {:noreply, put_flash(socket, :error, App.AshErrors.summarize(error))}
    end
  end

  defp valid_code(code, codes) do
    if Enum.any?(codes, &(elem(&1, 0) == code)), do: code, else: codes |> hd() |> elem(0)
  end

  defp valid_type(nil, _filters), do: nil
  defp valid_type("", _filters), do: nil

  defp valid_type(type, filters) do
    Enum.find(types_of(filters), &(Atom.to_string(&1) == type))
  end

  defp types_of(%{code: code}), do: Registers.codes() |> List.keyfind(code, 0) |> elem(1)
  defp types_of(_filters), do: Types.ids()

  defp years(%{code: code, year: year}),
    do: Enum.uniq([Date.utc_today().year, year | Registers.years(code)]) |> Enum.sort(:desc)

  defp years(_filters), do: []

  defp parse_int(value, default) do
    case Integer.parse(value || "") do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp export_query(%{case_id: id}, type), do: compact(%{"case" => id, "type" => type})

  defp export_query(%{code: code, year: year}, type),
    do: compact(%{"code" => code, "year" => year, "type" => type})

  defp page_query(filters, type, page),
    do: Map.put(export_query(filters, type), "page", page)

  defp compact(map),
    do:
      map
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new(fn {k, v} -> {k, to_string(v)} end)

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        first: (assigns.page - 1) * Registers.page_size() + 1,
        last: min(assigns.page * Registers.page_size(), assigns.total)
      )

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-5xl flex-col gap-4 p-4">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h1 class="flex items-center gap-2 text-xl font-semibold">
            {gettext("Registers")}
            <.field_description description={
              gettext(
                "Signed documents in number order. The person a document is about is shown only to those who may read the document."
              )
            } />
          </h1>
          <div :if={@letters?} class="flex flex-wrap gap-2">
            <button
              id="new-incoming"
              type="button"
              phx-click="new_letter"
              phx-value-type="incoming_letter"
              class="btn btn-sm btn-primary"
            >
              <.icon name="hero-envelope-open" class="size-4" /> {gettext("New incoming letter")}
            </button>
            <button
              id="new-outgoing"
              type="button"
              phx-click="new_letter"
              phx-value-type="outgoing_letter"
              class="btn btn-sm"
            >
              <.icon name="hero-paper-airplane" class="size-4" /> {gettext("New outgoing letter")}
            </button>
          </div>
          <.link
            href={~p"/exports/register.xlsx?#{export_query(@filters, @type)}"}
            class="btn btn-sm"
            id="register-export"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Export (.xlsx)")}
          </.link>
        </div>

        <div :if={@kase} id="case-heading" class="flex flex-wrap items-center gap-2">
          <.link navigate={~p"/file-plan?year=#{@kase.year}"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-4" /> {gettext("File plan")}
          </.link>
          <span class="font-semibold">{gettext("Case %{index}", index: @kase.index)}</span>
          <span class="opacity-80">{@kase.title}</span>
          <span class="badge badge-sm">{@kase.year}</span>
        </div>

        <form
          :if={!@kase}
          id="register-filter"
          phx-change="filter"
          class="flex flex-wrap items-end gap-2"
        >
          <label class="flex flex-col gap-1 text-sm">
            {gettext("Register")}
            <select name="code" class="select select-sm w-auto">
              <option
                :for={{code, types} <- @codes}
                value={code}
                selected={code == @filters.code}
                title={Enum.map_join(types, ", ", &DocumentUI.type_label/1)}
              >
                {code}
              </option>
            </select>
          </label>
          <label class="flex flex-col gap-1 text-sm">
            {gettext("Year")}
            <select name="year" class="select select-sm w-auto">
              <option :for={year <- @years} value={year} selected={year == @filters.year}>
                {year}
              </option>
            </select>
          </label>
          <label class="flex flex-col gap-1 text-sm">
            {gettext("Type")}
            <select name="type" class="select select-sm w-auto max-w-full">
              <option value="">{gettext("All types")}</option>
              <option
                :for={type <- types_of(@filters)}
                value={type}
                selected={type == @type}
              >
                {DocumentUI.type_label(type)}
              </option>
            </select>
          </label>
        </form>

        <section id="register-entries">
          <DataList.section_header
            id="register-header"
            title={gettext("Entries")}
            count={@total}
          />
          <DataList.data_list
            id="register-list"
            rows={@entries}
            empty={gettext("No signed documents.")}
          >
            <:col :let={e} label={gettext("Number")}>
              <.link :if={e.readable?} navigate={~p"/documents/#{e.id}"} class="link font-mono">
                {e.number}
              </.link>
              <span :if={!e.readable?} class="font-mono">{e.number}</span>
            </:col>
            <:col :let={e} label={gettext("Registered")}>
              {DateFormat.display(e.registered_on)}
            </:col>
            <:col :let={e} label={gettext("Type")}>{DocumentUI.type_label(e.type)}</:col>
            <:col :let={e} label={gettext("Person")}>
              <span :if={e.person}>{e.person}</span>
              <span
                :if={!e.person}
                class="opacity-60"
                title={gettext("Not shown: you may not read this document.")}
              >
                —
              </span>
            </:col>
            <:col :let={e} label={gettext("Signed by")}>{e.signed_by}</:col>
            <:col :let={e} label={gettext("Case")}>
              <span :if={e.case_index} class="font-mono">{e.case_index}</span>
              <span :if={!e.case_index} class="text-warning">{gettext("not filed")}</span>
            </:col>
          </DataList.data_list>

          <nav
            :if={@total > length(@entries)}
            id="register-pages"
            class="mt-2 flex items-center justify-between gap-2 text-sm"
          >
            <span class="opacity-70">
              {gettext("%{first}–%{last} of %{total}", first: @first, last: @last, total: @total)}
            </span>
            <span class="flex gap-1">
              <.link
                :if={@page > 1}
                patch={~p"/registers?#{page_query(@filters, @type, @page - 1)}"}
                class="btn btn-sm"
              >
                <.icon name="hero-chevron-left" class="size-4" />
                <span class="sr-only">{gettext("Previous page")}</span>
              </.link>
              <.link
                :if={@last < @total}
                patch={~p"/registers?#{page_query(@filters, @type, @page + 1)}"}
                class="btn btn-sm"
              >
                <.icon name="hero-chevron-right" class="size-4" />
                <span class="sr-only">{gettext("Next page")}</span>
              </.link>
            </span>
          </nav>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
