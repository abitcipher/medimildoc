defmodule AppWeb.ExportController do
  @moduledoc """
  `GET /exports/assignments.xlsx` — the offline assignments workbook
  (`App.People.AssignmentSync.export/1` → `App.Xlsx`,
  docs/design/assignments-sheets.md), with what the signed-in user may read.

  `GET /exports/register.xlsx?code=&year=[&type=]` or `?case=` — a register
  for a year or a case's contents (docs/design/registers-file-plan.md), as
  on the Registers page.

  `GET /exports/case-inventory.pdf|.xlsx?year=&kind=` — the inventory of a
  year's closed cases of one retention class (`App.Records.Inventory`).
  """
  use AppWeb, :controller

  alias App.Documents.Types
  alias App.People.AssignmentSync
  alias App.Records.{Case, DisposalAct, Inventory, Registers}

  def assignments(conn, _params) do
    user = conn.assigns[:current_user]

    if user && AppWeb.Authz.can?(user, "people.read") do
      {:ok, binary} = user |> AssignmentSync.export() |> App.Xlsx.assignments_workbook()

      send_download(conn, {:binary, binary},
        filename: "assignments-#{Date.to_iso8601(Date.utc_today())}.xlsx",
        content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      )
    else
      conn |> put_status(:forbidden) |> text(gettext("Not allowed."))
    end
  end

  def register(conn, params) do
    user = conn.assigns[:current_user]

    with true <- user != nil,
         true <-
           AppWeb.Authz.can?(user, "records.manage") or AppWeb.Authz.can?(user, "people.write"),
         {:ok, filters, name} <- register_filters(params, user) do
      %{entries: entries} = Registers.entries(filters, user, :all)

      header = [
        gettext("Number"),
        gettext("Registered"),
        gettext("Type"),
        gettext("Person"),
        gettext("Signed by"),
        gettext("Case")
      ]

      rows =
        Enum.map(entries, fn e ->
          [
            e.number,
            AppWeb.DateFormat.display(e.registered_on),
            AppWeb.DocumentUI.type_label(e.type),
            e.person || "—",
            e.signed_by || "",
            e.case_index || ""
          ]
        end)

      {:ok, binary} = App.Xlsx.table_workbook(name, [header | rows], [14, 12, 34, 32, 24, 10])

      send_download(conn, {:binary, binary},
        filename: "register-#{name}.xlsx",
        content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      )
    else
      _ -> conn |> put_status(:forbidden) |> text(gettext("Not allowed."))
    end
  end

  defp register_filters(%{"case" => id} = params, user) do
    case Ash.get(Case, id, actor: user) do
      {:ok, kase} -> {:ok, with_type(%{case_id: kase.id}, params), "#{kase.year}-#{kase.index}"}
      _ -> :error
    end
  end

  defp register_filters(%{"code" => code, "year" => year} = params, _user) do
    case Integer.parse(year) do
      {year, ""} -> {:ok, with_type(%{code: code, year: year}, params), "#{year}-#{code}"}
      _ -> :error
    end
  end

  defp register_filters(_params, _user), do: :error

  defp with_type(filters, %{"type" => type}) when is_binary(type) and type != "" do
    case Enum.find(Types.ids(), &(Atom.to_string(&1) == type)) do
      nil -> filters
      found -> Map.put(filters, :type, found)
    end
  end

  defp with_type(filters, _params), do: filters

  def case_inventory_pdf(conn, params) do
    with {:ok, user, year, kind} <- inventory_params(conn, params),
         {:ok, pdf} <- Inventory.pdf(year, kind, user) do
      send_download(conn, {:binary, pdf},
        filename: "inventory-#{year}-#{kind}.pdf",
        content_type: "application/pdf",
        disposition: :inline
      )
    else
      _ -> conn |> put_status(:not_found) |> text(gettext("Not found."))
    end
  end

  def case_inventory_xlsx(conn, params) do
    case inventory_params(conn, params) do
      {:ok, user, year, kind} ->
        header = [
          "№",
          gettext("Index"),
          gettext("Title"),
          gettext("First document"),
          gettext("Last document"),
          gettext("Documents"),
          gettext("Retention"),
          gettext("Note")
        ]

        rows =
          year
          |> Inventory.rows(kind, user)
          |> Enum.map(fn r ->
            Enum.map(~w(n index title first last documents retention note), &r[&1])
          end)

        {:ok, binary} =
          App.Xlsx.table_workbook("#{year}", [header | rows], [6, 10, 50, 14, 14, 12, 18, 30])

        send_download(conn, {:binary, binary},
          filename: "inventory-#{year}-#{kind}.xlsx",
          content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        )

      :error ->
        conn |> put_status(:not_found) |> text(gettext("Not found."))
    end
  end

  defp inventory_params(conn, %{"year" => year, "kind" => kind}) do
    user = conn.assigns[:current_user]

    with true <- user != nil,
         true <-
           AppWeb.Authz.can?(user, "records.manage") or AppWeb.Authz.can?(user, "people.write"),
         {year, ""} <- Integer.parse(year),
         kind when is_atom(kind) <-
           Enum.find(Inventory.kinds(), &(Atom.to_string(&1) == kind)) do
      {:ok, user, year, kind}
    else
      _ -> :error
    end
  end

  defp inventory_params(_conn, _params), do: :error

  def disposal_act(conn, _params) do
    user = conn.assigns[:current_user]

    with true <- user != nil and AppWeb.Authz.can?(user, "records.manage"),
         {:ok, pdf} <- DisposalAct.pdf(Date.utc_today(), user) do
      send_download(conn, {:binary, pdf},
        filename: "disposal-act-#{Date.to_iso8601(Date.utc_today())}.pdf",
        content_type: "application/pdf",
        disposition: :inline
      )
    else
      _ -> conn |> put_status(:not_found) |> text(gettext("Not found."))
    end
  end
end
