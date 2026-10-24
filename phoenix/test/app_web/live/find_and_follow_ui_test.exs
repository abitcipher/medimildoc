defmodule AppWeb.FindAndFollowUiTest do
  @moduledoc "docs/design/search-timeline-notifications.md: search page, timeline tab, notifications page."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  alias App.Notify.Emitter

  setup %{conn: conn} do
    App.Access.put_admin_full_data_access_override(false)
    unit = org_fixture("A Company")

    person =
      person_fixture(%{given_name: "Olena", family_name: "Kovalenko"}) |> assign_fixture(unit)

    %{conn: conn, person: person, hr: user_fixture(:hr)}
  end

  test "search updates while typing and links to the person", %{
    conn: conn,
    hr: hr,
    person: person
  } do
    {:ok, view, _html} = live(authenticated_conn(conn, hr), ~p"/search?q=zzzz")
    assert render(view) =~ "Nothing found."

    html = view |> form("#search-form", %{"q" => "koval"}) |> render_change()
    assert_patch(view, ~p"/search?q=koval")
    assert html =~ "Olena Kovalenko"
    assert has_element?(view, ~s(#found-people a[href="/people/#{person.id}"]))
  end

  test "the person page has a timeline", %{conn: conn, hr: hr, person: person} do
    record_fixture(person, :rank_history, %{"grade" => "OR-4", "effectiveDate" => "2024-05-01"})
    {:ok, view, _html} = live(authenticated_conn(conn, hr), ~p"/people/#{person.id}")
    timeline = view |> element("#person-timeline") |> render()
    assert timeline =~ "2024"
    assert timeline =~ "Rank"
  end

  test "a user subscribes, sets a channel and reads messages", %{conn: conn, hr: hr} do
    Emitter.emit(:registration, [hr.id])
    {:ok, view, html} = live(authenticated_conn(conn, hr), ~p"/notifications")
    assert html =~ "Your account was registered"
    # Incidents are offered only to those who may review them.
    refute html =~ "New data-consistency incident"

    view
    |> element(~s(input[phx-value-event="document_waiting"][phx-value-channel="telegram"]))
    |> render_click()

    assert [%{event: :document_waiting, channel: :telegram}] =
             Ash.read!(App.Notify.Subscription, authorize?: false)

    view
    |> form("#channel-telegram", %{"address" => "4242", "enabled" => "true"})
    |> render_submit()

    assert [%{kind: :telegram, address: "4242"}] =
             Ash.read!(App.Notify.Channel, authorize?: false)

    view |> element("button", "Mark all read") |> render_click()

    assert Enum.all?(
             Ash.read!(App.Notify.Notification, authorize?: false),
             &(&1.read_at || &1.channel != :in_app)
           )
  end
end
