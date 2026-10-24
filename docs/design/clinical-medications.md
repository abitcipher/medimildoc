# Clinical module 2: medications given and procedures

Status: **done** (2026-09-28). Follows
`docs/design/clinical-module.md` (encounters, vital signs).

## Decisions (user, 2026-09-28)

- **Given medications and procedures**, recorded inside an encounter like
  vital signs (category `care`). A long-term **medication list** (FHIR
  MedicationStatement, category `medical`) may come later: the data and
  code below are shaped so it can reuse them.
- **Drug names from the app's own short INN list** (no licensed coding
  system), plus free text for anything else.
- **Allergy match: warn, allow saving**; the record notes the match.
- **Who records:** everyone with `care.write` (combat medic, nurse,
  clinician, command surgeon), unit scope as for other care records.

## Records

- `medication_administration` (FHIR MedicationAdministration-flavored):
  drug (`medication.text` + `medication.coding`), dose (`value` + `unit`),
  route, time given (`occurrence`), status (given / being given / not
  given / entered in error), site, reason, notes; `allergyWarning` set by
  the server.
- `procedure` (FHIR Procedure-flavored): the intervention from a list in
  TCCC MARCH order (tourniquets, wound packing, airways, chest seal, needle
  decompression, IV/IO access, transfusion, pelvic binder, hypothermia
  prevention, splint, …, other), details, time done and ended (a
  tourniquet converted or removed), status, body site, side, outcome.

Both may belong to an encounter (`x-part-of`). Route and procedure codes
are the app's own: FHIR uses SNOMED CT for them, which needs a licence.

## Shared pieces (for the future medication list)

- **Drug list** — `priv/clinical/drugs.json`, `App.Clinical.Drugs`: 71
  common field and emergency drugs by WHO International Nonproprietary
  Name, with Ukrainian and French names, other usual names (adrenaline,
  aspirin, TXA), drug classes (used only for allergy matching), usual
  routes and dose unit. Not a formulary: no doses or indications.
- **Medication shape** — `medication: {text, coding}` (FHIR
  CodeableConcept; coding system `urn:hrda:drug`, code = the list id) and
  `dose: {value, unit}`. A schema field `"x-suggest-list": "drugs"` gives
  the drug suggestions (`<datalist>`, names in the user's language, any
  text allowed).
- **Allergy check** — `App.Clinical.AllergyCheck`: a drug matches an active
  allergy whose substance names the drug (any language), one of its
  classes, or another listed drug sharing a class (amoxicillin allergy →
  ceftriaxone: beta-lactam). Classes count with their wider class
  (`class_parents`: penicillins, cephalosporins and carbapenems are
  beta-lactams; salicylates are NSAIDs), so a penicillin allergy warns for
  ceftriaxone. Whole words, or prefixes of 5+ letters for inflected forms.
- **`App.Clinical.Changes.CodeMedication`** — on save of any kind with a
  `medication` drug field: sets the coding (before validation) and the
  allergy warning (before the write, reading allergies without an actor;
  never blocks). Neither value can come from the form.

## Screens

- The form warns under the fields as soon as the drug matches (with
  "high risk" for a high-criticality allergy); saving stays possible.
- Record cards show the stored warning (schema `"x-system": "alert"`)
  and the dose with its unit (`"x-unit-field"`; the unit field itself is
  `"x-card": false`).

## Demo data

Demo encounters get treatment: for injuries IV access, ketamine or oral
transmucosal fentanyl, moxifloxacin, and for bleeding a limb tourniquet
(later converted) with tranexamic acid; for illness paracetamol and
ondansetron.

## Long-term medication list (2026-09-29)

Agreed next step (user). Kind `medication_statement` (FHIR R5
MedicationStatement-flavored): drug, dose, route, how often (a short list
plus instructions in words, FHIR renderedDosageInstruction), taking / on
hold / stopped / not taking / unknown (R5 `adherence`, kept apart from the
record status as R5 does), since / until, reason, source of the
information, notes. Coding and the allergy warning come from the same
`App.Clinical.Changes.CodeMedication`.

- **Category `care`**, not `medical` as first suggested: point-of-care
  staff need current medicines (anticoagulants, insulin) as they need
  allergies. Clinicians see them too.
- **Drug list v2**: 28 common long-term drugs added (99 in total) with
  classes that allergies and warnings name (ACE inhibitors, sartans, beta
  blockers, statins, SSRIs, anticoagulants, antiplatelets, antihistamines,
  proton pump inhibitors, insulin…); heparins count as anticoagulants.
- **Person page**: a status chip with the number of current medicines
  (taking or on hold), the list in the viewer's language in its tooltip,
  and a warning colour plus "blood thinner" when one is an anticoagulant or
  antiplatelet.
- **Demo**: people with an active condition get a matching regimen
  (hypertension, asthma, type 2 diabetes, atrial fibrillation).

## Interactions (2026-10-07, user's batch C11)

- On saving a given medication or a medication-list entry, the server
  sets `interactionWarning` (like `allergyWarning`: never blocks, never
  taken from the form) when the coded drug meets what the person **takes
  now** (medication list, not stopped or ended) or **was given in the
  last 24 hours** (local time): a listed interaction (by drug, class or
  group), the same drug again, or a second drug of a class where one is
  enough (NSAIDs, opioids, benzodiazepines, anticoagulants, …).
- The list: `priv/clinical/interactions.json` (`App.Clinical.Interactions`,
  checked against `drugs.json` at compile time) — about twenty textbook
  pairs and groups (QT-prolonging, serotonergic, CNS depressants).
  **Illustrative, not a clinical knowledge base:** verify with a
  pharmacist; no warning means nothing.
- The text is English (INN names and a short effect, with severity
  major / moderate / minor); the list keeps Ukrainian and French notes for
  a localized display later.
- Later: localized display; a licensed interaction source if the
  organisation gets one.
