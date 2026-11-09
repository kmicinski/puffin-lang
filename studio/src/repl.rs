//! Evaluation in the live lane (docs/STUDIO.md §2.2): text from the prompt,
//! a form from a buffer, or a whole module, compiled as one `--repl` unit
//! and loaded into the session. A unit that does not compile never reaches
//! the session.
//!
//! Each unit is checked alone, so a later unit does not know an earlier
//! unit's `define-type`. The studio keeps every type declaration the
//! session has loaded and puts them ahead of each unit it compiles, the
//! latest definition of a name winning; a unit that defines a type itself
//! gets only the others.
//!
//! Evaluating a form of a module (⌘↵, `,eval FILE:LINE`) first loads, in
//! the same unit, the definitions of that module it needs that the session
//! lacks or has stale (session.rs). What each unit loaded is kept, so the
//! editor can mark each form current, stale, or not loaded. When the
//! session observes (lane.rs), every unit is compiled with `--observe`, and
//! after the evaluations pause the record is read back with a `try` of
//! `(#%observations)`; and every unit is compiled with `--trace` for each
//! traced name (trace.rs).

use crate::lane::{Output, Status};
use crate::session::{self, Session};
use crate::sexp::{self, Form};
use crate::studio::{Entry, Fix, Studio};
use crate::toolchain::{self, Files};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Where a unit's text came from.
#[derive(Clone, Debug)]
pub enum Source {
    /// Typed at the prompt.
    Prompt,
    /// Forms of `file` (eval-from-buffer): pieces of the text, each
    /// (its first line in the text, that line in the file).
    Buffer { file: String, pieces: Vec<(usize, usize)> },
    /// The whole module `file`.
    File { file: String },
}

impl Source {
    /// Text of `file` starting on its `line`.
    pub fn buffer(file: impl Into<String>, line: usize) -> Self {
        Source::Buffer { file: file.into(), pieces: vec![(1, line)] }
    }
}

/// Where a form of a module is: a byte offset, or a line.
#[derive(Clone, Copy, Debug)]
pub enum At {
    Pos(usize),
    Line(usize),
}

/// The line in the file of line `line` of a buffer unit's text.
pub fn file_line(pieces: &[(usize, usize)], line: usize) -> usize {
    match pieces.iter().rev().find(|(first, _)| *first <= line) {
        Some((first, file)) => file + (line - first),
        None => line,
    }
}

/// The top-level form of `text` at `at`: for a line, the form holding it,
/// else the next one to start.
pub fn form_at(text: &str, at: At) -> Option<Form> {
    match at {
        At::Pos(pos) => sexp::form_at(text, pos),
        At::Line(line) => {
            let all = sexp::forms(text);
            let holding = all.iter().find(|form| form.line <= line && line <= sexp::line_of(text, form.end));
            holding.or_else(|| all.iter().find(|form| form.line >= line)).cloned()
        }
    }
}

/// A unit ready to compile: where it is, and how its lines map back.
pub struct Unit {
    /// The directory to compile in, and the unit's path within it.
    pub dir: std::path::PathBuf,
    pub path: String,
    /// The lines the session's types took ahead of the text, and the line
    /// after which they were put (0: at the very start).
    pub prefix_lines: usize,
    pub inserted_after: usize,
    /// The type names the unit's own text defines.
    pub defines: Vec<(String, String)>,
    /// Kept alive until the unit has run.
    _workspace: Option<toolchain::Workspace>,
}

/// The session's types `text` does not define itself, as one block.
pub fn prefix(types: &[(String, String)], defined: &[String]) -> String {
    types
        .iter()
        .filter(|(name, _)| !defined.contains(name))
        .map(|(_, form)| format!("{form}\n"))
        .collect()
}

/// Keep `defines` as the session's newest type declarations.
pub fn remember(types: &mut Vec<(String, String)>, defines: &[(String, String)]) {
    for (name, form) in defines {
        match types.iter_mut().find(|(known, _)| known == name) {
            Some(kept) => kept.1 = form.clone(),
            None => types.push((name.clone(), form.clone())),
        }
    }
}

/// Where in a module the session's types go: after its leading `require`
/// and `provide` forms, which must come first. (byte offset, line)
pub fn insertion_point(text: &str) -> (usize, usize) {
    let mut at = (0, 0);
    for form in sexp::forms(text) {
        match form.head.as_deref() {
            Some("require" | "provide") => at = (form.end, sexp::line_of(text, form.end)),
            _ => break,
        }
    }
    at
}

/// What would fix a run that referenced names before their definition:
/// each such name a module of `files` defines at its top level.
pub fn fixes(files: &Files, errors: &str) -> Vec<Fix> {
    let mut out = Vec::new();
    for name in session::undefined_names(errors) {
        for (file, text) in files {
            let defines = sexp::forms(text)
                .into_iter()
                .find(|form| session::definition(form) && !sexp::type_form(form) && form.name.as_deref() == Some(name.as_str()));
            if let Some(form) = defines {
                out.push(Fix { name: name.clone(), file: file.clone(), line: form.line });
                break;
            }
        }
    }
    out
}

/// Words an assistant's `evaluate` may not use: effects outside the
/// session, and reads of stdin (which is the session's command pipe).
const EFFECTS: [&str; 7] = ["system", "write-file", "read", "read-all", "read-line", "foreign", "define-foreign-type"];

pub fn effectful(text: &str) -> Option<&'static str> {
    let words: Vec<&str> = text.split(|c: char| c.is_whitespace() || "()[]'`,\"".contains(c)).collect();
    EFFECTS.into_iter().find(|effect| words.contains(effect))
}

impl Studio {
    /// Lay out `text` from `source` as a unit, with the session's types.
    pub(crate) fn unit(&self, text: &str, source: &Source) -> Result<Unit, String> {
        let types = self.types.lock().expect("types lock").clone();
        match source {
            Source::Prompt | Source::Buffer { .. } => {
                let mut defines = sexp::define_types(text);
                let mut names: Vec<String> = defines.iter().map(|(name, _)| name.clone()).collect();
                // a form from a buffer means its module's types, as the
                // module now declares them
                if let Source::Buffer { file, .. } = source {
                    let files = self.files();
                    let mut declared = Vec::new();
                    for path in toolchain::closure(&files, file) {
                        if let Some(module) = files.get(&path) {
                            declared.extend(sexp::define_types(module).into_iter().filter(|(name, _)| !names.contains(name)));
                        }
                    }
                    names.extend(declared.iter().map(|(name, _)| name.clone()));
                    let head = prefix(&types, &names);
                    let own = declared.iter().map(|(_, form)| format!("{form}\n")).collect::<String>();
                    defines.extend(declared);
                    let head = format!("{head}{own}");
                    let dir = self.toolchain.fresh("unit");
                    std::fs::create_dir_all(&dir).map_err(|error| error.to_string())?;
                    std::fs::write(dir.join("unit.puf"), format!("{head}{text}\n")).map_err(|error| error.to_string())?;
                    return Ok(Unit { dir, path: "unit.puf".into(), prefix_lines: head.matches('\n').count(), inserted_after: 0, defines, _workspace: None });
                }
                let head = prefix(&types, &names);
                let dir = self.toolchain.fresh("unit");
                std::fs::create_dir_all(&dir).map_err(|error| error.to_string())?;
                std::fs::write(dir.join("unit.puf"), format!("{head}{text}\n")).map_err(|error| error.to_string())?;
                Ok(Unit { dir, path: "unit.puf".into(), prefix_lines: head.matches('\n').count(), inserted_after: 0, defines, _workspace: None })
            }
            Source::File { file } => {
                let files = self.files();
                let mut defines = Vec::new();
                for path in toolchain::closure(&files, file) {
                    if let Some(text) = files.get(&path) {
                        defines.extend(sexp::define_types(text));
                    }
                }
                let names: Vec<String> = defines.iter().map(|(name, _)| name.clone()).collect();
                let head = prefix(&types, &names);
                let (at, line) = insertion_point(text);
                let mut with_types = files.clone();
                let joined = if head.is_empty() { text.to_owned() } else { format!("{}\n{head}{}", &text[..at], &text[at..]) };
                with_types.insert(file.clone(), joined);
                let workspace = self.toolchain.workspace(&with_types)?;
                let prefix_lines = if head.is_empty() { 0 } else { head.matches('\n').count() + 1 };
                Ok(Unit {
                    dir: workspace.dir.clone(),
                    path: file.clone(),
                    prefix_lines,
                    inserted_after: line,
                    defines,
                    _workspace: Some(workspace),
                })
            }
        }
    }

    /// Compile `unit` for the live session: observing when it observes, and
    /// tracing the traced names when it can (trace.rs). The .pbc, or the
    /// compiler's message with its lines mapped back to the text (and, for
    /// a buffer's form, to its file).
    pub(crate) async fn compile(&self, unit: &Unit, source: &Source) -> Result<std::path::PathBuf, String> {
        // a compiler swapped for one that cannot observe compiles plainly
        let observe = self.lane.observing() && self.toolchain.observe_available().await;
        let trace = if self.can_trace().await { self.traced_names() } else { Vec::new() };
        self.compile_with(unit, source, observe, &trace).await
    }

    /// Compile `unit`, observing or not, with the defines of `trace` traced.
    pub(crate) async fn compile_with(&self, unit: &Unit, source: &Source, observe: bool, trace: &[String]) -> Result<std::path::PathBuf, String> {
        let out = unit.dir.join("unit.pbc");
        let output = self.toolchain.compile_traced(&unit.dir, &unit.path, &out, observe, trace).await?;
        if output.timed_out {
            return Err("the compile timed out".to_owned());
        }
        if output.success && out.is_file() {
            return Ok(out);
        }
        let base = unit.path.rsplit('/').next().unwrap_or(&unit.path).to_owned();
        let resolve = |name: &str| name.to_owned();
        let mut found = toolchain::diagnostics(false, &output.stdout, &output.stderr, &resolve);
        for d in found.iter_mut().filter(|d| d.severity == "hole") {
            d.message = format!("{} (a typed hole: fill it to evaluate; ⌘. on it lists candidates)", d.message);
        }
        let lines: Vec<String> = found
            .iter()
            // a typed hole stops a unit like any error: it cannot run
            .filter(|d| d.severity != "warning")
            .map(|d| {
                if d.line == 0 || d.file != base {
                    return match (d.file.as_str(), d.line) {
                        ("", _) | (_, 0) => d.message.clone(),
                        (file, line) => format!("{} [{file}:{line}]", d.message),
                    };
                }
                let line = if d.line > unit.inserted_after { d.line.saturating_sub(unit.prefix_lines) } else { d.line };
                if line <= unit.inserted_after && unit.prefix_lines > 0 && d.line > unit.inserted_after {
                    return format!("{} (in a type the session declared earlier)", d.message);
                }
                match source {
                    Source::Prompt => format!("{} [line {line}]", d.message),
                    Source::Buffer { file, pieces } => format!("{} [{file}:{}]", d.message, file_line(pieces, line)),
                    Source::File { file } => format!("{} [{file}:{line}]", d.message),
                }
            })
            .collect();
        Err(if lines.is_empty() { "the unit does not compile".to_owned() } else { lines.join("\n") })
    }

    /// Evaluate `text` in the live session, as a transcript entry.
    pub async fn evaluate(self: &Arc<Self>, text: String, source: Source) {
        let line = match &source {
            Source::File { file } => format!(",load {file}"),
            _ => text.trim().to_owned(),
        };
        self.evaluate_as(text, source, line, String::new(), Vec::new()).await;
    }

    /// Evaluate the form of `file` at `at`, with the definitions of the
    /// module it needs that the session lacks or has stale loaded first,
    /// as one unit: ⌘↵, and `,eval FILE:LINE`.
    pub async fn eval_form(self: &Arc<Self>, file: &str, at: At) -> Result<(), String> {
        self.eval_form_as(file, at, None).await
    }

    /// Evaluate the form of `file` at `at` as `eval_form` does, the entry
    /// showing `command` (`,trace f`) instead of `,eval FILE:LINE`.
    pub async fn eval_form_as(self: &Arc<Self>, file: &str, at: At, command: Option<String>) -> Result<(), String> {
        let text = self.text_of(file).ok_or_else(|| format!("no file {file}"))?;
        let form = form_at(&text, at).ok_or_else(|| match at {
            At::Line(line) => format!("no form at {file}:{line}"),
            At::Pos(_) => "no form at the cursor".to_owned(),
        })?;
        let view = self.session_view();
        let lacking = |need: &Form| Session::state(&view, file, &text, need).status != "current";
        let needs = session::needs(&text, &form, &lacking);
        let mut body = String::new();
        let mut pieces = Vec::new();
        for piece in needs.iter().chain(std::iter::once(&form)) {
            pieces.push((body.matches('\n').count() + 1, piece.line));
            body.push_str(&text[piece.start..piece.end]);
            body.push('\n');
        }
        let also = needs.iter().filter_map(|need| need.name.clone()).collect();
        let whole = text[form.start..form.end].trim();
        // a command's entry names the define by its first line: the command says the rest
        let shown = match (&command, whole.split_once('\n')) {
            (Some(_), Some((head, _))) => format!("{} …", head.trim_end()),
            _ => whole.to_owned(),
        };
        let command = command.unwrap_or_else(|| format!(",eval {file}:{}", form.line));
        self.evaluate_as(body, Source::Buffer { file: file.to_owned(), pieces }, shown, command, also).await;
        Ok(())
    }

    /// Evaluate `text` from `source` as a transcript entry showing `line`
    /// (and `command`, the gesture's, and `also`, what loads first).
    pub(crate) async fn evaluate_as(self: &Arc<Self>, text: String, source: Source, line: String, command: String, also: Vec<String>) {
        let (origin, file) = match &source {
            Source::Prompt => ("prompt", None),
            Source::Buffer { file, .. } => ("buffer", Some(file.clone())),
            Source::File { file } => ("file", Some(file.clone())),
        };
        let id = self.begin(Entry { kind: "eval", origin: origin.to_owned(), line, file, command, also, ..Entry::default() });
        let started = Instant::now();
        let _queue = self.eval_queue.lock().await;
        // a session started now knows whether this unit may observe
        if let Err(error) = self.lane.ensure().await {
            return self.finish(id, "error", Some(format!("the session did not start: {error}")), 0);
        }
        let files = self.files();
        let unit = match self.unit(&text, &source) {
            Ok(unit) => unit,
            Err(error) => return self.finish(id, "error", Some(error), 0),
        };
        let pbc = match self.compile(&unit, &source).await {
            Ok(pbc) => pbc,
            Err(error) => {
                // REPL units carry no positions; the check of the module does
                let error = match &source {
                    Source::File { file } => {
                        let report = self.toolchain.check(&self.files(), file).await;
                        let located = report.diagnostics.iter().any(|d| d.severity != "warning" && d.line > 0);
                        if located { report.describe() } else { error }
                    }
                    _ => error,
                };
                return self.finish(id, "compile-error", Some(error), started.elapsed().as_millis() as u64);
            }
        };
        let studio = self.clone();
        let mut errors = String::new();
        let mut last = None;
        let mut sink = |output: Output| match output {
            Output::Out(text) => studio.output(id, "out", text),
            Output::Err(text) => {
                if errors.len() < 16_000 {
                    errors.push_str(&text);
                }
                studio.output(id, "err", text)
            }
            Output::Result(text) => {
                last = Some(text.clone());
                studio.output(id, "result", text)
            }
        };
        let status = self.lane.run(&pbc, true, &mut sink).await;
        let ms = started.elapsed().as_millis() as u64;
        match status {
            Status::Ok => {
                crate::repl::remember(&mut self.types.lock().expect("types lock"), &unit.defines);
                {
                    let mut session = self.session.lock().expect("session lock");
                    match &source {
                        Source::Prompt => session.loaded_prompt(&files, &text, id),
                        Source::Buffer { file, .. } => session.loaded_buffer(file, &text, id, last),
                        Source::File { file } => session.loaded_file(&files, &toolchain::closure(&files, file), id),
                    }
                }
                self.finish(id, "ok", None, ms);
                self.publish_session();
                self.observations_due.notify_one();
            }
            Status::Err(code) => {
                let fixes = fixes(&self.files(), &errors);
                // a REPL unit looks unbound names up at run time, so a hole fails when reached
                let hole = if session::undefined_names(&errors).iter().any(|name| name == "??") {
                    "; it reached a typed hole (??): fill it first (⌘. on the hole lists candidates)"
                } else {
                    ""
                };
                self.finish_with(id, "error", Some(format!("the unit failed (exit {code}){hole}; the session is as it was")), ms, fixes);
                self.merge_spill().await;
            }
            Status::Interrupted => {
                self.finish(id, "interrupted", Some("interrupted; the session is as it was".into()), ms);
                self.merge_spill().await;
            }
            Status::Dead(why) => {
                self.forget_session();
                self.finish(id, "error", Some(format!("the session ended: {why}")), ms);
            }
        }
    }

    /// Restart the live lane, forgetting the session's types and what it
    /// held of the program.
    pub async fn reset(&self) {
        self.lane.reset().await;
        self.types.lock().expect("types lock").clear();
        self.forget_session();
    }

    /// Forget what the session held: it is gone.
    fn forget_session(&self) {
        self.session.lock().expect("session lock").clear();
        if let Some(record) = self.toolchain.observed.lock().expect("observed lock").take() {
            let _ = std::fs::remove_file(record);
        }
        self.clear_lint();
        self.publish_session();
    }

    /// After a failed evaluation, fold what it observed before it
    /// failed back into the session: the observer spilled its record as
    /// new shapes arrived (studio/observe.puf), and the shape that broke
    /// a match is the one most worth keeping. The merge is a `load` of
    /// `(#%observe-merge! 'RECORD)`.
    async fn merge_spill(&self) {
        if !self.lane.observing() || self.lane.status().mode != "serve" {
            return;
        }
        let spill = self.lane.spill_path();
        let Ok(record) = std::fs::read_to_string(&spill) else { return };
        let _ = std::fs::remove_file(&spill);
        let record = record.trim();
        if record.is_empty() || record == "()" {
            return;
        }
        let dir = self.toolchain.fresh("merge");
        let workspace = toolchain::Workspace { dir: dir.clone() };
        if std::fs::create_dir_all(&dir)
            .and_then(|()| std::fs::write(dir.join("unit.puf"), format!("(#%observe-merge! (quote {record}))\n")))
            .is_err()
        {
            return;
        }
        let pbc = dir.join("unit.pbc");
        if !self.toolchain.compile_unit(&dir, "unit.puf", &pbc, false).await.is_ok_and(|output| output.success) {
            return;
        }
        let merged = self.lane.run(&pbc, true, &mut |_| {}).await == Status::Ok;
        drop(workspace);
        if merged {
            self.observations_due.notify_one();
        }
    }

    /// Read the session's observation record back (`try` of
    /// `(#%observations)`), keep it in the scratch directory for
    /// `--observed`, and show it. Nothing when the session does not
    /// observe, or replays (a `try` there would run every unit's effects
    /// again).
    pub async fn refresh_observations(&self) {
        if !self.lane.observing() || self.lane.status().mode != "serve" {
            return;
        }
        let _queue = self.eval_queue.lock().await;
        let generation = self.lane.generation();
        let dir = self.toolchain.fresh("observations");
        let workspace = toolchain::Workspace { dir: dir.clone() };
        if std::fs::create_dir_all(&dir).and_then(|()| std::fs::write(dir.join("unit.puf"), "(#%observations)\n")).is_err() {
            return;
        }
        let pbc = dir.join("unit.pbc");
        let compiled = self.toolchain.compile_unit(&dir, "unit.puf", &pbc, false).await;
        if !compiled.is_ok_and(|output| output.success) {
            return;
        }
        let mut results = Vec::new();
        let mut sink = |output: Output| {
            if let Output::Result(text) = output {
                results.push(text);
            }
        };
        let status = self.lane.try_quietly(&pbc, &mut sink).await;
        drop(workspace);
        let (Some(Status::Ok), Some(record)) = (status, results.pop()) else { return };
        if generation != self.lane.generation() {
            return;
        }
        let path = self.toolchain.scratch.join("observed.sexp");
        if std::fs::write(&path, format!("{record}\n")).is_err() {
            return;
        }
        *self.toolchain.observed.lock().expect("observed lock") = Some(path);
        let changed = {
            let mut session = self.session.lock().expect("session lock");
            let observed = session::parse_record(&record);
            let changed = session.observed != observed;
            session.record = Some(record);
            session.observed = observed;
            changed
        };
        if changed {
            drop(_queue);
            self.publish_session();
            self.refresh_lint(None).await;
        }
    }

    /// Run `text` against the live session and keep nothing (`try`): the
    /// assistant's `evaluate`. Effects outside the session are refused.
    pub async fn try_expression(&self, text: &str) -> Result<Value, String> {
        if let Some(word) = effectful(text) {
            return Err(format!("`{word}` reaches outside the session; evaluate refuses it. Suggest it to the author in a ```repl block instead."));
        }
        let Ok(_queue) = tokio::time::timeout(Duration::from_secs(30), self.eval_queue.lock()).await else {
            return Err("the session is busy with the author's evaluation; try again shortly".to_owned());
        };
        let source = Source::Prompt;
        let unit = self.unit(text, &source)?;
        let pbc = match self.compile(&unit, &source).await {
            Ok(pbc) => pbc,
            Err(error) => return Ok(json!({ "ok": false, "phase": "compile", "error": error })),
        };
        let mut out = String::new();
        let mut results = Vec::new();
        let mut sink = |output: Output| match output {
            Output::Out(text) | Output::Err(text) => {
                if out.len() < 8000 {
                    out.push_str(&text);
                }
            }
            Output::Result(text) => results.push(text),
        };
        let status = tokio::time::timeout(Duration::from_secs(20), self.lane.run(&pbc, false, &mut sink)).await;
        let status = match status {
            Ok(status) => status,
            Err(_) => {
                let _ = self.lane.interrupt();
                Status::Interrupted
            }
        };
        // the observer's spill is of the discarded state: a later failure must not merge it
        let _ = std::fs::remove_file(self.lane.spill_path());
        let (ok, status) = match &status {
            Status::Ok => (true, "ok".to_owned()),
            Status::Err(code) => (false, format!("error (status {code})")),
            Status::Interrupted => (false, "interrupted (took over 20 s)".to_owned()),
            Status::Dead(why) => (false, format!("the session ended: {why}")),
        };
        Ok(json!({
            "ok": ok,
            "status": status,
            "output": toolchain::clip(&out, 6000),
            "results": results,
            "note": "run against the author's live session with try: nothing it defined was kept",
        }))
    }

    /// The forked program's `entry` compiled whole and run on a throwaway
    /// VM: the preview lane.
    pub async fn run_fork(&self, files: &Files, entry: &str) -> Value {
        self.toolchain.run_program(files, entry, Duration::from_secs(10)).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn types_go_ahead_of_units_latest_first_and_never_twice() {
        let mut types = Vec::new();
        remember(&mut types, &sexp::define_types("(define-type T (A Int))\n(define-type U (B))"));
        remember(&mut types, &sexp::define_types("(define-type T (A Int) (C))"));
        assert_eq!(prefix(&types, &[]), "(define-type T (A Int) (C))\n(define-type U (B))\n");
        assert_eq!(prefix(&types, &["U".into()]), "(define-type T (A Int) (C))\n");
    }

    #[test]
    fn type_aliases_ride_along_like_types() {
        let mut types = Vec::new();
        remember(&mut types, &sexp::define_types("(define-type-alias Env (Hash Str Int))\n(define (f [e : Env]) 1)"));
        assert_eq!(prefix(&types, &[]), "(define-type-alias Env (Hash Str Int))\n");
        remember(&mut types, &sexp::define_types("(define-type-alias (Table a) (Hash Str a))"));
        assert_eq!(prefix(&types, &[]), "(define-type-alias Env (Hash Str Int))\n(define-type-alias (Table a) (Hash Str a))\n");
    }

    #[test]
    fn buffer_lines_map_back_piece_by_piece() {
        let pieces = [(1, 5), (3, 20)];
        assert_eq!(file_line(&pieces, 1), 5);
        assert_eq!(file_line(&pieces, 2), 6);
        assert_eq!(file_line(&pieces, 4), 21);
        let text = "(define a 1)\n\n(define (f x)\n  x)\n";
        assert_eq!(form_at(text, At::Line(4)).unwrap().key(), "define:f");
        assert_eq!(form_at(text, At::Line(2)).unwrap().key(), "define:f");
        assert!(form_at(text, At::Line(9)).is_none());
    }

    #[test]
    fn an_undefined_name_a_module_defines_is_a_fix() {
        let files = Files::from([("m.puf".to_owned(), "(define x 1)\n(define (helper y) y)\n".to_owned())]);
        let errors = "puffin runtime error: helper: undefined; cannot reference an identifier before its definition\n";
        assert_eq!(fixes(&files, errors), [Fix { name: "helper".into(), file: "m.puf".into(), line: 2 }]);
        assert!(fixes(&files, "puffin runtime error: nope: undefined; cannot reference an identifier before its definition").is_empty());
    }

    #[test]
    fn module_units_take_types_after_their_requires() {
        let text = "(require \"a.puf\")\n(provide f)\n(define (f x) x)\n";
        let (at, line) = insertion_point(text);
        assert_eq!(&text[..at], "(require \"a.puf\")\n(provide f)");
        assert_eq!(line, 2);
        assert_eq!(insertion_point("(define x 1)"), (0, 0));
    }

    #[test]
    fn the_assistant_may_not_reach_outside_the_session() {
        assert_eq!(effectful("(system \"rm -rf /\")"), Some("system"));
        assert_eq!(effectful("(begin (read) 1)"), Some("read"));
        assert_eq!(effectful("(read-file \"x\")"), None);
        assert_eq!(effectful("(map car '((1 2)))"), None);
    }
}
