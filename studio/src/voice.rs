//! Voice mode (docs/VOICE.md): the author talks, and the program is built
//! and navigated as they do.
//!
//! Each final utterance from the browser's speech recognizer takes two
//! paths at once:
//! - the **router**, one fast Messages API call (claude_api.rs; ~1-2 s),
//!   decides what the words are for: moving the author's focus (a
//!   definition, its usages, a line, a file, a text search), steering the
//!   builder, a control (stop, undo, run the properties), or nothing (talk
//!   not meant for the studio). Navigation is resolved here, from the
//!   program's text, and never waits on the builder.
//! - the **builder**, a long-running `claude -p` agent with this server's
//!   MCP tools (in voice mode: edits apply at once, no proposals), builds
//!   what was asked. A new instruction either interrupts it (killed and
//!   resumed with the new words; what it already applied stays) or queues
//!   behind it, as the router judges. When it stops with properties
//!   failing it is sent back to fix them, a bounded number of times.
//!
//! Everything shown goes out as `Event::Voice`; the browser side is
//! `web/voice.js`.

use crate::claude_api::{self, Api};
use crate::props::{self, Results};
use crate::review::{Change, apply};
use crate::sexp;
use crate::studio::{Event, Studio};
use crate::toolchain::{self, Files};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::fmt::Write as _;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::process::{Child, Command};

/// The header naming a voice builder's MCP calls (mcp.rs).
pub const VOICE_HEADER: &str = "x-studio-voice";
/// The review thread a voice builder reads as: it has no proposals, so it
/// sees the program as it is.
pub const VOICE_THREAD: u32 = u32::MAX - 1;
/// How many voice events a tab that opens later is shown.
const LOG: usize = 1000;
/// How many lines of conversation the router and builder see.
const CONVERSATION: usize = 12;
/// How many times a builder is sent back on its own to fix failing
/// properties, per instruction from the author.
const AUTO_FIXES: u32 = 2;
/// The steps one builder run may take.
const MAX_TURNS: u32 = 80;
/// Most places a focus shows.
const MAX_TARGETS: usize = 40;
/// Words the router did nothing with (not yet a request: the recognizer
/// ends a phrase at every pause) are read with what comes next, for this long.
const FRAGMENT_TTL: Duration = Duration::from_secs(45);

/// What the browser knows when the author speaks.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Context {
    /// The shown file and the cursor's line in it.
    #[serde(default)]
    pub file: Option<String>,
    #[serde(default)]
    pub line: Option<usize>,
    /// What the mouse rests on: a file, a line, the word there.
    #[serde(default)]
    pub hover: Option<Hover>,
    /// The selected text, if any.
    #[serde(default)]
    pub selection: Option<String>,
    /// The first and last visible lines.
    #[serde(default)]
    pub visible: Option<(usize, usize)>,
    /// The selection's first and last lines, if any.
    #[serde(default)]
    pub selection_lines: Option<(usize, usize)>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct Hover {
    pub file: String,
    pub line: usize,
    #[serde(default)]
    pub word: String,
}

/// A voice event: `kind` and its fields (web/voice.js).
#[derive(Clone, Debug, Serialize)]
pub struct VoiceEvent {
    pub kind: String,
    #[serde(flatten)]
    pub data: Value,
}

#[derive(Default)]
struct State {
    /// The builder's claude session, resumed by every run after the first.
    session: Option<String>,
    child: Option<Child>,
    /// A builder task is driving runs.
    running: bool,
    /// Instructions not yet given to the builder, oldest first.
    pending: Vec<String>,
    /// The run in flight was killed for a newer instruction.
    interrupted: bool,
    /// The author said stop: the run in flight ends, the queue empties.
    stopped: bool,
    auto_fixes: u32,
    /// The builder's run in flight, numbered from 1 (0: none yet); every
    /// step and edit it makes carries it, so the trace groups them.
    turn: u64,
    /// Each tool call in flight: its id -> its tool's name.
    calls: std::collections::HashMap<String, String>,
    /// What the builder is doing, as the tabs show it.
    activity: Value,
    log: VecDeque<Value>,
    conversation: VecDeque<String>,
    properties: Results,
    /// (file, its text before) of each builder edit, newest last.
    undo: Vec<(String, Option<String>)>,
    /// (file, from, to) of each builder edit this turn: what the board
    /// arranges itself around when the turn ends (board.rs auto_arrange).
    touched: Vec<(String, usize, usize)>,
    /// Phrases the router found nothing in, when, oldest first: the start
    /// of a sentence the author is still saying. The next phrase is routed
    /// with them, and they are dropped once a phrase does something.
    fragments: Vec<(Instant, String)>,
    /// The excursion open, if one is (excursion.rs).
    excursion: Option<crate::excursion::Excursion>,
}

pub struct Voice {
    api: Option<Api>,
    state: Mutex<State>,
    model: String,
    effort: String,
    /// The latest change to the program; properties run once it settles.
    changed: Mutex<Option<Instant>>,
    /// Phrases are routed one at a time, in order, so each sees what the
    /// one before it came to (its fragments, the conversation).
    routing: tokio::sync::Mutex<()>,
}

impl Default for Voice {
    fn default() -> Self {
        Self::new()
    }
}

impl Voice {
    pub fn new() -> Self {
        Self {
            api: Api::from_env(),
            state: Mutex::new(State { activity: json!({ "state": "idle" }), ..State::default() }),
            model: crate::setting("PUFFIN_VOICE_MODEL", claude_api::DEEP_MODEL),
            effort: crate::setting("PUFFIN_VOICE_EFFORT", "medium"),
            changed: Mutex::new(None),
            routing: tokio::sync::Mutex::new(()),
        }
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().expect("voice lock")
    }

    /// Why voice mode cannot route or build, if it cannot.
    pub fn unavailable(&self) -> Option<String> {
        if self.api.is_none() {
            return Some("voice mode needs the Claude API: set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN".to_owned());
        }
        crate::agent::Agent::unavailable()
    }
}

impl Studio {
    /// The open excursion's slot, under the voice lock.
    pub(crate) fn voice_excursion<T>(&self, f: impl FnOnce(&mut Option<crate::excursion::Excursion>) -> T) -> T {
        f(&mut self.voice.state().excursion)
    }

    pub(crate) fn voice_api(&self) -> Option<&Api> {
        self.voice.api.as_ref()
    }

    /// Every tab is shown the excursion as it is now (or that it closed).
    pub(crate) fn publish_excursion(&self) {
        let view = self.excursion_view();
        self.voice_event("excursion", json!({ "excursion": view }));
    }

    fn excursion_view(&self) -> Value {
        let open = self.voice.state().excursion.clone();
        match open {
            Some(excursion) => excursion.view(&self.files()),
            None => Value::Null,
        }
    }

    pub(crate) fn voice_event(&self, kind: &str, data: Value) {
        let mut entry = data.clone();
        entry["kind"] = json!(kind);
        entry["at"] = json!(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0));
        {
            let mut state = self.voice.state();
            // the log replays the conversation, not every flicker of activity
            if !matches!(kind, "activity" | "interim" | "excursion") {
                state.log.push_back(entry.clone());
                while state.log.len() > LOG {
                    state.log.pop_front();
                }
            }
        }
        self.publish(Event::Voice(VoiceEvent { kind: kind.to_owned(), data: entry }));
    }

    fn converse(&self, line: String) {
        let mut state = self.voice.state();
        state.conversation.push_back(line);
        while state.conversation.len() > CONVERSATION {
            state.conversation.pop_front();
        }
    }

    fn set_activity(&self, activity: Value) {
        self.voice.state().activity = activity.clone();
        self.voice_event("activity", activity);
    }

    /// What a tab opening voice mode is shown: the conversation so far,
    /// the properties, what the builder is doing.
    pub fn voice_state(&self) -> Value {
        let excursion = self.excursion_view();
        let state = self.voice.state();
        json!({
            "t": "voice-state",
            "log": state.log,
            "properties": state.properties,
            "activity": state.activity,
            "unavailable": self.voice.unavailable(),
            "excursion": excursion,
            "model": self.voice.model,
        })
    }

    /// The author said `utterance`.
    pub fn hear(self: &Arc<Self>, utterance: String, context: Context) {
        let utterance = utterance.trim().to_owned();
        if utterance.is_empty() {
            return;
        }
        self.voice_event("heard", json!({ "text": utterance }));
        self.record("voice", json!({ "line": utterance }));
        let studio = self.clone();
        tokio::spawn(async move {
            let started = Instant::now();
            let decision = {
                let _turn = studio.voice.routing.lock().await;
                let before = studio.fragments();
                let decision = studio.route(&utterance, &before, &context).await;
                if let Ok(decision) = &decision {
                    let mut state = studio.voice.state();
                    if inert(decision) {
                        state.fragments.push((Instant::now(), utterance.clone()));
                        // chatter not meant for the studio is kept too: only
                        // the last couple can be the start of a request
                        while state.fragments.len() > 2 {
                            state.fragments.remove(0);
                        }
                    } else {
                        state.fragments.clear();
                    }
                }
                decision
            };
            match decision {
                Ok(decision) => {
                    let ms = started.elapsed().as_millis() as u64;
                    studio.converse(format!("author: {utterance}"));
                    studio.act(&utterance, decision, &context, ms).await;
                }
                Err(error) => studio.voice_event("error", json!({ "message": format!("could not route that: {error}") })),
            }
        });
    }

    /// A control from a button in the voice panel.
    pub fn voice_control(self: &Arc<Self>, command: &str) {
        let studio = self.clone();
        let command = command.to_owned();
        tokio::spawn(async move { studio.control(&command).await });
    }

    async fn control(self: &Arc<Self>, command: &str) {
        match command {
            "stop" => {
                let killed = {
                    let mut state = self.voice.state();
                    state.pending.clear();
                    state.stopped = true;
                    state.child.as_mut().is_some_and(|child| child.start_kill().is_ok())
                };
                self.voice_event("reply", json!({ "text": if killed { "Stopped." } else { "Nothing is running." }, "speak": true }));
            }
            "undo" => {
                let last = self.voice.state().undo.pop();
                match last {
                    Some((file, Some(before))) => {
                        self.replace(&file, before, "voice", "undo");
                        self.voice_event("reply", json!({ "text": format!("Undid the builder's last edit to {file}."), "speak": true }));
                    }
                    Some((file, None)) => {
                        let _ = self.delete_file(&file);
                        self.voice_event("reply", json!({ "text": format!("Removed {file}, which the builder made."), "speak": true }));
                    }
                    None => self.voice_event("reply", json!({ "text": "The builder has made no edits to undo.", "speak": true })),
                }
            }
            "run-properties" => {
                self.run_properties().await;
            }
            "close-excursion" => self.close_excursion(),
            "new-conversation" => {
                let mut state = self.voice.state();
                state.session = None;
                state.conversation.clear();
                state.fragments.clear();
                drop(state);
                self.voice_event("reply", json!({ "text": "Starting a fresh conversation with the builder.", "speak": true }));
            }
            other => self.voice_event("error", json!({ "message": format!("unknown voice control {other}") })),
        }
    }

    // ---- The router -------------------------------------------------------------

    /// The fragments still fresh enough to be the start of what comes next.
    fn fragments(&self) -> Vec<String> {
        let mut state = self.voice.state();
        state.fragments.retain(|(at, _)| at.elapsed() < FRAGMENT_TTL);
        state.fragments.iter().map(|(_, text)| text.clone()).collect()
    }

    async fn route(&self, utterance: &str, before: &[String], context: &Context) -> Result<Value, String> {
        let api = self.voice.api.as_ref().ok_or("no Claude API credentials")?;
        let files = self.files();
        let mut user = String::new();
        let _ = writeln!(user, "Files and their top-level definitions (name:line; a type's constructors in brackets, each name:line):");
        for (path, text) in &files {
            let names: Vec<String> = sexp::forms(text)
                .iter()
                .filter_map(|form| {
                    let name = form.name.as_ref()?;
                    let made: Vec<String> = sexp::constructors_at(text, form).iter().map(|(c, line)| format!("{c}:{line}")).collect();
                    Some(if made.is_empty() { format!("{name}:{}", form.line) } else { format!("{name}:{} [{}]", form.line, made.join(", ")) })
                })
                .take(80)
                .collect();
            let _ = writeln!(user, "- {path} ({} lines): {}", text.lines().count(), names.join(", "));
        }
        let _ = writeln!(user, "\nThe author's view: {}", serde_json::to_string(context).unwrap_or_default());
        if let Some(hover) = &context.hover
            && let Some(text) = files.get(&hover.file)
            && let Some(line) = text.lines().nth(hover.line.saturating_sub(1))
        {
            let _ = writeln!(user, "The line under the mouse ({}:{}): {}", hover.file, hover.line, line.trim());
        }
        if let (Some(file), Some(line)) = (&context.file, context.line)
            && let Some(text) = files.get(file)
        {
            let offset = sexp::offset_of(text, line, 1);
            if let Some(form) = sexp::form_at(text, offset) {
                let _ = writeln!(user, "The form at the cursor ({file}:{}): {}", form.line, toolchain::clip(&text[form.start..form.end], 600));
            }
        }
        if let Some(file) = &context.file
            && let Some(text) = files.get(file)
        {
            // the shown file line by line, so a clause inside a definition
            // ("the fix case", "where it extends the environment") can be
            // found and named by its lines
            let shown = crate::excursion::numbered(text, 1);
            if shown.len() <= 16_000 {
                let _ = writeln!(user, "\nThe shown file, {file}, numbered:\n{shown}");
            }
        }
        let (activity, running, queued, conversation, properties, excursion) = {
            let state = self.voice.state();
            (
                state.activity.clone(),
                state.running,
                state.pending.len(),
                state.conversation.iter().cloned().collect::<Vec<_>>(),
                state.properties.describe(),
                state.excursion.as_ref().map(crate::excursion::Excursion::describe),
            )
        };
        let board = self.board();
        let _ = writeln!(
            user,
            "\nThe view: {} (mode: {}){}",
            board["view"].as_str().unwrap_or("editor"),
            board["mode"].as_str().unwrap_or("build"),
            board["focus"]["label"].as_str().map(|l| format!("; focused on: {l}")).unwrap_or_default()
        );
        let open_questions: Vec<String> = board["questions"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|q| q["answered"] != json!(true))
            .map(|q| format!("#{} (about {}): {}", q["id"], q["about"], q["text"].as_str().unwrap_or("")))
            .collect();
        if !open_questions.is_empty() {
            let _ = writeln!(user, "The builder's open questions to the author:\n{}", open_questions.join("\n"));
        }
        if running {
            let doing = activity["text"].as_str().or(activity["state"].as_str()).unwrap_or("working");
            let _ = writeln!(user, "\nThe builder is WORKING ({doing}){}.", if queued > 0 { format!("; {queued} instruction(s) queued after it") } else { String::new() });
        } else {
            let _ = writeln!(
                user,
                "\nThe builder is IDLE: nothing is being built and nothing is queued. Unless your answer has a build \
                 instruction, nothing will be built."
            );
        }
        match &excursion {
            Some(open) => {
                let _ = writeln!(user, "{open}");
            }
            None => {
                let _ = writeln!(user, "No excursion is open.");
            }
        }
        let _ = writeln!(user, "Properties:\n{properties}");
        if !conversation.is_empty() {
            let _ = writeln!(user, "\nThe conversation so far, oldest first:\n{}", conversation.join("\n"));
        }
        if !before.is_empty() {
            let quoted: Vec<String> = before.iter().map(|text| format!("\"{text}\"")).collect();
            let _ = writeln!(
                user,
                "\nJust before, the author said {} -- you did nothing with it then, as not yet a whole request. \
                 It is likely the start of what they say now (the speech recognizer ends a phrase at every pause): \
                 read it and the new words as ONE utterance, and keep everything it asked for in any instruction.",
                quoted.join(", then ")
            );
        }
        let _ = writeln!(user, "\nThe author just said: \"{utterance}\"");
        api.structured(claude_api::FAST_MODEL, "low", ROUTER, &user, router_schema(), 1200, Duration::from_secs(20)).await
    }

    async fn act(self: &Arc<Self>, utterance: &str, decision: Value, context: &Context, ms: u64) {
        let control = decision["control"].as_str().unwrap_or("none");
        let arrange = &decision["arrange"];
        let arrange_kind = arrange["action"].as_str().unwrap_or("none");
        let answer_to = decision["answer"]["question"].as_u64().unwrap_or(0);
        let answer_text = decision["answer"]["text"].as_str().unwrap_or("").trim().to_owned();
        let navigate = &decision["navigate"];
        let nav_kind = navigate["kind"].as_str().unwrap_or("none");
        let build = &decision["build"];
        let instruction = build["instruction"].as_str().unwrap_or("").trim().to_owned();
        let urgency = build["urgency"].as_str().unwrap_or("none");
        let reply = decision["reply"].as_str().unwrap_or("").trim().to_owned();
        let explain = &decision["explain"];
        let explain_kind = explain["action"].as_str().unwrap_or("none");
        let mut did = Vec::new();
        if nav_kind != "none" {
            did.push(format!("navigate {nav_kind}"));
        }
        if urgency != "none" && !instruction.is_empty() {
            did.push(format!("build ({urgency})"));
        }
        if control != "none" {
            did.push(control.to_owned());
        }
        if arrange_kind != "none" {
            did.push(format!("arrange {arrange_kind}"));
        }
        if answer_to != 0 {
            did.push(format!("answer #{answer_to}"));
        }
        match explain_kind {
            "ask" => did.push("explain".to_owned()),
            "close" => did.push("close the excursion".to_owned()),
            _ => {}
        }
        self.voice_event("routed", json!({ "text": utterance, "did": did, "ms": ms, "decision": decision }));
        if !reply.is_empty() {
            self.voice_event("reply", json!({ "text": reply, "speak": true }));
            self.converse(format!("studio: {reply}"));
        }
        if nav_kind != "none" {
            self.navigate(navigate, context);
        }
        if arrange_kind != "none" {
            match self.arrange(arrange) {
                Ok(said) if !said.is_empty() && reply.is_empty() => self.voice_event("reply", json!({ "text": said, "speak": true })),
                Ok(_) => {}
                Err(why) => self.voice_event("reply", json!({ "text": why, "speak": true })),
            }
        }
        if answer_to != 0 && !answer_text.is_empty() {
            self.answer(answer_to, answer_text.clone());
        }
        if explain_kind != "none" {
            self.explain(explain, context);
        }
        if control != "none" {
            match control {
                // the browser's own: listening and speaking
                "mute" | "unmute" | "sleep" | "follow" | "unfollow" | "next" | "previous" | "run" | "show-output" | "hide-output" => {
                    self.voice_event("client", json!({ "command": control }));
                }
                other => self.control(other).await,
            }
        }
        if urgency != "none" && !instruction.is_empty() {
            self.instruct(instruction, urgency == "interrupt", context.clone());
        }
    }

    // ---- Navigation -------------------------------------------------------------

    fn navigate(&self, navigate: &Value, context: &Context) {
        let files = self.files();
        let kind = navigate["kind"].as_str().unwrap_or("");
        let name = navigate["name"].as_str().unwrap_or("").trim();
        let file = navigate["file"].as_str().unwrap_or("").trim();
        let query = navigate["query"].as_str().unwrap_or("").trim();
        let line = navigate["line"].as_u64().unwrap_or(0) as usize;
        let here = context.file.clone().unwrap_or_default();
        let (label, targets) = match kind {
            "definition" => {
                let found = definitions(&files, name);
                (format!("definition of {name}"), found)
            }
            "usages" => {
                let mut found = definitions(&files, name);
                let resolved = found.first().map(|t| t["name"].as_str().unwrap_or(name).to_owned()).unwrap_or_else(|| name.to_owned());
                found.extend(usages(&files, &resolved));
                dedupe(&mut found);
                (format!("{resolved}: definition and uses"), found)
            }
            "line" => {
                let file = if file.is_empty() || !files.contains_key(file) { here.clone() } else { file.to_owned() };
                (format!("{file}:{line}"), target(&files, &file, line.max(1), "line").into_iter().collect())
            }
            "file" => {
                let found = files.keys().find(|path| path.as_str() == file).or_else(|| {
                    let want = normalize(file);
                    files.keys().find(|path| normalize(path).contains(&want))
                });
                match found {
                    Some(path) => (path.clone(), target(&files, path, 1, "file").into_iter().collect()),
                    None => (file.to_owned(), Vec::new()),
                }
            }
            "text" => (format!("“{query}”"), search(&files, query)),
            "next" | "previous" | "back" => {
                self.voice_event("client", json!({ "command": kind }));
                return;
            }
            _ => return,
        };
        if targets.is_empty() {
            let text = format!("I couldn't find {label}.");
            self.voice_event("reply", json!({ "text": text, "speak": true }));
            return;
        }
        let mut targets = targets;
        targets.truncate(MAX_TARGETS);
        self.voice_event("focus", json!({ "label": label, "targets": targets }));
    }

    // ---- The builder ------------------------------------------------------------

    /// Give the builder `instruction`: now, cutting off what it is doing,
    /// or after it.
    fn instruct(self: &Arc<Self>, instruction: String, interrupt: bool, context: Context) {
        let line = match &context.hover {
            Some(hover) if !hover.word.is_empty() => format!("{instruction}\n  (the mouse was on `{}` at {}:{})", hover.word, hover.file, hover.line),
            _ => instruction,
        };
        let start = {
            let mut state = self.voice.state();
            state.pending.push(line);
            state.auto_fixes = 0;
            state.stopped = false;
            if interrupt && state.child.is_some() {
                state.interrupted = true;
                if let Some(child) = state.child.as_mut() {
                    let _ = child.start_kill();
                }
            }
            let start = !state.running;
            state.running = true;
            start
        };
        if !start {
            self.set_activity(json!({ "state": if interrupt { "redirecting" } else { "queued" }, "text": if interrupt { "taking the new instruction" } else { "will do that next" } }));
            return;
        }
        let studio = self.clone();
        tokio::spawn(async move { studio.drive().await });
    }

    /// Run the builder while there is something for it to do.
    async fn drive(self: Arc<Self>) {
        loop {
            let (batch, interrupted) = {
                let mut state = self.voice.state();
                if state.pending.is_empty() {
                    state.running = false;
                    drop(state);
                    self.set_activity(json!({ "state": "idle" }));
                    return;
                }
                let interrupted = std::mem::take(&mut state.interrupted);
                (std::mem::take(&mut state.pending), interrupted)
            };
            self.build(batch, interrupted).await;
            // the properties as the run left them, and back to fix them if
            // they fail -- unless the author stopped it or spoke since
            if self.files().contains_key(props::PROPERTIES) {
                let results = self.run_properties().await;
                let mut state = self.voice.state();
                let failing: Vec<String> = results.failing().iter().map(|p| format!("{} ({}: {})", p.name, p.status, p.detail)).collect();
                if state.pending.is_empty() && !state.stopped && !state.interrupted && (!failing.is_empty() || results.error.is_some()) && state.auto_fixes < AUTO_FIXES {
                    state.auto_fixes += 1;
                    let why = results.error.clone().unwrap_or_else(|| failing.join("; "));
                    state.pending.push(format!(
                        "(Automatic, not from the author.) The properties do not pass: {why}. Fix the program so they pass -- do not weaken a property -- or, if a property itself is wrong, say so with `say` and stop."
                    ));
                }
            }
        }
    }

    async fn build(self: &Arc<Self>, batch: Vec<String>, interrupted: bool) {
        let config = match self.voice_config() {
            Ok(path) => path,
            Err(error) => {
                self.voice_event("error", json!({ "message": error }));
                return;
            }
        };
        let mut prompt = self.builder_preamble();
        if interrupted {
            prompt.push_str("\nYou were interrupted: the author spoke while you worked. Your edits so far are applied. Take up the new words now; drop anything they make moot.\n");
        }
        prompt.push_str("\nThe author said:\n");
        for line in &batch {
            let _ = writeln!(prompt, "- {line}");
        }
        let system = crate::knowledge::system_prompt(&self.root, BUILDER);
        let mut resume = self.voice.state().session.clone();
        let turn = {
            let mut state = self.voice.state();
            state.turn += 1;
            state.calls.clear();
            state.touched.clear();
            state.turn
        };
        let began = Instant::now();
        self.voice_event("turn", json!({ "turn": turn, "instructions": batch, "interrupted": interrupted }));
        self.set_activity(json!({ "state": "starting", "text": crate::agent::title_of(batch.last().map(String::as_str).unwrap_or("")) }));
        let mut outcome = "done";
        loop {
            let mut args: Vec<String> = vec![
                "-p".into(), prompt.clone(),
                "--output-format".into(), "stream-json".into(), "--verbose".into(),
                "--include-partial-messages".into(),
                "--model".into(), self.voice.model.clone(),
                "--effort".into(), self.voice.effort.clone(),
                "--disable-slash-commands".into(),
                "--setting-sources".into(), "user".into(),
                "--mcp-config".into(), config.to_string_lossy().into_owned(), "--strict-mcp-config".into(),
                "--tools".into(), "".into(),
                "--allowedTools".into(), format!("mcp__{}", crate::agent::SERVER),
                "--disallowedTools".into(), "Bash,Write,Edit,NotebookEdit,Skill".into(),
                "--max-turns".into(), MAX_TURNS.to_string(),
                "--append-system-prompt".into(), system.clone(),
                "--exclude-dynamic-system-prompt-sections".into(),
            ];
            if let Some(session) = &resume {
                args.extend(["--resume".to_owned(), session.clone()]);
            }
            let mut child = match Command::new("claude")
                .args(&args)
                // every tool loaded up front: deferred behind tool search, a
                // direct call to one fails ("No such tool available")
                .env("ENABLE_TOOL_SEARCH", "false")
                .current_dir(&self.directory)
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .kill_on_drop(true)
                .spawn()
            {
                Ok(child) => child,
                Err(error) => {
                    self.voice_event("error", json!({ "message": format!("could not start claude: {error}") }));
                    break;
                }
            };
            let stdout = child.stdout.take().expect("piped stdout");
            let mut stderr = child.stderr.take().expect("piped stderr");
            self.voice.state().child = Some(child);
            let stderr_text = tokio::spawn(async move {
                let mut text = String::new();
                let _ = stderr.read_to_string(&mut text).await;
                text
            });
            let mut lines = BufReader::new(stdout).lines();
            let mut got_result = false;
            while let Ok(Some(line)) = lines.next_line().await {
                if let Ok(event) = serde_json::from_str::<Value>(&line) {
                    got_result |= self.builder_event(&event);
                }
            }
            let child = self.voice.state().child.take();
            let status = match child {
                Some(mut child) => child.wait().await.ok(),
                None => None,
            };
            let stderr_text = stderr_text.await.unwrap_or_default();
            let (cut, stopped) = {
                let state = self.voice.state();
                (state.interrupted, state.stopped)
            };
            if cut || stopped {
                outcome = if stopped { "stopped" } else { "interrupted" };
                break;
            }
            let failed = !got_result && !status.is_some_and(|status| status.success());
            if failed && resume.is_some() {
                // a session that cannot be resumed (an interrupted run can
                // leave one so): start afresh, with the conversation
                self.voice.state().session = None;
                resume = None;
                let conversation = self.voice.state().conversation.iter().cloned().collect::<Vec<_>>().join("\n");
                prompt = format!("(Your earlier conversation could not be resumed. Its last lines:\n{conversation})\n{prompt}");
                continue;
            }
            if failed {
                outcome = "failed";
                let last = stderr_text.lines().rev().find(|line| !line.trim().is_empty()).unwrap_or("no output").to_owned();
                self.voice_event("error", json!({ "message": format!("the builder stopped: {last}") }));
            }
            break;
        }
        let _ = std::fs::remove_file(&config);
        let touched = std::mem::take(&mut self.voice.state().touched);
        self.auto_arrange(&touched);
        self.voice_event("turn-end", json!({ "turn": turn, "ms": began.elapsed().as_millis() as u64, "outcome": outcome }));
    }

    /// Show one stream-json event of the builder; whether it was the result.
    fn builder_event(&self, event: &Value) -> bool {
        if !event["parent_tool_use_id"].is_null() {
            return false;
        }
        match event["type"].as_str() {
            Some("system") if event["subtype"] == "init" => {
                if let Some(session) = event["session_id"].as_str() {
                    self.voice.state().session = Some(session.to_owned());
                }
            }
            Some("stream_event") => {
                let inner = &event["event"];
                if inner["type"] == "content_block_start" {
                    match inner["content_block"]["type"].as_str() {
                        Some("thinking" | "redacted_thinking") => self.set_activity(json!({ "state": "thinking" })),
                        Some("text") => self.set_activity(json!({ "state": "talking" })),
                        _ => {}
                    }
                }
            }
            Some("assistant") => {
                for block in event["message"]["content"].as_array().into_iter().flatten() {
                    match block["type"].as_str() {
                        Some("text") => {
                            let text = block["text"].as_str().unwrap_or("").trim();
                            if !text.is_empty() {
                                let turn = self.voice.state().turn;
                                self.voice_event("builder", json!({ "text": text, "turn": turn }));
                                self.converse(format!("builder: {}", toolchain::clip(text, 400)));
                            }
                        }
                        Some("tool_use") => {
                            let name = block["name"].as_str().unwrap_or("").rsplit("__").next().unwrap_or("").to_owned();
                            let input = &block["input"];
                            let what = input["file"].as_str().or(input["name"].as_str()).or(input["query"].as_str()).unwrap_or("");
                            let text = describe_tool(&name, what);
                            let id = block["id"].as_str().unwrap_or("").to_owned();
                            let turn = {
                                let mut state = self.voice.state();
                                state.calls.insert(id.clone(), name.clone());
                                state.turn
                            };
                            // `say` and `show` speak for themselves in the trace
                            if !matches!(name.as_str(), "say" | "show" | "arrange") {
                                let mut step = json!({ "turn": turn, "id": id, "tool": name, "text": text });
                                if let Some(file) = input["file"].as_str() {
                                    step["file"] = json!(file);
                                }
                                if let Some(detail) = step_input(&name, input) {
                                    step["input"] = json!(detail);
                                }
                                self.voice_event("step", step);
                            }
                            self.set_activity(json!({ "state": "working", "tool": name, "text": text }));
                        }
                        _ => {}
                    }
                }
            }
            Some("user") => {
                for block in event["message"]["content"].as_array().into_iter().flatten() {
                    if block["type"] != "tool_result" {
                        continue;
                    }
                    let id = block["tool_use_id"].as_str().unwrap_or("").to_owned();
                    let (turn, name) = {
                        let state = self.voice.state();
                        (state.turn, state.calls.get(&id).cloned().unwrap_or_default())
                    };
                    if matches!(name.as_str(), "say" | "show") {
                        continue;
                    }
                    let text = match &block["content"] {
                        Value::String(text) => text.clone(),
                        Value::Array(parts) => parts.iter().filter_map(|part| part["text"].as_str()).collect::<Vec<_>>().join("\n"),
                        _ => String::new(),
                    };
                    let error = block["is_error"].as_bool().unwrap_or(false);
                    let (ok, summary) = step_outcome(&name, &text, error);
                    self.voice_event("step-done", json!({ "turn": turn, "id": id, "ok": ok, "summary": summary }));
                }
            }
            Some("result") => {
                if let Some(session) = event["session_id"].as_str() {
                    self.voice.state().session = Some(session.to_owned());
                }
                if event["is_error"].as_bool().unwrap_or(false) {
                    let text = event["result"].as_str().unwrap_or("").trim();
                    let message = if text.is_empty() { event["subtype"].as_str().unwrap_or("error").to_owned() } else { text.to_owned() };
                    self.voice_event("error", json!({ "message": format!("builder: {message}") }));
                }
                return true;
            }
            _ => {}
        }
        false
    }

    /// The MCP config of a builder run: our `/mcp`, its token, the voice
    /// header (mode 0600).
    fn voice_config(&self) -> Result<std::path::PathBuf, String> {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let config = json!({ "mcpServers": { crate::agent::SERVER: {
            "type": "http",
            "url": format!("http://127.0.0.1:{}/mcp", self.port()),
            "headers": {
                "Authorization": format!("Bearer {}", self.agent.mcp_token),
                "X-Studio-Thread": VOICE_THREAD.to_string(),
                "X-Studio-Voice": "1",
            },
        }}});
        let path = std::env::temp_dir().join(format!("puffin-studio-voice-{}.json", std::process::id()));
        std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&path)
            .and_then(|mut file| file.write_all(config.to_string().as_bytes()))
            .map_err(|error| format!("cannot write the builder's MCP config: {error}"))?;
        Ok(path)
    }

    /// What every builder run starts with: the files, the diagnostics, the
    /// properties, the conversation.
    fn builder_preamble(&self) -> String {
        let files = self.files();
        let mut out = String::from("(Puffin Studio, voice mode.)\n");
        let _ = writeln!(out, "Project {}.", self.directory.display());
        for (path, text) in &files {
            let names: Vec<String> = sexp::forms(text).iter().filter_map(|f| f.name.clone()).take(40).collect();
            let _ = writeln!(out, "- {path} ({} lines): {}", text.lines().count(), names.join(" "));
        }
        let diagnostics: Vec<String> = files
            .keys()
            .flat_map(|path| self.diagnostics_of(path))
            .map(|d| format!("{}: {} [{}:{}]", d.severity, d.message, d.file, d.line))
            .take(20)
            .collect();
        if !diagnostics.is_empty() {
            let _ = writeln!(out, "Diagnostics now:\n{}", diagnostics.join("\n"));
        }
        let (properties, conversation) = {
            let state = self.voice.state();
            (state.properties.describe(), state.conversation.iter().cloned().collect::<Vec<_>>())
        };
        let _ = writeln!(out, "Properties:\n{properties}");
        if !conversation.is_empty() {
            let _ = writeln!(out, "Recent conversation:\n{}", conversation.join("\n"));
        }
        let board = self.board();
        if board["mode"] == json!("plan") {
            out.push_str(PLAN_MODE);
        }
        out.push_str(&crate::board::describe_notes(&board));
        let open: Vec<String> = board["questions"].as_array().into_iter().flatten().filter(|q| q["answered"] != json!(true)).map(|q| format!("#{}: {}", q["id"], q["text"].as_str().unwrap_or(""))).collect();
        if !open.is_empty() {
            let _ = writeln!(out, "Your questions the author has not answered yet:\n{}", open.join("\n"));
        }
        out
    }

    // ---- Questions (docs/PLANNING.md §4) ----------------------------------------

    /// The builder asks the author `question` about the definitions
    /// `about`: the board shows their slice, the question is said.
    fn ask_author(&self, question: &str, about: &[String], why: &str) -> u64 {
        let outline = crate::board::outline(&self.files());
        let props = self.text_of(props::PROPERTIES).unwrap_or_default();
        let items = crate::board::slice(&outline, about, &props);
        let mut id = 0;
        self.update_board(|board| {
            id = board["questions"].as_array().map(|qs| qs.iter().filter_map(|q| q["id"].as_u64()).max().unwrap_or(0)).unwrap_or(0) + 1;
            if !board["questions"].is_array() {
                board["questions"] = json!([]);
            }
            board["questions"].as_array_mut().unwrap().push(json!({ "id": id, "text": question, "about": about, "why": why, "answered": false }));
            for (file, _) in &items {
                if !board["cards"].as_array().into_iter().flatten().any(|c| c["path"] == json!(file)) {
                    board["cards"].as_array_mut().unwrap().push(json!({ "path": file, "x": null, "y": null, "open": [], "hidden": [], "pinned": [] }));
                }
            }
            board["focus"] = json!({ "items": items, "question": id, "label": format!("question #{id}") });
            board["view"] = json!("board");
        });
        id
    }

    /// The author answered question `id`: it is closed, the focus goes, and
    /// the builder is told to record the decision.
    pub fn answer(self: &Arc<Self>, id: u64, text: String) {
        let mut question = String::new();
        self.update_board(|board| {
            for q in board["questions"].as_array_mut().into_iter().flatten() {
                if q["id"] == json!(id) {
                    q["answered"] = json!(true);
                    q["answer"] = json!(text);
                    question = q["text"].as_str().unwrap_or("").to_owned();
                }
            }
            if board["focus"]["question"] == json!(id) {
                board["focus"] = Value::Null;
            }
        });
        if question.is_empty() {
            return;
        }
        self.voice_event("reply", json!({ "text": format!("Noted for question {id}."), "speak": false }));
        self.converse(format!("author (answering #{id} \"{question}\"): {text}"));
        self.instruct(
            format!("The author answered your question #{id} (\"{question}\"): \"{text}\". Record the decision in the program -- as a property (add_property) when it says what must happen, or in the types and signatures when it says how things are built -- then carry on."),
            false,
            Context::default(),
        );
    }

    // ---- Properties -------------------------------------------------------------

    pub async fn run_properties(&self) -> Results {
        let files = self.files();
        if !files.contains_key(props::PROPERTIES) {
            return Results::default();
        }
        self.ensure_harness();
        let results = props::run(self, &self.files()).await;
        self.voice.state().properties = results.clone();
        self.voice_event("properties", json!({ "results": results }));
        results
    }

    /// `prop.puf` beside `properties.puf`, as this studio has it.
    fn ensure_harness(&self) {
        if self.text_of(props::HARNESS).as_deref() != Some(props::HARNESS_TEXT) {
            self.replace(props::HARNESS, props::HARNESS_TEXT.to_owned(), "voice", "the property harness");
        }
    }

    /// Run the properties once edits settle, whoever made them.
    pub fn watch_properties(self: &Arc<Self>) {
        let studio = self.clone();
        let mut events = self.subscribe();
        tokio::spawn(async move {
            loop {
                match events.recv().await {
                    Ok(Event::Text { file, .. }) if file != props::HARNESS => {
                        *studio.voice.changed.lock().expect("voice lock") = Some(Instant::now());
                        let again = studio.clone();
                        tokio::spawn(async move {
                            tokio::time::sleep(Duration::from_millis(1500)).await;
                            let settled = again.voice.changed.lock().expect("voice lock").is_some_and(|at| at.elapsed() >= Duration::from_millis(1400));
                            // the builder runs them itself when it stops
                            let building = again.voice.state().child.is_some();
                            if settled && !building && again.files().contains_key(props::PROPERTIES) {
                                *again.voice.changed.lock().expect("voice lock") = None;
                                again.run_properties().await;
                            }
                        });
                    }
                    Ok(_) => {}
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                    Err(_) => return,
                }
            }
        });
    }

    // ---- The builder's tools (mcp.rs routes voice calls here) ----------------

    pub async fn voice_call(self: &Arc<Self>, name: &str, arguments: &Value) -> Result<Value, String> {
        let text = |key: &str| arguments[key].as_str().map(str::to_owned).ok_or_else(|| format!("missing string argument `{key}`"));
        let note = arguments["note"].as_str().unwrap_or("").to_owned();
        match name {
            "edit" => {
                let change = Change { file: text("file")?, old: arguments["old"].as_str().unwrap_or("").to_owned(), new: text("new")? };
                self.apply_voice(change, &note).await
            }
            "write_file" => {
                let file = crate::studio::valid_path(&text("file")?)?;
                let body = text("text")?;
                let mut files = self.files();
                files.insert(file.clone(), body);
                self.land(&file, files, &note).await
            }
            "delete_file" => {
                let file = text("file")?;
                let before = self.text_of(&file);
                self.delete_file(&file)?;
                self.voice.state().undo.push((file.clone(), before));
                Ok(json!({ "deleted": file }))
            }
            "add_property" => {
                let property = text("name")?;
                let statement = text("statement")?;
                let code = text("code")?;
                let requires: Vec<String> = arguments["requires"].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(str::to_owned)).collect();
                let mut current = self.text_of(props::PROPERTIES).unwrap_or_else(|| props::new_file(&requires));
                for module in &requires {
                    let line = format!("(require \"{module}\")");
                    if !current.contains(&line) {
                        // after the harness's require, with the others
                        current = current.replacen("(require \"prop.puf\")\n", &format!("(require \"prop.puf\")\n{line}\n"), 1);
                    }
                }
                let mut files = self.files();
                files.insert(props::PROPERTIES.to_owned(), format!("{}\n\n;; @property {property}: {statement}\n{}\n", current.trim_end(), code.trim()));
                self.ensure_harness();
                files.insert(props::HARNESS.to_owned(), props::HARNESS_TEXT.to_owned());
                let mut answer = self.land(props::PROPERTIES, files, &format!("property {property}")).await?;
                let results = self.run_properties().await;
                answer["properties"] = json!(results.describe());
                Ok(answer)
            }
            "run_properties" => {
                let results = self.run_properties().await;
                Ok(json!({ "properties": results.describe(), "ms": results.ms }))
            }
            "research" => {
                let question = text("question")?;
                let api = self.voice.api.clone().ok_or("no Claude API credentials")?;
                self.set_activity(json!({ "state": "working", "tool": "research", "text": format!("researching: {}", crate::agent::title_of(&question)) }));
                let answer = api.research(&question).await?;
                Ok(json!({ "answer": answer }))
            }
            "ask" => {
                let question = text("question")?;
                let about: Vec<String> = arguments["about"].as_array().into_iter().flatten().filter_map(|v| v.as_str().map(str::to_owned)).collect();
                let why = arguments["why"].as_str().unwrap_or("").to_owned();
                let id = self.ask_author(&question, &about, &why);
                self.voice_event("reply", json!({ "text": question, "speak": true, "from": "builder" }));
                self.converse(format!("builder (asked #{id}): {question}"));
                Ok(json!({ "asked": id, "note": "The author sees the question with exactly the definitions it is about. Their answer will reach you as a new instruction; continue with work that does not depend on it, or stop." }))
            }
            "arrange" => {
                let mut arguments = arguments.clone();
                arguments["by"] = json!("builder");
                let said = self.arrange(&arguments)?;
                Ok(json!({ "arranged": true, "said": said }))
            }
            "say" => {
                let words = text("text")?;
                self.voice_event("reply", json!({ "text": words, "speak": true, "from": "builder" }));
                self.converse(format!("builder (said aloud): {words}"));
                Ok(json!({ "said": true }))
            }
            "show" => {
                let files = self.files();
                let file = text("file")?;
                let line = arguments["line"].as_u64().unwrap_or(1) as usize;
                let label = arguments["label"].as_str().unwrap_or(&file).to_owned();
                let targets: Vec<Value> = target(&files, &file, line, "builder").into_iter().collect();
                if targets.is_empty() {
                    return Err(format!("there is no file {file}"));
                }
                self.voice_event("focus", json!({ "label": label, "targets": targets, "from": "builder" }));
                Ok(json!({ "shown": true }))
            }
            _ => crate::mcp::call(self, Some(VOICE_THREAD), name, arguments).await,
        }
    }

    async fn apply_voice(self: &Arc<Self>, change: Change, note: &str) -> Result<Value, String> {
        if !change.old.is_empty() || !self.files().contains_key(&change.file) {
            crate::studio::valid_path(&change.file)?;
        }
        let after = apply(&self.files(), &change)?;
        self.land(&change.file, after, note).await
    }

    /// Put `file` as `after` has it into the program, at once; say where it
    /// changed and what the check says now.
    async fn land(self: &Arc<Self>, file: &str, after: Files, note: &str) -> Result<Value, String> {
        let text = after.get(file).cloned().ok_or_else(|| format!("there is no file {file}"))?;
        let before = self.text_of(file);
        if before.as_deref() == Some(text.as_str()) {
            return Ok(json!({ "applied": false, "note": "no change" }));
        }
        let (from, to) = changed_lines(before.as_deref().unwrap_or(""), &text);
        self.replace(file, text, "voice", note);
        {
            let mut state = self.voice.state();
            state.touched.push((file.to_owned(), from, to));
            state.undo.push((file.to_owned(), before));
            let len = state.undo.len();
            if len > 100 {
                state.undo.drain(..len - 100);
            }
        }
        let code: String = after.get(file).map(|text| text.lines().skip(from.saturating_sub(1)).take((to + 1 - from).min(40)).collect::<Vec<_>>().join("\n")).unwrap_or_default();
        let turn = self.voice.state().turn;
        self.voice_event("edited", json!({ "file": file, "from": from, "to": to, "note": note, "code": code, "turn": turn }));
        let report = self.check_program(&after, &[file.to_owned()]).await;
        let mut answer = json!({ "applied": true, "lines": [from, to] });
        if report.passes() && !report.holed() {
            answer["check"] = json!("the program passes the check");
        } else if report.passes() {
            answer["check"] = json!("passes the check; the typed holes (??) are the only parts not written yet");
        } else {
            answer["check"] = json!(format!("FAILS the check -- fix it next:\n{}", report.describe()));
        }
        let warnings: Vec<String> = report.diagnostics.iter().filter(|d| d.severity == "warning").map(|d| format!("{} [{}:{}]", d.message, d.file, d.line)).collect();
        if !warnings.is_empty() {
            answer["warnings"] = json!(warnings);
        }
        Ok(answer)
    }
}

/// The tools a voice builder has: the assistant's reads and checks, and
/// its own writes (applied at once).
/// A routing that does nothing at all: no navigation, build, control,
/// arrangement, answer or reply -- words that were not yet a request.
fn inert(decision: &Value) -> bool {
    let none = |v: &Value| v.as_str().is_none_or(|s| s == "none");
    none(&decision["navigate"]["kind"])
        && (none(&decision["build"]["urgency"]) || decision["build"]["instruction"].as_str().is_none_or(|s| s.trim().is_empty()))
        && none(&decision["control"])
        && none(&decision["arrange"]["action"])
        && decision["answer"]["question"].as_u64().unwrap_or(0) == 0
        && decision["reply"].as_str().is_none_or(|s| s.trim().is_empty())
        && none(&decision["explain"]["action"])
}

pub fn tools() -> Value {
    const READS: [&str; 13] = [
        "list_files", "get_file", "check", "assists_at", "holes", "lint", "type_at", "facts_at", "evaluate", "trace", "evaluate_program", "search_docs", "read_doc",
    ];
    let mut out: Vec<Value> = crate::mcp::tools().as_array().cloned().unwrap_or_default().into_iter().filter(|tool| READS.contains(&tool["name"].as_str().unwrap_or(""))).collect();
    let tool = |name: &str, description: &str, properties: Value, required: &[&str]| {
        json!({ "name": name, "description": description, "inputSchema": { "type": "object", "properties": properties, "required": required } })
    };
    out.extend([
        tool(
            "edit",
            "Change a file NOW (voice mode applies edits at once; no review). `old` is an exact piece of the file's current text occurring once, `new` its replacement; an empty `old` appends to the file, or makes a new file. Answers with the changed lines and the check of the program afterwards: fix what fails before moving on.",
            json!({ "file": {"type": "string"}, "old": {"type": "string"}, "new": {"type": "string"}, "note": {"type": "string", "description": "a few words: what this edit does"} }),
            &["file", "new"],
        ),
        tool(
            "write_file",
            "Make a file, or replace one's whole text, NOW. For scaffolding a new module in one step; prefer `edit` for changes.",
            json!({ "file": {"type": "string"}, "text": {"type": "string"}, "note": {"type": "string"} }),
            &["file", "text"],
        ),
        tool("delete_file", "Delete a file of the project.", json!({ "file": {"type": "string"} }), &["file"]),
        tool(
            "add_property",
            "Add a property to properties.puf (made, with the harness prop.puf, if missing) and run them all. `code` is one form: (check-property 'NAME (for-all (list GEN ...) (lambda (ARG ...) BOOL))) or (check-example 'NAME BOOL). Generators (prop.puf): gen-int gen-nat gen-small gen-bool gen-symbol gen-string, (gen-list g) (gen-nonempty-list g) (gen-vector g) (gen-pair a b) (gen-one-of g ...) (gen-elements LIST) (gen-map f g) (gen-bind g k) (gen-sized k) (gen-frequency (list (cons W g) ...)) (gen-const v); a generator is any (lambda (size) value). `requires` names the modules the property uses (each must provide what it uses).",
            json!({ "name": {"type": "string", "description": "a short kebab-case name"}, "statement": {"type": "string", "description": "the property in plain English, as the author meant it"}, "code": {"type": "string"}, "requires": {"type": "array", "items": {"type": "string"}} }),
            &["name", "statement", "code"],
        ),
        tool("run_properties", "Run every property in properties.puf; each one's status and any counterexample.", json!({}), &[]),
        tool(
            "research",
            "Look something up on the web (search and fetch run server-side): a paper, a spec, a definition. Ask a full question, e.g. 'In Van Horn & Might, Abstracting Abstract Machines (ICFP 2010), what are the CESK* machine's states and transition rules? Transcribe them exactly.' Slow (10-60 s): ask once, well.",
            json!({ "question": {"type": "string"} }),
            &["question"],
        ),
        tool(
            "say",
            "Speak one short sentence aloud to the author (they are listening, not reading): what you are starting on, what you finished, or a question you need answered. No code, no lists.",
            json!({ "text": {"type": "string"} }),
            &["text"],
        ),
        tool(
            "ask",
            "Ask the author a design question you cannot settle yourself and that matters (\"Should alloc be deterministic, so runs are reproducible?\"). `about` names the definitions it concerns: the studio lays out exactly those, what they use and what uses them, and the properties that mention them, says the question, and waits for the answer, which comes back to you as a new instruction. One question at a time, answerable in a sentence. Keep working on what does not depend on it, or stop.",
            json!({ "question": {"type": "string"}, "about": {"type": "array", "items": {"type": "string"}, "description": "top-level names the question is about"}, "why": {"type": "string", "description": "one sentence: what depends on the answer"} }),
            &["question", "about"],
        ),
        tool(
            "arrange",
            "Arrange the module board the author sees (they may also say it). action: open/close (show or fold definitions' bodies), hide/unhide (rows on their cards), only (just these definitions), slice (these and what touches them), clear, bring/put-away (modules' cards), show-board/show-editor, note (leave a comment, in `text`, on `names` or `modules` -- e.g. a design trade-off you noticed). Use it to put what you are talking about in front of them.",
            json!({ "action": {"type": "string"}, "names": {"type": "array", "items": {"type": "string"}}, "modules": {"type": "array", "items": {"type": "string"}}, "text": {"type": "string"} }),
            &["action"],
        ),
        tool(
            "show",
            "Move the author's view to a place, when they should look at it (e.g. a question about a line). Your edits already show themselves.",
            json!({ "file": {"type": "string"}, "line": {"type": "integer"}, "label": {"type": "string"} }),
            &["file"],
        ),
    ]);
    Value::Array(out)
}

// ---- Places in the program ------------------------------------------------------

fn normalize(name: &str) -> String {
    name.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}

fn target(files: &Files, file: &str, line: usize, role: &str) -> Option<Value> {
    let text = files.get(file)?;
    let count = text.lines().count().max(1);
    let line = line.clamp(1, count);
    let shown = text.lines().nth(line - 1).unwrap_or("").trim();
    Some(json!({ "file": file, "line": line, "text": toolchain::clip(shown, 160), "role": role }))
}

/// The top-level definitions named `name`, exactly, else by its letters
/// alone ("eval step" finds eval-step), else containing them.
fn definitions(files: &Files, name: &str) -> Vec<Value> {
    let want = normalize(name);
    if want.is_empty() {
        return Vec::new();
    }
    // every top-level definition, and every constructor of a define-type
    // (\"where is VRec defined\": on its line inside `Value`)
    let all: Vec<(String, String, usize)> = files
        .iter()
        .flat_map(|(path, text)| {
            sexp::forms(text).into_iter().flat_map(move |f| {
                let made: Vec<(String, String, usize)> = sexp::constructors_at(text, &f).into_iter().map(|(c, line)| (path.clone(), c, line)).collect();
                // a define-something names what it defines; a provide or a
                // signature only mentions it
                let defines = f.head.as_deref().is_some_and(|h| h.starts_with("define"));
                f.name.clone().filter(|_| defines).map(|n| (path.clone(), n, f.line)).into_iter().chain(made)
            })
        })
        .collect();
    let pick = |test: &dyn Fn(&str) -> bool| -> Vec<Value> {
        all.iter()
            .filter(|(_, n, _)| test(n))
            .filter_map(|(path, n, line)| {
                let mut t = target(files, path, *line, "definition")?;
                t["name"] = json!(n);
                Some(t)
            })
            .collect()
    };
    let exact = pick(&|n| n == name);
    if !exact.is_empty() {
        return exact;
    }
    let loose = pick(&|n| normalize(n) == want);
    if !loose.is_empty() {
        return loose;
    }
    pick(&|n| normalize(n).contains(&want))
}

/// Every place `name` is written, as an atom, in any file.
fn usages(files: &Files, name: &str) -> Vec<Value> {
    let mut out = Vec::new();
    for (path, text) in files {
        for (start, end) in sexp::atoms(text) {
            if &text[start..end] == name {
                let line = sexp::line_of(text, start);
                if let Some(mut t) = target(files, path, line, "use") {
                    t["name"] = json!(name);
                    out.push(t);
                }
            }
        }
    }
    out
}

/// Lines containing `query`, ignoring case.
fn search(files: &Files, query: &str) -> Vec<Value> {
    let want = query.to_lowercase();
    if want.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    for (path, text) in files {
        for (index, line) in text.lines().enumerate() {
            if line.to_lowercase().contains(&want) {
                out.extend(target(files, path, index + 1, "match"));
            }
        }
    }
    out
}

/// One target a line: the first (a definition before a use) wins.
fn dedupe(targets: &mut Vec<Value>) {
    let mut seen = std::collections::HashSet::new();
    targets.retain(|t| seen.insert((t["file"].as_str().unwrap_or("").to_owned(), t["line"].as_u64().unwrap_or(0))));
}

/// The first and last lines (1-based, of `after`) that differ from `before`.
fn changed_lines(before: &str, after: &str) -> (usize, usize) {
    let old: Vec<&str> = before.lines().collect();
    let new: Vec<&str> = after.lines().collect();
    let prefix = old.iter().zip(&new).take_while(|(a, b)| a == b).count();
    let suffix = old.iter().rev().zip(new.iter().rev()).take_while(|(a, b)| a == b).count().min(new.len().saturating_sub(prefix)).min(old.len().saturating_sub(prefix));
    let from = (prefix + 1).min(new.len().max(1));
    let to = new.len().saturating_sub(suffix).max(from);
    (from, to)
}

/// What a step was asked, worth showing beside it: the expression run,
/// the question researched.
fn step_input(name: &str, input: &Value) -> Option<String> {
    let text = match name {
        "evaluate" | "trace" => input["expr"].as_str()?.to_owned(),
        "research" => input["question"].as_str()?.to_owned(),
        "search_docs" => input["query"].as_str()?.to_owned(),
        "add_property" => input["statement"].as_str()?.to_owned(),
        "edit" | "write_file" => input["note"].as_str().filter(|n| !n.is_empty())?.to_owned(),
        _ => return None,
    };
    Some(toolchain::clip(&text, 300))
}

/// Whether a step went well, and a line saying how.
fn step_outcome(name: &str, text: &str, error: bool) -> (bool, String) {
    let first = |text: &str| {
        // the CLI wraps its own errors in <tool_use_error> tags
        let text = text.replace("<tool_use_error>", "").replace("</tool_use_error>", "");
        toolchain::clip(text.lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim(), 200)
    };
    if error {
        return (false, first(text));
    }
    let value: Value = serde_json::from_str(text).unwrap_or(Value::Null);
    match name {
        "edit" | "write_file" | "add_property" => {
            let check = value["check"].as_str().unwrap_or("");
            let failing = check.starts_with("FAILS");
            let mut line = if failing { first(check.trim_start_matches("FAILS the check -- fix it next:")) } else { check.to_owned() };
            if let Some(properties) = value["properties"].as_str() {
                line = format!("{line}{}{}", if line.is_empty() { "" } else { " · " }, first(properties));
            }
            (!failing, if line.is_empty() { "applied".to_owned() } else { line })
        }
        "check" => {
            let ok = value["ok"].as_bool().unwrap_or(false) || value["passes"].as_bool().unwrap_or(false);
            (ok, if ok { "passes".to_owned() } else { first(value["diagnostics"].as_str().unwrap_or("fails")) })
        }
        "run_properties" => {
            let properties = value["properties"].as_str().unwrap_or("");
            let bad = properties.contains("[fail]") || properties.contains("[crashed]") || properties.starts_with("properties did not run");
            (!bad, first(properties))
        }
        "evaluate" | "evaluate_program" | "trace" => {
            let shown = ["result", "output", "stdout", "value", "error", "errors"].iter().find_map(|k| value[*k].as_str().filter(|s| !s.is_empty()).map(str::to_owned));
            let failed = value["error"].as_str().is_some_and(|e| !e.is_empty()) || value["ok"] == false;
            (!failed, first(&shown.unwrap_or_else(|| text.to_owned())))
        }
        "research" => (true, toolchain::clip(value["answer"].as_str().unwrap_or(text).trim(), 400)),
        "get_file" | "list_files" | "search_docs" | "read_doc" | "type_at" | "facts_at" | "holes" | "assists_at" | "lint" => (true, String::new()),
        _ => (true, first(text)),
    }
}

fn describe_tool(name: &str, what: &str) -> String {
    let what = if what.is_empty() { String::new() } else { format!(" {what}") };
    match name {
        "edit" | "write_file" => format!("editing{what}"),
        "get_file" | "list_files" => format!("reading{what}"),
        "check" => "checking the program".to_owned(),
        "add_property" => format!("adding property{what}"),
        "run_properties" => "running the properties".to_owned(),
        "evaluate" | "evaluate_program" | "trace" => "running code".to_owned(),
        "research" => "researching".to_owned(),
        "search_docs" | "read_doc" => "reading Puffin's docs".to_owned(),
        "say" => "speaking".to_owned(),
        "ask" => "asking you".to_owned(),
        "arrange" => "arranging the board".to_owned(),
        other => other.replace('_', " "),
    }
}

fn router_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["navigate", "build", "control", "arrange", "answer", "explain", "reply"],
        "properties": {
            "navigate": {
                "type": "object",
                "additionalProperties": false,
                "required": ["kind", "name", "file", "line", "query"],
                "properties": {
                    "kind": { "type": "string", "enum": ["none", "definition", "usages", "line", "file", "text", "next", "previous", "back"] },
                    "name": { "type": "string" },
                    "file": { "type": "string" },
                    "line": { "type": "integer" },
                    "query": { "type": "string" },
                },
            },
            "build": {
                "type": "object",
                "additionalProperties": false,
                "required": ["instruction", "urgency"],
                "properties": {
                    "instruction": { "type": "string" },
                    "urgency": { "type": "string", "enum": ["none", "interrupt", "queue"] },
                },
            },
            "control": { "type": "string", "enum": ["none", "stop", "undo", "run-properties", "new-conversation", "mute", "unmute", "sleep", "follow", "unfollow", "run", "show-output", "hide-output"] },
            "arrange": {
                "type": "object",
                "additionalProperties": false,
                "required": ["action", "names", "modules", "near", "side", "text"],
                "properties": {
                    "action": { "type": "string", "enum": ["none", "show-board", "show-editor", "plan-mode", "build-mode", "open", "close", "hide", "unhide", "only", "slice", "clear", "bring", "put-away", "place", "note", "decide"] },
                    "text": { "type": "string" },
                    "names": { "type": "array", "items": { "type": "string" } },
                    "modules": { "type": "array", "items": { "type": "string" } },
                    "near": { "type": "string" },
                    "side": { "type": "string", "enum": ["right", "left", "below", "above"] },
                },
            },
            "answer": {
                "type": "object",
                "additionalProperties": false,
                "required": ["question", "text"],
                "properties": {
                    "question": { "type": "integer" },
                    "text": { "type": "string" },
                },
            },
            "explain": {
                "type": "object",
                "additionalProperties": false,
                "required": ["action", "question", "file", "from", "to", "label", "fresh"],
                "properties": {
                    "action": { "type": "string", "enum": ["none", "ask", "close"] },
                    "question": { "type": "string" },
                    "file": { "type": "string" },
                    "from": { "type": "integer" },
                    "to": { "type": "integer" },
                    "label": { "type": "string" },
                    "fresh": { "type": "boolean" },
                },
            },
            "reply": { "type": "string" },
        },
    })
}

/// The router's job (a fixed system prompt, so its cache holds).
const ROUTER: &str = "\
You are the ears of Puffin Studio's voice mode. A programmer is building a program in Puffin (a gradually \
typed Scheme) by talking, hands off the keyboard. Their speech arrives as a recognizer's transcript: expect \
mis-heard words, missing punctuation, homophones (\"line for tea\" = line 40, \"eval step\" = eval-step, \
\"see esk\" = CESK). Each time they finish a phrase you decide, in one structured answer, what it is for. A \
separate builder agent writes the code; you never write code.

navigate -- move their view, instantly. kind:
- definition: show where `name` is defined -- a definition, or a type's constructor (listed in brackets \
after its type). Use the exact identifier from the file list. Spoken names arrive mangled (\"v-rex\", \"v \
wreck\" = VRec; \"eval expert\" = eval-expr; \"if you rack\" may be VRec too): pick the identifier in the \
list that sounds closest, and never answer that it cannot be found while a name in the list sounds like it.
- usages: show the definition of `name` and every place it is used (\"where is foo used\", \"who calls \
this\").
- line: `line` in `file` (empty file = the shown one). Also for a part INSIDE a definition -- a clause, a \
case, a branch (\"the fix clause\", \"where it extends the environment\", \"the if case of eval\"): find it in \
the numbered shown file (or by its definition's line) and give its first line. Never answer with the \
enclosing definition when they named a part of it.
- file: open `file`.
- text: lines containing `query`.
- next / previous: step through the places last shown. back: return to where they were.
Resolve \"this\", \"this function\", \"here\" from the mouse (hover) first, then the cursor. Leave kind \
\"none\" when they are not asking to look somewhere. Navigation and building can both happen: \"go to \
eval-step and make it handle let\" navigates AND builds.

build -- an instruction for the builder. A request to make, add, change, plan or design anything -- a \
program, a module, a definition, properties -- IS a build instruction, even when it also switches mode: \
\"start in plan mode and lay out the modules\" is arrange plan-mode AND build (interrupt) in one answer. A \
long description ending in \"go\" / \"please\" / \"thanks\" is a build. Rewrite their words as a complete, self-contained instruction: \
resolve every \"this\"/\"that\"/\"here\" to the actual name, file and line, keep every requirement they \
stated, and keep it short. Properties they state (\"it should always...\", \"make sure that...\", \"a \
property: ...\") become an instruction to add that property. urgency:
- interrupt: it changes, corrects or cancels what the builder is doing now, or the builder is idle \
(\"no, use a hash instead\", \"actually call it step\").
- queue: it is more work that can wait for the current work to finish (\"also add a pretty printer\").
- none: there is nothing to build.

control: stop (stop the builder now), undo (revert the builder's last edit), run-properties, \
new-conversation (forget the builder's context), mute/unmute (the studio's voice), sleep (stop \
listening), follow/unfollow (whether the view follows the builder's edits), run (run the program), \
show-output / hide-output (the program's output and REPL), or none.

arrange -- the module board (the program as cards of ML-style signatures, bodies hidden until opened), \
instantly, no builder. action: show-board / show-editor (\"show me the board\", \"back to the code\"); \
plan-mode / build-mode (plan mode: the builder writes signatures and leaves bodies as holes); open / close \
(a definition's body: \"open step\", \"fold alloc\"); hide / unhide (rows: \"hide the store helpers\" -- \
name each definition); only (\"just show step and inject\"); slice (\"show me what step depends on\", \
\"what touches alloc\"); clear (\"show everything\"); bring / put-away (whole modules' cards); place \
(module cards `modules` next to `near`, on `side`); note / decide (the author's comment, or binding \
decision, on definitions `names` or whole `modules`, worded in `text` as they said it but self-contained: \
\"decide on alloc: it hands out the next unused integer\", \"a note on the store module: this will \
need garbage collection later\" -- a decision constrains the design, nothing is built now). `names` are \
exact definition names from the file list, `modules` file names; `text` is empty for every other \
action. Leave action \"none\" otherwise. Arranging and building can both happen.

explain -- an excursion: the author wants to UNDERSTAND code, not change it (\"explain the fix clause\", \
\"how does apply-fn work\", \"why is the environment a hash\", \"walk me through eval\"). action ask: \
`question` is their question, self-contained (resolve this/that/here to names); `file`, `from`, `to` the \
lines it is about, found in the numbered shown file or the definitions list (from 0 when it is about the \
open excursion as a whole, or the program at large; one line that opens a clause or definition is widened \
to the whole of it); `label` a few words naming those lines (\"the fix clause\", \"apply-fn\"). fresh: true \
when it starts a new topic, false when it follows up the open excursion (\"and what does extend do\", \"why \
there\", \"go on\", \"what calls it\") -- a follow-up about other code pulls that code into the same \
excursion. close: \"close the excursion\", \"done explaining\", \"back to building\". A question about how \
code works is an excursion, never a build, and an excursion edits nothing. \"Show me X and explain it\" \
navigates AND explains. Leave action \"none\" otherwise (question and label empty, from/to 0, fresh false).

answer -- when the builder has an open question (listed above) and these words answer it, `question` is its \
number and `text` the answer in full, self-contained (resolve \"yes\"/\"the second one\" against the \
question). Otherwise question 0, text empty. An answer is not also a build instruction.

reply: what the studio says back, aloud, in a few words -- or empty. Acknowledge build instructions \
briefly (\"On it.\", \"Switching to a hash.\"); stay silent for pure navigation (the view moving is the \
answer) and for an excursion (its panel answers); answer a question about the program or the builder's \
state from what you see here, in one sentence. NEVER say work is happening, will happen or is done unless \
it is: \"On it\", \"Got it\", \"Planning...\", \"Building...\" only with a build instruction in this same \
answer. Asked about progress (\"are we making progress?\", \"what are you doing?\"), answer from the \
builder's state above, truthfully: when it is idle say so plainly (\"Nothing is building right now -- tell \
me what to build.\"). If the words are clearly not meant for the studio (talking to someone else, filler, a \
half-sentence), do nothing: all none, reply empty.";

/// Added to a builder run's prompt while the board is in plan mode.
const PLAN_MODE: &str = "\n\
PLAN MODE is on. Build the program's design, not its code: modules (require/provide), data definitions \
(define-type, define-type-alias, define-grammar), and for every function a typed signature `(: f (-> A B))` \
with its body a single typed hole: `(define (f x) ??)`. The check checks everything around the holes, and \
properties that reach a hole show as open, not failing. Write a body only when the author says to dive in, \
implement or fill in a definition -- then that one alone. Keep each module's provide list current. When a \
design decision matters and you cannot settle it from what the author said, `ask` (one question, about \
the definitions it concerns) rather than guessing.\n";

/// The builder's role (a fixed system prompt, after the Puffin reference).
const BUILDER: &str = "\
You are the builder in Puffin Studio's voice mode. The author is talking, hands off the keyboard, and \
watching the editor; you write the program they describe, in Puffin, as they talk. Their words reach you \
as instructions rewritten from a speech transcript (each may say where the mouse was).

How this differs from ordinary coding:
- Your edits apply AT ONCE (the `edit` and `write_file` tools); there is no review step, and the author \
sees each one land. Make progress visible: work in small, frequent edits rather than one huge one. \
Scaffold first -- the modules, the data definitions, the function signatures, with typed holes `??` for \
bodies you have not written yet -- then fill the holes in. A program whose only failures are holes \
passes the check: everything around the holes is checked.
- Keep the program passing the check. Each edit's answer says whether it does; fix a failure before \
going on.
- The author may interrupt at any moment; you are then resumed with their new words, and what you \
applied stays. Drop work that the new words make moot; do not argue for the old plan.
- Narrate as you go, in text: before each step or small group of steps, one short line saying what you \
are about to do and why (\"Next: the step function, one clause per transition rule.\", \"The check \
failed on an unbound name; adding the require.\"). These lines are the author's trace of your \
reasoning, shown beside the code; keep each to one sentence.
- Use `say` sparingly: one short sentence when you start something substantial, when you finish, or \
when you need a decision. Never put code in it.
- Your text replies appear in a side panel; keep them to a line or two.

Specifications are properties. The author states what the program must do as properties, in English \
or as tests; you write each down with `add_property` (in properties.puf, with the English statement \
kept beside it) and make the program satisfy them. Run them (`run_properties`) after a change that could \
affect them. Never weaken or delete a property to make it pass unless the author says so; if one seems \
wrong, say so with `say`. When you build something substantial, propose a property or two of your own \
in your reply, but add them only if asked. Properties run in the program's own modules: a module must \
`provide` what properties.puf uses, and properties.puf must `require` it (add_property's `requires`).

Questions. When a design decision matters and you cannot settle it from the author's words or the \
source -- an interface, a representation, what a function must guarantee -- call `ask` with the question \
and the definitions it is about. The author sees exactly those on the board and answers aloud; the \
answer comes back as an instruction, and you write it down: as a property when it says what must hold, \
in the types and signatures when it says how things are built. Answers are how the spec grows.

The board. The author may be looking at the module board instead of the editor: module cards of \
signatures, bodies folded. Write a one-line comment above each definition saying what it is for -- the \
board shows it under the signature. Use `arrange` to put what you are talking about in front of them.

Sources. When the author points at a paper, a spec or a page (\"the CESK* machine from Van Horn and \
Might\"), use `research` once to get its exact content -- the grammar, the states, the transition rules \
-- and write that content into the code as a comment at the top of the module it shapes, so the code \
and the source can be compared. Then build from it faithfully, rule by rule, naming functions after the \
source's notation where you can.

Puffin. Write only what the reference and the docs show; search_docs and read_doc for anything else \
(docs/GRAMMARS.md for define-grammar, the s-expression grammar types this branch has; docs/MODULES.md \
for modules). Split a program of any size into modules (require/provide), one concern each: e.g. \
syntax.puf, machine.puf, main.puf. Use `evaluate` and `evaluate_program` to check behaviour, not just \
types. `string-append` takes exactly two arguments; there is no exception handling.";

#[cfg(test)]
mod tests {
    use super::*;

    fn files(pairs: &[(&str, &str)]) -> Files {
        pairs.iter().map(|(a, b)| (a.to_string(), b.to_string())).collect()
    }

    /// Structured output wants every object closed and every property
    /// required; a schema the API refuses would fail every utterance.
    #[test]
    fn the_router_schema_is_strict_all_the_way_down() {
        fn walk(v: &Value, path: &str) {
            match v["type"].as_str() {
                Some("object") => {
                    assert_eq!(v["additionalProperties"], json!(false), "{path}: additionalProperties");
                    let props: std::collections::BTreeSet<String> = v["properties"].as_object().unwrap_or_else(|| panic!("{path}: properties")).keys().cloned().collect();
                    let required: std::collections::BTreeSet<String> = v["required"].as_array().unwrap_or_else(|| panic!("{path}: required")).iter().map(|r| r.as_str().unwrap().to_owned()).collect();
                    assert_eq!(props, required, "{path}: every property required");
                    for (k, sub) in v["properties"].as_object().unwrap() {
                        walk(sub, &format!("{path}.{k}"));
                    }
                }
                Some("array") => walk(&v["items"], &format!("{path}[]")),
                Some("string" | "integer" | "boolean" | "number") => {
                    if let Some(e) = v["enum"].as_array() {
                        assert!(!e.is_empty() && e.iter().all(Value::is_string), "{path}: enum");
                    }
                }
                other => panic!("{path}: type {other:?}"),
            }
        }
        let schema = router_schema();
        walk(&schema, "router");
        // the actions the executor knows are the ones the router may pick
        let actions: Vec<&str> = schema["properties"]["arrange"]["properties"]["action"]["enum"].as_array().unwrap().iter().map(|a| a.as_str().unwrap()).collect();
        for action in ["note", "decide", "slice", "only", "plan-mode", "build-mode"] {
            assert!(actions.contains(&action), "{action}");
        }
    }

    #[test]
    fn constructors_are_definitions_too() {
        let values = ";; values.puf -- run-time values and environments.\n(require \"syntax.puf\")\n(provide Value VNum VBool VClo VRec Env)\n\n;; What an expression evaluates to.\n(define-type Value\n  (VNum Int)                       ;; an integer\n  (VBool Bool)                     ;; a boolean\n  (VClo Sym Expr Env)              ;; closure: parameter, body, defining env\n  (VRec Sym Sym Expr Env))         ;; recursive closure: self name, parameter, body, env\n";
        let files = files(&[("values.puf", values)]);
        let found = definitions(&files, "VRec");
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0]["line"], json!(10));
        assert_eq!(definitions(&files, "v rec")[0]["line"], json!(10));
        assert_eq!(definitions(&files, "Value")[0]["line"], json!(6));
    }

    #[test]
    fn a_routing_that_does_nothing_is_inert() {
        let nothing = json!({
            "navigate": { "kind": "none", "name": "", "file": "", "line": 0, "query": "" },
            "build": { "instruction": "", "urgency": "none" },
            "control": "none",
            "arrange": { "action": "none" },
            "answer": { "question": 0, "text": "" },
            "explain": { "action": "none", "question": "", "file": "", "from": 0, "to": 0, "label": "", "fresh": false },
            "reply": ""
        });
        assert!(inert(&nothing));
        let mut building = nothing.clone();
        building["build"] = json!({ "instruction": "Build an STLC checker", "urgency": "interrupt" });
        assert!(!inert(&building));
        let mut replying = nothing.clone();
        replying["reply"] = json!("I'm here.");
        assert!(!inert(&replying));
        let mut asking = nothing.clone();
        asking["explain"]["action"] = json!("ask");
        assert!(!inert(&asking));
        let mut looking = nothing;
        looking["navigate"]["kind"] = json!("definition");
        assert!(!inert(&looking));
    }

    #[test]
    fn changed_lines_finds_the_edit() {
        assert_eq!(changed_lines("a\nb\nc\n", "a\nB\nc\n"), (2, 2));
        assert_eq!(changed_lines("a\nc\n", "a\nb1\nb2\nc\n"), (2, 3));
        assert_eq!(changed_lines("", "x\ny\n"), (1, 2));
        assert_eq!(changed_lines("a\nb\n", "a\n"), (1, 1));
    }

    #[test]
    fn definitions_match_spoken_names() {
        let f = files(&[("m.puf", "(define (eval-step s) s)\n(define (inject e) (eval-step e))\n")]);
        assert_eq!(definitions(&f, "eval-step")[0]["line"], 1);
        assert_eq!(definitions(&f, "eval step")[0]["name"], "eval-step");
        assert_eq!(definitions(&f, "inject")[0]["line"], 2);
        assert!(definitions(&f, "nothing").is_empty());
    }

    #[test]
    fn usages_skip_comments_and_strings() {
        let f = files(&[("m.puf", ";; step here\n(define (step s) s)\n(display \"step\")\n(step 1)\n")]);
        let lines: Vec<u64> = usages(&f, "step").iter().map(|t| t["line"].as_u64().unwrap()).collect();
        assert_eq!(lines, vec![2, 4]);
    }

    #[test]
    fn properties_are_declared_with_their_english() {
        let text = "(require \"prop.puf\")\n;; @property rev: reversing twice is identity\n(check-property 'rev (for-all (list (gen-list gen-int)) (lambda (xs) #t)))\n(check-example 'one (equal? 1 1))\n";
        let declared = props::declared(text);
        assert_eq!(declared.len(), 2);
        assert_eq!(declared[0].name, "rev");
        assert_eq!(declared[0].statement, "reversing twice is identity");
        assert_eq!(declared[1].name, "one");
    }
}
