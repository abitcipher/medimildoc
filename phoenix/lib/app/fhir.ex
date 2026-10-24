defmodule App.Fhir do
  @moduledoc """
  Reads behind the FHIR R5 API (docs/design/fhir-api.md). A service client
  reads as an actor, through the same policies as any user (what they
  hide is "not found"). A personal token (`own_person_id`) reads only
  its owner's person, every category, and nothing about anyone else.
  Every read of sensitive data goes to the access log with the reader as
  the actor. Resources are built by `App.Fhir.Map`.
  """

  require Ash.Query

  alias App.Accounts.User
  alias App.Audit.AccessLogger
  alias App.Care.Provider
  alias App.Documents.{Document, Labels, Print, Types}
  alias App.Fhir.Map, as: FhirMap

  alias App.People.{
    IdentityDocument,
    Organization,
    Person,
    PersonId,
    PersonIdentifier,
    PersonRecord
  }

  @record_types %{
    "Encounter" => :encounter,
    # Vital signs and lab results (docs/design/lab-results.md).
    "Observation" => [:vital_signs, :lab_result],
    "Condition" => :medical_condition,
    "AllergyIntolerance" => :allergy_intolerance,
    "MedicationStatement" => :medication_statement,
    "MedicationAdministration" => :medication_administration,
    "Procedure" => :procedure
  }

  @request_types [:care_referral, :medical_board_referral]
  @composition_types [:discharge_summary, :medical_board_conclusion]
  @api_locale "en"

  @types [
           "Patient",
           "Practitioner",
           "Organization",
           "ServiceRequest",
           "Composition",
           "DocumentReference"
         ] ++
           Map.keys(@record_types)

  @doc "The resource types the API serves."
  @spec types() :: [String.t()]
  def types, do: Enum.sort(@types)

  @doc "The resource types an external system may be granted (no Practitioner)."
  @spec external_types() :: [String.t()]
  def external_types, do: types() -- ["Practitioner"]

  @type error :: :not_found | :forbidden | :unsupported | {:bad_request, String.t()}

  @doc "One resource by type and id."
  @spec read(map(), String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, error()}
  def read(actor, type, id, base) do
    with :ok <- known(type),
         :ok <- granted(actor, type),
         {:ok, id} <- uuid(id) do
      case find(actor, type, id, base) do
        nil -> {:error, :not_found}
        {:error, _} = error -> error
        resource -> {:ok, resource}
      end
    end
  end

  @doc "A search as a `searchset` Bundle."
  @spec search(map(), String.t(), map(), String.t()) :: {:ok, map()} | {:error, error()}
  def search(actor, type, params, base) do
    with :ok <- known(type),
         :ok <- granted(actor, type),
         {:ok, resources} <- run_search(actor, type, params, base) do
      {:ok, FhirMap.bundle(resources, base)}
    end
  end

  @doc "The signed PDF of a document the actor may read: `{:ok, document}` (logged when sensitive)."
  @spec pdf(map(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def pdf(actor, id) do
    with :ok <- granted(actor, "DocumentReference"),
         {:ok, id} <- uuid(id),
         %{state: :signed, pdf_key: key} = document when is_binary(key) <-
           read_one(scope(Ash.Query.filter(Document, id == ^id), actor, :document), actor),
         :ok <- AccessLogger.log_document_pdf(actor, document) do
      {:ok, document}
    else
      _ -> {:error, :not_found}
    end
  end

  # ---- reads ---------------------------------------------------------------

  defp find(actor, "Patient", id, _base) do
    Person
    |> Ash.Query.filter(id == ^id)
    |> scope(actor, :id)
    |> read_one(actor)
    |> patient(actor)
  end

  defp find(actor, "Organization", id, _base) do
    case read_one(Ash.Query.filter(Organization, id == ^id), actor) do
      nil ->
        provider = read_one(Ash.Query.filter(Provider, id == ^id), actor)
        provider && FhirMap.provider(provider)

      org ->
        FhirMap.unit(org)
    end
  end

  defp find(%{api: :personal}, "Practitioner", _id, _base), do: {:error, :forbidden}

  defp find(actor, "Practitioner", id, _base) do
    if App.Access.can?(actor, "people.read") do
      case Ash.get(User, id, authorize?: false, load: [:person]) do
        {:ok, user} -> FhirMap.practitioner(user, loaded(user.person))
        _ -> nil
      end
    else
      {:error, :forbidden}
    end
  end

  defp find(actor, type, id, _base) when is_map_key(@record_types, type) do
    PersonRecord
    |> Ash.Query.filter(id == ^id and kind in ^List.wrap(@record_types[type]))
    |> scope(actor, :person_id)
    |> Ash.Query.load(:data)
    |> read_one(actor)
    |> then(&(&1 && FhirMap.record(&1)))
  end

  defp find(actor, type, id, base) do
    Document
    |> Ash.Query.filter(id == ^id)
    |> document_filter(type)
    |> scope(actor, :document)
    |> maybe_load_data(type)
    |> read_one(actor)
    |> then(&(&1 && document(type, &1, base)))
  end

  # ---- searches ------------------------------------------------------------

  defp run_search(actor, "Patient", params, _base) do
    people =
      cond do
        params["_id"] ->
          with {:ok, id} <- uuid(params["_id"]) do
            Person |> Ash.Query.filter(id == ^id) |> scope(actor, :id) |> read_all(actor)
          end

        params["identifier"] ->
          by_identifier(actor, params["identifier"])

        params["name"] ->
          actor |> App.Search.run(params["name"]) |> Map.fetch!(:people) |> only_own(actor)

        own = actor[:own_person_id] ->
          Person |> Ash.Query.filter(id == ^own) |> read_all(actor)

        true ->
          {:error, {:bad_request, "search Patient by _id, identifier or name"}}
      end

    with people when is_list(people) <- people, do: {:ok, Enum.map(people, &patient(&1, actor))}
  end

  defp run_search(actor, "Organization", params, _base) do
    pattern = "%" <> (params["name"] || "") <> "%"

    units =
      Organization
      |> Ash.Query.filter(ilike(name, ^pattern))
      |> Ash.Query.limit(100)
      |> read_all(actor)

    providers =
      Provider
      |> Ash.Query.filter(ilike(name, ^pattern))
      |> Ash.Query.limit(100)
      |> read_all(actor)

    {:ok, Enum.map(units, &FhirMap.unit/1) ++ Enum.map(providers, &FhirMap.provider/1)}
  end

  defp run_search(_actor, "Practitioner", _params, _base),
    do: {:error, {:bad_request, "read a Practitioner by its id"}}

  defp run_search(actor, type, params, base) do
    with {:ok, person_id} <- patient_param(actor, params) do
      resources =
        if Map.has_key?(@record_types, type) do
          PersonRecord
          |> Ash.Query.filter(person_id == ^person_id and kind in ^List.wrap(@record_types[type]))
          |> scope(actor, :person_id)
          |> Ash.Query.load(:data)
          |> Ash.Query.sort(effective_on: :desc)
          |> read_all(actor)
          |> Enum.map(&FhirMap.record/1)
        else
          Document
          |> Ash.Query.filter(person_id == ^person_id)
          |> document_filter(type)
          |> scope(actor, :document)
          |> maybe_load_data(type)
          |> Ash.Query.sort(signed_at: :desc)
          |> read_all(actor)
          |> Enum.map(&document(type, &1, base))
        end

      {:ok, resources}
    end
  end

  # `system|value`: our Person ID, or a national ID / document number
  # (exact, through its keyed hash and logged — App.Search).
  defp by_identifier(actor, identifier) do
    value = identifier |> String.split("|") |> List.last()
    code = PersonId.unformat(value)

    if String.ends_with?(identifier, "person-id|" <> value) or PersonId.valid?(code) do
      Person |> Ash.Query.filter(person_id == ^code) |> scope(actor, :id) |> read_all(actor)
    else
      actor |> App.Search.run(value) |> Map.fetch!(:identified) |> only_own(actor)
    end
  end

  defp patient_param(actor, params) do
    raw = params["patient"] || params["subject"] || actor[:own_person_id]

    case raw && uuid(String.replace_prefix(raw, "Patient/", "")) do
      {:ok, id} -> {:ok, id}
      nil -> {:error, {:bad_request, "the patient parameter is required"}}
      error -> error
    end
  end

  # ---- documents -------------------------------------------------------------

  defp document_filter(query, "ServiceRequest"),
    do: Ash.Query.filter(query, type in ^@request_types)

  defp document_filter(query, "Composition"),
    do: Ash.Query.filter(query, type in ^@composition_types and state == :signed)

  defp document_filter(query, "DocumentReference"),
    do: Ash.Query.filter(query, state == :signed and not is_nil(pdf_key))

  defp maybe_load_data(query, "DocumentReference"), do: query
  defp maybe_load_data(query, _type), do: Ash.Query.load(query, :data)

  defp document("ServiceRequest", document, _base),
    do: FhirMap.service_request(document, identifiers(document))

  defp document("Composition", document, _base) do
    rows = Print.rows(document.type, document.data || %{}, Labels.impl(), @api_locale)
    FhirMap.composition(document, title(document), rows, identifiers(document))
  end

  defp document("DocumentReference", document, base),
    do:
      FhirMap.document_reference(
        document,
        title(document),
        "#{base}/Binary/#{document.id}",
        identifiers(document)
      )

  defp title(document), do: Labels.impl().text(Types.label(document.type), @api_locale)

  defp identifiers(document),
    do: FhirMap.identifiers(Types.identifiers(document)["identifier"] || [])

  # ---- patients --------------------------------------------------------------

  defp patient(nil, _actor), do: nil
  # External systems get no national IDs (data minimisation).
  defp patient(person, %{api: :external}), do: FhirMap.patient(person, [])
  defp patient(person, actor), do: FhirMap.patient(person, national_identifiers(person, actor))

  # Shown only to readers of identifiers; loading the values is logged.
  defp national_identifiers(person, actor) do
    ids =
      PersonIdentifier
      |> Ash.Query.filter(person_id == ^person.id)
      |> Ash.Query.load(:value)
      |> read_all_or_empty(actor)
      |> Enum.map(&{"id-type:#{&1.id_type}", &1.value})

    documents =
      IdentityDocument
      |> Ash.Query.filter(person_id == ^person.id)
      |> Ash.Query.load(:number)
      |> read_all_or_empty(actor)
      |> Enum.map(&{"identity-document:#{&1.document_type}", &1.number})

    ids ++ documents
  end

  # ---- scope and reading -----------------------------------------------------

  # A personal token: only its owner's person.
  defp scope(query, %{own_person_id: own}, :id), do: Ash.Query.filter(query, id == ^own)

  defp scope(query, %{own_person_id: own}, field) when field in [:person_id, :document],
    do: Ash.Query.filter(query, person_id == ^own)

  # An external system: patients referred to its provider, and documents
  # addressed to its provider.
  defp scope(query, %{api: :external} = actor, :id),
    do: Ash.Query.filter(query, id in ^referred(actor))

  defp scope(query, %{api: :external} = actor, :person_id),
    do: Ash.Query.filter(query, person_id in ^referred(actor))

  defp scope(query, %{api: :external, provider_id: provider} = actor, :document) do
    Ash.Query.filter(
      query,
      person_id in ^referred(actor) and recipient_provider_id == ^provider
    )
  end

  defp scope(query, _actor, _field), do: query

  # People with a signed referral to the external system's provider.
  defp referred(%{provider_id: provider}) do
    Document
    |> Ash.Query.filter(
      type == :care_referral and state == :signed and recipient_provider_id == ^provider
    )
    |> Ash.Query.select([:person_id])
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.person_id)
    |> Enum.uniq()
  end

  # An external system may read only the resource types its token grants.
  defp granted(%{api: :external, scopes: scopes}, type),
    do: if(type in scopes, do: :ok, else: {:error, :forbidden})

  defp granted(_actor, _type), do: :ok

  # Personal tokens and external systems read past the category policies
  # (the scope above decides); the actor still goes along for the access log.
  defp opts(%{api: api} = actor) when api in [:personal, :external],
    do: [actor: actor, authorize?: false]

  defp opts(actor), do: [actor: actor]

  defp read_one(query, actor) do
    case Ash.read(Ash.Query.limit(query, 1), opts(actor)) do
      {:ok, [one]} -> one
      _ -> nil
    end
  end

  defp read_all(query, actor) do
    case Ash.read(query, opts(actor)) do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  defp read_all_or_empty(query, actor), do: read_all(query, actor)

  defp only_own(people, %{own_person_id: own}), do: Enum.filter(people, &(&1.id == own))

  defp only_own(people, %{api: :external} = actor) do
    ids = referred(actor)
    Enum.filter(people, &(&1.id in ids))
  end

  defp only_own(people, _actor), do: people

  defp loaded(%Ash.NotLoaded{}), do: nil
  defp loaded(value), do: value

  defp known(type), do: if(type in @types, do: :ok, else: {:error, :unsupported})

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end
end
