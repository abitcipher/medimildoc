defmodule App.Audit.AccessLogger do
  @moduledoc """
  AshCloak `on_decrypt` hook (docs/design/access-control-phase1.md):
  called whenever an encrypted field is about to be decrypted, before the
  value is returned. Writes one `App.Audit.AccessLog` row per sensitive
  record for the reading actor.

  - **Fails closed:** if the log rows can't be written, decryption is
    refused, so no sensitive value is ever shown without its log entry.
  - **What counts as sensitive:** every `PersonIdentifier` and
    `IdentityDocument`, and `PersonRecord`s and documents whose kind or
    type is in a sensitive category (`@sensitive_categories`). Ordinary personnel records (rank,
    contact details, languages) are not logged.
  - **Reads without an actor are not logged:** maintenance tasks
    (`App.Encryption`, `App.Demo`) and remote-console reads run with
    `authorize?: false` and no actor. Access to those is controlled by who
    can reach the server, not by this log.
  """

  alias App.Audit.{AccessLog, EmergencyAccess}
  alias App.Documents.{Document, Types}
  alias App.People.{IdentityDocument, PersonIdentifier, PersonRecord, PersonRecordSchema}

  @sensitive_categories [:care, :medical, :vetting, :personnel_private]

  @doc "The PersonRecord categories whose reads are logged."
  @spec sensitive_categories() :: [atom()]
  def sensitive_categories, do: @sensitive_categories

  @spec on_decrypt(module(), [struct()], atom(), map()) :: :ok | {:error, term()}
  def on_decrypt(resource, records, _field, %{actor: %{id: actor_id} = actor}) do
    emergency = emergency_reasons(actor, resource, records)

    rows =
      for record <- records, sensitive?(resource, record) do
        %{
          actor_id: actor_id,
          actor_email: to_string(actor.email),
          resource: inspect(resource),
          record_id: record.id,
          person_id: Map.get(record, :person_id),
          kind: kind(resource, record),
          reason: emergency_reason(emergency, resource, record)
        }
      end

    write(rows)
  end

  def on_decrypt(_resource, _records, _field, _context), do: :ok

  @doc """
  Whether reading a stored file is logged: files on records of a sensitive
  category, and every file about a person except the portrait photo.
  """
  @spec sensitive_file?(struct()) :: boolean()
  def sensitive_file?(%App.People.Attachment{record_id: nil, purpose: :photo}), do: false
  def sensitive_file?(%App.People.Attachment{record_id: nil}), do: true

  def sensitive_file?(%App.People.Attachment{kind: kind}),
    do: PersonRecordSchema.category(kind) in @sensitive_categories

  @doc """
  Logs that `actor` was given a download link to `attachment`, if the file
  is sensitive. Returns an error when the row can't be written — the
  caller then gives no link (fails closed, like decryption).
  """
  @spec log_file_link(map(), struct()) :: :ok | {:error, term()}
  def log_file_link(%{id: actor_id} = actor, attachment) do
    if sensitive_file?(attachment) do
      write([
        %{
          actor_id: actor_id,
          actor_email: to_string(actor.email),
          resource: inspect(App.People.Attachment),
          record_id: attachment.id,
          person_id: attachment.person_id,
          kind:
            "file:#{attachment.purpose}" <>
              if(attachment.kind, do: ":#{attachment.kind}", else: ""),
          reason: nil
        }
      ])
    else
      :ok
    end
  end

  def log_file_link(_actor, _attachment), do: {:error, :no_actor}

  @doc """
  Logs that `actor` was given the PDF of `document`, if its type is in a
  sensitive category (a medical board conclusion). Fails closed like
  `log_file_link/2`.
  """
  @spec log_document_pdf(map(), struct()) :: :ok | {:error, term()}
  def log_document_pdf(%{id: actor_id} = actor, document) do
    if sensitive?(Document, document) do
      write([
        %{
          actor_id: actor_id,
          actor_email: to_string(actor.email),
          resource: inspect(Document),
          record_id: document.id,
          person_id: document.person_id,
          kind: "document-pdf:#{document.type}",
          reason: nil
        }
      ])
    else
      :ok
    end
  end

  def log_document_pdf(_actor, _document), do: {:error, :no_actor}

  @doc """
  Logs that a search by national ID or document number (`App.Search`)
  found these identifiers: `[{resource, record}]`. Fails closed: the
  search shows the people only when this was written.
  """
  @spec log_identifier_search(map(), [{module(), struct()}]) :: :ok | {:error, term()}
  def log_identifier_search(%{id: actor_id} = actor, matches) do
    matches
    |> Enum.map(fn {resource, record} ->
      %{
        actor_id: actor_id,
        actor_email: to_string(actor.email),
        resource: inspect(resource),
        record_id: record.id,
        person_id: record.person_id,
        kind: "search:identifier",
        reason: nil
      }
    end)
    |> write()
  end

  def log_identifier_search(_actor, _matches), do: {:error, :no_actor}

  # Allergy reads while the reader has an emergency access for that person
  # carry its reason (docs/design/access-control-phase2.md).
  defp emergency_reasons(actor, PersonRecord, records) do
    records
    |> Enum.filter(&(&1.kind == :allergy_intolerance))
    |> Enum.map(& &1.person_id)
    |> Enum.uniq()
    |> Enum.flat_map(&active_reason(actor, &1))
    |> Map.new()
  end

  defp emergency_reasons(_actor, _resource, _records), do: %{}

  defp active_reason(actor, person_id) do
    case EmergencyAccess.active_for(actor, person_id) do
      nil -> []
      grant -> [{person_id, grant.reason}]
    end
  end

  defp emergency_reason(reasons, PersonRecord, %{kind: :allergy_intolerance} = record) do
    case Map.get(reasons, record.person_id) do
      nil -> nil
      reason -> "Emergency access: " <> reason
    end
  end

  defp emergency_reason(_reasons, _resource, _record), do: nil

  @doc """
  Logs that `actor` saw sensitive `documents` as relations on the org
  graph (ORG-GRAPH.4: referrals to care providers) — only the document's
  existence, not its fields. Fails closed: the caller shows nothing when
  the rows can't be written.
  """
  @spec log_graph_relations(map(), [struct()]) :: :ok | {:error, term()}
  def log_graph_relations(%{id: actor_id} = actor, documents) do
    rows =
      for document <- documents, sensitive?(Document, document) do
        %{
          actor_id: actor_id,
          actor_email: to_string(actor.email),
          resource: inspect(Document),
          record_id: document.id,
          person_id: document.person_id,
          kind: "org-graph:#{document.type}",
          reason: nil
        }
      end

    write(rows)
  end

  def log_graph_relations(_actor, _documents), do: {:error, :no_actor}

  defp write([]), do: :ok

  defp write(rows) do
    case Ash.bulk_create(rows, AccessLog, :log,
           authorize?: false,
           return_errors?: true,
           stop_on_error?: true
         ) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, {:access_log_failed, errors}}
    end
  end

  defp sensitive?(PersonRecord, record),
    do: PersonRecordSchema.category(record.kind) in @sensitive_categories

  defp sensitive?(resource, _record) when resource in [PersonIdentifier, IdentityDocument],
    do: true

  # Documents (docs/design/documents-core.md): by their type's category.
  defp sensitive?(Document, document),
    do: Types.category(document.type) in @sensitive_categories

  defp sensitive?(_resource, _record), do: false

  defp kind(PersonRecord, record), do: to_string(record.kind)
  defp kind(Document, document), do: "document:#{document.type}"
  defp kind(PersonIdentifier, record), do: to_string(record.id_type)
  defp kind(IdentityDocument, record), do: to_string(record.document_type)
end
