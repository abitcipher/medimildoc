# Inbox first

Status: **done**. From `docs/design/product-direction.md` 
("each user starts from their tasks and deadlines"); builds on the inbox
of `docs/design/documents-core.md`.

## Decisions (2026-10-07)

- The start page (`/`) opens with **Waiting for you**: one list of what
  waits for the user, most urgent first — steps to approve or sign, orders
  to acknowledge, drafts returned to them, drafts the system opened for
  their team. Up to eight items, the count, how many are overdue and a
  link to all tasks. The deadline widgets (clearances, documents
  expiring, readiness …) and the section cards stay below it.
- **Deadlines:** a step to approve or sign is due a number of days after
  it became the assignee's — Settings → "Days to approve or sign"
  (`documents.step_days`, default 3, 1–60, calendar days). A document's
  own due date (scheduled drafts) counts if earlier. Orders to
  acknowledge have no deadline.
- **Marks:** overdue in error colour with an "overdue" badge; due today or
  within three days in warning colour. The same marks on the Tasks page
  and wherever a document row is shown (only while a draft or in
  approval).
- **Order:** overdue, due today, soon, later, then undated; older first
  within each.
- Phones: the reason and due date sit above the title instead of badges.

## Model

- `App.Documents.Inbox` — pure: `urgency/2`, `step_due/2`, `items/3`,
  `overdue/1`.
- `Queries.inbox/1` adds `due` and `step_action` to documents waiting for
  the actor's decision (the step's `updated_at` is when it became
  pending).
- `AppWeb.StartPage.inbox/1` → `PageHTML.inbox/1`; rows are
  `DocumentUI.row` with a `tag` (the reason) in place of the state badge.
- Demo data: four grade orders in approval in the commander's unit — two
  waiting for HR to approve, two for the commander to sign; one of each
  overdue.

## Reminders, count, stand-ins (2026-10-07, user: "steps 1–3 as one batch")

- **Reminders:** when a step becomes overdue, its assignee and their
  active deputies get `:document_overdue` ("A document waiting for your
  decision is overdue"), once per step (`Step.reminded_at`). A step's
  deadline counts from `Step.pending_since` (set when it becomes pending;
  existing pending steps were backfilled from `updated_at`), so marking or
  deciding never moves it. `App.Documents.Reminders.run/1`, hourly from
  `App.Documents.Reminders.Ticker` on the server (off in tests and
  release tasks). Like every event, users subscribe to it per channel on
  the Notifications page.
- **Count next to "Tasks"** in the sidebar (also on the collapsed icon
  rail): documents waiting for the user's decision — their own steps and
  those of users they stand in for — plus orders to acknowledge; red when
  any step is overdue (`Queries.waiting_count/1`).
- **Stand-ins** (Tasks → "My deputies"): a user names a deputy for dates,
  or without dates — then the deputy acts whenever the user is away on
  recorded leave or a business trip (`App.Leave.CalendarData.away_on/2`).
  Only someone who holds at least one of the user's route permissions may
  be named. While active, the deputy sees the user's waiting steps in
  their tasks ("to sign for N"), may read those documents and decide them —
  only where they hold the step's permission for that document themselves
  (unit scope included). The step keeps its assignee and records
  `decided_by`; the route shows "decided by deputy …". Notifications that
  a document waits, and overdue reminders, go to active deputies too. An
  administrator (`users.manage`) may set deputies for anyone through the
  same resource (no screen yet).
- `App.Documents.Deputy` (table `document_deputies`), `App.Documents.Deputies`
  (`active?/3` pure; `principals/2`, `of/2`, `may_act?/3`,
  `holds_step?/3`, `overview/1`); who may be named — `App.Documents.DeputyCandidates.for_user/1`.

- **Administrators** (Users page → Deputies, `AppWeb.DeputiesAdminComponent`,
  2026-10-07): every deputy, active today or not; add one for any user
  (same rules — the deputy must share a route permission), remove any.

## Later

- Deputies proposed from the chain of command (the post one reports to).
