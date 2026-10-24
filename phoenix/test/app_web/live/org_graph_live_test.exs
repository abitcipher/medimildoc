defmodule AppWeb.OrgGraphLiveTest do
  @moduledoc "docs/design/org-graph.md (ORG-GRAPH): the page."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  setup do
    brigade = org_fixture("Graph Brigade")
    company = org_fixture("Graph Company", brigade)
    person = person_fixture(%{given_name: "Olena", family_name: "Graphova"})
    assign_fixture(person, company, title: "Company Commander")
    %{brigade: brigade, company: company, person: person, hr: user_fixture(:hr)}
  end

  test "the graph gets its elements; a click shows the details", ctx do
    {:ok, view, _} =
      live(authenticated_conn(ctx.conn, ctx.hr), ~p"/org-graph?unit=#{ctx.brigade.id}")

    reply = render_hook(view, "ready", %{})
    assert reply =~ "Graph Company"

    assert_reply(view, %{elements: elements, layout: "network"})
    ids = MapSet.new(elements, & &1.data.id)
    assert "u:#{ctx.company.id}" in ids
    assert "h:#{ctx.person.id}" in ids

    render_hook(view, "select", %{"id" => "h:#{ctx.person.id}"})
    assert has_element?(view, "#graph-details", "Olena")
    assert has_element?(view, "#graph-details a[href='/people/#{ctx.person.id}']")
    assert has_element?(view, "#graph-details", "Company Commander")

    render_hook(view, "select", %{"id" => "u:#{ctx.company.id}"})
    assert has_element?(view, "#graph-details", "Graph Brigade")

    render_hook(view, "select", %{})
    refute has_element?(view, "#graph-details")

    # ORG-GRAPH.8: export what is shown, built in the browser.
    for action <- ~w(png svg graphml csv-nodes csv-edges),
        do: assert(has_element?(view, "#graph-export [data-graph-action='#{action}']"))
  end

  test "search counts matches; the view form patches the URL", ctx do
    {:ok, view, _} =
      live(authenticated_conn(ctx.conn, ctx.hr), ~p"/org-graph?unit=#{ctx.brigade.id}")

    view |> form("#graph-search", q: "graph") |> render_change()
    # Two units and one person.
    assert has_element?(view, "#graph-matches", "3")
    assert_push_event(view, "graph:highlight", %{ids: [_, _, _]})

    view
    |> form("#graph-view", %{
      unit: ctx.company.id,
      layout: "hierarchy",
      layer_units: "true",
      layer_posts: "false",
      layer_people: "true",
      layer_reporting: "false",
      layer_deputies: "false"
    })
    |> render_change()

    query = view |> assert_patch() |> URI.parse() |> Map.get(:query) |> URI.decode_query()

    assert query == %{
             "unit" => ctx.company.id,
             "layout" => "hierarchy",
             "layers" => "units,people"
           }

    assert_push_event(view, "graph:data", %{layout: "hierarchy", elements: elements})
    refute Enum.any?(elements, &(&1.data.type == "post"))
  end

  test "grouping is in the URL; a unit can be collapsed from its details (ORG-GRAPH.3)", ctx do
    {:ok, view, _} =
      live(authenticated_conn(ctx.conn, ctx.hr), ~p"/org-graph?unit=#{ctx.brigade.id}&group=1")

    render_hook(view, "ready", %{})
    assert_reply(view, %{group: true})
    assert has_element?(view, "#graph-group[checked]")

    view
    |> form("#graph-view", %{"layout" => "circles", "group" => "false"})
    |> render_change()

    assert_patch(view)
    assert_push_event(view, "graph:layout", %{layout: "circles", group: false})

    render_hook(view, "select", %{"id" => "u:#{ctx.company.id}"})
    view |> element("#graph-toggle-unit") |> render_click()
    assert_push_event(view, "graph:toggle", %{id: id})
    assert id == "u:#{ctx.company.id}"
  end

  test "as of a date, and who joined or left since another (ORG-GRAPH.5)", ctx do
    post =
      App.People.Position
      |> Ash.Changeset.for_create(:create, %{title: "Signaller", organization_id: ctx.company.id},
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    old = person_fixture(%{given_name: "Oleh", family_name: "Old"})
    new = person_fixture(%{given_name: "Nina", family_name: "New"})

    for {person, from, to} <- [{old, ~D[2026-01-01], ~D[2026-05-31]}, {new, ~D[2026-06-01], nil}] do
      Ash.Seed.seed!(App.People.Assignment, %{
        person_id: person.id,
        position_id: post.id,
        starts_on: from,
        ends_on: to
      })
    end

    conn = authenticated_conn(ctx.conn, ctx.hr)
    {:ok, view, _} = live(conn, ~p"/org-graph?unit=#{ctx.brigade.id}&on=2026-03-01")
    render_hook(view, "ready", %{})
    assert_reply(view, %{elements: elements})
    ids = MapSet.new(elements, & &1.data.id)
    assert "h:#{old.id}" in ids
    refute "h:#{new.id}" in ids

    {:ok, view, _} =
      live(conn, ~p"/org-graph?unit=#{ctx.brigade.id}&on=2026-07-01&compare=2026-03-01")

    render_hook(view, "ready", %{})
    assert_reply(view, %{elements: elements})
    by_id = Map.new(elements, &{&1.data.id, &1})
    assert by_id["h:#{new.id}"].classes =~ "joined"
    assert by_id["h:#{old.id}"].classes =~ "left"
    assert has_element?(view, "#graph-changes", "1 joined")
    assert has_element?(view, "#graph-changes", "1 left")
  end

  test "overlays: readiness and who is away on the date (ORG-GRAPH.6)", ctx do
    record_fixture(ctx.person, :fitness_for_duty, %{"status" => "downgraded"})
    today = Date.utc_today()

    record_fixture(ctx.person, :leave, %{
      "leaveType" => "annual",
      "startDate" => Date.to_iso8601(Date.add(today, -1)),
      "endDate" => Date.to_iso8601(Date.add(today, 5)),
      "days" => 7,
      "basis" => "12-ос"
    })

    conn = authenticated_conn(ctx.conn, user_fixture(:admin))
    {:ok, view, _} = live(conn, ~p"/org-graph?unit=#{ctx.brigade.id}&overlay=readiness")
    render_hook(view, "ready", %{})
    assert_reply(view, %{elements: elements})
    assert Enum.find(elements, &(&1.data.id == "h:#{ctx.person.id}")).classes =~ "ov-downgraded"
    assert has_element?(view, "#graph-legend")

    {:ok, view, _} = live(conn, ~p"/org-graph?unit=#{ctx.brigade.id}&overlay=absence")

    render_hook(view, "ready", %{})
    assert_reply(view, %{elements: elements})
    assert Enum.find(elements, &(&1.data.id == "h:#{ctx.person.id}")).classes =~ "ov-away"
  end

  test "progressive: a unit's contents come when it is opened, or found (ORG-GRAPH.7)", ctx do
    conn = authenticated_conn(ctx.conn, ctx.hr)
    {:ok, view, _} = live(conn, ~p"/org-graph?unit=#{ctx.brigade.id}&progressive=1")

    render_hook(view, "ready", %{})
    assert_reply(view, %{elements: elements})
    ids = MapSet.new(elements, & &1.data.id)
    assert "u:#{ctx.company.id}" in ids
    refute "h:#{ctx.person.id}" in ids

    render_hook(view, "select", %{"id" => "u:#{ctx.company.id}"})
    assert has_element?(view, "#graph-expand-unit")
    view |> element("#graph-expand-unit") |> render_click()
    assert_push_event(view, "graph:merge", %{elements: merged})
    assert "h:#{ctx.person.id}" in MapSet.new(merged, & &1.data.id)

    # Search opens the units of what it finds.
    {:ok, view, _} = live(conn, ~p"/org-graph?unit=#{ctx.brigade.id}&progressive=1")
    view |> form("#graph-search", q: "Graphova") |> render_change()
    assert_push_event(view, "graph:merge", %{elements: merged})
    assert "h:#{ctx.person.id}" in MapSet.new(merged, & &1.data.id)
    assert_push_event(view, "graph:highlight", %{ids: [_]})
  end
end
