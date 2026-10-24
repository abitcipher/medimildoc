defmodule AppWeb.CorrespondenceUiTest do
  @moduledoc "docs/design/correspondence.md: registering a letter, instructions, the reply — on screen."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  alias App.Documents.Document

  setup do
    App.Access.put_admin_full_data_access_override(false)
    company = org_fixture("A Company", org_fixture("1st Brigade"))

    %{
      company: company,
      records: user_fixture(:viewer, [:records_officer]),
      commander: unit_user_fixture(:viewer, [:commander], company),
      hr: Ash.Seed.update!(user_fixture(:hr), %{name: "Olena HR"})
    }
  end

  test "register a letter with its scan, give an instruction, the executor writes the reply",
       ctx do
    conn = authenticated_conn(ctx.conn, ctx.records)

    {:ok, registers, _} = live(conn, ~p"/registers")

    {:error, {:live_redirect, %{to: path}}} =
      registers |> element("#new-incoming") |> render_click()

    {:ok, page, _} = live(conn, path)

    page
    |> form("#document-form", %{
      "data" => %{
        "sender" => "Regional administration",
        "receivedOn" => Date.to_iso8601(Date.utc_today()),
        "summary" => "A request",
        "unit" => ctx.company.id
      }
    })
    |> render_submit()

    scan =
      file_input(page, "#document-files-upload", :file, [
        %{name: "scan.pdf", content: "%PDF-1.4\n% scan\n", type: "application/pdf"}
      ])

    render_upload(scan, "scan.pdf")
    page |> form("#document-files-upload") |> render_submit()
    assert has_element?(page, "#document-files", "scan.pdf")

    page |> element("#register-button") |> render_click()
    html = render(page)
    assert html =~ "-вх"
    # Registered, not signed.
    assert html =~ "Registered by"
    refute html =~ "Signed by"

    letter_id = path |> String.split("/") |> List.last()

    # The commander gives an instruction.
    {:ok, page, _} = live(authenticated_conn(build_conn(), ctx.commander), path)
    page |> element("#give-instruction") |> render_click()

    page
    |> form("#instruction-form", %{
      "form" => %{"text" => "Prepare a reply", "executor_id" => ctx.hr.id}
    })
    |> render_submit()

    assert has_element?(page, "#instructions", "Olena HR")

    # The executor: in their tasks, writes the reply from the letter.
    hr_conn = authenticated_conn(build_conn(), ctx.hr)
    {:ok, tasks, _} = live(hr_conn, ~p"/tasks")
    assert has_element?(tasks, "#instructions", "Prepare a reply")

    {:ok, page, _} = live(hr_conn, path)

    {:error, {:live_redirect, %{to: reply_path}}} =
      page |> element("#reply-button") |> render_click()

    reply_id = reply_path |> String.split("/") |> List.last()
    reply = Ash.get!(Document, reply_id, authorize?: false)
    assert reply.type == :outgoing_letter and reply.basis_id == letter_id
  end
end
