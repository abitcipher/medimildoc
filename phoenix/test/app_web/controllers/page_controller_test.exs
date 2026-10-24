defmodule AppWeb.PageControllerTest do
  use AppWeb.ConnCase

  import App.Fixtures

  test "signed out: a sign-in card", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(href="/sign-in")
    assert html =~ ~s(id="language-menu-button")
    assert html =~ ~r/<html[^>]* lang="en"/
    assert conn |> get(~p"/?locale=uk") |> html_response(200) =~ ~r/<html[^>]* lang="uk"/
    refute html =~ ~s(href="/people")
  end

  test "signed in: start cards for exactly the sections the user may open", %{conn: conn} do
    html =
      conn
      |> authenticated_conn(user_fixture(:viewer, [:ciso]))
      |> get(~p"/")
      |> html_response(200)

    # No greeting or other decoration, only what can be used.
    refute html =~ "Welcome"
    assert html =~ ~s(href="/people")
    assert html =~ ~s(href="/access-log")
    refute html =~ ~s(href="/users")
  end

  describe "start page widgets (docs/design/ui-plan.md item 8)" do
    setup do
      App.Access.put_admin_full_data_access_override(false)
      unit = org_fixture("Unit")
      fit = person_fixture(%{given_name: "Fit"}) |> assign_fixture(unit)
      down = person_fixture(%{given_name: "Down"}) |> assign_fixture(unit)
      elsewhere = person_fixture(%{given_name: "Far"}) |> assign_fixture(org_fixture("Elsewhere"))

      record_fixture(fit, :fitness_for_duty, %{"status" => "fit_for_duty"})
      record_fixture(down, :fitness_for_duty, %{"status" => "downgraded"})
      record_fixture(elsewhere, :fitness_for_duty, %{"status" => "non_effective"})

      App.People.IdentityDocument
      |> Ash.Changeset.for_create(
        :create,
        %{
          person_id: down.id,
          document_type: :military_id,
          number: "TEST-1",
          issued_on: Date.add(Date.utc_today(), -3000),
          expires_on: Date.add(Date.utc_today(), 10)
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

      %{unit: unit}
    end

    defp home_as(conn, user),
      do: conn |> authenticated_conn(user) |> get(~p"/") |> html_response(200)

    test "each role sees its own widgets", %{conn: conn} do
      hr = home_as(conn, user_fixture(:hr))
      assert hr =~ ~s(id="w-readiness")
      assert hr =~ ~s(id="w-clearances")
      assert hr =~ ~s(id="w-documents")
      refute hr =~ "Emergency accesses to review"

      ciso = home_as(conn, user_fixture(:viewer, [:ciso]))
      assert ciso =~ "Emergency accesses to review"
      refute ciso =~ ~s(id="w-readiness")

      refute home_as(conn, user_fixture(:viewer)) =~ ~s(id="w-)
    end

    test "a line commander's readiness counts only their unit", %{conn: conn, unit: unit} do
      html = home_as(conn, unit_user_fixture(:viewer, [:line_commander], unit))

      assert html =~ "Down"
      refute html =~ "Far"

      # Status badges: one symbol, colour and details on hover; position badge.
      assert html =~ ~r/badge-warning[^>]*data-float-tip="Downgraded/
      assert html =~ ~r/data-float-tip="Fit for duty[^"]*"[^>]*>\s*<span aria-hidden="true">\+</
      assert html =~ ~s(data-float-tip="Post · Unit")
    end

    test "opening the start page writes no access-log rows", %{conn: conn} do
      home_as(conn, user_fixture(:hr))
      assert Ash.read!(App.Audit.AccessLog, authorize?: false) == []
    end
  end
end
