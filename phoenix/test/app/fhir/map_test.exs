defmodule App.Fhir.MapTest do
  @moduledoc "docs/design/fhir-api.md: every resource we build is valid FHIR R5 (official JSON Schema)."
  use ExUnit.Case, async: true

  alias App.Fhir.Map, as: FhirMap

  setup_all do
    schema =
      "priv/fhir/R5/fhir.schema.json"
      |> File.read!()
      |> Jason.decode!()
      |> ExJsonSchema.Schema.resolve()

    %{schema: schema}
  end

  defp assert_valid(schema, %{"resourceType" => type} = resource) do
    case ExJsonSchema.Validator.validate_fragment(schema, "#/definitions/#{type}", resource) do
      :ok ->
        :ok

      {:error, errors} ->
        flunk("#{type} is not valid FHIR R5: #{inspect(errors)}\n#{inspect(resource)}")
    end
  end

  defp record(kind, data, extra \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        kind: kind,
        person_id: Ecto.UUID.generate(),
        part_of_id: nil,
        data: data
      },
      extra
    )
  end

  test "the validator really rejects invalid resources", %{schema: schema} do
    bad = %{"resourceType" => "Patient", "birthDate" => "01.05.1990", "gender" => "woman"}

    assert {:error, [_ | _]} =
             ExJsonSchema.Validator.validate_fragment(schema, "#/definitions/Patient", bad)

    bad = %{
      "resourceType" => "Condition",
      "subject" => %{"reference" => "Patient/1"},
      "clinicalStatus" => "active"
    }

    assert {:error, [_ | _]} =
             ExJsonSchema.Validator.validate_fragment(schema, "#/definitions/Condition", bad)
  end

  test "patients, units, providers and practitioners", %{schema: schema} do
    person = %App.People.Person{
      id: Ecto.UUID.generate(),
      person_id: "BADOKEFIGULO",
      given_name: "Olena",
      patronymic: "Petrivna",
      family_name: "Kovalenko",
      email: "olena@demo.test",
      date_of_birth: ~D[1990-05-01],
      birth_country: "UA",
      birth_locality: "Lviv"
    }

    patient = FhirMap.patient(person, [{"id-type:rnokpp", "TEST-1234567890"}])
    assert_valid(schema, patient)
    assert [%{"given" => ["Olena", "Petrivna"]}] = patient["name"]

    assert_valid(
      schema,
      FhirMap.unit(%{id: Ecto.UUID.generate(), name: "A Company", kind: :company, parent_id: nil})
    )

    assert_valid(
      schema,
      FhirMap.provider(%App.Care.Provider{
        id: Ecto.UUID.generate(),
        name: "Regional Hospital",
        provider_type: :hospital,
        active: true,
        registry_code: "TEST-1",
        phone: "+380441234567",
        address: "1 Main St",
        locality: "Kyiv",
        country: "UA"
      })
    )

    assert_valid(
      schema,
      FhirMap.practitioner(
        %{id: Ecto.UUID.generate(), name: "Dr Demo", email: "dr@demo.test"},
        nil
      )
    )
  end

  test "every clinical kind, from its sample data", %{schema: schema} do
    for kind <- [
          :encounter,
          :vital_signs,
          :medical_condition,
          :allergy_intolerance,
          :medication_statement,
          :medication_administration,
          :procedure,
          :lab_result
        ] do
      resource = FhirMap.record(record(kind, App.Demo.sample_record_data(kind)))
      assert_valid(schema, resource)
    end
  end

  test "local clinical times get the offset of the app's time zone" do
    assert FhirMap.datetime("2026-07-01T10:32") == "2026-07-01T10:32:00+03:00"
    assert FhirMap.datetime("2026-01-15T08:00") == "2026-01-15T08:00:00+02:00"
    assert FhirMap.datetime("2026-01-15") == "2026-01-15"
  end

  test "documents: referral, composition, document reference", %{schema: schema} do
    document = %{
      id: Ecto.UUID.generate(),
      type: :discharge_summary,
      state: :signed,
      person_id: Ecto.UUID.generate(),
      signed_by_id: Ecto.UUID.generate(),
      author_id: nil,
      number: "1-вип",
      signed_at: ~U[2026-10-08 12:00:00Z],
      updated_at: ~U[2026-10-08 12:00:00Z],
      data: %{
        "provider" => Ecto.UUID.generate(),
        "service" => "hospitalization",
        "priority" => "urgent",
        "reason" => "Knee injury",
        "reasonCode" => "S83.2",
        "plannedDate" => "2026-10-01"
      }
    }

    ids = FhirMap.identifiers([%{system: "urn:hrda:register:вип:2026", value: "1-вип"}])
    assert_valid(schema, FhirMap.service_request(%{document | type: :care_referral}, ids))

    rows = [%{"label" => "Diagnosis", "value" => "Tear of meniscus <left>"}]
    composition = FhirMap.composition(document, "Discharge summary", rows, ids)
    assert_valid(schema, composition)
    assert [%{"text" => %{"div" => div}}] = composition["section"]
    assert div =~ "&lt;left&gt;"

    assert_valid(
      schema,
      FhirMap.document_reference(document, "Discharge summary", "https://x/fhir/R5/Binary/1", ids)
    )
  end
end
