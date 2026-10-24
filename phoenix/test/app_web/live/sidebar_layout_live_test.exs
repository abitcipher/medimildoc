defmodule AppWeb.SidebarLayoutLiveTest do
  @moduledoc "docs/design/sheets-ui.md §Sidebar layout: the page."
  use AppWeb.ConnCase, async: false

  import App.Fixtures
  import Phoenix.LiveViewTest

  alias AppWeb.SidebarLayout

  test "an admin unticks an item for a role; it is saved at once", %{conn: conn} do
    admin = user_fixture(:admin)
    {:ok, view, _} = live(authenticated_conn(conn, admin), ~p"/sidebar-layout")

    ids = Enum.map(SidebarLayout.items(), & &1.id)

    shown =
      for {key, _kind, _name} <- SidebarLayout.audiences(), into: %{} do
        {key, if(key in ["viewer", "profile:nurse"], do: ids -- ["sheet"], else: ids)}
      end

    view |> form("#sidebar-layout", shown: shown) |> render_change()

    hidden = SidebarLayout.hidden()
    assert hidden["admin"] == [] and hidden["hr"] == []
    assert hidden["viewer"] == ["sheet"] and hidden["profile:nurse"] == ["sheet"]
    refute "sheet" in SidebarLayout.visible(user_fixture(:viewer))
    assert "sheet" in SidebarLayout.visible(user_fixture(:hr))
    # Hidden for one of the user's profiles (SHEETS-UI.19).
    refute "sheet" in SidebarLayout.visible(user_fixture(:hr, [:nurse]))
    assert has_element?(view, "th", "Nurse")
  end

  test "only for settings.manage", %{conn: conn} do
    assert {:error, {:redirect, _}} =
             live(authenticated_conn(conn, user_fixture(:hr)), ~p"/sidebar-layout")
  end

  test "a tool needs its permission and its tab, whatever is ticked" do
    viewer = user_fixture(:viewer)
    visible = SidebarLayout.visible(viewer)
    assert "data.export" in visible
    refute "data.check" in visible

    # Without an account in the app: only what needs no permission.
    assert SidebarLayout.visible(nil) ==
             MapSet.new(["sheet", "sheet.refresh", "sheet.cell_editor"])
  end
end
