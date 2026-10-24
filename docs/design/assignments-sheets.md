# Assignments through Google Sheets and offline .xlsx

Status: **done** (2026-09-28). Roadmap item 2.

## Decisions (user, 2026-09-28)

- **Current assignments only** are editable: one row per person. Changing
  the position ends the current assignment the day before "Since" and
  starts a new one; clearing it ends the current one. Past assignments are
  exported on a read-only History sheet. History is never rewritten.
- **Positions from a dropdown of short labels** (`App.People.PositionLabel`,
  "Rifleman A.Co¦1Bn¦OR-3"), listed on a Positions sheet; the import maps
  the label to the post (labels made unique if two posts would share one).
- **Preview, then confirm:** an import first lists every change and every
  error; nothing is written until confirmed; rows with errors are skipped.

## Channels

Both use one core (`App.People.AssignmentSync`: export rows, plan an
import, apply a plan):

- **Google Sheets** — the sidebar's Assignments tab writes the three
  sheets through the Sheets API (dropdown as data validation, version
  column hidden) and imports from them.
- **Offline .xlsx** — an Import / export page (HR, admin) downloads the
  workbook and uploads an edited one, via UmyaSpreadsheet 0.7 (MIT, Rust
  NIF, precompiled; checked to load on OTP 29 with its NIF 2.16 build).

## Workbook

- **Assignments:** PersonID · Name · Unit · Position (dropdown) · Since
  (dd.mm.yyyy) · Version (hidden). Unit and Name are informational.
- **Positions:** Position (label) · Unit · Title · Grade · Holders
  ("held/strength").
- **History:** PersonID · Name · Position · Unit · Started · Ended.

Every cell is written as a string (no formulas), so a value such as
`=HYPERLINK(…)` stays text in Excel and Sheets: Sheets writes use
`valueInputOption=RAW`, and UmyaSpreadsheet stores `=…` as a string.

In Google Sheets the tabs are created when missing and cleared before
writing; the dropdown is `ONE_OF_RANGE` on `=Positions!$A$2:$A$n`
(strict), Version is hidden, the header rows are frozen. Since
2026-10-08 the Assignments tab in Google Sheets is laid out like the
app's form (SHEETS-UI, `docs/design/sheets-ui.md`): a hidden key row, a
translated label row, real dates (written as serial numbers — numbers
are still RAW), hidden exported copies for change highlighting, and the
selected row as a form in the sidebar. The `.xlsx` keeps the one-header
format above. In the `.xlsx`
the dropdown and the hidden column are patched into the XML after
UmyaSpreadsheet writes it (it only writes inline lists, capped by Excel at
255 characters, and has no hidden-column call); there is no frozen header
(UmyaSpreadsheet 0.7 writes an invalid pane).

## Import rules

- Required columns: PersonID, Position, Since (found by header name).
- Same position, other Since → the start date is corrected. New position
  → move: the current assignment ends the day before Since; if Since was
  left at the old start date, the move starts today. Empty Position → the
  current assignment ends today. No current assignment → a new one.
- Dates: `dd.mm.yyyy`, ISO, or a spreadsheet serial number.
- Errors skip the row (unknown PersonID or label, duplicate person, bad
  date, Since not after the current start, a current assignment starting
  in the future); a post over strength is only a note.
- Each row is carried out on its own.

## Draft orders (2026-10-07)

Posts change only through signed personnel orders
(`docs/design/documents-core.md` §Personnel orders), so an import no
longer writes assignments:

- a new post → a draft **appointment** order, another post → a draft
  **transfer** order, a cleared post → a draft **release** order (its
  reason left for HR) — the post and date filled in, the importing user
  its author, in their Tasks → My drafts, to be completed and sent along
  the order route;
- a person with a personnel order already open (a draft or in approval)
  is skipped — importing the same sheet twice drafts nothing twice;
- a corrected start date is still applied directly: it fixes the record,
  it is not a personnel event (audited like any direct change).

After the import, the Google sheet is refreshed from the database and so
shows the current posts until the orders are signed.

## Conflicts 

The Version column carries the current assignment's `updated_at` at export
time. If the assignment changed since, the preview marks the row; a
corrected start date still overwrites it (last write wins) and records a
`ChangeConflict`; a drafted order overwrites nothing — whoever completes
it sees the current state.

## Access

Export: `people.read`. Import: drafts go through the Document policies
(the order types' write permission, `people.write`), corrections through
the Assignment policies.
