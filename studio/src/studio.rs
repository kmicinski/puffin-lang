//! The open project, its lanes, and the events every open browser tab
//! observes.
//!
//! The server owns the text of each file. A tab edits a file by sending its
//! whole text with the version it edited; an edit to a superseded version is
//! refused and answered with the current text, so two tabs cannot silently
//! overwrite each other. Save writes the edited files to disk. Files changed
//! on disk outside the studio are taken in when the studio's copy has no
//! unsaved edits.
//!
//! The program is checked about 400 ms after editing pauses (§2.1 `check`,
//! or the bytecode compile until `--assist` exists): the edited file, and
//! every program that requires it.
//!
//! What the live session holds of the program (session.rs) is shown to
//! every tab as it changes, and its observation record is refreshed about
//! 300 ms after the evaluations stop (repl.rs). Each check also finds the
//! program's typed holes and lints the edited modules against the
//! observations (holes.rs).
//!
//! Two parts live beside this file: studio/files.rs (files and folders on
//! disk: make, move, delete, save, and the disk watch) and
//! studio/journal.rs (the project's history as it is committed).

use crate::agent::{Agent, AgentEvent};
use crate::holes::{Finding, Hole, Marks};
use crate::pin::TestRun;
use crate::project::{self, Record};
use crate::lane::{Lane, LaneStatus};
use crate::review::{Acceptance, Review, ReviewView};
use crate::session::{Session, SessionView};
use crate::toolchain::{self, Files, Report, Toolchain};
use crate::versions::{History, Version};

pub mod files;
mod journal;
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, SystemTime};
use tokio::sync::{Notify, broadcast};

/// How long editing pauses before the program is checked.
pub const CHECK_PAUSE: Duration = Duration::from_millis(400);
/// How long evaluations pause before the observation record is refreshed.
const OBSERVE_PAUSE: Duration = Duration::from_millis(300);
/// Transcript entries kept, for tabs that open later.
const KEPT_ENTRIES: usize = 400;
/// Output one entry keeps.
const ENTRY_OUTPUT: usize = 256 * 1024;

/// Everything a tab needs to render the studio from scratch.
#[derive(Clone, Debug, Serialize)]
pub struct Snapshot {
    pub project: String,
    pub directory: String,
    /// The project is a repository the studio commits to (project.rs).
    pub tracked: bool,
    pub files: Vec<FileView>,
    /// Every directory of the project, empty ones included.
    pub folders: Vec<String>,
    pub lane: LaneStatus,
    pub review: ReviewView,
    pub diagnostics: BTreeMap<String, Report>,
    pub transcript: Vec<Entry>,
    pub session: SessionView,
    /// Each file's typed holes, and its observation lint findings.
    pub holes: BTreeMap<String, Marks<Hole>>,
    pub lint: BTreeMap<String, Marks<Finding>>,
    /// The traced function names (trace.rs).
    pub traced: Vec<String>,
    pub features: Features,
    /// Why the assistant cannot run here, if it cannot.
    pub agent_unavailable: Option<String>,
    /// The module board and the outline (board.rs).
    pub board: Value,
}

#[derive(Clone, Debug, Serialize)]
pub struct Features {
    /// `puffincc --assist` answers.
    pub assist: bool,
    /// `puffin-vm --serve` runs.
    pub serve: bool,
    /// `puffincc --repl --observe` compiles: sessions observe calls.
    pub observe: bool,
    /// `puffincc --assist facts` answers.
    pub facts: bool,
    /// `puffincc --assist lint` answers.
    pub lint: bool,
    /// `puffincc --assist rename` is an operation.
    pub rename: bool,
    /// `puffincc --repl --trace NAME` compiles: `,trace` works.
    pub trace: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct FileView {
    pub path: String,
    pub text: String,
    pub version: u64,
    /// The text is what the file on disk holds.
    pub saved: bool,
}

/// One transcript entry: a REPL evaluation, a command, an echoed gesture,
/// a question to the assistant, or a notice.
#[derive(Clone, Debug, Default, Serialize)]
pub struct Entry {
    pub id: u64,
    /// "eval", "echo", "ask", "test", or "notice".
    pub kind: &'static str,
    /// For an eval: "prompt", "buffer", or "file".
    #[serde(skip_serializing_if = "String::is_empty")]
    pub origin: String,
    /// What was typed or sent, as it would be typed.
    pub line: String,
    /// The command a gesture made it, when that is not `line`:
    /// `,eval expr.puf:17`.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub command: String,
    /// The definitions loaded first, ahead of the form (dependency-aware eval).
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub also: Vec<String>,
    /// What would fix the failure: a definition to load.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub fixes: Vec<Fix>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    /// Output, in order, as (stream, text): "out", "err", or "result".
    pub out: Vec<(String, String)>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub ms: u64,
    /// An ask entry's thread, and which of its turns (0-based).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thread: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn: Option<usize>,
    /// A `,test` run's checks.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tests: Option<TestRun>,
    #[serde(skip)]
    pub kept: usize,
}

/// A definition the session lacks, found in an open module: `Load X
/// from expr.puf`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Fix {
    pub name: String,
    pub file: String,
    pub line: usize,
}

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "t", rename_all = "kebab-case")]
pub enum Event {
    /// A file's text changed; `origin` is the connection that changed it
    /// (0: the studio itself, as an accepted proposal or a restore).
    Text { file: String, version: u64, text: String, origin: u64 },
    /// The set of files changed: one was added, moved or went; `folders`
    /// are every directory of the project, empty ones included.
    Files { files: Vec<FileView>, folders: Vec<String> },
    /// These files, at these versions, are what disk holds.
    Saved { files: BTreeMap<String, u64> },
    /// The latest check of each program, by its entry file.
    Diagnostics { reports: BTreeMap<String, Report> },
    Lane(LaneStatus),
    Features(Features),
    /// A transcript entry began.
    Entry(Entry),
    /// More output for entry `id`.
    EntryOut { id: u64, stream: &'static str, text: String },
    /// Entry `id` finished.
    EntryDone {
        id: u64,
        status: String,
        error: Option<String>,
        ms: u64,
        #[serde(skip_serializing_if = "Vec::is_empty")]
        fixes: Vec<Fix>,
        #[serde(skip_serializing_if = "Option::is_none")]
        tests: Option<TestRun>,
    },
    /// The typed holes of `file` (none: it has no holes now).
    Holes { file: String, holes: Marks<Hole> },
    /// The observation lint's findings in `file`.
    Lint { file: String, lint: Marks<Finding> },
    /// The traced function names changed.
    Traced { names: Vec<String> },
    /// What the live session holds of the program changed.
    Session(SessionView),
    /// Progress of an assistant turn.
    Agent(AgentEvent),
    /// Threads, changesets or proposals changed.
    Review(ReviewView),
    /// A new version of a file.
    Version { version: Version },
    /// Something every tab should know, briefly.
    Notice { message: String },
    /// Records were committed: the history has more to show.
    Journal,
    /// The studio now serves another project: reload.
    Reopen,
    /// Voice mode (voice.rs): what was heard, where to look, what the
    /// builder is doing.
    Voice(crate::voice::VoiceEvent),
    /// The module board (board.rs): its view state and the outline.
    Board { board: Value, outline: Value },
}

/// Why an edit was not taken.
#[derive(Debug, Eq, PartialEq)]
pub enum Refused {
    /// The edit was made to a superseded version: this is the current one.
    Stale { version: u64, text: String },
    NoFile,
}

struct Doc {
    text: String,
    version: u64,
    /// What disk holds, as last read or written; None for a file not yet
    /// written.
    disk: Option<String>,
    modified: Option<SystemTime>,
}

impl Doc {
    fn saved(&self) -> bool {
        self.disk.as_deref() == Some(self.text.as_str())
    }
}

struct Open {
    docs: BTreeMap<String, Doc>,
    clock: u64,
    /// The project's directories as disk has them (scan), made from the
    /// studio included: a folder stays listed while it is empty.
    folders: BTreeSet<String>,
}

impl Open {
    fn tick(&mut self) -> u64 {
        self.clock += 1;
        self.clock
    }

    /// Every directory a file sits in, every one known to disk, and
    /// their parents.
    fn folders(&self) -> Vec<String> {
        let mut out = self.folders.clone();
        for path in self.docs.keys().chain(self.folders.iter()) {
            let mut at = path.as_str();
            while let Some((dir, _)) = at.rsplit_once('/') {
                out.insert(dir.to_owned());
                at = dir;
            }
        }
        out.into_iter().collect()
    }

    fn files_event(&self) -> Event {
        Event::Files { files: self.views(), folders: self.folders() }
    }

    fn views(&self) -> Vec<FileView> {
        self.docs
            .iter()
            .map(|(path, doc)| FileView { path: path.clone(), text: doc.text.clone(), version: doc.version, saved: doc.saved() })
            .collect()
    }
}

pub struct Studio {
    /// The Puffin repository: the compiler, the VM, the docs.
    pub root: PathBuf,
    /// The project's directory.
    pub directory: PathBuf,
    pub toolchain: Arc<Toolchain>,
    pub lane: Lane,
    open: Mutex<Open>,
    events: broadcast::Sender<Event>,
    pub(crate) review: Mutex<Review>,
    /// Each pending op's acceptance, with the key of what it was checked
    /// against (ask.rs).
    pub(crate) acceptances: Mutex<HashMap<u32, (u64, Acceptance)>>,
    /// Signalled when the review or the program changes.
    pub(crate) review_changed: Arc<Notify>,
    pub(crate) history: Mutex<History>,
    /// The project keeps its history in git (project.rs).
    pub tracked: bool,
    /// Records not yet committed, oldest first.
    journal: Mutex<Vec<Record>>,
    journal_due: Arc<Notify>,
    /// Each file's text as last committed, to say which forms an edit
    /// changed.
    committed: Mutex<Files>,
    /// A commit failed and was said so; quiet until one succeeds.
    journal_failed: Mutex<bool>,
    transcript: Mutex<Vec<Entry>>,
    next_entry: std::sync::atomic::AtomicU64,
    diagnostics: Mutex<BTreeMap<String, Report>>,
    /// Files edited since the last check.
    to_check: Mutex<BTreeSet<String>>,
    edited: Arc<Notify>,
    /// The `define-type` and `define-type-alias` forms the live session has
    /// loaded: (name, form),
    /// in the order the names first came, each its latest text (repl.rs).
    pub(crate) types: Mutex<Vec<(String, String)>>,
    /// Held across a unit's compile and run, so units load in order.
    pub(crate) eval_queue: tokio::sync::Mutex<()>,
    /// What the live session holds of the program (session.rs).
    pub(crate) session: Mutex<Session>,
    /// Each file's typed holes and lint findings (holes.rs).
    pub(crate) holes: Mutex<BTreeMap<String, Marks<Hole>>>,
    pub(crate) lint: Mutex<BTreeMap<String, Marks<Finding>>>,
    /// Signalled after each successful evaluation: the observation record
    /// is due for a refresh.
    pub(crate) observations_due: Arc<Notify>,
    /// The function names `,trace` named: every unit defining one compiles
    /// with `--trace` for it (trace.rs).
    pub(crate) traced: Mutex<BTreeSet<String>>,
    pub agent: Agent,
    /// Voice mode: the router, the builder, the properties (voice.rs).
    pub voice: crate::voice::Voice,
    /// The module board's view state (board.rs).
    pub board: Mutex<Value>,
    port: OnceLock<u16>,
}

impl Studio {
    pub fn new(root: PathBuf, directory: PathBuf, mcp_token: String) -> std::io::Result<Arc<Self>> {
        let toolchain = Arc::new(Toolchain::new(root.clone())?);
        let (events, _) = broadcast::channel(1024);
        let lane_events = events.clone();
        let lane = Lane::new(
            toolchain.clone(),
            Box::new(move |status| {
                let _ = lane_events.send(Event::Lane(status));
            }),
        );
        let scanned = files::scan(&directory);
        let mut open = Open { docs: BTreeMap::new(), clock: 0, folders: scanned.folders.into_iter().collect() };
        let mut history = History::default();
        let mut committed: Files = Files::new();
        for (path, text, modified) in scanned.files {
            let version = open.tick();
            history.record(&path, &text, "open", "");
            committed.insert(path.clone(), text.clone());
            open.docs.insert(path, Doc { text: text.clone(), version, disk: Some(text), modified });
        }
        let tracked = project::tracked(&directory);
        if open.docs.is_empty() {
            let version = open.tick();
            let text = ";; main.puf -- a new Puffin program. Cmd-S saves it.\n\n".to_owned();
            open.docs.insert("main.puf".to_owned(), Doc { text, version, disk: None, modified: None });
        }
        let studio = Arc::new(Self {
            root,
            directory,
            toolchain,
            lane,
            open: Mutex::new(open),
            events,
            review: Mutex::new(Review::default()),
            acceptances: Mutex::new(HashMap::new()),
            review_changed: Arc::new(Notify::new()),
            history: Mutex::new(history),
            tracked,
            journal: Mutex::new(Vec::new()),
            journal_due: Arc::new(Notify::new()),
            committed: Mutex::new(committed),
            journal_failed: Mutex::new(false),
            transcript: Mutex::new(Vec::new()),
            next_entry: std::sync::atomic::AtomicU64::new(1),
            diagnostics: Mutex::new(BTreeMap::new()),
            to_check: Mutex::new(BTreeSet::new()),
            edited: Arc::new(Notify::new()),
            types: Mutex::new(Vec::new()),
            eval_queue: tokio::sync::Mutex::new(()),
            session: Mutex::new(Session::default()),
            holes: Mutex::new(BTreeMap::new()),
            lint: Mutex::new(BTreeMap::new()),
            observations_due: Arc::new(Notify::new()),
            traced: Mutex::new(BTreeSet::new()),
            agent: Agent::new(mcp_token),
            voice: crate::voice::Voice::new(),
            board: Mutex::new(crate::board::empty()),
            port: OnceLock::new(),
        });
        Ok(studio)
    }

    /// Start the background work: checks after edits, the disk watch, and
    /// the proposals' acceptance checks.
    pub fn start(self: &Arc<Self>) {
        self.watch_edits();
        self.watch_disk();
        self.watch_proposals();
        self.watch_observations();
        self.watch_journal();
        self.watch_properties();
        *self.board.lock().expect("board lock") = self.load_board();
        self.watch_board();
        self.record("session", json!({}));
        let studio = self.clone();
        tokio::spawn(async move {
            let features = studio.features().await;
            studio.publish(Event::Features(features));
        });
    }

    pub fn set_port(&self, port: u16) {
        let _ = self.port.set(port);
    }

    pub fn port(&self) -> u16 {
        self.port.get().copied().unwrap_or(0)
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.events.subscribe()
    }

    pub fn publish(&self, event: Event) {
        let _ = self.events.send(event);
    }

    pub fn notice(&self, message: impl Into<String>) {
        self.publish(Event::Notice { message: message.into() });
    }

    pub async fn features(&self) -> Features {
        Features {
            assist: self.toolchain.assist_available().await,
            serve: self.toolchain.serve_available().await,
            observe: self.toolchain.observe_available().await,
            facts: self.toolchain.facts_available().await,
            lint: self.toolchain.lint_available().await,
            rename: self.toolchain.rename_available().await,
            trace: self.toolchain.trace_available().await,
        }
    }

    pub async fn snapshot(&self) -> Snapshot {
        let features = self.features().await;
        // each lock taken alone: a guard in a struct literal lives to its end
        let (files, folders) = {
            let open = self.open.lock().expect("open lock");
            (open.views(), open.folders())
        };
        let review = self.review_view();
        let diagnostics = self.diagnostics.lock().expect("diagnostics lock").clone();
        let transcript = self.transcript.lock().expect("transcript lock").clone();
        let session = self.session_view();
        let holes = self.holes_view();
        let lint = self.lint_view();
        let traced = self.traced_names();
        Snapshot {
            project: self.directory.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default(),
            directory: self.directory.display().to_string(),
            tracked: self.tracked,
            files,
            folders,
            lane: self.lane.status(),
            review,
            diagnostics,
            transcript,
            session,
            holes,
            lint,
            traced,
            features,
            agent_unavailable: crate::claude_cli::unavailable(),
            board: self.board_view(),
        }
    }

    // ---- Files -------------------------------------------------------------

    /// Every file's text.
    pub fn files(&self) -> Files {
        self.open.lock().expect("open lock").docs.iter().map(|(path, doc)| (path.clone(), doc.text.clone())).collect()
    }

    pub fn version_of(&self, file: &str) -> Option<u64> {
        self.open.lock().expect("open lock").docs.get(file).map(|doc| doc.version)
    }

    pub fn text_of(&self, file: &str) -> Option<String> {
        self.open.lock().expect("open lock").docs.get(file).map(|doc| doc.text.clone())
    }

    pub fn edit(&self, origin: u64, file: &str, base: u64, text: String) -> Result<u64, Refused> {
        let version = {
            let mut open = self.open.lock().expect("open lock");
            let clock = open.tick();
            let doc = open.docs.get_mut(file).ok_or(Refused::NoFile)?;
            if doc.version != base {
                return Err(Refused::Stale { version: doc.version, text: doc.text.clone() });
            }
            if doc.text == text {
                return Ok(doc.version);
            }
            doc.text = text.clone();
            doc.version = clock;
            clock
        };
        self.publish(Event::Text { file: file.to_owned(), version, text, origin });
        self.edited_file(file);
        Ok(version)
    }

    /// Replace `file`'s text as the studio itself (an accepted proposal, a
    /// restore), recording a version.
    pub fn replace(&self, file: &str, text: String, origin: &'static str, label: &str) {
        let version = {
            let mut open = self.open.lock().expect("open lock");
            let clock = open.tick();
            match open.docs.get_mut(file) {
                Some(doc) => {
                    doc.text = text.clone();
                    doc.version = clock;
                }
                None => {
                    open.docs.insert(file.to_owned(), Doc { text: text.clone(), version: clock, disk: None, modified: None });
                    let event = open.files_event();
                    drop(open);
                    self.publish(event);
                }
            }
            clock
        };
        self.publish(Event::Text { file: file.to_owned(), version, text: text.clone(), origin: 0 });
        self.record_version(file, &text, origin, label);
        self.edited_file(file);
    }

    pub fn record_version(&self, file: &str, text: &str, origin: &'static str, label: &str) {
        let made = self.history.lock().expect("history lock").record(file, text, origin, label);
        if let Some(version) = made {
            if matches!(origin, "accept" | "restore" | "disk") {
                self.record(origin, json!({ "file": file, "label": label, "forms": version.forms_changed }));
            }
            self.publish(Event::Version { version });
        }
    }

    fn edited_file(&self, file: &str) {
        self.to_check.lock().expect("check lock").insert(file.to_owned());
        self.edited.notify_one();
        self.review_changed.notify_one();
        if self.tracked {
            self.journal_due.notify_one();
        }
    }

    pub fn versions_of(&self, file: &str) -> Vec<Version> {
        self.history.lock().expect("history lock").of(file)
    }

    pub fn version_text(&self, id: u64) -> Option<(String, String)> {
        self.history.lock().expect("history lock").get(id).map(|version| (version.file.clone(), version.text.clone()))
    }

    /// Make version `id`'s text its file's again, as a new version.
    pub fn restore(&self, id: u64) -> Result<(), String> {
        let (file, text) = self.version_text(id).ok_or_else(|| format!("no version {id}"))?;
        self.replace(&file, text, "restore", &format!("v{id}"));
        Ok(())
    }

    // ---- Checks --------------------------------------------------------------

    /// Check after editing pauses: each edited file, and every program
    /// that requires it.
    fn watch_edits(self: &Arc<Self>) {
        let studio = Arc::downgrade(self);
        let edited = self.edited.clone();
        tokio::spawn(async move {
            loop {
                edited.notified().await;
                // wait out the typing
                while tokio::time::timeout(CHECK_PAUSE, edited.notified()).await.is_ok() {}
                let Some(studio) = studio.upgrade() else { return };
                let files: Vec<String> = std::mem::take(&mut *studio.to_check.lock().expect("check lock")).into_iter().collect();
                studio.check_files(&files).await;
            }
        });
    }

    /// Check the programs `files` belong to, and publish what they report;
    /// then find the program's holes, and lint `files`.
    pub async fn check_files(&self, files: &[String]) {
        let program = self.files();
        let mut targets: BTreeSet<String> = BTreeSet::new();
        for file in files.iter().filter(|file| checkable(file)) {
            if program.contains_key(file) {
                targets.insert(file.clone());
            }
            for entry in toolchain::entries(&program) {
                if toolchain::closure(&program, &entry).contains(file) {
                    targets.insert(entry);
                }
            }
            // a module checked on its own before (it was shown) that
            // requires this one: its report would be stale otherwise
            let checked: Vec<String> = self.diagnostics.lock().expect("diagnostics lock").keys().cloned().collect();
            for module in checked {
                if module != *file && program.contains_key(&module) && toolchain::closure(&program, &module).contains(file) {
                    targets.insert(module);
                }
            }
        }
        if targets.is_empty() {
            return;
        }
        for entry in targets {
            let report = self.toolchain.check(&program, &entry).await;
            self.diagnostics.lock().expect("diagnostics lock").insert(entry, report);
        }
        let reports = self.diagnostics.lock().expect("diagnostics lock").clone();
        self.publish(Event::Diagnostics { reports });
        self.refresh_holes(&program).await;
        self.refresh_lint(Some(files)).await;
    }

    /// Check `file` unless a report for it is known.
    pub async fn check_if_unknown(&self, file: &str) {
        let known = self.diagnostics.lock().expect("diagnostics lock").contains_key(file);
        if !known {
            self.check_files(&[file.to_owned()]).await;
        }
    }

    /// The diagnostics known for `file`, from every program's check.
    pub fn diagnostics_of(&self, file: &str) -> Vec<toolchain::Diagnostic> {
        let reports = self.diagnostics.lock().expect("diagnostics lock");
        let mut out: Vec<toolchain::Diagnostic> = Vec::new();
        for report in reports.values() {
            for diagnostic in &report.diagnostics {
                if diagnostic.file == file && !out.contains(diagnostic) {
                    out.push(diagnostic.clone());
                }
            }
        }
        out
    }

    /// What the checks know of the program now, file by file, as an agent's
    /// prompt carries it: `severity: message [file:line]`, at most `limit`.
    pub fn diagnostic_lines(&self, limit: usize) -> Vec<String> {
        let files: Vec<String> = self.open.lock().expect("open lock").docs.keys().cloned().collect();
        files.iter().flat_map(|path| self.diagnostics_of(path)).map(|d| format!("{}: {} [{}:{}]", d.severity, d.message, d.file, d.line)).take(limit).collect()
    }

    /// What the checks keep of `path` goes: it was moved or deleted.
    fn forget_checks(&self, path: &str) {
        self.to_check.lock().expect("check lock").remove(path);
        self.diagnostics.lock().expect("diagnostics lock").retain(|entry, report| entry != path && !report.diagnostics.iter().any(|d| d.file == path));
        if self.holes.lock().expect("holes lock").remove(path).is_some() {
            self.publish(Event::Holes { file: path.to_owned(), holes: Marks::default() });
        }
        if self.lint.lock().expect("lint lock").remove(path).is_some() {
            self.publish(Event::Lint { file: path.to_owned(), lint: Marks::default() });
        }
        let reports = self.diagnostics.lock().expect("diagnostics lock").clone();
        self.publish(Event::Diagnostics { reports });
    }


    /// of `changed`: what a proposal and an accept must pass.
    pub async fn check_program(&self, files: &Files, changed: &[String]) -> Report {
        let mut entries: Vec<String> = toolchain::entries(files)
            .into_iter()
            .filter(|entry| changed.iter().any(|file| toolchain::closure(files, entry).contains(file)))
            .collect();
        for file in changed {
            if checkable(file) && !entries.contains(file) && files.contains_key(file) && entries.is_empty() {
                entries.push(file.clone());
            }
        }
        if entries.is_empty() {
            return Report { ok: true, diagnostics: Vec::new() };
        }
        self.toolchain.check_all(files, &entries).await
    }

    // ---- The transcript --------------------------------------------------------

    /// Begin a transcript entry, shown to every tab.
    pub fn begin(&self, mut entry: Entry) -> u64 {
        let id = self.next_entry.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        entry.id = id;
        {
            let mut transcript = self.transcript.lock().expect("transcript lock");
            transcript.push(entry.clone());
            let excess = transcript.len().saturating_sub(KEPT_ENTRIES);
            transcript.drain(..excess);
        }
        self.publish(Event::Entry(entry));
        id
    }

    /// More output for entry `id`; past the entry's limit it is dropped,
    /// with one line saying so.
    pub fn output(&self, id: u64, stream: &'static str, text: String) {
        {
            let mut transcript = self.transcript.lock().expect("transcript lock");
            let Some(entry) = transcript.iter_mut().rev().find(|entry| entry.id == id) else { return };
            if entry.kept > ENTRY_OUTPUT {
                return;
            }
            entry.kept += text.len();
            if entry.kept > ENTRY_OUTPUT {
                let cut = "\n… output cut: the studio keeps 256 KB of one evaluation's output\n".to_owned();
                entry.out.push(("err".to_owned(), cut.clone()));
                drop(transcript);
                self.publish(Event::EntryOut { id, stream: "err", text: cut });
                return;
            }
            match entry.out.last_mut() {
                Some((last, previous)) if last == stream => previous.push_str(&text),
                _ => entry.out.push((stream.to_owned(), text.clone())),
            }
        }
        self.publish(Event::EntryOut { id, stream, text });
    }

    pub fn finish(&self, id: u64, status: &str, error: Option<String>, ms: u64) {
        self.finish_with(id, status, error, ms, Vec::new());
    }

    /// Finish entry `id` with what would fix its failure.
    pub fn finish_with(&self, id: u64, status: &str, error: Option<String>, ms: u64, fixes: Vec<Fix>) {
        self.finish_entry(id, status, error, ms, fixes, None);
    }

    /// Finish entry `id`, with what would fix its failure, or a test run's
    /// checks.
    pub fn finish_entry(&self, id: u64, status: &str, error: Option<String>, ms: u64, fixes: Vec<Fix>, tests: Option<TestRun>) {
        {
            let mut transcript = self.transcript.lock().expect("transcript lock");
            if let Some(entry) = transcript.iter_mut().rev().find(|entry| entry.id == id) {
                entry.status = Some(status.to_owned());
                entry.error = error.clone();
                entry.ms = ms;
                entry.fixes = fixes.clone();
                entry.tests = tests.clone();
            }
        }
        self.publish(Event::EntryDone { id, status: status.to_owned(), error, ms, fixes, tests });
        if let Some(entry) = self.entry(id) {
            self.record_entry(&entry);
        }
    }

    /// The entry `id`, as kept.
    pub fn entry(&self, id: u64) -> Option<Entry> {
        self.transcript.lock().expect("transcript lock").iter().rev().find(|entry| entry.id == id).cloned()
    }

    // ---- The session ------------------------------------------------------------

    pub fn session_view(&self) -> SessionView {
        let files = self.files();
        let types = self.types.lock().expect("types lock").clone();
        self.session.lock().expect("session lock").view(&files, &types)
    }

    pub(crate) fn publish_session(&self) {
        self.publish(Event::Session(self.session_view()));
    }

    /// Refresh the observation record about 300 ms after the evaluations
    /// stop, and never while one is in flight.
    fn watch_observations(self: &Arc<Self>) {
        let studio = Arc::downgrade(self);
        let due = self.observations_due.clone();
        tokio::spawn(async move {
            loop {
                due.notified().await;
                while tokio::time::timeout(OBSERVE_PAUSE, due.notified()).await.is_ok() {}
                let Some(studio) = studio.upgrade() else { return };
                studio.refresh_observations().await;
            }
        });
    }

    /// Echo a gesture as the command it is, dimmed in the transcript.
    pub fn echo(&self, line: &str) {
        let id = self.begin(Entry { kind: "echo", line: line.to_owned(), ..Entry::default() });
        self.finish(id, "ok", None, 0);
    }

    /// Echo a command with a line saying what it did, or (`failed`) why
    /// it could not.
    pub fn echo_note(&self, line: &str, note: &str, failed: bool) {
        let id = self.begin(Entry { kind: "echo", line: line.to_owned(), ..Entry::default() });
        if failed {
            self.finish(id, "error", Some(note.to_owned()), 0);
        } else {
            self.output(id, "out", format!("{note}\n"));
            self.finish(id, "ok", None, 0);
        }
    }

    /// The latest REPL lines, oldest first, briefly: what a question carries.
    pub fn recent(&self, count: usize) -> Vec<Entry> {
        let transcript = self.transcript.lock().expect("transcript lock");
        let mut recent: Vec<Entry> =
            transcript.iter().rev().filter(|entry| entry.kind == "eval" || entry.kind == "echo").take(count).cloned().collect();
        recent.reverse();
        recent
    }

    // ---- The review, as tabs see it -----------------------------------------------

    pub(crate) fn review_view(&self) -> ReviewView {
        let files = self.files();
        let review = self.review.lock().expect("review lock");
        let mut view = review.view(&files);
        let kept = self.acceptances.lock().expect("acceptances lock");
        for op in &mut view.ops {
            op.check = kept
                .get(&op.op.id)
                .filter(|(key, _)| *key == crate::ask::acceptance_key(&files, &review, op.op.id))
                .map(|(_, check)| check.clone());
        }
        view
    }

    pub(crate) fn publish_review(&self) {
        self.publish(Event::Review(self.review_view()));
        self.review_changed.notify_one();
    }

    pub(crate) fn agent_event(&self, event: AgentEvent) {
        self.publish(Event::Agent(event));
    }
}

/// Whether the compiler checks `file`.
pub fn checkable(file: &str) -> bool {
    file.ends_with(".puf") || file.ends_with(".scm")
}
