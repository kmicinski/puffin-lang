//! Projects, and their history in git.
//!
//! A project is a directory of Puffin files. One made from the studio
//! lives under the projects home (`PUFFIN_PROJECTS`, else `~/Puffin`),
//! named or given a short random name, and is a git repository from its
//! first moment. A directory opened from the command line is adopted the
//! same way unless it sits inside another repository.
//!
//! In a tracked project the studio keeps the history itself: edits are
//! saved and committed as they settle, and everything else that happens
//! -- an evaluation, a question to the assistant and its answer, a test
//! run, a gesture -- is a timestamped **record** appended to
//! `.puffin/journal.jsonl` and carried in the commit's message, one JSON
//! line each. The git log is the history's ground truth: `history`
//! rebuilds the timeline from it, so a clone has the whole story, and a
//! commit made by hand shows up as one too. Nothing here depends on a
//! studio: the functions take a directory.

use serde::Serialize;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::Command;

/// One thing that happened, as the journal and the commit bodies carry it.
#[derive(Clone, Debug, Serialize)]
pub struct Record {
    /// Milliseconds since the epoch.
    pub at: u64,
    /// "edit", "eval", "ask", "test", "echo", "accept", "restore",
    /// "disk", "session", "project".
    pub kind: String,
    #[serde(flatten)]
    pub data: Value,
}

impl Record {
    pub fn new(kind: &str, data: Value) -> Self {
        Self { at: crate::review::now(), kind: kind.to_owned(), data }
    }

    /// The JSON line the journal and the commit body hold.
    pub fn line(&self) -> String {
        serde_json::to_string(self).expect("records serialize")
    }

    /// A record from a journal or commit-body line; None for any other line.
    pub fn parse(line: &str) -> Option<Self> {
        let mut value: Value = serde_json::from_str(line.trim()).ok()?;
        let object = value.as_object_mut()?;
        let at = object.remove("at")?.as_u64()?;
        let kind = object.remove("kind")?.as_str()?.to_owned();
        Some(Self { at, kind, data: value })
    }
}

/// One moment of the timeline, as the History panel lists it: a record,
/// with the commit it landed in (none while it is still pending), or a
/// commit made outside the studio, as `kind` "commit".
#[derive(Clone, Debug, Serialize)]
pub struct Moment {
    pub at: u64,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    #[serde(flatten)]
    pub data: Value,
}

/// A project under the home, for the Projects menu.
#[derive(Clone, Debug, Serialize)]
pub struct Listed {
    pub name: String,
    pub directory: String,
    /// Milliseconds since the epoch, of the latest change.
    pub modified: u64,
}

/// Where the studio's projects live: PUFFIN_PROJECTS, else ~/Puffin.
pub fn home() -> PathBuf {
    if let Some(home) = std::env::var_os("PUFFIN_PROJECTS") {
        return PathBuf::from(home);
    }
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join("Puffin")
}

/// The projects under `home`, latest changed first.
pub fn list(home: &Path) -> Vec<Listed> {
    let Ok(entries) = std::fs::read_dir(home) else { return Vec::new() };
    let mut out: Vec<Listed> = entries
        .flatten()
        .filter(|entry| entry.path().is_dir() && !entry.file_name().to_string_lossy().starts_with('.'))
        .map(|entry| {
            let directory = entry.path();
            let modified = latest_change(&directory);
            Listed { name: entry.file_name().to_string_lossy().into_owned(), directory: directory.display().to_string(), modified }
        })
        .collect();
    out.sort_by(|a, b| b.modified.cmp(&a.modified).then_with(|| a.name.cmp(&b.name)));
    out
}

/// When the project last changed: its last commit, else its directory's
/// modification time.
fn latest_change(directory: &Path) -> u64 {
    if tracked(directory)
        && let Ok(out) = git(directory, &["log", "-1", "--format=%ct"])
        && let Ok(seconds) = out.trim().parse::<u64>()
    {
        return seconds * 1000;
    }
    std::fs::metadata(directory)
        .and_then(|meta| meta.modified())
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |since| since.as_millis() as u64)
}

/// A project name: letters, digits, `-`, `_` and `.`, not starting with a
/// dot, at most 64 characters.
pub fn valid_name(name: &str) -> Result<&str, String> {
    let name = name.trim();
    if name.is_empty() {
        return Err("a project needs a name".to_owned());
    }
    if name.len() > 64 {
        return Err("a project name has at most 64 characters".to_owned());
    }
    if name.starts_with('.') || !name.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c)) {
        return Err(format!("{name:?} is not a project name: letters, digits, - _ and . only"));
    }
    Ok(name)
}

/// A short random name, like git's short hashes: seven hex characters.
pub fn random_name() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
    hasher.write_u64(crate::review::now());
    hasher.write_u32(std::process::id());
    format!("{:016x}", hasher.finish())[..7].to_owned()
}

/// Make the project `name` (a random one when None) under `home`: its
/// directory, a first `main.puf`, and a repository with that as its
/// first commit. Returns the directory.
pub fn create(home: &Path, name: Option<&str>) -> Result<PathBuf, String> {
    let name = match name {
        Some(name) => valid_name(name)?.to_owned(),
        None => random_name(),
    };
    let directory = home.join(&name);
    if directory.exists() {
        return Err(format!("a project named {name} exists already"));
    }
    std::fs::create_dir_all(&directory).map_err(|error| format!("cannot make {}: {error}", directory.display()))?;
    let main = format!(";; {name} -- a new Puffin program.\n\n");
    std::fs::write(directory.join("main.puf"), main).map_err(|error| format!("cannot write main.puf: {error}"))?;
    init(&directory)?;
    let record = Record::new("project", json!({ "name": name }));
    commit(&directory, &format!("new project {name}"), &[record])?;
    Ok(directory)
}

/// Whether `directory` is itself a repository (history is kept there).
pub fn tracked(directory: &Path) -> bool {
    directory.join(".git").exists()
}

/// Whether `directory` lies inside a repository rooted elsewhere, where a
/// repository of its own would nest.
pub fn inside_repository(directory: &Path) -> bool {
    match git(directory, &["rev-parse", "--show-toplevel"]) {
        Ok(top) => std::fs::canonicalize(top.trim()).ok() != std::fs::canonicalize(directory).ok(),
        Err(_) => false,
    }
}

/// Take `directory` as a tracked project unless it is one already or sits
/// inside another repository. Returns whether it is tracked now.
pub fn adopt(directory: &Path) -> Result<bool, String> {
    if tracked(directory) {
        return Ok(true);
    }
    if !git_available() || inside_repository(directory) {
        return Ok(false);
    }
    init(directory)?;
    let name = directory.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let record = Record::new("project", json!({ "name": name, "adopted": true }));
    commit(directory, &format!("project {name}"), &[record])?;
    Ok(true)
}

fn init(directory: &Path) -> Result<(), String> {
    git(directory, &["init", "-q"])?;
    let ignore = directory.join(".gitignore");
    if !ignore.exists() {
        std::fs::write(&ignore, "*.puffin-studio-tmp\n").map_err(|error| format!("cannot write .gitignore: {error}"))?;
    }
    Ok(())
}

pub fn git_available() -> bool {
    Command::new("git").arg("--version").output().is_ok_and(|out| out.status.success())
}

/// Run git in `directory`; its stdout, or its stderr as the error. A
/// repository without an identity configured commits as the studio.
pub fn git(directory: &Path, args: &[&str]) -> Result<String, String> {
    let output = Command::new("git")
        .arg("-c")
        .arg("user.name=Puffin Studio")
        .arg("-c")
        .arg("user.email=studio@puffin.invalid")
        .arg("-c")
        .arg("commit.gpgsign=false")
        .args(args)
        .current_dir(directory)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .map_err(|error| format!("cannot run git: {error}"))?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_owned())
    }
}

/// The journal file, relative to the project.
pub const JOURNAL: &str = ".puffin/journal.jsonl";

/// Append `records` to the journal, then commit everything in the
/// project with `subject` and the records as the message's body. Returns
/// the commit, or None when there was nothing to commit.
pub fn commit(directory: &Path, subject: &str, records: &[Record]) -> Result<Option<String>, String> {
    if !records.is_empty() {
        let journal = directory.join(JOURNAL);
        if let Some(parent) = journal.parent() {
            std::fs::create_dir_all(parent).map_err(|error| format!("cannot make .puffin: {error}"))?;
        }
        let lines: String = records.iter().map(|record| format!("{}\n", record.line())).collect();
        use std::io::Write;
        std::fs::OpenOptions::new()
            .append(true)
            .create(true)
            .open(&journal)
            .and_then(|mut file| file.write_all(lines.as_bytes()))
            .map_err(|error| format!("cannot write {JOURNAL}: {error}"))?;
    }
    git(directory, &["add", "-A"])?;
    let staged = git(directory, &["diff", "--cached", "--quiet"]).is_ok();
    if staged {
        return Ok(None);
    }
    let body: String = records.iter().map(|record| format!("{}\n", record.line())).collect();
    let message = if body.is_empty() { subject.to_owned() } else { format!("{subject}\n\n{body}") };
    git(directory, &["commit", "-q", "-m", &message])?;
    Ok(Some(git(directory, &["rev-parse", "HEAD"])?.trim().to_owned()))
}

/// The timeline, oldest first: every record of every commit, with the
/// commit it rode in, and each commit that carried no records as a
/// "commit" moment of its own.
pub fn history(directory: &Path) -> Result<Vec<Moment>, String> {
    if !tracked(directory) {
        return Ok(Vec::new());
    }
    // nothing committed yet: an empty repository has no log
    if git(directory, &["rev-parse", "--verify", "-q", "HEAD"]).is_err() {
        return Ok(Vec::new());
    }
    let log = git(directory, &["log", "--reverse", "--format=%x1e%H%x1f%ct%x1f%B"])?;
    let mut out = Vec::new();
    for entry in log.split('\u{1e}').filter(|entry| !entry.trim().is_empty()) {
        let mut fields = entry.splitn(3, '\u{1f}');
        let (Some(hash), Some(seconds), Some(body)) = (fields.next(), fields.next(), fields.next()) else { continue };
        let at = seconds.trim().parse::<u64>().unwrap_or(0) * 1000;
        let hash = hash.trim().to_owned();
        let records: Vec<Record> = body.lines().filter_map(Record::parse).collect();
        if records.is_empty() {
            let subject = body.lines().next().unwrap_or("").trim().to_owned();
            out.push(Moment { at, kind: "commit".to_owned(), commit: Some(hash), data: json!({ "subject": subject }) });
            continue;
        }
        for record in records {
            out.push(Moment { at: record.at, kind: record.kind, commit: Some(hash.clone()), data: record.data });
        }
    }
    Ok(out)
}

/// What commit `hash` changed, as a unified diff of the project's files
/// (the journal left out: the records say what it holds).
pub fn diff(directory: &Path, hash: &str) -> Result<String, String> {
    if hash.len() < 7 || !hash.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(format!("{hash} is not a commit"));
    }
    git(directory, &["show", "--format=", "--unified=3", "--no-color", hash, "--", ".", &format!(":(exclude){JOURNAL}")])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temporary(name: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!("puffin-studio-project-{}-{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        directory
    }

    #[test]
    fn records_round_trip_through_their_lines() {
        let record = Record::new("eval", json!({ "line": "(+ 1 2)", "result": "3" }));
        let back = Record::parse(&record.line()).unwrap();
        assert_eq!((back.at, back.kind.as_str(), back.data["result"].as_str()), (record.at, "eval", Some("3")));
        assert!(Record::parse("edit calc.puf").is_none());
        assert!(Record::parse("{\"kind\":\"eval\"}").is_none());
    }

    #[test]
    fn names_are_plain_and_random_ones_short() {
        assert_eq!(valid_name(" calc "), Ok("calc"));
        assert!(valid_name("../x").is_err());
        assert!(valid_name(".hidden").is_err());
        assert!(valid_name("").is_err());
        let name = random_name();
        assert_eq!(name.len(), 7);
        assert!(name.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn a_new_project_is_a_repository_whose_log_is_its_history() {
        if !git_available() {
            return;
        }
        let home = temporary("home");
        let directory = create(&home, Some("calc")).unwrap();
        assert!(tracked(&directory));
        assert!(directory.join("main.puf").is_file());
        assert!(create(&home, Some("calc")).is_err());
        // a settled edit and two records: one commit, both on the timeline
        std::fs::write(directory.join("main.puf"), "(define x 1)\n").unwrap();
        let records = [
            Record::new("edit", json!({ "file": "main.puf", "forms": ["main.puf:define:x"] })),
            Record::new("eval", json!({ "line": "x", "result": "1" })),
        ];
        let hash = commit(&directory, "edit main.puf", &records).unwrap().unwrap();
        // nothing changed: no commit
        assert_eq!(commit(&directory, "nothing", &[]).unwrap(), None);
        let moments = history(&directory).unwrap();
        let kinds: Vec<&str> = moments.iter().map(|m| m.kind.as_str()).collect();
        assert_eq!(kinds, ["project", "edit", "eval"]);
        assert_eq!(moments[2].commit.as_deref(), Some(hash.as_str()));
        assert!(diff(&directory, &hash).unwrap().contains("+(define x 1)"));
        let journal = std::fs::read_to_string(directory.join(JOURNAL)).unwrap();
        assert_eq!(journal.lines().count(), 3);
        // a commit made by hand is a moment too
        std::fs::write(directory.join("other.puf"), "1\n").unwrap();
        git(&directory, &["add", "-A"]).unwrap();
        git(&directory, &["commit", "-q", "-m", "by hand"]).unwrap();
        let last = history(&directory).unwrap().pop().unwrap();
        assert_eq!((last.kind.as_str(), last.data["subject"].as_str()), ("commit", Some("by hand")));
        let listed = list(&home);
        assert_eq!(listed.iter().map(|p| p.name.as_str()).collect::<Vec<_>>(), ["calc"]);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn a_plain_directory_is_adopted_but_not_one_inside_a_repository() {
        if !git_available() {
            return;
        }
        let outer = temporary("outer");
        git(&outer, &["init", "-q"]).unwrap();
        let inner = outer.join("inner");
        std::fs::create_dir_all(&inner).unwrap();
        assert!(inside_repository(&inner));
        assert_eq!(adopt(&inner), Ok(false));
        let plain = temporary("plain");
        std::fs::write(plain.join("main.puf"), "1\n").unwrap();
        assert_eq!(adopt(&plain), Ok(true));
        assert_eq!(adopt(&plain), Ok(true));
        assert_eq!(history(&plain).unwrap()[0].kind, "project");
        let _ = std::fs::remove_dir_all(&outer);
        let _ = std::fs::remove_dir_all(&plain);
    }
}
