defmodule AppWeb.PersonFilesTest do
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  alias App.People.{Attachment, Files}

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "a small png">>
  @pdf "%PDF-1.7 a scan"

  setup %{conn: conn} do
    App.Access.put_admin_full_data_access_override(false)
    hr = user_fixture(:hr)
    %{conn: authenticated_conn(conn, hr), hr: hr, person: person_fixture()}
  end

  defp upload(view, name, content, form_params) do
    input =
      file_input(view, "#person-files-form", :file, [
        %{name: name, content: content, type: "application/octet-stream"}
      ])

    render_upload(input, name)

    view
    |> form("#person-files-form", form_params)
    |> render_submit()
  end

  test "upload a scan and a portrait; the portrait becomes the avatar",
       %{conn: conn, person: person} do
    {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")

    html = upload(view, "scan.pdf", @pdf, %{"purpose" => "document"})
    assert html =~ "Uploaded scan.pdf."
    assert html =~ "scan.pdf"

    upload(view, "me.png", @png, %{"purpose" => "photo"})
    assert render(view) =~ ~r/<img[^>]+src="https:\/\/files.test\/hrda-files\/f\//

    assert Ash.read!(Attachment, authorize?: false) |> Enum.map(& &1.purpose) |> Enum.sort() ==
             [:document, :photo]
  end

  test "a file that isn't what it claims is refused with a reason",
       %{conn: conn, person: person} do
    {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")
    html = upload(view, "notes.pdf", "<html>not a pdf</html>", %{"purpose" => "document"})
    assert html =~ "unsupported file type"
    assert Ash.read!(Attachment, authorize?: false) == []
  end

  test "a file on a record shows on the record card", %{conn: conn, person: person} do
    record_fixture(person, :contact_info)
    {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")

    [record] = Ash.read!(App.People.PersonRecord, authorize?: false)
    upload(view, "card.pdf", @pdf, %{"purpose" => "document", "record_id" => record.id})

    # The record list reloads asynchronously; a fresh page shows it for sure.
    {:ok, fresh, _html} = live(conn, ~p"/people/#{person.id}")
    html = render_async(fresh, 2_000)
    assert html =~ ~r/id="record-[^"]+".*?aria-label="Files".*?card\.pdf/s
  end

  test "/files/:id redirects to a signed link after the access check",
       %{conn: conn, hr: hr, person: person} do
    path = Path.join(System.tmp_dir!(), "f-#{System.unique_integer([:positive])}")
    File.write!(path, @pdf)

    {:ok, file} =
      Files.store(hr, path, %{
        person_id: person.id,
        purpose: :document,
        file_name: "a.pdf"
      })

    conn = get(conn, ~p"/files/#{file.id}?inline=1")
    assert redirected_to(conn, 302) =~ "https://files.test/hrda-files/#{file.object_key}?"
    assert [_log] = Ash.read!(App.Audit.AccessLog, authorize?: false)

    viewer_conn = authenticated_conn(build_conn(), user_fixture(:viewer))
    assert get(viewer_conn, ~p"/files/#{file.id}").status == 404
  end

  test "a viewer sees no upload form and can't delete", %{person: person, hr: hr} do
    path = Path.join(System.tmp_dir!(), "f-#{System.unique_integer([:positive])}")
    File.write!(path, @png)

    {:ok, _} =
      Files.store(hr, path, %{
        person_id: person.id,
        purpose: :photo,
        file_name: "p.png"
      })

    conn = authenticated_conn(build_conn(), user_fixture(:viewer))
    {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")

    refute has_element?(view, "#person-files-form")
    assert has_element?(view, "#person-files", "p.png")
    refute has_element?(view, ~s(#person-files button[phx-click="delete"]))
  end
end
