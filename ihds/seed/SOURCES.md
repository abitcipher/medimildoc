# Seed data sources

| Dataset | File | Source | Licence |
|---|---|---|---|
| Countries: codes, facts, alternative spellings | `sources/awesome-travel-countries.json` | github.com/unseen1980/awesome-travel (`Countries/countries.json`, derived from mledoze/countries) | MIT |
| Country names in en, uk, fr, es, pt | `sources/cldr/territories-*.json` | Unicode CLDR 48.2.2, github.com/unicode-org/cldr-json (`cldr-localenames-full`) | Unicode License v3 |
| ISO 639-1 language list (with 639-2/639-3 codes) | `sources/geonames-iso-languagecodes.txt` | GeoNames, download.geonames.org/export/dump (inside `alternateNamesV2.zip`) | CC BY 4.0 |
| Language names | `sources/cldr/languages-*.json` | Unicode CLDR 48.2.2 (`cldr-localenames-full`) | Unicode License v3 |
| ISO 4217 active currencies | `sources/iso4217-list-one.xml` | SIX Group (ISO 4217 maintenance agency), list one, published 2026-09-17 | freely published by the maintenance agency |
| Currency names and symbols | `sources/cldr/currencies-*.json` | Unicode CLDR 48.2.2 (`cldr-numbers-full`) | Unicode License v3 |

| Cities worldwide, population 15 000+ (trimmed: id, names, country, admin1, population) | `sources/places/geonames-cities15000.tsv` | GeoNames `cities15000.zip`, download.geonames.org/export/dump | CC BY 4.0 |
| First-level divisions (regions) | `sources/places/geonames-admin1.tsv` | GeoNames `admin1CodesASCII.txt` | CC BY 4.0 |
| Names of those cities and regions in en, uk, fr, es, pt, de, pl, ru (not historic, not colloquial) | `sources/places/geonames-names.tsv` | GeoNames `alternateNamesV2.zip` (195 MB, not committed; filtered by the fetch script) | CC BY 4.0 |
| Every settlement, raion and oblast of Ukraine with official codes | `sources/places/katotth.tsv` | KATOTTH codifier, edition of 7 July 2026, `kodifikator-07-07.xlsx` from the Ministry for Development of Communities (mindev.gov.ua / mininfra.gov.ua); categories O, K, P, M, X, C kept | official state data (the ministry's own copy on data.gov.ua is CC BY and outdated) |

The `sources/places/` extracts are written by `scripts/fetch_places_sources.py`
(downloads, then trims); the other files are stored as downloaded.
`seed/*.json` are generated from these by `scripts/build_seeds.py`; edit the sources or
the scripts, never the generated files. Codes in generated files are the
values the main database stores and must never change or be reused.
