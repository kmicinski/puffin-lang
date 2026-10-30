//! What the compiler marks in the text besides its diagnostics, kept per
//! file and shown to every tab:
//!
//! - typed holes (docs/STUDIO.md §5 item 6): each `??` of a module, with
//!   the goal type `--assist facts` gives at it. Outside assists `??` is an
//!   unbound name, so the check stops at the first hole and reports it as a
//!   hole (toolchain.rs); the holes after it are found by scanning;
//! - the observation lint (§3.1): each match with no catch-all whose
//!   parameter the live session saw take a shape no clause handles, from
//!   `--assist lint FILE --observed OBS`. It is run for the edited modules
//!   after each check, and for every module when the observation record
//!   changes; with no record there is nothing to lint.
//!
//! Offsets go to tabs as UTF-16 offsets (what the editor counts), with the
//! byte offset as `pos`, and each set carries the file's version it was
//! made for.

use crate::sexp;
use crate::studio::{Event, Studio, checkable};
use crate::toolchain::Files;
use serde::Serialize;
use serde_json::Value;
use std::collections::BTreeMap;

/// Goals asked of the compiler for one file, at most.
const GOALS_ASKED: usize = 32;

/// One `??`: its span (UTF-16 offsets), its byte offset, its line, and its
/// goal type when the compiler gives one.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Hole {
    pub start: usize,
    pub end: usize,
    pub pos: usize,
    pub line: usize,
    pub goal: Option<String>,
}

/// One lint finding: the match's span (UTF-16 offsets), its byte offset,
/// its line, and what was seen.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Finding {
    pub start: usize,
    pub end: usize,
    pub pos: usize,
    pub line: usize,
    pub source: String,
    pub message: String,
}

/// What is marked in one file, for its `version`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Marks<T> {
    pub version: u64,
    pub items: Vec<T>,
}

impl<T> Default for Marks<T> {
    fn default() -> Self {
        Marks { version: 0, items: Vec::new() }
    }
}

/// The holes of `text`, without goals.
pub fn holes_of(text: &str) -> Vec<Hole> {
    sexp::holes(text)
        .into_iter()
        .map(|(start, end)| Hole {
            start: sexp::utf16_of_byte(text, start),
            end: sexp::utf16_of_byte(text, end),
            pos: start,
            line: sexp::line_of(text, start),
            goal: None,
        })
        .collect()
}

/// A lint line as a finding in `text`.
pub fn finding(text: &str, value: &Value) -> Option<Finding> {
    let pos = value["start"].as_u64()? as usize;
    let end = value["end"].as_u64().map_or(pos, |end| end as usize);
    Some(Finding {
        start: sexp::utf16_of_byte(text, pos),
        end: sexp::utf16_of_byte(text, end),
        pos,
        line: value["line"].as_u64().map_or_else(|| sexp::line_of(text, pos), |line| line as usize),
        source: value["source"].as_str().unwrap_or("observed").to_owned(),
        message: value["message"].as_str()?.to_owned(),
    })
}

impl Studio {
    /// The holes of `file` in `files`, each with its goal.
    pub async fn goals(&self, files: &Files, file: &str) -> Vec<Hole> {
        let Some(text) = files.get(file) else { return Vec::new() };
        let mut holes = holes_of(text);
        if !self.toolchain.facts_available().await {
            return holes;
        }
        for hole in holes.iter_mut().take(GOALS_ASKED) {
            if let Ok(answer) = self.toolchain.assist(files, "facts", file, Some(hole.pos)).await {
                hole.goal = answer["goal"].as_str().map(str::to_owned);
            }
        }
        holes
    }

    /// Find each module's holes again, with their goals, and show the ones
    /// that changed.
    pub(crate) async fn refresh_holes(&self, program: &Files) {
        let known: Vec<String> = self.holes.lock().expect("holes lock").keys().cloned().collect();
        for file in program.keys().filter(|file| checkable(file)) {
            let text = &program[file];
            if sexp::holes(text).is_empty() && !known.contains(file) {
                continue;
            }
            let version = self.version_of(file).unwrap_or(0);
            let items = self.goals(program, file).await;
            let marks = Marks { version, items };
            let changed = {
                let mut holes = self.holes.lock().expect("holes lock");
                let changed = holes.get(file) != Some(&marks);
                if marks.items.is_empty() {
                    holes.remove(file);
                } else {
                    holes.insert(file.clone(), marks.clone());
                }
                changed
            };
            if changed {
                self.publish(Event::Holes { file: file.clone(), holes: marks });
            }
        }
        // a file that went keeps no holes
        let gone: Vec<String> = known.into_iter().filter(|file| !program.contains_key(file)).collect();
        for file in gone {
            self.holes.lock().expect("holes lock").remove(&file);
        }
    }

    /// Every hole of the program as `files` holds it: (file, hole).
    pub async fn all_holes(&self, files: &Files) -> Vec<(String, Hole)> {
        let mut out = Vec::new();
        for file in files.keys().filter(|file| checkable(file) && !sexp::holes(&files[*file]).is_empty()) {
            for hole in self.goals(files, file).await {
                out.push((file.clone(), hole));
            }
        }
        out
    }

    /// Lint `targets` (every module when None) against the session's
    /// observations, and show the findings that changed.
    pub(crate) async fn refresh_lint(&self, targets: Option<&[String]>) {
        let program = self.files();
        let observed = self.toolchain.observed.lock().expect("observed lock").clone().is_some_and(|path| path.is_file());
        let files: Vec<String> = match targets {
            Some(targets) => targets.iter().filter(|file| program.contains_key(*file)).cloned().collect(),
            None => program.keys().cloned().collect(),
        };
        if !observed || !self.toolchain.lint_available().await {
            return self.clear_lint();
        }
        for file in files.iter().filter(|file| checkable(file)) {
            let version = self.version_of(file).unwrap_or(0);
            let items = self.lint_of(&program, file).await;
            self.keep_lint(file, Marks { version, items });
        }
    }

    /// The lint findings of `file` in `files`; what was printed before an
    /// error stopped it stands.
    pub async fn lint_of(&self, files: &Files, file: &str) -> Vec<Finding> {
        let Some(text) = files.get(file) else { return Vec::new() };
        match self.toolchain.assist_with(files, "lint", file, Vec::new()).await {
            Ok(answer) => answer["findings"].as_array().into_iter().flatten().filter_map(|value| finding(text, value)).collect(),
            Err(_) => Vec::new(),
        }
    }

    fn keep_lint(&self, file: &str, marks: Marks<Finding>) {
        let changed = {
            let mut lint = self.lint.lock().expect("lint lock");
            let before = lint.get(file).cloned().unwrap_or_default();
            let changed = before.items != marks.items || (!marks.items.is_empty() && before.version != marks.version);
            if marks.items.is_empty() {
                lint.remove(file);
            } else {
                lint.insert(file.to_owned(), marks.clone());
            }
            changed
        };
        if changed {
            self.publish(Event::Lint { file: file.to_owned(), lint: marks });
        }
    }

    /// Forget every finding: the session's record is gone.
    pub(crate) fn clear_lint(&self) {
        let files: Vec<String> = std::mem::take(&mut *self.lint.lock().expect("lint lock")).into_keys().collect();
        for file in files {
            self.publish(Event::Lint { file, lint: Marks::default() });
        }
    }

    /// Every file's findings, as kept.
    pub fn lint_view(&self) -> BTreeMap<String, Marks<Finding>> {
        self.lint.lock().expect("lint lock").clone()
    }

    /// Every file's holes, as kept.
    pub fn holes_view(&self) -> BTreeMap<String, Marks<Hole>> {
        self.holes.lock().expect("holes lock").clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn holes_and_findings_carry_both_offsets() {
        let text = "; λ\n(define (f [e : Int]) : Int\n  (+ ?? ??))\n";
        let holes = holes_of(text);
        assert_eq!(holes.len(), 2);
        assert_eq!((holes[0].line, holes[0].end - holes[0].start), (3, 2));
        // λ is two bytes and one UTF-16 unit
        assert_eq!(holes[0].pos, holes[0].start + 1);
        let line = serde_json::json!({ "start": 4, "end": 10, "line": 2, "source": "observed", "message": "e was seen as Str" });
        let found = finding(text, &line).unwrap();
        assert_eq!((found.start, found.pos, found.line, found.message.as_str()), (3, 4, 2, "e was seen as Str"));
        assert!(finding(text, &serde_json::json!({ "done": true })).is_none());
    }
}
