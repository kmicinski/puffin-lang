//! Properties: the spec voice mode builds toward (docs/VOICE.md §4).
//!
//! The author states properties -- as tests, or in English for the builder
//! to write down -- and they live in `properties.puf`, each as a
//! `check-property` (random arguments from generators) or `check-example`
//! (one case), with the English it came from in a `;; @property NAME: ...`
//! comment above it. `prop.puf`, the harness, is the studio's: it is written
//! beside them whenever properties are run, so it always matches this
//! studio. Running them builds and runs `properties.puf` on the VM, and
//! each property's line of output (`#prop NAME ok N` / `#prop NAME fail
//! TRIAL ARGS`) becomes its status.

use crate::sexp;
use crate::studio::Studio;
use crate::toolchain::{self, Files, Ran};
use serde::Serialize;
use std::time::{Duration, Instant};

pub const PROPERTIES: &str = "properties.puf";
pub const HARNESS: &str = "prop.puf";
pub const HARNESS_TEXT: &str = include_str!("prop.puf");
const LIMIT: Duration = Duration::from_secs(30);

#[derive(Clone, Debug, Serialize)]
pub struct Property {
    pub name: String,
    /// The English it was stated in, if a `;; @property` comment says.
    pub statement: String,
    pub line: usize,
    /// "ok", "fail", "crashed", "open" (it reached a typed hole: the
    /// definition it needs is not written yet), "not-run", or "pending".
    pub status: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub detail: String,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct Results {
    pub properties: Vec<Property>,
    /// Why nothing ran, if nothing did (a compile error, a missing file).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub ms: u64,
}

impl Results {
    /// The properties that do not hold: an open one (waiting on a hole)
    /// is not failing, it is not decided yet.
    pub fn failing(&self) -> Vec<&Property> {
        self.properties.iter().filter(|p| p.status != "ok" && p.status != "open").collect()
    }

    /// One line a property, for the builder.
    pub fn describe(&self) -> String {
        if let Some(error) = &self.error {
            return format!("properties did not run: {error}");
        }
        if self.properties.is_empty() {
            return "no properties yet".to_owned();
        }
        self.properties
            .iter()
            .map(|p| {
                let detail = if p.detail.is_empty() { String::new() } else { format!(" — {}", p.detail) };
                format!("{} [{}] {}{detail}", p.name, p.status, p.statement)
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

/// The properties `text` declares, in order, not yet run.
pub fn declared(text: &str) -> Vec<Property> {
    let mut statement_of = std::collections::HashMap::new();
    for line in text.lines() {
        if let Some(rest) = line.trim_start().strip_prefix(";; @property") {
            if let Some((name, statement)) = rest.split_once(':') {
                statement_of.insert(name.trim().to_owned(), statement.trim().to_owned());
            }
        }
    }
    let mut out = Vec::new();
    for form in sexp::forms(text) {
        if !matches!(form.head.as_deref(), Some("check-property" | "check-example")) {
            continue;
        }
        // the name: the quoted symbol after the head
        let body = &text[form.start..form.end];
        let name = body
            .split_once('\'')
            .map(|(_, rest)| rest.split(|c: char| c.is_whitespace() || c == '(' || c == ')').next().unwrap_or("").to_owned())
            .unwrap_or_default();
        if name.is_empty() {
            continue;
        }
        out.push(Property {
            statement: statement_of.get(&name).cloned().unwrap_or_default(),
            name,
            line: form.line,
            status: "pending".to_owned(),
            detail: String::new(),
        });
    }
    out
}

/// `text` (properties.puf) with each property form run inside the
/// harness's prop-guard, so a crash or a hole ends only that property:
/// `(check-example 'n E)` -> `(prop-guard 'n (lambda () (check-example 'n E)))`.
/// Line numbers are kept (the wrapper adds no newline).
pub fn guarded(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 256);
    let mut at = 0;
    let names = declared(text);
    let mut named = names.iter();
    for form in sexp::forms(text) {
        if !matches!(form.head.as_deref(), Some("check-property" | "check-example")) {
            continue;
        }
        let Some(property) = named.next() else { break };
        out.push_str(&text[at..form.start]);
        out.push_str(&format!("(prop-guard '{} (lambda () ", property.name));
        out.push_str(&text[form.start..form.end]);
        out.push_str("))");
        at = form.end;
    }
    out.push_str(&text[at..]);
    out
}

/// The harness and a properties file with nothing in it yet, requiring
/// the program's modules (`requires`).
pub fn new_file(requires: &[String]) -> String {
    let mut text = String::from(
        ";; properties.puf -- what the program must do, checked on every change\n\
         ;; (Puffin Studio voice mode; prop.puf is the harness).\n\
         (require \"prop.puf\")\n",
    );
    for module in requires {
        text.push_str(&format!("(require \"{module}\")\n"));
    }
    text
}

/// Run the properties of `files`, with the studio's harness in place.
pub async fn run(studio: &Studio, files: &Files) -> Results {
    let started = Instant::now();
    let Some(text) = files.get(PROPERTIES) else {
        return Results::default();
    };
    let mut declared = declared(text);
    // every module's holes become stubs that raise "??", so a property
    // that needs an unwritten definition is open, not a compile error
    let mut files = toolchain::runnable(files);
    files.insert(PROPERTIES.to_owned(), guarded(&files[PROPERTIES]));
    files.insert(HARNESS.to_owned(), HARNESS_TEXT.to_owned());
    let ran = studio.toolchain.build_and_run(&files, PROPERTIES, LIMIT).await;
    let ms = || started.elapsed().as_millis() as u64;
    let output = match ran {
        Ran::Unbuilt(report) => return Results { properties: declared, error: Some(report.describe()), ms: ms() },
        Ran::Failed(error) => return Results { properties: declared, error: Some(error), ms: ms() },
        Ran::Ran(output) => output,
    };
    let mut started_last: Option<String> = None;
    for line in output.stdout.lines() {
        if let Some(name) = line.strip_prefix("#prop-start ") {
            started_last = Some(name.trim().to_owned());
            continue;
        }
        let Some(rest) = line.strip_prefix("#prop ") else { continue };
        let mut parts = rest.splitn(3, ' ');
        let (name, status, detail) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""), parts.next().unwrap_or(""));
        started_last = None;
        let detail = match status {
            "ok" => format!("{detail} trials"),
            "open" => "reaches a definition not written yet (??)".to_owned(),
            "crashed" => detail.to_owned(),
            _ => match detail.split_once(' ') {
                Some((trial, args)) => format!("counterexample {args} (trial {trial})"),
                None => detail.to_owned(),
            },
        };
        match declared.iter_mut().find(|p| p.name == name && p.status == "pending") {
            Some(property) => {
                property.status = status.to_owned();
                property.detail = detail;
            }
            None => declared.push(Property { name: name.to_owned(), statement: String::new(), line: 0, status: status.to_owned(), detail }),
        }
    }
    // a run that died: the property it was in crashed, the rest never ran
    if let Some(name) = started_last {
        let why = output.stderr.lines().rev().find(|line| !line.trim().is_empty()).unwrap_or("the run stopped").trim().to_owned();
        let why = if output.timed_out { "timed out".to_owned() } else { why };
        if let Some(property) = declared.iter_mut().find(|p| p.name == name && p.status == "pending") {
            property.status = "crashed".to_owned();
            property.detail = why;
        }
    }
    for property in declared.iter_mut().filter(|p| p.status == "pending") {
        property.status = "not-run".to_owned();
    }
    Results { properties: declared, error: None, ms: ms() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn properties_are_declared_with_their_english() {
        let text = "(require \"prop.puf\")\n;; @property rev: reversing twice is identity\n(check-property 'rev (for-all (list (gen-list gen-int)) (lambda (xs) #t)))\n(check-example 'one (equal? 1 1))\n";
        let declared = declared(text);
        assert_eq!(declared.len(), 2);
        assert_eq!(declared[0].name, "rev");
        assert_eq!(declared[0].statement, "reversing twice is identity");
        assert_eq!(declared[1].name, "one");
    }
}
