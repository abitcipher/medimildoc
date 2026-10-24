# Documents core, first process: the medical board

Status: **first release done**. Follows
`docs/design/product-direction.md`.

## Decisions (user, 2026-09-29)

- **First process: the medical board for newcomers** (fitness and severity
  assessment with recommendations), with re-examinations scheduled.
  Personnel orders come next, on the same core.
- **Neutral core + Ukrainian templates**: the engine follows ISO 15489
  (unique numbers per register, fixed metadata, append-only history,
  retention); printed forms follow Ukrainian requisites (ДСТУ 4163);
  other formats are templates added later.
- **Internal signatures first**: who signed, when, and SHA-256 of the
  signed content and of the PDF; qualified signatures (КЕП / eIDAS) later.
- **Typst** renders the PDF (static binary in the image, PDF/A-2b),
  **Liberation Serif** (SIL OFL, Times-compatible) vendored in
  `priv/fonts`.

## Model (Ash domain `App.Documents`)

- **Document type** — `priv/document_types/<type>.json`, like record
  kinds: label, icon, category (access), numbering pattern, JSON Schema +
  UI Schema of the fields, route, Typst template, effects, retention, the
  types it may be based on. Adding a type needs no code unless it has a
  new effect.
- **Document** — type, person (subject), author, state, fields (`data`,
  encrypted at rest like records, reads of medical documents in the access
  log), basis document, due date (scheduled documents), number and
  registration date (set when signed), signer, content hash, PDF key and
  hash.
- **Lifecycle** (`ash_state_machine`): `draft → in_review → signed`;
  `in_review → draft` when returned (with a comment); `draft | in_review
  → cancelled`. Signing assigns the number, renders and stores the PDF
  and applies the effects in one transaction. A signed document is never
  edited or deleted; it can only be followed by another document.
- **Route steps** — created when the author sends the draft: one step per
  route entry (approve / sign), each with an assignee chosen from users
  holding the step's permission; a route entry may allow several
  assignees (board members). Sequential. The assignee of the current step
  approves, returns, or (last step) signs.
- **History** — append-only events (created, sent, approved, returned,
  signed, cancelled, effect applied) with actor and comment.
- **Registers** — each type names a register (`code`, display `format`);
  a counter per (register, year), taken under a row lock, so numbers are
  unique and never reused; a cancelled draft has no number.

## Registers and identifiers (user, 2026-09-29)

No standard fixes the *human* number: ISO 15489 and FHIR require a unique
identifier plus registration metadata (register, date, author) and leave
the format to local rules. Chosen:

- **Stored structured**: `register` (code, e.g. `ос`), `register_year`,
  `register_seq`; unique together. `number` is their display.
- **Displayed in the Ukrainian record-keeping style**: sequence and
  register index, `15-ос`; the registration date is a separate requisite
  (`№ 15-ос від 29.09.2026`); numbering restarts every year. (As
  understood from the national standard instruction on record-keeping,
  CMU resolution No. 55 of 2018 — to be checked against the current text.)
- **Identifiers in FHIR form** (`Types.identifiers/1`): `masterIdentifier`
  `urn:uuid:<id>` (stable, global), `identifier` `{system:
  urn:hrda:register:<code>:<year>, value: "15-ос"}`.
- Documents signed under the first patterns (`НВЛК-2026-0001`,
  `0001-ОС/2026`) keep their printed number — it is part of what was
  signed — and got their structured fields filled in; counters continue.

## Access

Each type names its permissions (`access` in its JSON): any one of its
`read` permissions lets an actor read it, its `write` permission lets
them create and edit drafts, with the unit scope those permissions have.
The type's category only says how sensitive it is (reads of sensitive
categories are in the access log).

- Referral: category `personnel_private` (logged); read by HR
  (`people.hr_private.read`) and medical staff (`medical.read`, the board
  needs the questions); written by HR (`people.write`). Found in the UI
  tests: with the `personnel` category every user who can see people
  could have read it.
- Conclusion: category `medical`; read `medical.read`, write
  `medical.write` (clinicians write; command surgeon and nurse read).

HR and commanders learn the result only through the effect on **fitness
for duty** (readiness), never the diagnoses. Route actions need the
current step's assignee.

## The medical board process

1. **Referral to the medical board** (`medical_board_referral`, HR):
   reason (entry examination of a newcomer, periodic, re-examination,
   after illness or injury, other), questions for the board, planned
   date. Signed by an HR signatory. **Effect:** a draft conclusion for the
   board, based on the referral.
2. **Medical board conclusion** (`medical_board_conclusion`, clinicians):
   - examinations by the standard panel (therapist, surgeon, neurologist,
     psychiatrist, ophthalmologist, ENT, dentist, dermatologist): findings
     and each specialist's opinion;
   - main and concomitant diagnoses with an optional ICD-10 code (pattern
     only, no bundled code list) and severity;
   - **functional limitation** on the WHO ICF generic qualifier scale
     (no, mild, moderate, severe, complete);
   - **conclusion**: fit; fit with restrictions; temporarily unfit (with a
     re-examination date); unfit — neutral categories with Ukrainian
     labels, not a quotation of any regulation;
   - duty restrictions (list + text, no diagnosis), recommendations
     (treatment, follow-up, workplace);
   - route: board members approve, the chair signs.
   **Effects:** a fitness-for-duty record (status, restrictions, review
   date, assessed by the board, basis = conclusion number); if a
   re-examination date is set, a scheduled referral due then.
3. **Inbox** (`/tasks`): my steps to approve or sign; my returned drafts;
   drafts waiting for my team (conclusions for clinicians); scheduled
   referrals due within 30 days (HR).

## Later

Personnel orders on the same core; parallel approvals; delegation and
deadlines with reminders; qualified signatures; acquaintance lists;
retention and disposal; FHIR export of the conclusion.

## Personnel orders (2026-09-29)

Decisions (user): one person per order; orders preferred, direct changes
to assignments remain and are logged as corrections; a new **Commander**
profile (unit scope, permission `orders.sign`) signs; four kinds.

- Types `personnel_order_appointment`, `_transfer`, `_dismissal`,
  `_grade`, one register `0001-ОС/2026`. Route: head of HR approves
  (`people.write`), commander signs (`orders.sign`). Read by HR
  (`people.hr_private.read`) and commanders; category `personnel`.
- Effects: appointment starts an assignment; transfer ends the current
  one the day before and starts the new one; release ends it; grade adds
  a `rank_history` record. `Effects.check/1` runs when the order is sent
  and again before signing (someone who already holds a post can't be
  appointed; a transfer after the current post started; …).
- Assignments keep their orders (`basis_document_id`, `end_document_id`)
  via the internal actions `:from_order` / `:end_by_order` (closed to
  actors). The person page shows "№ 0001-ОС/2026" under the dates.
- **Who may sign**: a commander whose unit covers the person **or the post
  the order names** — a newcomer is in no unit yet, so the commander of
  the unit they join signs their appointment (found by the tests).
- Direct changes (`:create`, `:update`, `:destroy` on assignments) write an
  `App.Audit.Correction` (who, when, what changed); listed under "Direct
  changes (without an order)" on the change-conflicts page (`audit.read`).
- The post field (`x-entity: "position"`) is a dropdown of short post
  labels; the page and the PDF show the label.
