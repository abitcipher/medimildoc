# Product direction: from records to processes

Status: **proposal** (2026-09-29), for the user's decision. Written after
the user's review: "interacting with spreadsheets offers little real value
… we are automating a massive organization that provides employment and
medical care; we need to fully automate the document workflows governing
these processes, adhering to best practices and standards."

## 1. Where we are (honest assessment)

What works today is a **secure registry**:

- people, organisations (NATO-style units), posts with strength, and
  assignment history;
- typed records per person (JSON Schema forms), point-of-care clinical
  records (encounters, vital signs with NEWS2, medications given,
  procedures, allergy checks);
- files, fine-grained access (roles, profiles, unit scope, clearances,
  break-the-glass), encryption at rest, access log, conflict log;
- three languages, the Google Sheets sidebar, `.xlsx` import/export.

What a user of an HR/ERP or hospital system would miss is **everything
that makes a change official**. Today a record is simply edited. In the
organisation we model, almost nothing changes that way:

- a person is appointed, moved, sent on leave or dismissed **by an order**
  (наказ) that someone drafts, others approve, a commander signs, a
  registry numbers, and people are made acquainted with;
- a person asks for something **by a request** (рапорт, заява) that goes
  up the chain and comes back decided;
- a patient is **referred**, examined, discharged with a **summary**, and
  a **medical board** (ВЛК) decides fitness, which HR must act on;
- every one of these documents has a number, a date, signatures, a
  retention period and an audit trail, and someone is **responsible for
  doing something by a deadline**.

The Sheets sidebar does not change this picture: it is a view and
should stay a secondary channel (exports, bulk review). New investment
goes into the web application.

## 2. Target: a document and workflow core, then processes on top

### 2.1 Core (one engine, used by every process)

| Piece | What it does | Standard / best practice |
|---|---|---|
| **Document types** declared in JSON (like record kinds): fields (JSON Schema + UI Schema), route, template, numbering rule, retention, effect | adding a document type needs no code, as with record kinds | ISO 15489 (records management), MoReq2010 metadata; national rules for organisational documents (in Ukraine ДСТУ 4163) |
| **Document** with a lifecycle: draft → in approval → approved → signed → registered → in force → executed / cancelled | state machine, every transition logged with who/when/why | ISO 15489 audit trail; our change-conflict log |
| **Approval routes**: sequential and parallel steps, by role or by post in the chain of command, with deadlines, delegation, return for rework | the chain of command already exists (posts, "reports to") | BPMN 2.0 concepts (user task, gateway), kept declarative in JSON |
| **Tasks and inbox** ("my tasks"): what waits for me to approve, sign, acknowledge or execute, with due dates and overdue marks | the first screen for most users instead of a list of people | standard in every ERP/EDMS |
| **Registration**: registers (journals) with numbering per type and year, incoming/outgoing/internal, file plan (номенклатура справ) | numbers are never reused; cancelled documents stay | ISO 15489, national records rules |
| **Printed form**: PDF generated from a template, with a hash; the signed PDF becomes the document of record | PDF/A for long-term archive | ISO 19005 (PDF/A) |
| **Signatures**: first an internal signature (who, when, hash of the exact text, recorded server-side); later qualified electronic signatures | the model stores signature containers, so a qualified provider can be plugged in | eIDAS / PAdES, ASiC (in Ukraine КЕП, e.g. via a qualified trust service provider) |
| **Effects**: a signed document *does* something: an appointment order creates the assignment, a medical board conclusion sets fitness for duty | links documents to the data they change; no direct edits for such data | "no change without a basis document" |
| **Notifications**: in the app, by e-mail later | tasks, deadlines, results | — |

### 2.2 HR processes (employment)

1. **Personnel orders**: appointment, transfer, dismissal, rank/grade,
   leave, business trip; each creates or ends assignments and records
   when signed. Assignments stop being edited directly (the Sheets and
   `.xlsx` import become *draft orders*, not direct writes).
2. **Requests** (рапорт / заява): leave, transfer, certificate; routed up
   the chain; the decision can start an order.
3. **Personnel file** (особова справа): the person page becomes the file:
   all documents, orders and acquaintances in one timeline.
4. **Leave and absence**: types, balances, calendar, conflicts with duty.
5. **Certificates** (довідки) generated on request from data already held.

### 2.3 Medical processes (care)

1. **Long-term medication list** (FHIR MedicationStatement) — next, agreed.
2. **Referral → encounter → discharge summary** (FHIR ServiceRequest,
   Encounter, Composition/DocumentReference), the summary as a signed
   document.
3. **Medical board (ВЛК / fitness board)**: referral, examinations, a
   conclusion signed by the board; its effect updates fitness for duty
   and notifies HR and the commander (only the conclusion, not the
   diagnosis).
4. **Sick leave** linking medical and HR: the certificate from care, the
   absence in HR.
5. **Lab results** (FHIR Observation with reference ranges), later.
6. **Interoperability**: a FHIR R5 REST endpoint for exchange (read first),
   HL7 v2 ADT messages if a hospital system needs them.

### 2.4 Usability, across everything

- **Inbox first**: each user starts from their tasks and deadlines.
- **Global search** (people, documents by number, orders) from the header.
- **Person timeline**: one chronological view of assignments, documents,
  care events.
- **Bulk actions** where the work is bulk (acquainting a unit with an
  order, exporting a register).
- Keep what the user asked for: no decorative text, help in ⓘ icons,
  nothing that overflows.

## 3. Proposed order

1. **Long-term medication list** (small, agreed; reuses the drug list and
   allergy check).
2. **Document core, first slice**: document types in JSON, lifecycle,
   sequential approval route by post, inbox, register numbering, PDF,
   internal signature. First type: **personnel order on appointment /
   transfer**, whose effect creates the assignment.
3. **Requests** (leave request → leave order) and **leave balances**.
4. **Medical board** conclusion as a document with an effect on fitness.
5. **Referral → discharge summary**, sick leave.
6. Global search, person timeline, notifications by e-mail.
7. FHIR read API; qualified signatures.

## 4. Decisions needed from the user

- **Order of section 3**, or a different first process.
- **Which national rules to follow first** for document requisites and
  registers (Ukrainian ДСТУ 4163 and military record-keeping rules, NATO
  staff procedures, or a neutral format with national templates later).
- **Signatures**: internal first (recommended), qualified electronic
  signatures later — which provider, when needed.
- **New dependencies** (to be justified in the PR):
  `ash_state_machine` (Ash's own state machine extension) for lifecycles;
  a PDF renderer (options: ChromicPDF with headless Chromium in the
  container, or Typst as a small binary; Typst gives better typography
  for official forms and no browser).
