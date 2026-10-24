defmodule AppWeb.ChangeConflictsLive.IndexTest do
  @moduledoc """
  Real connected-mount coverage for the `Cinder.collection` adoption
  the simplest of the four extensions (no inline
  forms/edit state), close to a pure drop-in replacement.
  """
  use AppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias App.Audit.ChangeConflict

  test "renders a logged conflict", %{conn: conn} do
    admin =
      Ash.Seed.seed!(App.Accounts.User, %{
        email: "admin-#{Ash.UUIDv7.generate()}@example.com",
        role: :admin
      })

    conflict =
      Ash.Seed.seed!(ChangeConflict, %{
        resource: "App.People.Person",
        record_id: Ash.UUIDv7.generate(),
        actor_email: "someone@example.com",
        expected_updated_at: DateTime.utc_now(),
        found_updated_at: DateTime.utc_now()
      })

    {:ok, view, _html} = live(authenticated_conn(conn, admin), ~p"/change-conflicts")
    settled = render_async(view, 2_000)

    assert settled =~ conflict.record_id
    assert settled =~ "someone@example.com"
  end

  test "an unauthenticated request is redirected to sign-in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/change-conflicts")
  end
end
