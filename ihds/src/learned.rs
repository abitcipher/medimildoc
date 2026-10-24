//! Learned values: organisational names users have entered before
//! (issuing authorities, vetting authorities), offered as suggestions.
//!
//! Stored append-only in `<data dir>/learned.jsonl`, one
//! `{"category", "value", "at"}` line per save — a bare value, never who
//! entered it or for whom. At start the file is replayed into counts; the
//! most recent spelling of a value is the one shown. Kept apart from the
//! curated seed data (docs/design/reference-data-and-files.md).

use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

const FILE: &str = "learned.jsonl";
pub const MAX_VALUE_CHARS: usize = 200;

#[derive(Serialize, Deserialize)]
struct Line {
    category: String,
    value: String,
    at: u64,
}

struct Known {
    value: String,
    count: u64,
}

pub struct Learned {
    path: Option<PathBuf>,
    /// category → normalized value → most recent spelling and count
    values: Mutex<HashMap<String, HashMap<String, Known>>>,
}

/// Categories are short snake_case names chosen by the app.
pub fn valid_category(category: &str) -> bool {
    !category.is_empty()
        && category.len() <= 40
        && category.chars().all(|c| c.is_ascii_lowercase() || c == '_')
}

/// Trimmed, inner whitespace collapsed; `None` if empty or too long.
pub fn clean_value(value: &str) -> Option<String> {
    let cleaned = value.split_whitespace().collect::<Vec<_>>().join(" ");
    let chars = cleaned.chars().count();
    (chars > 0 && chars <= MAX_VALUE_CHARS).then_some(cleaned)
}

fn key(value: &str) -> String {
    value.to_lowercase()
}

impl Learned {
    /// Loads `<dir>/learned.jsonl` (created on first write). `None` keeps
    /// everything in memory only (tests).
    pub fn open(dir: Option<PathBuf>) -> Result<Learned, String> {
        let learned = Learned {
            path: dir.map(|d| d.join(FILE)),
            values: Mutex::new(HashMap::new()),
        };
        if let Some(path) = &learned.path {
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
            }
            if path.exists() {
                let file = File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
                for line in BufReader::new(file).lines().map_while(Result::ok) {
                    // A torn last line (crash mid-write) is skipped, not fatal.
                    if let Ok(entry) = serde_json::from_str::<Line>(&line) {
                        learned.remember(&entry.category, &entry.value);
                    }
                }
            }
        }
        Ok(learned)
    }

    fn remember(&self, category: &str, value: &str) {
        let mut values = self.values.lock().expect("learned values lock");
        let known = values
            .entry(category.to_string())
            .or_default()
            .entry(key(value))
            .or_insert(Known {
                value: value.to_string(),
                count: 0,
            });
        known.value = value.to_string();
        known.count += 1;
    }

    /// Records one use of `value` in `category`.
    pub fn add(&self, category: &str, value: &str) -> Result<(), String> {
        if let Some(path) = &self.path {
            let at = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let line = serde_json::to_string(&Line {
                category: category.into(),
                value: value.into(),
                at,
            })
            .map_err(|e| e.to_string())?;
            let mut file = OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
                .map_err(|e| format!("{}: {e}", path.display()))?;
            writeln!(file, "{line}").map_err(|e| e.to_string())?;
        }
        self.remember(category, value);
        Ok(())
    }

    /// Values of `category` matching `query` (every query word starts a
    /// word of the value, case-insensitive): values starting with the
    /// query first, then by how often they were entered.
    pub fn search(&self, category: &str, query: &str, limit: usize) -> Vec<Value> {
        let needle = key(query.trim());
        let words: Vec<&str> = needle.split_whitespace().collect();
        let values = self.values.lock().expect("learned values lock");
        let Some(known) = values.get(category) else {
            return Vec::new();
        };
        let mut found: Vec<(bool, u64, &Known)> = known
            .iter()
            .filter(|(k, _)| {
                let value_words: Vec<&str> = k.split(|c: char| !c.is_alphanumeric()).collect();
                words
                    .iter()
                    .all(|w| value_words.iter().any(|v| v.starts_with(w)))
            })
            .map(|(k, v)| (!k.starts_with(&needle), u64::MAX - v.count, v))
            .collect();
        found.sort_by(|a, b| (a.0, a.1, &a.2.value).cmp(&(b.0, b.1, &b.2.value)));
        found
            .into_iter()
            .take(limit)
            .map(|(_, _, k)| json!({"value": k.value, "count": k.count}))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_and_ranks() {
        let l = Learned::open(None).unwrap();
        for v in [
            "State Migration Service",
            "State Migration Service",
            "Ministry of Defence",
        ] {
            l.add("issuing_authority", v).unwrap();
        }
        l.add("issuing_authority", "Stadtverwaltung Berlin")
            .unwrap();
        let found = l.search("issuing_authority", "st", 10);
        assert_eq!(found[0]["value"], "State Migration Service");
        assert_eq!(found[0]["count"], 2);
        assert_eq!(found.len(), 2);
        assert_eq!(l.search("issuing_authority", "migr serv", 10).len(), 1);
        assert!(l.search("vetting_authority", "st", 10).is_empty());
    }

    #[test]
    fn survives_restart_and_skips_a_torn_line() {
        let dir = std::env::temp_dir().join(format!("ihds-learned-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        {
            let l = Learned::open(Some(dir.clone())).unwrap();
            l.add("issuing_authority", "ДМС України").unwrap();
            l.add("issuing_authority", "дмс україни").unwrap();
        }
        let mut file = OpenOptions::new()
            .append(true)
            .open(dir.join(FILE))
            .unwrap();
        write!(file, r#"{{"category": "issuing_auth"#).unwrap();

        let l = Learned::open(Some(dir.clone())).unwrap();
        let found = l.search("issuing_authority", "дмс", 10);
        assert_eq!(found[0]["value"], "дмс україни");
        assert_eq!(found[0]["count"], 2);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn cleans_values_and_checks_categories() {
        assert_eq!(
            clean_value("  State   Migration\nService "),
            Some("State Migration Service".into())
        );
        assert_eq!(clean_value("   "), None);
        assert_eq!(clean_value(&"x".repeat(201)), None);
        assert!(valid_category("vetting_authority"));
        assert!(!valid_category("Vetting-Authority"));
        assert!(!valid_category("../etc"));
    }
}
