//! What the live session holds of the program: for each file, the
//! top-level forms it loaded and the text each was loaded with, the last
//! result of each expression evaluated from a buffer, the text of each name
//! the prompt defined last (what `,trace` evaluates again), and the
//! observation record (docs/STUDIO.md §3.1, layer 4). A form is current when its text
//! now is the text it was loaded with, stale when it was edited since, and
//! redefined when the prompt gave its name another definition.
//!
//! Forms are keyed as the form scanner keys them (sexp.rs, `--assist
//! forms`): `define:eval-expr`, `define-type:Expr`. An expression is keyed
//! by its text. A `define-type` is loaded with whatever text of it the
//! session's types hold (repl.rs), since every buffer unit carries them.
//!
//! This is session state: a reset, or a session that dies, clears it, and a
//! failed evaluation leaves it as it was.

use crate::sexp::{self, Form};
use crate::toolchain::Files;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};

/// One loaded form: its text as loaded, and what loaded it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Loaded {
    pub text: String,
    /// "buffer" (⌘↵ or `,eval`), "file" (`,load`), "prompt", or "types".
    pub by: &'static str,
    /// The transcript entry that loaded it.
    pub entry: u64,
}

/// What one function received, per the observer: its calls, and per
/// argument the distinct shapes, first seen first (§3.1).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Observed {
    pub function: String,
    pub calls: u64,
    pub args: Vec<Vec<String>>,
}

#[derive(Default)]
pub struct Session {
    /// file -> form key -> how the session has it
    forms: BTreeMap<String, BTreeMap<String, Loaded>>,
    /// file -> an expression's text -> what it evaluated to last
    results: BTreeMap<String, BTreeMap<String, String>>,
    /// name -> the text of its latest definition at the prompt, while no
    /// module's has replaced it: what `,trace` evaluates again.
    prompt: BTreeMap<String, String>,
    /// The observation record as the observer printed it, and parsed.
    pub record: Option<String>,
    pub observed: Vec<Observed>,
}

/// The session as tabs see it: what each file's forms were loaded with,
/// so a tab compares that with the text it shows as it types.
#[derive(Clone, Debug, Default, Serialize)]
pub struct SessionView {
    pub files: BTreeMap<String, BTreeMap<String, Loaded>>,
    pub results: BTreeMap<String, BTreeMap<String, String>>,
    pub observed: Vec<Observed>,
}

/// One form's state in the session.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct FormState {
    pub key: String,
    pub line: usize,
    /// "current", "stale", "redefined", "evaluated", or "absent".
    pub status: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub by: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<String>,
}

/// Whether a form is one the session can hold by name.
pub fn definition(form: &Form) -> bool {
    form.name.is_some() && form.head.as_deref().is_some_and(|head| head.starts_with("define"))
}

/// Whether a form is an expression: not a definition, signature, require,
/// or provide.
pub fn expression(form: &Form) -> bool {
    !definition(form) && !matches!(form.head.as_deref(), Some("require" | "provide" | ":"))
}

impl Session {
    pub fn clear(&mut self) {
        *self = Session::default();
    }

    /// A buffer unit of `file` ran: `text` is its forms as sent (without
    /// the types put ahead of them), and `result` the last value it printed.
    pub fn loaded_buffer(&mut self, file: &str, text: &str, entry: u64, result: Option<String>) {
        let found = sexp::forms(text);
        let forms = self.forms.entry(file.to_owned()).or_default();
        for form in &found {
            if definition(form) && form.head.as_deref() != Some("define-type") {
                forms.insert(form.key(), Loaded { text: text[form.start..form.end].to_owned(), by: "buffer", entry });
                if let Some(name) = &form.name {
                    self.prompt.remove(name);
                }
            }
        }
        // the target is last: an expression's value is its result
        if let (Some(last), Some(result)) = (found.last(), result)
            && expression(last)
        {
            self.results.entry(file.to_owned()).or_default().insert(text[last.start..last.end].to_owned(), result);
        }
    }

    /// The module `file` loaded whole: every form of every file in `closure`,
    /// as `files` held them.
    pub fn loaded_file(&mut self, files: &Files, closure: &[String], entry: u64) {
        for path in closure {
            let Some(text) = files.get(path) else { continue };
            let forms = self.forms.entry(path.clone()).or_default();
            for form in sexp::forms(text).iter().filter(|form| definition(form) && form.head.as_deref() != Some("define-type")) {
                forms.insert(form.key(), Loaded { text: text[form.start..form.end].to_owned(), by: "file", entry });
                if let Some(name) = &form.name {
                    self.prompt.remove(name);
                }
            }
        }
    }

    /// A prompt unit ran: each definition in it is now the session's for
    /// its name, in every file that defines that name.
    pub fn loaded_prompt(&mut self, files: &Files, text: &str, entry: u64) {
        for form in sexp::forms(text).iter().filter(|form| definition(form) && form.head.as_deref() != Some("define-type")) {
            if let Some(name) = &form.name {
                self.prompt.insert(name.clone(), text[form.start..form.end].to_owned());
            }
            let key = form.key();
            for (path, module) in files {
                if sexp::forms(module).iter().any(|f| f.key() == key) {
                    let loaded = Loaded { text: text[form.start..form.end].to_owned(), by: "prompt", entry };
                    self.forms.entry(path.clone()).or_default().insert(key.clone(), loaded);
                }
            }
        }
    }

    /// Every file's loaded forms, the session's types among them.
    pub fn view(&self, files: &Files, types: &[(String, String)]) -> SessionView {
        let mut out = self.forms.clone();
        for (path, text) in files {
            for form in sexp::forms(text).iter().filter(|form| form.head.as_deref() == Some("define-type")) {
                if let Some((_, declared)) = types.iter().find(|(name, _)| Some(name) == form.name.as_ref()) {
                    out.entry(path.clone()).or_default().insert(form.key(), Loaded { text: declared.clone(), by: "types", entry: 0 });
                }
            }
        }
        out.retain(|_, forms| !forms.is_empty());
        SessionView { files: out, results: self.results.clone(), observed: self.observed.clone() }
    }

    /// The state of `form` of `file`, whose text is `text`.
    pub fn state(view: &SessionView, file: &str, text: &str, form: &Form) -> FormState {
        let body = &text[form.start..form.end];
        let mut state = FormState { key: form.key(), line: form.line, status: "absent", by: None, result: None };
        if expression(form) {
            if let Some(result) = view.results.get(file).and_then(|results| results.get(body)) {
                state.status = "evaluated";
                state.result = Some(result.clone());
            }
            return state;
        }
        if let Some(loaded) = view.files.get(file).and_then(|forms| forms.get(&state.key)) {
            state.by = Some(loaded.by);
            state.status = match (loaded.text == body, loaded.by) {
                (true, _) => "current",
                (false, "prompt") => "redefined",
                (false, _) => "stale",
            };
        }
        state
    }

    /// The text of `name`'s definition at the prompt, when that is the
    /// session's latest.
    pub fn prompt_definition(&self, name: &str) -> Option<String> {
        self.prompt.get(name).cloned()
    }

    /// What one function's observations are, if any.
    pub fn observed_of(&self, function: &str) -> Option<&Observed> {
        self.observed.iter().find(|observed| observed.function == function)
    }
}

/// The definitions `target` needs from its module `text`, in source order:
/// those it mentions, and those they mention, transitively, that `wanted`
/// says the session lacks (not loaded, or stale). Types are not among them:
/// every buffer unit carries its module's types.
pub fn needs(text: &str, target: &Form, wanted: &dyn Fn(&Form) -> bool) -> Vec<Form> {
    let all = sexp::forms(text);
    let defines: Vec<&Form> =
        all.iter().filter(|form| definition(form) && form.head.as_deref() != Some("define-type") && form.start != target.start).collect();
    let mut seen: BTreeSet<usize> = BTreeSet::new();
    let mut queue = vec![target.clone()];
    while let Some(form) = queue.pop() {
        let names = sexp::mentions(&text[form.start..form.end]);
        for define in &defines {
            if define.name.as_ref().is_some_and(|name| names.contains(name)) && seen.insert(define.start) {
                queue.push((*define).clone());
            }
        }
    }
    defines.into_iter().filter(|form| seen.contains(&form.start) && wanted(form)).cloned().collect()
}

/// The names a run's output says were referenced before their definition:
/// `puffin runtime error: X: undefined; cannot reference ...`.
pub fn undefined_names(output: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in output.lines() {
        let Some(rest) = line.split("puffin runtime error: ").nth(1) else { continue };
        if let Some((name, why)) = rest.split_once(": undefined;")
            && why.contains("before its definition")
            && !name.contains(' ')
            && !out.iter().any(|known| known == name)
        {
            out.push(name.to_owned());
        }
    }
    out
}

// ---- The observation record ---------------------------------------------------

/// A printed datum: an atom, or a list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Datum {
    Atom(String),
    List(Vec<Datum>),
}

impl std::fmt::Display for Datum {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Datum::Atom(atom) => out.write_str(atom),
            Datum::List(items) => {
                out.write_str("(")?;
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.write_str(" ")?;
                    }
                    write!(out, "{item}")?;
                }
                out.write_str(")")
            }
        }
    }
}

/// Read one datum from printed text (as `display` writes it); a leading
/// quote is dropped.
pub fn read(text: &str) -> Option<Datum> {
    fn datum(chars: &mut std::iter::Peekable<std::str::Chars>) -> Option<Datum> {
        while chars.peek().is_some_and(|c| c.is_whitespace() || *c == '\'') {
            chars.next();
        }
        match chars.peek()? {
            '(' | '[' => {
                chars.next();
                let mut items = Vec::new();
                loop {
                    while chars.peek().is_some_and(|c| c.is_whitespace()) {
                        chars.next();
                    }
                    match chars.peek()? {
                        ')' | ']' => {
                            chars.next();
                            return Some(Datum::List(items));
                        }
                        _ => items.push(datum(chars)?),
                    }
                }
            }
            ')' | ']' => None,
            _ => {
                let mut atom = String::new();
                while let Some(&c) = chars.peek() {
                    if c.is_whitespace() || "()[]".contains(c) {
                        break;
                    }
                    atom.push(c);
                    chars.next();
                }
                Some(Datum::Atom(atom))
            }
        }
    }
    datum(&mut text.chars().peekable())
}

/// The record `((f CALLS ((shape ...) ...)) ...)`, function by function.
pub fn parse_record(text: &str) -> Vec<Observed> {
    let Some(Datum::List(entries)) = read(text) else { return Vec::new() };
    let mut out: Vec<Observed> = entries
        .iter()
        .filter_map(|entry| {
            let Datum::List(parts) = entry else { return None };
            let [Datum::Atom(function), Datum::Atom(calls), Datum::List(args)] = parts.as_slice() else { return None };
            let args = args
                .iter()
                .map(|shapes| match shapes {
                    Datum::List(shapes) => shapes.iter().map(Datum::to_string).collect(),
                    _ => Vec::new(),
                })
                .collect();
            Some(Observed { function: function.clone(), calls: calls.parse().ok()?, args })
        })
        .collect();
    out.sort_by(|a, b| a.function.cmp(&b.function));
    out
}

/// One line of what was observed of `function`, for the assistant:
/// `eval-expr e: (list add 3), Int over 12 calls`.
pub fn summary(observed: &Observed, params: &[String], patterns: &[Vec<String>]) -> String {
    let args: Vec<String> = observed
        .args
        .iter()
        .enumerate()
        .map(|(i, shapes)| {
            let name = params.get(i).cloned().unwrap_or_else(|| format!("#{i}"));
            let shown = patterns.get(i).filter(|patterns| !patterns.is_empty()).unwrap_or(shapes);
            format!("{name}: {}", shown.join(", "))
        })
        .collect();
    format!("{} {} over {} call{}", observed.function, args.join("; "), observed.calls, if observed.calls == 1 { "" } else { "s" })
}

#[cfg(test)]
mod tests {
    use super::*;

    const MODULE: &str = "\
(define-type Expr (Num Int) (Add Expr Expr))
(define (helper x) (* x 2))
(define (eval-expr [e : Expr]) : Int
  (match e [(Num n) (helper n)] [(Add a b) (+ (eval-expr a) (eval-expr b))]))
(define example (Add (Num 2) (Num 3)))
(define unused 'helper)
(eval-expr example)
";

    fn form(key: &str) -> Form {
        sexp::forms(MODULE).into_iter().find(|form| form.key() == key || MODULE[form.start..form.end] == *key).unwrap()
    }

    #[test]
    fn a_form_needs_what_it_mentions_transitively_in_source_order() {
        let target = form("(eval-expr example)");
        let names = |forms: Vec<Form>| forms.into_iter().map(|f| f.name.unwrap()).collect::<Vec<_>>();
        assert_eq!(names(needs(MODULE, &target, &|_| true)), ["helper", "eval-expr", "example"]);
        // what the session has current is not loaded again
        let lacking = |f: &Form| f.name.as_deref() != Some("eval-expr");
        assert_eq!(names(needs(MODULE, &target, &lacking)), ["helper", "example"]);
        // a define is never its own need; a quoted name is no mention
        assert_eq!(names(needs(MODULE, &form("define:eval-expr"), &|_| true)), ["helper"]);
        assert!(needs(MODULE, &form("define:unused"), &|_| true).is_empty());
    }

    #[test]
    fn forms_are_current_until_edited_and_types_come_from_the_session() {
        let mut session = Session::default();
        let files = Files::from([("m.puf".to_owned(), MODULE.to_owned())]);
        session.loaded_buffer("m.puf", "(define (helper x) (* x 2))\n(eval-expr example)", 4, Some("10".into()));
        let types = vec![("Expr".to_owned(), "(define-type Expr (Num Int) (Add Expr Expr))".to_owned())];
        let view = session.view(&files, &types);
        let state = |text: &str, key: &str| {
            let found = sexp::forms(text).into_iter().find(|f| f.key() == key || text[f.start..f.end] == *key).unwrap();
            Session::state(&view, "m.puf", text, &found)
        };
        assert_eq!(state(MODULE, "define:helper").status, "current");
        assert_eq!(state(MODULE, "define-type:Expr").status, "current");
        assert_eq!(state(MODULE, "define:example").status, "absent");
        let evaluated = state(MODULE, "(eval-expr example)");
        assert_eq!((evaluated.status, evaluated.result.as_deref()), ("evaluated", Some("10")));
        let edited = MODULE.replace("(* x 2)", "(* x 3)").replace("(Add Expr Expr))", "(Add Expr Expr) (Neg Expr))");
        assert_eq!(state(&edited, "define:helper").status, "stale");
        assert_eq!(state(&edited, "define-type:Expr").status, "stale");
        // the prompt redefines a name the module defines
        session.loaded_prompt(&files, "(define (helper x) x)", 5);
        let view = session.view(&files, &types);
        let helper = sexp::forms(MODULE).into_iter().find(|f| f.key() == "define:helper").unwrap();
        assert_eq!(Session::state(&view, "m.puf", MODULE, &helper).status, "redefined");
        session.loaded_file(&files, &["m.puf".to_owned()], 6);
        let view = session.view(&files, &types);
        assert_eq!(Session::state(&view, "m.puf", MODULE, &helper).status, "current");
        session.clear();
        assert!(session.view(&files, &[]).files.is_empty());
    }

    #[test]
    fn undefined_names_come_from_the_runtime_error() {
        let out = "puffin runtime error: helper: undefined; cannot reference an identifier before its definition\n";
        assert_eq!(undefined_names(out), ["helper"]);
        assert!(undefined_names("puffin runtime error: car: contract violation\n").is_empty());
    }

    #[test]
    fn the_record_reads_function_by_function() {
        let printed = "((g 1 (((adt A)) ((adt B)))) (eval-expr 2 (((list add 3) (sym x)) (Int Pair) (Str Bool))))";
        let record = parse_record(printed);
        assert_eq!(record.len(), 2);
        assert_eq!(record[0].function, "eval-expr");
        assert_eq!(record[0].calls, 2);
        assert_eq!(record[0].args[0], ["(list add 3)", "(sym x)"]);
        assert_eq!(record[1].args, [vec!["(adt A)".to_owned()], vec!["(adt B)".to_owned()]]);
        assert!(parse_record("()").is_empty());
        assert!(parse_record("'()").is_empty());
        let line = summary(&record[0], &["e".into()], &[vec!["`(add ,a ,b)".into()]]);
        assert_eq!(line, "eval-expr e: `(add ,a ,b); #1: Int, Pair; #2: Str, Bool over 2 calls");
    }
}
