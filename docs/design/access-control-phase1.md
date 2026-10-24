# Access control — phase 1 design

Status: **phase 1 implemented** (2026-09-25; commits `0d20d76`, `c801164`,
`b302212`, `5b987b9`, `a5f68d4`). Deviations from the text below, found
while building it;

Inputs: the user's role structure (clinical, administrative, military
medical roles; ABAC; FHIR security labels; Break the Glass) and the
decisions of 2026-09-25:

1. System Administrator has full data access during development (needed
   for the user's own testing). Must be switchable off before go-live.
2. Educational module (students, instructors, dean's office) — deferred.
3. No real medical data exists. The project generates its own synthetic
   data for automated and manual testing.
4. Encryption key lives in `infra/.env` on the VPS; only the project team
   has production access during development.

## 1. Scope

Phase 1 covers what exists in the app today. Phase 2 and later items are
listed alongside so nothing here pretends to cover them.

| In phase 1 | Phase 2 | Later (own module, on request) |
|---|---|---|
| Permissions + access profiles on top of `role` | Link `User` ↔ `Person` | Clinical resources (Encounter, Observation, Procedure, orders, vitals) |
| Record categories + security labels on `PersonRecord` | Unit scoping over the Organization tree | MEDEVAC / 9-line |
| New kinds: `fitness_for_duty`, `allergy_intolerance`, `vetting_record` | Clearance-level check (actor clearance vs record classification) | Medical logistics |
| Split `security_clearance` → status + `vetting_record` | Break the Glass | Educational module, trainee supervision |
| Encryption at rest (AshCloak) | CISO review workflow for BTG | De-identified research export |
| Access log for sensitive reads | Maker-checker for sensitive grants | Coalition exchange, offline sync |
| Synthetic data generator (seeds + test fixtures) | | |

## 2. Permission model

`App.Accounts.User` keeps `role` (`:admin | :hr | :viewer`) as the base
tier and gains:

```elixir
attribute :profiles, {:array, :atom}, default: [], constraints: [items: [one_of: [...]]]
```

A user's effective permissions are the union of the base role's bundle
and each profile's bundle. Bundles live in `priv/access_profiles.json`
(declarative JSON), loaded and validated at compile time
by `App.Access.Profiles`, the same way `PersonRecordSchema` loads kind
schemas. Policies stay explicit Elixir code the JSON only maps a
profile name to a list of permission strings, it never contains logic.

`App.Access.permissions(user)` → `MapSet` of permission strings. One
policy check, `App.Access.Checks.HasPermission, permission: "…"`, and one
filter check are the only places that read it.

### Permissions

| Permission | Grants |
|---|---|
| `people.read` | Person, Organization, Position, Assignment; records in category `personnel` |
| `people.write` | Create/update/delete those |
| `people.private.read` / `.write` | National IDs, identity documents, biometrics |
| `people.hr_private.read` / `.write` | Records in category `personnel_private` (pay, family status, dependents) |
| `readiness.read` / `.write` | Records in category `readiness` |
| `clearance.read` / `.write` | Records in category `clearance` (level, status, dates) |
| `medical.read` / `.write` | Records in category `medical` |
| `vetting.read` / `.write` | Records in category `vetting` |
| `audit.read` | Access log, change-conflict log |
| `users.manage` | `/users`: assign role and profiles |

### Base roles and profiles

| Name | Maps to (from the user's structure) | Permissions |
|---|---|---|
| role `:viewer` | any signed-in staff | `people.read` |
| role `:hr` | HR Specialist | `people.*`, `people.private.*`, `people.hr_private.*`, `readiness.read`, `clearance.read` |
| role `:admin` | System Administrator | `users.manage`, `people.*` **+ every other permission while `ADMIN_FULL_DATA_ACCESS=true`** |
| profile `registrar` | Registrar / Patient Administration Officer | `people.*`, `people.private.*` (demographics and IDs, no clinical data) |
| profile `line_commander` | Line Commander / G-1 | `readiness.read` only — clinical data fully hidden |
| profile `clinician` | Military Field Physician / Medical Officer; Clinician | `medical.*`, `readiness.*`, `people.private.read` |
| profile `command_surgeon` | Brigade / Command Surgeon | `medical.read`, `readiness.*` (phase 2 adds command-subtree scope) |
| profile `security_officer` | security / vetting officer | `clearance.*`, `vetting.*` |
| profile `ciso` | CISO | `audit.read` — no clinical or vetting content |

Profiles for roles with no data yet (Nurse, Combat Medic, MedLog,
Researcher, Trainee, Student…) are added with their modules, not now.

### 2.1 Admin full access (development)

`config :app, :admin_full_data_access` — runtime, from
`ADMIN_FULL_DATA_ACCESS` (default `true` in dev/test and in the current
`infra/.env`). When true, `:admin` gets every permission. At boot the app
logs a warning when it is true in `:prod`. Turning it off is one env
change and is the first item on the go-live checklist. Admin reads of
sensitive records are still written to the access log either way.

## 3. Record categories and security labels

### 3.1 Category (enforced in phase 1)

Every kind declares a category in its schema file (`x-category`), so a
new kind needs no policy change:

| Category | Kinds |
|---|---|
| `personnel` | `status_change`, `rank_history`, `contact_info`, `language_proficiency` |
| `personnel_private` | `compensation`, `family_status`, `dependent` |
| `readiness` | `fitness_for_duty` (new) |
| `clearance` | `security_clearance` |
| `medical` | `medical_condition`, `allergy_intolerance` (new) |
| `vetting` | `vetting_record` (new) |

`personnel_private` is an addition beyond the medical/clearance question:
today any viewer can read salaries, dependents and national ID numbers.
Pay and family data have their own permission (`people.hr_private.*`),
separate from identity documents (`people.private.*`): a clinician or
registrar needs a patient's national ID, not their salary. (Found while
checking step 3's synthetic data per demo user; the first version shared
one permission.)

### 3.2 Security labels (stored in phase 1, enforced in phase 2)

Two new `PersonRecord` attributes, modelled on FHIR `meta.security` and
kept as separate axes:

- `confidentiality` — HL7 v3 Confidentiality (`u l m n r v`), system
  `http://terminology.hl7.org/CodeSystem/v3-Confidentiality`.
- `classification` — NATO marking (`nato_unclassified`,
  `nato_restricted`, `nato_confidential`, `nato_secret`,
  `cosmic_top_secret`), nil when not classified.

Each kind declares defaults (`x-default-confidentiality`,
`x-default-classification`): medical kinds `r`, `vetting_record` `v` +
`nato_restricted`, personnel `n`. A writer may raise a record's label but
not set it below the kind default (validation). Phase 2 compares
`classification` with the actor's clearance.

### 3.3 Enforcement

- **Read:** one filter check,
  `App.Access.Checks.ReadableRecords`, returns
  `expr(kind in ^readable_kinds(actor))`. Unreadable records never leave
  the database — the Cinder table, counts and any future API are covered
  without UI changes.
- **Write:** `create`/`update`/`destroy` authorize when the actor has the
  `<category>.write` permission for the record's kind.
- The same pattern (`HasPermission`) replaces the role checks on Person,
  Organization, Position, Assignment, PersonIdentifier, IdentityDocument,
  BiometricRecord and ChangeConflict.
- UI hiding (`AppWeb.Authz`) switches from role checks to
  `App.Access.can?/2`; it stays UX only.

## 4. New and changed kinds

- **`fitness_for_duty`** (readiness): `status` ∈ `fit_for_duty`,
  `downgraded`, `non_effective`; `restrictions` (text, no diagnosis);
  `reviewDate`; `assessedBy`. This is the only medical-derived fact line
  commanders see.
- **`allergy_intolerance`** (medical), aligned with FHIR
  `AllergyIntolerance`: `code`, `clinicalStatus`, `criticality`,
  `category`, `reaction`, `note`. Phase 2's Break the Glass targets this
  kind.
- **`vetting_record`** (vetting): `investigatingAuthority`,
  `investigationType`, `openedOn`, `closedOn`, `outcome`, `note`.
- **`security_clearance`** schema version 2: keeps `clearanceLevel`,
  `status`, `grantedDate`, `expiryDate`; `clearanceLevel` switches to
  NATO markings (`NONE`, `NATO_RESTRICTED`, `NATO_CONFIDENTIAL`,
  `NATO_SECRET`, `COSMIC_TOP_SECRET`); `investigatingAuthority` and
  `note` move to `vetting_record`.

Blood group is left for the clinical Observation module rather than
invented as a kind now.

## 5. Encryption at rest

- Deps: `{:ash_cloak, "~> 0.4"}` (Ash-native, supports Ash `~> 3.26`;
  we run 3.33) and `{:cloak, "~> 1.1"}`.
- `App.Vault` (Cloak vault, AES-256-GCM). Key from `CLOAK_KEY`
  (base64, 32 bytes) — required in prod by `config/runtime.exs`, fixed
  throwaway keys in dev/test.
- Encrypted: `PersonRecord.data` (all kinds — one attribute, one rule),
  `PersonIdentifier.value`, `IdentityDocument.number`.
- Rotation: add the new key as the default cipher with a new tag, keep
  the old one for decryption, run `mix app.reencrypt`, then drop the old
  key. Written down in `infra/README.md`.
- Consequence: no SQL filtering inside those fields. Nothing filters
  inside them today (Cinder filters by `kind`, not `data`).

## 6. Access log

New `App.Audit.AccessLog` (next to `ChangeConflict`): `actor_id`,
`actor_email`, `resource`, `record_id`, `person_id`, `kind`, `reason`
(nil in phase 1, used by BTG later), `accessed_at`. Written by an
`after_action` preparation on reads of `medical`, `vetting` and
`personnel_private` records and of PersonIdentifier/IdentityDocument —
one row per returned record. Create is internal only
(`authorize?: false`); read needs `audit.read`. New admin-area page
`/access-log`; `/change-conflicts` moves from `:admin` to `audit.read`.

## 7. Synthetic data

No dependency: `App.Demo` generates deterministic data from a seed
(`:rand` with a fixed seed, built-in name lists for en/uk/fr).

- Explicit flag: new boolean `synthetic` on Person and Organization
  (default false), shown as a "Synthetic" badge in the UI. Purge deletes
  by this flag, never by guessing.
- Generated IDs can't collide with real ones: national ID values are
  prefixed `TEST-`; emails use the reserved `.test` TLD (RFC 6761).
- Structure: a demo brigade → battalions → companies, plus a Role 2
  medical company and a Role 3 field hospital; positions (commanders,
  surgeon, physicians, medics, HR, registrar); ~150 people with
  assignments and records of every kind, including edge cases (expired
  clearance, downgraded fitness, allergy with high criticality).
- One demo user per base role and profile (`clinician@demo.test`, …),
  listed on `/dev/sign-in` so each profile can be tried by hand.
- `mix app.demo.seed [--people N] [--seed S]`, `mix app.demo.purge`; in
  the release: `bin/app eval "App.Release.seed_demo()"`.
- Tests reuse `App.Demo` builders with small counts through a new
  `test/support/fixtures.ex`.

## 8. Migrations and data moves

Prod holds only test data, but migrations follow the project's
expand-contract rule anyway:

1. `users.profiles` (text[], default `{}`).
2. `people.synthetic`, `organizations.synthetic` (default false).
3. `person_records.confidentiality`, `.classification`; backfill from
   kind defaults.
4. Encrypted columns added next to `data` / `value` / `number`; a data
   task encrypts existing rows; old plaintext columns dropped in a
   separate migration after verification.
5. `security_clearance` v1 → v2: map level values, move
   `investigatingAuthority`/`note` into new `vetting_record` rows.
6. `access_logs` table.

## 9. Tests

- Policy matrix: every base role and profile × every category × read and
  write, table-driven from `priv/access_profiles.json` so the test and
  the config can't drift.
- Filter check: a `line_commander` listing a person's records sees
  `fitness_for_duty` and nothing clinical; counts match.
- Labels: defaults per kind; lowering below default rejected.
- Encryption: the raw column holds ciphertext; values round-trip.
- Access log: one row per sensitive record read; none for personnel kinds.
- Admin flag: admin reads medical with the flag on, is refused with it off.
- `security_clearance` v1 → v2 migration on fixture rows.
- Live check in Docker (Postgres 18 + release) and Playwright through
  several demo profiles, as usual.

## 10. Order of work

1. Permissions, profiles, policy rewrite, admin flag, `/users` profile
   editing (no data changes; existing behaviour preserved for
   admin/hr/viewer except the new `personnel_private` restriction).
2. Categories, labels, new kinds, clearance split, filtered UI.
3. Synthetic data generator (makes 1–2 testable by hand).
4. Encryption at rest.
5. Access log and `/access-log`.
6. Docs: rules, DEVLOG entry, go-live checklist
   (`ADMIN_FULL_DATA_ACCESS=false`, key custody).

Each step ends green on the full quality gate and is committed
separately; one VPS deploy at the end (batch-deploy rule).

## 11. Unverified or deferred

- NATO marking names are public; how AC/35-D/2000 maps them to personnel
  data handling is not verified.
- STANAG 2132's subject is not verified.
- Purpose-of-use codes other than `ETREAT` and `BTG` (e.g. the
  compliance code) to be checked against `v3-ActReason` before phase 2
  uses them.

## 12. Deviations found during implementation

- **Pay and family data got their own permission.** first gave
  `people.private.*` both identity documents and the `personnel_private`
  records, which let a clinician read salaries. They are now
  `people.hr_private.*` (HR only); `people.private.*` covers identity
  documents alone.
- **`vetting_record` has no required fields.** Old `security_clearance`
  rows carried only an authority and a note; the migration moves those
  as-is rather than inventing an investigation type.
- **Encryption: plaintext columns are kept for now, empty.** The expand
  step and the idempotent `App.Encryption.encrypt_plaintext/0` (run after
  every deploy's migrations) clear them; dropping them is a separate
  migration after production is verified (go-live checklist). Done
  2026-09-28: `DropPlaintextColumns` (refuses to run while any row has
  plaintext or lacks ciphertext); `encrypt_plaintext/0` removed.
- **Access log hooks into decryption** (AshCloak `on_decrypt`) instead of
  an `after_action` preparation: it covers every read path that exposes
  the value and fails closed. Reads without an actor are not logged.
- **`App.Release` helpers start the app with the HTTP endpoint off**, so
  `bin/app eval` next to the running server doesn't try to bind its port.
