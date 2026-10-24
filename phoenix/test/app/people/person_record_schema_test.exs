defmodule App.People.PersonRecordSchemaTest do
  use ExUnit.Case, async: true

  alias App.Access.SecurityLabels
  alias App.People.PersonRecordSchema
  alias App.People.RecordMigrations

  test "kinds/0 lists the known kinds" do
    assert Enum.sort(PersonRecordSchema.kinds()) == [
             :allergy_intolerance,
             :business_trip,
             :compensation,
             :contact_info,
             :dependent,
             :encounter,
             :family_status,
             :fitness_for_duty,
             :lab_result,
             :language_proficiency,
             :leave,
             :medical_condition,
             :medication_administration,
             :medication_statement,
             :procedure,
             :rank_history,
             :security_clearance,
             :status_change,
             :vetting_record,
             :vital_signs
           ]
  end

  describe "access metadata (docs/design/access-control-phase1.md)" do
    test "every kind declares a category, default labels and a version" do
      for kind <- PersonRecordSchema.kinds() do
        assert PersonRecordSchema.category(kind) in App.Access.record_categories()

        assert PersonRecordSchema.default_confidentiality(kind) in SecurityLabels.confidentiality_levels()

        assert is_binary(PersonRecordSchema.version(kind))
      end
    end

    test "clinical and vetting data sit in their own categories" do
      assert PersonRecordSchema.kinds_in_category(:medical) == [:medical_condition, :lab_result]
      # Allergies are point-of-care data (docs/design/clinical-module.md).
      assert :allergy_intolerance in PersonRecordSchema.kinds_in_category(:care)

      assert PersonRecordSchema.kinds_in_category(:vetting) == [:vetting_record]
      assert PersonRecordSchema.kinds_in_category(:readiness) == [:fitness_for_duty]
      assert PersonRecordSchema.default_classification(:vetting_record) == :nato_restricted
    end
  end

  test "schema/1 and ui_schema/1 return maps for known kinds, nil for unknown ones" do
    for kind <- PersonRecordSchema.kinds() do
      assert %{"type" => "object"} = PersonRecordSchema.schema(kind)
      assert %{"type" => "VerticalLayout"} = PersonRecordSchema.ui_schema(kind)
    end

    assert PersonRecordSchema.schema(:not_a_real_kind) == nil
    assert PersonRecordSchema.ui_schema(:not_a_real_kind) == nil
  end

  describe "validate/2 — :medical_condition" do
    test "accepts a minimal valid record" do
      assert :ok =
               PersonRecordSchema.validate(:medical_condition, %{
                 "code" => %{"text" => "Hypertension"},
                 "clinicalStatus" => "active"
               })
    end

    test "accepts the full FHIR-flavored shape" do
      assert :ok =
               PersonRecordSchema.validate(:medical_condition, %{
                 "resourceType" => "Condition",
                 "code" => %{
                   "text" => "Hypertension",
                   "coding" => [%{"system" => "http://snomed.info/sct", "code" => "38341003"}]
                 },
                 "clinicalStatus" => "active",
                 "onsetDate" => "2024-03-01",
                 "note" => "Diagnosed during routine checkup."
               })
    end

    test "accepts the fields added from the FHIR Condition alignment pass" do
      assert :ok =
               PersonRecordSchema.validate(:medical_condition, %{
                 "code" => %{"text" => "Hypertension"},
                 "clinicalStatus" => "resolved",
                 "verificationStatus" => "confirmed",
                 "severity" => "moderate",
                 "bodySite" => "N/A",
                 "onsetDate" => "2024-03-01",
                 "abatementDate" => "2024-09-01",
                 "recordedDate" => "2024-03-02"
               })
    end

    test "rejects an invalid verificationStatus value" do
      assert {:error, [_ | _]} =
               PersonRecordSchema.validate(:medical_condition, %{
                 "code" => %{"text" => "Hypertension"},
                 "clinicalStatus" => "active",
                 "verificationStatus" => "definitely_not_a_valid_status"
               })
    end

    test "rejects a record missing the required \"code\"" do
      assert {:error, [_ | _]} =
               PersonRecordSchema.validate(:medical_condition, %{"clinicalStatus" => "active"})
    end

    test "rejects an invalid clinicalStatus value" do
      assert {:error, [_ | _]} =
               PersonRecordSchema.validate(:medical_condition, %{
                 "code" => %{"text" => "Hypertension"},
                 "clinicalStatus" => "definitely_not_a_valid_status"
               })
    end

    test "rejects unknown properties" do
      assert {:error, [_ | _]} =
               PersonRecordSchema.validate(:medical_condition, %{
                 "code" => %{"text" => "Hypertension"},
                 "clinicalStatus" => "active",
                 "unexpectedField" => "nope"
               })
    end
  end

  describe "validate/2 — :status_change" do
    test "accepts a minimal valid record" do
      assert :ok =
               PersonRecordSchema.validate(:status_change, %{
                 "changeType" => "pay_change",
                 "description" => "Annual raise"
               })
    end

    test "rejects an invalid changeType" do
      assert {:error, [_ | _]} =
               PersonRecordSchema.validate(:status_change, %{
                 "changeType" => "not_a_real_type",
                 "description" => "..."
               })
    end
  end

  describe "validate/2 — :rank_history (APERSP-01-flavored)" do
    test "accepts a well-formed grade code" do
      assert :ok =
               PersonRecordSchema.validate(:rank_history, %{
                 "grade" => "OF-3",
                 "effectiveDate" => "2026-01-01"
               })
    end

    test "accepts the OF(D) special case" do
      assert :ok =
               PersonRecordSchema.validate(:rank_history, %{
                 "grade" => "OF(D)",
                 "effectiveDate" => "2026-01-01"
               })
    end

    test "rejects a grade that doesn't match the OF-n/OR-n shape" do
      assert {:error, [_ | _]} =
               PersonRecordSchema.validate(:rank_history, %{
                 "grade" => "Colonel",
                 "effectiveDate" => "2026-01-01"
               })
    end
  end

  describe "validate/2 — :contact_info (STANAG 5046-flavored)" do
    test "accepts a well-formed contact" do
      assert :ok =
               PersonRecordSchema.validate(:contact_info, %{
                 "contactType" => "phone",
                 "value" => "+1-555-0100"
               })
    end

    test "rejects an unknown contactType" do
      assert {:error, [_ | _]} =
               PersonRecordSchema.validate(:contact_info, %{
                 "contactType" => "carrier_pigeon",
                 "value" => "..."
               })
    end

    test "accepts \"use\" — the genuinely FHIR-verified ContactPoint.use addition" do
      assert :ok =
               PersonRecordSchema.validate(:contact_info, %{
                 "contactType" => "phone",
                 "value" => "+1-555-0100",
                 "use" => "mobile"
               })
    end

    test "rejects an unknown \"use\" value" do
      assert {:error, [_ | _]} =
               PersonRecordSchema.validate(:contact_info, %{
                 "contactType" => "phone",
                 "value" => "+1-555-0100",
                 "use" => "not_a_real_use"
               })
    end
  end

  describe "validate/2 — :language_proficiency (STANAG 6001-flavored)" do
    test "accepts scores within the 0-5 SLP range" do
      assert :ok =
               PersonRecordSchema.validate(:language_proficiency, %{
                 "language" => "English",
                 "listening" => 3,
                 "speaking" => 3,
                 "reading" => 4,
                 "writing" => 3
               })
    end

    test "rejects a score outside 0-5" do
      assert {:error, [_ | _]} =
               PersonRecordSchema.validate(:language_proficiency, %{
                 "language" => "English",
                 "listening" => 6,
                 "speaking" => 3,
                 "reading" => 4,
                 "writing" => 3
               })
    end

    test "accepts \"preferred\" — the FHIR Patient.communication.preferred addition" do
      assert :ok =
               PersonRecordSchema.validate(:language_proficiency, %{
                 "language" => "uk",
                 "listening" => 5,
                 "speaking" => 5,
                 "reading" => 5,
                 "writing" => 5,
                 "preferred" => true
               })
    end
  end

  describe "validate/2 — :family_status" do
    test "accepts a minimal valid record" do
      assert :ok = PersonRecordSchema.validate(:family_status, %{"maritalStatus" => "married"})
    end

    test "accepts the full shape" do
      assert :ok =
               PersonRecordSchema.validate(:family_status, %{
                 "maritalStatus" => "married",
                 "spouseName" => "Jordan Doe",
                 "dependentsCount" => 2,
                 "emergencyContactName" => "Jordan Doe",
                 "emergencyContactRelationship" => "spouse",
                 "emergencyContactPhone" => "+1-555-0100",
                 "note" => "Updated after relocation."
               })
    end

    test "rejects an invalid maritalStatus" do
      assert {:error, [_ | _]} =
               PersonRecordSchema.validate(:family_status, %{"maritalStatus" => "not_a_status"})
    end

    test "rejects a negative dependentsCount" do
      assert {:error, [_ | _]} =
               PersonRecordSchema.validate(:family_status, %{
                 "maritalStatus" => "single",
                 "dependentsCount" => -1
               })
    end
  end

  describe "validate/2 — :compensation" do
    test "accepts a minimal valid record" do
      assert :ok =
               PersonRecordSchema.validate(:compensation, %{
                 "amount" => 5000,
                 "currency" => "USD",
                 "effectiveDate" => "2026-01-01",
                 "reason" => "promotion"
               })
    end

    test "rejects an invalid reason" do
      assert {:error, [_ | _]} =
               PersonRecordSchema.validate(:compensation, %{
                 "amount" => 5000,
                 "currency" => "USD",
                 "effectiveDate" => "2026-01-01",
                 "reason" => "not_a_real_reason"
               })
    end

    test "rejects a currency code of the wrong length" do
      assert {:error, [_ | _]} =
               PersonRecordSchema.validate(:compensation, %{
                 "amount" => 5000,
                 "currency" => "US",
                 "effectiveDate" => "2026-01-01",
                 "reason" => "promotion"
               })
    end
  end

  describe "validate/2 — :dependent" do
    test "accepts a minimal valid record" do
      assert :ok =
               PersonRecordSchema.validate(:dependent, %{
                 "name" => "Sam Doe",
                 "relationship" => "child"
               })
    end

    test "accepts the full shape" do
      assert :ok =
               PersonRecordSchema.validate(:dependent, %{
                 "name" => "Sam Doe",
                 "relationship" => "child",
                 "dateOfBirth" => "2018-05-01",
                 "note" => "Lives with the other parent half the year."
               })
    end

    test "rejects a record missing the required \"name\"" do
      assert {:error, [_ | _]} =
               PersonRecordSchema.validate(:dependent, %{"relationship" => "child"})
    end

    test "rejects an invalid relationship" do
      assert {:error, [_ | _]} =
               PersonRecordSchema.validate(:dependent, %{
                 "name" => "Sam Doe",
                 "relationship" => "not_a_real_relationship"
               })
    end
  end

  describe "validate/2 — :security_clearance v2 (NATO markings; details moved to :vetting_record)" do
    test "accepts a minimal valid record" do
      assert :ok =
               PersonRecordSchema.validate(:security_clearance, %{
                 "clearanceLevel" => "NATO_SECRET",
                 "status" => "granted"
               })
    end

    test "accepts the full shape" do
      assert :ok =
               PersonRecordSchema.validate(:security_clearance, %{
                 "clearanceLevel" => "COSMIC_TOP_SECRET",
                 "status" => "granted",
                 "grantedDate" => "2026-01-01",
                 "expiryDate" => "2031-01-01"
               })
    end

    test "rejects v1 level names and v1 investigation fields" do
      assert {:error, _} =
               PersonRecordSchema.validate(:security_clearance, %{
                 "clearanceLevel" => "SECRET",
                 "status" => "granted"
               })

      assert {:error, _} =
               PersonRecordSchema.validate(:security_clearance, %{
                 "clearanceLevel" => "NATO_SECRET",
                 "status" => "granted",
                 "investigatingAuthority" => "National Security Service"
               })
    end

    test "rejects an invalid clearanceLevel" do
      assert {:error, [_ | _]} =
               PersonRecordSchema.validate(:security_clearance, %{
                 "clearanceLevel" => "ULTRA_CLASSIFIED",
                 "status" => "granted"
               })
    end

    test "rejects an invalid status" do
      assert {:error, [_ | _]} =
               PersonRecordSchema.validate(:security_clearance, %{
                 "clearanceLevel" => "NATO_SECRET",
                 "status" => "not_a_real_status"
               })
    end
  end

  describe "validate/2 — :fitness_for_duty" do
    test "accepts each readiness status" do
      for status <- ["fit_for_duty", "downgraded", "non_effective"] do
        assert :ok = PersonRecordSchema.validate(:fitness_for_duty, %{"status" => status})
      end
    end

    test "rejects an unknown status and extra fields such as a diagnosis" do
      assert {:error, _} = PersonRecordSchema.validate(:fitness_for_duty, %{"status" => "ok"})

      assert {:error, _} =
               PersonRecordSchema.validate(:fitness_for_duty, %{
                 "status" => "downgraded",
                 "diagnosis" => "Asthma"
               })
    end
  end

  describe "validate/2 — :allergy_intolerance" do
    test "accepts a FHIR-shaped record" do
      assert :ok =
               PersonRecordSchema.validate(:allergy_intolerance, %{
                 "code" => %{"text" => "Penicillin"},
                 "clinicalStatus" => "active",
                 "criticality" => "high",
                 "category" => ["medication", "food"],
                 "reactionManifestation" => "Anaphylaxis",
                 "reactionSeverity" => "severe"
               })
    end

    test "category is a list since x-version 2; old single values are upgraded" do
      old = %{
        "code" => %{"text" => "Penicillin"},
        "clinicalStatus" => "active",
        "category" => "food"
      }

      assert {:error, _} = PersonRecordSchema.validate(:allergy_intolerance, old)

      upgraded = RecordMigrations.upgrade_to_current(:allergy_intolerance, 1, old)
      assert upgraded["category"] == ["food"]
      assert :ok = PersonRecordSchema.validate(:allergy_intolerance, upgraded)
    end

    test "requires a substance and rejects unknown criticality" do
      assert {:error, _} =
               PersonRecordSchema.validate(:allergy_intolerance, %{"clinicalStatus" => "active"})

      assert {:error, _} =
               PersonRecordSchema.validate(:allergy_intolerance, %{
                 "code" => %{"text" => "Peanut"},
                 "clinicalStatus" => "active",
                 "criticality" => "extreme"
               })
    end
  end

  describe "validate/2 — :vetting_record" do
    test "accepts investigation details" do
      assert :ok =
               PersonRecordSchema.validate(:vetting_record, %{
                 "investigationType" => "periodic_review",
                 "investigatingAuthority" => "National Security Service",
                 "outcome" => "favourable"
               })
    end

    test "rejects an unknown outcome" do
      assert {:error, _} =
               PersonRecordSchema.validate(:vetting_record, %{"outcome" => "maybe"})
    end
  end

  test "normalize/2 drops blank fields so untouched optional ones count as not provided" do
    data = %{
      "code" => %{"text" => "Peanut"},
      "clinicalStatus" => "active",
      "criticality" => "",
      "note" => ""
    }

    assert PersonRecordSchema.normalize(:allergy_intolerance, data) ==
             %{"code" => %{"text" => "Peanut"}, "clinicalStatus" => "active"}

    assert :ok ==
             PersonRecordSchema.validate(
               :allergy_intolerance,
               PersonRecordSchema.normalize(:allergy_intolerance, data)
             )
  end

  test "normalize/2 turns submitted strings into the schema's numbers and booleans" do
    submitted = %{
      "language" => "fr",
      "listening" => "3",
      "speaking" => " 4 ",
      "reading" => "2",
      "writing" => "1",
      "preferred" => "false"
    }

    normalized = PersonRecordSchema.normalize(:language_proficiency, submitted)
    assert %{"listening" => 3, "speaking" => 4, "preferred" => false} = normalized
    assert :ok == PersonRecordSchema.validate(:language_proficiency, normalized)

    assert %{"amount" => 25_000, "previousAmount" => 1250.5} =
             PersonRecordSchema.normalize(:compensation, %{
               "amount" => "25000",
               "previousAmount" => "1250.5"
             })

    # Unparseable values are left for validation to report.
    assert %{"listening" => "a lot"} =
             PersonRecordSchema.normalize(:language_proficiency, %{"listening" => "a lot"})
  end

  test "validate/2 rejects an unknown kind with a descriptive error" do
    assert {:error, [error]} = PersonRecordSchema.validate(:not_a_real_kind, %{})
    assert error =~ "unknown PersonRecord kind"
  end
end
