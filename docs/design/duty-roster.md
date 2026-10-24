# Duty rosters

Status: **done** (2026-10-07). The user's batch B6 (after A3 parallel
approval and C11 drug interactions). On the leave calendar
(`docs/design/leave-calendar.md`).

## Decisions

- **Duty types** in `priv/duty_types.json`: duty officer, assistant duty
  officer, orderly (two a day), medic on duty, driver on duty — with how
  many people each needs a day and the rest between two duties of one
  person (one day). A placeholder set for a battalion; adjust to the
  unit's orders.
- **A shift** (`App.Duty.Shift`): one person, one duty, one day, in a
  unit's roster; at most one duty a person a day.
- **Who:** commanders plan their unit (`orders.sign`, covering the
  person), HR anywhere (`people.write`); those who see readiness in scope
  read; a person reads their own duties.
- **Roster page** `/duty-roster?unit=&month=` (like the leave calendar):
  people by days; a cell shows the duty's initials (from its translated
  name). Problems: red — on duty on a day of leave, sick leave or a trip
  (recorded or on its way); amber — two duties without the rest; a mark
  above a day — a duty type short of people (hover for which). A summary
  counts them. Commanders and HR assign or remove a duty by clicking a
  cell.
- **Leave requests** (and leave orders) show how many duties are planned
  in the requested days.

## Model

- Domain `App.Duty`: `Shift` (table `duty_shifts`), `Types`,
  `Checks.MayPlan`, `Roster` (pure: `problems/3`, `gaps/3`), `RosterData`
  (members and absences from `App.Leave.CalendarData`, shifts as the
  viewer; `count/3` for the leave request).
- Month-grid helpers shared with the leave calendar: `AppWeb.CalendarUI`.
- Demo: this month for the commander's battalion, every type covered each
  day by members in turn (`App.Demo.Duty`, no random calls); some fall on
  days of leave.

## Later

- Duty swaps and a duty order (наказ про наряд) as a document.
- Hours and night duties; rest by hours rather than days.
- A rule (FSDC) for a duty on a day away.
