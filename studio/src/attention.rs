//! The attention log (docs/ATTENTION.md §3): what the page showed the
//! author and what the author then did with it, one JSON record a line,
//! kept so the attention model (web/attention.js) can learn this author's
//! preferences.
//!
//! It is the author's behaviour, not the program's, so it stays on this
//! machine: in `.puffin/attention-log.jsonl`, listed in the repository's
//! own `.git/info/exclude` (never in the project's `.gitignore`, which is
//! committed) so the studio's commits leave it out. It is bounded: past
//! `MAX_BYTES` the older half goes. The studio only keeps it; the page
//! does the learning, from the whole log, when it opens.

use std::io::Write;
use std::path::Path;
use std::sync::Mutex;

pub const LOG: &str = ".puffin/attention-log.jsonl";
/// The log's ceiling: a few months of a busy author's records.
pub const MAX_BYTES: usize = 2 << 20;
/// No one record is bigger than this (an impression of a whole screen is
/// a few kilobytes).
const MAX_RECORD: usize = 32 << 10;

/// Appends and trims from two tabs must not interleave.
static WRITING: Mutex<()> = Mutex::new(());

/// Append the records in `body` (JSON objects, one a line, each with a
/// string `t`); lines that are not are dropped. Returns how many were kept.
pub fn append(directory: &Path, body: &str) -> Result<usize, String> {
    let records: Vec<&str> = body
        .lines()
        .map(str::trim)
        .filter(|line| line.len() <= MAX_RECORD)
        .filter(|line| serde_json::from_str::<serde_json::Value>(line).is_ok_and(|v| v.get("t").is_some_and(|t| t.is_string())))
        .collect();
    if records.is_empty() {
        return Ok(0);
    }
    let _writing = WRITING.lock().expect("attention log lock");
    let path = directory.join(LOG);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| format!("cannot make .puffin: {error}"))?;
    }
    exclude(directory)?;
    let lines: String = records.iter().map(|record| format!("{record}\n")).collect();
    std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(&path)
        .and_then(|mut file| file.write_all(lines.as_bytes()))
        .map_err(|error| format!("cannot write {LOG}: {error}"))?;
    trim(&path)?;
    Ok(records.len())
}

/// The whole log ("" when there is none).
pub fn read(directory: &Path) -> String {
    std::fs::read_to_string(directory.join(LOG)).unwrap_or_default()
}

/// Past the ceiling, keep the newer half, whole lines only.
fn trim(path: &Path) -> Result<(), String> {
    let size = std::fs::metadata(path).map(|m| m.len() as usize).unwrap_or(0);
    if size <= MAX_BYTES {
        return Ok(());
    }
    let text = std::fs::read_to_string(path).map_err(|error| format!("cannot read {LOG}: {error}"))?;
    let from = text.len() - MAX_BYTES / 2;
    let start = text[from..].find('\n').map_or(text.len(), |i| from + i + 1);
    std::fs::write(path, &text[start..]).map_err(|error| format!("cannot trim {LOG}: {error}"))
}

/// Keep the log out of the project's commits: the repository's local
/// exclude list, which is itself never committed.
fn exclude(directory: &Path) -> Result<(), String> {
    let git = directory.join(".git");
    if !git.is_dir() {
        return Ok(());
    }
    let list = git.join("info").join("exclude");
    let line = format!("/{LOG}");
    let current = std::fs::read_to_string(&list).unwrap_or_default();
    if current.lines().any(|l| l.trim() == line) {
        return Ok(());
    }
    std::fs::create_dir_all(git.join("info")).map_err(|error| format!("cannot make .git/info: {error}"))?;
    let separator = if current.is_empty() || current.ends_with('\n') { "" } else { "\n" };
    std::fs::write(&list, format!("{current}{separator}{line}\n")).map_err(|error| format!("cannot write .git/info/exclude: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temporary(name: &str) -> std::path::PathBuf {
        let directory = std::env::temp_dir().join(format!("puffin-studio-attention-{}-{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        directory
    }

    #[test]
    fn keeps_records_and_drops_the_rest() {
        let directory = temporary("append");
        let kept = append(&directory, "{\"t\":\"shown\",\"items\":[]}\nnot json\n{\"no\":\"type\"}\n\n{\"t\":\"pull\",\"id\":\"a.puf::f\"}\n").unwrap();
        assert_eq!(kept, 2);
        let log = read(&directory);
        assert_eq!(log.lines().count(), 2);
        assert!(log.lines().all(|l| l.starts_with("{\"t\":")));
    }

    #[test]
    fn stays_under_its_ceiling_in_whole_lines() {
        let directory = temporary("trim");
        let record = format!("{{\"t\":\"dwell\",\"pad\":\"{}\"}}", "x".repeat(1000));
        let batch: String = (0..200).map(|_| format!("{record}\n")).collect();
        for _ in 0..15 {
            append(&directory, &batch).unwrap();
        }
        let log = read(&directory);
        assert!(log.len() <= MAX_BYTES);
        assert!(log.len() >= MAX_BYTES / 4);
        assert!(log.lines().all(|l| l == record));
    }

    #[test]
    fn is_never_committed() {
        let directory = temporary("exclude");
        crate::project::git(&directory, &["init", "-q"]).unwrap();
        std::fs::write(directory.join("main.puf"), "(println 1)\n").unwrap();
        append(&directory, "{\"t\":\"open\"}\n").unwrap();
        append(&directory, "{\"t\":\"open\"}\n").unwrap();
        let exclude = std::fs::read_to_string(directory.join(".git/info/exclude")).unwrap();
        assert_eq!(exclude.matches(LOG).count(), 1);
        let status = crate::project::git(&directory, &["status", "--porcelain", "--untracked-files=all"]).unwrap();
        assert!(status.contains("main.puf"));
        assert!(!status.contains("attention"), "{status}");
    }
}
