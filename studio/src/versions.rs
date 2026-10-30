//! Each file's versions, in memory: the text it had when it was opened,
//! saved, changed by an accepted proposal, changed on disk, or restored.
//! Restoring is a new version, never a rewrite of history (docs/STUDIO.md
//! §4). A version names the forms that differ from the one before, as
//! `file:key` (sexp.rs), so the history can say what changed.

use crate::sexp;
use serde::Serialize;
use std::collections::BTreeMap;

#[derive(Clone, Debug, Serialize)]
pub struct Version {
    /// 1, 2, 3, … across every file, in the order versions were made.
    pub id: u64,
    pub file: String,
    #[serde(skip)]
    pub text: String,
    /// "open", "save", "accept", "disk", "restore".
    pub origin: &'static str,
    pub label: String,
    /// Milliseconds since the epoch.
    pub created: u64,
    pub forms_changed: Vec<String>,
}

/// How many versions a file keeps.
const KEPT: usize = 200;

#[derive(Default)]
pub struct History {
    next: u64,
    files: BTreeMap<String, Vec<Version>>,
}

impl History {
    /// Record `text` as `file`'s newest version, unless it is the newest
    /// already. Returns the version made.
    pub fn record(&mut self, file: &str, text: &str, origin: &'static str, label: &str) -> Option<Version> {
        let list = self.files.entry(file.to_owned()).or_default();
        let previous = list.last().map(|version| version.text.as_str());
        if previous == Some(text) {
            return None;
        }
        self.next += 1;
        let version = Version {
            id: self.next,
            file: file.to_owned(),
            text: text.to_owned(),
            origin,
            label: label.to_owned(),
            created: crate::review::now(),
            forms_changed: changed_forms(file, previous.unwrap_or(""), text),
        };
        list.push(version.clone());
        if list.len() > KEPT {
            list.remove(0);
        }
        Some(version)
    }

    /// `file`'s versions, oldest first.
    pub fn of(&self, file: &str) -> Vec<Version> {
        self.files.get(file).cloned().unwrap_or_default()
    }

    pub fn get(&self, id: u64) -> Option<&Version> {
        self.files.values().flatten().find(|version| version.id == id)
    }
}

/// `file:key` of each form that `after` adds, removes, or changes.
pub fn changed_forms(file: &str, before: &str, after: &str) -> Vec<String> {
    let texts = |text: &str| -> BTreeMap<String, String> {
        sexp::forms(text).into_iter().map(|form| (form.key(), text[form.start..form.end].to_owned())).collect()
    };
    let (old, new) = (texts(before), texts(after));
    let mut keys: Vec<String> = old.keys().chain(new.keys()).filter(|key| old.get(*key) != new.get(*key)).cloned().collect();
    keys.dedup();
    keys.sort();
    keys.dedup();
    keys.into_iter().map(|key| format!("{file}:{key}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_record_changes_only_and_name_their_forms() {
        let mut history = History::default();
        let first = history.record("main.puf", "(define (f x) x)\n", "open", "").unwrap();
        assert!(history.record("main.puf", "(define (f x) x)\n", "save", "").is_none());
        let second = history.record("main.puf", "(define (f x) (+ x 1))\n(define y 2)\n", "accept", "#3").unwrap();
        assert_eq!(second.forms_changed, ["main.puf:define:f", "main.puf:define:y"]);
        assert_eq!(history.of("main.puf").len(), 2);
        assert_eq!(history.get(first.id).unwrap().text, "(define (f x) x)\n");
    }
}
