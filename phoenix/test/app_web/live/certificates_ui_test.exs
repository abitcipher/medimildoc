defmodule AppWeb.CertificatesUiTest do
  @moduledoc "docs/design/certificates.md: a person requests a certificate; HR sees the preview and signs."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    App.Access.put_admin_full_data_access_override(false)
    company = org_fixture("A Company", org_fixture("1st Brigade"))

    %{
      conn: conn,
      requester: unit_user_fixture(:viewer, [], company, nil),
      hr: user_fixture(:hr)
    }
  end

  defp as(conn, user), do: authenticated_conn(conn, user)

  test "the person requests a pay certificate; the page previews it; HR signs it",
       %{conn: conn, requester: requester, hr: hr} do
    record_fixture(%{id: requester.person_id}, :compensation, %{
      "amount" => 30_000,
      "currency" => "UAH",
      "effectiveDate" => "2025-01-01",
      "reason" => "base_pay"
    })

    {:ok, view, _html} = live(as(conn, requester), ~p"/tasks")

    assert {:error, {:live_redirect, %{to: "/documents/" <> id}}} =
             view
             |> form("#new-request-form", %{"type" => "certificate_pay"})
             |> render_submit()

    {:ok, view, html} = live(as(conn, requester), "/documents/#{id}")
    assert html =~ "Pay certificate"
    refute has_element?(view, "#certificate-sections")

    data = %{"periodFrom" => "2026-01-01", "periodTo" => "2026-02-28", "presentTo" => "Bank"}
    html = view |> form("#document-form", %{"data" => data}) |> render_change()
    assert html =~ "The certificate would state today"
    assert html =~ "60 000.00 UAH"

    view |> form("#document-form", %{"data" => data}) |> render_submit()
    view |> form("#submit-form", %{"step_0" => hr.id}) |> render_submit()

    {:ok, view, _html} = live(as(conn, hr), "/documents/#{id}")
    html = view |> form("#decision-form") |> render_submit(%{"decision" => "sign"})

    assert html =~ "The certificate states"
    assert html =~ "1-дов"
    assert view |> element("#certificate-sections") |> render() =~ "60 000.00 UAH"
  end
end
