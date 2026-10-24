# Reference data, files and input formats — proposal

Status: **decided, in progress** (2026-09-27). 
Done:IHDS with countries and country picker (step 2),
step 3 — languages, currencies, places, regions, learned suggestions,
tags, step 4 — RustFS, attachments, portrait
photos. Step 5 (RabbitMQ) only when asynchronous
processing is needed (thumbnails, DICOM previews, virus scanning).

**Step 4 decisions (user, 2026-09-27):** DICOM download only (viewer
later); no encryption by the app — short-lived signed links plus the
access log (at-rest protection: disk encryption, go-live checklist);
200 MB per file; files on the person (Files tab), on records, and a
portrait photo as avatar.

**Step 3 decisions (user, 2026-09-27):**

- Places: GeoNames `cities15000` worldwide (CC BY 4.0, attribution in the
  footer and README) plus every Ukrainian settlement from the official
  KATOTTH codifier. Names in uk/fr/es/pt from GeoNames `alternateNamesV2`
  (downloaded by the build script only, never committed).
- Birth locality/region: the free-text fields stay; optional code fields
  are added (GeoNames id or KATOTTH code). Picking a suggestion fills both;
  unknown places keep only the text.
- Learned suggestions: only non-sensitive organisational names (issuing
  authorities, vetting authority). Stored in IHDS as bare values with a
  count, never linked to a person, on a persistent volume. Never medical
  or personal free text.
- Multi-value tags: first used for the allergy `category` (FHIR allows
  0..*): single value → list, `x-version` raised, stored records migrated.
- Languages: CLDR names for ISO 639-1 codes. Currencies: ISO 4217 active
  list (SIX Group) with CLDR names. Four parts, from the
user's brief. Decisions:

- **B (IHDS):** own Rust service (axum + Tantivy) — chosen by the user.
- **A (date picker):** own component (mask + native calendar popup) — the
  recommended option, taken as default; easy to revisit.
- **C (RabbitMQ):** added with the first asynchronous job, with a Postgres
  outbox — recommended default, easy to revisit.

## 1. Country fields

Every field holding an ISO 3166-1 alpha-2 code (`Person.birth_country`,
`PersonIdentifier.country`, `IdentityDocument.issuing_country`, …) becomes a
country picker: flag + name in the user's language, searchable by name in
any language, by alpha-2/alpha-3 code and by alternative spellings; the
stored value stays the alpha-2 code.

- Flags: `flag-icons` (flagicons.lipis.dev, MIT) SVGs, vendored, served as
  static assets (no CDN: the app runs offline too).
- Names: Unicode CLDR localized territory names (en, uk, fr, es, pt and any
  later language). The countries files the brief points to (awesome-travel,
  MIT; mledoze, ODbL) have no Ukrainian names.
- Data behind the picker comes from IHDS; a JSON Schema field opts in
  with `"x-reference": "country"`.

## 2. Dates as dd.mm.yyyy

All date inputs show and accept `dd.mm.yyyy`; values are still stored and
exchanged as ISO `yyyy-mm-dd`. Display of dates (record cards, tables)
follows the same format.

- The browser's own `<input type="date">` formats by the browser's locale
  and can't be forced to dd.mm.yyyy, so the input becomes a text field with
  a dd.mm.yyyy mask, validation (real calendar dates), and a calendar button.
- **Future:** a per-user setting for the date format (dd.mm.yyyy,
  yyyy-mm-dd, mm/dd/yyyy). The format lives in one place
  (`AppWeb.DateFormat`) so that setting is a small change.

**Decision A — calendar picker:** own small component (mask + native
calendar popup behind a button, no dependency) or a library (e.g.
flatpickr, MIT).

## 3. IHDS — Information Handbook and Digest Service

A separate service holding reference data and answering the dynamic parts
of the UI: search-as-you-type, suggestions, and lookups by code.

### Architecture

**Decision B — how to build it on Tantivy** (Tantivy is a Rust library,
not a server):

| Option | For | Against |
|---|---|---|
| **Own small Rust service** (axum + Tantivy), recommended | exactly our API; small image; data model under our control; fast; runs offline | code we maintain |
| Quickwit (Tantivy-based server) | ready-made | built for append-only logs and big clusters; updating or deleting reference entries is awkward; heavy |
| ParadeDB `pg_search` (Tantivy inside Postgres) | no new service | not a separate service; ties search to the main database |

Recommended shape: `ihds/` in the monorepo, a Rust service in
`docker-compose.yml`, HTTP/JSON API, called from Phoenix with `Req`, never
from the browser directly (the app stays the single entry point and
applies its access rules).

### Data and identity

- **Seed data is static, versioned JSON** in `ihds/seed/` (countries,
  cities, languages, currencies, ranks, units of measure, …), each entry
  with a **stable code that never changes and is never reused**: ISO codes
  where a standard exists (alpha-2 countries, ISO 639-1 languages,
  ISO 4217 currencies, GeoNames ids for places), our own prefixed codes
  otherwise.
- The main database stores only these codes. IHDS resolves them to names,
  flags, synonyms. Same code in both places: no numeric ids that could
  shift between rebuilds.
- **Idempotent**: the index is rebuilt from the seed files; rebuilding twice
  gives the same result. A seed version hash is exposed so Phoenix can see
  which data version it talks to.
- User-entered values (for suggestions from earlier input) live in a
  separate, append-only "learned" collection, per category, never mixed
  with the curated seed.

### Proposed initial datasets

| Dataset | Source | Codes |
|---|---|---|
| Countries | awesome-travel countries.json (MIT) for facts, CLDR for names | ISO 3166-1 alpha-2 |
| Languages | CLDR / ISO 639 | ISO 639-1 (639-3 fallback) |
| Currencies | CLDR / ISO 4217 | ISO 4217 |
| Cities / localities | GeoNames cities15000 (CC BY 4.0); Ukraine in more detail from the official KATOTTH codifier | GeoNames id; KATOTTH code for Ukraine |
| NATO rank codes | our list, marked unverified as today | OR-1…OR-9, OF-1…OF-10 |
| Units, posts, medical terms | later, per module | own codes |

### Where the UI uses it (proposed use cases)

| UI element | Examples |
|---|---|
| Select with search (single value) | country, language, currency, issuing country, NATO grade |
| Autocomplete with hints (free text allowed) | birth locality and region, city in addresses, investigating authority, substance in allergies, condition names |
| Suggestions from earlier entries of the same category | unit names, position titles, issuing authorities, emergency-contact relationships |
| Multi-value tag input | languages spoken, allergy categories, tags on files |
| Code → label lookups (display) | show "🇺🇦 Ukraine" / "Україна" wherever an alpha-2 code is stored |
| Global quick search | jump to a country, city or reference entry from one box (later: people via the main DB) |
| Validation hints | "did you mean…" for misspelled places |

## 4. Files — RustFS

Photos, scans, X-rays, CT/MRI results and other large binaries are stored
in RustFS (S3-compatible, Apache-2.0, 1.0.0), not in Postgres.

- `docker-compose.yml` gets a `rustfs` service with a persistent volume.
- Phoenix talks to it with `ex_aws` + `ex_aws_s3`.
- A new Ash resource (`App.People.Attachment`) holds the metadata: person,
  optional record it belongs to, kind (photo, scan, imaging…), file name,
  content type, size, SHA-256, security labels, uploaded by/when. The object
  key is opaque (not derived from names).
- Upload and download go through the app (or short-lived presigned URLs it
  issues after the access check), so the same permissions, unit scope,
  clearance and access log apply as for records. The bucket is never public.
- Files are encrypted at rest (server-side encryption in RustFS, key kept
  like `CLOAK_KEY`).
- This also gives `BiometricRecord` (photo, signature, fingerprint) its
  storage, deferred since phase 1.

## 5. RabbitMQ

**Decision C:** add it now, or when a real asynchronous need appears.

Recommended: not yet. Today nothing needs a message bus: IHDS is
queried synchronously, uploads are synchronous. It becomes useful for
thumbnails/previews of images and DICOM, virus scanning, re-indexing IHDS
when learned values arrive, and syncing with Sheets. When the first of
those is built, add RabbitMQ with a transactional outbox table in Postgres
(events written in the same transaction as the data, then published), so
nothing is lost or sent twice.

## 6. Order of work (once decided)

1. Date format (small, independent).
2. IHDS service with countries (+ CLDR names) and the country picker.
3. Cities, languages, currencies; autocomplete and suggestions in forms.
4. RustFS and attachments (+ biometric photo).
5. RabbitMQ when step 4 needs asynchronous processing.
