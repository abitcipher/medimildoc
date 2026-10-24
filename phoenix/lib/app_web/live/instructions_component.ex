defmodule AppWeb.InstructionsComponent do
  @moduledoc """
  Instructions on a registered incoming letter (docs/design/correspondence.md):
  the list with their executors, due dates and how they were closed; a form
  for the records officer or a head covering the letter's unit to give one;
  for the executor, "Done" with a note and "Write a reply" (a draft
  outgoing letter based on this one).
  """
  use AppWeb, :live_component

  alias App.Documents.{Access, Document, Instruction, Instructions}
  alias AppWeb.{DateFormat, FormSchemas, JsonSchemaForm}

  @impl true
  def update(assigns, socket) do
    actor = assigns.actor
    document = assigns.document

    may_give? =
      App.Access.can?(actor, "records.manage") or Access.holds?(actor, "orders.sign", document)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       may_give?: may_give?,
       executors:
         if(may_give?, do: Enum.map(Instructions.executors(), &{name(&1), &1.id}), else: [])
     )
     |> assign_new(:giving?, fn -> false end)
     |> assign_new(:completing_id, fn -> nil end)
     |> load()
     |> assign_give_form()}
  end

  defp load(socket),
    do: assign(socket, instructions: Instructions.for_document(socket.assigns.document))

  defp assign_give_form(socket) do
    form =
      Instruction
      |> AshPhoenix.Form.for_create(:give, actor: socket.assigns.actor, id: "instruction-new")
      |> to_form()

    assign(socket, give_form: form)
  end

  defp assign_done_form(socket, instruction) do
    form =
      instruction
      |> AshPhoenix.Form.for_update(:complete,
        actor: socket.assigns.actor,
        id: "instruction-done"
      )
      |> to_form()

    assign(socket, completing_id: instruction.id, done_form: form)
  end

  @impl true
  def handle_event("open_give", _params, socket), do: {:noreply, assign(socket, giving?: true)}
  def handle_event("close_give", _params, socket), do: {:noreply, assign(socket, giving?: false)}

  def handle_event("validate_give", %{"form" => params}, socket) do
    params = Map.put(params, "document_id", socket.assigns.document.id)

    {:noreply,
     assign(socket, give_form: AshPhoenix.Form.validate(socket.assigns.give_form, params))}
  end

  def handle_event("give", %{"form" => params}, socket) do
    params = Map.put(params, "document_id", socket.assigns.document.id)

    case AshPhoenix.Form.submit(socket.assigns.give_form, params: params) do
      {:ok, _} ->
        {:noreply, socket |> assign(giving?: false) |> load() |> assign_give_form()}

      {:error, form} ->
        {:noreply, assign(socket, give_form: form)}
    end
  end

  def handle_event("open_done", %{"id" => id}, socket) do
    instruction = Enum.find(socket.assigns.instructions, &(&1.id == id))
    {:noreply, if(instruction, do: assign_done_form(socket, instruction), else: socket)}
  end

  def handle_event("close_done", _params, socket),
    do: {:noreply, assign(socket, completing_id: nil)}

  def handle_event("validate_done", %{"form" => params}, socket),
    do:
      {:noreply,
       assign(socket, done_form: AshPhoenix.Form.validate(socket.assigns.done_form, params))}

  def handle_event("done", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.done_form, params: params) do
      {:ok, _} -> {:noreply, socket |> assign(completing_id: nil) |> load()}
      {:error, form} -> {:noreply, assign(socket, done_form: form)}
    end
  end

  # A draft reply: addressed to the sender, from the unit the letter was
  # addressed to, based on it.
  def handle_event("reply", _params, socket) do
    %{actor: actor, document: letter} = socket.assigns
    data = letter.data || %{}

    Document
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: :outgoing_letter,
        basis_id: letter.id,
        data:
          Map.reject(
            %{
              "addressee" => data["sender"],
              "unit" => data["unit"],
              "subject" =>
                gettext("Reply to letter No. %{number} of %{date}",
                  number: data["senderNumber"] || letter.number,
                  date: DateFormat.display(data["senderDate"] || letter.registered_on)
                )
            },
            fn {_key, value} -> is_nil(value) end
          )
      },
      actor: actor
    )
    |> Ash.create(actor: actor)
    |> case do
      {:ok, reply} ->
        {:noreply, push_navigate(socket, to: ~p"/documents/#{reply.id}")}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, App.AshErrors.summarize(error))}
    end
  end

  defp name(nil), do: "—"
  defp name(user), do: user.name || to_string(user.email)

  defp mine_open?(instructions, actor),
    do: Enum.any?(instructions, &(&1.status == :open and &1.executor_id == actor.id))

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="flex flex-col gap-2">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h2 class="flex items-center gap-2 font-semibold">
          {gettext("Resolutions and instructions")}
          <span class="badge badge-sm badge-ghost">{length(@instructions)}</span>
        </h2>
        <div class="flex flex-wrap gap-2">
          <button
            :if={mine_open?(@instructions, @actor) or App.Access.can?(@actor, "records.manage")}
            id="reply-button"
            type="button"
            phx-click="reply"
            phx-target={@myself}
            class="btn btn-sm"
          >
            <.icon name="hero-paper-airplane" class="size-4" /> {gettext("Write a reply")}
          </button>
          <button
            :if={@may_give? and not @giving?}
            id="give-instruction"
            type="button"
            phx-click="open_give"
            phx-target={@myself}
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus" class="size-4" /> {gettext("Give an instruction")}
          </button>
        </div>
      </div>

      <p :if={@instructions == []} class="text-sm opacity-60">{gettext("No instructions.")}</p>
      <ul :if={@instructions != []} class="flex flex-col gap-2">
        <li
          :for={i <- @instructions}
          id={"instruction-#{i.id}"}
          class="rounded-box border border-base-300 p-3 text-sm"
        >
          <p class="whitespace-pre-line">{i.text}</p>
          <p class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 opacity-80">
            <span>{gettext("Executor")}: {name(i.executor)}</span>
            <span :if={i.due_on}>
              {gettext("due %{date}", date: DateFormat.display(i.due_on))}
            </span>
            <span>{gettext("from %{name}", name: name(i.issued_by))}</span>
            <span :if={i.status == :open} class="badge badge-sm badge-warning">{gettext("open")}</span>
            <span :if={i.status == :done} class="badge badge-sm badge-success">{gettext("done")}</span>
          </p>
          <p :if={i.done_note} class="mt-1 italic opacity-80">«{i.done_note}»</p>
          <p :if={i.reply} class="mt-1">
            {gettext("Closed by the reply")}
            <.link navigate={~p"/documents/#{i.reply_id}"} class="link font-mono">
              {i.reply.number}
            </.link>
          </p>
          <button
            :if={i.status == :open and i.executor_id == @actor.id and @completing_id != i.id}
            type="button"
            phx-click="open_done"
            phx-value-id={i.id}
            phx-target={@myself}
            class="btn btn-sm mt-2"
          >
            <.icon name="hero-check" class="size-4" /> {gettext("Done")}
          </button>
          <.form
            :if={@completing_id == i.id}
            for={@done_form}
            id={"instruction-done-#{i.id}"}
            phx-change="validate_done"
            phx-submit="done"
            phx-target={@myself}
            class="mt-2"
          >
            <JsonSchemaForm.json_schema_form
              schema={FormSchemas.schema(:instruction_done)}
              ui_schema={FormSchemas.ui_schema(:instruction_done)}
              form={@done_form}
            />
            <div class="mt-2 flex gap-2">
              <button type="submit" class="btn btn-primary btn-sm">{gettext("Save")}</button>
              <button
                type="button"
                phx-click="close_done"
                phx-target={@myself}
                class="btn btn-ghost btn-sm"
              >
                {gettext("Cancel")}
              </button>
            </div>
          </.form>
        </li>
      </ul>

      <.form
        :if={@may_give? and @giving?}
        for={@give_form}
        id="instruction-form"
        phx-change="validate_give"
        phx-submit="give"
        phx-target={@myself}
        class="rounded-box border border-primary/40 p-3"
      >
        <JsonSchemaForm.json_schema_form
          schema={FormSchemas.schema(:instruction)}
          ui_schema={FormSchemas.ui_schema(:instruction)}
          form={@give_form}
          field_options={%{executor_id: @executors}}
        />
        <div class="mt-2 flex gap-2">
          <button type="submit" class="btn btn-primary btn-sm">{gettext("Give")}</button>
          <button
            type="button"
            phx-click="close_give"
            phx-target={@myself}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Cancel")}
          </button>
        </div>
      </.form>
    </section>
    """
  end
end
