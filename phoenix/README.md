# App — Phoenix backend

Real logic and state for the Sheets sidebar live here; `apps_script/` is only
a thin iframe host. See `/` for the full picture.

## Setup

* `mix setup` — deps, database (needs a local Postgres reachable per
  `config/dev.exs`), assets.
* `mix phx.server` (or `iex -S mix phx.server`) — starts on
  [`localhost:4000`](http://localhost:4000).
* `/people`, `/organizations`, `/positions` require a signed-in Google
  account, with a three-tier role on top (`:admin`/`:hr`/`:viewer`)
  — any role can view, only `:admin`/`:hr` can edit;
  `/users` (admin-only) manages everyone's role. New users default to
  `:viewer` — promote the first admin by hand once, via remote console
  (exact command). `config/dev.exs` has placeholder
  `GOOGLE_CLIENT_*` values so the app boots and `/sign-in` renders
  without any setup, but the actual Google redirect needs a real OAuth
  client: create one at [Google Cloud Console](https://console.cloud.google.com)
  (APIs & Services → Credentials → OAuth client ID, Web application), set
  `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET` env vars, and register
  `http://localhost:4000/auth/user/google/callback` as an Authorized
  redirect URI. `/sheets` (the embedded sidebar) is unaffected — separate
  ADR-3 token auth, no login screen.

## M0/M1 status

* `/sheets` — the LiveView the Apps Script sidebar iframe points at. Ticks a
  counter every second over the socket to prove the WSS round-trip works.
* `AppWeb.Plugs.FrameAncestors` — sets
  `Content-Security-Policy: frame-ancestors https://*.googleusercontent.com
  https://docs.google.com` and drops `x-frame-options`, scoped to the
  `/sheets` route only (other routes keep Phoenix's default
  `frame-ancestors 'self'`).
* **M1 (§8 step 4-5, ADR-3):** `assets/js/sheets_bridge.js` holds the
  LiveSocket connect until the parent sidebar answers a postMessage
  `REQUEST_CONTEXT` with `{spreadsheetId, sheetName, a1, email, token}` (or
  it times out / isn't embedded at all — e.g. opening `/sheets` directly in
  a plain tab during local dev). The token then rides as a `connect_params`
  entry (`sheets_token`) and `AppWeb.SheetsLive.mount/3` verifies it via
  `App.SheetsToken` — not a Plug, since connect_params only exist once the
  socket is up, matching ADR-3's "LiveView verifies at mount/3". Only `sub`
  (email) and `ssid` (spreadsheet id) are cryptographically covered by the
  signature; `sheetName`/`a1` ride unsigned and are informational only.
* **M2 (§8 steps 6-7, ADR-5):**
  * `App.Google.Sheets` — thin Sheets API v4 client (`Req`). Every call takes
    the caller's own Google access token explicitly; never a shared
    service-account/`goth` token (`goth` only re-enters the picture for
    server-initiated calls outside a user's request, which don't exist yet).
  * `assets/js/sheets_bridge.js`'s context now also forwards
    `google_access_token` (from `ScriptApp.getOAuthToken()`, *not* verified
    by us — Google verifies it when we use it), plus `sheet_name`/`a1`
    (unsigned, informational — picks the default range, never used for
    authorization). `AppWeb.SheetsLive` reads a default `A1:E20` range on
    connect and renders it as a table, with a form to write back to `A1`.
  * `AppWeb.Plugs.VerifySheetsToken` is now wired: `POST
    /webhooks/sheets/edit` is the target of the shim's installable `onEdit`
    trigger (`onSheetEdit` in `apps_script/src/main.ts`) — authenticated the
    same HMAC way as the LiveView's `sheets_token`. On success it calls
    `App.Sheets.notify_edit/2`, which broadcasts over `Phoenix.PubSub` to
    `"sheets:#{spreadsheet_id}"`; any `AppWeb.SheetsLive` subscribed to that
    spreadsheet re-fetches its range. Per §6, `onEdit` isn't transactional
    and delivery isn't guaranteed — this is a best-effort nudge 
    Sheets is a view, never the source of truth), not a critical path.

* **M3:** the domain layer, on Ash — `App.People`
  (`mix.exs`: `ash`, `ash_postgres`, `ash_phoenix`). The domain-only first
  pass deliberately skipped Cinder/salad_ui/json_forms_lv (see the M3
  kickoff decision) — the forms UI below is hand-rolled instead.
  * `App.People.Organization` — self-referential company/department/
    team/military-unit-echelon (`kind`, an open-ended atom — NATO-style
    decomposition per §1, extend by adding an atom, not a migration).
  * `App.People.Position` — a billet in an org, with an optional
    `reports_to` position. Reporting chains attach to the *position*, not
    the person (NATO/military convention) — `App.People.current_manager/2`
    and `App.People.direct_reports/2` derive the answer by following a
    person's *current* `Assignment`, nothing stored redundantly.
  * `App.People.Person` — deliberately minimal core identity. Everything
    that accrues over a person's life stays out of this resource.
  * `App.People.Assignment` — a person's full assignment history to a
    position (`ends_on: nil` = current), not a single overwritten field.
  * `App.People.PersonRecord` — §1's "modular growth" mechanism: JSONB
    `data` + a `kind` atom selecting which JSON Schema
    (`App.People.PersonRecordSchema`, loaded from
    `priv/person_record_schemas/*.schema.json` + matching `*.ui.json`
    UI Schemas — §1 mandates both) governs it, validated on
    create/update via `ex_json_schema`. Ships with five kinds:
    `:medical_condition` (FHIR `Condition`-flavored, not conformant — see
    the M3 kickoff decision on why no FHIR library), `:status_change`
    (generic pay/marital/address/rank change), and 
    `:rank_history`/`:contact_info`/`:language_proficiency` —
    illustrative placeholders for APERSP-01/STANAG 5046/STANAG 6001,
    explicitly *not* verified against the primary standards texts
    (`:rank_history`'s `grade` is pattern-validated, not a closed enum,
    specifically to avoid presenting an unverified code list as
    authoritative). Adding a kind is two JSON files, not a migration.
  * Every resource has an `Ash.Policy.Authorizer` policy requiring
    `actor_present()` — fails closed since there's no actor/role model yet;
    fine-grained rules (e.g. clinician-only access to `:medical_condition`)
    are a follow-up once one exists.
  * Migrations generated (`mix ash_postgres.generate_migrations`) under
    `priv/repo/migrations/` — **not applied/verified against a live DB in
    this environment** (Postgres client only, no server available here);
    run `mix ecto.migrate` yourself once Postgres is reachable.

* **M3 forms UI (§1's "форма для ввода... композиция"):** a standalone
  admin UI at `/people`, `/organizations`, `/positions` — not embedded in
  the Sheets sidebar (no `:embeddable` pipeline). No auth model yet: every
  page passes `AppWeb.PlaceholderActor.get()` as `actor` — replace once an
  accounts/roles resource exists.
  * `AppWeb.JsonSchemaForm` — the generic renderer calls for
    ("JSON Schema/UI Schema mandatory for every form"): turns a UI
    Schema's `Control`s + the matching JSON Schema into `<.input>`s. Two
    binding modes — `form` (an `AshPhoenix.Form`, for the plain
    Person/Organization/Position/Assignment resources; Ash owns
    validation) and `values`/`name` (a plain, possibly-nested map with
    hand-built `record_data[code][text]`-style names, for
    `PersonRecord.data` — one JSONB attribute, not a set of Ash
    attributes Phoenix's form machinery understands). `field_options`
    overrides a field's widget with a `select` of given options, for
    values a static schema can't express (`organization_id`,
    `position_id`, `reports_to_id` — existing rows, not enum values).
  * `AppWeb.FormSchemas` — the JSON Schema/UI Schema pairs for the plain
    resources (`priv/form_schemas/`), the counterpart to
    `App.People.PersonRecordSchema`. Presentation-only (widget/label
    choice), deliberately *not* a second validation source of truth —
    real errors still come from Ash.
  * `AppWeb.PeopleLive.Show` is the composition page: identity + current
    position/manager/direct-reports + assignment history + an "assign to
    a position" form + `PersonRecord`s grouped by kind + an "add a
    record" form (kind picker → `PersonRecordSchema`-driven form). Adding
    a record goes through `Ash.Changeset.for_create/4` + `Ash.create/2`
    directly rather than `AshPhoenix.Form` — `data`'s nested shape isn't
    a natural fit for it.
  * A real bug caught by its own test suite: `path_atom/1` (turns a JSON
    pointer segment into the Ash attribute atom `form[field]` binds to)
    originally used `String.to_existing_atom/1` on the reasoning that Ash
    attribute names are already-compiled atoms — true only once that
    resource module is actually *loaded*, not just compiled, which isn't
    guaranteed. Failed intermittently depending on what else in a test
    run happened to load `App.People.Person` first. Fixed to
    `String.to_atom/1` — safe here since the input is our own small,
    fixed set of `priv/form_schemas/` JSON files, not user input.

* **Postgres 18 + UUIDv7, and a JSON Schema/Ash sync check ("latest
  stable" + "single source of truth in declarative JSON" decisions):**
  * All five `App.People` resources use `uuid_v7_primary_key` (Ash's
    built-in, generates app-side via `Ash.UUIDv7.generate/0` — not
    dependent on Postgres's own native `uuidv7()`, but AshPostgres *does*
    use PG18's native function for the DB-level default once
    `App.Repo.min_pg_version` says 18+, instead of the polyfill SQL
    function it installs for older Postgres). Verified live: created
    records via the release's remote console against a real Postgres 18
    container, decoded the resulting ids — version nibble `7`, correct
    RFC 4122 variant bits, two ids created 50ms apart came back correctly
    time-ordered.
  * A real Postgres-18-specific bug caught the same way: its official
    Docker image changed the expected data-volume mount point from
    `/var/lib/postgresql/data` to `/var/lib/postgresql` (it now manages a
    version-specific subdirectory itself) — the old mount point makes the
    container refuse to start at all. Fixed in
    `infra/docker-compose.yml`; would not have been caught without
    actually booting the container.
  * `App.AshJsonSchema` derives the JSON Schema an Ash action actually
    accepts/requires by introspection (`Ash.Resource.Info`), and
    `test/app_web/form_schemas_sync_test.exs` asserts
    `priv/form_schemas/*.schema.json` agrees with it — catches the exact
    class of drift `AppWeb.FormSchemas`' moduledoc used to flag as a
    known risk (a hand-copied enum, or any future accepted-field/required
    change, going stale). Not full equality — a hand-authored file may
    deliberately omit a field Ash accepts (contextual/deferred fields) —
    just a subset/compatibility check.

* **Edit/delete for all five resources ("core functionality" — credentials
  aside, adding/editing is now complete):**
  * `PeopleLive.Edit` (`/people/:id/edit`) — same `AshPhoenix.Form`/
    `JsonSchemaForm` pattern as `New`, via `for_update/2`.
  * Organizations/Positions `Index` pages gained inline edit (row toggles
    to an edit form in place, same `field_options` dynamic-select pattern
    as create) and delete.
  * `PeopleLive.Show` gained delete for the person, plus inline edit/delete
    for each `Assignment` (a new `priv/form_schemas/assignment_edit.*`
    pair — just `starts_on`/`ends_on`, since `position_id`/`person_id`
    aren't revisited after creation) and each `PersonRecord` (edit reopens
    the add-record form pre-populated, submitting to `Ash.Changeset.
    for_update/4` instead of `for_create/4`).
  * Deletes can fail on an FK violation (e.g. a `Person` with existing
    `Assignment`s/`PersonRecord`s) — migrations don't cascade on purpose,
    so this surfaces as a flash, not a crash.
  * A real bug the live-verification loop caught:
    `Exception.message/1` on an `Ash.Error.Invalid` is not fit for a flash
    message — confirmed empirically (deleting a `Person` with a dependent
    `Assignment`) it renders "Bread Crumbs: > Error returned from: ...",
    blank lines, and file/line stacktrace references, meant for logs, not
    users. `App.AshErrors.summarize/1` extracts each field-level error's
    plain `.message` instead ("id: would leave records behind") and is
    now used at all 7 call sites that used to call `Exception.message/1`
    directly.
  * **Real browser verification (Playwright), once unblocked** — the user
    symlinked a snap-installed Chromium to the system-Chrome path the MCP
    tool requires. Clicking through the actual UI found two real bugs no
    amount of remote-console/curl testing had caught:
    1. **Data corruption**: editing a `Position` and clicking Save
       *without touching* the "Reports to" field silently set
       `reports_to_id` to the position's own id (self-reference!). Cause:
       our `<.input type="select">` for `field_options`-driven pickers
       (`organization_id`, `reports_to_id`, ...) never got a blank
       `prompt` option, so a `nil` value made the browser *display* (and,
       if untouched, *submit*) whichever option happened to render first
       — a plausible-looking but entirely accidental selection. Fixed:
       `AppWeb.JsonSchemaForm` now passes `prompt: "— select —"` for every
       `field_options`-driven select. Re-verified live: the blank prompt
       correctly shows for a genuinely-`nil` relationship and the real
       value for a set one; saving untouched now correctly leaves `nil`
       fields `nil`; submitting a required field left blank now correctly
       surfaces Ash's own "is required" validation instead of silently
       storifying garbage.
    2. **Silent UI failure**: every "New X" / "Add a record" `<details>`
       disclosure collapsed itself the instant you typed into any field
       inside it. Cause: `<details open>`'s state is native-HTML/
       client-only — untracked by any LiveView assign — so the next
       `phx-change` round-trip's DOM patch reset it to the server's
       rendered (always-closed) markup. Fixed: replaced every such
       disclosure (`OrganizationsLive.Index`, `PositionsLive.Index`,
       both embedded forms in `PeopleLive.Show`) with an always-visible
       section; the inner `PersonRecord` add-vs-edit visibility already
       ran through a proper assign-backed `:if`, so only the outer
       wrapper needed to change.
    Also confirmed: Assignment inline edit (ends_on save → "Current
    position" correctly flips to "No current assignment"), PersonRecord
    inline edit (data updates, though note: unset *optional* JSON Schema
    fields round-trip as `""` rather than being omitted — an HTML-form
    artifact, not a validation gap, since `""` is still schema-valid),
    Organization inline edit, and the exact `App.AshErrors.summarize/1`
    flash text rendering correctly on a real FK-violation delete attempt.
  * Before the fix was found: browser verification was blocked in this
    sandbox (MCP tool needs a real system Chrome at
    `/opt/google/chrome/chrome`, no `sudo` available) and the fallback was
    the release's remote console + curl — real Ash calls, real Postgres
    18, but unable to catch either bug above since neither is a
    server-side/data-layer defect, both are purely in how the browser
    renders and resubmits DOM state.

Needs a reachable Postgres for `mix test`'s `AppWeb.ConnCase`/`App.DataCase`
(always checks out a sandboxed DB connection, even for DB-free tests like
`AppWeb.SheetsLiveTest` and `AppWeb.SheetsWebhookControllerTest`), and for
any test that actually reads/writes an Ash resource — `mix ecto.create &&
mix ecto.migrate` first. `App.SheetsTokenTest`, `App.Google.SheetsTest`,
`App.People.PersonRecordSchemaTest`, `AppWeb.JsonSchemaFormTest`,
`App.AshJsonSchemaTest`, and `AppWeb.FormSchemasSyncTest` have no such
dependency (all pure `Ash.Resource.Info` introspection or component
rendering — no live server needed either); to run just those without
touching the DB:

```bash
MIX_ENV=test mix run --no-start -e '
Application.ensure_all_started(:req)
ExUnit.start()
Code.require_file("test/app/sheets_token_test.exs")
Code.require_file("test/app/google/sheets_test.exs")
Code.require_file("test/app/people/person_record_schema_test.exs")
Code.require_file("test/app_web/components/json_schema_form_test.exs")
Code.require_file("test/app/ash_json_schema_test.exs")
Code.require_file("test/app_web/form_schemas_sync_test.exs")
'
```

(`Application.ensure_all_started(:req)` is needed for `Req.Test`'s ownership
process, which `--no-start` would otherwise also skip along with our own,
DB-needing `App.Application`.)

## Quality gates

```bash
mix format
mix credo --strict
mix dialyzer   # first run builds a PLT under priv/plts/, several minutes
```

## Deploying

`Dockerfile`, `.dockerignore`, `rel/`, and `lib/app/release.ex` here are the
standard `mix phx.gen.release --docker` output — see `../infra/README.md`
for the actual deploy (docker-compose: this app + Postgres + Caddy for
automatic HTTPS). That whole path — image build, migrations, resource
CRUD, `App.People.current_manager/2`/`direct_reports/2`, and 
the Google-auth routes/redirect — has been run against a real
Postgres in a container and confirmed working end to end.
