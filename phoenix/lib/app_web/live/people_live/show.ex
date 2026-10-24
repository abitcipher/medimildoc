defmodule AppWeb.PeopleLive.Show do
  @moduledoc """
  A person's composed profile a form per data group, composed together. Identity,
  current position/manager/direct-reports, full assignment history (with
  inline edit/delete), and `PersonRecord`s grouped by kind (with inline
  edit/delete) — each kind rendered from its own JSON Schema/UI Schema
  (`App.People.PersonRecordSchema`). "Assign to a position" and "add a
  record" are both forms embedded on this one page rather than separate
  routes — that composition is the point.

  `PersonRecord.data` isn't a set of Ash attributes (see
  `AppWeb.JsonSchemaForm`'s moduledoc), so record create/update is built by
  hand against `Ash.Changeset.for_create/4`/`for_update/4` +
  `Ash.create/2`/`Ash.update/2` directly, not `AshPhoenix.Form` — errors are
  shown as a plain list rather than the full per-field `AshPhoenix.Form`
  treatment ("explicit over implicit": simpler than fighting the form
  abstraction for something it isn't a natural fit for).

  Deleting a `Person` can fail (FK violation) if they still have
  Assignments/PersonRecords — migrations don't cascade on purpose (losing
  someone's history silently on delete is the wrong default here); the
  error surfaces as a flash rather than a crash.

  Both embedded forms are always-visible sections, not `<details>`
  disclosures (see `AppWeb.OrganizationsLive.Index`'s moduledoc for why —
  confirmed live: a `phx-change` round-trip silently re-collapses an
  untracked `<details open>`, which would have hidden a record's own edit
  form the instant you typed into it).

  Every edit/delete control and both embedded forms are hidden for
  `:viewer` ( `AppWeb.Authz.can?(user, "people.write")`) — a `:viewer` still
  sees the full composed profile, just read-only. UI-only; the real gate
  is each resource's own Ash policy.

  added two more composed sections, same pattern as
  Assignments (plain `AshPhoenix.Form` — both `PersonIdentifier` and
  `IdentityDocument` are ordinary Ash-attribute resources, not
  `PersonRecord`'s polymorphic JSONB): national ID numbers and identity
  documents. `App.People.BiometricRecord` deliberately has no section
  here yet — no upload UI/storage backend exists, see its moduledoc.

  added the header's "PersonID" line — display only,
  `Person.person_id` is fully server-generated (see `App.People.PersonId`),
  nothing here writes to it.

  (UI-kit adoption): the identifiers table's `is_current`
  column now renders via `daisy_ui_components`'s `<.badge>` instead of
  plain "yes"/"no" text — available here through `AppWeb`'s
  `html_helpers` (`use DaisyUIComponents, core_components: false`), not
  a per-file import.

  extended `Cinder.collection` here too, for the
  `PersonRecord` list — real filter/sort on `kind`/`recorded_at`
  matters once a person's accumulated years of records across 9+ kinds
  (whole "modular growth" premise). Scoped to this one person via
  `query={Ash.Query.filter(PersonRecord, person_id == ^person.id)}`
  (computed once in `mount/3`, not `resource={PersonRecord}` — that
  would list every person's records). `data` itself (polymorphic JSONB)
  gets a plain unfiltered/unsortable display column — same reasoning as
  every other kind-specific field in this domain, nothing generic to
  filter it by. The create/edit form below the table is untouched
  (still hand-rolled against `Ash.Changeset.for_create/4`/`for_update/4`
  directly, per this moduledoc's own note above on why — that was never
  a Cinder concern to begin with, only the read-side list was).

  Writing this page's first connected-`LiveView` test surfaced
  a real, pre-existing bug unrelated to Cinder: every `AshPhoenix.Form.
  for_create/for_update` call on this page (`assignment_form`/
  `identifier_form`/`document_form` and their `_edit_form` counterparts)
  omitted `:id`, so every one of them defaulted to the same form id
  (`"form"`) — the two always-visible create forms sharing a field name
  (`identifier_form`'s and `document_form`'s `expires_on`) then rendered
  the exact same DOM id (`form_expires_on`) on the same page at once.
  Never triggered in practice before this test existed to render the
  whole page with every section's form live at the same time; would
  have caused the two fields' morphdom patching to target each other
  unpredictably in a real browser. Fixed by passing a distinct `id:` to
  each `for_create`/`for_update` call — **not** to the later
  `to_form/2`: confirmed by reading `AshPhoenix.Form`'s own
  `Phoenix.HTML.FormData` implementation that it always uses `form.id`
  (set once, at `for_create`/`for_update` time) and ignores whatever
  `:id` a later `to_form(form, id: ...)` call passes — the first fix
  attempt here did exactly that and silently didn't work.
  """
  use AppWeb, :live_view

  require Ash.Query

  alias App.People.{
    Assignment,
    IdentityDocument,
    Person,
    PersonId,
    PersonIdentifier,
    PersonRecord,
    PersonRecordSchema,
    Position
  }

  alias App.Access.RecordAccess
  alias AppWeb.Components.Tabs, as: MishkaTabs

  alias AppWeb.{
    EmergencyAccessUI,
    PersonListSections,
    PersonSummary,
    RecordComponents
  }

  # Only ever read in plain Elixir code (Cinder.refresh_table/2 calls
  # below) — the matching `id="records-table"` on `<Cinder.collection>`
  # in render/1 is a literal string, not `@table_id`, on purpose: `@foo`
  # inside `~H` always means a socket assign, never a module attribute
  # of the same name, even in the same module (caught live the first
  # time this mistake was made).
  @records_table_id "records-table"

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    actor = socket.assigns.current_user
    person = load_person(id, actor)

    {:ok,
     socket
     |> assign(:actor, actor)
     |> assign(:page_title, Person.full_name(person))
     # Not gettext-wrapped — a person's own name isn't UI copy to translate.
     |> assign(:person, person)
     |> assign(:manager, App.People.current_manager(person, actor: actor))
     |> assign(:direct_reports, AppWeb.PersonRows.direct_reports(person, actor))
     |> assign(:summary, PersonSummary.summary_records(person, actor))
     |> assign_emergency(person, actor)
     |> assign(:btg_form_open, false)
     |> assign(:records_category, :all)
     |> assign(:readable_categories, readable_categories(actor))
     |> assign(:kind_picker_open, false)
     |> assign(:records_query, records_query(person, :all))
     |> assign(:editing_assignment_id, nil)
     |> assign(:assignment_edit_form, nil)
     # Which "New …" form is open (docs/design/ui-preferences.md):
     # "assignment", "identifier", "identity_document" or nil.
     |> assign(:creating, nil)
     |> assign_new_assignment_form()
     |> assign(:record_kind, nil)
     |> assign(:part_of_options, [])
     |> assign(:record_part_of, nil)
     |> assign(:record_data, %{})
     |> assign(:record_errors, [])
     |> assign(:editing_record_id, nil)
     # National IDs and documents are private data (people.private.read,
     # docs/design/access-control-phase1.md): without it the Identity
     # tab isn't rendered and nothing is queried.
     |> assign(:can_read_private, AppWeb.Authz.can?(actor, "people.private.read"))
     # Record kinds this actor may create, edit and delete — each kind's
     # category needs its own write permission (docs/design/
     # access-control-phase1.md). Reads are filtered by the resource
     # policy itself, so the table only ever shows readable kinds.
     |> assign(:writable_kinds, RecordAccess.writable_kinds(actor))
     |> assign(:photo_url, photo_url(person, actor))
     |> assign(:can_write_photo, AppWeb.Authz.can?(actor, "people.write"))
     |> assign(:can_write_person_files, AppWeb.Authz.can?(actor, "people.private.write"))
     |> assign(:identifiers, load_identifiers(person, actor))
     |> assign(:editing_identifier_id, nil)
     |> assign(:identifier_edit_form, nil)
     |> assign_new_identifier_form()
     |> assign(:documents, load_documents(person, actor))
     |> assign(:editing_document_id, nil)
     |> assign(:document_edit_form, nil)
     |> assign_new_document_form()}
  end

  defp load_person(id, actor) do
    Ash.get!(Person, id,
      actor: actor,
      load: [
        :account,
        # The orders behind each assignment (read through their policy:
        # nil when the viewer may not read orders).
        assignments: [position: :organization, basis_document: [], end_document: []]
      ]
    )
  end

  defp load_identifiers(person, actor) do
    if AppWeb.Authz.can?(actor, "people.private.read"),
      do: read_identifiers(person, actor),
      else: []
  end

  defp read_identifiers(person, actor) do
    PersonIdentifier
    |> Ash.Query.filter(person_id == ^person.id)
    |> Ash.Query.sort(inserted_at: :desc)
    # Encrypted; decrypted (and access-logged) only because it is shown.
    |> Ash.Query.load(:value)
    |> Ash.read!(actor: actor)
  end

  defp load_documents(person, actor) do
    if AppWeb.Authz.can?(actor, "people.private.read"),
      do: read_documents(person, actor),
      else: []
  end

  defp read_documents(person, actor) do
    IdentityDocument
    |> Ash.Query.filter(person_id == ^person.id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.load(:number)
    |> Ash.read!(actor: actor)
  end

  defp assign_new_assignment_form(socket) do
    %{actor: actor, person: person} = socket.assigns

    positions =
      Position
      |> Ash.Query.load(
        organization: [],
        assignments: Assignment |> Ash.Query.filter(is_nil(ends_on)) |> Ash.Query.load(:person)
      )
      |> Ash.read!(actor: actor)

    form =
      Assignment
      |> AshPhoenix.Form.for_create(:create,
        actor: actor,
        params: %{"person_id" => person.id},
        id: "assignment-form"
      )
      |> to_form()

    socket
    |> assign(:assignment_form, form)
    |> assign(:position_options, AppWeb.PositionOptions.grouped(positions))
  end

  defp assign_new_identifier_form(socket) do
    %{actor: actor, person: person} = socket.assigns

    form =
      PersonIdentifier
      |> AshPhoenix.Form.for_create(:create,
        actor: actor,
        params: %{"person_id" => person.id},
        id: "identifier-form"
      )
      |> to_form()

    assign(socket, :identifier_form, form)
  end

  defp assign_new_document_form(socket) do
    %{actor: actor, person: person} = socket.assigns

    form =
      IdentityDocument
      |> AshPhoenix.Form.for_create(:create,
        actor: actor,
        params: %{"person_id" => person.id},
        id: "document-form"
      )
      |> to_form()

    assign(socket, :document_form, form)
  end

  ## Person delete

  @impl true
  def handle_event("delete_person", _params, socket) do
    case Ash.destroy(socket.assigns.person, actor: socket.assigns.actor) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Person deleted"))
         |> push_navigate(to: ~p"/people")}

      {:error, error} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Could not delete %{name}: still has assignments or records — remove those first (%{reason})",
             name: socket.assigns.person.given_name,
             reason: App.AshErrors.summarize(error)
           )
         )}
    end
  end

  ## "New …" forms opened by their control (docs/design/ui-preferences.md)

  def handle_event("open_create", %{"form" => form}, socket)
      when form in ~w(assignment identifier identity_document) do
    {:noreply,
     assign(socket,
       creating: form,
       editing_assignment_id: nil,
       editing_identifier_id: nil,
       editing_document_id: nil
     )}
  end

  def handle_event("close_create", _params, socket),
    do: {:noreply, assign(socket, :creating, nil)}

  ## Assignments — create

  def handle_event("validate_assignment", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.assignment_form, params)
    {:noreply, assign(socket, :assignment_form, form)}
  end

  def handle_event("save_assignment", %{"form" => params}, socket) do
    %{actor: actor, person: person} = socket.assigns
    # person_id isn't a visible field (it's implicit — this is *this*
    # person's assignment form) — set it explicitly regardless of whatever
    # the earlier for_create seed did, so submit never depends on that.
    params = Map.put(params, "person_id", person.id)

    case AshPhoenix.Form.submit(socket.assigns.assignment_form, params: params, actor: actor) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Assignment created"))
         |> push_navigate(to: ~p"/people/#{person.id}")}

      {:error, form} ->
        {:noreply, assign(socket, :assignment_form, form)}
    end
  end

  ## Assignments — inline edit/delete

  def handle_event("edit_assignment", %{"id" => id}, socket) do
    assignment = Enum.find(socket.assigns.person.assignments, &(&1.id == id))

    form =
      assignment
      |> AshPhoenix.Form.for_update(:update,
        actor: socket.assigns.actor,
        id: "assignment-edit-form"
      )
      |> to_form()

    {:noreply,
     assign(socket, editing_assignment_id: id, assignment_edit_form: form, creating: nil)}
  end

  def handle_event("cancel_edit_assignment", _params, socket) do
    {:noreply, assign(socket, editing_assignment_id: nil, assignment_edit_form: nil)}
  end

  def handle_event("validate_assignment_edit", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.assignment_edit_form, params)
    {:noreply, assign(socket, :assignment_edit_form, form)}
  end

  def handle_event("save_assignment_edit", %{"form" => params}, socket) do
    %{actor: actor, person: person} = socket.assigns

    case AshPhoenix.Form.submit(socket.assigns.assignment_edit_form, params: params, actor: actor) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Assignment updated"))
         |> assign(
           person: load_person(person.id, actor),
           editing_assignment_id: nil,
           assignment_edit_form: nil
         )}

      {:error, form} ->
        {:noreply, assign(socket, :assignment_edit_form, form)}
    end
  end

  def handle_event("delete_assignment", %{"id" => id}, socket) do
    %{actor: actor, person: person} = socket.assigns
    assignment = Enum.find(person.assignments, &(&1.id == id))

    case Ash.destroy(assignment, actor: actor) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Assignment removed"))
         |> assign(:person, load_person(person.id, actor))
         |> assign_new_assignment_form()}

      {:error, error} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not remove assignment: %{reason}",
             reason: App.AshErrors.summarize(error)
           )
         )}
    end
  end

  ## PersonIdentifier — create

  def handle_event("validate_identifier", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.identifier_form, params)
    {:noreply, assign(socket, :identifier_form, form)}
  end

  def handle_event("save_identifier", %{"form" => params}, socket) do
    %{actor: actor, person: person} = socket.assigns
    params = Map.put(params, "person_id", person.id)

    case AshPhoenix.Form.submit(socket.assigns.identifier_form, params: params, actor: actor) do
      {:ok, _identifier} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Identifier added"))
         |> assign(:creating, nil)
         |> assign(:identifiers, load_identifiers(person, actor))
         |> assign_new_identifier_form()}

      {:error, form} ->
        {:noreply, assign(socket, :identifier_form, form)}
    end
  end

  ## PersonIdentifier — inline edit/delete

  def handle_event("edit_identifier", %{"id" => id}, socket) do
    identifier = Enum.find(socket.assigns.identifiers, &(&1.id == id))

    form =
      identifier
      |> AshPhoenix.Form.for_update(:update,
        actor: socket.assigns.actor,
        id: "identifier-edit-form"
      )
      |> to_form()

    {:noreply,
     assign(socket, editing_identifier_id: id, identifier_edit_form: form, creating: nil)}
  end

  def handle_event("cancel_edit_identifier", _params, socket) do
    {:noreply, assign(socket, editing_identifier_id: nil, identifier_edit_form: nil)}
  end

  def handle_event("validate_identifier_edit", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.identifier_edit_form, params)
    {:noreply, assign(socket, :identifier_edit_form, form)}
  end

  def handle_event("save_identifier_edit", %{"form" => params}, socket) do
    %{actor: actor, person: person} = socket.assigns

    case AshPhoenix.Form.submit(socket.assigns.identifier_edit_form, params: params, actor: actor) do
      {:ok, _identifier} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Identifier updated"))
         |> assign(
           identifiers: load_identifiers(person, actor),
           editing_identifier_id: nil,
           identifier_edit_form: nil
         )}

      {:error, form} ->
        {:noreply, assign(socket, :identifier_edit_form, form)}
    end
  end

  def handle_event("delete_identifier", %{"id" => id}, socket) do
    %{actor: actor, person: person, identifiers: identifiers} = socket.assigns
    identifier = Enum.find(identifiers, &(&1.id == id))

    case Ash.destroy(identifier, actor: actor) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Identifier removed"))
         |> assign(:identifiers, load_identifiers(person, actor))}

      {:error, error} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not remove identifier: %{reason}",
             reason: App.AshErrors.summarize(error)
           )
         )}
    end
  end

  ## IdentityDocument — create

  def handle_event("validate_document", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.document_form, params)
    {:noreply, assign(socket, :document_form, form)}
  end

  def handle_event("save_document", %{"form" => params}, socket) do
    %{actor: actor, person: person} = socket.assigns
    params = Map.put(params, "person_id", person.id)

    case AshPhoenix.Form.submit(socket.assigns.document_form, params: params, actor: actor) do
      {:ok, _document} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Document added"))
         |> assign(:creating, nil)
         |> assign(:documents, load_documents(person, actor))
         |> assign_new_document_form()}

      {:error, form} ->
        {:noreply, assign(socket, :document_form, form)}
    end
  end

  ## IdentityDocument — inline edit/delete

  def handle_event("edit_document", %{"id" => id}, socket) do
    document = Enum.find(socket.assigns.documents, &(&1.id == id))

    form =
      document
      |> AshPhoenix.Form.for_update(:update,
        actor: socket.assigns.actor,
        id: "document-edit-form"
      )
      |> to_form()

    {:noreply, assign(socket, editing_document_id: id, document_edit_form: form, creating: nil)}
  end

  def handle_event("cancel_edit_document", _params, socket) do
    {:noreply, assign(socket, editing_document_id: nil, document_edit_form: nil)}
  end

  def handle_event("validate_document_edit", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.document_edit_form, params)
    {:noreply, assign(socket, :document_edit_form, form)}
  end

  def handle_event("save_document_edit", %{"form" => params}, socket) do
    %{actor: actor, person: person} = socket.assigns

    case AshPhoenix.Form.submit(socket.assigns.document_edit_form, params: params, actor: actor) do
      {:ok, _document} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Document updated"))
         |> assign(
           documents: load_documents(person, actor),
           editing_document_id: nil,
           document_edit_form: nil
         )}

      {:error, form} ->
        {:noreply, assign(socket, :document_edit_form, form)}
    end
  end

  def handle_event("delete_document", %{"id" => id}, socket) do
    %{actor: actor, person: person, documents: documents} = socket.assigns
    document = Enum.find(documents, &(&1.id == id))

    case Ash.destroy(document, actor: actor) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Document removed"))
         |> assign(:documents, load_documents(person, actor))}

      {:error, error} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not remove document: %{reason}", reason: App.AshErrors.summarize(error))
         )}
    end
  end

  ## Records — create

  # Only kinds offered to this actor are accepted; anything else from the
  # client is ignored rather than turned into an atom.
  # Break the Glass (docs/design/access-control-phase2.md).
  def handle_event("toggle_btg_form", _params, socket) do
    {:noreply, assign(socket, :btg_form_open, !socket.assigns.btg_form_open)}
  end

  def handle_event("invoke_btg", %{"reason" => reason}, socket) do
    %{person: person, actor: actor} = socket.assigns

    case EmergencyAccessUI.invoke(person, actor, reason) do
      {:ok, _grant} ->
        {:noreply,
         socket
         |> assign(:btg_form_open, false)
         |> assign_emergency(person, actor)
         |> refresh_records()
         |> put_flash(:info, gettext("Emergency access granted. Every view is logged."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, App.AshErrors.summarize(error))}
    end
  end

  def handle_event("toggle_kind_picker", _params, socket) do
    {:noreply, assign(socket, :kind_picker_open, !socket.assigns.kind_picker_open)}
  end

  # Category chips (docs/design/ui-plan.md item 2). Only categories the
  # actor may read are accepted; the query change makes Cinder reload.
  def handle_event("filter_records", %{"category" => value}, socket) do
    %{person: person, readable_categories: readable} = socket.assigns

    category =
      if value == "all",
        do: :all,
        else: Enum.find(readable, :all, &(Atom.to_string(&1) == value))

    {:noreply,
     socket
     |> assign(:records_category, category)
     |> assign(:records_query, records_query(person, category))}
  end

  def handle_event("select_record_kind", %{"kind" => kind}, socket) do
    case Enum.find(socket.assigns.writable_kinds, &(Atom.to_string(&1) == kind)) do
      nil ->
        {:noreply, socket}

      kind ->
        %{person: person, actor: actor} = socket.assigns

        {:noreply,
         assign(socket,
           record_kind: kind,
           record_data: %{},
           record_errors: [],
           editing_record_id: nil,
           kind_picker_open: false,
           part_of_options: RecordComponents.part_of_options(person, kind, actor),
           record_part_of: nil
         )}
    end
  end

  def handle_event("validate_record", params, socket) do
    # "record_data" is missing on the very first change to a form with only
    # text inputs and no prior value — nothing to merge in then. The
    # "part of" choice is kept too, or the next re-render resets the select.
    socket =
      case params do
        %{"record_data" => data} -> assign(socket, :record_data, data)
        _ -> socket
      end

    {:noreply, assign(socket, :record_part_of, blank_to_nil(params["record_part_of"]))}
  end

  def handle_event("save_record", %{"record_data" => data} = params, socket) do
    %{record_kind: kind, person: person, actor: actor, editing_record_id: editing_id} =
      socket.assigns

    # Vital signs within an encounter (docs/design/clinical-module.md).
    socket = assign(socket, :record_part_of, blank_to_nil(params["record_part_of"]))

    # PersonRecordSchema.normalize/2 — an <input
    # type="number"> left blank submits "", not an absent key; strip those
    # before validating/persisting so an optional numeric field left empty
    # doesn't get rejected as a type mismatch.
    data = PersonRecordSchema.normalize(kind, data)

    case PersonRecordSchema.validate(kind, data) do
      :ok when is_nil(editing_id) -> create_record(socket, kind, person, actor, data)
      :ok -> update_record(socket, editing_id, person, actor, data)
      {:error, errors} -> {:noreply, assign(socket, :record_errors, errors)}
    end
  end

  ## Records — inline edit/delete

  def handle_event("edit_record", %{"id" => id}, socket) do
    record = Ash.get!(PersonRecord, id, actor: socket.assigns.actor)

    {:noreply,
     assign(socket,
       editing_record_id: id,
       record_kind: record.kind,
       record_data: record.data,
       record_errors: [],
       kind_picker_open: false,
       part_of_options:
         RecordComponents.part_of_options(
           socket.assigns.person,
           record.kind,
           socket.assigns.actor
         ),
       record_part_of: record.part_of_id
     )}
  end

  def handle_event("cancel_edit_record", _params, socket) do
    {:noreply,
     assign(socket, editing_record_id: nil, record_kind: nil, record_data: %{}, record_errors: [])}
  end

  def handle_event("delete_record", %{"id" => id}, socket) do
    %{actor: actor} = socket.assigns
    record = Ash.get!(PersonRecord, id, actor: actor)

    case Ash.destroy(record, actor: actor) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Record removed"))
         |> refresh_records()}

      {:error, error} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not remove record: %{reason}", reason: App.AshErrors.summarize(error))
         )}
    end
  end

  ## Records — private helpers (kept together, after all handle_event/3
  ## clauses so the latter stay grouped per the compiler's warning).

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp create_record(socket, kind, person, actor, data) do
    PersonRecord
    |> Ash.Changeset.for_create(
      :create,
      %{person_id: person.id, kind: kind, data: data, part_of_id: socket.assigns.record_part_of},
      actor: actor
    )
    |> Ash.create(actor: actor)
    |> case do
      {:ok, _record} ->
        {:noreply, after_record_save(socket, gettext("Record added"))}

      {:error, error} ->
        {:noreply, assign(socket, :record_errors, [App.AshErrors.summarize(error)])}
    end
  end

  defp update_record(socket, record_id, _person, actor, data) do
    record_id
    |> then(&Ash.get!(PersonRecord, &1, actor: actor))
    |> Ash.Changeset.for_update(
      :update,
      %{data: data, part_of_id: socket.assigns.record_part_of},
      actor: actor
    )
    |> Ash.update(actor: actor)
    |> case do
      {:ok, _record} ->
        {:noreply, after_record_save(socket, gettext("Record updated"))}

      {:error, error} ->
        {:noreply, assign(socket, :record_errors, [App.AshErrors.summarize(error)])}
    end
  end

  defp after_record_save(socket, flash_message) do
    socket
    |> put_flash(:info, flash_message)
    |> assign(
      record_kind: nil,
      record_data: %{},
      record_errors: [],
      editing_record_id: nil
    )
    |> refresh_records()
  end

  # From AppWeb.PersonFilesComponent: the portrait or record files changed.
  @impl true
  def handle_info({:files_changed, _person_id}, socket) do
    %{person: person, actor: actor} = socket.assigns

    {:noreply,
     socket
     |> assign(:photo_url, photo_url(person, actor))
     |> refresh_records()}
  end

  defp photo_url(person, actor), do: AppWeb.PersonRows.photo_url(person, actor)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-4xl flex-col gap-6 p-4">
        <header class="flex flex-wrap items-start gap-4">
          <img
            :if={@photo_url}
            src={@photo_url}
            alt={gettext("Photo of %{name}", name: Person.full_name(@person))}
            class="size-12 shrink-0 rounded-full object-cover sm:size-14"
          />
          <span
            :if={!@photo_url}
            aria-hidden="true"
            class={[
              "inline-flex size-12 shrink-0 items-center justify-center rounded-full text-lg font-medium text-white sm:size-14 sm:text-xl",
              AppWeb.HeaderControls.avatar_color(%{email: @person.email || @person.id})
            ]}
          >
            {AppWeb.HeaderControls.initials(%{name: Person.full_name(@person), email: @person.id})}
          </span>
          <div class="min-w-0 flex-1 basis-60">
            <h1 class="flex flex-wrap items-center gap-2 text-xl font-semibold">
              {Person.full_name(@person)} <.synthetic_badge :if={@person.synthetic} />
            </h1>
            <p class="flex items-center gap-1 text-sm opacity-80">
              <.icon name="hero-briefcase" class="size-4 shrink-0" />
              <%= if current = current_assignment(@person) do %>
                <AppWeb.PersonBadges.position position={
                  AppWeb.PersonRows.position_summary(current.position)
                } />
                <span class="truncate">{current.position.organization.name}</span>
              <% else %>
                <span>{gettext("No current assignment.")}</span>
              <% end %>
            </p>
            <p class="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-xs opacity-70">
              <span :if={@person.email} class="flex items-center gap-1">
                <.icon name="hero-envelope" class="size-3.5" />{@person.email}
              </span>
              <span
                :if={born?(@person)}
                class="tooltip tooltip-bottom flex items-center gap-1"
                data-tip={gettext("Date and place of birth")}
              >
                <.icon name="hero-cake" class="size-3.5" />
                {AppWeb.DateFormat.display(@person.date_of_birth)}
                {birth_place(@person)}
                <.country :if={@person.birth_country} code={@person.birth_country} />
              </span>
              <span
                :if={@person.account}
                class="tooltip tooltip-bottom flex items-center gap-1"
                data-tip={gettext("Sign-in account linked to this person")}
              >
                <.icon name="hero-key" class="size-3.5" />{@person.account.email}
              </span>
              <span
                class="tooltip tooltip-bottom flex items-center gap-1 font-mono"
                data-tip={gettext("Secondary identifier — not the record's real key")}
              >
                <.icon name="hero-finger-print" class="size-3.5" />
                {PersonId.format(@person.person_id)}
              </span>
            </p>
            <div class="mt-3">
              <PersonSummary.status_chips summary={@summary} />
            </div>
          </div>
          <div :if={AppWeb.Authz.can?(@current_user, "people.write")} class="flex shrink-0 gap-2">
            <.link
              navigate={~p"/people/#{@person.id}/edit"}
              class="btn btn-sm btn-ghost border border-base-300"
            >
              <.icon name="hero-pencil-square" class="size-4" />
              {gettext("Edit")}
            </.link>
            <button
              type="button"
              phx-click="delete_person"
              data-confirm={
                gettext("Delete %{name}? This cannot be undone.", name: Person.full_name(@person))
              }
              class="btn btn-sm btn-ghost text-error"
            >
              <.icon name="hero-trash" class="size-4" />
              {gettext("Delete")}
            </button>
          </div>
        </header>

        <EmergencyAccessUI.banner :if={@emergency} emergency={@emergency} />
        <EmergencyAccessUI.request_form :if={@btg_available} open={@btg_form_open} />

        <MishkaTabs.tabs id="person-tabs" variant="pills" color="primary" scrollable>
          <:tab icon="hero-briefcase" active>{gettext("Assignments")}</:tab>
          <:tab :if={@can_read_private} icon="hero-identification">{gettext("Identity")}</:tab>
          <:tab icon="hero-clipboard-document-list">{gettext("Records")}</:tab>
          <:tab icon="hero-paper-clip">{gettext("Files")}</:tab>
          <:tab icon="hero-document-text">{gettext("Documents")}</:tab>
          <:tab icon="hero-clock">{gettext("Timeline")}</:tab>

          <:panel>
            <section class="mb-6">
              <h2 class="mb-2 font-semibold">{gettext("Current position")}</h2>
              <dl class="grid grid-cols-1 gap-3 rounded-box border border-base-300 p-3 text-sm sm:grid-cols-2">
                <div>
                  <dt class="text-xs opacity-70">{gettext("Position")}</dt>
                  <dd>
                    <%= if current = current_assignment(@person) do %>
                      <AppWeb.PersonBadges.position position={
                        AppWeb.PersonRows.position_summary(current.position)
                      } />
                      <span class="mt-1 block opacity-80">{current.position.organization.name}</span>
                      <span class="block text-xs opacity-70">
                        {gettext("since %{date}", date: AppWeb.DateFormat.display(current.starts_on))}
                      </span>
                    <% else %>
                      <span class="opacity-75">{gettext("No current assignment.")}</span>
                    <% end %>
                  </dd>
                </div>
                <div>
                  <dt class="text-xs opacity-70">{gettext("Reports to")}</dt>
                  <dd>
                    <.link
                      :if={@manager}
                      navigate={~p"/people/#{@manager.id}"}
                      class="link link-hover"
                    >
                      {Person.full_name(@manager)}
                    </.link>
                    <span :if={!@manager} class="opacity-60">—</span>
                  </dd>
                </div>
              </dl>
            </section>

            <section :if={@direct_reports != []} class="mb-6" aria-labelledby="direct-reports-heading">
              <h2 id="direct-reports-heading" class="mb-2 flex items-center gap-2 font-semibold">
                {gettext("Direct reports")}
                <span class="badge badge-sm badge-ghost">{length(@direct_reports)}</span>
              </h2>
              <.live_component
                module={AppWeb.PeopleListComponent}
                id="direct-reports"
                rows={@direct_reports}
              />
            </section>

            <PersonListSections.assignments
              person={@person}
              current_user={@current_user}
              creating={@creating}
              editing_assignment_id={@editing_assignment_id}
              assignment_edit_form={@assignment_edit_form}
              assignment_form={@assignment_form}
              position_options={@position_options}
            />
          </:panel>

          <:panel :if={@can_read_private}>
            <PersonListSections.identity
              current_user={@current_user}
              creating={@creating}
              identifiers={@identifiers}
              editing_identifier_id={@editing_identifier_id}
              identifier_edit_form={@identifier_edit_form}
              identifier_form={@identifier_form}
              documents={@documents}
              editing_document_id={@editing_document_id}
              document_edit_form={@document_edit_form}
              document_form={@document_form}
            />
          </:panel>

          <:panel>
            <section class="flex flex-col gap-3">
              <div class="flex flex-wrap items-center gap-2">
                <h2 class="mr-1 font-semibold">{gettext("Records")}</h2>
                <div
                  role="group"
                  aria-label={gettext("Show records of category")}
                  class="flex flex-wrap gap-1"
                >
                  <button
                    type="button"
                    phx-click="filter_records"
                    phx-value-category="all"
                    aria-pressed={to_string(@records_category == :all)}
                    class={category_chip_class(@records_category == :all)}
                  >
                    {gettext("All")}
                  </button>
                  <button
                    :for={category <- @readable_categories}
                    type="button"
                    phx-click="filter_records"
                    phx-value-category={category}
                    aria-pressed={to_string(@records_category == category)}
                    class={category_chip_class(@records_category == category)}
                  >
                    <.icon name={RecordComponents.category_icon(category)} class="size-3.5" />
                    {RecordComponents.category_label(category)}
                  </button>
                </div>
                <button
                  :if={@writable_kinds != [] and is_nil(@record_kind)}
                  type="button"
                  phx-click="toggle_kind_picker"
                  aria-expanded={to_string(@kind_picker_open)}
                  aria-controls="record-kind-picker"
                  class="btn btn-primary btn-sm ml-auto"
                >
                  <.icon
                    name={if @kind_picker_open, do: "hero-x-mark", else: "hero-plus"}
                    class="size-4"
                  />
                  {if @kind_picker_open, do: gettext("Close"), else: gettext("Add record")}
                </button>
              </div>

              <div
                :if={@kind_picker_open}
                id="record-kind-picker"
                class="rounded-box border border-base-300 p-3"
              >
                <p class="mb-3 text-sm opacity-70">{gettext("What kind of record?")}</p>
                <RecordComponents.kind_picker kinds={@writable_kinds} />
              </div>

              <RecordComponents.record_form_panel
                kind={@record_kind}
                editing?={@editing_record_id != nil}
                prefs={@current_user.ui_preferences}
                part_of_options={@part_of_options}
                part_of={@record_part_of}
                data={@record_data}
                errors={@record_errors}
                allergies={@summary.allergies}
              />

              <div :if={@summary.vitals != []} class="mb-3">
                <RecordComponents.vitals_panel vitals={@summary.vitals} />
              </div>

              <.top_pager id="records-table">
                <Cinder.collection
                  id="records-table"
                  query={@records_query}
                  actor={@current_user}
                  layout={:list}
                  show_filters={false}
                  theme={AppWeb.Cinder.RecordListTheme}
                >
                  <:item :let={record}>
                    <RecordComponents.record_card
                      record={record}
                      writable={record.kind in @writable_kinds}
                    />
                  </:item>
                </Cinder.collection>
              </.top_pager>
            </section>
          </:panel>

          <:panel>
            <.live_component
              module={AppWeb.PersonFilesComponent}
              id="person-files"
              person={@person}
              actor={@actor}
              writable_kinds={@writable_kinds}
              photo?={@can_write_photo}
              person_files?={@can_write_person_files}
            />
          </:panel>

          <:panel>
            <.live_component
              module={AppWeb.PersonDocumentsComponent}
              id="person-documents-tab"
              person={@person}
              actor={@actor}
            />
          </:panel>

          <:panel>
            <.live_component
              module={AppWeb.PersonTimelineComponent}
              id="person-timeline"
              person={@person}
              actor={@actor}
            />
          </:panel>
        </MishkaTabs.tabs>
      </div>
    </Layouts.app>
    """
  end

  defp records_query(person, :all) do
    PersonRecord
    |> Ash.Query.filter(person_id == ^person.id)
    |> Ash.Query.sort(recorded_at: :desc)
    # Files on each record, through the attachments' own read policy, and
    # the record it belongs to (vital signs within an encounter).
    |> Ash.Query.load([:attachments, :part_of])
  end

  defp records_query(person, category) do
    kinds = PersonRecordSchema.kinds_in_category(category)
    person |> records_query(:all) |> Ash.Query.filter(kind in ^kinds)
  end

  # Categories with at least one kind the actor may read, in display order.
  defp readable_categories(actor) do
    readable = RecordAccess.readable_kinds(actor)

    Enum.filter(RecordComponents.categories(), fn category ->
      Enum.any?(PersonRecordSchema.kinds_in_category(category), &(&1 in readable))
    end)
  end

  defp category_chip_class(active?) do
    [
      "btn btn-xs rounded-full gap-1",
      if(active?, do: "btn-primary", else: "btn-ghost border border-base-300")
    ]
  end

  # After a record changes: reload the list and the header status chips.
  defp refresh_records(socket) do
    %{person: person, actor: actor} = socket.assigns

    socket
    |> assign(:summary, PersonSummary.summary_records(person, actor))
    |> Cinder.refresh_table(@records_table_id)
  end

  defp current_assignment(person), do: Enum.find(person.assignments, &is_nil(&1.ends_on))

  defp assign_emergency(socket, person, actor) do
    {active, available?} = EmergencyAccessUI.state(person, actor)

    socket
    |> assign(:emergency, active)
    |> assign(:btg_available, available?)
  end

  defp born?(person) do
    Enum.any?(
      [person.date_of_birth, person.birth_locality, person.birth_region, person.birth_country],
      &(&1 not in [nil, ""])
    )
  end

  # "Kyiv, Kyiv Oblast" — the country follows as a flag and name.
  defp birth_place(person) do
    [person.birth_locality, person.birth_region]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
  end
end
