# First clinical module: encounters and vital signs

Status: **done**. Roadmap item "first clinical
module". FHIR-aligned (Encounter, Observation with the vital-signs
profile), built on the existing modular record kinds.

## Decisions (user, 2026-09-27)

1. **Access — new point-of-care category `care`.** Allergies, encounters
   and vital signs belong to it (allergies move there from `medical`).
   Permissions `care.read` / `care.write`. Profiles:
   - **combat medic** (unit): `people.read`, `care.read`, `care.write`;
   - **nurse** (unit): `people.read`, `care.*`, `medical.read`,
     `readiness.read`;
   - clinician: plus `care.*`; command surgeon: plus `care.read`.
   Reads of `care` records are in the access log (sensitive category).
   Break the Glass still gives allergies only.
2. **Field care on encounters:** NATO triage category (T1 immediate, T2
   delayed, T3 minimal, T4 expectant), evacuation priority (urgent,
   priority, routine — as in a 9-line MEDEVAC request), mechanism of
   injury, disposition.
3. **Warnings:** values outside adult reference ranges are flagged; the
   NEWS2 early-warning score and its risk level are computed (Royal College
   of Physicians, attribution in the footer).
4. **Trends:** the app's own SVG sparklines per vital sign (no library).

## Data

- `encounter` kind (FHIR Encounter subset): status, class (HL7 ActCode:
  emergency, field, ambulatory, inpatient, virtual), start and end
  (date and time), reason, location, practitioner (suggestions from
  earlier entries), triage, evacuation priority, mechanism of injury,
  disposition, note.
- `vital_signs` kind (FHIR vital-signs Observations, one record per set of
  measurements): measured at (date and time), systolic/diastolic blood
  pressure, heart rate, respiratory rate, SpO₂, on supplemental oxygen,
  temperature, consciousness (ACVPU), GCS, pain 0–10. Each field carries
  its LOINC code (`x-loinc`) for FHIR export later.
- `PersonRecord.part_of_id`: a record can belong to another record of the
  same person (vital signs within an encounter). General, reusable for
  procedures and medications later.
- Date-time fields are entered as `dd.mm.yyyy HH:MM` (24 h), stored as ISO
  8601 in UTC-free local form (`2026-09-27T14:05`).

## Resources

LOINC codes (free, attribution: "This material contains content from
LOINC® (https://loinc.org), © Regenstrief Institute, Inc."); HL7 v3
ActCode encounter classes; NATO triage categories; NEWS2 (RCP, free to
use with attribution). No new icons, fonts or libraries.
