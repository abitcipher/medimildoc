defmodule AppWeb.SidebarLayout do
  @moduledoc """
  What the Google Sheets sidebar (`AppWeb.SheetsLive`) may show
  (docs/design/sheets-ui.md §Sidebar layout): its tabs, the tool icons of
  each tab (in the top row, for the active tab), and optional sections.
  An item is shown when the user holds its permission (if it names one),
  its tab is shown, and the admin hasn't hidden it for the user's role or
  for one of the user's access profiles on the Sidebar layout page
  (`AppWeb.SidebarLayoutLive`, SHEETS-UI.19; stored in `App.Settings`
  `sheets.sidebar_hidden` as `%{audience => [item id]}`, the audience
  being a role, `"hr"`, or a profile, `"profile:nurse"`).

  Hiding is presentation only: every action still checks its permission.
  """
  use Gettext, backend: AppWeb.Gettext

  @type item :: %{
          id: String.t(),
          kind: :tab | :tool | :section,
          tab: String.t(),
          label: String.t(),
          icon: String.t(),
          permission: String.t() | nil
        }

  @setting "sheets.sidebar_hidden"

  # Labels are msgids, translated when shown (`label/1`).
  @items [
    %{id: "sheet", kind: :tab, tab: "sheet", icon: "hero-table-cells", permission: nil},
    %{id: "data", kind: :tab, tab: "data", icon: "hero-circle-stack", permission: "people.read"},
    %{id: "sheet.refresh", kind: :tool, tab: "sheet", icon: "hero-arrow-path", permission: nil},
    %{
      id: "sheet.cell_editor",
      kind: :section,
      tab: "sheet",
      icon: "hero-pencil",
      permission: nil
    },
    %{
      id: "data.export",
      kind: :tool,
      tab: "data",
      icon: "hero-arrow-up-tray",
      permission: "people.read"
    },
    %{
      id: "data.check",
      kind: :tool,
      tab: "data",
      icon: "hero-arrow-down-tray",
      permission: "people.write"
    },
    %{id: "data.new", kind: :tool, tab: "data", icon: "hero-plus", permission: "people.write"},
    %{
      id: "data.find",
      kind: :tool,
      tab: "data",
      icon: "hero-magnifying-glass",
      permission: "people.read"
    },
    %{
      id: "data.steps",
      kind: :section,
      tab: "data",
      icon: "hero-list-bullet",
      permission: "people.write"
    },
    %{
      id: "data.row_form",
      kind: :section,
      tab: "data",
      icon: "hero-cursor-arrow-rays",
      permission: "people.read"
    }
  ]

  @doc "Every item, in display order."
  @spec items() :: [item()]
  def items, do: Enum.map(@items, &Map.put(&1, :label, label(&1.id)))

  @doc "An item's label in the current locale."
  @spec label(String.t()) :: String.t()
  def label("sheet"), do: gettext("Sheet")
  def label("data"), do: gettext("Data")
  def label("sheet.refresh"), do: gettext("Refresh")
  def label("sheet.cell_editor"), do: gettext("Cell A1 editor")
  def label("data.export"), do: gettext("Export to this spreadsheet")
  def label("data.check"), do: gettext("Check changes in the sheet")
  def label("data.new"), do: gettext("New row")
  def label("data.find"), do: gettext("Find a person")
  def label("data.steps"), do: gettext("Step guide")
  def label("data.row_form"), do: gettext("Selected row form")

  @doc "The roles a layout is set for."
  @spec roles() :: [atom()]
  def roles, do: App.Access.roles()

  @doc """
  Everyone a layout is set for: the roles, then the access profiles —
  `[{key, kind, name}]`, `key` as stored (`"hr"`, `"profile:nurse"`).
  """
  @spec audiences() :: [{String.t(), :role | :profile, atom()}]
  def audiences do
    Enum.map(roles(), &{to_string(&1), :role, &1}) ++
      Enum.map(App.Access.profiles(), &{"profile:#{&1}", :profile, &1})
  end

  @doc "The ids hidden for each role (`%{\"hr\" => [...]}`)."
  @spec hidden() :: %{String.t() => [String.t()]}
  def hidden, do: App.Settings.get(@setting) || %{}

  @doc "Saves what is hidden for each audience (as `actor`, `settings.manage`)."
  @spec put_hidden(%{String.t() => [String.t()]}, map()) :: :ok | {:error, term()}
  def put_hidden(hidden, actor) do
    known = MapSet.new(@items, & &1.id)

    hidden =
      Map.new(audiences(), fn {key, _kind, _name} ->
        {key,
         hidden |> Map.get(key, []) |> Enum.filter(&MapSet.member?(known, &1)) |> Enum.sort()}
      end)

    App.Settings.put(@setting, hidden, actor)
  end

  @doc """
  The ids `user` sees (a user, or nil without an account in the app: only
  items needing no permission).
  """
  @spec visible(map() | nil) :: MapSet.t(String.t())
  def visible(user) do
    hidden = MapSet.new(hidden_for(hidden(), user))

    allowed =
      @items
      |> Enum.filter(fn item ->
        not MapSet.member?(hidden, item.id) and permitted?(item, user)
      end)
      |> MapSet.new(& &1.id)

    # A tab's tools and sections only with the tab.
    allowed
    |> Enum.filter(fn id -> MapSet.member?(allowed, tab_of(id)) end)
    |> MapSet.new()
  end

  @doc "The visible tabs, in order."
  @spec tabs(MapSet.t(String.t())) :: [item()]
  def tabs(visible),
    do: Enum.filter(items(), &(&1.kind == :tab and MapSet.member?(visible, &1.id)))

  @doc "The visible tools of `tab`."
  @spec tools(MapSet.t(String.t()), String.t()) :: [item()]
  def tools(visible, tab),
    do:
      Enum.filter(
        items(),
        &(&1.kind == :tool and &1.tab == tab and MapSet.member?(visible, &1.id))
      )

  # Hidden for the role, or for any of the user's profiles.
  defp hidden_for(_hidden, nil), do: []

  defp hidden_for(hidden, user) do
    profiles = for profile <- Map.get(user, :profiles) || [], do: "profile:#{profile}"
    Enum.flat_map([to_string(user.role) | profiles], &Map.get(hidden, &1, []))
  end

  defp permitted?(%{permission: nil}, _user), do: true
  defp permitted?(_item, nil), do: false
  defp permitted?(%{permission: permission}, user), do: AppWeb.Authz.can?(user, permission)

  defp tab_of(id), do: Enum.find(@items, &(&1.id == id)).tab
end
