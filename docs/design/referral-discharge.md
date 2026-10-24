# Referral → discharge summary → sick leave

Status: **done** (2026-09-29). On the documents core
(`docs/design/documents-core.md`); product direction item 5.

## Decisions (user, 2026-09-29)

- **Care providers**: every organization providing medical care is kept
  in a searchable register with its details. "Internal medical units" are
  those marked **priority** in it: they need no service contract or other
  paperwork (transfer of information to third parties, system access by
  another organization). They are listed first.
- **Sick leave is created from the discharge summary**: the doctor issues
  it in the summary, and when the summary is signed it becomes the
  person's absence automatically.
- **A discharge summary is signed by the treating clinician and the head
  of department.**
- Built in order: referral → discharge summary, then sick leave.

## Model

- **`App.Care.Provider`** (FHIR Organization with a healthcare type):
  name, type, priority, registry code, country, locality, address,
  contacts, agreement and its end date (external providers), active,
  a link to our unit (priority units). Read with `people.read`, written
  with `providers.manage` (admin role, registrar profile). Page
  `/care-providers`: search and filters, priority first.
- **Referral** `care_referral` (FHIR ServiceRequest; register `напр`,
  category medical): provider, service, priority (FHIR request
  priority), reason and ICD-10 code, planned date. Signed by the
  referring clinician; signing opens the discharge summary draft for the
  provider (`open_discharge_summary`).
- **Discharge summary** `discharge_summary` (FHIR Composition, discharge
  summary; register `вип`, category medical): provider, type of care,
  admission and discharge dates, diagnosis and ICD-10 code, treatment,
  outcome, recommendations, sick leave from–to. Route: the treating
  clinician approves, the head of department signs (`medical.sign`, new
  profile `head_of_department`, unit scope). A summary from an external
  provider is entered by our clinician from the paper one, the same way.
- **Sick leave** (`sick_leave` effect): a signed summary with a period
  records a `leave` record of type `sick` whose basis is the summary's
  number — HR sees the absence, never the diagnosis. The leave rules
  (overlap) apply to it like any recorded leave.

## Handling unit

The fields of a document are encrypted, so a read filter can't see which
provider it names. `Document.handling_unit_id` keeps, in plain form, the
unit of the post (orders) or the priority provider (care documents) the
document names; unit-scoped users of that unit read and handle it as well
as those of the person's unit. So the Role 3 hospital handles the summary
of a patient from any battalion. It replaces the lookup of the post's
unit that orders had.

## Not yet

- A referral to the medical board from a summary's recommendation.
- Importing providers from a national register (needs the data source).
- Encounters and vital signs linked to the summary.
