defmodule AppWeb.EventsLiveTest do
  @moduledoc "docs/design/events-and-person-login.md: the event log page."
  use AppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import App.Fixtures

  alias App.EventLog

  test "access events on their own tab, all on the other, the packet on click, the switches", %{
    conn: conn
  } do
    admin = user_fixture(:admin)
    EventLog.emit("hrda.auth.sign_in.failed", %{method: "person_id", reason: "bad_credentials"})
    EventLog.emit("hrda.documents.document.signed", %{document_type: "leave_request"})

    conn = authenticated_conn(conn, admin)
    {:ok, view, _} = live(conn, ~p"/events")
    html = render_async(view)
    assert html =~ "hrda.auth.sign_in.failed"
    refute html =~ "hrda.documents.document.signed"

    {:ok, view, _} = live(conn, ~p"/events?tab=all&severity=notice")
    html = render_async(view)
    assert html =~ "hrda.documents.document.signed"
    refute html =~ "hrda.auth.sign_in.failed"

    [event] =
      App.Events.Event
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&(&1.type == "hrda.documents.document.signed"))

    render_click(view, "show", %{"id" => event.id})
    assert has_element?(view, "#event-packet", ~s("specversion": "1.0"))

    view |> element("#switch-logging") |> render_click()
    refute EventLog.logging?()
    assert has_element?(view, "#switch-publishing[disabled]")
  end

  test "without audit.read there is no page", %{conn: conn} do
    conn = authenticated_conn(conn, user_fixture(:hr))
    assert {:error, {_, %{to: _}}} = live(conn, ~p"/events")
  end
end
