defmodule AppWeb.SheetsWebhookControllerTest do
  @moduledoc """
  Uses `AppWeb.ConnCase`, whose setup always checks out a sandboxed DB
  connection regardless of whether a test touches Ecto — needs a reachable
  Postgres + `app_test` database (`mix ecto.create`) to run.
  """
  use AppWeb.ConnCase, async: true

  import App.SheetsTokenFixtures

  test "broadcasts an edit notification and returns 204 given a valid token", %{conn: conn} do
    App.Sheets.subscribe("ss-1")
    token = sheets_token(ssid: "ss-1")

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(~p"/webhooks/sheets/edit", %{"sheetName" => "Sheet1", "a1" => "B2"})

    assert response(conn, 204)
    assert_receive {:sheets_edit, %{sheet_name: "Sheet1", a1: "B2"}}
  end

  test "rejects a missing token with 401 and broadcasts nothing", %{conn: conn} do
    App.Sheets.subscribe("ss-1")

    conn = post(conn, ~p"/webhooks/sheets/edit", %{"sheetName" => "Sheet1", "a1" => "B2"})

    assert response(conn, 401)
    refute_receive {:sheets_edit, _}
  end

  test "rejects an expired token with 401", %{conn: conn} do
    now = System.system_time(:second)
    token = sheets_token(ssid: "ss-1", exp: now - 1)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> post(~p"/webhooks/sheets/edit", %{"sheetName" => "Sheet1", "a1" => "B2"})

    assert response(conn, 401)
  end
end
