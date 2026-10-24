defmodule AppWeb.SheetsWebhookController do
  @moduledoc """
  Target of the Apps Script shim's installable `onEdit` trigger (`onSheetEdit`
  in `apps_script/src/main.ts`;. `onEdit` is not
  transactional and delivery is not guaranteed — this is a best-effort
  "something changed, go re-fetch" nudge for already-open LiveViews
  (`App.Sheets.notify_edit/2`), never a source of truth.

  Authenticated by `AppWeb.Plugs.VerifySheetsToken` (router pipeline), same
  HMAC token scheme as the LiveView session (`App.SheetsToken`) — it's the
  shim calling its own backend, not a browser, so no OAuth token involved
  here.
  """
  use AppWeb, :controller

  def edit(conn, params) do
    %{spreadsheet_id: spreadsheet_id} = conn.assigns.sheets_claims

    App.Sheets.notify_edit(spreadsheet_id, %{
      sheet_name: params["sheetName"],
      a1: params["a1"]
    })

    send_resp(conn, :no_content, "")
  end
end
