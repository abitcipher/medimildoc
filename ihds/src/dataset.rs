//! Seed loading and the per-dataset Tantivy index.

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::Path;

use serde::Deserialize;
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use tantivy::Order;
use tantivy::collector::TopDocs;
use tantivy::query::{BooleanQuery, Occur, Query, TermQuery};
use tantivy::schema::{
    FAST, Field, IndexRecordOption, STORED, STRING, Schema, TextFieldIndexing, TextOptions,
    Value as _,
};
use tantivy::tokenizer::{
    AsciiFoldingFilter, LowerCaser, NgramTokenizer, SimpleTokenizer, TextAnalyzer, TokenStream,
};
use tantivy::{Index, IndexReader, TantivyDocument, Term, doc};

/// Longest prefix that is indexed; longer query words are cut to it.
const MAX_PREFIX: usize = 20;
const PREFIX_TOKENIZER: &str = "ihds_prefix";
/// Candidates fetched from the index before ranking in code.
const CANDIDATES: usize = 500;

/// Language used when an entry has no name in the requested one.
pub const FALLBACK_LANG: &str = "en";

#[derive(Deserialize)]
struct SeedFile {
    dataset: String,
    #[serde(default)]
    description: String,
    entries: Vec<Map<String, Value>>,
}

pub struct Dataset {
    pub name: String,
    pub description: String,
    /// SHA-256 of the seed file bytes: the data version Phoenix sees.
    pub version: String,
    entries: Vec<Map<String, Value>>,
    by_code: HashMap<String, usize>,
    reader: IndexReader,
    code_field: Field,
    prefix_field: Field,
    country_field: Field,
    /// Whether entries carry a `weight` (population and the like): then
    /// search candidates are taken by weight, not by text score.
    weighted: bool,
}

/// All datasets, keyed by name.
pub struct Catalog {
    pub datasets: BTreeMap<String, Dataset>,
    /// SHA-256 over every dataset version, in name order.
    pub version: String,
}

impl Catalog {
    /// Loads every `*.json` file directly inside `dir` (subdirectories,
    /// such as the raw `sources/`, are skipped).
    pub fn load_dir(dir: &Path) -> Result<Catalog, String> {
        let mut paths: Vec<_> = fs::read_dir(dir)
            .map_err(|e| format!("{}: {e}", dir.display()))?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.is_file() && p.extension().is_some_and(|x| x == "json"))
            .collect();
        paths.sort();

        let mut datasets = BTreeMap::new();
        for path in paths {
            let bytes = fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?;
            let dataset =
                Dataset::from_seed(&bytes).map_err(|e| format!("{}: {e}", path.display()))?;
            if datasets.contains_key(&dataset.name) {
                return Err(format!(
                    "{}: duplicate dataset {}",
                    path.display(),
                    dataset.name
                ));
            }
            datasets.insert(dataset.name.clone(), dataset);
        }

        let mut hasher = Sha256::new();
        for d in datasets.values() {
            hasher.update(d.name.as_bytes());
            hasher.update(d.version.as_bytes());
        }
        Ok(Catalog {
            datasets,
            version: hex(&hasher.finalize()),
        })
    }
}

impl Catalog {
    /// Adds `context_label` to an entry that names a `region` (a code in
    /// the regions dataset) and/or a `district` (names by language):
    /// "Bakhchysaraiskyi Raion, Autonomous Republic of Crimea".
    pub fn with_context(&self, mut entry: Value, lang: &str) -> Value {
        let region = entry
            .get("region")
            .and_then(Value::as_str)
            .and_then(|code| self.datasets.get("regions")?.get(code, lang))
            .and_then(|r| r.get("label").and_then(Value::as_str).map(String::from));
        let district = entry
            .get("district")
            .and_then(Value::as_object)
            .and_then(|d| d.get(lang).or_else(|| d.get(FALLBACK_LANG)))
            .and_then(Value::as_str)
            .map(String::from);
        // Kyiv's region is Kyiv: don't repeat the place's own name.
        let own = entry
            .get("label")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let parts: Vec<String> = [district, region]
            .into_iter()
            .flatten()
            .filter(|p| !p.is_empty() && p != own)
            .collect();
        if let (false, Some(map)) = (parts.is_empty(), entry.as_object_mut()) {
            map.insert("context_label".into(), Value::String(parts.join(", ")));
        }
        entry
    }
}

impl Dataset {
    pub fn from_seed(bytes: &[u8]) -> Result<Dataset, String> {
        let seed: SeedFile = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
        let version = hex(&Sha256::digest(bytes));

        let mut by_code = HashMap::new();
        for (i, entry) in seed.entries.iter().enumerate() {
            let code =
                entry_code(entry).ok_or_else(|| format!("entry {i} has no string `code`"))?;
            if by_code.insert(code.to_string(), i).is_some() {
                return Err(format!("duplicate code {code}"));
            }
        }

        let mut schema = Schema::builder();
        let code_field = schema.add_text_field("code", STRING | STORED);
        let country_field = schema.add_text_field("country", STRING);
        let weight_field = schema.add_u64_field("weight", FAST);
        let prefix_field = schema.add_text_field(
            "prefix",
            TextOptions::default().set_indexing_options(
                TextFieldIndexing::default()
                    .set_tokenizer(PREFIX_TOKENIZER)
                    .set_index_option(IndexRecordOption::Basic),
            ),
        );
        let index = Index::create_in_ram(schema.build());
        index
            .tokenizers()
            .register(PREFIX_TOKENIZER, prefix_analyzer());

        let mut writer = index.writer(15_000_000).map_err(|e| e.to_string())?;
        for entry in &seed.entries {
            let mut document = doc!(
                code_field => entry_code(entry).unwrap_or_default(),
                weight_field => weight(entry),
            );
            if let Some(country) = entry.get("country").and_then(Value::as_str) {
                document.add_text(country_field, country);
            }
            for word in search_words(entry) {
                document.add_text(prefix_field, word);
            }
            writer.add_document(document).map_err(|e| e.to_string())?;
        }
        writer.commit().map_err(|e| e.to_string())?;
        let reader = index.reader().map_err(|e| e.to_string())?;
        let weighted = seed.entries.iter().any(|e| e.contains_key("weight"));

        Ok(Dataset {
            name: seed.dataset,
            description: seed.description,
            version,
            entries: seed.entries,
            by_code,
            reader,
            code_field,
            prefix_field,
            country_field,
            weighted,
        })
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// One entry by code (case-insensitive), with its `label` in `lang`.
    pub fn get(&self, code: &str, lang: &str) -> Option<Value> {
        let i = self
            .by_code
            .get(code)
            .or_else(|| self.by_code.get(&code.to_uppercase()))
            .or_else(|| self.by_code.get(&code.to_lowercase()))?;
        Some(labelled(&self.entries[*i], lang))
    }

    /// Every entry, sorted by its label in `lang`.
    pub fn list(&self, lang: &str) -> Vec<Value> {
        let mut all: Vec<Value> = self.entries.iter().map(|e| labelled(e, lang)).collect();
        all.sort_by_key(|e| sort_key(label_of(e)));
        all
    }

    /// Search-as-you-type: every query word must be a prefix of some word
    /// of the entry (names in any language, alternative names, codes).
    /// Ranked: exact code or alternative name; the name in the requested
    /// language or in English starting with the query; any other name
    /// starting with it; a name containing it; other matches.
    /// Ties: heavier (more populous) first, then by label.
    pub fn search(
        &self,
        query: &str,
        lang: &str,
        limit: usize,
        country: Option<&str>,
    ) -> Vec<Value> {
        let words = query_words(query);
        if words.is_empty() {
            return Vec::new();
        }
        let mut clauses: Vec<(Occur, Box<dyn Query>)> = words
            .iter()
            .map(|w| {
                let term = Term::from_field_text(self.prefix_field, &truncate(w, MAX_PREFIX));
                (
                    Occur::Must,
                    Box::new(TermQuery::new(term, IndexRecordOption::Basic)) as Box<dyn Query>,
                )
            })
            .collect();
        if let Some(country) = country.filter(|c| !c.is_empty()) {
            let term = Term::from_field_text(self.country_field, &country.to_uppercase());
            clauses.push((
                Occur::Must,
                Box::new(TermQuery::new(term, IndexRecordOption::Basic)),
            ));
        }
        let matching = BooleanQuery::new(clauses);

        // Big datasets (places): a short prefix matches thousands of
        // entries, so take the heaviest (most populous) candidates.
        let searcher = self.reader.searcher();
        let addresses: Vec<_> = if self.weighted {
            let collector =
                TopDocs::with_limit(CANDIDATES).order_by_fast_field::<u64>("weight", Order::Desc);
            match searcher.search(&matching, &collector) {
                Ok(hits) => hits.into_iter().map(|(_, a)| a).collect(),
                Err(_) => return Vec::new(),
            }
        } else {
            match searcher.search(&matching, &TopDocs::with_limit(CANDIDATES).order_by_score()) {
                Ok(hits) => hits.into_iter().map(|(_, a)| a).collect(),
                Err(_) => return Vec::new(),
            }
        };

        let needle = normalize(query.trim());
        let mut found: Vec<(u8, std::cmp::Reverse<u64>, String, Value)> = addresses
            .into_iter()
            .filter_map(|address| {
                let stored: TantivyDocument = searcher.doc(address).ok()?;
                let code = stored.get_first(self.code_field)?.as_str()?.to_string();
                let raw = &self.entries[*self.by_code.get(&code)?];
                let entry = labelled(raw, lang);
                // The name in the requested language and the English one:
                // people type either (Londrina, lacking a Ukrainian name,
                // must not beat Лондон/London for "lond").
                let primary: Vec<String> = [Some(label_of(&entry)), english_name(&entry)]
                    .into_iter()
                    .flatten()
                    .map(normalize)
                    .collect();
                let names: Vec<String> = all_names(&entry).map(normalize).collect();
                let rank = if exact_names(&entry).any(|n| normalize(n) == needle) {
                    0
                } else if primary.iter().any(|n| n.starts_with(&needle)) {
                    1
                } else if names.iter().any(|n| n.starts_with(&needle)) {
                    2
                } else if names.iter().any(|n| n.contains(&needle)) {
                    3
                } else {
                    4
                };
                Some((
                    rank,
                    std::cmp::Reverse(weight(raw)),
                    sort_key(label_of(&entry)),
                    entry,
                ))
            })
            .collect();
        found.sort_by(|a, b| (a.0, a.1, &a.2).cmp(&(b.0, b.1, &b.2)));
        found
            .into_iter()
            .take(limit)
            .map(|(_, _, _, e)| e)
            .collect()
    }
}

/// Ranking weight of an entry (population for places); 0 when absent.
fn weight(entry: &Map<String, Value>) -> u64 {
    entry.get("weight").and_then(Value::as_u64).unwrap_or(0)
}

fn entry_code(entry: &Map<String, Value>) -> Option<&str> {
    entry.get("code")?.as_str()
}

/// The entry plus `label`: its name in `lang`, else in English, else its code.
fn labelled(entry: &Map<String, Value>, lang: &str) -> Value {
    let names = entry.get("names").and_then(Value::as_object);
    let label = names
        .and_then(|n| n.get(lang).or_else(|| n.get(FALLBACK_LANG)))
        .and_then(Value::as_str)
        .or_else(|| entry_code(entry))
        .unwrap_or_default()
        .to_string();
    let mut out = entry.clone();
    out.insert("label".into(), Value::String(label));
    Value::Object(out)
}

fn english_name(entry: &Value) -> Option<&str> {
    entry.get("names")?.get(FALLBACK_LANG)?.as_str()
}

/// The label, names in every language and alternative names.
fn all_names(entry: &Value) -> impl Iterator<Item = &str> {
    let label = std::iter::once(label_of(entry));
    let names = entry
        .get("names")
        .and_then(Value::as_object)
        .into_iter()
        .flat_map(|m| m.values())
        .filter_map(Value::as_str);
    let alt = entry
        .get("alt_names")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str);
    label.chain(names).chain(alt)
}

/// Codes and alternative names: typing one of them exactly ("UA", "UKR",
/// "UK") puts that entry first.
fn exact_names(entry: &Value) -> impl Iterator<Item = &str> {
    let codes = ["code", "alpha3"]
        .into_iter()
        .filter_map(|k| entry.get(k).and_then(Value::as_str));
    let alt = entry
        .get("alt_names")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str);
    codes.chain(alt)
}

fn label_of(entry: &Value) -> &str {
    entry
        .get("label")
        .and_then(Value::as_str)
        .unwrap_or_default()
}

fn sort_key(label: &str) -> String {
    normalize(label)
}

/// Every searchable word of an entry: code, alternative codes, names in
/// all languages, alternative names.
fn search_words(entry: &Map<String, Value>) -> Vec<String> {
    let mut texts: Vec<&str> = Vec::new();
    for key in ["code", "alpha3", "numeric", "official_name"] {
        if let Some(s) = entry.get(key).and_then(Value::as_str) {
            texts.push(s);
        }
    }
    if let Some(names) = entry.get("names").and_then(Value::as_object) {
        texts.extend(names.values().filter_map(Value::as_str));
    }
    if let Some(alt) = entry.get("alt_names").and_then(Value::as_array) {
        texts.extend(alt.iter().filter_map(Value::as_str));
    }
    let mut words: Vec<String> = texts.iter().flat_map(|t| split_words(t)).collect();
    words.sort();
    words.dedup();
    words
}

/// Words of a text, lowercased and ASCII-folded (é → e; Cyrillic kept).
fn query_words(text: &str) -> Vec<String> {
    split_words(text)
        .into_iter()
        .map(|w| normalize(&w))
        .collect()
}

fn split_words(text: &str) -> Vec<String> {
    let mut analyzer = TextAnalyzer::from(SimpleTokenizer::default());
    let mut stream = analyzer.token_stream(text);
    let mut words = Vec::new();
    while stream.advance() {
        words.push(stream.token().text.clone());
    }
    words
}

fn normalize(text: &str) -> String {
    let mut analyzer = TextAnalyzer::builder(tantivy::tokenizer::RawTokenizer::default())
        .filter(LowerCaser)
        .filter(AsciiFoldingFilter)
        .build();
    let mut stream = analyzer.token_stream(text);
    let mut out = String::new();
    while stream.advance() {
        out.push_str(&stream.token().text);
    }
    out
}

/// Edge n-grams of each (already split) word, lowercased and folded, so
/// that a term query on a query word is a prefix match.
fn prefix_analyzer() -> TextAnalyzer {
    TextAnalyzer::builder(NgramTokenizer::prefix_only(1, MAX_PREFIX).expect("valid ngram bounds"))
        .filter(LowerCaser)
        .filter(AsciiFoldingFilter)
        .build()
}

fn truncate(word: &str, max_chars: usize) -> String {
    word.chars().take(max_chars).collect()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seed() -> Dataset {
        let json = serde_json::json!({
            "dataset": "countries",
            "entries": [
                {"code": "UA", "alpha3": "UKR", "names": {"en": "Ukraine", "uk": "Україна", "fr": "Ukraine"}, "alt_names": ["Ukrayina"]},
                {"code": "GB", "alpha3": "GBR", "names": {"en": "United Kingdom", "uk": "Велика Британія"}, "alt_names": ["Great Britain", "UK"]},
                {"code": "US", "alpha3": "USA", "names": {"en": "United States", "uk": "Сполучені Штати"}},
                {"code": "CI", "alpha3": "CIV", "names": {"en": "Côte d’Ivoire", "uk": "Кот-дʼІвуар"}},
                {"code": "DE", "alpha3": "DEU", "names": {"en": "Germany", "uk": "Німеччина", "fr": "Allemagne"}}
            ]
        });
        Dataset::from_seed(json.to_string().as_bytes()).unwrap()
    }

    fn codes(found: Vec<Value>) -> Vec<String> {
        found
            .iter()
            .map(|e| e["code"].as_str().unwrap().to_string())
            .collect()
    }

    #[test]
    fn prefix_search_in_any_language() {
        let d = seed();
        assert_eq!(codes(d.search("укр", "uk", 10, None)), ["UA"]);
        assert_eq!(codes(d.search("allem", "en", 10, None)), ["DE"]);
        assert_eq!(codes(d.search("united", "en", 10, None)), ["GB", "US"]);
        assert_eq!(codes(d.search("united st", "en", 10, None)), ["US"]);
        assert_eq!(codes(d.search("great brit", "en", 10, None)), ["GB"]);
    }

    #[test]
    fn accents_and_case_are_ignored() {
        assert_eq!(codes(seed().search("COTE", "en", 10, None)), ["CI"]);
    }

    #[test]
    fn exact_code_ranks_first() {
        let d = seed();
        assert_eq!(codes(d.search("uk", "en", 10, None))[0], "GB");
        assert_eq!(codes(d.search("ua", "en", 10, None)), ["UA"]);
        assert_eq!(codes(d.search("ukr", "en", 10, None)), ["UA"]);
    }

    #[test]
    fn labels_follow_the_language_with_english_fallback() {
        let d = seed();
        assert_eq!(d.get("ua", "uk").unwrap()["label"], "Україна");
        assert_eq!(d.get("GB", "fr").unwrap()["label"], "United Kingdom");
        assert!(d.get("XX", "en").is_none());
    }

    #[test]
    fn list_is_sorted_by_label() {
        let labels: Vec<String> = seed()
            .list("en")
            .iter()
            .map(|e| e["label"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(
            labels,
            [
                "Côte d’Ivoire",
                "Germany",
                "Ukraine",
                "United Kingdom",
                "United States"
            ]
        );
    }

    #[test]
    fn same_seed_same_version() {
        assert_eq!(seed().version, seed().version);
        assert_eq!(seed().version.len(), 64);
    }

    #[test]
    fn rejects_duplicate_codes() {
        let json = r#"{"dataset":"x","entries":[{"code":"A"},{"code":"A"}]}"#;
        assert!(Dataset::from_seed(json.as_bytes()).is_err());
    }

    #[test]
    fn real_countries_seed_loads() {
        let catalog =
            Catalog::load_dir(Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/seed"))).unwrap();
        let countries = &catalog.datasets["countries"];
        assert!(countries.len() > 240);
        assert_eq!(countries.get("UA", "uk").unwrap()["label"], "Україна");
        assert_eq!(codes(countries.search("нім", "uk", 5, None))[0], "DE");

        let languages = &catalog.datasets["languages"];
        assert_eq!(languages.get("UK", "fr").unwrap()["label"], "ukrainien");
        assert_eq!(codes(languages.search("ukr", "en", 3, None))[0], "uk");

        let currencies = &catalog.datasets["currencies"];
        assert_eq!(currencies.get("uah", "en").unwrap()["symbol"], "₴");
        assert_eq!(codes(currencies.search("гривн", "uk", 3, None))[0], "UAH");

        // Places: the most populous match first; filtering by country;
        // context composed from raion and region.
        let places = &catalog.datasets["places"];
        assert_eq!(places.search("ки", "uk", 1, None)[0]["label"], "Київ");
        assert_eq!(places.search("paris", "en", 1, None)[0]["country"], "FR");
        assert_eq!(
            places.search("odes", "en", 1, Some("US"))[0]["country"],
            "US"
        );
        assert_eq!(
            places.search("odes", "en", 1, Some("ua"))[0]["label"],
            "Odesa"
        );
        let village = catalog.with_context(places.get("UA01020010010075540", "uk").unwrap(), "uk");
        assert_eq!(village["label"], "Андріївка");
        assert_eq!(
            village["context_label"],
            "Бахчисарайський р-н, Автономна Республіка Крим"
        );
        let paris = catalog.with_context(places.search("paris", "fr", 1, None).remove(0), "fr");
        assert_eq!(paris["context_label"], "Région Île-de-France");
    }
}
