defmodule AppWeb.SheetsLiveTest do
  @moduledoc """
  Exercises `AppWeb.SheetsLive.mount/3`'s token verification 
  and range read/PubSub refresh. Uses
  `AppWeb.ConnCase`, whose setup always checks out a sandboxed DB connection
  (`App.DataCase.setup_sandbox/1`) regardless of whether a given test
  touches Ecto — so this file needs a reachable Postgres + an `app_test`
  database (`mix ecto.create`) to run, same as any other ConnCase test in
  this project.
  """
  use AppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import App.SheetsTokenFixtures

  alias App.Google.Sheets

  # The Tabbar's actual switching is Phoenix.LiveView.JS
  # (client-side only, confirmed live via Playwright against the real
  # embedded sidebar) — nothing ExUnit's server-side render can
  # observe. This guards the static structure the JS chains in
  # AppWeb.SheetsLive rely on by id (#tab-sheet/#tab-data/#panel-sheet/
  # #panel-data): a rename here without updating the matching selector
  # would silently break tab-switching without ever failing a test, so
  # this exists to at least catch that one class of regression.
  test "renders the accessible tabbar structure the JS-based tab switch depends on", %{
    conn: conn
  } do
    # Tabs beyond Sheet need an account in the app (people.read).
    Ash.Seed.seed!(App.Accounts.User, %{email: "person@example.com", role: :viewer})
    token = sheets_token(ssid: "ss-42")
    conn = put_connect_params(conn, %{"sheets_token" => token})

    {:ok, _view, html} = live(conn, ~p"/sheets")

    # Theme and language: rows at the bottom of the ☰ menu.
    assert html =~ ~s(id="theme-row")
    assert html =~ ~s(id="language-row")
    assert html =~ ~s(role="tablist")
    assert html =~ ~s(id="tab-sheet")
    assert html =~ ~s(id="tab-data")
    assert html =~ ~s(aria-controls="panel-sheet")
    assert html =~ ~s(aria-controls="panel-data")
    assert html =~ ~s(id="panel-sheet")
    assert html =~ ~s(id="panel-data")
  end

  test "authenticates when a valid sheets_token connect param is supplied", %{conn: conn} do
    token = sheets_token(sub: "person@example.com", ssid: "ss-42")
    conn = put_connect_params(conn, %{"sheets_token" => token})

    {:ok, _view, html} = live(conn, ~p"/sheets")

    # No account in the app: only the Sheet tab, so no tab list.
    assert html =~ ~s(id="panel-sheet")
    assert html =~ "person@example.com"
    assert html =~ "ss-42"
    refute html =~ "open it again"
  end

  test "shows an auth error when no token connect param is supplied", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/sheets")

    assert html =~ "did not pass a sign-in token"
    assert html =~ "missing_token"
  end

  test "names the sidebar's own failure instead of a missing token", %{conn: conn} do
    conn =
      put_connect_params(conn, %{"sheets_error" => "SHARED_SECRET script property is not set"})

    {:ok, _view, html} = live(conn, ~p"/sheets")

    assert html =~ "The Apps Script of this spreadsheet failed"
    assert html =~ "SHARED_SECRET script property is not set"
    assert html =~ "sidebar_error"
  end

  test "explains Google's multiple-accounts error", %{conn: conn} do
    message =
      "Під час зчитування зі сховища сталася помилка сервера. Код помилки: PERMISSION_DENIED."

    conn = put_connect_params(conn, %{"sheets_error" => message})
    {:ok, _view, html} = live(conn, ~p"/sheets")

    assert html =~ "signed in to several Google accounts"
    assert html =~ "multiple_accounts"
  end

  test "says when the sidebar didn't answer in time", %{conn: conn} do
    conn = put_connect_params(conn, %{"sheets_error" => "timeout"})
    {:ok, _view, html} = live(conn, ~p"/sheets")

    assert html =~ "did not answer in time"
    assert html =~ "no_answer"
    assert html =~ ~s(href="/sheets")
  end

  test "shows an auth error for an expired token", %{conn: conn} do
    now = System.system_time(:second)
    token = sheets_token(exp: now - 1)
    conn = put_connect_params(conn, %{"sheets_token" => token})

    {:ok, _view, html} = live(conn, ~p"/sheets")

    assert html =~ "session expired"
    assert html =~ "expired"
  end

  test "the disconnected (static) render shows pending, not an error", %{conn: conn} do
    conn = get(conn, ~p"/sheets")
    assert html_response(conn, 200) =~ "Waiting for Sheets context"
  end

  test "reads and displays the default range when a google_access_token is supplied", %{
    conn: conn
  } do
    Req.Test.stub(Sheets, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer google-token"]
      Req.Test.json(conn, %{"values" => [["hello", "world"]]})
    end)

    conn =
      put_connect_params(conn, %{
        "sheets_token" => sheets_token(ssid: "ss-42"),
        "google_access_token" => "google-token",
        "sheet_name" => "Sheet1"
      })

    {:ok, _view, html} = live(conn, ~p"/sheets")

    assert html =~ "hello"
    assert html =~ "world"
    refute html =~ "Sheets error"
  end

  test "shows a Sheets error without a google_access_token", %{conn: conn} do
    conn = put_connect_params(conn, %{"sheets_token" => sheets_token()})

    {:ok, _view, html} = live(conn, ~p"/sheets")

    assert html =~ "Sheets error: :missing_google_access_token"
  end

  test "re-fetches the range when notified of an edit via PubSub", %{conn: conn} do
    Req.Test.stub(Sheets, fn conn -> Req.Test.json(conn, %{"values" => [["old"]]}) end)

    conn =
      put_connect_params(conn, %{
        "sheets_token" => sheets_token(ssid: "ss-77"),
        "google_access_token" => "google-token",
        "sheet_name" => "Sheet1"
      })

    {:ok, view, html} = live(conn, ~p"/sheets")
    assert html =~ "old"

    Req.Test.stub(Sheets, fn conn -> Req.Test.json(conn, %{"values" => [["new"]]}) end)
    App.Sheets.notify_edit("ss-77", %{sheet_name: "Sheet1", a1: "A1"})

    assert render(view) =~ "new"
  end

  # The `sub` claim inside a real sheets_token is a plain email (from GAS's
  # Session.getActiveUser()); the Data tab needs a matching
  # App.Accounts.User (see the module's own moduledoc).
  describe "Data tab" do
    setup %{conn: conn} do
      Req.Test.stub(Sheets, fn conn -> Req.Test.json(conn, %{"values" => []}) end)

      conn =
        put_connect_params(conn, %{
          "sheets_token" => sheets_token(sub: "hr@example.com", ssid: "ss-roster"),
          "google_access_token" => "google-token",
          "sheet_name" => "Sheet1"
        })

      %{conn: conn}
    end

    test "no matching account: data tools stay hidden with an explanation", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sheets")

      assert html =~ "No account matches"
      assert html =~ "hr@example.com"
      refute html =~ "tool-data.export"
    end

    test ":viewer can export but not check or add rows", %{conn: conn} do
      Ash.Seed.seed!(App.Accounts.User, %{email: "hr@example.com", role: :viewer})

      {:ok, _view, html} = live(conn, ~p"/sheets")

      assert html =~ ~s(id="tool-data.export")
      refute html =~ ~s(id="tool-data.check")
      refute html =~ ~s(id="tool-data.new")
    end
  end
end
