defmodule AppWeb.DocumentsUiTest do
  @moduledoc "docs/design/documents-core.md: tasks, the document page, the person's Documents tab, the PDF."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  require Ash.Query

  alias App.Documents.Document

  setup %{conn: conn} do
    App.Access.put_admin_full_data_access_override(false)
    unit = org_fixture("A Company")
    patient = person_fixture(%{given_name: "Newcomer"}) |> assign_fixture(unit)

    %{
      conn: conn,
      patient: patient,
      hr: user_fixture(:hr),
      hr_head: user_fixture(:hr),
      member: unit_user_fixture(:viewer, [:clinician], unit),
      chair: unit_user_fixture(:viewer, [:clinician], unit)
    }
  end

  defp as(conn, user), do: authenticated_conn(conn, user)

  test "HR opens a referral from the person page, fills it in and sends it; the signatory signs",
       %{conn: conn, patient: patient, hr: hr, hr_head: hr_head} do
    {:ok, view, _html} = live(as(conn, hr), ~p"/people/#{patient.id}")

    assert {:error, {:live_redirect, %{to: "/documents/" <> id}}} =
             view
             |> form("#new-document-form", %{"type" => "medical_board_referral"})
             |> render_submit()

    {:ok, view, html} = live(as(conn, hr), "/documents/#{id}")
    assert html =~ "Referral to the medical board"
    assert html =~ "Draft"

    view
    |> form("#document-form", %{"data" => %{"reason" => "entry", "plannedDate" => "2026-10-05"}})
    |> render_submit()

    html = view |> form("#submit-form", %{"step_0" => hr_head.id}) |> render_submit()
    assert html =~ "Sent for approval"
    assert html =~ "In approval"

    {:ok, view, _html} = live(as(conn, hr_head), ~p"/tasks")
    assert view |> element("#to-decide") |> render() =~ "Referral to the medical board"

    {:ok, view, _html} = live(as(conn, hr_head), "/documents/#{id}")
    html = view |> form("#decision-form") |> render_submit(%{"decision" => "sign"})
    assert html =~ "Signed and registered"
    assert html =~ "1-нвлк"
    assert html =~ "/documents/#{id}/pdf"
  end

  test "the board sees the opened conclusion in Tasks; HR gets no PDF of it",
       %{conn: conn, patient: patient, hr: hr, hr_head: hr_head, member: member} do
    referral =
      Document
      |> Ash.Changeset.for_create(
        :create,
        %{type: :medical_board_referral, person_id: patient.id, data: %{"reason" => "entry"}},
        actor: hr
      )
      |> Ash.create!(actor: hr)
      |> Ash.load!(:data, authorize?: false)
      |> Ash.Changeset.for_update(:submit, %{assignees: [[hr_head.id]]}, actor: hr)
      |> Ash.update!(actor: hr)
      |> Ash.Changeset.for_update(:sign, %{}, actor: hr_head)
      |> Ash.update!(actor: hr_head)

    {:ok, view, _html} = live(as(conn, member), ~p"/tasks")
    assert view |> element("#team") |> render() =~ "Medical board conclusion"

    # The referral's PDF: HR may have it; someone without HR or medical
    # permissions may not (not even that it exists).
    assert redirected_to(get(as(conn, hr), "/documents/#{referral.id}/pdf"), 302) =~ "documents"

    assert get(as(conn, user_fixture(:viewer, [:ciso])), "/documents/#{referral.id}/pdf").status ==
             404
  end
end
