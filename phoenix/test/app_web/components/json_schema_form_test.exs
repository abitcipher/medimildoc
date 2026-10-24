defmodule AppWeb.JsonSchemaFormTest do
  @moduledoc """
  Renders `AppWeb.JsonSchemaForm` directly via `render_component/2` — no
  DB needed (it's a plain function component; only Ash-resource-backed
  forms need a live Repo, tested end-to-end elsewhere).
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [to_form: 2]

  alias AppWeb.{FormSchemas, JsonSchemaForm}

  @endpoint AppWeb.Endpoint

  describe "form mode (AppWeb.FormSchemas, flat Ash attributes)" do
    test "renders the right widget/label/name/id per field, from :person" do
      form = to_form(%{}, as: :form)

      html =
        render_component(&JsonSchemaForm.json_schema_form/1,
          schema: FormSchemas.schema(:person),
          ui_schema: FormSchemas.ui_schema(:person),
          form: form
        )

      assert html =~ ~s(name="form[given_name]")
      assert html =~ ~s(id="form_given_name")
      assert html =~ "Given name"
      assert html =~ ~s(type="text" name="form[given_name]")
      assert html =~ ~s(type="email" name="form[email]")
      assert html =~ ~s(type="date" name="form[date_of_birth]")
    end

    test "renders a select with the schema's enum, from :organization" do
      form = to_form(%{}, as: :form)

      html =
        render_component(&JsonSchemaForm.json_schema_form/1,
          schema: FormSchemas.schema(:organization),
          ui_schema: FormSchemas.ui_schema(:organization),
          form: form
        )

      assert html =~ "<select"
      assert html =~ ~s(name="form[kind]")
      assert html =~ ">Battalion<"
    end

    test "field_options overrides the widget with a select of the given options" do
      form = to_form(%{}, as: :form)

      html =
        render_component(&JsonSchemaForm.json_schema_form/1,
          schema: FormSchemas.schema(:position),
          ui_schema: FormSchemas.ui_schema(:position),
          form: form,
          field_options: %{organization_id: [{"HQ", "org-1"}]}
        )

      assert html =~ "<select"
      assert html =~ ~s(name="form[organization_id]")
      assert html =~ ">HQ<"
      assert html =~ ~s(value="org-1")
    end
  end

  describe "values mode (App.People.PersonRecordSchema, polymorphic PersonRecord.data)" do
    test "builds bracketed names/ids from nested JSON pointer scopes, from :medical_condition" do
      html =
        render_component(&JsonSchemaForm.json_schema_form/1,
          schema: App.People.PersonRecordSchema.schema(:medical_condition),
          ui_schema: App.People.PersonRecordSchema.ui_schema(:medical_condition),
          values: %{"code" => %{"text" => "Hypertension"}, "clinicalStatus" => "active"},
          name: "record_data"
        )

      assert html =~ ~s(name="record_data[code][text]")
      assert html =~ ~s(id="record_data_code_text")
      assert html =~ ~s(value="Hypertension")
      assert html =~ "<select"
      assert html =~ ~s(name="record_data[clinicalStatus]")
    end

    test "renders empty inputs (not a crash) when values is empty" do
      html =
        render_component(&JsonSchemaForm.json_schema_form/1,
          schema: App.People.PersonRecordSchema.schema(:status_change),
          ui_schema: App.People.PersonRecordSchema.ui_schema(:status_change),
          values: %{},
          name: "record_data"
        )

      assert html =~ ~s(name="record_data[changeType]")
      assert html =~ ~s(name="record_data[description]")
    end
  end
end
