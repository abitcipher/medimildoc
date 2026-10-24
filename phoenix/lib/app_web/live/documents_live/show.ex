defmodule AppWeb.DocumentsLive.Show do
  @moduledoc """
  One document (docs/design/documents-core.md): its fields — a form while
  it is a draft its viewer may write, read-only otherwise; sending it along
  its route with the assignees chosen per step; the route and what each
  step decided; approve / return / sign for whoever holds the current
  step; the register number, hashes and PDF once signed; the history.

  Every action goes through the document's Ash actions with the viewer as
  actor, so the policies decide; this page only hides what can't succeed.
  """
  use AppWeb, :live_view

  require Ash.Query

  alias App.Documents.{Access, Certificates, Deputies, Document, Drafts, Print, Queries, Types}
  alias App.Duty.RosterData
  alias App.Leave.CalendarData
  alias App.People.{Position, PositionLabel}
  alias App.Rules.Check
  alias AppWeb.{DocumentUI, JsonSchemaForm}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok, socket |> assign(errors: []) |> load(id)}
  end

  defp load(socket, id) do
    actor = socket.assigns.current_user

    document =
      Document
      |> Ash.get!(id, actor: actor, load: [:data, :person, :basis, :author, :signed_by])
      |> Queries.load_trail()
      # The file plan case (index and title only; docs/design/registers-file-plan.md).
      |> Ash.load!(:case, authorize?: false)

    # The actor's pending step (a parallel stage has several pending).
    current = Queries.step_for(actor, document)

    editable? = Drafts.editable?(actor, document)

    assign(socket,
      page_title: DocumentUI.type_label(document.type),
      document: document,
      values: document.data || %{},
      current: current,
      my_turn?: current != nil and current.assignee_id == actor.id,
      for_assignee: for_assignee(actor, current, document),
      editable?: editable?,
      registers_directly?: editable? and Drafts.registers_directly?(actor, document),
      route: if(editable?, do: route_choices(document), else: []),
      field_options: if(editable?, do: field_options(document.type), else: %{}),
      rows: Print.rows(document.type, document.data || %{}, AppWeb.DocumentLabels, locale()),
      round: latest_round(document.steps),
      flags: Check.open_flags(document.id),
      leave: leave_summary(document, document.data || %{}),
      sections: certificate_sections(document, document.data || %{})
    )
    |> assign_acknowledgement(document, actor)
  end

  # A deputy deciding for the assignee (docs/design/inbox-first.md): the
  # assignee, or nil.
  defp for_assignee(_actor, nil, _document), do: nil
  defp for_assignee(%{id: id}, %{assignee_id: id}, _document), do: nil

  defp for_assignee(actor, current, document) do
    if Deputies.may_act?(actor, current, document),
      do: Enum.find_value(document.steps, &(&1.id == current.id && &1.assignee))
  end

  # An order the person acknowledges (docs/design/acknowledgements.md):
  # done or not; the person may acknowledge it themselves, HR or a
  # commander covering them may record it on their behalf.
  defp assign_acknowledgement(socket, document, actor) do
    if document.state == :signed and Types.acknowledge?(document.type) do
      done = Queries.acknowledgements([document.id])[document.id]

      assign(socket,
        acknowledge?: true,
        acknowledgement: done,
        can_acknowledge?:
          is_nil(done) and document.person_id != nil and actor.person_id == document.person_id,
        can_record?: is_nil(done) and Access.can_record_acknowledgement?(actor, document)
      )
    else
      assign(socket,
        acknowledge?: false,
        acknowledgement: nil,
        can_acknowledge?: false,
        can_record?: false
      )
    end
  end

  # A certificate: what it states — frozen once signed, otherwise what it
  # would state today (docs/design/certificates.md).
  defp certificate_sections(%{state: :signed} = document, data),
    do: Print.sections(document.type, data, AppWeb.DocumentLabels, locale())

  defp certificate_sections(%{state: state} = document, data)
       when state in [:draft, :in_review] do
    with kind when is_binary(kind) <- Types.facts(document.type),
         {:ok, data} <- Types.cast_draft(document.type, data),
         :ok <- Certificates.check(document.type, data) do
      kind
      |> Certificates.facts(document.person_id, data, Date.utc_today())
      |> then(&Certificates.sections(kind, &1, AppWeb.DocumentLabels, locale()))
    else
      _ -> []
    end
  end

  defp certificate_sections(_document, _data), do: []

  # A leave request or order on its way: the days it asks for, what is
  # left of that leave this year before it, and overlaps (docs/design/leave.md).
  @leave_types [:leave_request, :personnel_order_leave]

  defp leave_summary(%{type: type, state: state} = document, values)
       when type in @leave_types and state in [:draft, :in_review] do
    facts = App.Leave.facts(document.person_id, document.id, values)

    if facts["requestedDays"] do
      facts
      |> Map.put("unit", CalendarData.unit_load(document.person_id, values))
      |> Map.put("duties", duties(document.person_id, values))
    end
  end

  defp leave_summary(_document, _values), do: nil

  # Duties planned in the requested days (docs/design/duty-roster.md): a count.
  defp duties(person_id, values) do
    with {:ok, first} <- Date.from_iso8601(values["startDate"] || ""),
         {:ok, last} <- Date.from_iso8601(values["endDate"] || "") do
      RosterData.count(person_id, first, last)
    else
      _ -> 0
    end
  end

  defp locale, do: Gettext.get_locale(AppWeb.Gettext)

  defp route_choices(document),
    do: Enum.map(Types.route(document.type), &{&1, Access.eligible_users(&1, document)})

  # Choices for fields that reference an entity (`x-entity`): a post from
  # the staffing table, by its short label, or a care provider.
  defp field_options(type) do
    for {key, %{"x-entity" => entity}} <- Types.schema(type)["properties"], into: %{} do
      {key, entity_options(entity)}
    end
  end

  defp entity_options("position"), do: position_options()

  # A unit (letters, docs/design/correspondence.md).
  defp entity_options("organization") do
    App.People.Organization
    |> Ash.read!(authorize?: false)
    |> Enum.map(&{&1.name, &1.id})
    |> Enum.sort()
  end

  # Active care providers, our own units first (docs/design/referral-discharge.md).
  defp entity_options("provider") do
    {own, external} =
      App.Care.Provider
      |> Ash.Query.filter(active == true)
      |> Ash.Query.sort(name: :asc)
      |> Ash.read!(authorize?: false)
      |> Enum.split_with(& &1.priority)

    [
      {gettext("Our units"), Enum.map(own, &{&1.name, &1.id})},
      {gettext("External providers"), Enum.map(external, &{&1.name, &1.id})}
    ]
  end

  defp position_options do
    Position
    |> Ash.Query.load(:organization)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&{PositionLabel.for_position(&1), &1.id})
    |> Enum.sort()
  end

  defp latest_round([]), do: []

  defp latest_round(steps) do
    last = steps |> Enum.map(& &1.round) |> Enum.max()
    Enum.filter(steps, &(&1.round == last))
  end

  @impl true
  def handle_event("validate", %{"data" => data}, socket) do
    document = socket.assigns.document

    {:noreply,
     assign(socket,
       values: data,
       leave: leave_summary(document, data),
       sections: certificate_sections(document, data)
     )}
  end

  def handle_event("save", %{"data" => data}, socket) do
    run(socket, :update_fields, %{data: data}, gettext("Draft saved"))
  end

  def handle_event("submit", params, socket) do
    assignees =
      socket.assigns.route
      |> Enum.with_index()
      |> Enum.map(fn {_entry, i} ->
        params |> Map.get("step_#{i}", []) |> List.wrap() |> Enum.reject(&(&1 == ""))
      end)

    run(socket, :submit, %{assignees: assignees}, gettext("Sent for approval"))
  end

  def handle_event("decide", %{"decision" => decision} = params, socket)
      when decision in ["approve", "return", "sign"] do
    message =
      case decision do
        "approve" -> gettext("Approved")
        "return" -> gettext("Returned to the author")
        "sign" -> gettext("Signed and registered")
      end

    run(socket, String.to_existing_atom(decision), %{comment: params["comment"]}, message)
  end

  # An incoming letter: sent to oneself and signed in one go
  # (docs/design/correspondence.md).
  def handle_event("register", _params, socket) do
    actor = socket.assigns.current_user

    with true <- socket.assigns.registers_directly?,
         {:ok, document} <-
           socket.assigns.document
           |> Ash.Changeset.for_update(:submit, %{assignees: [[actor.id]]}, actor: actor)
           |> Ash.update(actor: actor) do
      socket = assign(socket, document: document)
      run(socket, :sign, %{}, gettext("Registered"))
    else
      {:error, error} ->
        {:noreply, assign(socket, errors: [translate(App.AshErrors.summarize(error))])}

      false ->
        {:noreply, socket}
    end
  end

  # The person's report on their signed business trip order
  # (docs/design/business-trips.md §Report), pre-filled from it.
  def handle_event("trip_report", _params, socket) do
    actor = socket.assigns.current_user
    order = socket.assigns.document
    data = order.data || %{}

    Document
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: :business_trip_report,
        person_id: order.person_id,
        basis_id: order.id,
        data:
          Map.reject(
            %{
              "destination" => data["destination"],
              "startDate" => data["startDate"],
              "endDate" => data["endDate"],
              "destinationType" => "domestic"
            },
            fn {_key, value} -> is_nil(value) end
          )
      },
      actor: actor
    )
    |> Ash.create(actor: actor)
    |> case do
      {:ok, report} ->
        {:noreply, push_navigate(socket, to: ~p"/documents/#{report.id}")}

      {:error, error} ->
        {:noreply, assign(socket, errors: [translate(App.AshErrors.summarize(error))])}
    end
  end

  def handle_event("cancel", _params, socket),
    do: run(socket, :cancel, %{}, gettext("Document cancelled"))

  def handle_event("acknowledge", _params, socket),
    do: acknowledge(socket, :acknowledge, %{}, gettext("Acknowledged"))

  def handle_event("record_acknowledgement", %{"acknowledgement" => params}, socket) do
    args = %{
      acknowledged_on: params["acknowledged_on"],
      method: params["method"],
      note: blank_to_nil(params["note"])
    }

    acknowledge(socket, :record, args, gettext("Acknowledgement recorded"))
  end

  defp acknowledge(socket, action, args, message) do
    actor = socket.assigns.current_user
    document = socket.assigns.document

    App.Documents.Acknowledgement
    |> Ash.Changeset.for_create(action, Map.put(args, :document_id, document.id), actor: actor)
    |> Ash.create(actor: actor)
    |> case do
      {:ok, _acknowledgement} ->
        {:noreply, socket |> put_flash(:info, message) |> assign(errors: []) |> load(document.id)}

      {:error, error} ->
        {:noreply, assign(socket, errors: [translate(App.AshErrors.summarize(error))])}
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp run(socket, action, args, message) do
    actor = socket.assigns.current_user

    socket.assigns.document
    |> Ash.Changeset.for_update(action, args, actor: actor)
    |> Ash.update(actor: actor)
    |> case do
      {:ok, _document} ->
        {:noreply,
         socket
         |> put_flash(:info, message)
         |> assign(errors: [])
         |> load(socket.assigns.document.id)}

      {:error, error} ->
        {:noreply, assign(socket, errors: [translate(App.AshErrors.summarize(error))])}
    end
  end

  # Messages from the domain are English msgids (App.Documents.Effects,
  # the types' x-then-message); shown in the viewer's language when known.
  defp translate(text),
    do: text |> String.split("; ") |> Enum.map_join("; ", &Gettext.gettext(AppWeb.Gettext, &1))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-4xl flex-col gap-4 p-4">
        <header class="flex flex-wrap items-start gap-3">
          <span class="grid size-10 shrink-0 place-items-center rounded-full bg-base-200">
            <.icon name={Types.icon(@document.type)} class="size-5" />
          </span>
          <div class="min-w-0 grow">
            <h1 class="flex flex-wrap items-center gap-2 text-xl font-semibold">
              {DocumentUI.type_label(@document.type)}
              <DocumentUI.state_badge state={@document.state} type={@document.type} />
            </h1>
            <p class="flex flex-wrap gap-x-3 text-sm opacity-80">
              <.link
                :if={@document.person}
                navigate={~p"/people/#{@document.person_id}"}
                class="link link-hover"
              >
                {App.People.Person.full_name(@document.person)}
              </.link>
              <span :if={@document.number} class="font-mono">
                № {@document.number} · {AppWeb.DateFormat.display(@document.registered_on)}
              </span>
              <span :if={@document.due_on}>
                {gettext("due %{date}", date: AppWeb.DateFormat.display(@document.due_on))}
              </span>
              <.link
                :if={@document.basis}
                navigate={"/documents/#{@document.basis_id}"}
                class="link link-hover"
              >
                {gettext("Basis: %{document}",
                  document: @document.basis.number || DocumentUI.type_label(@document.basis.type)
                )}
              </.link>
            </p>
          </div>
          <a
            :if={@document.state == :signed and @document.pdf_key}
            href={~p"/documents/#{@document.id}/pdf"}
            target="_blank"
            rel="noopener"
            class="btn btn-sm"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> PDF
          </a>
        </header>

        <div
          :if={@flags != []}
          id="document-flags"
          role="alert"
          class="alert alert-warning alert-soft text-sm"
        >
          <.icon name="hero-flag" class="size-5" />
          <div>
            <p class="font-medium">{gettext("Flagged by a data consistency rule")}</p>
            <ul>
              <li :for={flag <- @flags}>{Gettext.gettext(AppWeb.Gettext, flag)}</li>
            </ul>
          </div>
        </div>

        <div
          :if={@leave}
          id="leave-summary"
          class="flex flex-wrap items-center gap-x-4 gap-y-1 rounded-box border border-base-300 px-3 py-2 text-sm"
        >
          <span>
            {ngettext("%{count} day requested", "%{count} days requested", @leave["requestedDays"])}
          </span>
          <span
            :if={@leave["balance"]}
            class={@leave["balance"] < @leave["requestedDays"] && "text-warning"}
          >
            {ngettext(
              "%{count} day of this leave left this year before it",
              "%{count} days of this leave left this year before it",
              @leave["balance"]
            )}
          </span>
          <span :if={@leave["overlaps"] > 0} class="text-warning">
            <.icon name="hero-exclamation-triangle" class="size-4" />
            {gettext("Overlaps another leave")}
          </span>
          <span
            :if={@leave["unit"]}
            id="leave-unit-load"
            class={@leave["unit"].over? && "text-warning"}
          >
            <.icon :if={@leave["unit"].over?} name="hero-user-group" class="size-4" />
            {gettext("In the unit up to %{count} others away then (limit %{limit})",
              count: @leave["unit"].others_away,
              limit: @leave["unit"].limit
            )}
          </span>
          <span :if={(@leave["duties"] || 0) > 0} id="leave-duties" class="text-warning">
            <.icon name="hero-shield-exclamation" class="size-4" />
            {ngettext(
              "%{count} duty planned in these days",
              "%{count} duties planned in these days",
              @leave["duties"]
            )}
          </span>
        </div>

        <div :for={error <- @errors} role="alert" class="alert alert-error alert-soft text-sm">
          <.icon name="hero-exclamation-circle" class="size-5" />
          {error}
        </div>

        <section :if={@editable?} class="rounded-box border border-base-300 p-4">
          <form id="document-form" phx-change="validate" phx-submit="save">
            <JsonSchemaForm.json_schema_form
              schema={Types.schema(@document.type)}
              ui_schema={Types.ui_schema(@document.type)}
              values={@values}
              name="data"
              field_options={@field_options}
            />
            <button type="submit" class="btn btn-sm mt-3">
              <.icon name="hero-check" class="size-4" /> {gettext("Save draft")}
            </button>
          </form>
        </section>

        <section :if={not @editable?} class="rounded-box border border-base-300">
          <dl class="divide-y divide-base-200">
            <div :for={row <- @rows} class="grid grid-cols-1 gap-1 px-4 py-2 sm:grid-cols-3">
              <dt class="text-sm opacity-70">{row["label"]}</dt>
              <dd class="whitespace-pre-line break-words sm:col-span-2">{row["value"]}</dd>
            </div>
          </dl>
          <p :if={@rows == []} class="p-4 text-sm opacity-60">{gettext("No fields filled in.")}</p>
        </section>

        <.live_component
          :if={Types.files?(@document.type)}
          module={AppWeb.DocumentFilesComponent}
          id="document-files"
          document={@document}
          actor={@current_user}
          editable?={@editable?}
        />

        <section
          :if={@sections != []}
          id="certificate-sections"
          class="flex flex-col gap-3 rounded-box border border-base-300 p-4"
        >
          <h2 class="font-semibold">
            {if @document.state == :signed,
              do: gettext("The certificate states"),
              else: gettext("The certificate would state today")}
          </h2>
          <.certificate_section :for={section <- @sections} section={section} />
        </section>

        <section :if={@editable?} class="rounded-box border border-primary/40 bg-base-200/40 p-4">
          <div :if={@registers_directly?} class="flex flex-wrap items-center gap-2">
            <button
              id="register-button"
              type="button"
              phx-click="register"
              data-confirm={
                gettext("Register? The document gets its number and can no longer be changed.")
              }
              class="btn btn-primary btn-sm"
            >
              <.icon name="hero-inbox-arrow-down" class="size-4" /> {gettext("Register the letter")}
            </button>
            <button
              type="button"
              phx-click="cancel"
              data-confirm={gettext("Cancel this document?")}
              class="btn btn-ghost btn-sm"
            >
              {gettext("Cancel document")}
            </button>
          </div>
          <h2 :if={!@registers_directly?} class="mb-2 font-semibold">
            {gettext("Send for approval")}
          </h2>
          <form
            :if={!@registers_directly?}
            id="submit-form"
            phx-submit="submit"
            class="flex flex-col gap-3"
          >
            <div :for={{{entry, users}, i} <- Enum.with_index(@route)}>
              <p class="mb-1 text-sm font-medium">
                {AppWeb.SchemaText.translate(entry["label"])}
                <span class="opacity-60">
                  · {if entry["action"] == "sign", do: gettext("signs"), else: gettext("approves")}
                  <span :if={entry["parallel"]}>· {gettext("together, in any order")}</span>
                  <span :if={entry["optional"]}>· {gettext("optional")}</span>
                </span>
              </p>
              <select
                :if={entry["multiple"] != true}
                name={"step_#{i}"}
                class="select select-sm w-full"
              >
                <option value="">{gettext("— select —")}</option>
                <option :for={user <- users} value={user.id}>{user.name || user.email}</option>
              </select>
              <div :if={entry["multiple"] == true} class="flex flex-wrap gap-2">
                <label :for={user <- users} class="label cursor-pointer gap-2 text-sm">
                  <input
                    type="checkbox"
                    name={"step_#{i}[]"}
                    value={user.id}
                    class="checkbox checkbox-sm"
                  />
                  {user.name || user.email}
                </label>
              </div>
            </div>
            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary btn-sm">
                <.icon name="hero-paper-airplane" class="size-4" /> {gettext("Send")}
              </button>
              <button
                type="button"
                phx-click="cancel"
                data-confirm={gettext("Cancel this document?")}
                class="btn btn-ghost btn-sm"
              >
                {gettext("Cancel document")}
              </button>
            </div>
          </form>
        </section>

        <section :if={@round != []} class="rounded-box border border-base-300 p-4">
          <h2 class="mb-2 font-semibold">{gettext("Approval route")}</h2>
          <ol class="flex flex-col gap-2">
            <li :for={step <- @round} class="flex flex-wrap items-center gap-2 text-sm">
              <.step_icon status={step.status} />
              <span class="font-medium">{AppWeb.SchemaText.translate(step.label)}</span>
              <span
                :if={step.parallel}
                class="badge badge-xs badge-ghost"
                title={gettext("together, in any order")}
              >
                ∥
              </span>
              <span>{step.assignee && (step.assignee.name || step.assignee.email)}</span>
              <span :if={step.decided_by} class="opacity-70">
                ({gettext("decided by deputy %{name}",
                  name: step.decided_by.name || step.decided_by.email
                )})
              </span>
              <span :if={step.decided_at} class="opacity-60">
                {AppWeb.DateFormat.display_datetime(step.decided_at)}
              </span>
              <span :if={step.comment} class="w-full pl-7 italic opacity-80">«{step.comment}»</span>
            </li>
          </ol>

          <p :if={@for_assignee} id="deputy-note" class="mt-4 text-sm text-info">
            <.icon name="hero-user-plus" class="size-4" />
            {gettext("You decide as deputy for %{name}.",
              name: @for_assignee.name || @for_assignee.email
            )}
          </p>
          <form
            :if={@my_turn? or @for_assignee}
            id="decision-form"
            phx-submit="decide"
            class="mt-4 flex flex-col gap-2"
          >
            <label for="decision-comment" class="text-sm font-medium">{gettext("Comment")}</label>
            <textarea
              id="decision-comment"
              name="comment"
              rows="2"
              class="textarea textarea-sm w-full"
            ></textarea>
            <div class="flex flex-wrap gap-2">
              <button
                :if={@current.action == :approve}
                type="submit"
                name="decision"
                value="approve"
                class="btn btn-primary btn-sm"
              >
                <.icon name="hero-check" class="size-4" /> {gettext("Approve")}
              </button>
              <button
                :if={@current.action == :sign}
                type="submit"
                name="decision"
                value="sign"
                class="btn btn-primary btn-sm"
                data-confirm={
                  gettext("Sign? The document gets its number and can no longer be changed.")
                }
              >
                <.icon name="hero-pencil" class="size-4" /> {gettext("Sign")}
              </button>
              <button type="submit" name="decision" value="return" class="btn btn-ghost btn-sm">
                <.icon name="hero-arrow-uturn-left" class="size-4" /> {gettext("Return for rework")}
              </button>
            </div>
          </form>
        </section>

        <section
          :if={@document.state == :signed}
          class="rounded-box border border-success/40 p-4 text-sm"
        >
          <p>
            {if Types.registration_only?(@document.type),
              do:
                gettext("Registered by %{name} on %{date}.",
                  name:
                    @document.signed_by && (@document.signed_by.name || @document.signed_by.email),
                  date: AppWeb.DateFormat.display_datetime(@document.signed_at)
                ),
              else:
                gettext("Signed by %{name} on %{date}.",
                  name:
                    @document.signed_by && (@document.signed_by.name || @document.signed_by.email),
                  date: AppWeb.DateFormat.display_datetime(@document.signed_at)
                )}
          </p>
          <p :if={@document.case} id="document-case" class="mt-1">
            {gettext("Filed into case %{index} (%{title})",
              index: @document.case.index,
              title: @document.case.title
            )}
          </p>
          <p class="mt-1 break-all font-mono text-xs opacity-70">
            {gettext("Identifier")}: urn:uuid:{@document.id}<br />
            {gettext("Content SHA-256")}: {@document.content_sha256}<br />
            {gettext("PDF SHA-256")}: {@document.pdf_sha256}
          </p>
        </section>

        <.live_component
          :if={@document.state == :signed and Types.instructions?(@document.type)}
          module={AppWeb.InstructionsComponent}
          id="instructions"
          document={@document}
          actor={@current_user}
        />

        <div
          :if={
            @document.type == :personnel_order_business_trip and @document.state == :signed and
              @current_user.person_id == @document.person_id
          }
          class="flex"
        >
          <button id="trip-report-button" type="button" phx-click="trip_report" class="btn btn-sm">
            <.icon name="hero-receipt-percent" class="size-4" /> {gettext("Write the trip report")}
          </button>
        </div>

        <section :if={@acknowledge?} id="acknowledgement" class="flex flex-col gap-3 text-sm">
          <h2 class="flex items-center gap-2 font-semibold">
            {gettext("Acknowledgement")}
            <.field_description description={
              gettext(
                "The person this order is about confirms they have read it: themselves in the app, or HR or their commander records that it was read out to them or signed on paper."
              )
            } />
          </h2>

          <p :if={@acknowledgement} class="flex flex-wrap items-center gap-x-2">
            <.icon name="hero-check-circle" class="size-5 text-success" />
            {gettext("Acknowledged on %{date}",
              date: AppWeb.DateFormat.display(@acknowledgement.acknowledged_on)
            )}
            <span class="opacity-70">
              · {DocumentUI.acknowledgement_method(@acknowledgement.method)}
              <span :if={@acknowledgement.method != :self}>
                · {gettext("recorded by %{who}", who: @acknowledgement.recorded_by_email)}
              </span>
            </span>
            <span :if={@acknowledgement.note} class="w-full pl-7 italic opacity-80">
              «{@acknowledgement.note}»
            </span>
          </p>

          <p :if={is_nil(@acknowledgement)} class="flex items-center gap-2 text-warning">
            <.icon name="hero-clock" class="size-5" /> {gettext("Not acknowledged yet.")}
          </p>

          <button
            :if={@can_acknowledge?}
            id="acknowledge-button"
            type="button"
            phx-click="acknowledge"
            data-confirm={gettext("Confirm that you have read this order?")}
            class="btn btn-primary btn-sm self-start"
          >
            <.icon name="hero-check" class="size-4" /> {gettext("I have read this order")}
          </button>

          <form
            :if={@can_record?}
            id="record-acknowledgement-form"
            phx-submit="record_acknowledgement"
            class="flex flex-wrap items-end gap-2"
          >
            <label class="flex flex-col gap-1">
              <span class="text-xs opacity-70">{gettext("Date")}</span>
              <input
                type="date"
                name="acknowledgement[acknowledged_on]"
                value={Date.to_iso8601(Date.utc_today())}
                max={Date.to_iso8601(Date.utc_today())}
                class="input input-sm"
                required
              />
            </label>
            <label class="flex flex-col gap-1">
              <span class="text-xs opacity-70">{gettext("How")}</span>
              <select name="acknowledgement[method]" class="select select-sm">
                <option value="in_person">{DocumentUI.acknowledgement_method(:in_person)}</option>
                <option value="paper">{DocumentUI.acknowledgement_method(:paper)}</option>
              </select>
            </label>
            <label class="flex min-w-48 grow flex-col gap-1">
              <span class="text-xs opacity-70">{gettext("Note")}</span>
              <input
                type="text"
                name="acknowledgement[note]"
                maxlength="500"
                class="input input-sm w-full"
              />
            </label>
            <button type="submit" class="btn btn-sm">
              <.icon name="hero-pencil-square" class="size-4" /> {gettext("Record acknowledgement")}
            </button>
          </form>
        </section>

        <details class="rounded-box border border-base-300 px-4 py-2">
          <summary class="cursor-pointer text-sm font-medium">{gettext("History")}</summary>
          <ol class="mt-2 flex flex-col gap-1 text-sm">
            <li :for={event <- @document.events} class="flex flex-wrap gap-x-2">
              <span class="opacity-60">{AppWeb.DateFormat.display_datetime(event.inserted_at)}</span>
              <span class="font-medium">{event_label(event.action)}</span>
              <span>{event.actor_email || gettext("system")}</span>
              <span :if={event.comment} class="italic opacity-80">«{event.comment}»</span>
            </li>
          </ol>
        </details>
      </div>
    </Layouts.app>
    """
  end

  attr :section, :map, required: true

  defp certificate_section(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <h3 class="text-sm font-medium">{@section["title"]}</h3>
      <p :if={@section["rows"] == []} class="text-sm opacity-60">{@section["empty"] || "—"}</p>
      <dl
        :if={@section["rows"] != [] and is_nil(@section["header"])}
        class="divide-y divide-base-200 text-sm"
      >
        <div
          :for={[label, value] <- @section["rows"]}
          class="grid grid-cols-1 gap-1 py-1 sm:grid-cols-3"
        >
          <dt class="opacity-70">{label}</dt>
          <dd class="break-words sm:col-span-2">{value}</dd>
        </div>
      </dl>
      <div :if={@section["rows"] != [] and @section["header"]} class="overflow-x-auto">
        <table class="table table-xs">
          <thead>
            <tr>
              <th :for={h <- @section["header"]}>{h}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @section["rows"]}>
              <td :for={cell <- row}>{cell}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :status, :atom, required: true

  defp step_icon(assigns) do
    ~H"""
    <.icon
      name={
        case @status do
          :pending -> "hero-clock"
          :waiting -> "hero-ellipsis-horizontal-circle"
          :approved -> "hero-check-circle"
          :signed -> "hero-check-badge"
          :returned -> "hero-arrow-uturn-left"
          :cancelled -> "hero-x-circle"
        end
      }
      class={[
        "size-5",
        @status in [:approved, :signed] && "text-success",
        @status == :pending && "text-info",
        @status == :returned && "text-warning",
        @status in [:waiting, :cancelled] && "opacity-50"
      ]}
    />
    """
  end

  defp event_label(:created), do: gettext("Created")
  defp event_label(:submitted), do: gettext("Sent for approval")
  defp event_label(:approved), do: gettext("Approved")
  defp event_label(:returned), do: gettext("Returned")
  defp event_label(:signed), do: gettext("Signed")
  defp event_label(:cancelled), do: gettext("Cancelled")
  defp event_label(:effect_applied), do: gettext("Effect applied")
  defp event_label(:acknowledged), do: gettext("Acknowledged")
end
