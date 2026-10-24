defmodule App.OrgGraphTest do
  @moduledoc "docs/design/org-graph.md (ORG-GRAPH): the elements, pure."
  use ExUnit.Case, async: true

  alias App.OrgGraph
  alias App.OrgGraph.Overlay

  defp data do
    brigade = %{
      id: "b",
      name: "Brigade",
      kind: :brigade,
      parent_id: nil,
      country: "UA",
      locality: "Lviv"
    }

    company = %{
      id: "c",
      name: "A Company",
      kind: :company,
      parent_id: "b",
      country: nil,
      locality: nil
    }

    boss = %{id: "p1", title: "Commander", organization_id: "c", reports_to_id: nil, strength: 1}
    rifle = %{id: "p2", title: "Rifleman", organization_id: "c", reports_to_id: "p1", strength: 3}
    person = &%App.People.Person{id: &1, given_name: &2, family_name: "Test"}

    %{
      units: [brigade, company],
      posts: [boss, rifle],
      holders: [{"h1", "p1"}, {"h2", "p2"}],
      people: %{"h1" => person.("h1", "Anna"), "h2" => person.("h2", "Ivan")},
      providers: [
        %{
          id: "m1",
          name: "Aid post",
          provider_type: :role1,
          organization_id: "c",
          country: "UA",
          locality: "Lviv"
        },
        %{
          id: "m2",
          name: "Hospital",
          provider_type: :hospital,
          organization_id: nil,
          country: "UA",
          locality: " lviv "
        }
      ],
      deputies: [{"h1", "h2"}]
    }
  end

  defp ids(elements, type), do: for(%{data: %{type: ^type, id: id}} <- elements, do: id)

  defp edge(elements, type),
    do: for(%{data: %{type: ^type} = d} <- elements, do: {d.source, d.target})

  test "every layer: nodes, and edges pointing down the structure" do
    elements = OrgGraph.elements(data(), OrgGraph.layers())

    assert ids(elements, "unit") == ["u:b", "u:c"]
    assert edge(elements, "part_of") == [{"u:b", "u:c"}]
    assert edge(elements, "reports_to") == [{"p:p1", "p:p2"}]
    assert {"p:p2", "h:h2"} in edge(elements, "holds")
    # Ivan is Anna's deputy: from the deputy to the person.
    assert edge(elements, "deputy") == [{"h:h2", "h:h1"}]
    # One place for both providers (same locality, any case or spaces).
    assert ids(elements, "place") == ["l:UA:lviv"]
    assert edge(elements, "serves") == [{"c:m1", "u:c"}]

    rifle = Enum.find(elements, &(&1.data.id == "p:p2"))
    assert rifle.data.vacant == 2 and rifle.classes =~ "vacant"
    assert Enum.find(elements, &(&1.data.id == "p:p1")).classes =~ "leader"

    # The rifleman's post hangs under the commander's in the hierarchy.
    assert Enum.find(elements, &(&1.data.id == "post_in:u:c>p:p2")).classes =~ "via_boss"
    refute Enum.find(elements, &(&1.data.id == "post_in:u:c>p:p1")).classes =~ "via_boss"
  end

  test "hidden layers drop their nodes; people join their unit without posts" do
    elements = OrgGraph.elements(data(), ~w(units people))

    assert ids(elements, "post") == []
    assert ids(elements, "provider") == []
    assert Enum.sort(edge(elements, "holds")) == [{"u:c", "h:h1"}, {"u:c", "h:h2"}]
    assert edge(elements, "deputy") == []
  end

  test "edges never point at a node that isn't there" do
    for layers <- [~w(posts people), ~w(units providers), ~w(people deputies), OrgGraph.layers()] do
      elements = OrgGraph.elements(data(), layers)

      nodes =
        MapSet.new(for %{data: %{id: id} = d} <- elements, not Map.has_key?(d, :source), do: id)

      for %{data: %{source: source, target: target}} <- elements do
        assert source in nodes and target in nodes, inspect({layers, source, target})
      end
    end
  end

  test "units in a place share it with providers; a unit without one is where its parent is (ORG-GRAPH.1)" do
    elements = OrgGraph.elements(data(), OrgGraph.layers())
    assert {"u:b", "l:UA:lviv"} in edge(elements, "located_in")
    refute Enum.any?(edge(elements, "located_in"), &(elem(&1, 0) == "u:c"))
    assert ids(elements, "place") == ["l:UA:lviv"]

    assert {%{id: "b"}, "Lviv, UA"} = OrgGraph.unit_place("c", data().units)
    assert OrgGraph.unit_place("x", data().units) == nil
  end

  test "relations: counted edges between people, referrals, dependants (ORG-GRAPH.4)" do
    data =
      Map.put(data(), :relations, %{
        duty: [{"h1", "h2", 3}],
        approvals: [{"h1", "h2", 1}],
        referrals: [{"h2", "m2"}, {"h2", "gone"}],
        family: [%{id: "r1", person_id: "h1", name: "Kid", relationship: "child"}]
      })

    elements = OrgGraph.elements(data, OrgGraph.layers())
    assert [%{data: %{count: 3}}] = Enum.filter(elements, &(&1.data.type == "duty_with"))
    assert edge(elements, "approves") == [{"h:h1", "h:h2"}]
    # A provider not on the graph: no edge.
    assert edge(elements, "referred") == [{"h:h2", "c:m2"}]
    assert ids(elements, "relative") == ["d:r1"]
    assert edge(elements, "family") == [{"h:h1", "d:r1"}]

    # Off by default with their layer.
    plain = OrgGraph.elements(data, ~w(units posts people))
    refute Enum.any?(plain, &(&1.data.type in ~w(duty_with approves referred family relative)))
  end

  test "overlays: a status class on people, vacant places per unit (ORG-GRAPH.6)" do
    data = data()
    elements = OrgGraph.elements(data, OrgGraph.layers())

    marked =
      OrgGraph.overlay(elements, "readiness", %{people: %{"h1" => "downgraded"}, units: %{}})

    classes = Map.new(marked, &{&1.data.id, &1.classes})
    assert classes["h:h1"] =~ "ov-downgraded"
    assert classes["h:h2"] =~ "ov-none"

    away = OrgGraph.overlay(elements, "absence", %{people: %{"h2" => "sick"}, units: %{}})
    assert Enum.find(away, &(&1.data.id == "h:h2")).classes =~ "ov-away ov-sick"

    # The rifleman post (strength 3, one holder) leaves 2 vacant places in
    # the company, counted in the brigade too.
    vacancies = Overlay.vacancies(data)
    assert vacancies == %{"b" => 2, "c" => 2}
    shown = OrgGraph.overlay(elements, "vacancies", %{people: %{}, units: vacancies})

    assert %{data: %{vacant_total: 2}, classes: classes} =
             Enum.find(shown, &(&1.data.id == "u:c"))

    assert classes =~ "has-vacancies"
    assert OrgGraph.overlay(elements, nil, %{}) == elements
  end

  test "progressive: only opened units' contents are sent; others say how much waits (ORG-GRAPH.7)" do
    data = data()
    full = OrgGraph.elements(data, OrgGraph.layers())

    closed = OrgGraph.subgraph(full, data, MapSet.new(["b"]))
    assert ids(closed, "unit") == ["u:b", "u:c"]
    assert ids(closed, "post") == [] and ids(closed, "person") == []
    # Two posts and two holders wait in the company.
    assert %{data: %{remote: 4}, classes: classes} = Enum.find(closed, &(&1.data.id == "u:c"))
    assert classes =~ "remote"
    # No edge to anything not sent.
    sent = MapSet.new(closed, & &1.data.id)
    for %{data: %{source: s, target: t}} <- closed, do: assert(s in sent and t in sent)

    opened = OrgGraph.subgraph(full, data, MapSet.new(["b", "c"]))
    assert ids(opened, "post") == ["p:p1", "p:p2"]
    assert ids(opened, "person") == ["h:h1", "h:h2"]
    refute Enum.find(opened, &(&1.data.id == "u:c")).data[:remote]
  end
end
