defmodule AppWeb.HeaderControlsTest do
  use AppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AppWeb.HeaderControls

  describe "avatar helpers" do
    test "initials come from the name, or the email when there is none" do
      assert HeaderControls.initials(%{name: "Demo clinician", email: "x@demo.test"}) == "DC"
      assert HeaderControls.initials(%{name: "Ada", email: "x@demo.test"}) == "A"
      assert HeaderControls.initials(%{name: nil, email: "zoe@demo.test"}) == "Z"
      assert HeaderControls.initials(%{name: "", email: "zoe@demo.test"}) == "Z"
    end

    test "the avatar colour is stable for an email" do
      color = HeaderControls.avatar_color(%{email: "a@demo.test"})
      assert color == HeaderControls.avatar_color(%{email: "a@demo.test"})
      assert String.starts_with?(color, "bg-")
    end

    test "languages are named in their own language" do
      assert HeaderControls.native_name("uk") == "Українська"
      assert HeaderControls.native_name("fr") == "Français"
      assert HeaderControls.native_name("xx") == "XX"
    end
  end

  test "the top bar has exactly three controls, each one labelled icon button", %{conn: conn} do
    user =
      Ash.Seed.seed!(App.Accounts.User, %{
        email: "hc-#{Ash.UUIDv7.generate()}@example.test",
        name: "Header Check",
        role: :hr
      })

    {:ok, view, _html} = live(authenticated_conn(conn, user), ~p"/people")

    for id <- ~w(language-menu theme-menu account-menu) do
      assert has_element?(view, "##{id}-button[aria-haspopup=menu][aria-label]")
      assert has_element?(view, "##{id}-menu[role=menu]")
    end

    assert has_element?(view, "#language-menu-menu a[role=menuitem][href='?locale=uk']")
    assert has_element?(view, ~s(#theme-menu-menu button[data-phx-theme="system"]))
    assert has_element?(view, "#account-menu-menu", "Header Check")
    assert has_element?(view, "#account-menu-menu", "HR staff")
  end
end
