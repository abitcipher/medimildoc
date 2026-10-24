defmodule AppWeb.PeopleLive.Edit do
  @moduledoc """
  Edit-person form — same `AppWeb.FormSchemas`/`AppWeb.JsonSchemaForm`
  pattern as `AppWeb.PeopleLive.New`, built from `AshPhoenix.Form.for_update/2`
  instead of `for_create/3`.
  """
  use AppWeb, :live_view

  alias App.People.Person
  alias AppWeb.{FormSchemas, JsonSchemaForm}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    person = Ash.get!(Person, id, actor: socket.assigns.current_user)

    form =
      person
      |> AshPhoenix.Form.for_update(:update, actor: socket.assigns.current_user)
      |> to_form()

    {:ok, assign(socket, form: form, person: person, page_title: gettext("Edit person"))}
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
         |> put_flash(:info, gettext("Person updated"))
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
        <h1 class="text-xl font-semibold mb-4">
          {gettext("Edit %{name}", name: Person.full_name(@person))}
        </h1>
        <.form for={@form} id="person-form" phx-change="validate" phx-submit="save">
          <JsonSchemaForm.json_schema_form
            schema={FormSchemas.schema(:person)}
            ui_schema={FormSchemas.ui_schema(:person)}
            form={@form}
          />
          <div class="flex gap-2 mt-4">
            <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
            <.link navigate={~p"/people/#{@person.id}"} class="btn">{gettext("Cancel")}</.link>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
