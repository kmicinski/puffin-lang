//! The project's files and folders as disk has them: making, moving and
//! deleting them (a moved file's `require`s are pointed at its new place),
//! saving the edited ones, the scan that finds a project's Puffin files,
//! and the watch that takes in what changes on disk outside the studio.
//! The texts themselves, their versions and edits are studio.rs.

use super::{Doc, Event, Studio};
use crate::toolchain;
use serde_json::json;
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

/// How often the project's directory is looked at for outside changes.
const DISK_POLL: Duration = Duration::from_secs(2);
/// The file extensions a project's files have.
pub const EXTENSIONS: [&str; 3] = ["puf", "pufs", "scm"];
/// Directories never looked into.
const SKIPPED: [&str; 7] = ["node_modules", "target", "build", "_site", "compiled", "build-cache", "output"];
/// At most this many files make a project.
const MAX_FILES: usize = 400;

impl Studio {
    pub fn new_file(&self, path: &str) -> Result<(), String> {
        let path = valid_path(path)?;
        let event = {
            let mut open = self.open.lock().expect("open lock");
            if open.docs.contains_key(&path) {
                return Err(format!("{path} exists already"));
            }
            let version = open.tick();
            open.docs.insert(path.clone(), Doc { text: String::new(), version, disk: None, modified: None });
            open.files_event()
        };
        self.publish(event);
        Ok(())
    }

    /// Make directory `path` in the project: listed at once, empty, and
    /// kept on disk (git takes no note of it until a file is in it).
    pub fn new_folder(&self, path: &str) -> Result<(), String> {
        let path = valid_folder(path)?;
        let event = {
            let mut open = self.open.lock().expect("open lock");
            if open.docs.keys().any(|file| file == &path) {
                return Err(format!("{path} is a file"));
            }
            std::fs::create_dir_all(self.directory.join(&path)).map_err(|error| format!("cannot make {path}: {error}"))?;
            open.folders.insert(path.clone());
            open.files_event()
        };
        self.publish(event);
        Ok(())
    }

    /// Move file `from` to `to`, on disk too, and point every `require`
    /// of it in the other files at its new place. Says which files were
    /// pointed anew.
    pub fn move_file(&self, from: &str, to: &str) -> Result<String, String> {
        let to = valid_path(to)?;
        if from == to {
            return Ok(String::new());
        }
        let event = {
            let mut open = self.open.lock().expect("open lock");
            if !open.docs.contains_key(from) {
                return Err(format!("there is no file {from}"));
            }
            if open.docs.contains_key(&to) {
                return Err(format!("{to} exists already"));
            }
            self.move_on_disk(from, &to)?;
            let version = open.tick();
            let mut doc = open.docs.remove(from).expect("checked above");
            doc.version = version;
            open.docs.insert(to.clone(), doc);
            open.files_event()
        };
        self.moved(from, &to);
        self.publish(event);
        let pointed = self.point_requires(&[(from.to_owned(), to.clone())]);
        self.record("rename", json!({ "from": from, "to": to, "pointed": pointed }));
        self.edited_file(&to);
        Ok(pointed_note(&pointed))
    }

    /// Move directory `from` and every file in it to `to`.
    pub fn move_folder(&self, from: &str, to: &str) -> Result<String, String> {
        let from = valid_folder(from)?;
        let to = valid_folder(to)?;
        if from == to {
            return Ok(String::new());
        }
        if to.starts_with(&format!("{from}/")) {
            return Err(format!("{to} is inside {from}"));
        }
        let moves: Vec<(String, String)>;
        let event = {
            let mut open = self.open.lock().expect("open lock");
            let inside = |path: &str| path.starts_with(&format!("{from}/"));
            if open.docs.contains_key(&to) || open.folders().contains(&to) {
                return Err(format!("{to} exists already"));
            }
            if !open.folders().contains(&from) {
                return Err(format!("there is no folder {from}"));
            }
            moves = open.docs.keys().filter(|path| inside(path)).map(|path| (path.clone(), format!("{to}{}", &path[from.len()..]))).collect();
            let source = self.directory.join(&from);
            if source.is_dir() {
                let target = self.directory.join(&to);
                if let Some(parent) = target.parent() {
                    std::fs::create_dir_all(parent).map_err(|error| format!("cannot make {to}: {error}"))?;
                }
                std::fs::rename(&source, &target).map_err(|error| format!("cannot move {from} to {to}: {error}"))?;
            }
            for (old, new) in &moves {
                let version = open.tick();
                let mut doc = open.docs.remove(old).expect("listed above");
                doc.version = version;
                open.docs.insert(new.clone(), doc);
            }
            let renamed: Vec<String> = open.folders.iter().filter(|dir| *dir == &from || inside(dir)).cloned().collect();
            for dir in renamed {
                open.folders.remove(&dir);
                open.folders.insert(format!("{to}{}", &dir[from.len()..]));
            }
            open.files_event()
        };
        for (old, new) in &moves {
            self.moved(old, new);
        }
        self.publish(event);
        let pointed = self.point_requires(&moves);
        self.record("rename", json!({ "from": from, "to": to, "folder": true, "files": moves.len(), "pointed": pointed }));
        for (_, new) in &moves {
            self.edited_file(new);
        }
        Ok(pointed_note(&pointed))
    }

    /// Take file `path` out of the project and off disk. A tracked
    /// project's history keeps it.
    pub fn delete_file(&self, path: &str) -> Result<(), String> {
        let event = {
            let mut open = self.open.lock().expect("open lock");
            if !open.docs.contains_key(path) {
                return Err(format!("there is no file {path}"));
            }
            self.remove_on_disk(path)?;
            open.docs.remove(path);
            open.files_event()
        };
        self.forget(path);
        self.publish(event);
        self.record("delete", json!({ "file": path }));
        Ok(())
    }

    /// Take directory `path` and its files out of the project. A folder
    /// holding files the studio does not manage stays, and says so.
    pub fn delete_folder(&self, path: &str) -> Result<(), String> {
        let path = valid_folder(path)?;
        let removed: Vec<String>;
        let event = {
            let mut open = self.open.lock().expect("open lock");
            if !open.folders().contains(&path) {
                return Err(format!("there is no folder {path}"));
            }
            let inside = |dir: &str| dir.starts_with(&format!("{path}/"));
            removed = open.docs.keys().filter(|file| inside(file)).cloned().collect();
            for file in &removed {
                self.remove_on_disk(file)?;
                open.docs.remove(file);
            }
            let dirs: Vec<String> = open.folders.iter().filter(|dir| *dir == &path || inside(dir)).cloned().collect();
            for dir in dirs {
                open.folders.remove(&dir);
            }
            let target = self.directory.join(&path);
            let kept = target.is_dir() && remove_empty_dirs(&target).is_err();
            if kept {
                open.folders.insert(path.clone());
            }
            (open.files_event(), kept)
        };
        let (event, kept) = event;
        for file in &removed {
            self.forget(file);
        }
        self.publish(event);
        self.record("delete", json!({ "file": path, "folder": true, "files": removed.len() }));
        if kept {
            return Err(format!("{path} holds files the studio does not manage, so the folder stays; its Puffin files are gone"));
        }
        Ok(())
    }

    /// Remove `file` from disk, with any save of it left half-done.
    fn remove_on_disk(&self, file: &str) -> Result<(), String> {
        let target = self.directory.join(file);
        if target.exists() {
            std::fs::remove_file(&target).map_err(|error| format!("cannot delete {file}: {error}"))?;
        }
        let _ = std::fs::remove_file(target.with_extension("puffin-studio-tmp"));
        Ok(())
    }

    /// Move `from` to `to` on disk, if `from` is there.
    fn move_on_disk(&self, from: &str, to: &str) -> Result<(), String> {
        let source = self.directory.join(from);
        if !source.is_file() {
            return Ok(());
        }
        let target = self.directory.join(to);
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent).map_err(|error| format!("cannot make {to}'s folder: {error}"))?;
        }
        std::fs::rename(&source, &target).map_err(|error| format!("cannot move {from} to {to}: {error}"))?;
        let _ = std::fs::remove_file(source.with_extension("puffin-studio-tmp"));
        Ok(())
    }

    /// What the studio keeps per file follows a moved one.
    fn moved(&self, from: &str, to: &str) {
        self.history.lock().expect("history lock").rename(from, to);
        {
            let mut committed = self.committed.lock().expect("committed lock");
            if let Some(text) = committed.remove(from) {
                committed.insert(to.to_owned(), text);
            }
        }
        self.forget_checks(from);
    }

    /// What the studio keeps per file goes with a deleted one.
    fn forget(&self, path: &str) {
        self.committed.lock().expect("committed lock").remove(path);
        self.forget_checks(path);
    }

    /// Rewrite each `(require "...")` that named a moved file so it names
    /// the file where it is now. Returns the files rewritten.
    fn point_requires(&self, moves: &[(String, String)]) -> Vec<String> {
        let files = self.files();
        let mut pointed = Vec::new();
        for (path, text) in &files {
            let dir = path.rsplit_once('/').map_or("", |(dir, _)| dir);
            let mut edited = text.clone();
            for form in crate::sexp::forms(text).iter().rev() {
                let (Some("require"), Some(target)) = (form.head.as_deref(), form.string.as_ref()) else { continue };
                let named = toolchain::normalize(dir, target);
                let Some((_, to)) = moves.iter().find(|(from, _)| *from == named) else { continue };
                let quoted = format!("\"{target}\"");
                let Some(at) = text[form.start..form.end].find(&quoted) else { continue };
                let start = form.start + at;
                edited.replace_range(start..start + quoted.len(), &format!("\"{}\"", relative_path(dir, to)));
            }
            if edited != *text {
                self.replace(path, edited, "rename", &format!("requires {}", moves.iter().map(|(_, to)| to.as_str()).collect::<Vec<_>>().join(", ")));
                pointed.push(path.clone());
            }
        }
        pointed
    }

    /// Write every file whose text differs from disk's.
    pub fn save(&self) -> Result<(), String> {
        let mut written = BTreeMap::new();
        let mut versions = Vec::new();
        let mut failed = Vec::new();
        {
            let mut open = self.open.lock().expect("open lock");
            for (path, doc) in open.docs.iter_mut() {
                if doc.saved() {
                    written.insert(path.clone(), doc.version);
                    continue;
                }
                let target = self.directory.join(path);
                let write = || -> std::io::Result<()> {
                    if let Some(parent) = target.parent() {
                        std::fs::create_dir_all(parent)?;
                    }
                    let temporary = target.with_extension("puffin-studio-tmp");
                    std::fs::write(&temporary, &doc.text)?;
                    std::fs::rename(&temporary, &target)
                };
                match write() {
                    Ok(()) => {
                        doc.disk = Some(doc.text.clone());
                        doc.modified = modified(&target);
                        written.insert(path.clone(), doc.version);
                        versions.push((path.clone(), doc.text.clone()));
                    }
                    Err(error) => failed.push(format!("{path}: {error}")),
                }
            }
        }
        for (path, text) in versions {
            self.record_version(&path, &text, "save", "");
        }
        self.publish(Event::Saved { files: written });
        if failed.is_empty() { Ok(()) } else { Err(format!("cannot save {}", failed.join("; "))) }
    }

    /// Take in files changed on disk outside the studio: one with no unsaved
    /// edits follows disk; one with edits keeps them, and tabs are told.
    pub(super) fn watch_disk(self: &Arc<Self>) {
        let studio = Arc::downgrade(self);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(DISK_POLL).await;
                let Some(studio) = studio.upgrade() else { return };
                let directory = studio.directory.clone();
                let Ok(found) = tokio::task::spawn_blocking(move || scan(&directory)).await else { continue };
                studio.take_disk(found);
            }
        });
    }

    fn take_disk(&self, found: Scanned) {
        let mut changed = Vec::new();
        let mut kept = Vec::new();
        let mut gone = Vec::new();
        let mut added = false;
        {
            let mut open = self.open.lock().expect("open lock");
            // a saved file that went from disk (deleted or moved outside the
            // studio) goes from the project; one with unsaved edits stays
            let complete = found.files.len() < MAX_FILES;
            if complete {
                let present: BTreeSet<&str> = found.files.iter().map(|(path, ..)| path.as_str()).collect();
                let vanished: Vec<String> = open
                    .docs
                    .iter()
                    .filter(|(path, doc)| doc.disk.is_some() && doc.saved() && !present.contains(path.as_str()) && !self.directory.join(path).exists())
                    .map(|(path, _)| path.clone())
                    .collect();
                for path in vanished {
                    open.docs.remove(&path);
                    gone.push(path);
                }
            }
            let folders: BTreeSet<String> = found.folders.into_iter().collect();
            if folders != open.folders {
                open.folders = folders;
                added = true;
            }
            for (path, text, stamp) in found.files {
                let clock = open.clock + 1;
                match open.docs.get_mut(&path) {
                    Some(doc) if doc.disk.as_deref() == Some(text.as_str()) => doc.modified = stamp,
                    Some(doc) if doc.saved() || doc.text == text => {
                        doc.text = text.clone();
                        doc.disk = Some(text.clone());
                        doc.modified = stamp;
                        doc.version = clock;
                        open.clock = clock;
                        changed.push((path, clock, text));
                    }
                    Some(doc) => {
                        doc.disk = Some(text);
                        doc.modified = stamp;
                        kept.push(path);
                    }
                    // the scan ran before a move or a delete: not back again
                    None if !self.directory.join(&path).is_file() => {}
                    None => {
                        open.clock = clock;
                        open.docs.insert(path.clone(), Doc { text: text.clone(), version: clock, disk: Some(text.clone()), modified: stamp });
                        changed.push((path, clock, text));
                        added = true;
                    }
                }
            }
            if added || !gone.is_empty() {
                let event = open.files_event();
                drop(open);
                self.publish(event);
            }
        }
        for path in gone {
            self.forget(&path);
            self.record("delete", json!({ "file": path, "disk": true }));
            self.notice(format!("{path} went from disk; it is out of the project"));
        }
        for (path, version, text) in changed {
            self.publish(Event::Text { file: path.clone(), version, text: text.clone(), origin: 0 });
            self.publish(Event::Saved { files: BTreeMap::from([(path.clone(), version)]) });
            self.record_version(&path, &text, "disk", "");
            self.edited_file(&path);
        }
        for path in kept {
            self.notice(format!("{path} changed on disk; the studio keeps your unsaved edits (save to overwrite)"));
        }
    }
}

fn modified(path: &Path) -> Option<SystemTime> {
    std::fs::metadata(path).and_then(|meta| meta.modified()).ok()
}

/// What a scan of the project found.
#[derive(Default)]
pub struct Scanned {
    /// The Puffin files: (relative path, text, mtime).
    pub files: Vec<(String, String, Option<SystemTime>)>,
    /// Every directory, relative, empty ones included.
    pub folders: Vec<String>,
}

/// The project's files under `directory`, and its directories.
pub fn scan(directory: &Path) -> Scanned {
    let mut found = Scanned::default();
    walk(directory, directory, 0, &mut found.files, &mut found.folders);
    found.files.sort_by(|a, b| a.0.cmp(&b.0));
    found.folders.sort();
    found
}

fn walk(root: &Path, directory: &Path, depth: usize, out: &mut Vec<(String, String, Option<SystemTime>)>, folders: &mut Vec<String>) {
    if depth > 6 || out.len() >= MAX_FILES {
        return;
    }
    let Ok(entries) = std::fs::read_dir(directory) else { return };
    let mut entries: Vec<_> = entries.flatten().collect();
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') || name.starts_with('#') {
            continue;
        }
        let path = entry.path();
        if path.is_dir() {
            if !SKIPPED.contains(&name.as_str()) {
                if let Ok(relative) = path.strip_prefix(root) {
                    folders.push(relative.to_string_lossy().into_owned());
                }
                walk(root, &path, depth + 1, out, folders);
            }
        } else if path.extension().and_then(|e| e.to_str()).is_some_and(|e| EXTENSIONS.contains(&e))
            && let Ok(text) = std::fs::read_to_string(&path)
            && let Ok(relative) = path.strip_prefix(root)
        {
            out.push((relative.to_string_lossy().into_owned(), text, modified(&path)));
            if out.len() >= MAX_FILES {
                return;
            }
        }
    }
}

/// A new file's path: relative, inside the project, with a Puffin suffix.
pub fn valid_path(path: &str) -> Result<String, String> {
    let path = valid_folder(path)?;
    if EXTENSIONS.iter().any(|extension| path.ends_with(&format!(".{extension}"))) {
        Ok(path)
    } else {
        Ok(format!("{path}.puf"))
    }
}

/// A directory's path: relative, inside the project, no hidden parts.
pub fn valid_folder(path: &str) -> Result<String, String> {
    let path = path.trim().trim_start_matches("./").trim_end_matches('/');
    if path.is_empty() || path.starts_with('/') || path.split('/').any(|part| part == ".." || part.is_empty() || part.starts_with('.')) {
        return Err(format!("{path}: a file of the project is a relative path inside it"));
    }
    Ok(path.to_owned())
}

/// `target` as a path relative to directory `dir`, as a `require` names it.
pub fn relative_path(dir: &str, target: &str) -> String {
    let from: Vec<&str> = if dir.is_empty() { Vec::new() } else { dir.split('/').collect() };
    let to: Vec<&str> = target.split('/').collect();
    let shared = from.iter().zip(&to).take_while(|(a, b)| a == b).count();
    let mut parts: Vec<&str> = vec![".."; from.len() - shared];
    parts.extend(&to[shared..]);
    parts.join("/")
}

/// Remove `directory` and the directories under it, if nothing else is
/// in them.
fn remove_empty_dirs(directory: &Path) -> std::io::Result<()> {
    for entry in std::fs::read_dir(directory)?.flatten() {
        let path = entry.path();
        if path.is_dir() {
            remove_empty_dirs(&path)?;
        } else if path.extension().and_then(|e| e.to_str()) == Some("puffin-studio-tmp") || path.file_name().is_some_and(|n| n == ".DS_Store") {
            std::fs::remove_file(&path)?;
        }
    }
    std::fs::remove_dir(directory)
}

/// A note for the tab: which files now require a moved file by its new
/// name.
fn pointed_note(pointed: &[String]) -> String {
    match pointed {
        [] => String::new(),
        [one] => format!("{one} requires it by its new name now"),
        many => format!("{} require it by its new name now", many.join(", ")),
    }
}

#[cfg(test)]
mod tests {
    use super::valid_path;

    #[test]
    fn new_files_stay_inside_the_project() {
        assert_eq!(valid_path("lib/vec").unwrap(), "lib/vec.puf");
        assert_eq!(valid_path("./a.puf").unwrap(), "a.puf");
        assert!(valid_path("../x.puf").is_err());
        assert!(valid_path("/etc/x.puf").is_err());
        assert!(valid_path("a//b.puf").is_err());
        assert_eq!(super::valid_folder("lib/").unwrap(), "lib");
        assert!(super::valid_folder("lib/.hidden").is_err());
    }

    #[test]
    fn a_require_names_a_moved_file_from_where_it_stands() {
        use super::relative_path;
        assert_eq!(relative_path("", "lib/vec.puf"), "lib/vec.puf");
        assert_eq!(relative_path("lib", "lib/vec.puf"), "vec.puf");
        assert_eq!(relative_path("lib/a", "lib/b/vec.puf"), "../b/vec.puf");
        assert_eq!(relative_path("src", "main.puf"), "../main.puf");
    }
}
