#!/usr/bin/env python3
"""Builds the small seed datasets in ihds/seed/ from the vendored sources
in ihds/seed/sources/ (stdlib only; see seed/SOURCES.md for sources and
licences):

- countries.json  — ISO 3166-1 alpha-2; facts from awesome-travel,
  names from CLDR territories
- languages.json  — ISO 639-1; list from GeoNames iso-languagecodes,
  names from CLDR languages
- currencies.json — ISO 4217 (active, SIX list one); names and symbols
  from CLDR currencies
- regions.json, places.json — see places.py

Deterministic: same sources give byte-identical output (sorted keys and
entries), so rebuilding is idempotent. The `code` of every entry is the
value the main database stores.

    python3 ihds/scripts/build_seeds.py
"""
import csv
import json
import os
import xml.etree.ElementTree as ET

import places as places_builder

ROOT = os.path.join(os.path.dirname(__file__), "..", "seed")
LANGS = ["en", "uk", "fr", "es", "pt"]


def load(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as f:
        return json.load(f)


def common_names(value):
    """`translations`/`native` are a map of {lang: {common, official}} in
    some source entries and a list of such objects in others."""
    items = value.values() if isinstance(value, dict) else (value or [])
    return {v["common"] for v in items if isinstance(v, dict) and v.get("common")}


def cldr(kind, lang):
    """sources/cldr/<kind>-<lang>.json, the inner map below `main.<lang>`."""
    data = load(f"sources/cldr/{kind}-{lang}.json")["main"][lang]
    return data["localeDisplayNames"][kind] if kind != "currencies" else data["numbers"]["currencies"]


def write(dataset, description, entries, compact=False):
    entries.sort(key=lambda e: e["code"])
    codes = [e["code"] for e in entries]
    assert len(codes) == len(set(codes)), f"duplicate codes in {dataset}"
    out = {"dataset": dataset, "description": description, "entries": entries}
    with open(os.path.join(ROOT, f"{dataset}.json"), "w", encoding="utf-8") as f:
        if compact:
            # One entry per line: small file, readable diffs.
            f.write('{"dataset": %s, "description": %s, "entries": [\n' % (json.dumps(dataset), json.dumps(description, ensure_ascii=False)))
            f.write(",\n".join(json.dumps(e, ensure_ascii=False, sort_keys=True, separators=(",", ":")) for e in entries))
            f.write("\n]}\n")
        else:
            json.dump(out, f, ensure_ascii=False, indent=1, sort_keys=True)
            f.write("\n")
    print(f"{dataset}.json: {len(entries)} entries")


def build_languages():
    names = {lang: cldr("languages", lang) for lang in LANGS}
    path = os.path.join(ROOT, "sources/geonames-iso-languagecodes.txt")
    with open(path, encoding="utf-8") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))

    entries = []
    for row in rows:
        code = row["ISO 639-1"].strip().lower()
        if not code:
            continue
        english = row["Language Name"].strip()
        entries.append(
            {
                "code": code,
                "alpha3": row["ISO 639-2"].strip() or None,
                "iso639_3": row["ISO 639-3"].strip() or None,
                "names": {
                    lang: names[lang].get(code) or names["en"].get(code) or english
                    for lang in LANGS
                },
                "alt_names": sorted({english} - {names["en"].get(code)}),
            }
        )
    write("languages", "ISO 639-1 languages; code = two-letter code", entries)


# Entries of SIX list one that are not currencies anyone is paid in:
# funds, precious metals, SDR, bond-market units, test and "no currency".
NON_CURRENCIES = {"XAU", "XAG", "XPT", "XPD", "XDR", "XSU", "XUA", "XTS", "XXX",
                  "XBA", "XBB", "XBC", "XBD"}


def symbol(cldr_entry, code):
    """The English CLDR symbol, or the narrow one when the symbol is just
    the code ("UAH" → "₴"); None when neither says more than the code."""
    for key in ("symbol", "symbol-alt-narrow"):
        value = cldr_entry.get(key)
        if value and value != code:
            return value
    return None


def build_currencies():
    names = {lang: cldr("currencies", lang) for lang in LANGS}
    root = ET.parse(os.path.join(ROOT, "sources/iso4217-list-one.xml")).getroot()

    by_code = {}
    for entry in root.iter("CcyNtry"):
        code = entry.findtext("Ccy")
        name_el = entry.find("CcyNm")
        if not code or code in NON_CURRENCIES or name_el.get("IsFund") == "true":
            continue
        minor = entry.findtext("CcyMnrUnts")
        current = by_code.setdefault(
            code,
            {
                "code": code,
                "numeric": entry.findtext("CcyNbr"),
                "minor_units": int(minor) if minor and minor.isdigit() else None,
                "iso_name": name_el.text.strip(),
                "used_in": set(),
            },
        )
        current["used_in"].add(entry.findtext("CtryNm").strip())

    entries = []
    for code, c in by_code.items():
        en = names["en"].get(code, {})
        entries.append(
            {
                "code": code,
                "numeric": c["numeric"],
                "minor_units": c["minor_units"],
                "symbol": symbol(en, code),
                "names": {
                    lang: names[lang].get(code, {}).get("displayName") or en.get("displayName") or c["iso_name"]
                    for lang in LANGS
                },
                "alt_names": sorted({c["iso_name"]} - {en.get("displayName")}),
                "used_in": sorted(c["used_in"]),
            }
        )
    published = root.get("Pblshd")
    write("currencies", f"ISO 4217 active currencies (SIX list one, {published})", entries)


def build_places():
    regions, places, stats = places_builder.build()
    write("regions", "First-level divisions: GeoNames admin1 (code CC.NN); Ukraine from KATOTTH (level-1 code)", regions, compact=True)
    write("places", "Cities worldwide (GeoNames cities15000, code = GeoNames id) and every settlement of Ukraine (KATOTTH, code = KATOTTH code)", places, compact=True)
    print(f"places: {stats}")


def main():
    build_countries()
    build_languages()
    build_currencies()
    build_places()


def build_countries():
    countries = load("sources/awesome-travel-countries.json")
    names = {
        lang: load(f"sources/cldr/territories-{lang}.json")["main"][lang][
            "localeDisplayNames"
        ]["territories"]
        for lang in LANGS
    }

    entries = []
    for c in countries:
        code = c["cca2"].upper()
        entry = {
            "code": code,
            "alpha3": c.get("cca3"),
            "numeric": c.get("ccn3"),
            "names": {
                lang: names[lang].get(code) or c["name"]["common"] for lang in LANGS
            },
            "official_name": c["name"].get("official"),
            "alt_names": sorted(
                set(c.get("altSpellings", []))
                | {c["name"]["common"], c["name"]["official"]}
                | common_names(c.get("translations"))
                | common_names(c["name"].get("native"))
            ),
            "calling_codes": c.get("callingCode", []),
            "currencies": c.get("currency", []),
            "languages": sorted(c.get("languages", {}).keys()),
            "capital": c.get("capital") or None,
            "region": c.get("region") or None,
            "subregion": c.get("subregion") or None,
            "flag": code.lower(),
        }
        entries.append(entry)

    write("countries", "ISO 3166-1 countries; code = alpha-2", entries)


if __name__ == "__main__":
    main()
