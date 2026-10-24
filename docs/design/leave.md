# Requests and leave

Status: **done** (2026-09-29). On the documents core
(`docs/design/documents-core.md`) and FSDC (`data-consistency.md`).

## Decisions (user, 2026-09-29)

- A leave request is filed **by the person themselves** (their account
  linked to them, `User.person_id`) **or by HR** on their behalf.
- Approval of the request leads to a **leave order** (personnel orders,
  register `ос`), as for other personnel changes.
- Balance and overlap checks are **FSDC rules**, default "flag +
  incident", so they can be tuned in the rule editor.

## Flow

1. **Request** (`leave_request`, register `рап`, "15-рап"): leave type,
   first and last day, destination, reason. Filed by the person or HR.
2. Route: the **commander** (unit scope: the unit covering the person)
   approves, **HR** signs it as accepted.
3. Signing the request **drafts the leave order** (`personnel_order_leave`,
   basis = the request) for the HR member who signed; HR sends it through
   the usual order route (head of HR, commander signs).
4. Signing the order **records the leave** (person record `leave`: type,
   period, days, order number) — the leave history and the source of the
   balance.

## Leave types and entitlement

`priv/leave_types.json`: id, label, days per year (or none: not counted
against a balance), whether days are calendar days. The numbers shipped
are **placeholders to confirm** (like the STANAG codes): annual 30
calendar days, family circumstances 10, study, sick leave and unpaid with
no yearly limit.

Balance for a year = entitlement − days of recorded leave of that type
starting in the year − days of requests of that type in review. Shown on
the request and on the person's page.

## Self-service

A document type may allow **self-service** (`access.self: true`): the
account linked to the person may create, edit and send their own draft and
read their own documents of that type — without the type's write
permission. Everything else (approval, signing) follows the route.

## FSDC rules

Facts for `document:leave_request` (point `document.submit`): the
requested days, the balance left for the type and year, and the number of
recorded leaves or requests in review that overlap the period.

- `leave_within_balance` — the requested days don't exceed the balance.
- `leave_no_overlap` — the period overlaps no other leave or request.

## Implementation (2026-09-29)

- `App.Leave` — types and entitlement (`priv/leave_types.json`, checked
  against the `leave` record's enum at compile time), `days/2`,
  `periods/2` (recorded leave + requests in review + leave orders not yet
  signed), `balance/3`, `overlaps/3`, `facts/3`.
- Document types `leave_request` (self-service, register `рап`, effect
  `leave_order_draft`) and `personnel_order_leave` (basis: the request,
  effect `leave_record`). A reversed period is refused when sent.
- Self-service: `access.self` in the type; `App.Documents.Access` and the
  read filter open it to the account linked to the person.
- Rules `leave_within_balance`, `leave_no_overlap` (flag), facts under
  `"leave"` for `document:leave_request`.
- UI: "New leave request" and "My requests" on `/tasks` for a linked
  account; "My page" in the account menu; on the request and order the
  days, the balance before it and an overlap warning, live while editing.

Not yet: leave in the synthetic data and the reference dataset (rules at
`document.submit` aren't covered by the sweep), a person-page balance
summary, return from leave / recall orders.
