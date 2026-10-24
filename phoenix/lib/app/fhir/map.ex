defmodule App.Fhir.Map do
  @moduledoc """
  Our data as FHIR R5 resources (docs/design/fhir-api.md). Pure: callers
  pass what was read (as the reader); nothing is looked up here. Empty
  fields are left out. Local times from clinical forms are given with the
  offset of the app's time zone (`config :app, :app_time_zone`).

  Vital signs use LOINC codes (© Regenstrief Institute) and UCUM units.
  """

  alias App.Clinical.LabTests
  alias App.People.Person

  @hrda "urn:hrda:"
  @loinc "http://loinc.org"
  @ucum "http://unitsofmeasure.org"

  # ---- people and organizations -----------------------------------------

  @doc "A person as a Patient; `identifiers` are `{system_suffix, value}` the reader may see."
  @spec patient(Person.t(), [{String.t(), String.t()}]) :: map()
  def patient(person, identifiers \\ []) do
    compact(%{
      "resourceType" => "Patient",
      "id" => person.id,
      "identifier" =>
        [%{"system" => @hrda <> "person-id", "value" => person.person_id}] ++
          Enum.map(identifiers, fn {system, value} ->
            %{"system" => @hrda <> system, "value" => value}
          end),
      "active" => true,
      "name" => [
        %{
          "use" => "official",
          "family" => person.family_name,
          "given" => Enum.reject([person.given_name, person.patronymic], &blank?/1),
          "text" => Person.full_name(person)
        }
      ],
      "telecom" => if(person.email, do: [%{"system" => "email", "value" => person.email}]),
      "birthDate" => date(person.date_of_birth),
      "extension" => birth_place(person)
    })
  end

  defp birth_place(%{birth_locality: nil, birth_region: nil, birth_country: nil}), do: nil

  defp birth_place(person) do
    [
      %{
        "url" => "http://hl7.org/fhir/StructureDefinition/patient-birthPlace",
        "valueAddress" =>
          compact(%{
            "city" => person.birth_locality,
            "state" => person.birth_region,
            "country" => person.birth_country
          })
      }
    ]
  end

  @doc "One of our units as an Organization."
  @spec unit(map()) :: map()
  def unit(org) do
    compact(%{
      "resourceType" => "Organization",
      "id" => org.id,
      "active" => true,
      "name" => org.name,
      "type" => [%{"text" => to_string(org.kind)}],
      "partOf" => org.parent_id && ref("Organization", org.parent_id)
    })
  end

  @doc "A care provider from the register as an Organization."
  @spec provider(map()) :: map()
  def provider(p) do
    compact(%{
      "resourceType" => "Organization",
      "id" => p.id,
      "active" => p.active,
      "name" => p.name,
      "identifier" =>
        p.registry_code &&
          [%{"system" => @hrda <> "provider-registry", "value" => p.registry_code}],
      "type" => [
        %{
          "coding" => [
            %{
              "system" => "http://terminology.hl7.org/CodeSystem/organization-type",
              "code" => "prov"
            }
          ],
          "text" => to_string(p.provider_type)
        }
      ],
      "contact" => [
        compact(%{
          "telecom" =>
            Enum.reject(
              [
                p.phone && %{"system" => "phone", "value" => p.phone},
                p.email && %{"system" => "email", "value" => p.email}
              ],
              &is_nil/1
            ),
          "address" =>
            compact(%{
              "line" => p.address && [p.address],
              "city" => p.locality,
              "country" => p.country
            })
        })
      ],
      "partOf" => p.organization_id && ref("Organization", p.organization_id)
    })
  end

  @doc "A user (who approves and signs documents) as a Practitioner."
  @spec practitioner(map(), map() | nil) :: map()
  def practitioner(user, person) do
    compact(%{
      "resourceType" => "Practitioner",
      "id" => user.id,
      "active" => true,
      "name" => [%{"text" => (person && Person.full_name(person)) || user.name || "?"}],
      "telecom" => [%{"system" => "email", "value" => to_string(user.email)}]
    })
  end

  # ---- clinical records ---------------------------------------------------

  @doc "A person record as its FHIR resource (by kind)."
  @spec record(map()) :: map()
  def record(%{kind: :encounter, data: d} = r) do
    compact(%{
      "resourceType" => "Encounter",
      "id" => r.id,
      "status" => d["status"] || "unknown",
      "class" =>
        d["class"] && [coded("http://terminology.hl7.org/CodeSystem/v3-ActCode", d["class"])],
      "priority" => d["triage"] && %{"text" => "Triage " <> d["triage"]},
      "subject" => ref("Patient", r.person_id),
      "actualPeriod" => compact(%{"start" => datetime(d["start"]), "end" => datetime(d["end"])}),
      "reason" => d["reason"] && [%{"value" => [%{"concept" => %{"text" => d["reason"]}}]}],
      "participant" => d["practitioner"] && [%{"actor" => %{"display" => d["practitioner"]}}],
      "location" => d["location"] && [%{"location" => %{"display" => d["location"]}}],
      "admission" =>
        d["disposition"] && %{"dischargeDisposition" => %{"text" => d["disposition"]}}
    })
  end

  def record(%{kind: :vital_signs, data: d} = r) do
    compact(%{
      "resourceType" => "Observation",
      "id" => r.id,
      "status" => "final",
      "category" => [
        coded("http://terminology.hl7.org/CodeSystem/observation-category", "vital-signs")
      ],
      "code" => loinc("85353-1", "Vital signs panel"),
      "subject" => ref("Patient", r.person_id),
      "encounter" => r.part_of_id && ref("Encounter", r.part_of_id),
      "effectiveDateTime" => datetime(d["measuredAt"]),
      "component" => vital_components(d),
      "note" => note(d)
    })
  end

  # A laboratory result (docs/design/lab-results.md): LOINC from the test list.
  def record(%{kind: :lab_result, data: d} = r) do
    test = LabTests.get(d["test"])

    compact(%{
      "resourceType" => "Observation",
      "id" => r.id,
      "status" => "final",
      "category" => [
        coded("http://terminology.hl7.org/CodeSystem/observation-category", "laboratory")
      ],
      "code" =>
        if(test,
          do: loinc(test["loinc"], test["names"]["en"]),
          else: %{"text" => d["test"]}
        ),
      "subject" => ref("Patient", r.person_id),
      "encounter" => r.part_of_id && ref("Encounter", r.part_of_id),
      "effectiveDateTime" => datetime(d["collectedAt"]),
      "valueQuantity" =>
        is_number(d["value"]) && compact(%{"value" => d["value"], "unit" => blank_nil(d["unit"])}),
      "referenceRange" => test && [lab_range(test)],
      "interpretation" => lab_interpretation(d["interpretation"]),
      "performer" => d["laboratory"] && [%{"display" => d["laboratory"]}],
      "note" => note(d)
    })
  end

  def record(%{kind: :medical_condition, data: d} = r) do
    compact(%{
      "resourceType" => "Condition",
      "id" => r.id,
      "clinicalStatus" =>
        coded(
          "http://terminology.hl7.org/CodeSystem/condition-clinical",
          d["clinicalStatus"] || "active"
        ),
      "verificationStatus" =>
        d["verificationStatus"] &&
          coded(
            "http://terminology.hl7.org/CodeSystem/condition-ver-status",
            d["verificationStatus"]
          ),
      "severity" => d["severity"] && %{"text" => d["severity"]},
      "code" => concept(d["code"]),
      "bodySite" => d["bodySite"] && [%{"text" => d["bodySite"]}],
      "subject" => ref("Patient", r.person_id),
      "onsetDateTime" => datetime(d["onsetDate"]),
      "abatementDateTime" => datetime(d["abatementDate"]),
      "recordedDate" => datetime(d["recordedDate"]),
      "note" => note(d)
    })
  end

  def record(%{kind: :allergy_intolerance, data: d} = r) do
    compact(%{
      "resourceType" => "AllergyIntolerance",
      "id" => r.id,
      "clinicalStatus" =>
        d["clinicalStatus"] &&
          coded(
            "http://terminology.hl7.org/CodeSystem/allergyintolerance-clinical",
            d["clinicalStatus"]
          ),
      "verificationStatus" =>
        d["verificationStatus"] &&
          coded(
            "http://terminology.hl7.org/CodeSystem/allergyintolerance-verification",
            d["verificationStatus"]
          ),
      "type" =>
        d["type"] &&
          coded("http://hl7.org/fhir/allergy-intolerance-type", d["type"]),
      "category" => d["category"],
      "criticality" => d["criticality"],
      "code" => concept(d["code"]),
      "patient" => ref("Patient", r.person_id),
      "onsetDateTime" => datetime(d["onsetDate"]),
      "reaction" =>
        d["reactionManifestation"] &&
          [
            compact(%{
              "manifestation" => [%{"concept" => %{"text" => d["reactionManifestation"]}}],
              "severity" => d["reactionSeverity"]
            })
          ],
      "note" => note(d)
    })
  end

  def record(%{kind: :medication_statement, data: d} = r) do
    compact(%{
      "resourceType" => "MedicationStatement",
      "id" => r.id,
      "status" => "recorded",
      "medication" => %{"concept" => concept(d["medication"])},
      "subject" => ref("Patient", r.person_id),
      "effectivePeriod" =>
        compact(%{
          "start" => datetime(d["effectiveStart"]),
          "end" => datetime(d["effectiveEnd"])
        }),
      "adherence" =>
        d["adherence"] &&
          %{
            "code" =>
              coded(
                "http://hl7.org/fhir/CodeSystem/medication-statement-adherence",
                d["adherence"]
              )
          },
      "reason" => d["reason"] && [%{"concept" => %{"text" => d["reason"]}}],
      "informationSource" => d["informationSource"] && [%{"display" => d["informationSource"]}],
      "dosage" => [
        compact(%{
          "text" => d["dosageText"],
          "route" => d["route"] && %{"text" => d["route"]},
          "timing" => d["frequency"] && %{"code" => %{"text" => d["frequency"]}},
          "doseAndRate" => d["dose"] && [%{"doseQuantity" => quantity(d["dose"])}]
        })
      ],
      "note" => note(d)
    })
  end

  def record(%{kind: :medication_administration, data: d} = r) do
    compact(%{
      "resourceType" => "MedicationAdministration",
      "id" => r.id,
      "status" => d["status"] || "completed",
      "medication" => %{"concept" => concept(d["medication"])},
      "subject" => ref("Patient", r.person_id),
      "encounter" => r.part_of_id && ref("Encounter", r.part_of_id),
      "occurenceDateTime" => datetime(d["occurrence"]),
      "reason" => d["reason"] && [%{"concept" => %{"text" => d["reason"]}}],
      "dosage" =>
        compact(%{
          "route" => d["route"] && %{"text" => d["route"]},
          "site" => d["site"] && %{"text" => d["site"]},
          "dose" => d["dose"] && quantity(d["dose"])
        }),
      "note" => note(d)
    })
  end

  def record(%{kind: :procedure, data: d} = r) do
    compact(%{
      "resourceType" => "Procedure",
      "id" => r.id,
      "status" => d["status"] || "completed",
      "code" =>
        d["code"] &&
          %{
            "coding" => [%{"system" => @hrda <> "procedure", "code" => d["code"]}],
            "text" => d["detail"] || d["code"]
          },
      "subject" => ref("Patient", r.person_id),
      "encounter" => r.part_of_id && ref("Encounter", r.part_of_id),
      "occurrencePeriod" =>
        d["endedAt"] &&
          compact(%{"start" => datetime(d["performed"]), "end" => datetime(d["endedAt"])}),
      "occurrenceDateTime" => if(is_nil(d["endedAt"]), do: datetime(d["performed"])),
      "bodySite" =>
        d["bodySite"] &&
          [%{"text" => Enum.join(Enum.reject([d["side"], d["bodySite"]], &blank?/1), " ")}],
      "outcome" => d["outcome"] && %{"text" => d["outcome"]},
      "note" => note(d)
    })
  end

  # ---- documents ----------------------------------------------------------

  @doc "A referral (care or medical board) as a ServiceRequest."
  @spec service_request(map(), [map()]) :: map()
  def service_request(document, identifiers) do
    d = document.data || %{}

    compact(%{
      "resourceType" => "ServiceRequest",
      "id" => document.id,
      "identifier" => identifiers,
      "status" => request_status(document.state),
      "intent" => "order",
      "priority" => d["priority"],
      "code" => %{
        "concept" => %{"text" => d["service"] || d["reason"] || to_string(document.type)}
      },
      "subject" => ref("Patient", document.person_id),
      "performer" => d["provider"] && [ref("Organization", d["provider"])],
      "reason" =>
        (d["reasonCode"] || d["reason"]) &&
          [
            %{
              "concept" =>
                compact(%{
                  "text" => d["reason"],
                  "coding" => d["reasonCode"] && [icd10(d["reasonCode"])]
                })
            }
          ],
      "occurrenceDateTime" => datetime(d["plannedDate"]),
      "authoredOn" => datetime(document.signed_at),
      "requester" => document.signed_by_id && ref("Practitioner", document.signed_by_id),
      "note" => note(d)
    })
  end

  defp request_status(:signed), do: "active"
  defp request_status(:in_review), do: "draft"
  defp request_status(:draft), do: "draft"
  defp request_status(:cancelled), do: "revoked"

  @doc """
  A signed document as a Composition: its fields as sections (`rows` —
  `%{"label", "value"}` in print order, `App.Documents.Print.rows/4`).
  """
  @spec composition(map(), String.t(), [map()], [map()]) :: map()
  def composition(document, title, rows, identifiers) do
    compact(%{
      "resourceType" => "Composition",
      "id" => document.id,
      "identifier" => identifiers,
      "status" => if(document.state == :signed, do: "final", else: "preliminary"),
      "type" => composition_type(document.type, title),
      "subject" => [ref("Patient", document.person_id)],
      "date" => datetime(document.signed_at || document.updated_at),
      "author" => [author(document)],
      "title" => title,
      "section" =>
        Enum.map(rows, fn %{"label" => label, "value" => value} ->
          %{"title" => label, "text" => narrative(value)}
        end)
    })
  end

  defp composition_type(:discharge_summary, title),
    do: Map.put(loinc("18842-5", "Discharge summary"), "text", title)

  defp composition_type(_type, title), do: %{"text" => title}

  @doc "A signed document's PDF as a DocumentReference (`pdf_url` serves it with the token)."
  @spec document_reference(map(), String.t(), String.t(), [map()]) :: map()
  def document_reference(document, title, pdf_url, identifiers) do
    compact(%{
      "resourceType" => "DocumentReference",
      "id" => document.id,
      "identifier" => identifiers,
      "status" => "current",
      "docStatus" => "final",
      "type" => %{"text" => title},
      "subject" => ref("Patient", document.person_id),
      "date" => datetime(document.signed_at),
      "author" => [author(document)],
      "content" => [
        %{
          "attachment" => %{
            "contentType" => "application/pdf",
            "url" => pdf_url,
            "title" => document.number || title,
            "creation" => datetime(document.signed_at)
          }
        }
      ]
    })
  end

  defp author(%{signed_by_id: id}) when is_binary(id), do: ref("Practitioner", id)
  defp author(%{author_id: id}) when is_binary(id), do: ref("Practitioner", id)
  defp author(_document), do: %{"display" => "System"}

  @doc "The FHIR identifiers of a registered document (`App.Documents.Types.identifiers/1`)."
  @spec identifiers([map()]) :: [map()]
  def identifiers(list),
    do:
      Enum.map(
        list,
        &compact(%{"system" => &1[:system] || &1["system"], "value" => &1[:value] || &1["value"]})
      )

  # ---- bundles and outcomes -----------------------------------------------

  @doc "A searchset Bundle of resources (`base` builds the full URLs)."
  @spec bundle([map()], String.t()) :: map()
  def bundle(resources, base) do
    %{
      "resourceType" => "Bundle",
      "type" => "searchset",
      "total" => length(resources),
      "entry" =>
        Enum.map(resources, fn r ->
          %{
            "fullUrl" => "#{base}/#{r["resourceType"]}/#{r["id"]}",
            "resource" => r,
            "search" => %{"mode" => "match"}
          }
        end)
    }
  end

  @doc "An OperationOutcome with one issue."
  @spec outcome(String.t(), String.t()) :: map()
  def outcome(code, text) do
    %{
      "resourceType" => "OperationOutcome",
      "issue" => [%{"severity" => "error", "code" => code, "diagnostics" => text}]
    }
  end

  # ---- helpers ------------------------------------------------------------

  @vitals [
    {"systolic", "8480-6", "Systolic blood pressure", "mm[Hg]", "mmHg"},
    {"diastolic", "8462-4", "Diastolic blood pressure", "mm[Hg]", "mmHg"},
    {"heartRate", "8867-4", "Heart rate", "/min", "/min"},
    {"respiratoryRate", "9279-1", "Respiratory rate", "/min", "/min"},
    {"spo2", "2708-6", "Oxygen saturation in Arterial blood", "%", "%"},
    {"temperature", "8310-5", "Body temperature", "Cel", "°C"},
    {"gcs", "9269-2", "Glasgow coma score total", "{score}", "score"},
    {"pain", "72514-3", "Pain severity - 0-10 verbal numeric rating", "{score}", "score"}
  ]

  defp vital_components(d) do
    numeric =
      for {field, code, name, ucum, unit} <- @vitals, is_number(d[field]) do
        %{
          "code" => loinc(code, name),
          "valueQuantity" => %{
            "value" => d[field],
            "unit" => unit,
            "system" => @ucum,
            "code" => ucum
          }
        }
      end

    other =
      Enum.reject(
        [
          d["consciousness"] &&
            %{
              "code" => %{"text" => "Level of consciousness (ACVPU)"},
              "valueCodeableConcept" => %{"text" => d["consciousness"]}
            },
          is_boolean(d["onOxygen"]) &&
            %{
              "code" => %{"text" => "On supplemental oxygen"},
              "valueBoolean" => d["onOxygen"]
            }
        ],
        &(&1 in [nil, false])
      )

    numeric ++ other
  end

  defp ref(type, id), do: %{"reference" => "#{type}/#{id}"}
  defp coded(system, code), do: %{"coding" => [%{"system" => system, "code" => code}]}

  defp loinc(code, display),
    do: %{"coding" => [%{"system" => @loinc, "code" => code, "display" => display}]}

  defp icd10(code), do: %{"system" => "http://hl7.org/fhir/sid/icd-10", "code" => code}

  # Our `{text, coding}` (coding a list, or one map) as a CodeableConcept.
  defp concept(%{} = c) do
    coding =
      case c["coding"] do
        list when is_list(list) -> list
        %{} = one -> [one]
        _ -> nil
      end

    compact(%{"text" => c["text"], "coding" => coding && Enum.map(coding, &compact/1)})
  end

  defp concept(_other), do: nil

  defp quantity(%{"value" => value} = q) when is_number(value),
    do: compact(%{"value" => value, "unit" => q["unit"]})

  defp quantity(_other), do: nil

  defp lab_range(test) do
    unit = blank_nil(test["unit"])

    compact(%{
      "low" => compact(%{"value" => test["low"], "unit" => unit}),
      "high" => compact(%{"value" => test["high"], "unit" => unit})
    })
  end

  @interpretation "http://terminology.hl7.org/CodeSystem/v3-ObservationInterpretation"
  defp lab_interpretation("low"), do: [coded(@interpretation, "L")]
  defp lab_interpretation("high"), do: [coded(@interpretation, "H")]
  defp lab_interpretation("normal"), do: [coded(@interpretation, "N")]
  defp lab_interpretation(_other), do: nil

  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value

  defp note(%{"note" => text}) when is_binary(text) and text != "", do: [%{"text" => text}]
  defp note(_data), do: nil

  defp narrative(value) do
    escaped = value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    %{
      "status" => "generated",
      "div" => ~s(<div xmlns="http://www.w3.org/1999/xhtml">#{escaped}</div>)
    }
  end

  defp date(nil), do: nil
  defp date(%Date{} = d), do: Date.to_iso8601(d)

  @doc false
  # A FHIR dateTime: a date stays a date; a local "yyyy-mm-ddTHH:MM[:SS]"
  # gets the app's time zone offset; a UTC timestamp stays UTC.
  def datetime(nil), do: nil
  def datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def datetime(%Date{} = d), do: Date.to_iso8601(d)

  def datetime(value) when is_binary(value) do
    cond do
      match?({:ok, _, _}, DateTime.from_iso8601(value)) ->
        value

      String.length(value) == 10 ->
        value

      true ->
        value |> pad_seconds() |> NaiveDateTime.from_iso8601() |> in_zone()
    end
  end

  defp pad_seconds(value), do: if(String.length(value) == 16, do: value <> ":00", else: value)

  defp in_zone({:ok, naive}) do
    zone = Application.get_env(:app, :app_time_zone, "Etc/UTC")

    case DateTime.from_naive(naive, zone, Tz.TimeZoneDatabase) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      {:ambiguous, first, _second} -> DateTime.to_iso8601(first)
      {:gap, _before, after_gap} -> DateTime.to_iso8601(after_gap)
      _ -> nil
    end
  end

  defp in_zone(_error), do: nil

  defp blank?(value), do: value in [nil, ""]

  # Drops nil, empty strings, empty lists and empty maps (FHIR forbids
  # empty elements); `false` stays.
  defp compact(%{} = map) do
    map
    |> Enum.map(fn {k, v} -> {k, compact_value(v)} end)
    |> Enum.reject(fn {_k, v} -> v in [nil, "", [], %{}] end)
    |> Map.new()
  end

  defp compact_value(%{} = map), do: compact(map)

  defp compact_value(list) when is_list(list),
    do: list |> Enum.map(&compact_value/1) |> Enum.reject(&(&1 in [nil, %{}, ""]))

  defp compact_value(value), do: value
end
