# FSDC — Flexible System of Data Consistency

Status: **in progress** (2026-09-29). Decided: GoRules ZEN + JDM Editor;
the engine in-process as a Rustler NIF; default severity "flag +
incident". Core done (engine, settings, rule sets, incidents, check
points, sweep, screens), the JDM Editor page, the reference dataset and
the shipped rules, including (2026-10-07) "fitness only from a signed
conclusion" (`fitness_from_signed_conclusion`: a downgraded or
non-effective status names a signed board conclusion of the person in
`basis`; fit for duty may be recorded directly; the demo data backs such
statuses with signed conclusions in register `TEST-влк`, a planted few
without) and "leave within the unit limit" (on sending a leave request).

## What the user asked for

- Declarative **rules for data consistency and quality**, switched on or
  off in the system settings.
  Example: an identity document of an employee or patient must be entered
  **before** any medical examination of that person ("identity is
  verified before data is processed").
- A **validation pipeline** and its **processing workflow** defined in
  JSON, with a **visual editor** to create and view them.
- **Off-the-shelf** tools integrated into our workflow, not a system built
  from scratch (n8n or a similar alternative).
- Every violation (data in an invalid state) is **logged and treated as a
  potential security incident**, whether it is an error or forgery.
- When enabled: **synthetic test data with 1–3 % invalid records**, kept
  as a **reference dataset** to verify the system after each deployment.

## Options checked (2026-09-29)

| Tool | Licence | Role | Fit |
|---|---|---|---|
| **GoRules ZEN** engine | MIT, Rust core (`zen-engine` 2.0), bindings for many languages | evaluates rules in JSON Decision Model (JDM): decision tables, expressions, switches, functions | **rules** — deterministic, fast, in the data path; Rust fits our IHDS service |
| **GoRules JDM Editor** | MIT, React component | visual editor for JDM graphs and decision tables | **visual editor** for the rules |
| n8n | Sustainable Use License (fair-code; internal business use allowed) | visual workflow automation, integrations | **processing workflow** around incidents (notify, open a ticket, escalate); heavy extra service; not meant for rule evaluation in the data path |
| Node-RED | Apache-2.0 | visual event flows | same role as n8n, fully open |
| JSON Logic | MIT | rule format, small libraries | no mature visual editor, no decision tables |
| Open Policy Agent | Apache-2.0 | policy engine (Rego) | good engine, no visual editor, rules as code |
| Camunda (DMN/BPMN) | proprietary for production use (8.x) | decision tables and processes | heavy (JVM), licence |

## Recommendation

- **Rules: GoRules ZEN + JDM Editor.** Rules are JSON files (versioned
  in the repository and editable in the app), evaluated by the Rust
  engine inside our IHDS service (or a small sibling service), called by
  Phoenix at defined points of the pipeline. The editor is embedded in an
  admin page (a LiveView hook mounting the React component) for viewing
  and editing rule graphs.
- **Workflow around incidents: in the app first** (incident record,
  access-log style, notification in Tasks); **n8n or Node-RED later** if
  integrations (e-mail, messengers, ticketing, SIEM) are needed, fed by a
  webhook for each incident.

## Design sketch

- **Settings**: `fsdc.enabled` and per-rule-set switches (system settings
  page; admin only). Off = rules not evaluated, nothing logged.
- **Check points** in the pipeline: before saving a record or document,
  before signing, and a periodic sweep over existing data (a rule
  switched on later finds old violations).
- **Rule sets** (JDM files) with a severity: `block` (the action is
  refused), `flag` (saved, marked, incident), `observe` (incident only).
- **Incident**: a new audit resource — rule, data involved (references,
  not copies of sensitive values), actor, time, severity, status (open /
  explained / confirmed). Visible to the CISO profile, in the access-log
  style; never deletable.
- **First rules**: identity document before medical examination; signed
  document dates not before their basis; assignment periods of a person
  not overlapping; fitness status only from a signed conclusion (after
  the medical board process); no diagnosis text in fitness restrictions.
- **Reference dataset**: a deterministic synthetic set (fixed seed) with
  1–3 % deliberately invalid records, each labelled with the rule it
  breaks, stored in the repository with the expected incidents; a test
  and a post-deployment check compare what the system reports with the
  expected list.

## Open decisions

- Confirm the tools (ZEN + JDM Editor; n8n or Node-RED for the incident
  workflow, or none at first).
- Which check points and severities to start with.

## Implementation (2026-09-29)

- **Engine** — `native/rules` (Rust, `zen-engine` 2.0.1, `rustler` 0.36)
  as `App.Rules.Engine`: `evaluate(graph, context, trace:)`,
  `validate(graph)`; dirty CPU scheduler. Dev/test: Rustler builds it; the
  image builds it in its own Dockerfile stage (cached until the crate
  changes) and loads it (`RULES_NIF_PREBUILT=1`).
- **Settings** — `App.Settings` (`fsdc.enabled`, off by default), page
  `/settings` (`settings.manage`, admin).
- **Rule sets** — `App.Rules.RuleSet` (key, label, severity, points,
  subjects, enabled, JDM graph, version) seeded from `priv/rules/*.json`
  after migrations; a new graph is validated by the engine and the old
  one kept (`RuleSetVersion`). Page `/rules` (`rules.manage`: admin, CISO):
  severity, on/off, "check existing data".
- **Check points** — `App.Rules.Changes.Check` on person records
  (`record.save`) and documents (`document.submit`, `document.sign`). A
  rule returns `valid`, `code`, `message`; a rule that fails to evaluate
  counts as a violation (`rule_error`). `block` refuses the action.
- **Incidents** — `App.Audit.Incident`, written after the transaction (a
  refused attempt is kept), with the rule version, point, subject, actor
  and **facts only** (dates, ids — no record content). Page `/incidents`
  (`audit.read`): review as explained or confirmed. A flagged document
  shows the rule's message to its readers.
- **Sweep** — `App.Rules.Sweep`: existing records and signed documents,
  no duplicate of an open incident.
- **First rule** — `identity_before_examination` (flag): the first identity
  document or national ID must be entered no later than the examination
  (encounter, vital signs, condition, board conclusion).

- **Visual editor** — page `/rules/:key` (`rules.manage`): the GoRules
  JDM Editor (React, MIT) mounted by the `RulesEditor` hook; saving checks
  the graph with the engine and keeps the previous version (list of
  earlier versions on the page). "Run" evaluates the edited graph with a
  sample context (`App.Rules.Engine.simulate/2`, with the trace) without
  saving. The editor is built by Vite (`assets/rules_editor`, Monaco bundled
  locally — no CDN) into `priv/static/assets/rules_editor`; the image does
  this in its own Dockerfile stage.
- **Shipped rule upgrades** — `App.Rules.Library.sync/0` also upgrades a
  shipped rule to a newer file version while nobody has edited it in the
  app (`updated_by_email` empty); an edited rule is kept.
- **Reference dataset** — `App.Demo.seed/1` enters identity (its
  `inserted_at`) before anything recorded about a person, except for a
  planted share of people with examinations (chosen by seed and position,
  not `:rand`): their identity is entered only now, after the
  examinations, or not at all. Each planted violation is returned with its
  rule and code; with the default seed and size that is 2.2 % of records.
  The labels live in `priv/reference/rules.json` (`mix
  app.rules.reference` reseeds and rewrites it; commit the file).
  `App.Rules.Reference.verify/0` runs every rule set, whatever the
  switches, over the synthetic people and compares with the labels —
  read-only, no incidents. Where: the test suite (`ReferenceTest`, on
  every CI run), `bin/app eval "App.Release.verify_rules()"` and the
  "Reference check" button on `/rules` after a deployment. It needs the
  synthetic data seeded with the reference's seed and size. The VPS is the
  staging environment (user, 2026-09-29): the reference set stays there
  and is checked after each deployment; a production instance would purge
  it, and there the check runs in CI. A seeded set can be written to JSON
  files (`App.Demo.Export`, `mix app.demo.export DIR`,
  `App.Release.export_demo/1`); the staging copy of 2026-09-29 is on the
  VPS in `~/hrda-reference/demo-seed1-2026-09-29/`.
- **More rules (2026-09-29)** — `no_diagnosis_in_restrictions` (fitness
  restrictions with an ICD-10-like code: a letter and two digits; ZEN
  regular expressions without backslashes, `\b` does not work there),
  `signed_after_basis` (facts `basis.signedAt`), `assignments_no_overlap`
  (new check point `assignment.save` on every assignment action, facts
  `assignment.overlaps`), and the leave rules also on recorded leave
  (`record:leave`). Facts get the subject's own id and basis
  (`Facts.context/6`), so a record isn't compared with itself.
- The synthetic data plants violations of every rule except
  `signed_after_basis` (it has no documents): identity, leave history of
  last year (overlap, over the balance), a restriction with a code, a
  duplicated assignment — 26 of 1,839 records and assignments (1.4 %).
  Seeding runs with FSDC off for its process (`App.Settings.without_fsdc/1`),
  so planting raises no incidents.
