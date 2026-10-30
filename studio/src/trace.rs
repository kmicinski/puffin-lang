//! Tracing (docs/STUDIO.md §3.2): `,trace NAME` and `,untrace NAME`, and
//! the assistant's `trace` tool.
//!
//! The studio keeps a set of traced function names. Every unit the live
//! session compiles passes `--trace NAME` for each (the compiler rewrites
//! only the defines a unit has), so a traced function's calls print, nested
//! by depth, wherever its define is next loaded from: ⌘↵, `,load`, or the
//! prompt. The printing is the session runtime's (`studio/observe.puf`), so
//! a session without it cannot trace.
//!
//! `,trace f` evaluates f's definition again at once, so the trace applies
//! now: the session's own when the prompt made it, else its module's by the
//! path ⌘↵ takes. `,untrace f` evaluates it again untraced. REPL redefinition is retroactive: every caller of f
//! traces too. The set outlives a reset, as breakpoints would: the next load
//! of f is traced.
//!
//! The assistant's `trace {names, expr}` never touches the set or the
//! session: it compiles each named define (as the thread's proposals leave
//! it, with what it needs that the session lacks) traced, and the
//! expression, as one unit, and runs it with `try`.

use crate::lane::{Output, Status};
use crate::repl::{At, Source, effectful};
use crate::session::{self, Session, SessionView};
use crate::sexp::{self, Form};
use crate::studio::{Event, Studio};
use crate::toolchain::{self, Files};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;

/// Lines of a trace the `trace` tool returns, at most.
pub const TRACE_LINES: usize = 200;
/// How long the `trace` tool's run may take.
const TRACE_LIMIT: Duration = Duration::from_secs(20);

/// Whether `line` is one the trace runtime prints: `> (f args)` on entry or
/// `< value` on return, after a `| ` per level of depth.
pub fn is_trace_line(line: &str) -> bool {
    let mut rest = line;
    while let Some(after) = rest.strip_prefix("| ") {
        rest = after;
    }
    rest.starts_with("> (") || rest.starts_with("< ")
}

/// Whether `line` is a traced call's entry.
pub fn is_call_line(line: &str) -> bool {
    let mut rest = line;
    while let Some(after) = rest.strip_prefix("| ") {
        rest = after;
    }
    rest.starts_with("> (")
}

/// A run's output kept a line at a time: the first `limit` lines, and a
/// count of every line and of the traced calls among them, so a runaway
/// trace costs a count and not memory.
#[derive(Debug, Default)]
pub struct Kept {
    pub limit: usize,
    pub text: String,
    pub lines: usize,
    pub calls: usize,
    partial: String,
}

impl Kept {
    pub fn new(limit: usize) -> Self {
        Kept { limit, ..Kept::default() }
    }

    pub fn push(&mut self, chunk: &str) {
        self.partial.push_str(chunk);
        while let Some(end) = self.partial.find('\n') {
            let line: String = self.partial.drain(..=end).collect();
            self.line(line.trim_end_matches('\n'));
        }
        // a line that never ends is kept to a bound
        if self.partial.len() > 4096 {
            let line = toolchain::clip(&std::mem::take(&mut self.partial), 4096);
            self.line(&line);
        }
    }

    pub fn finish(&mut self) {
        if !self.partial.is_empty() {
            let line = std::mem::take(&mut self.partial);
            self.line(&line);
        }
    }

    fn line(&mut self, line: &str) {
        self.lines += 1;
        if is_call_line(line) {
            self.calls += 1;
        }
        if self.lines <= self.limit {
            self.text.push_str(line);
            self.text.push('\n');
        }
    }
}

/// Whether `name` could name a function: one atom.
pub fn valid_name(name: &str) -> Result<(), String> {
    if name.is_empty() || name.contains(|c: char| c.is_whitespace() || "()[]\";'`,".contains(c)) {
        Err(format!("`{name}` is not a name"))
    } else {
        Ok(())
    }
}

/// The top-level define of `name` in `files`: in the file the session
/// loaded it from, else the first that defines it. (file, form)
pub fn definition_of(files: &Files, name: &str, view: &SessionView) -> Option<(String, Form)> {
    let key = format!("define:{name}");
    let defines = |text: &str| sexp::forms(text).into_iter().find(|form| form.head.as_deref() == Some("define") && form.name.as_deref() == Some(name));
    let loaded = view.files.iter().filter(|(_, forms)| forms.contains_key(&key)).map(|(file, _)| file);
    for file in loaded.chain(files.keys()) {
        if let Some(form) = files.get(file).and_then(|text| defines(text)) {
            return Some((file.clone(), form));
        }
    }
    None
}

/// Whether `form` of `text` is a define the compiler can trace: a
/// function's, `(define (f a ...) ...)`, with fixed parameters.
pub fn traceable(text: &str, form: &Form) -> bool {
    if sexp::params(text, form).is_none() {
        return false;
    }
    // params skips a rest marker; the head says whether there was one
    let head_end = text[form.start..form.end].find(')').map_or(form.end, |end| form.start + end);
    let head = &text[form.start..head_end];
    !head.split_whitespace().any(|word| word == "." || word.starts_with("#:"))
}

impl Studio {
    /// The traced names, in order.
    pub fn traced_names(&self) -> Vec<String> {
        self.traced.lock().expect("traced lock").iter().cloned().collect()
    }

    /// Whether the session running can trace: the compiler has `--trace`,
    /// and the session loaded the runtime that prints (the observer).
    pub(crate) async fn can_trace(&self) -> bool {
        self.lane.observing() && self.toolchain.trace_available().await
    }

    fn set_traced(&self, name: &str, on: bool) {
        let changed = {
            let mut traced = self.traced.lock().expect("traced lock");
            if on { traced.insert(name.to_owned()) } else { traced.remove(name) }
        };
        if changed {
            self.publish(Event::Traced { names: self.traced_names() });
        }
    }

    /// `,trace NAMES` (`on`) or `,untrace NAMES`: change the set, and
    /// evaluate each name's defining form again so the change applies now.
    /// `,untrace` with no names untraces every one.
    pub async fn trace(self: &Arc<Self>, names: Vec<String>, on: bool) {
        let verb = if on { ",trace" } else { ",untrace" };
        let names = if names.is_empty() && !on { self.traced_names() } else { names };
        if names.is_empty() {
            return self.echo_note(verb, "nothing is traced", false);
        }
        for name in names {
            let command = format!("{verb} {name}");
            if let Err(why) = valid_name(&name) {
                self.echo_note(&command, &why, true);
                continue;
            }
            let files = self.files();
            let view = self.session_view();
            let found = definition_of(&files, &name, &view);
            // the session's latest definition, when the prompt made it
            let typed = self.session.lock().expect("session lock").prompt_definition(&name);
            if on {
                let fixed = match (&typed, &found) {
                    (Some(text), _) => sexp::forms(text).first().is_some_and(|form| traceable(text, form)),
                    (None, Some((file, form))) => traceable(&files[file], form),
                    (None, None) => true,
                };
                if !fixed {
                    let at = match (&typed, &found) {
                        (None, Some((file, form))) => format!(" [{file}:{}]", form.line),
                        _ => " (defined at the prompt)".to_owned(),
                    };
                    let why = format!("{name} is not a function define: only (define ({name} a ...) ...) with fixed parameters traces{at}");
                    self.echo_note(&command, &why, true);
                    continue;
                }
                if let Err(error) = self.lane.ensure().await {
                    self.echo_note(&command, &format!("the session did not start: {error}"), true);
                    continue;
                }
                if !self.can_trace().await {
                    let why = if self.toolchain.trace_available().await {
                        "this session cannot trace: its runtime (studio/observe.puf) did not load"
                    } else {
                        "this session cannot trace: this puffincc has no --repl --trace"
                    };
                    self.echo_note(&command, why, true);
                    continue;
                }
            }
            self.set_traced(&name, on);
            if let Some(text) = typed {
                let shown = match text.split_once('\n') {
                    Some((head, _)) => format!("{} …", head.trim_end()),
                    None => text.clone(),
                };
                self.evaluate_as(text, Source::Prompt, shown, command, Vec::new()).await;
                continue;
            }
            match found {
                Some((file, form)) if on || Session::state(&view, &file, &files[&file], &form).status != "absent" => {
                    if let Err(error) = self.eval_form_as(&file, At::Pos(form.start), Some(command.clone())).await {
                        self.echo_note(&command, &error, true);
                    }
                }
                Some((file, _)) => self.echo_note(&command, &format!("untraced; the session has not loaded {name} from {file}"), false),
                None if on => self.echo_note(&command, &format!("nothing defines {name} yet: its next definition is traced"), false),
                None => self.echo_note(&command, &format!("untraced; nothing in the session defines {name}"), false),
            }
        }
    }

    /// The assistant's `trace`: each of `names`' defining forms in `files`
    /// (the thread's program) traced, with the definitions it and `expr`
    /// need that the session lacks, the modules' types, and `expr`, as one
    /// unit run against the live session with `try`. Nothing is kept: not
    /// the definitions, not the traced set.
    pub async fn trace_try(&self, files: &Files, names: &[String], expr: &str) -> Result<Value, String> {
        if names.is_empty() {
            return Err("name at least one function to trace in `names`".to_owned());
        }
        if expr.trim().is_empty() {
            return Err("give an expression to run in `expr`, e.g. `(eval-expr example)`".to_owned());
        }
        let view = self.session_view();
        // each definition the unit carries: (file, byte start) or the
        // prompt, its name, its text
        let mut pieces: Vec<((String, usize), Option<String>, String)> = Vec::new();
        let mut add = |key: (String, usize), name: Option<String>, text: String| {
            if !pieces.iter().any(|(k, n, _)| *k == key || (name.is_some() && *n == name)) {
                pieces.push((key, name, text));
            }
        };
        let mut modules: Vec<String> = Vec::new();
        let mut traced = Vec::new();
        for name in names {
            valid_name(name)?;
            // the session's own definition when the prompt made it (and this
            // thread's program does not define it), else the module's
            let typed = self.session.lock().expect("session lock").prompt_definition(name);
            let found = definition_of(files, name, &view);
            if let (Some(text), None) = (&typed, &found) {
                if !sexp::forms(text).first().is_some_and(|form| traceable(text, form)) {
                    return Err(format!("{name} (defined at the prompt) is not a function define with fixed parameters: it cannot be traced"));
                }
                add((String::new(), traced.len()), Some(name.clone()), text.clone());
                traced.push(format!("{name} [the prompt's definition]"));
                continue;
            }
            let (file, form) = found.ok_or_else(|| format!("nothing defines {name}: trace needs its (define ({name} ...) ...) in a file or the session"))?;
            let text = &files[&file];
            if !traceable(text, &form) {
                return Err(format!("{name} is not a function define with fixed parameters [{file}:{}]: it cannot be traced", form.line));
            }
            let lacking = |need: &Form| Session::state(&view, &file, text, need).status != "current";
            for piece in session::needs(text, &form, &lacking).into_iter().chain(std::iter::once(form.clone())) {
                add((file.clone(), piece.start), piece.name.clone(), text[piece.start..piece.end].to_owned());
            }
            traced.push(format!("{name} [{file}:{}]", form.line));
            if !modules.contains(&file) {
                modules.push(file);
            }
        }
        // what the expression mentions that the session lacks, from the
        // traced names' modules first: `(eval-expr example)` brings example
        let others: Vec<String> = files.keys().filter(|file| crate::studio::checkable(file) && !modules.contains(file)).cloned().collect();
        for file in modules.clone().into_iter().chain(others) {
            let text = &files[&file];
            let joined = format!("{text}\n{expr}\n");
            let Some(target) = sexp::forms(&joined).into_iter().find(|form| form.start > text.len()) else { continue };
            let lacking = |need: &Form| Session::state(&view, &file, text, need).status != "current";
            let needed = session::needs(&joined, &target, &lacking);
            if !needed.is_empty() && !modules.contains(&file) {
                modules.push(file.clone());
            }
            for piece in needed {
                add((file.clone(), piece.start), piece.name.clone(), text[piece.start..piece.end].to_owned());
            }
        }
        let mut types: Vec<(String, String)> = Vec::new();
        for module in &modules {
            for path in toolchain::closure(files, module) {
                for (name, form) in files.get(&path).map(|text| sexp::define_types(text)).unwrap_or_default() {
                    if !types.iter().any(|(known, _)| *known == name) {
                        types.push((name, form));
                    }
                }
            }
        }
        let mut body: String = types.iter().map(|(_, form)| format!("{form}\n")).collect();
        for (_, _, text) in &pieces {
            body.push_str(text);
            body.push('\n');
        }
        body.push_str(expr);
        body.push('\n');
        if let Some(word) = effectful(&body) {
            return Err(format!("`{word}` reaches outside the session; trace refuses it, as evaluate does. Suggest it to the author in a ```repl block instead."));
        }
        let Ok(_queue) = tokio::time::timeout(Duration::from_secs(30), self.eval_queue.lock()).await else {
            return Err("the session is busy with the author's evaluation; try again shortly".to_owned());
        };
        self.lane.ensure().await.map_err(|error| format!("the session did not start: {error}"))?;
        if !self.can_trace().await {
            return Err("the author's session cannot trace (no --repl --trace, or its runtime did not load); use evaluate".to_owned());
        }
        let source = Source::Prompt;
        let unit = self.unit(&body, &source)?;
        let pbc = match self.compile_with(&unit, &source, false, names).await {
            Ok(pbc) => pbc,
            Err(error) => return Ok(json!({ "ok": false, "phase": "compile", "error": error, "traced": traced })),
        };
        let mut kept = Kept::new(TRACE_LINES);
        let mut errors = String::new();
        let mut results = Vec::new();
        let mut sink = |output: Output| match output {
            Output::Out(text) => kept.push(&text),
            Output::Err(text) => {
                if errors.len() < 4000 {
                    errors.push_str(&text);
                }
            }
            Output::Result(text) => results.push(text),
        };
        let status = match tokio::time::timeout(TRACE_LIMIT, self.lane.run(&pbc, false, &mut sink)).await {
            Ok(status) => status,
            Err(_) => {
                let _ = self.lane.interrupt();
                Status::Interrupted
            }
        };
        kept.finish();
        // the observer's spill is of the discarded state
        let _ = std::fs::remove_file(self.lane.spill_path());
        let (ok, status) = match &status {
            Status::Ok => (true, "ok".to_owned()),
            Status::Err(code) => (false, format!("error (status {code}): the trace shows the calls up to the failure")),
            Status::Interrupted => (false, format!("interrupted (took over {} s): likely runaway recursion; the trace shows how it began", TRACE_LIMIT.as_secs())),
            Status::Dead(why) => (false, format!("the session ended: {why}")),
        };
        let mut answer = json!({
            "ok": ok,
            "status": status,
            "traced": traced,
            "trace": kept.text,
            "lines": kept.lines,
            "calls": kept.calls,
            "results": results,
            "note": "`> (f args)` is a call, `< value` its return, one `| ` per level of depth. Run against the author's live session with try: nothing it defined or traced was kept; the definitions are the files' as your proposals leave them.",
        });
        if kept.lines > TRACE_LINES {
            answer["cut"] = json!(format!("{} more lines not shown (the first {TRACE_LINES} are): trace a smaller input", kept.lines - TRACE_LINES));
        }
        if !errors.trim().is_empty() {
            answer["stderr"] = json!(toolchain::clip(&errors, 3000));
        }
        Ok(answer)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trace_lines_are_calls_and_returns_by_depth() {
        assert!(is_trace_line("> (fact 2)"));
        assert!(is_trace_line("| | < 1"));
        assert!(is_call_line("| > (fact 1)"));
        assert!(!is_call_line("< 2"));
        assert!(!is_trace_line("hello"));
        assert!(!is_trace_line("> not a call"));
    }

    #[test]
    fn a_runaway_trace_is_kept_to_its_first_lines_and_counted() {
        let mut kept = Kept::new(3);
        kept.push("> (f 1)\n| > (f");
        kept.push(" 0)\n| < 0\n< 0\nplain\n");
        kept.push("> (f 2)");
        kept.finish();
        assert_eq!(kept.text, "> (f 1)\n| > (f 0)\n| < 0\n");
        assert_eq!((kept.lines, kept.calls), (6, 3));
    }

    #[test]
    fn a_name_is_traced_where_the_session_loaded_it() {
        let files = Files::from([
            ("a.puf".to_owned(), "(define x 1)\n(define (f n) n)\n".to_owned()),
            ("b.puf".to_owned(), "(define (f n . rest) n)\n(define (g [n : Int]) : Int n)\n".to_owned()),
        ]);
        let mut view = SessionView::default();
        let (file, form) = definition_of(&files, "f", &view).unwrap();
        assert_eq!((file.as_str(), form.line), ("a.puf", 2));
        view.files.entry("b.puf".into()).or_default().insert(
            "define:f".into(),
            crate::session::Loaded { text: String::new(), by: "buffer", entry: 1 },
        );
        let (file, form) = definition_of(&files, "f", &view).unwrap();
        assert_eq!(file, "b.puf");
        assert!(!traceable(&files[&file], &form), "a rest parameter does not trace");
        let (file, form) = definition_of(&files, "g", &view).unwrap();
        assert!(traceable(&files[&file], &form));
        let (file, form) = definition_of(&files, "x", &view).unwrap();
        assert!(!traceable(&files[&file], &form), "x is no function");
        assert!(valid_name("two words").is_err());
    }
}
