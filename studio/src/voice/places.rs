//! Places in the program the author's view can be sent to, found in its
//! text: a definition by a spoken name, a name's uses, a line, a file, a
//! search. The router's `navigate` (voice.rs) resolves here, at once,
//! without the builder; the builder's `show` names a place directly.

use super::Context;
use crate::sexp;
use crate::studio::Studio;
use crate::toolchain::{self, Files};
use serde_json::{Value, json};

/// Most places a focus shows.
const MAX_TARGETS: usize = 40;

impl Studio {
    /// The router's `navigate`: move the author's focus to the places it
    /// names, or say none were found.
    pub(super) fn navigate(&self, navigate: &Value, context: &Context) {
        let files = self.files();
        let kind = navigate["kind"].as_str().unwrap_or("");
        let name = navigate["name"].as_str().unwrap_or("").trim();
        let file = navigate["file"].as_str().unwrap_or("").trim();
        let query = navigate["query"].as_str().unwrap_or("").trim();
        let line = navigate["line"].as_u64().unwrap_or(0) as usize;
        let here = context.file.clone().unwrap_or_default();
        let (label, targets) = match kind {
            "definition" => {
                let found = definitions(&files, name);
                (format!("definition of {name}"), found)
            }
            "usages" => {
                let mut found = definitions(&files, name);
                let resolved = found.first().map(|t| t["name"].as_str().unwrap_or(name).to_owned()).unwrap_or_else(|| name.to_owned());
                found.extend(usages(&files, &resolved));
                dedupe(&mut found);
                (format!("{resolved}: definition and uses"), found)
            }
            "line" => {
                let file = if file.is_empty() || !files.contains_key(file) { here.clone() } else { file.to_owned() };
                (format!("{file}:{line}"), target(&files, &file, line.max(1), "line").into_iter().collect())
            }
            "file" => {
                let found = files.keys().find(|path| path.as_str() == file).or_else(|| {
                    let want = normalize(file);
                    files.keys().find(|path| normalize(path).contains(&want))
                });
                match found {
                    Some(path) => (path.clone(), target(&files, path, 1, "file").into_iter().collect()),
                    None => (file.to_owned(), Vec::new()),
                }
            }
            "text" => (format!("“{query}”"), search(&files, query)),
            "next" | "previous" | "back" => {
                self.voice_event("client", json!({ "command": kind }));
                return;
            }
            _ => return,
        };
        if targets.is_empty() {
            let text = format!("I couldn't find {label}.");
            self.voice_event("reply", json!({ "text": text, "speak": true }));
            return;
        }
        let mut targets = targets;
        targets.truncate(MAX_TARGETS);
        self.voice_event("focus", json!({ "label": label, "targets": targets }));
    }

}

fn normalize(name: &str) -> String {
    name.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}

pub(super) fn target(files: &Files, file: &str, line: usize, role: &str) -> Option<Value> {
    let text = files.get(file)?;
    let count = text.lines().count().max(1);
    let line = line.clamp(1, count);
    let shown = text.lines().nth(line - 1).unwrap_or("").trim();
    Some(json!({ "file": file, "line": line, "text": toolchain::clip(shown, 160), "role": role }))
}

/// The top-level definitions named `name`, exactly, else by its letters
/// alone ("eval step" finds eval-step), else containing them.
fn definitions(files: &Files, name: &str) -> Vec<Value> {
    let want = normalize(name);
    if want.is_empty() {
        return Vec::new();
    }
    // every top-level definition, and every constructor of a define-type
    // (\"where is VRec defined\": on its line inside `Value`)
    let all: Vec<(String, String, usize)> = files
        .iter()
        .flat_map(|(path, text)| {
            sexp::forms(text).into_iter().flat_map(move |f| {
                let made: Vec<(String, String, usize)> = sexp::constructors_at(text, &f).into_iter().map(|(c, line)| (path.clone(), c, line)).collect();
                // a define-something names what it defines; a provide or a
                // signature only mentions it
                let defines = f.head.as_deref().is_some_and(|h| h.starts_with("define"));
                f.name.clone().filter(|_| defines).map(|n| (path.clone(), n, f.line)).into_iter().chain(made)
            })
        })
        .collect();
    let pick = |test: &dyn Fn(&str) -> bool| -> Vec<Value> {
        all.iter()
            .filter(|(_, n, _)| test(n))
            .filter_map(|(path, n, line)| {
                let mut t = target(files, path, *line, "definition")?;
                t["name"] = json!(n);
                Some(t)
            })
            .collect()
    };
    let exact = pick(&|n| n == name);
    if !exact.is_empty() {
        return exact;
    }
    let loose = pick(&|n| normalize(n) == want);
    if !loose.is_empty() {
        return loose;
    }
    pick(&|n| normalize(n).contains(&want))
}

/// Every place `name` is written, as an atom, in any file.
fn usages(files: &Files, name: &str) -> Vec<Value> {
    let mut out = Vec::new();
    for (path, text) in files {
        for (start, end) in sexp::atoms(text) {
            if &text[start..end] == name {
                let line = sexp::line_of(text, start);
                if let Some(mut t) = target(files, path, line, "use") {
                    t["name"] = json!(name);
                    out.push(t);
                }
            }
        }
    }
    out
}

/// Lines containing `query`, ignoring case.
fn search(files: &Files, query: &str) -> Vec<Value> {
    let want = query.to_lowercase();
    if want.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    for (path, text) in files {
        for (index, line) in text.lines().enumerate() {
            if line.to_lowercase().contains(&want) {
                out.extend(target(files, path, index + 1, "match"));
            }
        }
    }
    out
}

/// One target a line: the first (a definition before a use) wins.
fn dedupe(targets: &mut Vec<Value>) {
    let mut seen = std::collections::HashSet::new();
    targets.retain(|t| seen.insert((t["file"].as_str().unwrap_or("").to_owned(), t["line"].as_u64().unwrap_or(0))));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn files(pairs: &[(&str, &str)]) -> Files {
        pairs.iter().map(|(a, b)| (a.to_string(), b.to_string())).collect()
    }

    #[test]
    fn constructors_are_definitions_too() {
        let values = ";; values.puf -- run-time values and environments.\n(require \"syntax.puf\")\n(provide Value VNum VBool VClo VRec Env)\n\n;; What an expression evaluates to.\n(define-type Value\n  (VNum Int)                       ;; an integer\n  (VBool Bool)                     ;; a boolean\n  (VClo Sym Expr Env)              ;; closure: parameter, body, defining env\n  (VRec Sym Sym Expr Env))         ;; recursive closure: self name, parameter, body, env\n";
        let files = files(&[("values.puf", values)]);
        let found = definitions(&files, "VRec");
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0]["line"], json!(10));
        assert_eq!(definitions(&files, "v rec")[0]["line"], json!(10));
        assert_eq!(definitions(&files, "Value")[0]["line"], json!(6));
    }

    #[test]
    fn definitions_match_spoken_names() {
        let f = files(&[("m.puf", "(define (eval-step s) s)\n(define (inject e) (eval-step e))\n")]);
        assert_eq!(definitions(&f, "eval-step")[0]["line"], 1);
        assert_eq!(definitions(&f, "eval step")[0]["name"], "eval-step");
        assert_eq!(definitions(&f, "inject")[0]["line"], 2);
        assert!(definitions(&f, "nothing").is_empty());
    }

    #[test]
    fn usages_skip_comments_and_strings() {
        let f = files(&[("m.puf", ";; step here\n(define (step s) s)\n(display \"step\")\n(step 1)\n")]);
        let lines: Vec<u64> = usages(&f, "step").iter().map(|t| t["line"].as_u64().unwrap()).collect();
        assert_eq!(lines, vec![2, 4]);
    }
}
