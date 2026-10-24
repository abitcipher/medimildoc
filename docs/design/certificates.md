# Certificates on request (довідки)

Status: **done** (2026-10-06). On the documents core
(`docs/design/documents-core.md`) and the self-service of requests
(`docs/design/leave.md` §Self-service).

## Decisions (user, 2026-10-06)

- Certificates come next among the product-direction items.
- First four types: **service** (з місця служби), **pay** (про грошове
  забезпечення), **family composition** (про склад сім'ї), **leave**
  (про використання відпусток).

## Flow

1. The person (self-service, an account linked to them) or HR opens a
   certificate request: where it will be presented, and per type a period
   (pay) or a year (leave).
2. One route step: **HR signs** it (service and leave: `people.write`; pay
   and family: `people.hr_private.write`).
3. **Signing freezes the facts**: the system reads what the database holds
   on the signing date (as the system, no access-log entry for its own
   read) and stores them in the document's encrypted fields under
   `facts`. The content hash covers them, and the PDF prints them. A
   certificate never changes afterwards, even when the records do.
4. Until it is signed, the document page shows a **preview** of what the
   certificate would state today, so HR can check the records first.

All four types share one register: code `дов`, numbers `15-дов`.

## What each certificate states

| Type | Facts (as of the signing date) |
|---|---|
| Service | Current posts (title, unit with its parent units, grade, since), service start (the earliest assignment), current rank (latest `rank_history`). |
| Pay | Pay for each month of the period: the rate in force (`compensation` records of base pay, promotion, COLA adjustment), prorated by days when it changes mid-month, plus one-off payments (bonus, allowance) dated in that month; totals per currency. At most 24 months. |
| Family | Marital status and spouse (latest `family_status`), dependants (`dependent`: name, relationship, date of birth). |
| Leave | For the year: per leave type with a yearly entitlement, the days entitled, used and left; every recorded leave starting that year (type, first and last day, days, order number). Only recorded (signed) leave, not requests on their way. |

The pay figures are **computed from the pay records**, not taken from a
payroll system: the certificate says "according to the records". The rate
model is monthly; a change on the 20th counts the old rate for 19 days of
the month and the new one for the rest.

## Model

- Type JSON key `facts` (optional): `service`, `pay`, `family`,
  `leave_balance` — checked at compile time like effects.
- `App.Documents.Certificates`: facts for a person and date, the check
  before sending and signing (a valid period or year), and the print
  sections. `App.Documents.Certificates.Pay`: the monthly proration (pure).
- Signing (`App.Documents.Changes.Sign`): facts computed before the hash,
  stored after the write through the internal action `:attach_facts`.
- Print: `sections` in the payload (title, optional header, rows); the
  shared layout prints them after the fields. One template,
  `certificate.typ`.

## Access

- Read: `people.hr_private.read`, and the person themselves
  (`access.self`).
- Category: service and leave `personnel`; pay and family
  `personnel_private` (reads in the access log).

## Implementation (2026-10-06)

- Types `certificate_service`, `certificate_pay`, `certificate_family`,
  `certificate_leave` (self-service, register `дов`, one HR sign step,
  template `certificate.typ`; the shared layout prints `sections`).
- `App.Documents.Certificates` (facts, `check/2` — wired into
  `App.Documents.Effects.check/1`, so sending and signing both check —
  and `sections/4`), `App.Documents.Certificates.Pay` (pure, `Decimal`).
- `App.Documents.Changes.Sign`: facts computed before the hash, stored by
  `Document` action `:attach_facts` (forbidden to any actor, like
  `:attach_pdf`).
- UI: "New request" menu on `/tasks` with every self-service type
  (replaces "New leave request"); on the document page "The certificate
  would state today" (draft, in review; live while editing) and "The
  certificate states" once signed. HR opens one from the person's
  Documents tab like any type.
- The preview is computed as the system; what the viewer sees is covered
  by the access-log entry for reading the certificate itself (pay and
  family certificates are `personnel_private`).
- Tests: `test/app/documents/certificates_test.exs` (proration, the four
  types signed end to end, hash over the facts, frozen after later
  records), `test/app_web/live/certificates_ui_test.exs`.

## Later

- Certificates in other languages (print language is Ukrainian now).
- A payroll source for pay figures; income tax and deductions.
- FHIR: the facts in the Composition (the PDF is already served).
