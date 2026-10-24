defmodule App.Accounts.AccessRequestTest do
  @moduledoc "Second approval (docs/design/access-control-phase2.md)."
  use App.DataCase, async: true

  alias App.Access
  alias App.Accounts.{AccessRequest, User}

  setup do
    %{
      maker: user_fixture(:admin),
      checker: user_fixture(:admin),
      target: user_fixture(:viewer, [:line_commander])
    }
  end

  defp request(actor, user, attrs) do
    AccessRequest
    |> Ash.Changeset.for_create(:request, Map.put(attrs, :user_id, user.id), actor: actor)
    |> Ash.create!()
  end

  defp decide(request, action, actor),
    do: request |> Ash.Changeset.for_update(action, %{}, actor: actor) |> Ash.update()

  test "only additions of sensitive profiles and promotion to admin need approval", %{
    target: target
  } do
    assert Access.needs_approval(target, :viewer, [:line_commander, :registrar]) ==
             %{role: nil, profiles: []}

    assert Access.needs_approval(target, :admin, [:clinician, :line_commander]) ==
             %{role: :admin, profiles: [:clinician]}

    assert Access.needs_approval(target, :viewer, []) == %{role: nil, profiles: []}
  end

  test "another administrator approves, and the change is applied", %{
    maker: maker,
    checker: checker,
    target: target
  } do
    req = request(maker, target, %{profiles: [:clinician], role: :hr})

    assert {:error, %Ash.Error.Forbidden{}} = decide(req, :approve, maker)
    assert {:ok, %{status: :approved}} = decide(req, :approve, checker)

    user = Ash.get!(User, target.id, authorize?: false)
    assert user.role == :hr
    assert Enum.sort(user.profiles) == [:clinician, :line_commander]
  end

  test "a rejected request changes nothing and can't be decided again", %{
    maker: maker,
    checker: checker,
    target: target
  } do
    req = request(maker, target, %{profiles: [:ciso]})
    assert {:ok, rejected} = decide(req, :reject, checker)
    assert Ash.get!(User, target.id, authorize?: false).profiles == [:line_commander]

    assert {:error, _} = decide(rejected, :approve, checker)
  end

  test "requests need users.manage", %{target: target} do
    assert_raise Ash.Error.Forbidden, fn ->
      request(user_fixture(:hr), target, %{profiles: [:ciso]})
    end
  end
end
