#!/usr/bin/env python3
"""Downloads the place sources and writes trimmed, committed extracts to
ihds/seed/sources/places/ (stdlib only). Run by hand when updating the
data; build_seeds.py then builds seed/places.json and seed/regions.json
from the extracts, deterministically (that part is checked in CI).

Sources (see seed/SOURCES.md):
- GeoNames cities15000, admin1CodesASCII, alternateNamesV2 (CC BY 4.0)
- KATOTTH, the official codifier of Ukraine's administrative-territorial
  units, xlsx from the Ministry for Development of Communities

    python3 ihds/scripts/fetch_places_sources.py [--katotth URL] [--cache DIR]

The 195 MB alternateNamesV2.zip is only downloaded to the cache directory,
never committed; only names in LANGS for the kept places are extracted.
"""
import argparse
import csv
import io
import os
import urllib.request
import zipfile

import xlsx

GEONAMES = "https://download.geonames.org/export/dump/"
KATOTTH_URL = "https://mindev.gov.ua/storage/app/sites/1/uploaded-files/kodifikator-07-07.xlsx"
OUT = os.path.join(os.path.dirname(__file__), "..", "seed", "sources", "places")
# Languages of names kept: the app's languages plus a few that people
# commonly type place names in.
LANGS = {"en", "uk", "fr", "es", "pt", "de", "pl", "ru"}
# KATOTTH categories kept: O oblast/ARC, K city with special status,
# P raion (regions and context); M city, X settlement, C village (places).
# H (hromada) and B (city district) are territories, not places to be born in.
KATOTTH_KEEP = set("OKPMXC")


def fetch(url, cache):
    path = os.path.join(cache, url.rsplit("/", 1)[1])
    if not os.path.exists(path):
        print(f"downloading {url}")
        request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 ihds-seed"})
        with urllib.request.urlopen(request) as response, open(path + ".part", "wb") as f:
            while chunk := response.read(1 << 20):
                f.write(chunk)
        os.rename(path + ".part", path)
    return path


def write_tsv(name, header, rows):
    rows = sorted(rows)
    with open(os.path.join(OUT, name), "w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f, delimiter="\t", lineterminator="\n", quoting=csv.QUOTE_NONE, escapechar="\\")
        writer.writerow(header)
        writer.writerows(rows)
    print(f"{name}: {len(rows)} rows")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--katotth", default=KATOTTH_URL)
    parser.add_argument("--cache", default="/tmp/ihds-sources")
    args = parser.parse_args()
    os.makedirs(args.cache, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)

    # Cities: id, name, ascii name, lat, lon, feature code, country, admin1, population.
    with zipfile.ZipFile(fetch(GEONAMES + "cities15000.zip", args.cache)) as z:
        text = z.read("cities15000.txt").decode("utf-8")
    cities = []
    for line in text.splitlines():
        c = line.split("\t")
        cities.append((int(c[0]), c[1], c[2], c[4], c[5], c[7], c[8], c[10], int(c[14] or 0)))
    write_tsv("geonames-cities15000.tsv",
              ["geonameid", "name", "asciiname", "lat", "lon", "feature", "country", "admin1", "population"],
              cities)

    # Regions (first-level divisions): code "FR.11", name, geonameid.
    with open(fetch(GEONAMES + "admin1CodesASCII.txt", args.cache), encoding="utf-8") as f:
        admin1 = [tuple(line.rstrip("\n").split("\t")) for line in f if line.strip()]
    write_tsv("geonames-admin1.tsv", ["code", "name", "asciiname", "geonameid"],
              [(code, name, ascii_name, int(gid)) for code, name, ascii_name, gid in admin1])

    # Names of those cities and regions in LANGS (not historic, not colloquial).
    wanted = {c[0] for c in cities} | {int(a[3]) for a in admin1}
    names = set()
    with zipfile.ZipFile(fetch(GEONAMES + "alternateNamesV2.zip", args.cache)) as z:
        with z.open("alternateNamesV2.txt") as raw:
            for line in io.TextIOWrapper(raw, encoding="utf-8"):
                a = line.rstrip("\n").split("\t")
                if a[2] in LANGS and int(a[1]) in wanted and a[6] != "1" and a[7] != "1":
                    names.add((int(a[1]), a[2], a[3], int(a[4] == "1"), int(a[5] == "1")))
    write_tsv("geonames-names.tsv", ["geonameid", "lang", "name", "preferred", "short"], names)

    # KATOTTH: the seven columns of the codifier, header rows skipped.
    rows = []
    for r in xlsx.rows(fetch(args.katotth, args.cache)):
        r = (r + [""] * 7)[:7]
        if r[5] in KATOTTH_KEEP and r[0].startswith("UA"):
            rows.append(tuple(r))
    write_tsv("katotth.tsv", ["level1", "level2", "level3", "level4", "extra", "category", "name"], rows)
    print(f"KATOTTH source: {args.katotth}")


if __name__ == "__main__":
    main()
