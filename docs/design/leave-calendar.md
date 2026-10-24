# Leave calendar and staffing conflicts

Status: **done** (2026-10-07). On leave (`docs/design/leave.md`) and sick
leave (`docs/design/referral-discharge.md`: a `leave` record of type
`sick`).

## Decisions (2026-10-07)

- The user agreed the order: acknowledging orders, then this.
- **Absences:** recorded leave of any type, sick leave included, and leave
  on its way (a request in approval, a leave order not signed yet). Both
  count as away — the calendar is for planning; leave on its way is drawn
  dashed.
- **Too many away:** more people away on a day than the limit — a share of
  the unit set in Settings ("Most of a unit away at once", default 30 %),
  but one person may always be away (`max(1, ⌊size × % ⌋)`).
- **Leaders away:** two or more holders of key posts away on the same day.
  A key post is one other posts report to — derived from the staffing
  structure, nothing to mark by hand.
- The unit is the one chosen with all its sub-units; its size is the
  people currently assigned there.

## Where

- **Leave calendar** (`/leave-calendar`, sidebar for `people.write`,
  `orders.sign` or `readiness.read`): a unit and a month (both in the
  URL). Wide screens: people by days, bars coloured by leave type (a fixed
  palette — red and orange mean conflicts), weekends and today marked, a
  coloured mark over each day in conflict, the count away per day, key
  posts starred, a legend. Phones: the conflicts and, per person, their
  absences this month. Read as the viewer — what they may not read is not
  shown.
- **On a leave request or leave order** (while a draft or in approval):
  "In the unit up to N others away then (limit L)", in warning colour when
  this leave would go over — counts only, read as the system, nobody named.
- **Settings:** the limit (1–100 %).

## Model

- `App.Leave.Calendar` — pure: `limit/2`, `days/4` (away, on its way,
  leaders away, flags), `conflicts/1` (runs of days), `load_for/6`.
- `App.Leave.CalendarData` — members of a unit (`leader?` from
  `Position.reports_to`) and their absences; leave records found by their
  plain `effective_on` (start date) and decrypted only then; not a
  sensitive category, so no access-log entries.
- Demo data: about a quarter of people on annual leave and a few on sick
  leave around today (`App.Demo.current_leave/1`).

## Later

- ~~A rule (FSDC) that flags a request over the limit~~ — done 2026-10-07:
  `leave_within_unit_limit` (flag, on sending a leave request; facts
  `leave.unitOver`, `othersAway`, `unitLimit` from
  `App.Leave.CalendarData.unit_load/2`). Not in the reference dataset: it
  checks documents being sent, the reference what is stored.
- Duty rosters, if they come: a day on duty conflicting with leave.
