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
//!
//! This file is voice mode's state, its events, and the router; the
//! builder is voice/builder.rs, the places navigation finds are
//! voice/places.rs, and excursions are excursion.rs.

pub mod builder;
mod places;

use crate::claude_api::{self, Api};
use crate::props::Results;
use crate::sexp;
use crate::studio::{Event, Studio};
use crate::toolchain;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::fmt::Write as _;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::process::Child;

/// How many voice events a tab that opens later is shown.
const LOG: usize = 1000;
/// How many lines of conversation the router and builder see.
const CONVERSATION: usize = 12;
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
        crate::claude_cli::unavailable()
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

}

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

#[cfg(test)]
mod tests {
    use super::*;

    /// A schema the API refuses would fail every utterance.
    #[test]
    fn the_router_schema_is_strict_all_the_way_down() {
        let schema = router_schema();
        claude_api::assert_strict(&schema, "router");
        // the actions the executor knows are the ones the router may pick
        let actions: Vec<&str> = schema["properties"]["arrange"]["properties"]["action"]["enum"].as_array().unwrap().iter().map(|a| a.as_str().unwrap()).collect();
        for action in ["note", "decide", "slice", "only", "plan-mode", "build-mode"] {
            assert!(actions.contains(&action), "{action}");
        }
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

}
