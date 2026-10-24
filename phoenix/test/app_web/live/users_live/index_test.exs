defmodule AppWeb.UsersLive.IndexTest do
  @moduledoc "Users page (docs/design/ui-plan.md item 7)."
  # Not async: one test turns on the global second-approval setting, which
  # the LiveView process reads.
  use AppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import App.Fixtures

  alias App.Accounts.User

  setup %{conn: conn} do
    admin = user_fixture(:admin)
    other = user_fixture(:viewer, [:line_commander])
    %{conn: authenticated_conn(conn, admin), admin: admin, other: other}
  end

  test "lists users with role and profile chips", %{conn: conn, other: other} do
    {:ok, view, _html} = live(conn, ~p"/users")
    html = render_async(view, 2_000)

    assert html =~ to_string(other.email)
    assert html =~ "Line commander"
    assert html =~ "Viewer"
  end

  test "access is edited in a panel: role and profiles saved together", %{
    conn: conn,
    other: other
  } do
    {:ok, view, _html} = live(conn, ~p"/users")
    render_async(view, 2_000)

    view
    |> element(~s(button[phx-click="edit_access"][phx-value-id="#{other.id}"]))
    |> render_click()

    assert has_element?(view, "#access-panel", "Clinician")
    assert has_element?(view, "#access-panel", "Clinical history (conditions, diagnoses)")

    view
    |> form("#access-form", %{"role" => "hr", "profiles" => ["", "clinician", "ciso"]})
    |> render_submit()

    updated = Ash.get!(User, other.id, authorize?: false)
    assert updated.role == :hr
    assert Enum.sort(updated.profiles) == [:ciso, :clinician]
    refute has_element?(view, "#access-panel")

    view
    |> element(~s(button[phx-click="edit_access"][phx-value-id="#{other.id}"]))
    |> render_click()

    view |> form("#access-form", %{"role" => "hr", "profiles" => [""]}) |> render_submit()
    assert Ash.get!(User, other.id, authorize?: false).profiles == []
  end

  test "an account is linked to a person, with a same-email suggestion", %{
    conn: conn,
    other: other
  } do
    match =
      person_fixture(%{given_name: "Same", family_name: "Email", email: to_string(other.email)})

    {:ok, view, _html} = live(conn, ~p"/users")
    render_async(view, 2_000)

    view
    |> element(~s(button[phx-click="edit_access"][phx-value-id="#{other.id}"]))
    |> render_click()

    assert has_element?(view, "#access-panel button", "Same email: Same Email")

    view
    |> form("#access-form", %{"role" => "viewer", "profiles" => [""], "person_id" => match.id})
    |> render_submit()

    assert Ash.get!(User, other.id, authorize?: false).person_id == match.id
    assert render_async(view, 2_000) =~ "Same Email"
  end

  test "with second approval on, a sensitive grant waits for another admin", %{
    conn: conn,
    other: other
  } do
    Application.put_env(:app, :require_second_approval, true)
    on_exit(fn -> Application.delete_env(:app, :require_second_approval) end)

    {:ok, view, _html} = live(conn, ~p"/users")
    render_async(view, 2_000)

    view
    |> element(~s(button[phx-click="edit_access"][phx-value-id="#{other.id}"]))
    |> render_click()

    view
    |> form("#access-form", %{"role" => "viewer", "profiles" => ["", "clinician", "registrar"]})
    |> render_submit()

    # Registrar isn't sensitive and line commander was unticked: both applied
    # now. Clinician waits for a second approver.
    assert Ash.get!(User, other.id, authorize?: false).profiles == [:registrar]

    assert has_element?(view, "#access-requests", "Clinician")
    assert has_element?(view, "#access-requests", "Awaiting another approver")
    refute has_element?(view, ~s(#access-requests button[phx-value-decision="approve"]))

    checker = user_fixture(:admin)

    {:ok, view2, _html} =
      live(authenticated_conn(Phoenix.ConnTest.build_conn(), checker), ~p"/users")

    view2
    |> element(~s(#access-requests button[phx-value-decision="approve"]))
    |> render_click()

    assert :clinician in Ash.get!(User, other.id, authorize?: false).profiles
    refute has_element?(view2, "#access-requests")
  end

  test "your own row can't be edited", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(conn, ~p"/users")
    render_async(view, 2_000)

    refute has_element?(view, ~s(button[phx-value-id="#{admin.id}"]))
    render_click(view, "edit_access", %{"id" => admin.id})
    refute has_element?(view, "#access-panel")
  end

  test "a user without users.manage is sent away", %{other: other} do
    conn = authenticated_conn(Phoenix.ConnTest.build_conn(), other)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/users")
  end

  test "an unauthenticated request is redirected to sign-in" do
    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/users")
  end

  describe "users and roles (docs/design/events-and-person-login.md)" do
    test "the sign-in methods, and each role and profile with who holds it", %{conn: conn} do
      admin = user_fixture(:admin)

      Ash.Seed.seed!(App.Accounts.User, %{
        email: "pid@demo.test",
        role: :person,
        login_id: "ABCD-EFGH-IJKL"
      })

      conn = authenticated_conn(conn, admin)
      {:ok, view, _} = live(conn, ~p"/users")
      assert render_async(view) =~ "PersonID…"

      {:ok, view, _} = live(conn, ~p"/users?view=roles")
      assert has_element?(view, "#role-person", "Person (own data)")
      assert has_element?(view, "#role-person", "1")
      assert has_element?(view, "#profile-nurse")
    end
  end
end
