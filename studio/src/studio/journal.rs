//! The journal: what happens in the studio, kept as the project's history
//! (project.rs). Edits, once they settle, are saved and committed together
//! with the records of what else happened -- evaluations, questions, test
//! runs, renames, accepts -- one commit a settled run, its subject naming
//! the files edited and counting the rest. In an untracked project the
//! records are kept for this run alone. The timeline, the replay slider and
//! a commit's diff read it back.

use super::{Entry, Event, Studio};
use crate::project::{self, Moment, Record};
use crate::toolchain::Files;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;

/// How long edits and records settle before they are saved and committed
/// (project.rs), and the longest a run of edits waits.
const JOURNAL_PAUSE: Duration = Duration::from_millis(1500);
const JOURNAL_LONGEST: Duration = Duration::from_secs(15);
/// How much of an entry's output a record keeps.
const RECORD_OUTPUT: usize = 4000;

impl Studio {
    /// Note that something happened: a record for the history, committed
    /// with the next settled edits (in an untracked project, kept for this
    /// run alone).
    pub fn record(&self, kind: &str, data: Value) {
        self.journal.lock().expect("journal lock").push(Record::new(kind, data));
        if self.tracked {
            self.journal_due.notify_one();
        }
    }

    /// A finished transcript entry as a record: what was typed or asked,
    /// what came back (briefly), and how it ended.
    pub(super) fn record_entry(&self, entry: &Entry) {
        let mut out = String::new();
        for (stream, text) in &entry.out {
            if stream == "result" {
                out.push_str("=> ");
            }
            out.push_str(text);
            if !out.ends_with('\n') {
                out.push('\n');
            }
        }
        let out = clip(&out, RECORD_OUTPUT);
        let mut data = json!({ "line": entry.line, "status": entry.status, "ms": entry.ms });
        let object = data.as_object_mut().expect("an object");
        if !entry.origin.is_empty() {
            object.insert("origin".into(), json!(entry.origin));
        }
        if !entry.command.is_empty() {
            object.insert("command".into(), json!(entry.command));
        }
        if let Some(file) = &entry.file {
            object.insert("file".into(), json!(file));
        }
        if !out.is_empty() {
            object.insert("out".into(), json!(out));
        }
        if let Some(error) = &entry.error {
            object.insert("error".into(), json!(error));
        }
        if let Some(thread) = entry.thread {
            object.insert("thread".into(), json!(thread));
            object.insert("turn".into(), json!(entry.turn));
        }
        if let Some(tests) = &entry.tests {
            object.insert("tests".into(), json!({ "passed": tests.passed, "failed": tests.failed, "not_run": tests.not_run }));
        }
        self.record(entry.kind, data);
    }

    /// Save and commit after edits and records settle, and at the latest
    /// JOURNAL_LONGEST after the first of a run.
    pub(super) fn watch_journal(self: &Arc<Self>) {
        if !self.tracked {
            return;
        }
        let studio = Arc::downgrade(self);
        let due = self.journal_due.clone();
        tokio::spawn(async move {
            loop {
                due.notified().await;
                let started = tokio::time::Instant::now();
                while tokio::time::timeout(JOURNAL_PAUSE, due.notified()).await.is_ok() {
                    if started.elapsed() > JOURNAL_LONGEST {
                        break;
                    }
                }
                let Some(studio) = studio.upgrade() else { return };
                studio.flush_journal().await;
            }
        });
    }

    /// Write the edited files, and commit them with the pending records as
    /// one commit; nothing to commit is nothing done. In an untracked
    /// project, nothing.
    pub async fn flush_journal(&self) {
        if !self.tracked {
            return;
        }
        if let Err(error) = self.save() {
            self.notice(error);
        }
        let files = self.files();
        let mut edits = Vec::new();
        {
            let committed = self.committed.lock().expect("committed lock");
            for (path, text) in &files {
                let before = committed.get(path).map(String::as_str).unwrap_or("");
                if before != text {
                    let forms = crate::versions::changed_forms(path, before, text);
                    edits.push(Record::new("edit", json!({ "file": path, "forms": forms, "new": !committed.contains_key(path) })));
                }
            }
        }
        let mut records = edits;
        records.append(&mut self.journal.lock().expect("journal lock"));
        if records.is_empty() {
            return;
        }
        records.sort_by_key(|record| record.at);
        let subject = subject_of(&records);
        let directory = self.directory.clone();
        let moved = records.clone();
        let outcome = tokio::task::spawn_blocking(move || project::commit(&directory, &subject, &moved)).await.unwrap_or_else(|e| Err(e.to_string()));
        match outcome {
            Ok(_) => {
                *self.committed.lock().expect("committed lock") = files;
                *self.journal_failed.lock().expect("journal lock") = false;
                self.publish(Event::Journal);
            }
            Err(error) => {
                // keep the records for the next try
                let mut journal = self.journal.lock().expect("journal lock");
                let mut kept = records.into_iter().filter(|record| record.kind != "edit").collect::<Vec<_>>();
                kept.append(&mut journal);
                *journal = kept;
                drop(journal);
                let mut failed = self.journal_failed.lock().expect("journal lock");
                if !*failed {
                    *failed = true;
                    self.notice(format!("the history could not be committed: {error}"));
                }
            }
        }
    }

    /// The timeline, oldest first: what git holds, then what is pending.
    pub async fn history(&self) -> Result<Vec<Moment>, String> {
        let directory = self.directory.clone();
        let mut moments = if self.tracked {
            tokio::task::spawn_blocking(move || project::history(&directory)).await.unwrap_or_else(|e| Err(e.to_string()))?
        } else {
            Vec::new()
        };
        for record in self.journal.lock().expect("journal lock").iter() {
            moments.push(Moment { at: record.at, kind: record.kind.clone(), commit: None, data: record.data.clone() });
        }
        Ok(moments)
    }

    /// The files as commit `hash` left them (the replay slider).
    pub async fn files_at(&self, hash: String) -> Result<Files, String> {
        let directory = self.directory.clone();
        tokio::task::spawn_blocking(move || project::files_at(&directory, &hash)).await.unwrap_or_else(|e| Err(e.to_string()))
    }

    /// What commit `hash` changed, as a unified diff.
    pub async fn history_diff(&self, hash: String) -> Result<String, String> {
        let directory = self.directory.clone();
        tokio::task::spawn_blocking(move || project::diff(&directory, &hash)).await.unwrap_or_else(|e| Err(e.to_string()))
    }
}

/// A commit's subject line for `records`: the files edited, then what else
/// happened, counted.
fn subject_of(records: &[Record]) -> String {
    let mut parts = Vec::new();
    let edited: Vec<&str> = records.iter().filter(|r| r.kind == "edit").filter_map(|r| r.data["file"].as_str()).collect();
    if !edited.is_empty() {
        parts.push(format!("edit {}", edited.join(", ")));
    }
    for kind in ["rename", "delete", "eval", "ask", "test", "accept", "restore", "echo", "disk", "session"] {
        let count = records.iter().filter(|r| r.kind == kind).count();
        match count {
            0 => {}
            1 => parts.push(kind.to_owned()),
            n => parts.push(format!("{kind} ×{n}")),
        }
    }
    if parts.is_empty() { "studio".to_owned() } else { parts.join(" · ") }
}

/// At most `limit` bytes of `text`, cut at a character, with a note.
fn clip(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_owned();
    }
    let mut end = limit;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}… ({} bytes cut)", &text[..end], text.len() - end)
}

#[cfg(test)]
mod tests {
    use super::{clip, subject_of};
    use crate::project::Record;
    use serde_json::json;

    #[test]
    fn commit_subjects_name_the_files_and_count_the_rest() {
        let records = [
            Record::new("edit", json!({ "file": "calc.puf" })),
            Record::new("eval", json!({})),
            Record::new("eval", json!({})),
            Record::new("ask", json!({})),
        ];
        assert_eq!(subject_of(&records), "edit calc.puf · eval ×2 · ask");
        assert_eq!(subject_of(&[Record::new("rename", json!({})), Record::new("edit", json!({ "file": "main.puf" }))]), "edit main.puf · rename");
        assert_eq!(subject_of(&[]), "studio");
        assert_eq!(clip("héllo", 2), "h… (5 bytes cut)");
        assert_eq!(clip("hi", 2), "hi");
    }
}
