# IHDS — Information Handbook and Digest Service

Reference data for the app: search-as-you-type, lookup by code, full lists.
Rust (axum + Tantivy). Design: `docs/design/reference-data-and-files.md`.

- **Data** only from `seed/*.json`, generated from the vendored sources in
  `seed/sources/` by `scripts/` (see `seed/SOURCES.md` for sources and
  licences). The seed is deterministic; CI checks it is up to date.
- **Codes** (`code`) are what the main database stores: ISO 3166-1 alpha-2
  for countries. They never change and are never reused.
- **Index** is built in memory at start from the seed files, so restarts
  are idempotent and the service has no state. Each dataset's version is
  the SHA-256 of its seed file.
- **Learned values** (organisational names entered before) are the only
  state: an append-only `learned.jsonl` in `IHDS_DATA_DIR` (a volume),
  each line `{"category", "value", "at"}` — no person, no record id —
  replayed into counts at start. The app decides which categories exist
  (`App.IHDS.learned_categories/0`).
- **Called only by the Phoenix app** (`App.IHDS`), never by browsers; no
  port is published in `infra/docker-compose.yml`.

## API

| Request | Answer |
|---|---|
| `GET /health` | `{"status":"ok","version":…}` |
| `GET /v1/datasets` | datasets with entry counts and versions |
| `GET /v1/{dataset}?lang=uk` | every entry, `label` in `lang` (English fallback); 400 for datasets over 10 000 entries (places: search only) |
| `GET /v1/{dataset}/search?q=нім&lang=uk&limit=20&country=UA` | prefix search over names in every language, alternative names and codes; `country` optional |
| `GET /v1/{dataset}/entries/{code}?lang=uk` | one entry, 404 if unknown |

| `POST /v1/learned/{category}` `{"value": "…"}` | records one use of a value (204); category `[a-z_]{1,40}`, value 1–200 chars |
| `GET /v1/learned/{category}/search?q=&limit=` | earlier values: those starting with the query first, then most used |

Datasets: `countries`, `languages`, `currencies`, `regions`, `places`.
Entries naming a `region` (and, in Ukraine, a `district`) get a
`context_label` such as "Бахчисарайський р-н, Автономна Республіка Крим".

Search ranking: an exact code or alternative name; then the name in the
requested language or in English starting with the query; then any other
name starting with it; then names containing it. Ties go to the heavier
entry (`weight`: population for places), then alphabetical. For weighted
datasets the 500 candidates are taken by weight, so a short prefix still
finds the big cities.

## Commands

```bash
python3 scripts/fetch_places_sources.py   # re-download place sources (by hand)
python3 scripts/build_seeds.py            # rebuild seed/*.json
cargo test
IHDS_ADDR=127.0.0.1:4100 cargo run --release
```

`IHDS_SEED_DIR` (default `seed`), `IHDS_ADDR` (default `0.0.0.0:4100`) and
`IHDS_DATA_DIR` (learned values; unset = in memory only) configure it. `ihds healthcheck` is used by the Docker healthcheck.
