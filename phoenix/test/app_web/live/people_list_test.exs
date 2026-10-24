defmodule AppWeb.PeopleListTest do
  use AppWeb.ConnCase, async: true

  import App.Fixtures
  import Phoenix.LiveViewTest

  require Ash.Query

  setup %{conn: conn} do
    unit = org_fixture("A Company")

    commander =
      person_fixture(%{given_name: "Chief", family_name: "Boss"})
      |> assign_fixture(unit, title: "Company Commander", grade: "OF-2")

    [%{position: command_post}] =
      App.People.Assignment
      |> Ash.Query.filter(person_id == ^commander.id)
      |> Ash.Query.load(:position)
      |> Ash.read!(authorize?: false)

    for i <- 1..25 do
      title = if rem(i, 5) == 0, do: "Combat Medic", else: "Rifleman"
      name = "Report#{String.pad_leading(to_string(i), 2, "0")}"

      person_fixture(%{given_name: name, family_name: "Soldier"})
      |> assign_fixture(unit, title: title, reports_to: command_post)
    end

    %{conn: authenticated_conn(conn, user_fixture(:hr)), commander: commander, unit: unit}
  end

  defp rows(view), do: view |> element("#direct-reports-rows") |> render()
  defp count(html), do: length(Regex.scan(~r/id="direct-reports-[0-9a-f-]{36}"/, html))

  test "direct reports load 20 at a time, then more on scrolling", %{
    conn: conn,
    commander: commander
  } do
    {:ok, view, _html} = live(conn, ~p"/people/#{commander.id}")

    assert count(rows(view)) == 20
    assert rows(view) =~ "Report01 Soldier"

    # The scroll trigger pushes "more" to the component (its phx-target).
    view |> with_target("#direct-reports") |> render_hook("more", %{})
    assert count(rows(view)) == 25
  end

  test "quick search by position, sort by name both ways", %{conn: conn, commander: commander} do
    {:ok, view, _html} = live(conn, ~p"/people/#{commander.id}")

    view |> element("#direct-reports-search") |> render_change(%{"q" => "medic"})
    html = rows(view)
    assert count(html) == 5
    assert html =~ "Combat Medic"
    refute html =~ "Rifleman"

    view |> element("#direct-reports-search") |> render_change(%{"q" => ""})
    view |> element(~s(#direct-reports button[phx-value-by="name"])) |> render_click()
    [first | _] = Regex.scan(~r/Report\d\d Soldier/, rows(view))
    assert first == ["Report25 Soldier"]
  end

  test "positions are grouped by unit, with short labels and who holds them",
       %{conn: conn, commander: commander} do
    {:ok, view, _html} = live(conn, ~p"/people/#{commander.id}")
    # The form opens from its control above the assignment list.
    html = view |> element("#assignments-header-actions-toolbar button") |> render_click()

    assert html =~ ~s(<optgroup label="A Company">)
    assert html =~ "Company Commander A.Co¦OF-2 · Chief Boss"
    # 20 riflemen and 5 medics share one post each (strength).
    assert html =~ "Rifleman A.Co · 20/20"
    assert html =~ "Combat Medic A.Co · 5/5"
  end

  test "the person header shows the position as a badge with details on hover",
       %{conn: conn, commander: commander} do
    {:ok, _view, html} = live(conn, ~p"/people/#{commander.id}")
    assert html =~ ~s(data-float-tip="Company Commander · A Company · grade OF-2")
  end
end
