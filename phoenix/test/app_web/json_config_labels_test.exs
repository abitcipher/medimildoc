defmodule AppWeb.JsonConfigLabelsTest do
  @moduledoc """
  Labels that live in JSON config are translated at runtime, so
  `mix gettext.extract` only sees them through
  `AppWeb.CoreComponents.json_config_labels/0`. This keeps that list
  complete.
  """
  use ExUnit.Case, async: true

  alias AppWeb.CoreComponents

  test "every access profile label is marked for extraction" do
    for profile <- App.Access.profiles() do
      assert App.Access.profile_label(profile) in CoreComponents.json_config_labels()
    end
  end

  test "every navigation label is marked for extraction" do
    labels =
      Enum.flat_map(AppWeb.NavSchema.items(), fn item ->
        items = [item | item["children"] || []]

        Enum.flat_map(
          items,
          &Enum.reject([&1["label"], &1["description"]], fn text -> is_nil(text) end)
        )
      end)

    for label <- labels do
      assert label in CoreComponents.json_config_labels()
    end
  end

  test "every permission description is marked for extraction" do
    for permission <- App.Access.permissions() do
      assert App.Access.permission_description(permission) in CoreComponents.json_config_labels()
    end
  end
end
