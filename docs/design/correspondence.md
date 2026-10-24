# Incoming and outgoing correspondence

Status: **done** (2026-10-07). The step after
`docs/design/registers-file-plan.md` (user's order: correspondence, then
closing cases and the inventory, then the case index on prints, then the
deputies screen, the leave-limit rule and the "fitness only from a signed
conclusion" rule).

## Decisions (2026-10-07)

- **Letters are documents** on the same core (`docs/design/documents-core.md`):
  types `incoming_letter` (register `вх`) and `outgoing_letter` (register
  `вих`), JSON Schema forms, routes, numbers, PDF, hash, file plan cases.
- **No person:** a type with `"subject": "none"` has no person; its unit
  is the one the letter is addressed to or sent from (field `unit` →
  `Document.handling_unit_id`), which is what unit-scoped readers and
  signers are checked against.
- **Incoming:** the records officer enters the letter (sender, their
  number and date, received on, summary, delivery, unit addressed) with
  its scan, and registers it — a one-step route signed by
  `records.manage`; the page offers "Register" (send to oneself and sign
  in one go). The number is `N-вх`, the PDF is a registration card.
- **Instructions (резолюції / доручення):** on a registered incoming letter
  a head (`orders.sign` covering its unit) or the records officer gives
  one or more instructions: text, executor, due date. The executor sees
  the letter in their tasks with the deadline (overdue marks, the count,
  reminders), and closes the instruction with a note — or by a reply.
  The executor may read the letter.
- **Outgoing:** written by the records officer or by an executor as a
  reply (basis: the incoming letter); route: the records officer checks
  (approve), the head of the sending unit signs; the number `N-вих` comes
  with the signature. Signing a reply closes the open instructions on its
  incoming letter.
- **Files on documents:** scans and attachments belong to the document
  (`App.Documents.DocumentFile`), uploaded while it is a draft, read only
  through the document; their SHA-256 is part of the signed content hash.
- **Access:** correspondence is readable by records officers
  (`records.manage`), heads covering its unit (`orders.sign`), anyone on
  its route, and executors of its instructions. Category `personnel` (not
  a sensitive category; letters with medical content are a later case).

## Model

- **Types** `incoming_letter`, `outgoing_letter` (`priv/document_types/`):
  `"subject": "none"`, `"files": true`; incoming `"instructions": true`,
  route one `sign` step (`records.manage`); outgoing `"reply_by_executor":
  true`, basis `incoming_letter`, route approve (`records.manage`) → sign
  (`orders.sign`), effect `close_instructions`. Template `letter.typ` (the
  shared layout, without the person block).
- **Documents without a person:** `Document.person_id` may be nil only for
  such types (`Validations.Subject`); the field `unit` (`x-entity:
  "organization"`) gives `handling_unit_id`.
- **`App.Documents.Drafts`:** who edits a draft (`editable?/2`: writers of
  the type, or the executor of an open instruction on the basis letter)
  and `registers_directly?/2` ("Register" on the page: submit to oneself
  and sign).
- **Files:** `App.Documents.DocumentFile` (table `document_files`) and
  `App.Documents.Files` (attach, list, remove, link; same type and size
  checks as people's files); `GET /documents/:id/files/:file_id`. Their
  SHA-256 joins the signed content hash only when there are files.
- **Instructions:** `App.Documents.Instruction` (table
  `document_instructions`; actions `give` — `Checks.MayInstruct`,
  `complete` — executor or issuer, internal `close_by_reply`, `remind`) and
  `App.Documents.Instructions`. Notifications `instruction_given`,
  `instruction_done`, `instruction_overdue` (reminded once by
  `App.Documents.Reminders`). Tasks → "Instructions to carry out"; start
  page reason "to carry out"; the sidebar count includes them.
- **Read access added:** authors read what they wrote; executors read
  letters they have an instruction on.
- **Creating letters:** Registers page → "New incoming letter" / "New
  outgoing letter" (records officers); the reply from the letter's page.
- **File plan template:** cases `01-01` (incoming letters) and `01-02`
  (copies of outgoing letters).
- **Demo:** four registered incoming letters to the commander's battalion
  (register `TEST-вх`), instructions to HR (one overdue) and to the
  commander, one answered by a signed reply (`TEST-вих`); purged by their
  test register.

- **Registered, not signed** (2026-10-08): an incoming letter (a document
  about no person whose route is one signature, `Types.registration_only?/1`)
  shows "Registered" on its badge, "Registered by …" on its page and
  "Зареєстровано" on its card.
- **Letterhead** (2026-10-08): outgoing letters print with
  `outgoing_letter.typ` — the sending unit, number and date, the addressee
  on the right, "Щодо: …", the text in paragraphs, the signature, the case.

## Later

- Letters with medical content (a sensitive category, access log).
- Scans for the demo letters.

