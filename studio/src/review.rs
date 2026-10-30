//! Proposals: what the assistant wants to change, held until the author
//! accepts it. Nothing an agent writes reaches the program by fiat
//! (docs/STUDIO.md §1, §4).
//!
//! A proposal is `{file, old, new, note}`: replace the one occurrence of
//! `old` in `file` with `new`. Text anchors need no positions, so edits
//! elsewhere leave a proposal applicable, and an edit to its own text makes
//! it *stale* (it no longer applies). An empty `old` appends to the file,
//! making it if it does not exist. Pending proposals of different threads
//! whose old text overlaps are in *conflict*; neither can be accepted until
//! the author rejects one.
//!
//! Each question is a thread, and each turn of it a changeset with the
//! scope the author asked at (§4): a selection, a form, a module, or the
//! program. A proposal outside its turn's scope is refused.
//!
//! Ported from Slog Studio's review.rs, with a file on every edit.

use crate::toolchain::Files;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Change {
    pub file: String,
    pub old: String,
    pub new: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Pending,
    Accepted,
    Rejected,
}

#[derive(Clone, Debug, Serialize)]
pub struct Op {
    pub id: u32,
    pub thread: u32,
    pub changeset: u32,
    #[serde(flatten)]
    pub change: Change,
    pub note: String,
    pub status: Status,
}

/// What a turn may change.
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ScopeKind {
    Selection,
    #[default]
    Form,
    Module,
    Program,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct Scope {
    pub kind: ScopeKind,
    /// The focused file.
    pub file: String,
    /// For a selection or a form: the text it covers, as the thread's
    /// proposals have left it, and where it started in the file.
    pub region: Option<String>,
    #[serde(skip)]
    pub near: usize,
}

impl Scope {
    /// Why `change`, made to `text` (the thread's fork of its file), leaves
    /// this scope, if it does.
    pub fn refuses(&self, change: &Change, text: &str) -> Option<String> {
        let what = match self.kind {
            ScopeKind::Program => return None,
            ScopeKind::Module => "module",
            ScopeKind::Form => "form",
            ScopeKind::Selection => "selection",
        };
        if change.file != self.file {
            return Some(format!(
                "Refused: this question is scoped to the {what} in {}; {} is outside it. Propose changes to {} only, or tell the author a wider scope is needed.",
                self.file, change.file, self.file
            ));
        }
        let Some(region) = &self.region else { return None };
        if change.old.is_empty() {
            return Some(format!("Refused: an append adds text outside the {what} this question is scoped to."));
        }
        let Some(start) = locate(text, region, self.near) else {
            return Some(format!("Refused: the {what} this question is scoped to is no longer in {}.", self.file));
        };
        let at = text.find(change.old.as_str()).unwrap_or(usize::MAX);
        if at < start || at + change.old.len() > start + region.len() {
            return Some(format!(
                "Refused: the old text lies outside the {what} this question is scoped to. Change only text inside it:\n{region}"
            ));
        }
        None
    }

    /// Follow a change this scope allowed: the region now holds its new text.
    pub fn follow(&mut self, change: &Change) {
        if let Some(region) = &mut self.region
            && region.contains(change.old.as_str())
            && !change.old.is_empty()
        {
            *region = region.replacen(change.old.as_str(), &change.new, 1);
        }
    }
}

/// The occurrence of `region` in `text` nearest byte `near`.
fn locate(text: &str, region: &str, near: usize) -> Option<usize> {
    text.match_indices(region).map(|(at, _)| at).min_by_key(|at| at.abs_diff(near))
}

/// One turn's proposals, titled with the question that caused them.
#[derive(Clone, Debug, Serialize)]
pub struct Changeset {
    pub id: u32,
    pub thread: u32,
    pub title: String,
    pub scope: Scope,
}

/// One entry of a thread's transcript.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Message {
    /// "user", "assistant", "thinking", "tool", "notice", "error", or "turn"
    /// (a turn's closing line).
    pub role: String,
    pub text: String,
    /// When it was said, in milliseconds since the epoch.
    #[serde(default)]
    pub at: u64,
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub data: Value,
}

impl Message {
    pub fn new(role: &str, text: &str, data: Value) -> Self {
        Self { role: role.to_owned(), text: text.to_owned(), at: now(), data }
    }
}

pub fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |since| since.as_millis() as u64)
}

/// One line of questioning: its own claude session, resumed for follow-ups.
#[derive(Clone, Debug, Serialize)]
pub struct Thread {
    pub id: u32,
    pub title: String,
    #[serde(skip)]
    pub session: Option<String>,
    pub messages: Vec<Message>,
    pub running: bool,
}

/// What the author and the agents see of an op.
#[derive(Clone, Debug, Serialize)]
pub struct OpView {
    #[serde(flatten)]
    pub op: Op,
    /// It cannot apply to the current program any more.
    pub stale: bool,
    /// Pending ops of other threads that touch the same text.
    pub conflicts: Vec<u32>,
    /// Whether accepting it leaves a program that passes the check; absent
    /// until checked.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub check: Option<Acceptance>,
}

/// What accepting a pending op would take.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Acceptance {
    pub ok: bool,
    /// The earlier pending ops of its thread it builds on, accepted with it.
    pub with: Vec<u32>,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub reason: String,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct ReviewView {
    pub threads: Vec<Thread>,
    pub changesets: Vec<Changeset>,
    pub ops: Vec<OpView>,
}

#[derive(Clone, Default)]
pub struct Review {
    threads: Vec<Thread>,
    changesets: Vec<Changeset>,
    ops: Vec<Op>,
}

impl Review {
    pub fn new_thread(&mut self, title: String) -> u32 {
        let id = self.threads.len() as u32 + 1;
        self.threads.push(Thread { id, title, session: None, messages: Vec::new(), running: false });
        id
    }

    pub fn thread(&self, id: u32) -> Option<&Thread> {
        self.threads.iter().find(|thread| thread.id == id)
    }

    pub fn thread_mut(&mut self, id: u32) -> Option<&mut Thread> {
        self.threads.iter_mut().find(|thread| thread.id == id)
    }

    /// The changeset a thread's next proposals join: one per turn.
    pub fn open_changeset(&mut self, thread: u32, title: String, scope: Scope) -> u32 {
        let id = self.changesets.len() as u32 + 1;
        self.changesets.push(Changeset { id, thread, title, scope });
        id
    }

    fn open_of(&self, thread: u32) -> Option<&Changeset> {
        self.changesets.iter().rev().find(|changeset| changeset.thread == thread)
    }

    /// The scope of `thread`'s turn in progress.
    pub fn scope_of(&self, thread: u32) -> Option<&Scope> {
        self.open_of(thread).map(|changeset| &changeset.scope)
    }

    /// The program as `thread` sees it: `files` with the thread's own
    /// pending ops applied in order, skipping any that no longer apply.
    pub fn fork(&self, files: &Files, thread: u32) -> Files {
        self.ops
            .iter()
            .filter(|op| op.thread == thread && op.status == Status::Pending)
            .fold(files.clone(), |files, op| apply(&files, &op.change).unwrap_or(files))
    }

    /// Queue a change from `thread`, checked against that thread's fork so
    /// it may build on its own earlier proposals. An edit of text that one
    /// of those proposals wrote corrects it instead: that proposal is
    /// rewritten, and its id returned, so the author reviews the final
    /// text, not a chain of fixes. The caller has checked scope and program.
    pub fn propose(&mut self, files: &Files, thread: u32, change: Change, note: String) -> Result<u32, String> {
        apply(&self.fork(files, thread), &change)?;
        let changeset = self.open_of(thread).map(|changeset| changeset.id).ok_or("this thread has no open changeset")?;
        if let Some(scope) = self.changesets.iter_mut().find(|c| c.id == changeset).map(|c| &mut c.scope) {
            scope.follow(&change);
        }
        if !change.old.is_empty()
            && let Some(op) = self.ops.iter_mut().rev().find(|op| {
                op.thread == thread
                    && op.status == Status::Pending
                    && op.change.file == change.file
                    && op.change.new.matches(change.old.as_str()).count() == 1
            })
        {
            op.change.new = op.change.new.replacen(change.old.as_str(), &change.new, 1);
            if !note.is_empty() {
                op.note = note;
            }
            return Ok(op.id);
        }
        let id = self.ops.len() as u32 + 1;
        self.ops.push(Op { id, thread, changeset, change, note, status: Status::Pending });
        Ok(id)
    }

    /// Accept op `id` against `files`, returning the files it leaves.
    pub fn accept(&mut self, files: &Files, id: u32) -> Result<Files, String> {
        let view = self.view(files);
        let op = view.ops.iter().find(|view| view.op.id == id).ok_or_else(|| format!("no proposal #{id}"))?;
        if op.op.status != Status::Pending {
            return Err(format!("proposal #{id} is already {:?}", op.op.status).to_lowercase());
        }
        if !op.conflicts.is_empty() {
            return Err(format!("proposal #{id} conflicts with {}; reject one side first", ids(&op.conflicts)));
        }
        let updated = apply(files, &op.op.change).map_err(|why| format!("proposal #{id} no longer applies: {why}"))?;
        self.set_status(id, Status::Accepted);
        Ok(updated)
    }

    pub fn reject(&mut self, id: u32) -> Result<(), String> {
        match self.ops.iter().find(|op| op.id == id).map(|op| op.status) {
            None => Err(format!("no proposal #{id}")),
            Some(Status::Pending) => {
                self.set_status(id, Status::Rejected);
                Ok(())
            }
            Some(status) => Err(format!("proposal #{id} is already {status:?}").to_lowercase()),
        }
    }

    /// Record that op `id` was accepted (the studio checked and applied it).
    pub fn mark_accepted(&mut self, id: u32) {
        self.set_status(id, Status::Accepted);
    }

    fn set_status(&mut self, id: u32, status: Status) {
        if let Some(op) = self.ops.iter_mut().find(|op| op.id == id) {
            op.status = status;
        }
    }

    pub fn op(&self, id: u32) -> Option<&Op> {
        self.ops.iter().find(|op| op.id == id)
    }

    pub fn view(&self, files: &Files) -> ReviewView {
        let pending: Vec<&Op> = self.ops.iter().filter(|op| op.status == Status::Pending).collect();
        let ops = self
            .ops
            .iter()
            .map(|op| {
                let open = op.status == Status::Pending;
                OpView {
                    op: op.clone(),
                    // built on an earlier proposal of its thread, an op may
                    // apply only to its fork until that one is accepted
                    stale: open && apply(&self.fork_before(files, op), &op.change).is_err(),
                    conflicts: if open {
                        pending
                            .iter()
                            .filter(|other| other.thread != op.thread && overlaps(files, &op.change, &other.change))
                            .map(|other| other.id)
                            .collect()
                    } else {
                        Vec::new()
                    },
                    check: None,
                }
            })
            .collect();
        ReviewView { threads: self.threads.clone(), changesets: self.changesets.clone(), ops }
    }

    /// Pending op `id`'s change, and the pending changes of its thread
    /// before it, in order.
    pub fn chain(&self, id: u32) -> Option<(Change, Vec<(u32, Change)>)> {
        let op = self.ops.iter().find(|op| op.id == id && op.status == Status::Pending)?;
        let before = self
            .ops
            .iter()
            .filter(|other| other.thread == op.thread && other.status == Status::Pending && other.id < id)
            .map(|other| (other.id, other.change.clone()))
            .collect();
        Some((op.change.clone(), before))
    }

    /// The pending ops of `changeset`, in order.
    pub fn pending_of(&self, changeset: u32) -> Vec<u32> {
        self.ops.iter().filter(|op| op.changeset == changeset && op.status == Status::Pending).map(|op| op.id).collect()
    }

    /// The pending ops of `thread`, in order.
    pub fn pending_of_thread(&self, thread: u32) -> Vec<&Op> {
        self.ops.iter().filter(|op| op.thread == thread && op.status == Status::Pending).collect()
    }

    fn fork_before(&self, files: &Files, op: &Op) -> Files {
        self.ops
            .iter()
            .filter(|other| other.thread == op.thread && other.status == Status::Pending && other.id < op.id)
            .fold(files.clone(), |files, other| apply(&files, &other.change).unwrap_or(files))
    }
}

/// `files` with `change` made, or why it cannot be.
pub fn apply(files: &Files, change: &Change) -> Result<Files, String> {
    let mut out = files.clone();
    let text = files.get(&change.file);
    if change.old.is_empty() {
        if change.new.trim().is_empty() {
            return Err("nothing to add".to_owned());
        }
        let mut updated = text.map(|text| text.trim_end().to_owned()).unwrap_or_default();
        if !updated.is_empty() {
            updated.push_str("\n\n");
        }
        updated.push_str(change.new.trim_end());
        updated.push('\n');
        out.insert(change.file.clone(), updated);
        return Ok(out);
    }
    let text = text.ok_or_else(|| format!("there is no file {}", change.file))?;
    match text.match_indices(change.old.as_str()).count() {
        1 => {
            out.insert(change.file.clone(), text.replacen(change.old.as_str(), &change.new, 1));
            Ok(out)
        }
        0 => Err(format!("the old text does not occur in {}", change.file)),
        n => Err(format!("the old text occurs {n} times in {}; include more context to make it unique", change.file)),
    }
}

/// Two edits conflict when the text they replace overlaps. Appends never
/// conflict: both land, one after the other.
fn overlaps(files: &Files, a: &Change, b: &Change) -> bool {
    if a.file != b.file {
        return false;
    }
    let Some(text) = files.get(&a.file) else { return false };
    let span = |change: &Change| {
        (!change.old.is_empty())
            .then(|| text.find(change.old.as_str()).map(|start| start..start + change.old.len()))
            .flatten()
    };
    match (span(a), span(b)) {
        (Some(a), Some(b)) => a.start < b.end && b.start < a.end,
        _ => false,
    }
}

fn ids(ids: &[u32]) -> String {
    ids.iter().map(|id| format!("#{id}")).collect::<Vec<_>>().join(", ")
}

#[cfg(test)]
mod tests {
    use super::*;

    const MAIN: &str = "(define (f x) (+ x 1))\n(define (g y) (* y 2))\n";

    fn files() -> Files {
        Files::from([("main.puf".to_owned(), MAIN.to_owned()), ("lib.puf".to_owned(), "(provide h)\n".to_owned())])
    }

    fn edit(file: &str, old: &str, new: &str) -> Change {
        Change { file: file.to_owned(), old: old.to_owned(), new: new.to_owned() }
    }

    fn program_scope() -> Scope {
        Scope { kind: ScopeKind::Program, ..Scope::default() }
    }

    #[test]
    fn an_edit_needs_its_old_text_exactly_once_in_its_file() {
        assert!(apply(&files(), &edit("main.puf", "(+ x 1)", "(+ x 2)")).is_ok());
        assert!(apply(&files(), &edit("main.puf", "(+ x 9)", "x")).unwrap_err().contains("does not occur"));
        assert!(apply(&files(), &edit("main.puf", "define", "x")).unwrap_err().contains("2 times"));
        assert!(apply(&files(), &edit("nope.puf", "x", "y")).unwrap_err().contains("no file"));
        // an empty old text appends, making the file if need be
        let made = apply(&files(), &edit("new.puf", "", "(define z 3)")).unwrap();
        assert_eq!(made["new.puf"], "(define z 3)\n");
        let added = apply(&files(), &edit("lib.puf", "", "(define (h) 1)")).unwrap();
        assert_eq!(added["lib.puf"], "(provide h)\n\n(define (h) 1)\n");
    }

    /// A thread builds on its own pending proposals; another thread editing
    /// the same text conflicts; an op whose text changed is stale.
    #[test]
    fn threads_fork_conflict_go_stale_and_accept() {
        let mut review = Review::default();
        let a = review.new_thread("a".into());
        let b = review.new_thread("b".into());
        review.open_changeset(a, "a".into(), program_scope());
        review.open_changeset(b, "b".into(), program_scope());
        let first = review.propose(&files(), a, edit("main.puf", "(+ x 1)", "(+ x 10)"), "ten".into()).unwrap();
        // b cannot see a's text
        assert!(review.propose(&files(), b, edit("main.puf", "(+ x 10)", "x"), "".into()).is_err());
        let rival = review.propose(&files(), b, edit("main.puf", "(define (f x) (+ x 1))", "(define (f x) x)"), "".into()).unwrap();
        let view = review.view(&files());
        let op = |id| view.ops.iter().find(|view| view.op.id == id).unwrap();
        assert_eq!(op(first).conflicts, vec![rival]);
        assert!(review.accept(&files(), first).unwrap_err().contains("conflicts"));
        review.reject(rival).unwrap();
        let after = review.accept(&files(), first).unwrap();
        assert_eq!(after["main.puf"], "(define (f x) (+ x 10))\n(define (g y) (* y 2))\n");
        assert!(review.accept(&after, first).unwrap_err().contains("already accepted"));

        // the author edits the proposal's text away: stale
        let next = review.propose(&after, a, edit("main.puf", "(* y 2)", "(* y 3)"), "".into()).unwrap();
        let mut edited = after.clone();
        edited.insert("main.puf".into(), "(define (f x) (+ x 10))\n(define (g y) (* y 4))\n".into());
        assert!(review.view(&edited).ops.iter().find(|v| v.op.id == next).unwrap().stale);
        assert!(review.accept(&edited, next).unwrap_err().contains("no longer applies"));
    }

    #[test]
    fn a_correction_folds_into_the_proposal_it_corrects() {
        let mut review = Review::default();
        let a = review.new_thread("a".into());
        review.open_changeset(a, "a".into(), program_scope());
        let first = review.propose(&files(), a, edit("main.puf", "(* y 2)", "(* y (+ 1 1)"), "doubles".into()).unwrap();
        let fix = review.propose(&files(), a, edit("main.puf", "(+ 1 1)", "(+ 1 1))"), "".into()).unwrap();
        assert_eq!(fix, first);
        assert_eq!(review.ops.len(), 1);
        assert_eq!(review.ops[0].change.new, "(* y (+ 1 1))");
        assert_eq!(review.ops[0].note, "doubles");
    }

    #[test]
    fn scopes_refuse_what_lies_outside_them() {
        let text = MAIN;
        let form = Scope { kind: ScopeKind::Form, file: "main.puf".into(), region: Some("(define (g y) (* y 2))".into()), near: 23 };
        assert!(form.refuses(&edit("main.puf", "(* y 2)", "(* y 3)"), text).is_none());
        assert!(form.refuses(&edit("main.puf", "(+ x 1)", "x"), text).unwrap().contains("outside the form"));
        assert!(form.refuses(&edit("lib.puf", "(provide h)", "x"), text).unwrap().contains("outside it"));
        assert!(form.refuses(&edit("main.puf", "", "(define z 1)"), text).unwrap().contains("append"));
        let module = Scope { kind: ScopeKind::Module, file: "main.puf".into(), region: None, near: 0 };
        assert!(module.refuses(&edit("main.puf", "(+ x 1)", "x"), text).is_none());
        assert!(module.refuses(&edit("lib.puf", "(provide h)", "x"), text).is_some());
        assert!(program_scope().refuses(&edit("lib.puf", "(provide h)", "x"), text).is_none());

        // the region follows the thread's own changes inside it
        let mut review = Review::default();
        let t = review.new_thread("t".into());
        review.open_changeset(t, "t".into(), form);
        review.propose(&files(), t, edit("main.puf", "(* y 2)", "(* y 3)"), "".into()).unwrap();
        let scope = review.scope_of(t).unwrap().clone();
        assert_eq!(scope.region.as_deref(), Some("(define (g y) (* y 3))"));
        let fork = review.fork(&files(), t);
        assert!(scope.refuses(&edit("main.puf", "(* y 3)", "(* y 4)"), &fork["main.puf"]).is_none());
    }
}
