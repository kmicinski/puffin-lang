//! The module board (docs/PLANNING.md): the program as module cards
//! showing ML-style signatures, bodies opaque until asked for, arranged
//! to keep as much of the design on screen as possible.
//!
//! Two halves:
//! - the **outline**, computed from the text on every change: each
//!   module's requires and provides, and each top-level definition with
//!   its kind, its signature rendered ML-style from `(: name τ)`
//!   declarations and parameter annotations, its holes (a body that is
//!   just `??` is *opaque*: planned, not written), the comment above it,
//!   and the other top-level names it uses -- the dependency graph the
//!   slicer walks (`slice`);
//! - the **board**, the view: which module cards are out, where, which
//!   definitions are open (body shown) or hidden, whether the studio is
//!   in plan mode, the questions asked and the focus a question set.
//!   It is JSON the page mostly owns, kept in `.puffin/board.json` (so it
//!   is committed with the project's history) and broadcast as
//!   `Event::Board` with the outline whenever either changes.

use crate::sexp;
use crate::studio::{Event, Studio};
use crate::toolchain::Files;
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use std::time::Duration;

pub const BOARD_FILE: &str = ".puffin/board.json";
/// Files the studio keeps for itself: never cards.
const HIDDEN: [&str; 1] = ["prop.puf"];

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Item {
    pub name: String,
    /// "fun", "val", "type", "alias", "grammar".
    pub kind: String,
    pub line: usize,
    pub end_line: usize,
    /// The ML-style signature: `val step : State -> State`.
    pub sig: String,
    pub holes: usize,
    /// The body is just `??`: planned, not written.
    pub opaque: bool,
    /// The comment lines right above it, without their `;;`.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub doc: String,
    /// The other top-level names (of any module) it mentions.
    pub uses: Vec<String>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Module {
    pub path: String,
    pub requires: Vec<String>,
    /// Its provide list; None: everything is provided.
    pub provides: Option<Vec<String>>,
    pub items: Vec<Item>,
    /// Top-level expressions that are not definitions (effects, checks).
    pub effects: usize,
}

// ---- A small reader: enough of an s-expression to render signatures ---------

#[derive(Clone, Debug, PartialEq)]
enum T {
    Atom(String),
    List(Vec<T>),
}

fn read_all(text: &str) -> Vec<T> {
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    let mut out = Vec::new();
    while let Some(t) = read(&chars, &mut i) {
        out.push(t);
    }
    out
}

fn read(c: &[char], i: &mut usize) -> Option<T> {
    loop {
        while *i < c.len() && c[*i].is_whitespace() {
            *i += 1;
        }
        if *i < c.len() && c[*i] == ';' {
            while *i < c.len() && c[*i] != '\n' {
                *i += 1;
            }
            continue;
        }
        break;
    }
    if *i >= c.len() {
        return None;
    }
    match c[*i] {
        '(' | '[' => {
            *i += 1;
            let mut items = Vec::new();
            loop {
                while *i < c.len() && c[*i].is_whitespace() {
                    *i += 1;
                }
                if *i >= c.len() {
                    return Some(T::List(items));
                }
                if c[*i] == ')' || c[*i] == ']' {
                    *i += 1;
                    return Some(T::List(items));
                }
                match read(c, i) {
                    Some(t) => items.push(t),
                    None => return Some(T::List(items)),
                }
            }
        }
        ')' | ']' => {
            *i += 1;
            read(c, i)
        }
        '"' => {
            let start = *i;
            *i += 1;
            while *i < c.len() && c[*i] != '"' {
                if c[*i] == '\\' {
                    *i += 1;
                }
                *i += 1;
            }
            *i = (*i + 1).min(c.len());
            Some(T::Atom(c[start..*i].iter().collect()))
        }
        '\'' | '`' | ',' => {
            let prefix = c[*i];
            *i += 1;
            let inner = read(c, i)?;
            Some(T::List(vec![T::Atom(prefix.to_string()), inner]))
        }
        _ => {
            let start = *i;
            while *i < c.len() && !c[*i].is_whitespace() && !"()[]\";".contains(c[*i]) {
                *i += 1;
            }
            Some(T::Atom(c[start..*i].iter().collect()))
        }
    }
}

fn atom(t: &T) -> Option<&str> {
    match t {
        T::Atom(a) => Some(a),
        T::List(_) => None,
    }
}

/// Source-like text of a tree, on one line.
fn source(t: &T) -> String {
    match t {
        T::Atom(a) => a.clone(),
        T::List(items) if items.len() == 2 && matches!(atom(&items[0]), Some("'" | "`" | ",")) => format!("{}{}", atom(&items[0]).unwrap(), source(&items[1])),
        T::List(items) => format!("({})", items.iter().map(source).collect::<Vec<_>>().join(" ")),
    }
}

/// A type, ML-style: `(-> A B C)` is `A * B -> C`, `(List a)` is `List a`.
fn render(t: &T) -> String {
    render_at(t, false)
}

fn render_at(t: &T, nested: bool) -> String {
    let wrap = |s: String| if nested { format!("({s})") } else { s };
    match t {
        T::Atom(a) => a.clone(),
        T::List(items) if items.is_empty() => "()".to_owned(),
        T::List(items) => match atom(&items[0]) {
            Some("->") if items.len() >= 2 => {
                let args = &items[1..items.len() - 1];
                let result = render_at(&items[items.len() - 1], false);
                let from = if args.is_empty() { "unit".to_owned() } else { args.iter().map(|a| render_at(a, true)).collect::<Vec<_>>().join(" * ") };
                wrap(format!("{from} -> {result}"))
            }
            Some("->*") if items.len() == 4 => {
                let fixed = match &items[1] {
                    T::List(xs) => xs.iter().map(|a| render_at(a, true)).collect::<Vec<_>>(),
                    other => vec![render_at(other, true)],
                };
                let mut from = fixed;
                from.push(format!("{}...", render_at(&items[2], true)));
                wrap(format!("{} -> {}", from.join(" * "), render_at(&items[3], false)))
            }
            Some(_) => wrap(items.iter().map(|a| render_at(a, true)).collect::<Vec<_>>().join(" ")),
            None => wrap(items.iter().map(|a| render_at(a, true)).collect::<Vec<_>>().join(" ")),
        },
    }
}

// ---- The outline ------------------------------------------------------------------

pub fn outline(files: &Files) -> Vec<Module> {
    // every top-level name of the program, for `uses`
    let mut names: BTreeSet<String> = BTreeSet::new();
    for (path, text) in files {
        if HIDDEN.contains(&path.as_str()) {
            continue;
        }
        for form in sexp::forms(text) {
            if let (Some(name), true) = (&form.name, form.head.as_deref().is_some_and(|h| h.starts_with("define"))) {
                names.insert(name.clone());
            }
        }
    }
    files
        .iter()
        .filter(|(path, _)| !HIDDEN.contains(&path.as_str()) && (path.ends_with(".puf") || path.ends_with(".scm")))
        .map(|(path, text)| module(path, text, &names))
        .collect()
}

fn module(path: &str, text: &str, names: &BTreeSet<String>) -> Module {
    let forms = sexp::forms(text);
    let lines: Vec<&str> = text.lines().collect();
    // (: name τ) declarations, by name
    let mut declared: BTreeMap<String, T> = BTreeMap::new();
    let mut provides: Option<Vec<String>> = None;
    for form in &forms {
        let Some(T::List(items)) = read_all(&text[form.start..form.end]).into_iter().next() else { continue };
        match form.head.as_deref() {
            Some(":") if items.len() == 3 => {
                if let Some(name) = atom(&items[1]) {
                    declared.insert(name.to_owned(), items[2].clone());
                }
            }
            Some("provide") => {
                let list = provides.get_or_insert_with(Vec::new);
                let mut skip = false;
                for item in &items[1..] {
                    match atom(item) {
                        Some(k) if k.starts_with("#:") => skip = true,
                        Some(a) if !skip => list.push(a.to_owned()),
                        _ => skip = false,
                    }
                }
            }
            _ => {}
        }
    }
    let mut items = Vec::new();
    let mut effects = 0;
    for form in &forms {
        let body = &text[form.start..form.end];
        let tree = read_all(body).into_iter().next();
        let head = form.head.as_deref().unwrap_or("");
        // a declaration is part of its definition's signature
        if matches!(head, ":" | "#%prelude:" | "provide" | "require") {
            continue;
        }
        // sexp::forms names any form by its second atom: only define* forms define
        let name = form.name.clone().filter(|_| head.starts_with("define"));
        let Some(name) = name else {
            if head != "foreign" {
                effects += 1;
            }
            continue;
        };
        let (kind, sig, opaque) = match (head, &tree) {
            ("define", Some(T::List(parts))) => function_or_value(&name, parts, declared.get(&name)),
            ("define-type", Some(T::List(parts))) => ("type".to_owned(), type_sig(parts), false),
            ("define-type-alias", Some(T::List(parts))) if parts.len() >= 3 => {
                ("alias".to_owned(), format!("type {} = {}", render(&parts[1]), render(&parts[2])), false)
            }
            ("define-grammar", Some(T::List(parts))) => ("grammar".to_owned(), grammar_sig(parts), false),
            _ => ("val".to_owned(), format!("val {name}"), false),
        };
        let uses: Vec<String> = sexp::mentions(body).into_iter().filter(|n| n != &name && names.contains(n)).collect();
        // the comment lines right above
        let mut doc = Vec::new();
        let mut at = form.line.saturating_sub(1);
        while at >= 1 {
            let line = lines.get(at - 1).map(|l| l.trim()).unwrap_or("");
            // a one-line (: name τ) right above belongs to it; the comment may sit over that
            if doc.is_empty() && line.starts_with("(: ") && line.ends_with(')') {
                at -= 1;
                continue;
            }
            match line.strip_prefix(";;") {
                Some(rest) => doc.push(rest.trim_start_matches(';').trim().to_owned()),
                None => break,
            }
            at -= 1;
        }
        doc.reverse();
        items.push(Item {
            name,
            kind,
            line: form.line,
            end_line: sexp::line_of(text, form.end.saturating_sub(1)),
            sig,
            holes: sexp::holes(body).len(),
            opaque,
            doc: doc.join(" "),
            uses,
        });
    }
    // the spec: one row a property, its English as the signature
    if path == crate::props::PROPERTIES {
        let forms = sexp::forms(text);
        items = crate::props::declared(text)
            .into_iter()
            .map(|p| {
                let form = forms.iter().find(|f| f.line == p.line);
                let body = form.map(|f| &text[f.start..f.end]).unwrap_or("");
                Item {
                    sig: if p.statement.is_empty() { p.name.clone() } else { p.statement.clone() },
                    kind: "property".to_owned(),
                    line: p.line,
                    end_line: form.map(|f| sexp::line_of(text, f.end.saturating_sub(1))).unwrap_or(p.line),
                    holes: 0,
                    opaque: false,
                    doc: String::new(),
                    uses: sexp::mentions(body).into_iter().filter(|n| names.contains(n)).collect(),
                    name: p.name,
                }
            })
            .collect();
        effects = 0;
    }
    Module { path: path.to_owned(), requires: sexp::requires(text), provides, items, effects }
}

/// `(define (f a [b : T]) : R body)` or `(define x e)`.
fn function_or_value(name: &str, parts: &[T], declared: Option<&T>) -> (String, String, bool) {
    match parts.get(1) {
        Some(T::List(head)) => {
            let mut rest = 2;
            let mut result = "_".to_owned();
            if parts.get(2).and_then(atom) == Some(":") && parts.len() > 3 {
                result = render(&parts[3]);
                rest = 4;
            }
            let body = &parts[rest.min(parts.len())..];
            let opaque = body.len() == 1 && atom(&body[0]) == Some("??");
            let sig = match declared {
                Some(t) => format!("val {name} : {}", render(t)),
                None => {
                    let mut from = Vec::new();
                    let mut params = head[1..].iter();
                    while let Some(p) = params.next() {
                        match p {
                            T::Atom(a) if a == "." => {
                                if let Some(T::Atom(r)) = params.next() {
                                    from.push(format!("{r}..."));
                                }
                            }
                            T::Atom(a) => from.push(a.clone()),
                            T::List(xs) if xs.len() == 3 && atom(&xs[1]) == Some(":") => from.push(render_at(&xs[2], true)),
                            other => from.push(source(other)),
                        }
                    }
                    let from = if from.is_empty() { "unit".to_owned() } else { from.join(" * ") };
                    format!("val {name} : {from} -> {result}")
                }
            };
            ("fun".to_owned(), sig, opaque)
        }
        _ => {
            let opaque = parts.len() == 3 && atom(&parts[2]) == Some("??");
            // (define x : T e)
            let annotated = (parts.get(2).and_then(atom) == Some(":")).then(|| parts.get(3).map(render)).flatten();
            let sig = match (declared, annotated) {
                (Some(t), _) => format!("val {name} : {}", render(t)),
                (None, Some(t)) => format!("val {name} : {t}"),
                (None, None) => format!("val {name}"),
            };
            ("val".to_owned(), sig, opaque)
        }
    }
}

/// `type Expr = Num of Int | Add of Expr * Expr`
fn type_sig(parts: &[T]) -> String {
    let head = parts.get(1).map(|t| render(t)).unwrap_or_default();
    let ctors: Vec<String> = parts[2.min(parts.len())..]
        .iter()
        .map(|c| match c {
            T::Atom(a) => a.clone(),
            T::List(xs) if xs.len() == 1 => source(&xs[0]),
            T::List(xs) => format!("{} of {}", source(&xs[0]), xs[1..].iter().map(|f| render_at(f, true)).collect::<Vec<_>>().join(" * ")),
        })
        .collect();
    if ctors.is_empty() { format!("type {head}") } else { format!("type {head} = {}", ctors.join(" | ")) }
}

/// `grammar Expr = Int | Sym | (+ Expr Expr) | ...`
fn grammar_sig(parts: &[T]) -> String {
    let head = parts.get(1).map(|t| render(t)).unwrap_or_default();
    let mut prods = Vec::new();
    let mut i = 2;
    while i < parts.len() {
        if atom(&parts[i]).is_some_and(|a| a.starts_with("#:")) {
            i += 2;
            continue;
        }
        prods.push(source(&parts[i]));
        i += 1;
    }
    format!("grammar {head} = {}", prods.join(" | "))
}

// ---- Designing on the board: a signature becomes a planned definition ------------

/// A definition from what the author typed on a card, in the board's own
/// ML style, as Puffin text with its body a typed hole:
///   `val alloc : Store -> Addr`      (: alloc (-> Store Addr))
///                                    (define (alloc store) ??)
///   `step : State * Kont -> State`   (parameters named after their types)
///   `val limit : Int`                (: limit Int) (define limit ??)
///   `type Kont = Done | Arg of Expr * Env`
///                                    (define-type Kont (Done) (Arg Expr Env))
///   `type Option a = None | Some of a`
///   `type Env = Hash Var Addr`       (a type without constructors: an alias)
/// Types: `A -> B` is a function, `A * B -> C` takes two arguments, `unit
/// -> C` none; `List Int` is `(List Int)`; parentheses group.
pub fn define_from_signature(text: &str) -> Result<String, String> {
    let text = text.trim().trim_end_matches(';');
    if let Some(rest) = text.strip_prefix("type ") {
        let (head, body) = rest.split_once('=').ok_or("a type needs `= ...`: type T = A | B of Int")?;
        let head_words: Vec<&str> = head.split_whitespace().collect();
        let name = *head_words.first().ok_or("the type needs a name")?;
        check_name(name)?;
        let head = if head_words.len() == 1 { name.to_owned() } else { format!("({})", head_words.join(" ")) };
        let alternatives: Vec<&str> = body.split('|').map(str::trim).filter(|a| !a.is_empty()).collect();
        // a capitalized single word followed by type words is a constructor
        // only when there are alternatives or `of`; `type Env = Hash Var Addr` is an alias
        let constructors = alternatives.len() > 1 || body.contains(" of ");
        if !constructors {
            let ty = ml_type(body.trim())?;
            return Ok(format!("(define-type-alias {head} {ty})"));
        }
        let mut ctors = Vec::new();
        for alt in alternatives {
            let (ctor, fields) = match alt.split_once(" of ") {
                Some((c, f)) => (c.trim(), f.split('*').map(|t| ml_type(t.trim())).collect::<Result<Vec<_>, _>>()?),
                None => (alt, Vec::new()),
            };
            check_name(ctor)?;
            ctors.push(if fields.is_empty() { format!("({ctor})") } else { format!("({ctor} {})", fields.join(" ")) });
        }
        return Ok(format!("(define-type {head}\n  {})", ctors.join("\n  ")));
    }
    let text = text.strip_prefix("val ").unwrap_or(text);
    let (name, ty) = text.split_once(':').ok_or("write it as `name : Type -> Type` (or `type T = ...`)")?;
    let name = name.trim();
    check_name(name)?;
    let ty = ty.trim();
    if ty.is_empty() {
        return Err(format!("{name} needs a type after the colon"));
    }
    let parsed = MlType::parse(ty)?;
    match &parsed {
        MlType::Arrow(args, _) => {
            let mut used: Vec<String> = Vec::new();
            let params: Vec<String> = args
                .iter()
                .map(|a| {
                    let base = a.param_name();
                    let mut name = base.clone();
                    let mut n = 2;
                    while used.contains(&name) {
                        name = format!("{base}{n}");
                        n += 1;
                    }
                    used.push(name.clone());
                    name
                })
                .collect();
            let head = if params.is_empty() { format!("({name})") } else { format!("({name} {})", params.join(" ")) };
            Ok(format!("(: {name} {})\n(define {head} ??)", parsed.puffin()))
        }
        _ => Ok(format!("(: {name} {})\n(define {name} ??)", parsed.puffin())),
    }
}

fn check_name(name: &str) -> Result<(), String> {
    if name.is_empty() || name.chars().any(|c| c.is_whitespace() || "()[]{}\";'`,".contains(c)) || name.parse::<i64>().is_ok() {
        return Err(format!("`{name}` is not a name"));
    }
    Ok(())
}

fn ml_type(text: &str) -> Result<String, String> {
    Ok(MlType::parse(text)?.puffin())
}

#[derive(Debug, Clone, PartialEq)]
enum MlType {
    Name(String),
    App(Vec<MlType>),
    Arrow(Vec<MlType>, Box<MlType>),
}

impl MlType {
    fn parse(text: &str) -> Result<MlType, String> {
        let tokens = ml_tokens(text);
        let mut at = 0;
        let ty = Self::arrow(&tokens, &mut at)?;
        if at != tokens.len() {
            return Err(format!("could not read the type `{text}` past `{}`", tokens[at..].join(" ")));
        }
        Ok(ty)
    }

    // arrow := product ('->' arrow)?   product := app ('*' app)*
    fn arrow(t: &[String], at: &mut usize) -> Result<MlType, String> {
        let mut args = vec![Self::app(t, at)?];
        while t.get(*at).map(String::as_str) == Some("*") {
            *at += 1;
            args.push(Self::app(t, at)?);
        }
        if t.get(*at).map(String::as_str) == Some("->") {
            *at += 1;
            let result = Self::arrow(t, at)?;
            if args.len() == 1 && args[0] == MlType::Name("unit".into()) {
                args.clear();
            }
            return Ok(MlType::Arrow(args, Box::new(result)));
        }
        if args.len() > 1 {
            // a bare product: a pair type, Puffin's Pairof for two
            return Ok(MlType::App(std::iter::once(MlType::Name("Pairof".into())).chain(args).collect()));
        }
        Ok(args.pop().unwrap())
    }

    fn app(t: &[String], at: &mut usize) -> Result<MlType, String> {
        let mut parts = Vec::new();
        while let Some(tok) = t.get(*at) {
            match tok.as_str() {
                "(" => {
                    *at += 1;
                    let inner = Self::arrow(t, at)?;
                    if t.get(*at).map(String::as_str) != Some(")") {
                        return Err("a parenthesis is not closed".to_owned());
                    }
                    *at += 1;
                    parts.push(inner);
                }
                ")" | "*" | "->" => break,
                name => {
                    parts.push(MlType::Name(name.to_owned()));
                    *at += 1;
                }
            }
        }
        match parts.len() {
            0 => Err("a type is missing".to_owned()),
            1 => Ok(parts.pop().unwrap()),
            _ => Ok(MlType::App(parts)),
        }
    }

    fn puffin(&self) -> String {
        match self {
            MlType::Name(n) => n.clone(),
            MlType::App(parts) => format!("({})", parts.iter().map(MlType::puffin).collect::<Vec<_>>().join(" ")),
            MlType::Arrow(args, result) => {
                let mut all: Vec<String> = args.iter().map(MlType::puffin).collect();
                all.push(result.puffin());
                format!("(-> {})", all.join(" "))
            }
        }
    }

    /// A parameter named after its type: Store -> store, (List Int) ->
    /// list, a function -> f, `_` -> x.
    fn param_name(&self) -> String {
        match self {
            MlType::Name(n) if n == "_" => "x".to_owned(),
            MlType::Name(n) => {
                let lower: String = n.chars().filter(|c| c.is_alphanumeric() || *c == '-').collect::<String>().to_lowercase();
                if lower.is_empty() || lower.len() == 1 && !n.chars().next().is_some_and(char::is_uppercase) { "x".to_owned() } else { lower }
            }
            MlType::App(parts) => parts[0].param_name(),
            MlType::Arrow(..) => "f".to_owned(),
        }
    }
}

fn ml_tokens(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut word = String::new();
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0;
    let flush = |word: &mut String, out: &mut Vec<String>| {
        if !word.is_empty() {
            out.push(std::mem::take(word));
        }
    };
    while i < chars.len() {
        let c = chars[i];
        if c == '-' && chars.get(i + 1) == Some(&'>') {
            flush(&mut word, &mut out);
            out.push("->".to_owned());
            i += 2;
            continue;
        }
        if c.is_whitespace() {
            flush(&mut word, &mut out);
        } else if "()*".contains(c) {
            flush(&mut word, &mut out);
            out.push(c.to_string());
        } else {
            word.push(c);
        }
        i += 1;
    }
    flush(&mut word, &mut out);
    out
}

impl Studio {
    /// The author typed a signature on `file`'s card: append the planned
    /// definition to the module (and its name to the provide list, if the
    /// module has one). Answers the definition's name.
    pub fn board_define(&self, file: &str, text: &str) -> Result<String, String> {
        let current = self.text_of(file).ok_or_else(|| format!("there is no module {file}"))?;
        let code = define_from_signature(text)?;
        let defined = read_all(&code)
            .iter()
            .find_map(|t| match t {
                T::List(items) if items.first().and_then(atom).is_some_and(|h| h.starts_with("define")) => match items.get(1) {
                    Some(T::Atom(a)) => Some(a.clone()),
                    Some(T::List(h)) => h.first().and_then(atom).map(str::to_owned),
                    None => None,
                },
                _ => None,
            })
            .unwrap_or_default();
        let names: BTreeSet<String> = sexp::forms(&current).into_iter().filter(|f| f.head.as_deref().is_some_and(|h| h.starts_with("define"))).filter_map(|f| f.name).collect();
        if names.contains(&defined) {
            return Err(format!("{file} already defines {defined}"));
        }
        let mut next = current.trim_end().to_owned();
        // a provide list names what the module offers: the new definition too
        if let Some(form) = sexp::forms(&current).into_iter().find(|f| f.head.as_deref() == Some("provide")) {
            let provide = &current[form.start..form.end];
            if !provide.contains("#:") && !provide.split(|c: char| c.is_whitespace() || c == '(' || c == ')').any(|w| w == defined) {
                let extended = format!("{} {defined})", provide.trim_end_matches(')'));
                next = next.replacen(provide, &extended, 1);
            }
        }
        if !next.is_empty() {
            next.push_str("\n\n");
        }
        next.push_str(&code);
        next.push('\n');
        self.replace(file, next, "board", &format!("plan {defined}"));
        Ok(defined)
    }
}

// ---- Slicing: what a question about some definitions needs on screen ------------

/// The definitions to show for a question about `about` (names): those
/// themselves; what they use (their signatures are the context); what
/// uses them (the callers that constrain them) -- each one step out --
/// and the properties that mention any of them. Returns (file, name)
/// pairs, `about` first.
pub fn slice(outline: &[Module], about: &[String], properties: &str) -> Vec<(String, String)> {
    let mut chosen: Vec<String> = Vec::new();
    let add = |name: &str, chosen: &mut Vec<String>| {
        if !chosen.iter().any(|n| n == name) {
            chosen.push(name.to_owned());
        }
    };
    let all: Vec<(&Module, &Item)> = outline.iter().flat_map(|m| m.items.iter().map(move |i| (m, i))).collect();
    for name in about {
        add(name, &mut chosen);
    }
    for name in about {
        if let Some((_, item)) = all.iter().find(|(_, i)| &i.name == name) {
            for used in &item.uses {
                add(used, &mut chosen);
            }
        }
        for (_, item) in all.iter().filter(|(_, i)| i.uses.contains(name)) {
            add(&item.name, &mut chosen);
        }
    }
    let mut out: Vec<(String, String)> =
        chosen.iter().filter_map(|name| all.iter().find(|(_, i)| &i.name == name).map(|(m, i)| (m.path.clone(), i.name.clone()))).collect();
    // properties mentioning them, by name
    for (line, statement) in property_lines(properties) {
        if about.iter().any(|name| statement.contains(name.as_str())) {
            out.push((crate::props::PROPERTIES.to_owned(), format!("@{line}")));
        }
    }
    out
}

/// (line, text) of each property form in properties.puf.
fn property_lines(text: &str) -> Vec<(usize, String)> {
    sexp::forms(text)
        .into_iter()
        .filter(|f| matches!(f.head.as_deref(), Some("check-property" | "check-example")))
        .map(|f| (f.line, text[f.start..f.end].to_owned()))
        .collect()
}

// ---- The board's state, and the studio's side of it ------------------------------

pub fn empty() -> Value {
    json!({ "view": "editor", "mode": "build", "cards": [], "focus": null, "questions": [], "notes": [] })
}

impl Studio {
    pub fn load_board(&self) -> Value {
        let path = self.directory.join(BOARD_FILE);
        let mut board = std::fs::read_to_string(path).ok().and_then(|text| serde_json::from_str::<Value>(&text).ok()).filter(Value::is_object).unwrap_or_else(empty);
        for (key, default) in empty().as_object().unwrap() {
            if board.get(key).is_none() {
                board[key] = default.clone();
            }
        }
        board
    }

    /// The board and the outline, as tabs are sent them.
    pub fn board_view(&self) -> Value {
        let board = self.board.lock().expect("board lock").clone();
        json!({ "board": board, "outline": outline(&self.files()) })
    }

    pub fn board(&self) -> Value {
        self.board.lock().expect("board lock").clone()
    }

    /// Replace the board (from a tab, or the studio's own change), keep
    /// it on disk, and tell every tab.
    pub fn set_board(&self, board: Value) {
        if !board.is_object() {
            return;
        }
        {
            let mut current = self.board.lock().expect("board lock");
            if *current == board {
                return;
            }
            *current = board.clone();
        }
        let path = self.directory.join(BOARD_FILE);
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(&path, serde_json::to_string_pretty(&board).unwrap_or_default() + "\n");
        self.publish_board();
    }

    /// Change the board with `f` (the studio's own arrangements).
    pub fn update_board(&self, f: impl FnOnce(&mut Value)) {
        let mut board = self.board();
        f(&mut board);
        self.set_board(board);
    }

    pub fn publish_board(&self) {
        let view = self.board_view();
        self.publish(Event::Board { board: view["board"].clone(), outline: view["outline"].clone() });
    }

    /// Send the outline again once edits settle.
    pub fn watch_board(self: &Arc<Self>) {
        let studio = self.clone();
        let mut events = self.subscribe();
        tokio::spawn(async move {
            let mut last: Option<Value> = None;
            loop {
                let changed = match events.recv().await {
                    Ok(Event::Text { .. } | Event::Files { .. }) => true,
                    Ok(_) => false,
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => true,
                    Err(_) => return,
                };
                if !changed {
                    continue;
                }
                // settle: drain what arrives in the next moment
                tokio::time::sleep(Duration::from_millis(250)).await;
                while let Ok(_) = events.try_recv() {}
                let outline = json!(outline(&studio.files()));
                if last.as_ref() != Some(&outline) {
                    last = Some(outline);
                    studio.publish_board();
                }
            }
        });
    }
}

// ---- Arranging: what the voice router and the builder ask of the board ----------

impl Studio {
    /// Do one arrangement (voice.rs routes "hide the store", "just show
    /// step", "what does step need", "put machine next to store", ...).
    /// `a` is { action, names: [definition], modules: [path], near, side }.
    /// Answers a few words for the caption, or why it could not.
    pub fn arrange(&self, a: &Value) -> Result<String, String> {
        let action = a["action"].as_str().unwrap_or("none");
        let strings = |key: &str| -> Vec<String> { a[key].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(|s| s.trim().to_owned())).filter(|s| !s.is_empty()).collect() };
        let names = strings("names");
        let outline = outline(&self.files());
        let found = locate(&outline, &names);
        let module_of = |name: &str| -> Option<String> {
            let want = name.trim_end_matches(".puf");
            outline.iter().map(|m| m.path.clone()).find(|p| p.trim_end_matches(".puf") == want || p.trim_end_matches(".puf").ends_with(&format!("/{want}")))
        };
        let modules: Vec<String> = strings("modules").iter().filter_map(|m| module_of(m)).collect();
        let need = |what: &str, empty: bool| if empty { Err(format!("I couldn't find {what} to {action}.")) } else { Ok(()) };
        let mut board = self.board();
        let said = match action {
            "show-board" => {
                board["view"] = json!("board");
                "The board.".to_owned()
            }
            "show-editor" => {
                board["view"] = json!("editor");
                String::new()
            }
            "plan-mode" => {
                board["mode"] = json!("plan");
                "Plan mode: signatures first, bodies left as holes.".to_owned()
            }
            "build-mode" => {
                board["mode"] = json!("build");
                "Build mode.".to_owned()
            }
            "open" | "close" | "hide" | "unhide" => {
                need("those definitions", found.is_empty())?;
                for (file, name) in &found {
                    let card = card_mut(&mut board, file);
                    let (list, add) = match action {
                        "open" => ("open", true),
                        "close" => ("open", false),
                        "hide" => ("hidden", true),
                        _ => ("hidden", false),
                    };
                    set_member(card, list, name, add);
                    match action {
                        "open" | "unhide" => set_member(card, "pinned", name, true),
                        "hide" => {
                            set_member(card, "open", name, false);
                            set_member(card, "pinned", name, false);
                        }
                        _ => {}
                    }
                }
                board["view"] = json!("board");
                String::new()
            }
            "only" | "slice" => {
                need("those definitions", found.is_empty())?;
                let items: Vec<(String, String)> = if action == "only" {
                    found.clone()
                } else {
                    let props = self.text_of(crate::props::PROPERTIES).unwrap_or_default();
                    slice(&outline, &names, &props)
                };
                for (file, _) in &items {
                    card_mut(&mut board, file);
                }
                let label = if action == "only" { format!("just {}", names.join(", ")) } else { format!("{} and what touches it", names.join(", ")) };
                board["focus"] = json!({ "items": items, "label": label, "question": null });
                board["view"] = json!("board");
                String::new()
            }
            // the author's notes on the design (docs/PLANNING.md §5): a
            // decision binds the builder, a comment informs it
            "note" | "decide" => {
                let text = a["text"].as_str().unwrap_or("").trim().to_owned();
                if text.is_empty() {
                    return Err("What should the note say?".to_owned());
                }
                // on definitions by name, else on modules
                let anchors: Vec<(String, Option<String>)> = if !found.is_empty() {
                    found.iter().map(|(f, n)| (f.clone(), Some(n.clone()))).collect()
                } else {
                    need("what to put it on", modules.is_empty())?;
                    modules.iter().map(|m| (m.clone(), None)).collect()
                };
                let kind = if action == "decide" { "decision" } else { "comment" };
                let by = a["by"].as_str().unwrap_or("author");
                for (file, name) in anchors {
                    let id = add_note(&mut board, &file, name.as_deref(), kind, &text);
                    if let Some(note) = board["notes"].as_array_mut().and_then(|ns| ns.iter_mut().find(|n| n["id"] == json!(id))) {
                        note["by"] = json!(by);
                    }
                }
                board["view"] = json!("board");
                if action == "decide" { "Decided.".to_owned() } else { "Noted.".to_owned() }
            }
            "clear" => {
                board["focus"] = Value::Null;
                for card in board["cards"].as_array_mut().into_iter().flatten() {
                    card["hidden"] = json!([]);
                }
                "Everything again.".to_owned()
            }
            "bring" => {
                need("those modules", modules.is_empty())?;
                for m in &modules {
                    card_mut(&mut board, m);
                }
                board["view"] = json!("board");
                String::new()
            }
            "put-away" => {
                need("those modules", modules.is_empty())?;
                if let Some(cards) = board["cards"].as_array_mut() {
                    cards.retain(|c| !modules.iter().any(|m| c["path"] == json!(m)));
                }
                String::new()
            }
            "place" => {
                need("those modules", modules.is_empty())?;
                let near = a["near"].as_str().and_then(module_of).ok_or_else(|| "Next to what?".to_owned())?;
                let side = a["side"].as_str().unwrap_or("right");
                let anchor = card_mut(&mut board, &near).clone();
                let (ax, ay) = (anchor["x"].as_f64().unwrap_or(28.0), anchor["y"].as_f64().unwrap_or(64.0));
                for (i, m) in modules.iter().enumerate() {
                    let offset = 40.0 * i as f64;
                    let (x, y) = match side {
                        "left" => ((ax - 440.0).max(0.0), ay + offset),
                        "below" => (ax + offset, ay + 260.0),
                        "above" => (ax + offset, (ay - 260.0).max(0.0)),
                        _ => (ax + 440.0, ay + offset),
                    };
                    let card = card_mut(&mut board, m);
                    card["x"] = json!(x);
                    card["y"] = json!(y);
                }
                board["view"] = json!("board");
                String::new()
            }
            other => return Err(format!("unknown arrangement {other}")),
        };
        self.set_board(board);
        Ok(said)
    }
}

impl Studio {
    /// After a builder turn: arrange the board around what it changed
    /// (`touched`: file, first and last line of each edit), hiding as much
    /// as can go. The modules it touched come out; on each, the
    /// definitions it changed and everything they use stay, the module's
    /// interface (its provides) stays, and the rest of its internals --
    /// helpers the turn neither touched nor needs -- fold into "N hidden".
    /// What the author pinned (opened or unhid themselves) is never
    /// hidden. In build mode the bodies just written open (the last few);
    /// in plan mode bodies stay folded: the signatures are the design.
    pub fn auto_arrange(&self, touched: &[(String, usize, usize)]) {
        if touched.is_empty() {
            return;
        }
        let outline = outline(&self.files());
        let changed: Vec<(String, String)> = outline
            .iter()
            .flat_map(|m| {
                m.items
                    .iter()
                    .filter(|i| touched.iter().any(|(f, from, to)| f == &m.path && *from <= i.end_line && *to >= i.line))
                    .map(|i| (m.path.clone(), i.name.clone()))
                    .collect::<Vec<_>>()
            })
            .collect();
        let mut relevant: BTreeSet<String> = changed.iter().map(|(_, n)| n.clone()).collect();
        for m in &outline {
            for item in &m.items {
                if changed.iter().any(|(f, n)| f == &m.path && n == &item.name) {
                    relevant.extend(item.uses.iter().cloned());
                }
            }
        }
        let plan = self.board()["mode"] == json!("plan");
        let files: BTreeSet<&String> = touched.iter().map(|(f, _, _)| f).collect();
        self.update_board(|board| {
            for m in outline.iter().filter(|m| files.contains(&m.path) && m.path != crate::props::HARNESS) {
                let card = card_mut(board, &m.path);
                let pinned: BTreeSet<String> = card["pinned"].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(str::to_owned)).collect();
                // few definitions: nothing worth folding away
                let hidden: Vec<String> = if m.items.len() <= 5 {
                    Vec::new()
                } else {
                    m.items
                        .iter()
                        .filter(|i| !relevant.contains(&i.name) && !pinned.contains(&i.name))
                        .filter(|i| m.provides.as_ref().is_some_and(|p| !p.contains(&i.name)))
                        .map(|i| i.name.clone())
                        .collect()
                };
                card["hidden"] = json!(hidden);
                let mut open: Vec<String> = pinned.iter().filter(|n| card["open"].as_array().is_some_and(|o| o.contains(&json!(n)))).cloned().collect();
                if !plan {
                    let fresh: Vec<String> = changed.iter().filter(|(f, n)| f == &m.path && m.items.iter().any(|i| &i.name == n && i.kind == "fun")).map(|(_, n)| n.clone()).collect();
                    for name in fresh.iter().rev().take(3) {
                        if !open.contains(name) {
                            open.push(name.clone());
                        }
                    }
                }
                card["open"] = json!(open);
            }
        });
    }
}

/// A note on `file` (and definition `name`, or the whole module).
pub fn add_note(board: &mut Value, file: &str, name: Option<&str>, kind: &str, text: &str) -> u64 {
    if !board["notes"].is_array() {
        board["notes"] = json!([]);
    }
    let id = board["notes"].as_array().unwrap().iter().filter_map(|n| n["id"].as_u64()).max().unwrap_or(0) + 1;
    let at = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0);
    board["notes"].as_array_mut().unwrap().push(json!({ "id": id, "file": file, "name": name, "kind": kind, "text": text, "at": at }));
    id
}

/// The author's notes and the answered questions, as the builder reads
/// them: decisions first (they bind), then comments.
pub fn describe_notes(board: &Value) -> String {
    let mut decisions = Vec::new();
    let mut comments = Vec::new();
    for note in board["notes"].as_array().into_iter().flatten() {
        let place = match note["name"].as_str() {
            Some(name) => format!("{name} ({})", note["file"].as_str().unwrap_or("")),
            None => format!("the module {}", note["file"].as_str().unwrap_or("")),
        };
        let line = format!("- on {place}: {}", note["text"].as_str().unwrap_or("").trim());
        match note["kind"].as_str() {
            Some("decision") => decisions.push(line),
            _ => comments.push(line),
        }
    }
    for q in board["questions"].as_array().into_iter().flatten().filter(|q| q["answered"] == json!(true)) {
        decisions.push(format!("- {} -> {}", q["text"].as_str().unwrap_or(""), q["answer"].as_str().unwrap_or("")));
    }
    let mut out = String::new();
    if !decisions.is_empty() {
        out.push_str(&format!("The author's DECISIONS about the design -- binding: build to them, and keep them true when you change things:\n{}\n", decisions.join("\n")));
    }
    if !comments.is_empty() {
        out.push_str(&format!("The author's comments on the design (context, not commands):\n{}\n", comments.join("\n")));
    }
    out
}

/// The card of `path` on `board`, made (unplaced) if it is not out.
fn card_mut<'a>(board: &'a mut Value, path: &str) -> &'a mut Value {
    if !board["cards"].is_array() {
        board["cards"] = json!([]);
    }
    let cards = board["cards"].as_array_mut().unwrap();
    let index = match cards.iter().position(|c| c["path"] == json!(path)) {
        Some(index) => index,
        None => {
            cards.push(json!({ "path": path, "x": null, "y": null, "open": [], "hidden": [], "pinned": [] }));
            cards.len() - 1
        }
    };
    &mut cards[index]
}

fn set_member(card: &mut Value, list: &str, name: &str, present: bool) {
    let mut items: Vec<String> = card[list].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(str::to_owned)).collect();
    items.retain(|n| n != name);
    if present {
        items.push(name.to_owned());
    }
    card[list] = json!(items);
}

/// Every (file, name) of `outline` named in `names`.
pub fn locate(outline: &[Module], names: &[String]) -> Vec<(String, String)> {
    outline.iter().flat_map(|m| m.items.iter().filter(|i| names.contains(&i.name)).map(move |i| (m.path.clone(), i.name.clone()))).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn files(pairs: &[(&str, &str)]) -> Files {
        pairs.iter().map(|(a, b)| (a.to_string(), b.to_string())).collect()
    }

    #[test]
    fn signatures_read_ml_style() {
        let text = "(provide step inject)\n(require \"syntax.puf\")\n\
(define-type State (St Expr Env) (Done))\n\
(define-type-alias Env (Hash Sym Int))\n\
;; one transition\n;; of the machine\n(: step (-> State State))\n(define (step s) ??)\n\
(define (inject [e : Expr]) : State (St e (hash)))\n\
(define (run s k) (step (step s)))\n\
(define limit 100)\n(define (varargs a . more) a)\n(println 1)\n";
        let o = outline(&files(&[("machine.puf", text), ("syntax.puf", "(define-type Expr (Num Int))\n")]));
        let m = o.iter().find(|m| m.path == "machine.puf").unwrap();
        let sig = |name: &str| m.items.iter().find(|i| i.name == name).unwrap().clone();
        assert_eq!(m.provides, Some(vec!["step".into(), "inject".into()]));
        assert_eq!(m.requires, vec!["syntax.puf".to_owned()]);
        assert_eq!(sig("State").sig, "type State = St of Expr * Env | Done");
        assert_eq!(sig("Env").sig, "type Env = Hash Sym Int");
        assert_eq!(sig("step").sig, "val step : State -> State");
        assert!(sig("step").opaque && sig("step").holes == 1);
        assert_eq!(sig("step").doc, "one transition of the machine");
        assert_eq!(sig("inject").sig, "val inject : Expr -> State");
        assert_eq!(sig("run").sig, "val run : s * k -> _");
        assert_eq!(sig("run").uses, vec!["step".to_owned()]);
        assert_eq!(sig("limit").sig, "val limit");
        assert_eq!(sig("varargs").sig, "val varargs : a * more... -> _");
        assert_eq!(m.effects, 1);
        assert_eq!(render(&read_all("(-> (-> Int Int) (List Int) Bool)")[0]), "(Int -> Int) * (List Int) -> Bool");
    }

    #[test]
    fn signatures_typed_on_the_board_become_planned_definitions() {
        assert_eq!(define_from_signature("val alloc : Store -> Addr").unwrap(), "(: alloc (-> Store Addr))\n(define (alloc store) ??)");
        assert_eq!(define_from_signature("step : State * Kont -> State").unwrap(), "(: step (-> State Kont State))\n(define (step state kont) ??)");
        assert_eq!(define_from_signature("pair : Int * Int -> Int").unwrap(), "(: pair (-> Int Int Int))\n(define (pair int int2) ??)");
        assert_eq!(define_from_signature("fresh : unit -> Addr").unwrap(), "(: fresh (-> Addr))\n(define (fresh) ??)");
        assert_eq!(define_from_signature("map-k : (Int -> Int) * List Int -> List Int").unwrap(), "(: map-k (-> (-> Int Int) (List Int) (List Int)))\n(define (map-k f list) ??)");
        assert_eq!(define_from_signature("val limit : Int").unwrap(), "(: limit Int)\n(define limit ??)");
        assert_eq!(define_from_signature("type Kont = Done | Arg of Expr * Env").unwrap(), "(define-type Kont\n  (Done)\n  (Arg Expr Env))");
        assert_eq!(define_from_signature("type Option a = None | Some of a").unwrap(), "(define-type (Option a)\n  (None)\n  (Some a))");
        assert_eq!(define_from_signature("type Env = Hash Var Addr").unwrap(), "(define-type-alias Env (Hash Var Addr))");
        assert!(define_from_signature("alloc Store").is_err());
        assert!(define_from_signature("f : (Int -> Int").is_err());
        assert!(define_from_signature("type = A").is_err());
    }

    #[test]
    fn a_slice_is_the_definition_its_uses_and_its_users() {
        let text = "(define (a x) (b x))\n(define (b x) (c x))\n(define (c x) x)\n(define (d x) x)\n";
        let o = outline(&files(&[("m.puf", text)]));
        let s: Vec<String> = slice(&o, &["b".to_owned()], "(check-example 'p (equal? (b 1) 1))\n").into_iter().map(|(_, n)| n).collect();
        assert_eq!(s, vec!["b", "c", "a", "@1"]);
    }
}
