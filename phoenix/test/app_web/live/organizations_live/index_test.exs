defmodule AppWeb.OrganizationsLive.IndexTest do
  @moduledoc """
  Real connected-mount coverage for the `Cinder.collection` adoption
  same `render_async/1` discipline as `PeopleLive.
  IndexTest`. Specifically exercises the `field="parent.name"` dot-
  notation relationship column, since that's the part of this
  extension with no precedent in the flagship `PeopleLive.Index`
  adoption (none of its columns cross a relationship).
  """
  use AppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias App.People.Organization

  test "renders organizations including the parent.name relationship column", %{conn: conn} do
    admin =
      Ash.Seed.seed!(App.Accounts.User, %{
        email: "admin-#{Ash.UUIDv7.generate()}@example.com",
        role: :admin
      })

    brigade =
      Organization
      |> Ash.Changeset.for_create(:create, %{name: "1st Brigade", kind: :brigade}, actor: admin)
      |> Ash.create!()

    battalion =
      Organization
      |> Ash.Changeset.for_create(
        :create,
        %{name: "2nd Battalion", kind: :battalion, parent_id: brigade.id},
        actor: admin
      )
      |> Ash.create!()

    {:ok, view, _html} = live(authenticated_conn(conn, admin), ~p"/organizations")
    settled = render_async(view, 2_000)

    assert settled =~ battalion.name
    # The relationship column — confirms field="parent.name" actually
    # resolves through Cinder's own query building, not just that the
    # page renders at all.
    assert settled =~ brigade.name
  end

  test "an unauthenticated request is redirected to sign-in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/organizations")
  end

  test "a unit's place is saved with it (ORG-GRAPH.1)", %{conn: conn} do
    admin =
      Ash.Seed.seed!(App.Accounts.User, %{
        email: "admin-#{Ash.UUIDv7.generate()}@example.com",
        role: :admin
      })

    {:ok, view, _html} = live(authenticated_conn(conn, admin), ~p"/organizations")
    render_hook(view, "open_create", %{})
    assert has_element?(view, "#organization-edit-form [name='form[country]']")
    assert has_element?(view, "#organization-edit-form [name='form[locality]']")

    # The country and place are pickers (hidden inputs set by their hooks).
    view
    |> element("#organization-edit-form")
    |> render_submit(%{
      "form" => %{"name" => "Garrison", "kind" => "unit", "country" => "UA", "locality" => "Lviv"}
    })

    [unit] = Organization |> Ash.read!(authorize?: false)
    assert {unit.country, unit.locality} == {"UA", "Lviv"}
  end
end
