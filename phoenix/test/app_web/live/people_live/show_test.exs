defmodule AppWeb.PeopleLive.ShowTest do
  @moduledoc """
  First `App.DataCase`/connected-`LiveView` test coverage for
  `AppWeb.PeopleLive.Show` — focused on the `Cinder.collection`
  extension to the `PersonRecord` list. Same
  `live/2` + `render_async/1` discipline as the other `Cinder`
  adoptions — a plain disconnected render shows an empty
  table shell, not the actual rows.
  """
  use AppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import App.Fixtures

  alias App.People.{Person, PersonRecord, PersonRecordSchema}

  setup %{conn: conn} do
    admin =
      Ash.Seed.seed!(App.Accounts.User, %{
        email: "admin-#{Ash.UUIDv7.generate()}@example.com",
        role: :admin
      })

    person =
      Person
      |> Ash.Changeset.for_create(:create, %{given_name: "Ada", family_name: "Lovelace"},
        actor: admin
      )
      |> Ash.create!()

    %{conn: authenticated_conn(conn, admin), admin: admin, person: person}
  end

  test "records render as readable cards and can be narrowed by category", %{
    conn: conn,
    person: person
  } do
    medical =
      record_fixture(person, :medical_condition, %{
        "code" => %{"text" => "Hypertension"},
        "clinicalStatus" => "active"
      })

    pay = record_fixture(person, :compensation)

    {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")
    render_async(view, 2_000)

    # Readable fields, not the raw map: translated labels and choice values.
    assert has_element?(view, "#record-#{medical.id} h3", "Medical condition")
    assert has_element?(view, "#record-#{medical.id} dd", "Hypertension")
    assert has_element?(view, "#record-#{medical.id} dd", "Active")
    refute render(view) =~ "%{"
    assert has_element?(view, "#record-#{pay.id}")

    view |> element(~s(button[phx-value-category="medical"])) |> render_click()
    render_async(view, 2_000)

    assert has_element?(view, "#record-#{medical.id}")
    refute has_element?(view, "#record-#{pay.id}")
    assert has_element?(view, ~s(button[phx-value-category="medical"][aria-pressed="true"]))
  end

  test "classified records carry the marking band", %{conn: conn, person: person} do
    vetting = record_fixture(person, :vetting_record)

    {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")
    render_async(view, 2_000)

    assert has_element?(view, "#record-#{vetting.id} [role=note]", "NATO RESTRICTED")
  end

  test "adding a record: open the picker, choose a kind, save", %{
    conn: conn,
    person: person
  } do
    {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")
    render_async(view, 2_000)

    refute has_element?(view, "#record-kind-picker")
    view |> element(~s(button[phx-click="toggle_kind_picker"])) |> render_click()

    view
    |> element(~s(#record-kind-picker button[phx-value-kind="family_status"]))
    |> render_click()

    refute has_element?(view, "#record-kind-picker")

    view
    |> form("form[phx-submit=save_record]", %{"record_data" => %{"maritalStatus" => "married"}})
    |> render_submit()

    render_async(view, 2_000)

    assert [%{kind: :family_status} = record] = Ash.read!(PersonRecord, authorize?: false)
    assert has_element?(view, "#record-#{record.id} dd", "Married")
  end

  test "optional choices start empty and aren't saved unless chosen; required ones are marked",
       %{conn: conn, person: person} do
    {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")
    view |> element(~s(button[phx-click="toggle_kind_picker"])) |> render_click()

    view
    |> element(~s(#record-kind-picker button[phx-value-kind="allergy_intolerance"]))
    |> render_click()

    assert has_element?(view, ~s(select[name="record_data[criticality]"] option[value=""]))

    assert has_element?(
             view,
             ~s(input[type=checkbox][name="record_data[category][]"][value=food])
           )

    refute has_element?(view, ~s(select[name="record_data[clinicalStatus]"] option[value=""]))
    assert has_element?(view, ~s(select[name="record_data[clinicalStatus]"][required]))

    view
    |> form("form[phx-submit=save_record]", %{
      "record_data" => %{
        "code" => %{"text" => "Peanut"},
        "clinicalStatus" => "active",
        "criticality" => "",
        "category" => ["", "food", "medication"]
      }
    })
    |> render_submit()

    assert [record] = Ash.read!(PersonRecord, authorize?: false)
    refute Map.has_key?(record.data, "criticality")
    assert record.data["category"] == ["food", "medication"]
  end

  test "a record with sliders and a checkbox saves (form values arrive as strings)",
       %{conn: conn, person: person} do
    {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")
    view |> element(~s(button[phx-click="toggle_kind_picker"])) |> render_click()

    view
    |> element(~s(#record-kind-picker button[phx-value-kind="language_proficiency"]))
    |> render_click()

    view
    |> form("form[phx-submit=save_record]", %{
      "record_data" => %{
        "listening" => "3",
        "speaking" => "3",
        "reading" => "2",
        "writing" => "2",
        "preferred" => "true"
      }
    })
    # The language picker's value travels in a hidden input.
    |> render_submit(%{"record_data" => %{"language" => "fr"}})

    assert [record] = Ash.read!(PersonRecord, authorize?: false)
    assert %{"language" => "fr", "listening" => 3, "preferred" => true} = record.data
  end

  describe "private identity data (docs/design/access-control-phase1.md)" do
    test "a viewer gets no Identity tab and no national ID data", %{person: person} do
      viewer =
        Ash.Seed.seed!(App.Accounts.User, %{
          email: "viewer-#{Ash.UUIDv7.generate()}@example.com",
          role: :viewer
        })

      conn = authenticated_conn(Phoenix.ConnTest.build_conn(), viewer)
      {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")

      refute has_element?(view, "h2", "National ID numbers")
      refute has_element?(view, "h2", "Identity documents")
      assert has_element?(view, "h2", "Records")
    end

    test "HR sees the Identity tab", %{person: person} do
      hr =
        Ash.Seed.seed!(App.Accounts.User, %{
          email: "hr-#{Ash.UUIDv7.generate()}@example.com",
          role: :hr
        })

      conn = authenticated_conn(Phoenix.ConnTest.build_conn(), hr)
      {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")

      assert has_element?(view, "h2", "National ID numbers")
    end
  end

  describe "record kinds offered per permission (docs/design/access-control-phase1.md)" do
    defp kind_buttons(view) do
      PersonRecordSchema.kinds()
      |> Enum.filter(&has_element?(view, ~s(button[phx-value-kind="#{&1}"])))
      |> Enum.sort()
    end

    defp live_as(person, role, profiles) do
      user =
        Ash.Seed.seed!(App.Accounts.User, %{
          email: "u-#{Ash.UUIDv7.generate()}@example.com",
          role: role,
          profiles: profiles
        })

      conn = authenticated_conn(Phoenix.ConnTest.build_conn(), user)
      {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")
      view
    end

    test "a clinician may add clinical and readiness records only", %{person: person} do
      view = live_as(person, :viewer, [:clinician])
      view |> element(~s(button[phx-click="toggle_kind_picker"])) |> render_click()

      assert kind_buttons(view) ==
               [
                 :allergy_intolerance,
                 :encounter,
                 :fitness_for_duty,
                 :lab_result,
                 :medical_condition,
                 :medication_administration,
                 :medication_statement,
                 :procedure,
                 :vital_signs
               ]
    end

    test "a combat medic may add point-of-care records only", %{person: person} do
      view = live_as(person, :viewer, [:combat_medic])
      view |> element(~s(button[phx-click="toggle_kind_picker"])) |> render_click()

      assert kind_buttons(view) == [
               :allergy_intolerance,
               :encounter,
               :medication_administration,
               :medication_statement,
               :procedure,
               :vital_signs
             ]
    end

    test "a line commander may add nothing", %{person: person} do
      view = live_as(person, :viewer, [:line_commander])
      assert kind_buttons(view) == []
      refute has_element?(view, ~s(button[phx-click="toggle_kind_picker"]))
    end

    test "a kind the actor can't write is ignored if sent anyway", %{person: person} do
      view = live_as(person, :viewer, [:clinician])
      render_click(view, "select_record_kind", %{"kind" => "vetting_record"})
      refute has_element?(view, ~s(form[phx-submit="save_record"]))
    end
  end

  describe "Break the Glass (docs/design/access-control-phase2.md)" do
    test "a clinician outside the unit can request emergency access with a reason", %{
      person: person
    } do
      App.Access.put_admin_full_data_access_override(false)
      assign_fixture(person, org_fixture("Their unit"))
      record_fixture(person, :allergy_intolerance)
      clinician = unit_user_fixture(:viewer, [:clinician], org_fixture("My unit"))

      conn = authenticated_conn(Phoenix.ConnTest.build_conn(), clinician)
      {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")

      refute has_element?(view, ~s([role="alert"]), "Allergies:")
      view |> element(~s(button[phx-click="toggle_btg_form"])) |> render_click()

      view
      |> form("#btg-form", %{"reason" => "Casualty at Role 2, allergy check"})
      |> render_submit()

      assert has_element?(view, ~s(div[role="alert"]), "Emergency access until")
      assert has_element?(view, ~s(span[role="alert"]), "Allergies:")
      refute has_element?(view, ~s(button[phx-click="toggle_btg_form"]))
    end

    test "no emergency button for someone already in the unit, or without btg.invoke", %{
      conn: conn,
      person: person
    } do
      {:ok, view, _html} = live(conn, ~p"/people/#{person.id}")
      refute has_element?(view, ~s(button[phx-click="toggle_btg_form"]))
    end
  end
end
