defmodule AppWeb.ApiAccessUiTest do
  @moduledoc "docs/design/fhir-api.md: tokens are created on /api-access and shown once."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  alias App.Api.Tokens

  test "an admin creates a service client; the token is shown once and works", %{conn: conn} do
    admin = user_fixture(:admin)
    {:ok, view, _html} = live(authenticated_conn(conn, admin), ~p"/api-access")
    refute has_element?(view, "#personal-tokens")

    html =
      view
      |> form("#create-service", %{"name" => "export", "profiles" => ["health_data_reader"]})
      |> render_submit()

    [token] = Regex.run(~r/hrda_[A-Za-z0-9_-]{20,}/, html)

    assert {:ok, %{api: :service, profiles: [:health_data_reader]}} =
             Tokens.actor_for_token(token)

    view |> element("button", "Done") |> render_click()
    refute render(view) =~ token

    view |> element("#service-clients button", "Revoke") |> render_click()
    assert Tokens.actor_for_token(token) == :error
  end

  test "a person creates their own token", %{conn: conn} do
    unit = org_fixture("A Company")
    user = unit_user_fixture(:viewer, [], unit, nil)
    {:ok, view, _html} = live(authenticated_conn(conn, user), ~p"/api-access")
    refute has_element?(view, "#service-clients")

    html =
      view |> form("#create-personal", %{"name" => "phone", "days" => "30"}) |> render_submit()

    [token] = Regex.run(~r/hrda_[A-Za-z0-9_-]{20,}/, html)
    assert {:ok, %{api: :personal, own_person_id: own}} = Tokens.actor_for_token(token)
    assert own == user.person_id
  end

  test "an admin registers an external system and gets its client id", %{conn: conn} do
    admin = user_fixture(:admin)

    hospital =
      App.Care.Provider
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Regional Hospital", agreement_ref: "DSA-1"},
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    {_, public} = {:ec, "P-384"} |> JOSE.JWK.generate_key() |> JOSE.JWK.to_public_map()
    {:ok, view, _html} = live(authenticated_conn(conn, admin), ~p"/api-access")

    html =
      view
      |> form("#create-external", %{
        "name" => "hospital-ehr",
        "provider_id" => hospital.id,
        "scopes" => ["Patient", "Condition"],
        "jwks" => Jason.encode!(%{"keys" => [public]})
      })
      |> render_submit()

    [client] = Ash.read!(App.Api.Client, authorize?: false)
    assert client.kind == :external and client.scopes == ["Patient", "Condition"]
    assert html =~ client.id
    assert html =~ "/fhir/auth/token"

    html =
      view
      |> form("#create-external", %{"name" => "bad", "provider_id" => hospital.id, "jwks" => "{"})
      |> render_submit()

    assert html =~ "not valid JSON"
  end
end
