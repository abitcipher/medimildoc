defmodule AppWeb.CareUiTest do
  @moduledoc "docs/design/referral-discharge.md: the providers page and the provider choice."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  alias App.Care.Provider

  setup %{conn: conn} do
    App.Access.put_admin_full_data_access_override(false)

    for {name, priority} <- [{"Role 3 Field Hospital", true}, {"Regional Hospital", false}] do
      Provider
      |> Ash.Changeset.for_create(:create, %{name: name, priority: priority}, authorize?: false)
      |> Ash.create!(authorize?: false)
    end

    %{conn: conn}
  end

  test "the list shows our units first; a registrar adds a provider", %{conn: conn} do
    registrar = user_fixture(:viewer, [:registrar])
    {:ok, view, _html} = live(authenticated_conn(conn, registrar), ~p"/care-providers")
    html = render_async(view)

    assert html =~ "Our unit"
    {own, _} = :binary.match(html, "Role 3 Field Hospital")
    {external, _} = :binary.match(html, "Regional Hospital")
    assert own < external

    view |> element("#provider-actions-toolbar button") |> render_click()

    view
    |> form("#provider-new-form", %{
      "form" => %{"name" => "Demo Clinic", "provider_type" => "clinic"}
    })
    |> render_submit()

    assert render_async(view) =~ "Demo Clinic"
  end

  test "a viewer sees the list without the forms", %{conn: conn} do
    {:ok, view, _html} =
      live(authenticated_conn(conn, user_fixture(:viewer)), ~p"/care-providers")

    assert render_async(view) =~ "Regional Hospital"
    refute has_element?(view, "#provider-new-form")
  end

  test "a referral offers providers in two groups", %{conn: conn} do
    unit = org_fixture("A Company")
    patient = person_fixture() |> assign_fixture(unit)
    clinician = unit_user_fixture(:viewer, [:clinician], unit)

    attrs = %{type: :care_referral, person_id: patient.id, data: %{}}

    {:ok, document} =
      App.Documents.Document
      |> Ash.Changeset.for_create(:create, attrs, actor: clinician)
      |> Ash.create(actor: clinician)

    {:ok, view, _html} = live(authenticated_conn(conn, clinician), "/documents/#{document.id}")
    assert has_element?(view, ~s(optgroup[label="Our units"] option), "Role 3 Field Hospital")

    assert has_element?(
             view,
             ~s(optgroup[label="External providers"] option),
             "Regional Hospital"
           )
  end
end
