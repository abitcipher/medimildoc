defmodule AppWeb.PersonRolePagesTest do
  @moduledoc "docs/design/events-and-person-login.md: what the minimal role person may open."
  use AppWeb.ConnCase, async: false

  import App.Fixtures

  setup do
    person = person_fixture()

    user =
      Ash.Seed.seed!(App.Accounts.User, %{
        email: "p@demo.test",
        role: :person,
        person_id: person.id,
        login_id: person.person_id
      })

    %{person: person, user: user}
  end

  test "the start page and My data open", %{conn: conn, user: user} do
    conn = authenticated_conn(conn, user)
    assert html_response(get(conn, ~p"/"), 200)
    assert html_response(get(conn, ~p"/me"), 200)
  end

  test "the person reads their own person, nobody else", %{person: person, user: user} do
    other = person_fixture(%{given_name: "Other"})
    ids = App.People.Person |> Ash.read!(actor: user) |> Enum.map(& &1.id)
    assert ids == [person.id]
    refute other.id in ids
  end
end
