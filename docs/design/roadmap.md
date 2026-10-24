# Roadmap

Ordered work queue. The top item is in progress; the rest wait for it.

## Now

**Small UI task — done.** position badges; on `/people/<id>` →
Assignments: fix duplicate options in "Assign to a position → Position";
"Direct reports" and the start page "Readiness" list become scrollable,
loaded in pages, with quick search and sorting by full name and position;
rows show an avatar (photo preferred), full name, position badge, and on
Readiness a coloured status badge (+ fit, – non-effective, ~ downgraded);
badges show short details on hover, respecting access.

**Then — reference data, files and input formats** —
`docs/design/reference-data-and-files.md`. Steps 1–3 done (dates, IHDS with
countries/languages/currencies/places, suggestions,tags;).
Step 4 done (RustFS, attachments, portrait photos;). Step 5
(RabbitMQ + outbox) only when asynchronous processing is needed.

## Right after step 4 (saved 2026-09-27) — done. 

1. **Short position labels where duplicates are likely** (lists, selects):
   title plus abbreviated unit and grade, joined by a delimiter held in one
   constant (`¦` if safe everywhere, otherwise `|`), e.g.
   "Rifleman A.Co¦1Bn¦OR-3", "Physician R.3¦F.H.¦OF-3".
2. **Badge tooltips clipped by scrollable lists** (start page Readiness):
   fix so tooltips render above the scroll area's bounds.
3. **Remove full duplicates in Positions at the source** — decided
   (user): merge posts identical in title, unit, grade and reporting line
   into one post with an authorised strength (e.g. Rifleman ×10); move
   assignments to it, delete the empty copies (migration), demo generator
   creates merged posts, a uniqueness rule prevents new duplicates, lists
   show holders/strength.

## Next, after that (saved 2026-09-27)

1. **First clinical module** — done, `docs/design/clinical-module.md`:
   encounters and vital signs (FHIR Encounter / Observation), with nurse
   and combat medic access profiles.
2. **Assignments through Google Sheets**, and offline `.xlsx` import/export
   with UmyaSpreadsheet (work without Google) — done,
   `docs/design/assignments-sheets.md`.
3. **Go-live chores** — the checklist in `infra/README.md`. Done
   2026-09-28: plaintext columns dropped (`DropPlaintextColumns`), RustFS
   keys rotated, `CLOAK_KEY` backed up by the user. The rest is below.

## Maybe before PROD MODE (user, 2026-09-28)

The user says when the service goes to production mode; until then these
wait.

- **At the production launch, remind the user:** put the Docker volumes
  (`db_data`, `rustfs_data`) on an encrypted disk (go-live checklist 7).
- Review users on `/users`: roles and profiles, link every account to its
  person, a second admin, then `REQUIRE_SECOND_APPROVAL=true`, a CISO
  profile holder checks `/access-log` (checklist 5–6).
- Switch to real data: `purge_demo`, `ADMIN_FULL_DATA_ACCESS=false`
  (checklist 1, 3).
- **Mail deliverability** (postponed by the user, 2026-10-06): add the DKIM
  TXT record `v1-rsa-20261006._domainkey` (value in `~/hrda-mail/dns-zone.txt`
  on the VPS; optional `v1-ed25519-20261006._domainkey`) and DMARC `_dmarc`
  = `v=DMARC1; p=none; rua=mailto:postmaster@artcomplect.com` at the
  registrar, then send a test to adaptunit@gmail.com and check SPF / DKIM /
  DMARC in Gmail's "Show original". Done so far: Stalwart running, reverse
  DNS `mail.artcomplect.com`, a first test accepted by Gmail (2026-10-06,
  inbox/spam result not yet reported).
- **Automated backups** (moved here 2026-09-29): nightly `pg_dump` plus the
  RustFS volume, encrypted, sent off the server, with a tested restore
  (`infra/README.md` → Backups). Destination still to be decided.

## After go-live (development continues now)

Done: medications given and procedures (`docs/design/clinical-medications.md`,
2026-09-28); long-term medication list (2026-09-29). **Direction:**
`docs/design/product-direction.md`. Done: documents core and the medical
board process (`docs/design/documents-core.md`, 2026-09-29). **Next:**
~~personnel orders on the same core~~ — done 2026-09-29
(`docs/design/documents-core.md` §Personnel orders); ~~requests and
leave~~ — done 2026-09-29 (`docs/design/leave.md`: self-service request,
commander → HR, leave order, balances, two FSDC rules). ~~Referral → discharge summary, sick leave~~ — done 2026-09-29
(`docs/design/referral-discharge.md`: register of care providers with
priority units, referral, discharge summary signed by the treating
clinician and head of department, sick leave recorded as an absence).
~~Global search, person timeline, notifications~~ — done 2026-09-30
(`docs/design/search-timeline-notifications.md`: search incl. exact
national-ID match through keyed hashes, timeline tab, subscriptions with
an outbox → RabbitMQ → Apprise API; channels e-mail, Telegram, Signal,
Matrix wait for their sender credentials). FHIR read API — done 2026-09-30 (`docs/design/fhir-api.md`: service
accounts, personal tokens, and external medical systems through SMART on
FHIR backend services, limited to patients referred to their provider).
~~Certificates on request~~ — done 2026-10-06
(`docs/design/certificates.md`: service, pay, family composition, leave;
facts frozen at signing). ~~Usability recommendations (user)~~ — done
2026-10-06 (`docs/design/ui-preferences.md`: SVG/EPS files, page navigation
above tables, interface settings for edit and "New" forms on narrow and
wide screens). ~~Acknowledging orders~~ — done 2026-10-07
(`docs/design/acknowledgements.md`: by the person in the app or recorded
for them, in bulk). ~~Leave calendar and staffing conflicts~~ — done
2026-10-07 (`docs/design/leave-calendar.md`). ~~Business trip order~~ —
done 2026-10-07 (`docs/design/business-trips.md`). ~~Sheets/.xlsx imports
as draft orders~~ — done 2026-10-07 (`docs/design/assignments-sheets.md`
§Draft orders). ~~Business trip requests; acknowledging medical board
conclusions~~ — done 2026-10-07 (`docs/design/business-trips.md`,
`docs/design/acknowledgements.md`). ~~Inbox first~~ — done 2026-10-07
(`docs/design/inbox-first.md`: the start page opens with what waits for
the user, overdue steps marked); ~~overdue reminders, task count,
stand-ins~~ — done 2026-10-07 (same note). ~~Registers and file
plan~~ — done 2026-10-07 (`docs/design/registers-file-plan.md`). ~~Incoming and outgoing correspondence~~ — done 2026-10-07
(`docs/design/correspondence.md`). ~~Closing cases, the inventory of cases,
the case index on printed documents~~ — done 2026-10-07
(`docs/design/registers-file-plan.md` §Closing). ~~The deputies screen for
administrators, the leave-limit rule, the "fitness only from a signed
conclusion" rule~~ — done 2026-10-07. ~~Parallel approval, drug
interaction warnings, duty rosters~~ — done 2026-10-07
(`docs/design/parallel-approval.md`, `clinical-medications.md`
§Interactions, `duty-roster.md`). ~~Lab results, business-trip report
and allowances, registered wording / letterhead / disposal act~~ — done
2026-10-08. **Postponed (user, 2026-10-08):** FHIR additions (consent,
SMART app launch, certificate facts); Telegram / Signal / Matrix channels
(need sender credentials); certificates from a payroll source and in other
languages; qualified signatures (КЕП); co-approvers for personnel orders;
real allowance rates and verified lab reference ranges; backups (before
the release). Now: interface improvements (user) — rows loaded on
scroll in the leave calendar and duty roster (done); **ORG-GRAPH**, the
organisation as an interactive Cytoscape.js graph (`org-graph.md`, v1
done 2026-10-08; follow-ups ORG-GRAPH.1–8 done 2026-10-09, .9 — a
compact sidebar mode — open); **SHEETS-UI**,
spreadsheet tabs and the sidebar like the app's forms (`sheets-ui.md`,
pilot on the Assignments tab with the row form, 2026-10-08; follow-ups
SHEETS-UI.1–6); **SHEETS-UI upgrade plan** (user, 2026-10-09) —
SHEETS-UI.7–20 in three stages, `sheets-ui.md` §Upgrade plan; Stages 1–3
(SHEETS-UI.1–20) done 2026-10-09, with a PersonID generator for new
people; **EVENTS / PERSON-LOGIN** (user, 2026-10-09,
`events-and-person-login.md`) — users and roles view, PersonID + password
sign-in with an e-mailed link, My data with downloads, the general event
log (CloudEvents, hrda.<domain>.<subject>.<action>) and publishing to
RabbitMQ — done 2026-10-09.
Backups only before the release (user). Qualified
signatures later (user).

**Later (user, 2026-09-29): FSDC — flexible system of data consistency**,
`docs/design/data-consistency.md`: declarative rules in JSON with a visual
editor (proposed: GoRules ZEN engine + JDM Editor, MIT), switched on in
the settings; violations logged as potential security incidents; a
reference synthetic dataset with 1–3 % invalid records kept for
post-deployment checks. Core, editor, reference dataset and five more rules (signed after
basis, non-overlapping assignments, no diagnosis in restrictions, leave on
recorded leave) done 2026-09-29; "fitness only from a signed conclusion"
waits for board conclusions in the synthetic data. Deferred decisions, taken one at a time on request: more
clinical modules (long-term medication list, lab results); es/pt locales; Hasura vs
AshGraphql; password / PersonID sign-in; biometric storage; Salad UI;
RabbitMQ + outbox.
