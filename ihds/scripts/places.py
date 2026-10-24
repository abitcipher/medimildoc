"""Builds seed/regions.json and seed/places.json from the extracts in
seed/sources/places/ (written by fetch_places_sources.py). Called from
build_seeds.py; deterministic.

Ukraine comes from KATOTTH (official codes and Ukrainian names; English by
the official transliteration, Cabinet of Ministers resolution No. 55 of
2010). The ~400 Ukrainian cities that GeoNames also has are matched to
their KATOTTH entries by Ukrainian name within the same oblast, so they get
the usual names in other languages (Kyiv / Kiev / Kiew) and a population;
the entry keeps its KATOTTH code. Everything else comes from GeoNames
(code = GeoNames id).

A place names its `region` (a code in regions.json) and, in Ukraine, its
`district` (raion); IHDS composes the "raion, region" context line in the
requested language when it answers.
"""
import csv
import os
from collections import defaultdict

LANGS = ["en", "uk", "fr", "es", "pt"]
SEARCH_LANGS = ["en", "uk", "fr", "es", "pt", "de", "pl", "ru"]
SRC = os.path.join(os.path.dirname(__file__), "..", "seed", "sources", "places")

# KMU resolution No. 55 (2010). Word-initial forms first.
_INITIAL = {"є": "ye", "ї": "yi", "й": "y", "ю": "yu", "я": "ya"}
_LETTERS = {
    "а": "a", "б": "b", "в": "v", "г": "h", "ґ": "g", "д": "d", "е": "e", "є": "ie",
    "ж": "zh", "з": "z", "и": "y", "і": "i", "ї": "i", "й": "i", "к": "k", "л": "l",
    "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch", "ь": "", "ю": "iu",
    "я": "ia", "'": "", "’": "", "ʼ": "",
}


def transliterate(text):
    out = []
    word_start = True
    lower = text.lower()
    for i, ch in enumerate(lower):
        if ch == "г" and i > 0 and lower[i - 1] == "з":
            latin = "gh"  # "зг" → "zgh"
        elif word_start and ch in _INITIAL:
            latin = _INITIAL[ch]
        else:
            latin = _LETTERS.get(ch, ch)
        if text[i].isupper() and latin:
            latin = latin[0].upper() + latin[1:]
        out.append(latin)
        word_start = not ch.isalpha() and ch not in "'’ʼ"
    return "".join(out)


def _tsv(name):
    with open(os.path.join(SRC, name), encoding="utf-8") as f:
        return list(csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE, escapechar="\\"))


def _geonames_names():
    """{geonameid: {lang: [names, best first]}}"""
    by_id = defaultdict(lambda: defaultdict(list))
    for r in _tsv("geonames-names.tsv"):
        by_id[int(r["geonameid"])][r["lang"]].append(
            (-int(r["preferred"]), int(r["short"]), r["name"])
        )
    return {
        gid: {lang: [n for _, _, n in sorted(v)] for lang, v in langs.items()}
        for gid, langs in by_id.items()
    }


def _localized(fallback, names_by_lang):
    """names in LANGS: GeoNames' best name, else the fallback name."""
    out = {}
    for lang in LANGS:
        found = names_by_lang.get(lang)
        out[lang] = found[0] if found else fallback
    return out


def _compact(localized):
    """Drops languages whose text equals English (IHDS falls back to en)."""
    return {k: v for k, v in localized.items() if k == "en" or v != localized["en"]}


def _alt(*groups):
    return sorted({n for g in groups for n in g if n})


def _names_for_search(names):
    """At most two names per search language: GeoNames also lists
    grammatical case forms ("Киевом"), which only bloat the index."""
    return [n for lang in SEARCH_LANGS for n in names.get(lang, [])[:2]]


def _latin_key(name):
    return "".join(ch for ch in name.lower() if ch.isalpha())


def _bare_region(name):
    name = name.lower()
    for affix in (" область", "місто "):
        name = name.replace(affix, "")
    return name.strip()


def build():
    gn_names = _geonames_names()
    katotth = _tsv("katotth.tsv")

    # --- regions -------------------------------------------------------------
    regions = {}
    admin1 = _tsv("geonames-admin1.tsv")
    ua_admin1 = {}  # GeoNames "UA.12" -> KATOTTH level-1 code
    k_level1 = {r["level1"]: r for r in katotth if r["category"] in ("O", "K") and not r["level2"]}

    for a in admin1:
        country = a["code"].split(".")[0]
        names = gn_names.get(int(a["geonameid"]), {})
        if country == "UA":
            # "Черкаська область", "Місто Київ" → the KATOTTH level-1 name.
            uk_names = {_bare_region(n) for n in names.get("uk", [])}
            for code, k in k_level1.items():
                if k["name"].lower() in uk_names:
                    ua_admin1[a["code"]] = code
            continue
        localized = _localized(a["name"], names)
        regions[a["code"]] = {
            "code": a["code"],
            "country": country,
            "names": _compact(localized),
            "alt_names": _alt([a["asciiname"], a["name"]], _names_for_search(names)),
        }

    gn_for_level1 = {v: k for k, v in ua_admin1.items()}
    for code, k in k_level1.items():
        uk = k["name"] if k["category"] == "K" or k["name"].startswith("Автономна") else f"{k['name']} область"
        names = gn_names.get(int(next((a["geonameid"] for a in admin1 if a["code"] == gn_for_level1.get(code)), 0)), {})
        localized = _localized(transliterate(uk).replace(" Oblast", "").replace("oblast", "Oblast"), names)
        localized["uk"] = uk
        regions[code] = {
            "code": code,
            "country": "UA",
            "names": _compact(localized),
            "alt_names": _alt([transliterate(uk)], _names_for_search(names)),
        }

    # --- places --------------------------------------------------------------
    places = {}
    raion = {r["level2"]: r["name"] for r in katotth if r["category"] == "P" and not r["level3"]}
    kinds = {"M": "city", "K": "city", "X": "settlement", "C": "village"}
    weights = {"K": 1_000_000, "M": 5_000, "X": 1_000, "C": 100}

    ua_by_name = defaultdict(list)  # (level1, uk name) -> KATOTTH rows
    ua_by_latin = defaultdict(list)  # (level1, transliterated name) -> rows
    for r in katotth:
        if r["category"] in kinds:
            ua_by_name[(r["level1"], r["name"])].append(r)
            ua_by_latin[(r["level1"], _latin_key(transliterate(r["name"])))].append(r)

    def district(r):
        """The raion, as shown before the region: {"uk": "… р-н", "en": "… Raion"}."""
        name = raion.get(r["level2"])
        if not name or r["category"] == "K":
            return None
        return {"en": f"{transliterate(name)} Raion", "uk": f"{name} р-н"}

    matched = {}  # KATOTTH code -> GeoNames city row
    unmatched_ua = []
    cities = _tsv("geonames-cities15000.tsv")
    for c in cities:
        if c["country"] != "UA":
            continue
        level1 = ua_admin1.get(f"UA.{c['admin1']}")
        names = gn_names.get(int(c["geonameid"]), {})
        candidates = [
            r for n in names.get("uk", []) for r in ua_by_name.get((level1, n), [])
        ] or ua_by_latin.get((level1, _latin_key(c["asciiname"])), [])
        # Prefer cities over villages of the same name; one match only.
        best = sorted({r["level4"] or r["level1"]: r for r in candidates}.values(),
                      key=lambda r: "KMXC".index(r["category"]))
        if best and best[0]["category"] in "KM" or len(best) == 1:
            matched[best[0]["level4"] or best[0]["level1"]] = c
        elif c["feature"] != "PPLX":
            # PPLX: a neighbourhood or district of a city, not a place of
            # birth on its own; KATOTTH has the city itself.
            unmatched_ua.append(c)

    for r in katotth:
        if r["category"] not in kinds or (r["category"] == "K" and r["level2"]):
            continue
        code = r["level4"] or r["level1"]
        uk = r["name"]
        latin = transliterate(uk)
        gn = matched.get(code)
        names = gn_names.get(int(gn["geonameid"]), {}) if gn else {}
        localized = _localized(names.get("en", [latin])[0] if gn else latin, names)
        localized["uk"] = uk
        entry = {
            "code": code,
            "kind": kinds[r["category"]],
            "country": "UA",
            "region": r["level1"],
            "names": _compact(localized),
            "district": district(r),
            "alt_names": _alt([latin], _names_for_search(names)),
            "weight": int(gn["population"]) if gn else weights[r["category"]],
        }
        if entry["district"] is None:
            del entry["district"]
        if gn:
            entry["geonameid"] = gn["geonameid"]
            entry["population"] = int(gn["population"])
        places[code] = entry

    for c in cities:
        if c["country"] == "UA" and c not in unmatched_ua:
            continue
        gid = int(c["geonameid"])
        names = gn_names.get(gid, {})
        localized = _localized(c["name"], names)
        region_code = ua_admin1.get(f"UA.{c['admin1']}") if c["country"] == "UA" else f"{c['country']}.{c['admin1']}"
        region = regions.get(region_code)
        places[str(gid)] = {
            "code": str(gid),
            "kind": "city",
            "country": c["country"],
            "region": region_code if region else None,
            "names": _compact(localized),
            "alt_names": _alt([c["name"], c["asciiname"]], _names_for_search(names)),
            "weight": int(c["population"]),
            "population": int(c["population"]),
        }

    stats = {"ua_matched": len(matched), "ua_unmatched_geonames_kept": len(unmatched_ua)}
    return list(regions.values()), list(places.values()), stats
