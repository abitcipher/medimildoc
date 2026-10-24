# Registers and the file plan

Status: **done**. From `docs/design/product-direction.md`
Registration and exporting a register; numbering itself is
in `docs/design/documents-core.md` §Registers and identifiers.

## Decisions (2026-10-07, user)

- First slice: **registers + file plan**; incoming and outgoing
  correspondence is the next step, on its own.
- The file plan (номенклатура справ) is kept **in the app by a records
  officer** (new permission `records.manage`, profile `records_officer`,
  also in the `admin` role); each year's plan can be copied from the
  previous year's or started from a template.
- Retention periods and article references in the template are
  **placeholders** to verify against the list of standard documents in
  force for the organisation (`priv/records/file_plan_template.json`) —
  not an authoritative list, like the STANAG codes.

## Registers (`/registers`)

- A register (`ос`, `рап`, `дов`, `влк`, …, plus any register documents
  were actually numbered in, such as the demo `TEST-ос`) and a year, or
  one case (`?case=`): signed documents in number order — number,
  registration date, type, person, signed by, case ("not filed" when
  none). Optional filter by type. 100 per page; everything in the URL.
- **Who sees what:** records officers and HR (`records.manage` or
  `people.write`) open the page. Numbers, dates, types, signatories and
  cases are shown to them for every document; **the person** only where
  the viewer may read the document itself — a medical register doesn't
  reveal whose discharge summary it is. Nothing encrypted is read, so
  nothing goes to the access log (`App.Records.Registers`).
- **Export** to .xlsx (`/exports/register.xlsx?code=&year=[&type=]` or
  `?case=`): the same rows, all pages (`App.Xlsx.table_workbook/3`).

## File plan (`/file-plan`)

- `App.Records.Case` (table `file_plan_cases`): year, index (unique per
  year), title, retention, article, the unit that keeps it, note, and the
  **document types** filed into it — a type goes into at most one case a
  year.
- **Filing:** a document is filed when signed into the case of its type
  and year (`Document.case_id`, set in `App.Documents.Changes.Sign` via
  `App.Records.CaseLookup`). Documents signed before their case existed
  are filed when the case is created or its types change
  (`App.Records.FilePlan.file_backlog/1`; internal action `:file`).
- A case with documents can't be removed (checked by `FilePlan.delete/2`,
  guaranteed by the foreign key, on delete restrict).
- "Copy cases from <last year>" and, for an empty year, "Start from the
  template". The count of documents links to the case's contents on the
  Registers page. A signed document's page names its case.
- Forms from `priv/form_schemas/file_plan_case.*.json` (the document type
  choices are filled in from the type definitions at runtime).
- Demo: this year's plan from the template when seeding; the demo's
  signed orders are filed into `03-01`. Purging the demo keeps the plan
  (configuration, not demo data).

## Closing, inventory, disposal (2026-10-07, user's step 2)

- A case keeps its retention for these: **permanent** (handed to the
  state archive) or **years kept** (`retention_years`, counted from the
  1st of January after its year); the written `retention` text stays as
  the file plan shows it. Existing cases got their years from that text.
- **Closing:** the records officer closes a case (`:close`, with date and
  who) or all of a year at once ("Close the cases of <year>",
  `FilePlan.close_year/2`), and may reopen one. Nothing more is filed into
  a closed case (`CaseLookup` skips it): later documents of its types stay
  "not filed" until a case takes them.
- **Inventory (опис справ):** a year's closed cases of one retention class
  — permanent, long-term (over 10 years; personnel cases, 75 years),
  temporary (up to 10), or no period given — with the dates of the first
  and last document and how many documents each holds; PDF
  (`priv/document_templates/case_inventory.typ`, A4 landscape, in
  Ukrainian) and .xlsx (`/exports/case-inventory.pdf|.xlsx?year=&kind=`,
  `App.Records.Inventory`). Documents are counted, not sheets.
- The page shows the year's summary (cases, closed, by class).
- **Due for disposal:** closed, non-permanent cases whose period has ended
  — listed on the File plan page (all years). The disposal act itself is
  later.
- **"До справи №":** a signed document's print names its case (Print
  payload `case`, shared layout).

- **Disposal act** (2026-10-08): "Disposal act (PDF)" on the File plan
  page (records officers) prints the cases due for disposal
  (`App.Records.DisposalAct`, `disposal_act.typ`) for signing on paper by
  the records officer and the expert commission; the app destroys nothing.

## Later

- Transfer to the archive; sheets counted in cases; marking cases as
  destroyed once the act is approved.
