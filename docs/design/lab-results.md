# Lab results

Status: **done** (2026-10-08). The user's batch C12 (then B7 business-trip
report and allowances, then small leftovers). On the clinical module
(`docs/design/clinical-module.md`).

## Decisions

- A record kind **`lab_result`**: one test, its value and when the sample
  was taken; optionally the laboratory and a note; may sit inside an
  encounter. Category **medical** (like conditions: clinicians and nurses
  read and write; the combat medic doesn't; every read is in the access
  log).
- **Tests** from the app's own list `priv/clinical/lab_tests.json`
  (`App.Clinical.LabTests`): about twenty common ones — blood count,
  glucose and HbA1c, kidney and liver tests, electrolytes, CRP, INR,
  troponin, lactate, cholesterol — with LOINC code, names in English,
  Ukrainian and French, unit and an adult reference range. **The ranges
  are placeholders** (each laboratory reports its own) and the LOINC codes
  are to verify against loinc.org.
- The server sets, never the form: **unit**, **reference range**, the flag
  **low / normal / high**, and the **previous value** of the same test
  (the latest earlier sample), for comparison.
- **FHIR:** an Observation of category `laboratory` with the LOINC code,
  `valueQuantity`, `referenceRange` and `interpretation` (L / N / H);
  `/fhir/R5/Observation` serves vital signs and lab results.

## Model

- `PersonRecordSchema`: a property marked `"x-system": "value"` is shown
  on the record card (after the form's fields) and never in the form —
  how server-set values are displayed.
- `App.Clinical.Changes.InterpretLab` (pure part, then the previous value
  in a before-action hook, like `CodeMedication`).
- `App.People.RecordDates` takes `collectedAt` as the record's date.
- Demo: about a quarter of people have two haemoglobin results a month
  apart and some a potassium result (values from the seed key, no random
  calls); reference set 1955 records, 45 expected violations.

## Later

- Panels entered together (a full blood count in one form) and a trend
  chart per test, as for vital signs.
- Lab results as examinations for the "identity before examination" rule.
- Ranges by sex and age; the laboratory's own range on the result.
