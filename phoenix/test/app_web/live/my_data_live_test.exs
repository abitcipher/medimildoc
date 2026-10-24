defmodule AppWeb.MyDataLiveTest do
  @moduledoc "docs/design/events-and-person-login.md: a person's own data."
  use AppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import App.Fixtures

  require Ash.Query

  alias App.Accounts.{Throttle, User}
  alias App.Events.Event

  @password "correct horse battery"

  setup do
    Throttle.clear()
    person = person_fixture(%{given_name: "Olena", family_name: "Mydata"})
    record_fixture(person, :medical_condition)

    user =
      Ash.Seed.seed!(User, %{
        email: "olena@demo.test",
        role: :person,
        person_id: person.id,
        login_id: person.person_id,
        hashed_password: Bcrypt.hash_pwd_salt(@password)
      })

    %{person: person, user: user}
  end

  defp events(type),
    do: Event |> Ash.Query.filter(type == ^type) |> Ash.read!(authorize?: false)

  test "the person sees everything about them; a sensitive record is in the access log", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _} = live(authenticated_conn(conn, user), ~p"/me")
    assert has_element?(view, "#my-data-card", "Olena")
    assert has_element?(view, "#confirm-form")
    refute has_element?(view, "#download-links")

    assert [_ | _] =
             App.Audit.AccessLog
             |> Ash.Query.filter(actor_id == ^user.id)
             |> Ash.read!(authorize?: false)
  end

  test "downloads need the password; each download is an event", %{
    conn: conn,
    user: user,
    person: person
  } do
    conn = authenticated_conn(conn, user)
    {:ok, view, _} = live(conn, ~p"/me")

    view |> form("#confirm-form", password: "wrong one") |> render_submit()
    assert has_element?(view, "#confirm-form", "Wrong password")
    assert [_] = events("hrda.auth.confirmation.failed")

    view |> form("#confirm-form", password: @password) |> render_submit()
    assert has_element?(view, "#download-links")

    href = fn format ->
      view
      |> element("#download-#{format}")
      |> render()
      |> then(&Regex.run(~r/href="([^"]+)"/, &1))
      |> List.last()
      |> String.replace("&amp;", "&")
    end

    md = get(conn, href.("markdown"))
    assert response_content_type(md, :markdown) =~ "text/markdown"
    assert md.resp_body =~ "# Olena"

    json = get(conn, href.("json"))

    assert %{"person" => %{"person_id" => pid}, "records" => [_ | _]} =
             Jason.decode!(json.resp_body)

    assert pid == person.person_id

    pdf = get(conn, href.("pdf"))
    assert "%PDF" <> _ = pdf.resp_body

    assert length(events("hrda.privacy.export.downloaded")) == 3

    # Someone else's session can't use the link.
    other = authenticated_conn(build_conn(), user_fixture(:hr))
    assert redirected_to(get(other, href.("json"))) == ~p"/me"
  end

  test "an account not linked to a person", %{conn: conn} do
    {:ok, view, _} = live(authenticated_conn(conn, user_fixture(:hr)), ~p"/me")
    assert has_element?(view, "#not-linked")
  end

  test "markdown of card rows" do
    assert AppWeb.MyData.markdown([
             {:title, "A B", ""},
             {:section, "Records", ""},
             {:record, "01.01.2026", ""},
             {:field, "Status", "fit"}
           ]) == "# A B\n\n## Records\n\n### 01.01.2026\n- **Status:** fit\n"
  end

  test "a sign-in within five minutes counts as confirmed", %{conn: conn, user: user} do
    conn =
      conn
      |> authenticated_conn(user)
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_session(:signed_in_at, System.system_time(:second) - 60)

    {:ok, view, _} = live(conn, ~p"/me")
    assert has_element?(view, "#download-links")
  end
end
