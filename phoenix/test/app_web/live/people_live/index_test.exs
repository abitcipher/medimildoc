defmodule AppWeb.PeopleLive.IndexTest do
  @moduledoc """
  Exercises `AppWeb.PeopleLive.Index` through a real connected mount
  (`Phoenix.LiveViewTest.live/2` + `render_async/1`), not just the
  static disconnected render `Plug.Conn` gives us — 
  `Cinder.collection` adoption loads its rows via an async task after
  connect (confirmed live against a real Docker release build while
  building this: both a plain `curl` and `live/2`'s own initial return
  show an empty `<tbody>` with a loading indicator, not the actual
  data). This is the reliable way to check what a real signed-in
  user's browser would eventually see, without fighting this session's
  known Playwright flakiness for something a plain
  LiveView test already covers better.
  """
  use AppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias App.People.{Person, PersonId}

  test "renders known people via the connected Cinder table, not just the static shell", %{
    conn: conn
  } do
    admin =
      Ash.Seed.seed!(App.Accounts.User, %{
        email: "admin-#{Ash.UUIDv7.generate()}@example.com",
        role: :admin
      })

    person =
      Person
      |> Ash.Changeset.for_create(:create, %{given_name: "Ada", family_name: "Lovelace"},
        actor: admin
      )
      |> Ash.create!()

    {:ok, view, html} = live(authenticated_conn(conn, admin), ~p"/people")
    # Cinder's collection loads its rows via an async task after connect
    # (confirmed live: the initial render's <tbody> is empty with a
    # loading indicator, not the actual data) — render_async/1 is
    # LiveViewTest's own helper for exactly this pattern, not a sleep.
    refute html =~ "Ada Lovelace"
    settled = render_async(view, 2_000)

    assert settled =~ "Ada Lovelace"
    assert settled =~ PersonId.format(person.person_id)
  end

  test "an unauthenticated request is redirected to sign-in, never sees the table", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/people")
  end

  test "filtering by the dash-formatted PersonID (the rough edge fixed) still matches",
       %{conn: conn} do
    admin =
      Ash.Seed.seed!(App.Accounts.User, %{
        email: "admin-#{Ash.UUIDv7.generate()}@example.com",
        role: :admin
      })

    target =
      Person
      |> Ash.Changeset.for_create(:create, %{given_name: "Ada", family_name: "Lovelace"},
        actor: admin
      )
      |> Ash.create!()

    _other =
      Person
      |> Ash.Changeset.for_create(:create, %{given_name: "Grace", family_name: "Hopper"},
        actor: admin
      )
      |> Ash.create!()

    {:ok, view, _html} = live(authenticated_conn(conn, admin), ~p"/people")
    render_async(view, 2_000)

    # The collection's id is "people-table" (explicit since the page
    # navigation above it needs one) — its filter form is
    # "#{id}-filter-form", and Cinder.Filter.field_name/1 names each
    # input "filters[<field>]".
    formatted = PersonId.format(target.person_id)

    view
    |> form("#people-table-filter-form", %{"filters" => %{"person_id" => formatted}})
    |> render_change()

    settled = render_async(view, 2_000)

    assert settled =~ "Ada Lovelace"
    refute settled =~ "Grace Hopper"
  end
end
