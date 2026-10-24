defmodule AppWeb.FsdcUiTest do
  @moduledoc "docs/design/data-consistency.md: settings, rules, incidents on screen."
  use AppWeb.ConnCase, async: false

  alias App.Rules.Library
  import App.Fixtures
  import Phoenix.LiveViewTest

  alias App.People.PersonRecord

  setup %{conn: conn} do
    Library.sync()
    %{conn: conn, admin: user_fixture(:admin), ciso: user_fixture(:viewer, [:ciso])}
  end

  defp encounter(person, actor) do
    PersonRecord
    |> Ash.Changeset.for_create(
      :create,
      %{person_id: person.id, kind: :encounter, data: App.Demo.sample_record_data(:encounter)},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  test "an admin switches FSDC on; a violation shows up in Incidents and is reviewed",
       %{conn: conn, admin: admin, ciso: ciso} do
    {:ok, view, _html} = live(authenticated_conn(conn, admin), ~p"/settings")
    refute has_element?(view, "#fsdc-toggle[checked]")
    view |> element("#fsdc-toggle") |> render_click()
    assert App.Settings.fsdc?()
    assert has_element?(view, "#fsdc-toggle[checked]")

    encounter(person_fixture(), admin)

    {:ok, view, html} = live(authenticated_conn(conn, ciso), ~p"/incidents")
    assert html =~ "No identity document was entered before this examination."

    [incident] = Ash.read!(App.Audit.Incident, authorize?: false)
    view |> element("#incident-#{incident.id} button", "Review") |> render_click()

    view
    |> form("#review-#{incident.id}", %{
      "status" => "explained",
      "note" => "Passport entered late"
    })
    |> render_submit()

    assert Ash.get!(App.Audit.Incident, incident.id, authorize?: false).status == :explained
  end

  test "rules: severity, on/off and a check of existing data", %{conn: conn, admin: admin} do
    person = person_fixture()
    encounter(person, admin)
    :ok = App.Settings.put("fsdc.enabled", true, admin)

    {:ok, view, html} = live(authenticated_conn(conn, admin), ~p"/rules")
    assert html =~ "Identity verified before examination"

    view
    |> form("#severity-identity_before_examination", %{"severity" => "observe"})
    |> render_change(%{"key" => "identity_before_examination", "severity" => "observe"})

    assert Ash.get!(App.Rules.RuleSet, "identity_before_examination", authorize?: false).severity ==
             :observe

    html = view |> element("button", "Check existing data") |> render_click()
    assert html =~ "1 new incidents"

    # The reference check needs the seeded reference data (App.Rules.ReferenceTest).
    html = view |> element("button", "Reference check") |> render_click()
    assert html =~ "The synthetic data is not the reference set."
  end

  test "only the right permissions open these pages", %{conn: conn} do
    hr = user_fixture(:hr)
    assert {:error, {:redirect, _}} = live(authenticated_conn(conn, hr), ~p"/settings")
    assert {:error, {:redirect, _}} = live(authenticated_conn(conn, hr), ~p"/rules")
    assert {:error, {:redirect, _}} = live(authenticated_conn(conn, hr), ~p"/incidents")
  end
end
