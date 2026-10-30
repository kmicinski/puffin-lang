//! The studio's side of the assistant (docs/STUDIO.md §6): questions asked
//! at the prompt in ask mode, the context each carries, the proposals it
//! makes, and the author's accept and reject.
//!
//! No assistant-written code reaches the author without passing the check,
//! at two gates (typed holes aside: a program whose check stops at a `??`
//! passes, as the assistant may leave a hole for the author to fill):
//! - a proposal is refused, with the located errors as the tool's answer,
//!   unless the thread's program as it would leave it checks, and unless it
//!   stays inside the turn's scope;
//! - accepting checks the program accepting makes, taking along the earlier
//!   ops of its thread it builds on, and is refused if that fails. Each
//!   pending op's acceptance is kept current for the Accept controls.

use crate::agent::{self, Agent};
use crate::review::{Acceptance, Change, Message, Review, Scope, ScopeKind, Status, apply};
use crate::sexp;
use crate::studio::{Entry, Studio};
use crate::toolchain::{self, Files};
use serde::Deserialize;
use serde_json::{Value, json};
use std::fmt::Write;
use std::hash::{Hash, Hasher};
use std::sync::Arc;

/// What the prompt knows when a question is asked.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Context {
    /// The focused file.
    #[serde(default)]
    pub file: Option<String>,
    /// The selection in it, as UTF-16 offsets (what the editor counts).
    #[serde(default)]
    pub selection: Option<(usize, usize)>,
    /// The cursor, as a UTF-16 offset.
    #[serde(default)]
    pub cursor: Option<usize>,
    #[serde(default)]
    pub scope: ScopeKind,
}

/// How much of a module a question carries; get_file reads the rest.
const MODULE_CHARS: usize = 16_000;
/// REPL entries a question carries.
const RECENT: usize = 8;

impl Studio {
    /// Ask in `thread`, or in a new thread. Returns its id; the run's
    /// progress arrives as agent events.
    pub fn ask(self: &Arc<Self>, thread: Option<u32>, message: String, context: Context) -> Result<u32, String> {
        if let Some(why) = Agent::unavailable() {
            return Err(why);
        }
        let message = message.trim().to_owned();
        if message.is_empty() {
            return Err("ask something".to_owned());
        }
        let scope = self.scope(&context)?;
        let preamble = self.preamble(&context, &scope);
        let mut review = self.review.lock().expect("review lock");
        let thread = match thread.filter(|id| review.thread(*id).is_some()) {
            Some(id) if self.agent.is_running(id) => {
                return Err("still answering: wait for it, or press Esc and ask anew".to_owned());
            }
            Some(id) => id,
            None => review.new_thread(agent::title_of(&message)),
        };
        let entry = review.thread_mut(thread).expect("the thread exists");
        let turn = entry.messages.iter().filter(|m| m.role == "user").count();
        entry.messages.push(Message::new("user", &message, json!({ "scope": scope.kind, "file": scope.file })));
        entry.running = true;
        review.open_changeset(thread, agent::title_of(&message), scope);
        drop(review);
        self.begin(Entry { kind: "ask", line: message.clone(), thread: Some(thread), turn: Some(turn), ..Entry::default() });
        self.publish_review();
        let studio = self.clone();
        tokio::spawn(async move {
            let observed = studio.observed_of_focus(&context).await;
            agent::run(studio, thread, message, format!("{preamble}{observed}The author asks:")).await;
        });
        Ok(thread)
    }

    pub fn stop_thread(&self, thread: u32) -> bool {
        self.agent.stop(thread)
    }

    /// The scope a question asks at, with the text it covers.
    fn scope(&self, context: &Context) -> Result<Scope, String> {
        let file = context.file.clone().unwrap_or_default();
        let text = self.text_of(&file).unwrap_or_default();
        let mut scope = Scope { kind: context.scope.clone(), file: file.clone(), region: None, near: 0 };
        match context.scope {
            ScopeKind::Program => {}
            ScopeKind::Module => {
                if file.is_empty() {
                    return Err("no file is focused for a module-scoped question".to_owned());
                }
            }
            ScopeKind::Selection => {
                let (start, end) = context.selection.filter(|(start, end)| start != end).ok_or("nothing is selected")?;
                let (start, end) = (sexp::byte_of_utf16(&text, start), sexp::byte_of_utf16(&text, end));
                scope.region = Some(text[start.min(end)..end.max(start)].to_owned());
                scope.near = start.min(end);
            }
            ScopeKind::Form => {
                let cursor = sexp::byte_of_utf16(&text, context.cursor.unwrap_or(0));
                match sexp::form_at(&text, cursor) {
                    Some(form) => {
                        scope.region = Some(text[form.start..form.end].to_owned());
                        scope.near = form.start;
                    }
                    // no form at the cursor: the module is the scope
                    None => scope.kind = ScopeKind::Module,
                }
            }
        }
        Ok(scope)
    }

    /// A question's preamble: the studio, the focus, the scope's rule, the
    /// diagnostics, and the latest REPL lines. The line of observations and
    /// the question follow it.
    fn preamble(&self, context: &Context, scope: &Scope) -> String {
        let files = self.files();
        let mut out = String::from("(Puffin Studio session.)\n");
        let _ = writeln!(
            out,
            "Project {} — files: {}.",
            self.directory.display(),
            files.keys().cloned().collect::<Vec<_>>().join(", ")
        );
        let file = &scope.file;
        let text = files.get(file).cloned().unwrap_or_default();
        match scope.kind {
            ScopeKind::Selection | ScopeKind::Form => {
                let region = scope.region.clone().unwrap_or_default();
                let line = sexp::line_of(&text, scope.near);
                let what = if scope.kind == ScopeKind::Form { "form at the cursor" } else { "selection" };
                let _ = writeln!(
                    out,
                    "Scope: the {what} in {file}, from line {line}. Proposals may change only text inside it.\n```puffin\n{}\n```",
                    region.trim_end()
                );
            }
            ScopeKind::Module => {
                let cut = toolchain::clip(&text, MODULE_CHARS);
                let _ = writeln!(out, "Scope: the module {file}. Proposals may change only this file.\n```puffin\n{}\n```", cut.trim_end());
            }
            ScopeKind::Program => {
                let _ = writeln!(out, "Scope: the whole program; any file may change, and new files may be made.");
                if !file.is_empty() {
                    let cursor = context.cursor.map(|c| sexp::byte_of_utf16(&text, c)).unwrap_or(0);
                    if let Some(form) = sexp::form_at(&text, cursor) {
                        let _ = writeln!(
                            out,
                            "The author is in {file}, at the form on line {}:\n```puffin\n{}\n```",
                            form.line,
                            &text[form.start..form.end]
                        );
                    }
                }
            }
        }
        let diagnostics: Vec<String> = files
            .keys()
            .flat_map(|path| self.diagnostics_of(path))
            .map(|d| format!("{}: {} [{}:{}]", d.severity, d.message, d.file, d.line))
            .collect();
        if !diagnostics.is_empty() {
            let _ = writeln!(out, "Current diagnostics:\n{}", diagnostics.join("\n"));
        }
        let recent = self.recent(RECENT);
        if !recent.is_empty() {
            let _ = writeln!(out, "Recent REPL entries, oldest first:");
            for entry in recent {
                let _ = writeln!(out, "› {}", toolchain::clip(entry.line.trim(), 600));
                let shown: String = entry
                    .out
                    .iter()
                    .map(|(stream, text)| if stream == "result" { format!("=> {text}\n") } else { text.clone() })
                    .collect();
                for line in toolchain::clip(&shown, 600).lines().take(10) {
                    let _ = writeln!(out, "  {line}");
                }
                if let Some(error) = &entry.error {
                    let _ = writeln!(out, "  error: {}", toolchain::clip(error, 400));
                }
            }
        }
        out
    }

    /// The line of observations of the focused form a question carries,
    /// or nothing.
    async fn observed_of_focus(&self, context: &Context) -> String {
        let Some(file) = context.file.clone() else { return String::new() };
        let text = self.text_of(&file).unwrap_or_default();
        let cursor = sexp::byte_of_utf16(&text, context.cursor.or(context.selection.map(|(start, _)| start)).unwrap_or(0));
        match self.observed_line(&file, cursor).await {
            Some(line) => format!("Observed in the live session (sampled shapes of real arguments; evidence, not proof): {line}\n"),
            None => String::new(),
        }
    }

    // ---- Tools (mcp.rs) ---------------------------------------------------------

    /// The program as `thread` sees it.
    pub(crate) fn fork_of(&self, thread: u32) -> Files {
        let files = self.files();
        self.review.lock().expect("review lock").fork(&files, thread)
    }

    /// Propose `change` if it stays in the turn's scope and the thread's
    /// program as it leaves it passes the check; else refuse it with why.
    pub(crate) async fn propose(&self, thread: u32, change: Change, note: String) -> Result<Value, String> {
        if !change.old.is_empty() || !self.files().contains_key(&change.file) {
            crate::studio::valid_path(&change.file).map_err(|why| format!("Refused: {why}"))?;
        }
        let files = self.files();
        let (fork, scope) = {
            let review = self.review.lock().expect("review lock");
            (review.fork(&files, thread), review.scope_of(thread).cloned())
        };
        let scope = scope.ok_or("this thread has no turn in progress")?;
        if let Some(why) = scope.refuses(&change, fork.get(&change.file).map_or("", String::as_str)) {
            return Err(why);
        }
        let after = apply(&fork, &change)?;
        let report = self.check_program(&after, std::slice::from_ref(&change.file)).await;
        if !report.passes() {
            let before = self.check_program(&fork, std::slice::from_ref(&change.file)).await;
            let also = if before.passes() { "" } else { "\nThe program fails the check without this change too: fix those errors as well." };
            return Err(format!(
                "Refused: the program as this would leave it fails the check, so nothing was proposed. Fix it and propose again:\n{}{also}",
                report.describe()
            ));
        }
        let holes: usize = after.values().map(|text| sexp::holes(text).len()).sum();
        let id = self.review.lock().expect("review lock").propose(&files, thread, change, note)?;
        self.publish_review();
        let checks = if report.holed() {
            format!("the program as your proposals leave it has {holes} typed hole(s) (??); it passes the check up to the first hole, and nothing past that hole was checked")
        } else {
            "the program as your proposals leave it passes the check".to_owned()
        };
        Ok(json!({
            "proposed": id,
            "checks": checks,
            "warnings": report.diagnostics.iter().filter(|d| d.severity == "warning").map(|d| format!("{} [{}:{}]", d.message, d.file, d.line)).collect::<Vec<_>>(),
            "message": "queued for the author to accept or reject; nothing changed yet",
        }))
    }

    /// Accept these ops in order, with the earlier ops of their threads each
    /// builds on, as one change per file.
    pub async fn accept(&self, ids: &[u32]) -> Result<(), String> {
        let mut files = self.files();
        let mut accepted = Vec::new();
        let mut changed: Vec<String> = Vec::new();
        let mut review = self.review_copy();
        for &id in ids {
            let with = self.acceptance(&files, &review, id).await;
            if !with.ok {
                return Err(format!("#{id} cannot be accepted: {}", with.reason));
            }
            for op in with.with.iter().copied().chain(std::iter::once(id)) {
                if accepted.contains(&op) {
                    continue;
                }
                let file = review.op(op).map(|op| op.change.file.clone()).unwrap_or_default();
                files = review.accept(&files, op)?;
                accepted.push(op);
                if !changed.contains(&file) {
                    changed.push(file);
                }
            }
        }
        let report = self.check_program(&files, &changed).await;
        if !report.passes() {
            return Err(format!("accepting leaves the program failing the check:\n{}", report.describe()));
        }
        {
            let mut live = self.review.lock().expect("review lock");
            for &op in &accepted {
                live.mark_accepted(op);
            }
        }
        let label: Vec<String> = accepted
            .iter()
            .map(|id| {
                let note = self.review.lock().expect("review lock").op(*id).map(|op| op.note.clone()).unwrap_or_default();
                if note.is_empty() { format!("#{id}") } else { format!("#{id} {note}") }
            })
            .collect();
        for file in &changed {
            if let Some(text) = files.get(file) {
                self.replace(file, text.clone(), "accept", &label.join("; "));
            }
        }
        self.echo(&format!(",accept {}", accepted.iter().map(|id| format!("#{id}")).collect::<Vec<_>>().join(" ")));
        self.publish_review();
        Ok(())
    }

    pub async fn accept_changeset(&self, changeset: u32) -> Result<(), String> {
        let ids = self.review.lock().expect("review lock").pending_of(changeset);
        if ids.is_empty() {
            return Err("nothing pending in that changeset".to_owned());
        }
        self.accept(&ids).await
    }

    pub fn reject(&self, id: u32) -> Result<(), String> {
        self.review.lock().expect("review lock").reject(id)?;
        self.echo(&format!(",reject #{id}"));
        self.publish_review();
        Ok(())
    }

    fn review_copy(&self) -> Review {
        self.review.lock().expect("review lock").clone()
    }

    /// What accepting pending op `id` into `files` would take: the op alone
    /// if the result checks, else with the earlier ops of its thread.
    pub(crate) async fn acceptance(&self, files: &Files, review: &Review, id: u32) -> Acceptance {
        let Some((change, before)) = review.chain(id) else {
            return Acceptance { reason: format!("#{id} is not pending"), ..Acceptance::default() };
        };
        let made = |with: &[(u32, Change)]| {
            with.iter()
                .map(|(_, change)| change)
                .chain(std::iter::once(&change))
                .try_fold(files.clone(), |files, change| apply(&files, change).ok())
        };
        let touched = |with: &[(u32, Change)]| {
            let mut out: Vec<String> = with.iter().map(|(_, c)| c.file.clone()).collect();
            out.push(change.file.clone());
            out
        };
        let mut failure = None;
        if let Some(alone) = made(&[]) {
            let report = self.check_program(&alone, &touched(&[])).await;
            if report.passes() {
                return Acceptance { ok: true, ..Acceptance::default() };
            }
            failure = Some(report.describe());
        }
        if !before.is_empty()
            && let Some(all) = made(&before)
            && self.check_program(&all, &touched(&before)).await.passes()
        {
            return Acceptance { ok: true, with: before.iter().map(|(id, _)| *id).collect(), reason: String::new() };
        }
        let reason = match failure {
            Some(errors) => format!("accepting it leaves the program failing the check:\n{errors}"),
            None => "it no longer applies, or builds on earlier proposals that no longer apply".to_owned(),
        };
        Acceptance { ok: false, with: Vec::new(), reason }
    }

    /// Keep each pending op's acceptance current: checked again whenever the
    /// review or the program changes, and shown to every tab.
    pub(crate) fn watch_proposals(self: &Arc<Self>) {
        let studio = Arc::downgrade(self);
        let changed = self.review_changed.clone();
        tokio::spawn(async move {
            loop {
                changed.notified().await;
                tokio::time::sleep(std::time::Duration::from_millis(150)).await;
                let Some(studio) = studio.upgrade() else { return };
                if studio.refresh_acceptances().await {
                    studio.publish(crate::studio::Event::Review(studio.review_view()));
                }
            }
        });
    }

    async fn refresh_acceptances(&self) -> bool {
        let files = self.files();
        let review = self.review_copy();
        let pending: Vec<(u32, u64)> = review
            .view(&files)
            .ops
            .iter()
            .filter(|op| op.op.status == Status::Pending)
            .map(|op| (op.op.id, acceptance_key(&files, &review, op.op.id)))
            .collect();
        let mut checked = false;
        for (id, key) in pending {
            let known = self.acceptances.lock().expect("acceptances lock").get(&id).is_some_and(|(k, _)| *k == key);
            if !known {
                let check = self.acceptance(&files, &review, id).await;
                self.acceptances.lock().expect("acceptances lock").insert(id, (key, check));
                checked = true;
            }
        }
        checked
    }

    /// Apply the assist `id` at byte `pos` (or for the selection [pos,
    /// end)), computed on the thread's fork, as a proposal: the forms the
    /// edits touch, before and after. `title` picks among assists that
    /// share the id.
    pub(crate) async fn propose_assist(
        &self,
        thread: u32,
        file: &str,
        (pos, end): (usize, Option<usize>),
        id: &str,
        title: Option<&str>,
        note: String,
    ) -> Result<Value, String> {
        let fork = self.fork_of(thread);
        let text = fork.get(file).ok_or_else(|| format!("there is no file {file}"))?.clone();
        let args = [Some(pos), end].into_iter().flatten().map(|n| n.to_string()).collect();
        let answer = self.toolchain.assist_with(&fork, "assists", file, args).await.map_err(|report| report.describe())?;
        let assist = answer["assists"]
            .as_array()
            .and_then(|list| list.iter().find(|assist| assist["id"] == id && title.is_none_or(|title| assist["title"] == title)))
            .ok_or_else(|| format!("no assist `{id}`{} applies at {file}:{pos}", title.map(|t| format!(" titled `{t}`")).unwrap_or_default()))?;
        let edits = edits_of(assist)?;
        let (old, new) = anchored(&text, &edits)?;
        let note = if note.is_empty() { assist["title"].as_str().unwrap_or(id).to_owned() } else { note };
        self.propose(thread, Change { file: file.to_owned(), old, new }, note).await
    }
}

/// An assist's edits: (start, end, text), byte offsets.
pub fn edits_of(assist: &Value) -> Result<Vec<(usize, usize, String)>, String> {
    assist["edits"]
        .as_array()
        .ok_or("the assist has no edits")?
        .iter()
        .map(|edit| {
            let at = |key: &str| edit[key].as_u64().map(|n| n as usize).ok_or(format!("an edit without `{key}`"));
            Ok((at("start")?, at("end")?, edit["text"].as_str().unwrap_or("").to_owned()))
        })
        .collect()
}

/// `edits` (byte spans into `text`) as one exact-text change: the top-level
/// forms they touch, before and after, widened until the old text is unique.
pub fn anchored(text: &str, edits: &[(usize, usize, String)]) -> Result<(String, String), String> {
    if edits.is_empty() {
        return Err("the assist makes no edit".to_owned());
    }
    let low = edits.iter().map(|e| e.0).min().unwrap_or(0).min(text.len());
    let high = edits.iter().map(|e| e.1).max().unwrap_or(0).min(text.len());
    let forms = sexp::forms(text);
    let mut start = forms.iter().filter(|f| f.start <= low).map(|f| f.start).max().unwrap_or(0);
    let mut end = forms.iter().filter(|f| f.end >= high).map(|f| f.end).min().unwrap_or(text.len()).max(high);
    while text[start..end].is_empty() || text.matches(&text[start..end]).count() > 1 {
        if start == 0 && end == text.len() {
            break;
        }
        let wider = (
            forms.iter().filter(|f| f.start < start).map(|f| f.start).max().unwrap_or(0),
            forms.iter().filter(|f| f.end > end).map(|f| f.end).min().unwrap_or(text.len()),
        );
        if wider == (start, end) {
            break;
        }
        (start, end) = wider;
    }
    let mut sorted = edits.to_vec();
    sorted.sort_by_key(|e| std::cmp::Reverse(e.0));
    let mut new = text[start..end].to_owned();
    for (edit_start, edit_end, replacement) in sorted {
        let (a, b) = (edit_start.clamp(start, end) - start, edit_end.clamp(start, end) - start);
        new.replace_range(a..b, &replacement);
    }
    Ok((text[start..end].to_owned(), new))
}

/// What a pending op's acceptance was checked against: the files and the
/// op's chain.
pub(crate) fn acceptance_key(files: &Files, review: &Review, id: u32) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    files.hash(&mut hasher);
    if let Some((change, before)) = review.chain(id) {
        (change.file, change.old, change.new).hash(&mut hasher);
        for (op, change) in before {
            (op, change.file, change.old, change.new).hash(&mut hasher);
        }
    }
    hasher.finish()
}

#[cfg(test)]
mod tests {
    use super::anchored;

    #[test]
    fn an_assist_becomes_an_exact_text_change_of_whole_forms() {
        let text = "(define (f x) x)\n(define (g e)\n  (match e))\n";
        let at = text.find("(match e)").unwrap() + "(match e".len();
        let (old, new) = anchored(text, &[(at, at, " [(Num n) n]".to_owned())]).unwrap();
        assert_eq!(old, "(define (g e)\n  (match e))");
        assert_eq!(new, "(define (g e)\n  (match e [(Num n) n]))");
        // a form that occurs twice widens to its neighbour
        let twice = "(define a 1)\n(f)\n(define b 2)\n(f)\n";
        let at = twice.rfind("(f)").unwrap() + 2;
        let (old, new) = anchored(twice, &[(at, at, " 1".to_owned())]).unwrap();
        assert_eq!(twice.matches(&old).count(), 1);
        assert!(new.trim_end().ends_with("(f 1)"), "{new}");
    }
}
