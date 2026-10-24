defmodule AppWeb.PositionsLive.IndexTest do
  @moduledoc """
  Real connected-mount coverage for the `Cinder.collection` adoption
  exercises the `field="organization.name"`
  relationship column, same reasoning as `OrganizationsLive.IndexTest`.
  """
  use AppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias App.People.{Organization, Position}

  test "renders positions including the organization.name relationship column", %{conn: conn} do
    admin =
      Ash.Seed.seed!(App.Accounts.User, %{
        email: "admin-#{Ash.UUIDv7.generate()}@example.com",
        role: :admin
      })

    org =
      Organization
      |> Ash.Changeset.for_create(:create, %{name: "1st Brigade", kind: :brigade}, actor: admin)
      |> Ash.create!()

    position =
      Position
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Brigade Commander", organization_id: org.id, authorised_grade: "OF-5"},
        actor: admin
      )
      |> Ash.create!()

    {:ok, view, _html} = live(authenticated_conn(conn, admin), ~p"/positions")
    settled = render_async(view, 2_000)

    assert settled =~ position.title
    assert settled =~ org.name
    assert settled =~ "OF-5"
  end

  test "an unauthenticated request is redirected to sign-in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/positions")
  end
end
