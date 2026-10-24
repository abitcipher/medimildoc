defmodule AppWeb.PersonLoginTest do
  @moduledoc "docs/design/events-and-person-login.md: signing in with a PersonID."
  use AppWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import App.Fixtures

  require Ash.Query

  alias App.Accounts.{PersonLogin, Throttle, User}
  alias App.Events.Event
  alias App.Notify.Notification
  alias App.People.PersonId

  setup do
    Throttle.clear()
    person = person_fixture()
    record_fixture(person, :contact_info, %{"contactType" => "email", "value" => "pat@demo.test"})
    %{person: person}
  end

  defp outcomes do
    Event
    |> Ash.Query.filter(type == "hrda.auth.first_sign_in.requested")
    |> Ash.Query.sort(occurred_at: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.data["outcome"])
  end

  defp link_token do
    [notification] =
      Notification |> Ash.Query.filter(event == :set_password) |> Ash.read!(authorize?: false)

    assert notification.channel == :email
    "/sign-in/person/password?token=" <> token = notification.path
    URI.decode_www_form(token)
  end

  test "a request makes a minimal account and e-mails a link; the answer never tells", %{
    person: person
  } do
    assert :ok = PersonLogin.request(String.downcase(person.person_id), "203.0.113.5")
    user = User |> Ash.Query.filter(person_id == ^person.id) |> Ash.read_one!(authorize?: false)
    assert %{role: :person, profiles: []} = user
    assert to_string(user.email) == "pat@demo.test"
    assert to_string(user.login_id) == person.person_id
    assert is_binary(link_token())

    assert :ok = PersonLogin.request("NO-SUCH-ID", "203.0.113.5")
    other = person_fixture(%{given_name: "Nocontact"})
    assert :ok = PersonLogin.request(other.person_id, "203.0.113.5")
    assert outcomes() == ["sent", "unknown", "no_contact"]

    assert [%{data: %{"method" => "person_id", "role" => "person"}}] =
             Event
             |> Ash.Query.filter(type == "hrda.accounts.user.created")
             |> Ash.read!(authorize?: false)
  end

  test "the minimal role sees nobody" do
    refute App.Access.can?(%User{role: :person, profiles: []}, "people.read")
  end

  test "an address already used by another account is a conflict, no link", %{person: person} do
    Ash.Seed.seed!(User, %{email: "pat@demo.test", role: :viewer})
    PersonLogin.request(person.person_id, "203.0.113.5")
    assert outcomes() == ["conflict"]
    assert Notification |> Ash.read!(authorize?: false) |> Enum.empty?()
  end

  test "switched off: nothing is sent", %{person: person} do
    App.Settings.put("auth.person_login", false, user_fixture(:admin))
    PersonLogin.request(person.person_id, "203.0.113.5")
    assert outcomes() == ["disabled"]
  end

  test "the link sets the password once and signs in; then PersonID + password works", %{
    conn: conn,
    person: person
  } do
    PersonLogin.request(person.person_id, "203.0.113.5")
    token = link_token()
    password = "correct horse battery"

    params = %{
      "user" => %{
        "reset_token" => token,
        "password" => password,
        "password_confirmation" => password
      }
    }

    conn1 = post(conn, ~p"/auth/user/password/reset", params)
    assert redirected_to(conn1) == ~p"/"
    assert get_session(conn1, "user_token")

    # Used once: the same link no longer works.
    conn2 = post(build_conn(), ~p"/auth/user/password/reset", params)
    assert redirected_to(conn2) == ~p"/sign-in/person/request"

    # As the app shows it: grouped, any case.
    ok =
      post(build_conn(), ~p"/auth/user/password/sign_in", %{
        "user" => %{
          "login_id" => person.person_id |> PersonId.format() |> String.downcase(),
          "password" => password
        }
      })

    assert redirected_to(ok) == ~p"/"
    assert get_session(ok, "user_token")

    types =
      Event |> Ash.read!(authorize?: false) |> Enum.map(& &1.type) |> MapSet.new()

    assert "hrda.auth.password.set" in types
    assert "hrda.auth.session.started" in types
  end

  test "five wrong passwords lock the PersonID; then even the right one fails", %{
    person: person
  } do
    PersonLogin.request(person.person_id, "198.51.100.1")
    password = "correct horse battery"

    post(build_conn(), ~p"/auth/user/password/reset", %{
      "user" => %{
        "reset_token" => link_token(),
        "password" => password,
        "password_confirmation" => password
      }
    })

    sign_in = fn password ->
      post(build_conn(), ~p"/auth/user/password/sign_in", %{
        "user" => %{"login_id" => person.person_id, "password" => password}
      })
    end

    for _ <- 1..5, do: sign_in.("wrong password!!")
    locked = sign_in.(password)
    assert redirected_to(locked) == ~p"/sign-in/person"
    refute get_session(locked, "user_token")
    assert Phoenix.Flash.get(locked.assigns.flash, :error) =~ "Too many"

    assert [%{data: %{"scope" => "login"}, severity: "critical"}] =
             Event
             |> Ash.Query.filter(type == "hrda.auth.sign_in.locked")
             |> Ash.read!(authorize?: false)
  end

  test "the pages", %{conn: conn, person: person} do
    {:ok, view, html} = live(conn, ~p"/sign-in")
    assert html =~ "/auth/user/google"
    assert has_element?(view, "#person-sign-in-form[action='/auth/user/password/sign_in']")

    {:ok, view, _} = live(conn, ~p"/sign-in/person/request")
    view |> form("#request-form", login_id: person.person_id) |> render_submit()
    assert has_element?(view, "#request-sent")

    {:ok, view, _} = live(conn, ~p"/sign-in/person/password?token=x")
    view |> form("#set-password-form", user: %{password: "short"}) |> render_change()
    assert has_element?(view, "#password-errors", "At least 12")
  end
end
