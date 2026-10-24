# SHEETS-UI — spreadsheet tabs and the sidebar like the app's forms

**Task name: `SHEETS-UI`.** Follow-ups are numbered `SHEETS-UI.n` below.

Status: **pilot done on the Assignments tab** (2026-10-08, user: "Start
SHEETS-UI with the Assignments tab, including the row form").

## Idea

One source for both: a spreadsheet tab is generated from the same JSON
Schema and UI Schema as the app's form, and the sidebar shows the selected
row as that very form. What Sheets can't do (custom widgets in cells,
per-row layouts) is done in the sidebar; the sheet shows the result.

## The laid-out tab (pilot: Assignments)

`priv/sheet_layouts/assignments.json` lists the columns. A column with a
`field` takes its label (UI Schema), format (`format: date`) and help
(`x-help`) from the form schema named in `form` (`assignment` — the form on
the person's page); the others are read-only context; `copyOf` keeps the
exported value in a hidden column. `AppWeb.SheetLayout` turns it into:

| App | Sheet |
|---|---|
| Field label, translated | Row 2 in the user's language; row 1 (hidden) holds the keys `App.People.AssignmentSync` reads, so import works in any language |
| `x-help` (ⓘ) | A note on the label |
| Choice (`options`) | A dropdown from the Positions tab, strict |
| `format: date` | A real date (serial number, `dd.mm.yyyy`), validated, Google's date picker |
| Read-only | Muted text, protected with a warning |
| Theme | Header in the theme's neutral colour, alternating rows, frozen header and first two columns |
| Changed / emptied value | Amber / red cell (conditional formatting against the hidden exported copy) |

Writing the tab again replaces its banding, conditional formats and our
protected ranges (description `SHEETS-UI`) instead of stacking them
(`App.Google.Sheets.sheet_details/2`). A tab written before SHEETS-UI
(one header row) still imports; `App.Google.AssignmentSheets.read/2` drops
the label row (marked `#labels` in its first hidden column) and passes
the first data row to `AssignmentSync.plan/4` (`first_row`), so row
numbers in the preview are the sheet's.

## The row form (sidebar)

`AppWeb.SheetsRowFormComponent` under the Assignments panel: the selected
row of the Assignments tab as the `assignment` form (`JsonSchemaForm`, the
app's own component), with the person's name, PersonID, current post from
the database and a link to the person in the app.

- **Check** plans this one row like an import and, once confirmed,
  carries it out (a draft order or a corrected start date — the same
  `AssignmentSync.apply/2`), then writes the row again from the database.
- **Write to the sheet** puts the form's values into the row's cells (they
  turn amber) for a batch import later.
- Without `people.write` only the person and the current post are shown.

**Selection:** the sidebar can't see the selection itself. The hook
`SheetSelection` asks the Apps Script sidebar every 2 s while the panel is
shown: `REQUEST_SELECTION` → `getSelection()` (new in the shim, no token)
— or, with an older shim that doesn't answer, `REQUEST_CONTEXT` →
`getContext()` every 4 s. Only a changed selection reaches the server,
which reads that row through the Sheets API. **The shim change needs
`cd apps_script && npm run push`** (until then the fallback works).

## Sidebar layout (2026-10-08, user)

Fewer permanent elements in the sidebar (Apps Script gives it ~300 px):

- **Top row**: connection dot · **menu** (☰) · the **tool icons of the
  open tab** (tooltips; Sheet: refresh; People: export, import;
  Assignments: export, check changes) · language · theme · avatar. No
  "HR Admin" title, no e-mail row.
- **Menu**: the account and spreadsheet, "Sheet format" help for People
  and Assignments (opens a closable box above the tabs), "Sidebar layout"
  (for `settings.manage`), "Open the app".
- **Per role**: `AppWeb.SidebarLayout` lists the items (tabs, tool icons,
  sections: the A1 editor, the selected-row form) with the permission each
  needs; the page `/sidebar-layout` (Admin → Sidebar layout,
  `settings.manage`) ticks which items each role sees (`App.Settings`
  `sheets.sidebar_hidden`, saved on change). Shown = permission held, tab
  shown, not hidden for the role. Hiding is presentation only. The first
  visible tab opens; with one tab there is no tab list.

## Next (SHEETS-UI.n)

1. **People tab** (the roster export/import) on the same layout, with the
   `person` form schema.
2. **Personnel record kinds** as tabs — one tab per kind, laid out from
   `priv/person_record_schemas`; enum labels translated in the dropdown,
   `x-enum-badges` colours as conditional formatting.
3. **Record card** — one person as a vertical label | value tab, like the
   app's person page, for printing.
4. **Groups** — UI Schema `Group`/`HorizontalLayout` as coloured bands over
   column groups that fold.
5. **Import checks in the sheet** — errors from the plan and the FSDC rules
   as notes and red cells on the rows concerned.
6. **Dark sidebar** — follow the sidebar's theme; compact density for
   ~300 px.

### Upgrade plan (user, 2026-10-09: "it's nice plan for Google Sheets App upgrade")

Aim: the spreadsheet as a workspace for any of the app's forms — what can
be edited in the app can be edited in bulk in a sheet, and the sidebar is
the app's form for the selected row. Postgres stays the source of truth
Nothing in the sheet changes the database without a check and a
confirmation; no logic moves into Apps Script.

**Stage 1 — simpler flow (Assignments):** 7–11, then 5. **Done
2026-10-09**, except FSDC findings in the sheet (5): plan
errors are in the Status column; rule findings come with the documents.

How it works:

- **Status column** (`status: true` in the layout, after Since):
  `AppWeb.SheetStatus` texts start with a sign the sheet colours — ✓ done,
  → will be done, ! look at it, ↻ changed in the app, ✗ not done. Check
  writes them by sheet row (`AssignmentSheets.write_statuses/5`); Carry
  out writes the tab again from the database with them, keyed by
  PersonID (rows move).
- **Unedited rows** (value = the hidden `Exported*` copy) are never a
  change: `AssignmentSync.plan/4` counts them unchanged, or `stale` when
  the app changed the person after the export — an old sheet can't undo
  newer work. An .xlsx (no copies) works as before.
- **Steps**: `assignments.steps` section (`people.write`); the first step
  is Edit when the spreadsheet already has the tab.
- **Drafts**: `apply/2` returns `outcomes` by row;
  `AssignmentPlan.drafts/2` lists them with links;
  `AssignmentSync.cancel_drafts/2` cancels those still drafts.
- **Row form**: compares the row with the app on selection (post, start
  date, or out of date).

7. **Step guide** — the Assignments panel shows *Export → Edit → Check →
   Carry out* with the current step marked, so a new user knows what's
   next.
8. **Status column** — after Carry out, each row gets its result in the
   sheet: ✓, "draft order …" or "skipped: reason".
9. **Sheet vs app on selection** — the row form compares the row with the
   database as soon as it's selected; Check is needed only to carry out.
10. **Created drafts** — the import report lists the draft orders with
    links into the app and offers "Cancel these drafts".
11. **Changed since export** — the hidden Version column flags rows the
    app changed after the export; overwriting them is logged as a
    conflict .

**Stage 2 — one layout engine for every form:** 1, 2, then 12–16.
**Done 2026-10-09**.

How it works:

- **Datasets**: `assignments` (as before, `AssignmentSync`), `people` and
  `record:<kind>` (`App.People.SheetSync`: export / plan / apply, the
  same unedited/stale rule). A record kind is a sheet when it isn't kept
  inside another record (`x-part-of`) and every required field fits a
  cell (`SheetSync.sheet_kinds/0`); only top-level string, number and
  yes/no fields become columns — the rest of a record's data is kept on
  save. A user sees the datasets they may read; reads go through the
  policies and the access log.
- **Layouts** for people and records are built from the schema
  (`SheetLayout`): context columns, fields, Status, then hidden
  RecordID/Version and the `Exported<key>` copies. Tab titles are English
  and stable (People, the kind's `x-label`); the label row carries
  `#labels <dataset>`, so the tab says what it holds
  (`App.Google.LaidOutTab`).
- **Sheet rules (14)**: enum → dropdown of translated labels (read back
  by `SheetLayout.unlabel/2`), yes/no → checkbox, numbers → range,
  e-mail → e-mail check, date → date; a required field left empty on a
  row with data is red (not on Assignments: an empty post means "no
  post").
- **Sidebar**: two tabs, Sheet and **Data**. Data has the dataset picker
  ("Open a tab", 12), the steps, the preview (`AssignmentPlan` or
  `SheetPlan`) and the report; top-row icons Export, Check, **New** (15).
  Selecting a row on any laid-out tab opens its form
  (`SheetsSelectionComponent` → `SheetsRowFormComponent` for
  assignments, `SheetsRecordRowComponent` otherwise — 13) with who it is
  about (`SheetPerson`: photo, PersonID, post, open documents — 16), and
  the picker follows the tab. The first "People roster" (
  import without a preview) is gone.
- **After Carry out** on people/records only the rows carried out are
  written again from the database (one `values:batchUpdate`); rows that
  failed keep what was typed, with their Status.
- Tests run against `App.FakeSheets` (an in-memory spreadsheet behind
  `Req.Test`).

Items:

12. **"Open a tab"** in the sidebar — pick a dataset (Assignments, People,
    a record kind) and get its laid-out tab; replaces per-tab export
    buttons.
13. **One row form for every tab** — the selected row opens the matching
    app form (person, record kind, assignment) with Check / Write to the
    sheet.
14. **Sheet rules from the schema** — required, ranges, formats, enums as
    data validation; labels and help in the user's language.
15. **New row from the form** — "New" in the sidebar appends a row (or
    saves to the app directly).
16. **Person summary in the row form** — photo, badges, status, open
    documents waiting for the person.

**Stage 3 — deeper:** 3, 4, 17–20, 6. **Done 2026-10-09**:

- **Record card (3)**: the person card's ⧉ button writes the tab "Card"
  (`AppWeb.SheetCard`): name, PersonID, post, then every record the
  viewer may read, by kind, newest first, with the fields of the app's
  record card; no gridlines, headings in the theme's colours; a view,
  never imported. The sidebar then selects it (`selectRange`).
- **Groups (4)**: `Group`/`HorizontalLayout` fields side by side →
  a column group (fold) with tinted labels, the group's name in a note;
  replaced on rewrite (`deleteDimensionGroup`). Only where the form has
  groups (leave, business trip dates); the person form has none.
- **Filtered exports (17)**: Unit in the Data panel (default: the user's
  own unit) — only people posted there and below, and their records;
  kept in the marker (`#labels people unit=<id>`), restored when the tab
  is picked again. Positions stay complete (a transfer may leave the
  unit).
- **Find (18)**: the top row's Find icon → the app's people search →
  the person's row on the open dataset's tab is selected via the shim's
  `selectRange()` (SELECT_RANGE), and opens as the form.
- **Profiles (19)**: `/sidebar-layout` has a column per access profile;
  an item unticked for the role or any of the user's profiles is hidden.
- **Edits (20)**: the shim's onEdit nudge re-reads the selected row when
  the edit touched it.
- **Compact (6)**: smaller fields (`--size-field`) and spacing; the theme
  already follows the system.

**PersonID generator (user, 2026-10-09)**: a new person's PersonID is
generated before saving and can be regenerated (↻) in the sidebar —
the New form, or a new row selected in the People tab (Generate / ↻
writes it into the cell). `Person :create` takes `proposed_person_id`
(`App.People.Changes.ProposedPersonId`: shape checked, not taken — in a
before_action); a new People row without one gets one at the check,
shown in the preview and the Status. A PersonID the app doesn't know is
a new person only on a row never exported (no Version, no copies);
otherwise it is an unknown PersonID.

Items:


17. **Filtered exports** — "my unit" by default, saved views (unit,
    status); smaller tabs, fewer quota problems.
18. **Find a person** — search in the sidebar, jump to the row (one small
    shim call to select a range).
19. **Layout by access profile** — `/sidebar-layout` columns for profiles
    (nurse, commander, …), not only roles.
20. **Faster reaction to edits** — an `onEdit` trigger as a hint to
    re-check the row; never the source of truth (not guaranteed).

And 6 (dark sidebar).

Limits kept: Sheets API quotas (batched writes, filtered tabs), ~300 px
sidebar (one form column, tools as icons), confidential record kinds
exported only to readers with the permission, each export in the access
log.
