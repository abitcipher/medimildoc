defmodule AppWeb.PeopleLive.New do
  @moduledoc """
  Create-person form, driven by `AppWeb.FormSchemas`'s `:person` JSON
  Schema/UI Schema pair via `AppWeb.JsonSchemaForm`. Ash
  (`AshPhoenix.Form`) owns validation/errors; the schema pair only decides
  widgets/labels.
  """
  use AppWeb, :live_view

  alias App.People.Person
  alias AppWeb.{FormSchemas, JsonSchemaForm}

  @impl true
  def mount(_params, _session, socket) do
    form =
      Person
      |> AshPhoenix.Form.for_create(:create, actor: socket.assigns.current_user)
      |> to_form()

    {:ok, assign(socket, form: form, page_title: gettext("New person"))}
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    {:noreply, assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form,
           params: params,
           actor: socket.assigns.current_user
         ) do
      {:ok, person} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Person created"))
         |> push_navigate(to: ~p"/people/#{person.id}")}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="max-w-lg mx-auto p-4">
        <h1 class="text-xl font-semibold mb-4">{gettext("New person")}</h1>
        <.form for={@form} id="person-form" phx-change="validate" phx-submit="save">
          <JsonSchemaForm.json_schema_form
            schema={FormSchemas.schema(:person)}
            ui_schema={FormSchemas.ui_schema(:person)}
            form={@form}
          />
          <button type="submit" class="btn btn-primary mt-4">{gettext("Create")}</button>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
