defmodule App.Documents.Changes.Sign do
  @moduledoc """
  Signing a document (docs/design/documents-core.md), in the action's
  transaction:

  1. before the write — the next number in the type's register for this
     year (`App.Documents.Counter`), the registration date, the signer and
     time, a certificate's facts as of today (`App.Documents.Certificates`,
     added to the fields under `"facts"`), and SHA-256 of the signed
     content (type, person, number, date, fields in canonical JSON);
  2. after the write — a certificate's facts stored, the PDF rendered
     (`App.Documents.Pdf`), stored, and its SHA-256 kept; then the type's
     effects (`App.Documents.Effects`).

  If any of it fails, the whole signature is rolled back: no number is
  used up, no effect is half applied. (A PDF already uploaded before a
  failed commit stays as an unreferenced object.)
  """
  use Ash.Resource.Change

  require Ash.Query

  alias App.Documents.{Certificates, Counter, DocumentFile, Effects, Pdf, Print, Queries, Types}
  alias App.Records.CaseLookup

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.before_action(&register(&1, context.actor))
    |> Ash.Changeset.after_action(fn changeset, document ->
      with {:ok, signed} = result <-
             finish(document, changeset.context[:certificate_data], context.actor) do
        # A key event (docs/design/events-and-person-login.md), in the same
        # transaction: the type only, nothing of the content.
        App.EventLog.emit(
          "hrda.documents.document.signed",
          %{document_type: to_string(signed.type)},
          actor: context.actor,
          subject: "document/#{signed.id}"
        )

        result
      end
    end)
  end

  defp register(changeset, actor) do
    today = Date.utc_today()
    # The fields as signed, however the document was read; a certificate's
    # with what it states today.
    document = %{changeset.data | data: with_facts(changeset.data, today)}
    register = Types.register(document.type)
    seq = Counter.next(register, today.year)
    number = Types.number(document.type, today.year, seq)

    changeset
    |> then(fn changeset ->
      if Types.facts(document.type),
        do: Ash.Changeset.put_context(changeset, :certificate_data, document.data),
        else: changeset
    end)
    |> Ash.Changeset.force_change_attributes(%{
      register: register,
      register_year: today.year,
      register_seq: seq,
      number: number,
      registered_on: today,
      signed_at: DateTime.utc_now(),
      signed_by_id: actor.id,
      # The file plan case for this type and year (docs/design/registers-file-plan.md).
      case_id: CaseLookup.case_id(document.type, today.year),
      content_sha256: content_hash(document, number, today)
    })
  end

  @doc "SHA-256 (hex) of what is signed; the same input always gives the same hash."
  @spec content_hash(map(), String.t(), Date.t()) :: String.t()
  def content_hash(document, number, date) do
    %{
      "type" => to_string(document.type),
      "person_id" => document.person_id,
      "number" => number,
      "date" => Date.to_iso8601(date),
      "data" => document.data
    }
    |> with_files(document)
    |> canonical()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # The document's files (a letter's scan) by their SHA-256, in upload
  # order (docs/design/correspondence.md). Left out when there are none,
  # so hashes of documents without files stay as they were.
  defp with_files(content, %{id: id}) when is_binary(id) do
    case DocumentFile
         |> Ash.Query.filter(document_id == ^id)
         |> Ash.Query.sort(inserted_at: :asc)
         |> Ash.read!(authorize?: false) do
      [] -> content
      files -> Map.put(content, "files", Enum.map(files, & &1.sha256))
    end
  end

  defp with_files(content, _document), do: content

  # Maps with keys in order, at every depth, so the JSON is canonical.
  defp canonical(%{} = map),
    do:
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> {k, canonical(v)} end)
      |> Jason.OrderedObject.new()

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(other), do: other

  defp with_facts(document, date) do
    data = stored_data(document)

    case Types.facts(document.type) do
      nil -> data
      kind -> Map.put(data, "facts", Certificates.facts(kind, document.person_id, data, date))
    end
  end

  defp finish(document, certificate_data, actor) do
    with {:ok, document} <- store_facts(document, certificate_data),
         document =
           document
           |> Map.put(:data, certificate_data || stored_data(document))
           |> Queries.load_trail()
           |> Ash.load!([:person, :basis], authorize?: false),
         {:ok, pdf} <- Pdf.render(Types.template(document.type), Print.payload(document)),
         {:ok, document} <- store_pdf(document, pdf),
         :ok <- Effects.apply_all(document, actor) do
      {:ok, document}
    end
  end

  # The fields as signed (decrypted without an actor: no access-log entry
  # for the system's own read).
  @doc "The document's fields, loaded as the system if they weren't (no access-log entry)."
  # (Ash.NotLoaded is a struct, so it matches %{} — test for it first.)
  @spec stored_data(map()) :: map()
  def stored_data(document) do
    case document.data do
      %Ash.NotLoaded{} -> Ash.load!(document, :data, authorize?: false).data
      %{} = data -> data
      _ -> Ash.load!(document, :data, authorize?: false).data
    end
  end

  # A certificate's fields with its facts, through the internal action (the
  # encryption of `data` happens there).
  defp store_facts(document, nil), do: {:ok, document}

  defp store_facts(document, data) do
    document
    |> Ash.Changeset.for_update(:attach_facts, %{data: data}, authorize?: false)
    |> Ash.update(authorize?: false)
  end

  defp store_pdf(document, pdf) do
    key = "documents/#{document.id}.pdf"
    path = Path.join(System.tmp_dir!(), "#{document.id}.pdf")
    File.write!(path, pdf)

    try do
      with :ok <- App.Storage.put_file(key, path, "application/pdf") do
        document
        |> Ash.Changeset.for_update(
          :attach_pdf,
          %{pdf_key: key, pdf_sha256: Base.encode16(:crypto.hash(:sha256, pdf), case: :lower)},
          authorize?: false
        )
        |> Ash.update(authorize?: false)
        |> case do
          {:ok, updated} ->
            {:ok,
             %{updated | data: document.data}
             |> Map.merge(Map.take(document, [:steps, :events, :person, :basis]))}

          error ->
            error
        end
      end
    after
      File.rm(path)
    end
  end
end
