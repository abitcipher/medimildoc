defmodule App.Duty.ShiftTest do
  @moduledoc "docs/design/duty-roster.md: who plans and reads duties."
  use App.DataCase, async: false

  import App.Fixtures

  alias App.Duty.Shift

  setup do
    App.Access.put_admin_full_data_access_override(false)
    company = org_fixture("A Company", org_fixture("1st Brigade"))

    %{
      company: company,
      soldier: unit_user_fixture(:viewer, [], company, nil),
      commander: unit_user_fixture(:viewer, [:commander], company),
      other_commander: unit_user_fixture(:viewer, [:commander], org_fixture("B Company")),
      hr: user_fixture(:hr)
    }
  end

  defp plan(ctx, actor, attrs \\ %{}) do
    Shift
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          date: ~D[2026-11-02],
          duty_type: "duty_officer",
          person_id: ctx.soldier.person_id,
          organization_id: ctx.company.id
        },
        attrs
      ),
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  test "a commander plans their unit; HR anywhere; not another unit's commander", ctx do
    assert {:ok, shift} = plan(ctx, ctx.commander)
    assert shift.created_by_email == to_string(ctx.commander.email)

    assert {:error, %Ash.Error.Forbidden{}} =
             plan(ctx, ctx.other_commander, %{date: ~D[2026-11-04]})

    assert {:ok, _} = plan(ctx, ctx.hr, %{date: ~D[2026-11-06]})
  end

  test "one duty a day; known types only", ctx do
    assert {:ok, _} = plan(ctx, ctx.hr)
    assert {:error, _} = plan(ctx, ctx.hr, %{duty_type: "orderly"})
    assert {:error, _} = plan(ctx, ctx.hr, %{date: ~D[2026-11-08], duty_type: "astronaut"})
  end

  test "the person sees their duties; another unit's commander doesn't", ctx do
    {:ok, _} = plan(ctx, ctx.hr)
    assert [_] = Ash.read!(Shift, actor: ctx.soldier)
    assert [_] = Ash.read!(Shift, actor: ctx.commander)
    assert [] = Ash.read!(Shift, actor: ctx.other_commander)
  end
end
