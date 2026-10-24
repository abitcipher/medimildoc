# Acknowledging orders (ознайомлення з наказом)

Status: **done** (2026-10-07). On the documents core
(`docs/design/documents-core.md`, personnel orders).

## Decisions (2026-10-07)

- The user agreed: next after the UI work, then the leave calendar.
- Types that need acknowledging declare it (`"acknowledge": true` in
  `priv/document_types/<type>.json`); the five personnel orders do. Other
  types (a medical board conclusion) can be added later by the same flag.
- An order is about one person; that person acknowledges it once.

## How

1. **The person themselves** (an account linked to them): signed orders
   about them that await acknowledgement are at the top of **Tasks**; the
   order's page has "I have read this order" — recorded as acknowledged in
   the app, today.
2. **On their behalf**, when the order was read out at a formation or the
   person signed a paper sheet: HR (the type's write permission) or a
   commander (`orders.sign`) covering the person records it — the date,
   how (in person / on paper) and a note — on the order's page, or **in
   bulk** on the new page **Acknowledgements**: the orders still awaiting
   acknowledgement, filtered by unit (with its sub-units), order type and
   signing date, selected with check boxes, recorded in one step.

An acknowledgement is never changed or deleted (it is a record of fact);
it appears in the order's history, on the person's timeline, and on the
order's page.

## Access

- The person reads their own signed orders of acknowledgeable types (to
  read what they acknowledge) — only those, only once signed.
- Recording for someone else needs the type's write permission or
  `orders.sign`, in scope (the person's unit or the order's handling unit).
- Acknowledgements are read only through the order they belong to.

## Medical board conclusions (2026-10-07)

`medical_board_conclusion` is acknowledged too: the person reads their own
signed conclusion (in the access log, as every read of a medical
document) and confirms it. Recording on their behalf needs the type's
write permission (`medical.write` — a board member); a commander's
`orders.sign` counts only for types they may read, so not for
conclusions. The Acknowledgements page is also in the sidebar for
`medical.write`.

## Notifications

A signed order to acknowledge notifies the person's account (event
"An order awaits your acknowledgement"; type and number only).

## Implementation (2026-10-07)

- `App.Documents.Acknowledgement` (table `document_acknowledgements`, one
  per document): `:acknowledge` (the person, today, `method: :self`) and
  `:record` (on their behalf: `in_person` / `paper`, a date from the
  signing to today, a note); `App.Documents.Changes.Acknowledge` checks the
  order (signed, acknowledgeable) in its hook and writes the history row
  (`Event` action `:acknowledged`). Policies: `Checks.AcknowledgeOwn`,
  `Checks.CanRecordAcknowledgement` (`Access.can_record_acknowledgement?/2`);
  never read directly.
- Types: `"acknowledge": true` (`Types.acknowledge?/1`); the person reads
  their own signed acknowledgeable documents (`ReadableDocuments`).
- `App.Documents.Queries`: `to_acknowledge/1`, `pending_acknowledgements/3`
  (unit with sub-units — `App.Access.Unit.subtree_ids/1` — type, signed
  from; only what the actor may record), `acknowledgements/1`.
- UI: "Orders to acknowledge" first on `/tasks`; the "Acknowledgement"
  section on the order's page; `/acknowledgements` (sidebar for
  `people.write` or `orders.sign` — nav permissions may be a list) with
  filters, check boxes, select all and a record bar that stays at the
  bottom of the screen.
- Timeline: "Acknowledged: <order>" with how. Notification
  `:document_to_acknowledge`.
- Demo data: one signed grade order per demo account with a person and 20
  more (every third already acknowledged), in their own register
  `TEST-n-ос` — no PDF, no effects.
- Tests: `test/app/documents/acknowledgements_test.exs`,
  `test/app_web/live/acknowledgements_ui_test.exs`.
