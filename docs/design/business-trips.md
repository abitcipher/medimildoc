# Business trips (відрядження)

Status: **done** (2026-10-07). The missing personnel order
(`docs/design/documents-core.md` §Personnel orders).

## What

- **Order: business trip** (`personnel_order_business_trip`, register
  `ос`): destination, purpose, first and last day, transport, notes. The
  same route as the other orders (head of HR approves, the commander
  signs); the person acknowledges it (`docs/design/acknowledgements.md`).
  A trip ending before it starts is refused when sent and when signed.
- **Signing records the trip** as a person record `business_trip`
  (personnel category): destination, purpose, period, days, transport, the
  order's number as its basis. On the person's Records tab and timeline.
- **Leave calendar** (`docs/design/leave-calendar.md`): a trip is an
  absence of its own colour — signed ones solid, orders on their way
  dashed — and counts towards the day's conflicts. It is not leave: no
  leave balance is touched.
- **Demo data:** a few people on a trip around today.

## Request from the person (2026-10-07)

**Business trip request** (`business_trip_request`, self-service, register
`рап` like the leave request): the person files it from Tasks → New
request (or HR on their behalf) with the same fields as the order; the
commander approves, HR accepts — accepting drafts the trip order
(`business_trip_order_draft`, basis = the request) for HR's team, to be
sent along the order route. A request in approval already shows dashed on
the leave calendar; once accepted, the draft order takes its place.

## Report and allowances (2026-10-08, user's batch B7)

- **`business_trip_report`** (self-service, basis: the signed trip order;
  register `ав`): the person writes it from their signed order's page
  ("Write the trip report", pre-filled with destination and dates) —
  actual first and last day, within the country or abroad, results,
  travel, accommodation and other costs, the advance received. Route:
  the commander approves, HR signs. Category `personnel_private`.
- **Settlement** frozen at signing (facts kind `trip_settlement`,
  `App.Documents.Certificates.TripSettlement`, pure): days × the per-diem
  rate for the destination (`priv/trip_allowances.json` — **placeholder
  rates**, one currency), plus the costs, less the advance → to pay out or
  to return. Shown on the page before signing (preview) and printed as
  sections, like certificates.
- Not offered in Tasks → "New request" (it starts from the order).

## Later

- A report due reminder after a trip ends; receipts as files on the
  report; per-diem by country and currency; a payment order.
