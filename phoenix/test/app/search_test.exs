defmodule App.SearchTest do
  @moduledoc "docs/design/search-timeline-notifications.md: global search."
  use App.DataCase, async: false

  import App.Fixtures

  require Ash.Query

  alias App.People.{PersonId, PersonIdentifier}

  setup do
    App.Access.put_admin_full_data_access_override(false)
    unit = org_fixture("A Company")
    elsewhere = org_fixture("Elsewhere")

    olena =
      person_fixture(%{given_name: "Olena", family_name: "Kovalenko"}) |> assign_fixture(unit)

    taras =
      person_fixture(%{given_name: "Taras", family_name: "Kovalchuk"})
      |> assign_fixture(elsewhere)

    %{
      unit: unit,
      olena: olena,
      taras: taras,
      hr: user_fixture(:hr),
      viewer: user_fixture(:viewer)
    }
  end

  defp names(people), do: people |> Enum.map(& &1.given_name) |> Enum.sort()

  test "people by name parts and Person ID; units by name", ctx do
    assert names(App.Search.run(ctx.hr, "koval").people) == ["Olena", "Taras"]
    assert names(App.Search.run(ctx.hr, "olena koval").people) == ["Olena"]
    assert names(App.Search.run(ctx.hr, PersonId.format(ctx.taras.person_id)).people) == ["Taras"]

    assert App.Search.run(ctx.hr, "compan").organizations |> Enum.map(& &1.name) == ["A Company"]
    assert App.Search.run(ctx.hr, "k").people == []
  end

  test "a national ID finds its person by exact match, logged; only for those who may read IDs",
       ctx do
    PersonIdentifier
    |> Ash.Changeset.for_create(
      :create,
      %{person_id: ctx.olena.id, id_type: :rnokpp, country: "UA", value: "TEST-1234567890"},
      actor: ctx.hr
    )
    |> Ash.create!(actor: ctx.hr)

    assert [%{id: id}] = App.Search.run(ctx.hr, "test 1234-567 890").identified
    assert id == ctx.olena.id

    assert [%{kind: "search:identifier", person_id: ^id}] =
             App.Audit.AccessLog
             |> Ash.Query.filter(kind == "search:identifier")
             |> Ash.read!(authorize?: false)

    # No partial matches, and nothing for a viewer who can't read IDs.
    assert App.Search.run(ctx.hr, "TEST-123456789").identified == []
    assert App.Search.run(ctx.viewer, "TEST-1234567890").identified == []
  end

  test "the hash follows the value", ctx do
    identifier =
      PersonIdentifier
      |> Ash.Changeset.for_create(
        :create,
        %{person_id: ctx.taras.id, id_type: :rnokpp, country: "UA", value: "TEST-11111"},
        actor: ctx.hr
      )
      |> Ash.create!(actor: ctx.hr)

    identifier
    |> Ash.Changeset.for_update(:update, %{value: "TEST-22222"}, actor: ctx.hr)
    |> Ash.update!(actor: ctx.hr)

    assert App.Search.run(ctx.hr, "TEST-11111").identified == []
    assert [%{given_name: "Taras"}] = App.Search.run(ctx.hr, "TEST-22222").identified
  end

  test "documents by number, only those the viewer may read", ctx do
    {:ok, request} =
      App.Documents.Document
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: :leave_request,
          person_id: ctx.olena.id,
          data: %{"leaveType" => "annual", "startDate" => "2026-11-02", "endDate" => "2026-11-03"}
        },
        actor: ctx.hr
      )
      |> Ash.create(actor: ctx.hr)

    App.Repo.query!("UPDATE documents SET number = '7-рап' WHERE id = $1", [
      Ecto.UUID.dump!(request.id)
    ])

    assert [%{id: id}] = App.Search.run(ctx.hr, "7-РАП").documents
    assert id == request.id
    assert App.Search.run(ctx.viewer, "7-рап").documents == []
  end
end
