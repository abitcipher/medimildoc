defmodule AppWeb.NavSchema do
  @moduledoc """
  Loads the app's primary navigation from `priv/nav_schema.json` — a
  declarative, hierarchical JSON structure, not
  hand-written HEEx `<:item>` slots one call site at a time. This is
  deliberately NOT a JSON Schema document (there's no data here to
  validate against a schema — a nav tree isn't a form) — it's plain
  declarative JSON, the same spirit as `App.People.PersonRecordSchema.
  @kinds`/`AppWeb.FormSchemas.@ids`: config data lives in a JSON file,
  not scattered across Elixir modules.

  Each item: `id`, `label` (English string — also the Gettext msgid, see
  below), `icon` (a Heroicons name, same convention as everywhere else in
  this app), `path` (nil for a parent-only grouping item), `permission` (nil =
  any authenticated user; otherwise an `App.Access` permission name, or a
  list of them — any one is enough), and
  optional `children` (one level deep — this app's route tree doesn't
  need more, and `visible_items/2` recurses generically if it ever does).

  Adding a nav entry is "add an object to the JSON file", the same
  mechanical growth story as the rest of this app's declarative config —
  no new Elixir code, no template edit.
  """

  @nav_schema_path Application.app_dir(:app, "priv/nav_schema.json")
  @external_resource @nav_schema_path

  @raw @nav_schema_path |> File.read!() |> Jason.decode!()

  @doc """
  The full item tree, unfiltered — every item and its children as loaded
  from `priv/nav_schema.json`, string keys throughout (`"id"`, `"label"`,
  `"icon"`, `"path"`, `"permission"`, `"children"`).
  """
  @spec items() :: [map()]
  def items, do: @raw["items"]

  @doc """
  The item tree filtered to what `actor` (an `App.Accounts.User` or
  `nil`) may see — an item with `"permission" => nil` is visible to any
  authenticated actor; otherwise the actor must hold that permission
  (`App.Access.can?/2`). A parent with `"permission" => nil` but all children filtered away
  is dropped too (no point showing an empty group), unless the parent
  itself also has a `"path"` (then it's a real link, not just a group
  label, and survives on its own).
  """
  @spec visible_items(App.Accounts.User.t() | nil) :: [map()]
  def visible_items(actor) do
    items()
    |> Enum.map(&filter_item(&1, actor))
    |> Enum.filter(& &1)
  end

  defp filter_item(item, actor) do
    if visible?(item, actor), do: filter_visible_item(item, actor), else: nil
  end

  defp filter_visible_item(%{"children" => nil} = item, _actor), do: item

  defp filter_visible_item(%{"children" => children} = item, actor) do
    visible_children = children |> Enum.map(&filter_item(&1, actor)) |> Enum.filter(& &1)

    cond do
      visible_children != [] -> Map.put(item, "children", visible_children)
      item["path"] -> Map.put(item, "children", [])
      true -> nil
    end
  end

  defp filter_visible_item(item, _actor), do: item

  defp visible?(%{"permission" => nil}, actor), do: !is_nil(actor)

  defp visible?(%{"permission" => permissions}, actor) when is_list(permissions),
    do: Enum.any?(permissions, &App.Access.can?(actor, &1))

  defp visible?(%{"permission" => permission}, actor), do: App.Access.can?(actor, permission)

  @doc """
  Translates an item's `"label"` through `AppWeb.Gettext` — a *runtime*
  lookup (`Gettext.gettext/2`, not the `gettext/1` macro import), since
  the label is a JSON-loaded string, not a compile-time literal
  `mix gettext.extract` could see. This still finds a translation as
  long as the `.po` catalog has a matching msgid: most labels here
  ("People", "Organizations", "Positions", "Users", "Change conflicts")
  already exist as extracted msgids from `home.html.heex`'s own nav, so
  they're translated for free; a genuinely new label ("Admin") needs its
  own `msgid`/`msgstr` pair added by hand to `priv/gettext/*/LC_MESSAGES/
  default.po` (`mix gettext.extract` can't discover a JSON-sourced string
  on its own) — done once, in the same commit that adds this module.
  """
  @spec label(map()) :: String.t()
  def label(item), do: Gettext.gettext(AppWeb.Gettext, item["label"])
end
