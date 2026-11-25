//! Excursions (docs/VOICE.md §5): going off to understand a fragment of
//! the program, by voice, without changing it.
//!
//! An excursion starts on a fragment -- a clause, a definition, the
//! selection, some lines ("explain the fix clause", "how does apply-fn
//! work") -- and is a thread of questions and answers about it. Follow-ups
//! stay in it ("and why a hash there?"); one about other code, or an answer
//! that leans on other code, *pulls that code in*: a second fragment beside
//! the first, then a third, so the picture is built a piece at a time and
//! every piece stays in view. Nothing is edited. The builder is not
//! involved: an answer is one Messages API call that sees the fragments,
//! the whole program and the thread so far.

use crate::claude_api;
use crate::sexp;
use crate::studio::Studio;
use crate::toolchain::{self, Files};
use crate::voice::Context;
use serde_json::{Value, json};
use std::fmt::Write as _;
use std::sync::Arc;
use std::time::Duration;

/// Fragments one excursion holds at most (the oldest pulled-in goes first).
const MAX_FRAGMENTS: usize = 6;
/// Lines one fragment shows at most.
const MAX_LINES: usize = 60;
/// What the explainer is shown of the program, at most.
const PROGRAM_BYTES: usize = 40_000;

#[derive(Clone, Debug)]
pub struct Fragment {
    pub file: String,
    /// 1-based, inclusive.
    pub from: usize,
    pub to: usize,
    pub label: String,
    /// Why it was pulled in (empty for the one it started on, and for the
    /// ones the author asked about).
    pub why: String,
}

#[derive(Clone, Debug)]
pub struct Exchange {
    pub question: String,
    /// None while it is being answered.
    pub answer: Option<String>,
    pub failed: bool,
    /// The lines the answer centers on.
    pub highlight: Option<(String, usize, usize)>,
}

#[derive(Clone, Debug, Default)]
pub struct Excursion {
    pub id: u64,
    pub fragments: Vec<Fragment>,
    pub thread: Vec<Exchange>,
}

impl Excursion {
    fn covers(&self, file: &str, from: usize, to: usize) -> bool {
        self.fragments.iter().any(|f| f.file == file && f.from <= from && to <= f.to)
    }

    /// Add a fragment, unless one already shows those lines; one it
    /// overlaps grows to hold both.
    fn add(&mut self, fragment: Fragment) {
        if self.covers(&fragment.file, fragment.from, fragment.to) {
            return;
        }
        if let Some(existing) = self.fragments.iter_mut().find(|f| f.file == fragment.file && f.from <= fragment.to + 1 && fragment.from <= f.to + 1) {
            existing.from = existing.from.min(fragment.from);
            existing.to = existing.to.max(fragment.to);
            return;
        }
        self.fragments.push(fragment);
        while self.fragments.len() > MAX_FRAGMENTS {
            // keep the one it started on
            self.fragments.remove(1);
        }
    }

    /// What the tabs are shown: each fragment with its text, the thread.
    pub fn view(&self, files: &Files) -> Value {
        let fragments: Vec<Value> = self
            .fragments
            .iter()
            .map(|f| {
                let text = files.get(&f.file).map(|text| lines(text, f.from, f.to)).unwrap_or_default();
                json!({ "file": f.file, "from": f.from, "to": f.to, "label": f.label, "why": f.why, "text": text })
            })
            .collect();
        let thread: Vec<Value> = self
            .thread
            .iter()
            .map(|e| {
                json!({
                    "question": e.question,
                    "answer": e.answer,
                    "failed": e.failed,
                    "highlight": e.highlight.as_ref().map(|(file, from, to)| json!({ "file": file, "from": from, "to": to })),
                })
            })
            .collect();
        json!({ "id": self.id, "fragments": fragments, "thread": thread })
    }

    /// One line for the router: what is open.
    pub fn describe(&self) -> String {
        let places: Vec<String> = self.fragments.iter().map(|f| format!("{} {}-{} ({})", f.file, f.from, f.to, f.label)).collect();
        let last = self.thread.last().map(|e| format!("; last question: \"{}\"", toolchain::clip(&e.question, 200))).unwrap_or_default();
        format!("An excursion is open on: {}{last}", places.join(", "))
    }
}

/// Lines `from..=to` of `text` (1-based).
fn lines(text: &str, from: usize, to: usize) -> String {
    text.lines().skip(from.saturating_sub(1)).take(to + 1 - from.max(1)).collect::<Vec<_>>().join("\n")
}

/// `text` with each line numbered, for a model to cite.
pub fn numbered(text: &str, first: usize) -> String {
    let mut out = String::new();
    for (i, line) in text.lines().enumerate() {
        let _ = writeln!(out, "{:>4}  {line}", first + i);
    }
    out
}

/// Clamp a range to the file and to MAX_LINES; widen a single line that
/// opens a form to the whole form (a clause, a definition).
fn settle(text: &str, from: usize, to: usize) -> Option<(usize, usize)> {
    let count = text.lines().count();
    if count == 0 || from == 0 {
        return None;
    }
    let from = from.min(count);
    let mut to = to.max(from).min(count);
    if to == from {
        // the smallest form that starts on that line, at any depth
        let start = sexp::offset_of(text, from, 1);
        let line_end = text[start..].find('\n').map_or(text.len(), |i| start + i);
        let first = text[start..line_end].find(['(', '[']).map(|i| start + i);
        if let Some(open) = first
            && let Some(close) = matching(text, open)
        {
            to = text[..close].bytes().filter(|&b| b == b'\n').count() + 1;
        }
    }
    Some((from, to.min(from + MAX_LINES - 1)))
}

/// The offset of the bracket closing the one at `open` (strings and
/// comments skipped), if it closes.
fn matching(text: &str, open: usize) -> Option<usize> {
    let bytes = text.as_bytes();
    let mut depth = 0i32;
    let mut i = open;
    let mut in_string = false;
    while i < bytes.len() {
        let b = bytes[i];
        if in_string {
            if b == b'\\' {
                i += 1;
            } else if b == b'"' {
                in_string = false;
            }
        } else {
            match b {
                b'"' => in_string = true,
                b';' => {
                    while i < bytes.len() && bytes[i] != b'\n' {
                        i += 1;
                    }
                }
                b'(' | b'[' => depth += 1,
                b')' | b']' => {
                    depth -= 1;
                    if depth == 0 {
                        return Some(i);
                    }
                }
                _ => {}
            }
        }
        i += 1;
    }
    None
}

impl Studio {
    /// The router's `explain`: ask (start, or follow up and pull in), or close.
    pub(crate) fn explain(self: &Arc<Self>, explain: &Value, context: &Context) {
        match explain["action"].as_str().unwrap_or("none") {
            "close" => self.close_excursion(),
            "ask" => {
                let question = explain["question"].as_str().unwrap_or("").trim().to_owned();
                if question.is_empty() {
                    return;
                }
                let fresh = explain["fresh"].as_bool().unwrap_or(false);
                let label = explain["label"].as_str().unwrap_or("").trim().to_owned();
                let file = explain["file"].as_str().unwrap_or("").trim().to_owned();
                let from = explain["from"].as_u64().unwrap_or(0) as usize;
                let to = explain["to"].as_u64().unwrap_or(0) as usize;
                self.ask_excursion(question, fresh, (file, from, to), label, context);
            }
            _ => {}
        }
    }

    pub(crate) fn close_excursion(&self) {
        let had = self.voice_excursion(|slot| slot.take().is_some());
        if had {
            self.publish_excursion();
        }
    }

    fn ask_excursion(self: &Arc<Self>, question: String, fresh: bool, (file, from, to): (String, usize, usize), label: String, context: &Context) {
        let files = self.files();
        // what it is about: the lines named, else the selection, else (with
        // nothing open) the form at the cursor
        let mut place = files.get(&file).and_then(|text| settle(text, from, to)).map(|(from, to)| (file.clone(), from, to));
        if place.is_none()
            && let (Some(file), Some((from, to))) = (&context.file, context.selection_lines)
            && let Some(text) = files.get(file)
        {
            place = settle(text, from, to).map(|(from, to)| (file.clone(), from, to));
        }
        let open = self.voice_excursion(|slot| slot.is_some());
        if place.is_none()
            && (fresh || !open)
            && let (Some(file), Some(line)) = (&context.file, context.line)
            && let Some(text) = files.get(file)
            && let Some(form) = sexp::form_at(text, sexp::offset_of(text, line, 1))
        {
            let end = text[..form.end].bytes().filter(|&b| b == b'\n').count() + 1;
            place = Some((file.clone(), form.line, end.min(form.line + MAX_LINES - 1)));
        }
        let index = self.voice_excursion(|slot| {
            if fresh || slot.is_none() {
                let id = slot.as_ref().map_or(1, |e| e.id + 1);
                *slot = Some(Excursion { id, ..Excursion::default() });
            }
            let excursion = slot.as_mut().expect("just made");
            if let Some((file, from, to)) = &place {
                let label = if label.is_empty() { format!("{file} {from}–{to}") } else { label.clone() };
                excursion.add(Fragment { file: file.clone(), from: *from, to: *to, label, why: String::new() });
            }
            excursion.thread.push(Exchange { question: question.clone(), answer: None, failed: false, highlight: None });
            (excursion.id, excursion.thread.len() - 1)
        });
        self.publish_excursion();
        let studio = self.clone();
        tokio::spawn(async move { studio.answer_excursion(index.0, index.1).await });
    }

    async fn answer_excursion(self: Arc<Self>, id: u64, at: usize) {
        let Some(excursion) = self.voice_excursion(|slot| slot.as_ref().filter(|e| e.id == id).cloned()) else {
            return;
        };
        let files = self.files();
        let mut user = String::new();
        let _ = writeln!(user, "The program, every file numbered by line:\n");
        let mut budget = PROGRAM_BYTES;
        for (path, text) in &files {
            if path == crate::props::HARNESS {
                continue;
            }
            let shown = numbered(text, 1);
            if shown.len() > budget {
                let _ = writeln!(user, "== {path} ({} lines, too long to show; ask for it by pulling in lines)\n", text.lines().count());
                continue;
            }
            budget -= shown.len();
            let _ = writeln!(user, "== {path}\n{shown}");
        }
        let _ = writeln!(user, "\nThe fragments of this excursion, in the order they were brought in:");
        for f in &excursion.fragments {
            let why = if f.why.is_empty() { String::new() } else { format!(" -- pulled in: {}", f.why) };
            let _ = writeln!(user, "- {} lines {}-{} ({}){why}", f.file, f.from, f.to, f.label);
        }
        if at > 0 {
            let _ = writeln!(user, "\nThe excursion so far:");
            for e in &excursion.thread[..at] {
                let _ = writeln!(user, "Q: {}\nA: {}\n", e.question, e.answer.as_deref().unwrap_or("(not answered)"));
            }
        }
        let _ = writeln!(user, "\nThe question now: {}", excursion.thread[at].question);
        let model = crate::setting("PUFFIN_EXPLAIN_MODEL", claude_api::EXPLAIN_MODEL);
        let answer = match self.voice_api() {
            Some(api) => {
                // the language itself, as the builder has it: a question is
                // as often about Puffin (`ann`, `_`, define-grammar) as the program
                let system = crate::knowledge::system_prompt(&self.root, EXPLAINER);
                api.structured(&model, "low", &system, &user, schema(), 2500, Duration::from_secs(90)).await
            }
            None => Err("no Claude API credentials".to_owned()),
        };
        self.voice_excursion(|slot| {
            let Some(excursion) = slot.as_mut().filter(|e| e.id == id) else { return };
            let Some(exchange) = excursion.thread.get_mut(at) else { return };
            match &answer {
                Ok(value) => {
                    exchange.answer = Some(value["answer"].as_str().unwrap_or("").trim().to_owned());
                    let h = &value["highlight"];
                    if let (Some(file), Some(from)) = (h["file"].as_str().filter(|f| files.contains_key(*f)), h["from"].as_u64().filter(|&n| n > 0)) {
                        let to = h["to"].as_u64().unwrap_or(from).max(from);
                        exchange.highlight = Some((file.to_owned(), from as usize, to as usize));
                    }
                    for pull in value["pull"].as_array().into_iter().flatten().take(2) {
                        let file = pull["file"].as_str().unwrap_or("");
                        let Some(text) = files.get(file) else { continue };
                        let Some((from, to)) = settle(text, pull["from"].as_u64().unwrap_or(0) as usize, pull["to"].as_u64().unwrap_or(0) as usize) else { continue };
                        let label = pull["label"].as_str().filter(|l| !l.trim().is_empty()).map(str::to_owned).unwrap_or_else(|| format!("{file} {from}–{to}"));
                        excursion.add(Fragment { file: file.to_owned(), from, to, label, why: pull["why"].as_str().unwrap_or("").to_owned() });
                    }
                }
                Err(error) => {
                    exchange.answer = Some(format!("Could not answer: {error}"));
                    exchange.failed = true;
                }
            }
        });
        self.publish_excursion();
        if let Ok(value) = &answer
            && let Some(said) = value["spoken"].as_str().filter(|s| !s.trim().is_empty())
        {
            // the gist, for the caption (and aloud, when the author has
            // asked for replies to be spoken); the panel has the whole of it
            self.voice_event("reply", json!({ "text": said.trim(), "speak": true, "from": "excursion" }));
        }
    }
}

fn schema() -> Value {
    let range = |extra: Value| {
        let mut properties = json!({
            "file": { "type": "string" },
            "from": { "type": "integer" },
            "to": { "type": "integer" },
        });
        let mut required = vec!["file", "from", "to"];
        if let Value::Object(more) = extra {
            for (key, value) in more {
                properties[&key] = value;
            }
            required.extend(["label", "why"]);
        }
        json!({ "type": "object", "additionalProperties": false, "required": required, "properties": properties })
    };
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["answer", "spoken", "highlight", "pull"],
        "properties": {
            "answer": { "type": "string" },
            "spoken": { "type": "string" },
            "highlight": range(Value::Null),
            "pull": { "type": "array", "items": range(json!({ "label": { "type": "string" }, "why": { "type": "string" } })) },
        },
    })
}

const EXPLAINER: &str = "\
You are the guide on an excursion through a Puffin program (Puffin: a gradually typed Scheme with ML-style \
types, define-type data, match, typed holes `??` that are bodies not written yet). The author is building it \
by voice and has stopped to understand part of it. You are shown the whole program with line numbers, the \
fragments of code this excursion has brought into view, the questions and answers so far, and the question \
now. Explain; never propose edits unless asked what to change. When the question is about a form of the language \
itself (`ann`, `_`, `define-grammar`, `match` patterns, quasiquote templates), say that it is built in and what \
it does, from the reference above, then what it does in this code.

answer: markdown, short -- a few sentences to two short paragraphs, or a few bullets -- read in a narrow \
panel beside the code. Speak to this program: name its definitions and constructors in `code`, cite lines as \
`file:line` (e.g. `interp.puf:15`). Explain what the fragment does and how, the idea behind it (an \
environment, a closure, a fixed point -- whatever it is), and how it connects to the rest. Build on the \
earlier answers; do not repeat them. If part of it is a hole (`??`), say what it will have to do.

spoken: the gist in one sentence, for a caption (and read aloud if the author has turned that on).

highlight: the lines the answer centers on (file, from, to; from 0 for none).

pull: other code the answer leans on that is not yet in view and that the author will want next to it -- \
the helper this clause calls, the type it matches on, the definition that builds the value -- each with a \
short label (\"apply-fn\", \"the Value type\") and why (\"what happens when the closure is called\"). At most \
two; none when the fragments already in view suffice. Lines must be real, from the numbered program. This is \
how an excursion grows: a piece at a time, as the explanation needs it.";

#[cfg(test)]
mod tests {
    use super::*;

    const TEXT: &str = "(define (eval-expr e env)\n  (match e\n    [(Num n) (VNum n)]\n    [(Fix f x body)\n     (VRec f x body env)]\n    [_ (error \"bad\")]))\n";

    #[test]
    fn one_line_widens_to_its_form() {
        assert_eq!(settle(TEXT, 4, 4), Some((4, 5)));
        assert_eq!(settle(TEXT, 1, 1), Some((1, 6)));
        assert_eq!(settle(TEXT, 3, 3), Some((3, 3)));
        assert_eq!(settle(TEXT, 2, 3), Some((2, 3)));
        assert_eq!(settle(TEXT, 0, 3), None);
        assert_eq!(settle(TEXT, 99, 99), Some((6, 6)));
    }

    #[test]
    fn fragments_merge_and_never_repeat() {
        let mut e = Excursion::default();
        let frag = |from, to| Fragment { file: "a.puf".into(), from, to, label: String::new(), why: String::new() };
        e.add(frag(4, 5));
        e.add(frag(4, 5));
        e.add(frag(5, 5));
        assert_eq!(e.fragments.len(), 1);
        e.add(frag(6, 8));
        assert_eq!((e.fragments.len(), e.fragments[0].from, e.fragments[0].to), (1, 4, 8));
        e.add(frag(20, 22));
        assert_eq!(e.fragments.len(), 2);
    }

    #[test]
    fn the_explainer_schema_is_strict() {
        claude_api::assert_strict(&schema(), "explainer");
    }
}
