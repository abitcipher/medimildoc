defmodule AppWeb.InterfaceLiveTest do
  @moduledoc "docs/design/ui-preferences.md: interface settings and how pages follow them."
  use AppWeb.ConnCase, async: true

  import App.Fixtures
  import Phoenix.LiveViewTest

  alias App.Accounts.{UiPreferences, User}
  alias AppWeb.FormPanels

  describe "UiPreferences" do
    test "defaults: edit in the page, a button opens New forms; unknown keys are dropped" do
      assert UiPreferences.get(%{}, "edit_form", "narrow") == "inline"
      assert UiPreferences.get(nil, "create_form", "wide") == "toolbar"

      assert {:ok, prefs} = UiPreferences.put(%{}, "edit_form", "narrow", "modal")
      assert prefs == %{"edit_form" => %{"narrow" => "modal"}}
      assert UiPreferences.get(prefs, "edit_form", "wide") == "inline"

      assert :error = UiPreferences.put(prefs, "edit_form", "narrow", "sideways")
      assert :error = UiPreferences.put(prefs, "colour", "narrow", "modal")
      assert :error = UiPreferences.put(prefs, "edit_form", "huge", "modal")

      assert UiPreferences.normalize(%{
               "edit_form" => %{"narrow" => "modal", "wide" => "nope", "tv" => "modal"},
               "theme" => %{"wide" => "dark"},
               "forms" => %{
                 "identifier" => %{"wide" => "compact"},
                 "nonsense" => %{"wide" => "menu"}
               }
             }) == %{
               "edit_form" => %{"narrow" => "modal"},
               "forms" => %{"identifier" => %{"wide" => "compact"}}
             }

      assert UiPreferences.normalize(%{"forms" => "broken"}) == %{}
    end

    test "a form can have its own add control, or follow the general one" do
      {:ok, prefs} = UiPreferences.put(%{}, "create_form", "wide", "menu")
      {:ok, prefs} = UiPreferences.put_form(prefs, "identifier", "wide", "compact")

      assert UiPreferences.create_mode(prefs, "identifier", "wide") == "compact"
      assert UiPreferences.create_mode(prefs, "identity_document", "wide") == "menu"
      assert UiPreferences.create_mode(prefs, nil, "wide") == "menu"
      assert UiPreferences.form_override(prefs, "identifier", "narrow") == nil

      assert {:ok, prefs} = UiPreferences.put_form(prefs, "identifier", "wide", "default")
      refute Map.has_key?(prefs, "forms")
      assert :error = UiPreferences.put_form(prefs, "nonsense", "wide", "menu")
      assert :error = UiPreferences.put_form(prefs, "identifier", "wide", "sideways")
    end

    test "a form shows hidden, inline or modal per width" do
      prefs = %{
        "edit_form" => %{"narrow" => "modal", "wide" => "inline"},
        "create_form" => %{"narrow" => "menu", "wide" => "visible"}
      }

      assert FormPanels.presentation(prefs, :edit, false, "narrow") == :hidden
      assert FormPanels.presentation(prefs, :edit, true, "narrow") == :modal
      assert FormPanels.presentation(prefs, :edit, true, "wide") == :inline
      # Always visible on wide screens, behind the menu on narrow ones.
      assert FormPanels.presentation(prefs, :create, false, "wide") == :inline
      assert FormPanels.presentation(prefs, :create, false, "narrow") == :hidden
      assert FormPanels.presentation(prefs, :create, true, "narrow") == :modal
    end
  end

  test "a user changes their own settings, never someone else's", %{conn: conn} do
    user = user_fixture(:viewer)
    other = user_fixture(:admin)

    {:ok, view, html} = live(authenticated_conn(conn, user), ~p"/interface")
    assert html =~ "Narrow screens (phones)"

    view
    |> form("#interface-form", %{"prefs" => %{"edit_form" => %{"narrow" => "modal"}}})
    |> render_change()

    saved = Ash.get!(User, user.id, authorize?: false).ui_preferences
    assert UiPreferences.get(saved, "edit_form", "narrow") == "modal"
    assert UiPreferences.get(saved, "edit_form", "wide") == "inline"

    assert {:error, %Ash.Error.Forbidden{}} =
             other
             |> Ash.Changeset.for_update(:update_preferences, %{ui_preferences: %{}}, actor: user)
             |> Ash.update(actor: user)
  end

  defp with_prefs(user, prefs) do
    user
    |> Ash.Changeset.for_update(:update_preferences, %{ui_preferences: prefs}, actor: user)
    |> Ash.update!(actor: user)
  end

  test "organizations: the New form behind a toolbar button, edit in a window", %{conn: conn} do
    admin =
      with_prefs(user_fixture(:admin), %{
        "edit_form" => %{"narrow" => "modal", "wide" => "modal"},
        "create_form" => %{"narrow" => "menu", "wide" => "toolbar"}
      })

    org = org_fixture("1st Brigade")

    {:ok, view, _html} = live(authenticated_conn(conn, admin), ~p"/organizations")
    render_async(view, 2_000)

    # Hidden until asked for; the toolbar on wide screens, the ⋮ menu on narrow ones.
    refute has_element?(view, "#organization-new")
    assert has_element?(view, "#organization-actions-toolbar.hidden.md\\:flex")
    assert has_element?(view, "#organization-actions-menu.flex.md\\:hidden")

    view |> element("#organization-actions-toolbar button") |> render_click()
    assert has_element?(view, "#organization-new[role=dialog].fixed")
    assert has_element?(view, "#organization-edit-form")

    view |> element("#organization-new button.rounded-full[aria-label=Close]") |> render_click()
    refute has_element?(view, "#organization-new")

    view |> element("button[phx-click=edit][phx-value-id='#{org.id}']") |> render_click()
    assert has_element?(view, "#organization-edit[role=dialog]")
  end

  test "default settings: New behind a toolbar button, edit in the page", %{conn: conn} do
    admin = user_fixture(:admin)
    org = org_fixture("1st Brigade")

    {:ok, view, _html} = live(authenticated_conn(conn, admin), ~p"/organizations")
    render_async(view, 2_000)

    refute has_element?(view, "#organization-new")
    view |> element("#organization-actions-toolbar button") |> render_click()
    assert has_element?(view, "#organization-new #organization-edit-form")
    refute has_element?(view, "#organization-new[role=dialog]")

    view |> element("button[phx-click=edit][phx-value-id='#{org.id}']") |> render_click()
    assert has_element?(view, "#organization-edit")
    refute has_element?(view, "#organization-edit[role=dialog]")
  end

  test "the Identity tab: each list with its own add control, forms opened on demand",
       %{conn: conn} do
    hr = user_fixture(:hr)

    # National IDs: their own setting (always shown); documents: compact icon.
    hr =
      with_prefs(hr, %{
        "create_form" => %{"narrow" => "compact", "wide" => "compact"},
        "edit_form" => %{"narrow" => "modal", "wide" => "modal"},
        "forms" => %{"identifier" => %{"narrow" => "visible", "wide" => "visible"}}
      })

    person = person_fixture()

    {:ok, view, _html} = live(authenticated_conn(conn, hr), ~p"/people/#{person.id}")

    assert has_element?(view, "#identifier-new-panel #identifier-form-element")
    refute has_element?(view, "#identity-document-new-panel")

    button = "#identity-documents-header-actions-compact button[aria-label='Add a document']"
    view |> element(button) |> render_click()
    assert has_element?(view, "#identity-document-new-panel[role=dialog] #document-form-element")

    view
    |> form("#document-form-element", %{
      "form" => %{"document_type" => "passport", "number" => "AB123456"}
    })
    |> render_submit()

    refute has_element?(view, "#identity-document-new-panel")
    assert view |> element("#identity-documents-list") |> render() =~ "AB123456"

    # Edit opens in a window; the row is marked.
    [doc] = Ash.read!(App.People.IdentityDocument, authorize?: false)

    view
    |> element("#identity-documents-list tr button[phx-click=edit_document]")
    |> render_click()

    assert has_element?(view, "#identity-document-edit-panel[role=dialog]")
    assert has_element?(view, "#identity-documents-list tr.bg-base-200")
    assert doc.number
  end

  test "sections: glow by default, a frame only or off; the page carries the choice",
       %{conn: conn} do
    assert UiPreferences.section_style(%{}) == "glow"
    assert UiPreferences.section_style(%{"sections" => "nonsense"}) == "glow"
    assert :error = UiPreferences.put_section_style(%{}, "sparkles")
    assert UiPreferences.normalize(%{"sections" => "off"}) == %{"sections" => "off"}

    user = user_fixture(:viewer)
    {:ok, view, html} = live(authenticated_conn(conn, user), ~p"/interface")
    assert html =~ ~s(data-sections="glow")

    view |> form("#interface-form", %{"sections" => "static"}) |> render_change()
    saved = Ash.get!(User, user.id, authorize?: false).ui_preferences
    assert UiPreferences.section_style(saved) == "static"

    {:ok, _view, html} = live(authenticated_conn(conn, user), ~p"/notifications")
    assert html =~ ~s(data-sections="static")
  end

  test "windows: buttons left or right, Save and Cancel in the title bar, the frame",
       %{conn: conn} do
    assert UiPreferences.single(%{}, "window_controls") == "left"
    assert UiPreferences.single(%{}, "form_buttons") == "form"
    assert UiPreferences.single(%{}, "window_border") == "colour"
    assert :error = UiPreferences.put_single(%{}, "window_controls", "top")
    assert :error = UiPreferences.put_single(%{}, "nonsense", "left")

    admin = user_fixture(:admin)
    {:ok, view, _html} = live(authenticated_conn(conn, admin), ~p"/interface")

    view
    |> form("#interface-form", %{
      "prefs" => %{"edit_form" => %{"narrow" => "modal", "wide" => "modal"}},
      "singles" => %{
        "window_controls" => "right",
        "form_buttons" => "header",
        "window_border" => "contrast"
      }
    })
    |> render_change()

    org = org_fixture("1st Brigade")
    {:ok, view, _html} = live(authenticated_conn(conn, admin), ~p"/organizations")
    render_async(view, 2_000)
    view |> element("button[phx-click=edit][phx-value-id='#{org.id}']") |> render_click()

    panel = "#organization-edit.window-border-contrast.actions-in-header"
    assert has_element?(view, panel)
    # Save in the title bar submits the edit form; the title bar is mirrored.
    assert has_element?(view, "#{panel} button[type=submit][form=organization-update-form]")
    assert has_element?(view, "#{panel} .flex-row-reverse.md\\:flex-row-reverse")
    # The form's own buttons are marked, so the window hides them.
    assert has_element?(view, "#organization-update-form .form-actions")

    view
    |> form("#organization-update-form", %{"form" => %{"name" => "1st Brigade (renamed)"}})
    |> render_submit()

    assert Ash.get!(App.People.Organization, org.id, authorize?: false).name ==
             "1st Brigade (renamed)"
  end

  test "per-form settings are saved from the settings page", %{conn: conn} do
    user = user_fixture(:viewer)
    {:ok, view, _html} = live(authenticated_conn(conn, user), ~p"/interface")

    view
    |> form("#interface-form", %{"forms" => %{"identifier" => %{"wide" => "menu"}}})
    |> render_change()

    saved = Ash.get!(User, user.id, authorize?: false).ui_preferences
    assert UiPreferences.create_mode(saved, "identifier", "wide") == "menu"
    assert UiPreferences.form_override(saved, "identifier", "narrow") == nil
    assert UiPreferences.create_mode(saved, "position", "wide") == "toolbar"
  end
end
