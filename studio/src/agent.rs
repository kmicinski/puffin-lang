//! The assistant: headless `claude -p` runs whose only tools are this
//! server's own `/mcp` endpoint (mcp.rs), as in Slog Studio's agent.rs. It
//! is just another MCP client: everything it writes is a proposal the
//! author accepts or rejects (review.rs), and it never mutates the author's
//! session (`evaluate` runs with `try`).
//!
//! Each question is a thread: its own claude session (resumed for
//! follow-ups) and transcript, and one changeset per turn. The MCP config a
//! run gets carries a header naming its thread, so the server attributes
//! its proposals. Progress streams to every tab as `Event::Agent`. How a
//! run is started and read is claude_cli.rs; this is what the assistant's
//! runs are told, and how their stream becomes a transcript.

use crate::claude_cli::{McpConfig, Part, Run, parts, tool_name};
use crate::knowledge;
use crate::review::Message;
use crate::studio::Studio;
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tokio::process::Child;

/// The header a run's MCP config carries: its thread id.
pub const THREAD_HEADER: &str = "x-studio-thread";

/// How the assistant works: the role in its system prompt
/// (knowledge::system_prompt).
const PERSONA: &str = "\
You are the assistant at the REPL prompt of Puffin Studio, a workbench for the Puffin language \
(a gradually typed, immutable-by-default Scheme with algebraic data types and pattern matching; \
the reference above is your knowledge of it). The author is writing a program and asked you \
something at the prompt; your reply appears inline in the REPL transcript, between their \
evaluations. The `puffin` MCP tools are your only way to read or change the program.

Knowing Puffin -- never guess:
- Write only syntax and primitives the reference shows. For anything it does not cover, \
search_docs (e.g. `hash-ref/default`, `define-type`, `require #:as`) and read_doc the passage \
(docs/STDLIB.md lists every primitive; docs/TYPES.md the type system; docs/MODULES.md modules).
- `string-append` takes exactly two arguments; there is no exception handling; pairs are \
immutable (no set-car!).

How to work -- the author is waiting:
- The message opens with the session: the scope, the code in it, diagnostics, and recent REPL \
entries. get_file reads a file as your pending proposals leave it; list_files names them.
- Deterministic edits beat generated ones: when the compiler can write the code (match \
clauses from a type, missing cases, stubs), call assists_at to see what applies at a point and \
apply_assist to propose it, rather than writing it yourself. type_at says the type at a point; \
facts_at says everything known there, layer by layer.
- Observations are evidence from real runs: when the author's session observes, each function \
records the shapes of the arguments it was called with (e.g. `(list add 3)`, `(adt Num)`, \
`Int`), and facts_at reports them, with match patterns made from them. They are sampled (at \
most 16 shapes a parameter) and say only what was seen so far, never what cannot occur; prefer \
the checker's types where there are any. Assists with source `observed` are built from them \
(cases a match has seen; `annotate` inserts (: f τ) from observed argument types). Say so when \
your answer rests on them. The lint tool lists the matches the session saw take a shape no \
clause handles; the add-missing-cases assist with source observed, at the match, adds them.
- Typed holes: `??` marks a missing expression, and the holes tool lists each with its goal \
type. The check checks the whole program around its holes, so a program whose only \
shortfall is holes passes the proposal check. You may leave a \
`??` in a proposal when the right expression is genuinely the author's call (a design \
decision, a value only they know); say so in the note. When asked to fill holes, prefer the \
compiler's candidates: assists_at on the hole lists fill-hole edits (a local of the goal \
type, the recursive call, a constructor with new holes); apply_assist one by its title, then \
check, and write an expression yourself only when no candidate fits.
- Change code only with propose_edit: `old` is an exact piece of the file's current text, \
occurring once (include enough context), `new` its replacement; give a one-sentence `note`. \
An empty `old` appends to the file (or makes a new file), when the scope allows it. Every \
proposal is checked as the program it would leave, and must stay inside the question's \
scope: one that fails is refused with the reason. Fix it and propose again; propose_edit on \
text your pending proposal wrote corrects that proposal. Nothing changes until the author \
accepts.
- Check behaviour, not just types: evaluate runs an expression against the author's live \
session (definitions they evaluated are there) and keeps nothing; evaluate_program compiles \
and runs a whole file of the program as your proposals leave it, on a throwaway VM. Cite \
what you saw.
- Trace before you fix a recursive function: trace runs an expression with the functions you \
name traced -- each call `> (f args)` and its return `< value`, nested by depth -- against the \
author's session, and keeps nothing. It shows what an interpreter or a recursive pass actually \
does on an input: which case each call took, which call returned the wrong value, where a \
recursion ran away. Trace a small failing input before proposing a fix, cite the lines that \
show the bug, and trace again after proposing (your pending proposals apply) to confirm it. \
Keep inputs small: the trace is cut at 200 lines. The author traces with `,trace f` (it makes \
f's calls print in their transcript); suggest it in a ```repl block when it would help them see.
- Answer briefly: a sentence or two, then any code. No preamble, no headings. Put \
expressions you suggest the author run in a ```repl block, one per line (a form may span \
lines); each becomes a chip that runs it at the prompt. Show other Puffin in ```puffin \
blocks. Do not repeat a proposed change as a code block: the author sees it in the editor.";

/// The steps a turn may take.
const MAX_TURNS: u32 = 24;
/// Claude Code's own plumbing, never shown.
const HIDDEN_TOOLS: [&str; 1] = ["ToolSearch"];
/// How much of a tool's input string or result a transcript keeps.
const CLIP: usize = 4000;
/// How much of a `trace` result's trace a transcript keeps, for its tree.
const TRACE_KEPT: usize = 64_000;

pub struct Agent {
    /// The bearer token `/mcp` requires; it never leaves this machine except
    /// in the 0600 config file a run reads (claude_cli::McpConfig).
    pub mcp_token: String,
    model: Option<String>,
    effort: String,
    /// The claude process of every run in flight, by thread.
    running: Mutex<HashMap<u32, Child>>,
    /// Threads whose run the author stopped, so its end is no failure.
    stopped: Mutex<HashSet<u32>>,
}

#[derive(Clone, Debug, Serialize)]
pub struct AgentEvent {
    pub thread: u32,
    /// "start"; "phase" ("thinking", "replying" or "tool NAME"); "delta"
    /// (streamed text of the reply); "entry" (transcript entry `index`, new
    /// or changed); or "done".
    pub kind: &'static str,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub index: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entry: Option<Message>,
}

impl Agent {
    pub fn new(mcp_token: String) -> Self {
        Self {
            mcp_token,
            // the CLI's own default model unless the operator picks one
            model: std::env::var("PUFFIN_STUDIO_MODEL").ok().filter(|model| !model.is_empty()),
            effort: crate::setting("PUFFIN_STUDIO_EFFORT", "medium"),
            running: Mutex::new(HashMap::new()),
            stopped: Mutex::new(HashSet::new()),
        }
    }

    pub fn is_running(&self, thread: u32) -> bool {
        self.running.lock().expect("agent lock").contains_key(&thread)
    }

    pub fn stop(&self, thread: u32) -> bool {
        let killed = self.running.lock().expect("agent lock").get_mut(&thread).is_some_and(|child| child.start_kill().is_ok());
        if killed {
            self.stopped.lock().expect("agent lock").insert(thread);
        }
        killed
    }
}

/// The first line of a request, cut to a title's length.
pub fn title_of(message: &str) -> String {
    let line = message.lines().find(|line| !line.trim().is_empty()).unwrap_or("").trim();
    let title: String = line.chars().take(72).collect();
    if title.len() < line.len() { format!("{}…", title.trim_end()) } else { title }
}

/// One thread's transcript as a run writes it: each change is kept by the
/// studio and streamed to every tab.
struct Transcript<'a> {
    studio: &'a Studio,
    thread: u32,
}

impl Transcript<'_> {
    fn event(&self, kind: &'static str, text: impl Into<String>) {
        self.studio.agent_event(AgentEvent { thread: self.thread, kind, text: text.into(), index: None, entry: None });
    }

    fn show(&self, index: usize, entry: Message) {
        self.studio.agent_event(AgentEvent { thread: self.thread, kind: "entry", text: String::new(), index: Some(index), entry: Some(entry) });
    }

    fn push(&self, role: &str, text: &str, data: Value) -> usize {
        let entry = Message::new(role, text, data);
        let index = {
            let mut review = self.studio.review.lock().expect("review lock");
            let Some(thread) = review.thread_mut(self.thread) else { return 0 };
            thread.messages.push(entry.clone());
            thread.messages.len() - 1
        };
        self.show(index, entry);
        index
    }

    fn update(&self, index: usize, change: impl FnOnce(&mut Message)) {
        let changed = {
            let mut review = self.studio.review.lock().expect("review lock");
            review.thread_mut(self.thread).and_then(|thread| thread.messages.get_mut(index)).map(|message| {
                change(message);
                message.clone()
            })
        };
        if let Some(entry) = changed {
            self.show(index, entry);
        }
    }

    fn session(&self) -> Option<String> {
        self.studio.review.lock().expect("review lock").thread(self.thread).and_then(|thread| thread.session.clone())
    }

    fn set_session(&self, session: Option<String>) {
        if let Some(thread) = self.studio.review.lock().expect("review lock").thread_mut(self.thread) {
            thread.session = session;
        }
    }
}

/// One turn of `thread`: run claude until it finishes, streaming its
/// progress. `context` leads the message, not the system prompt.
pub async fn run(studio: Arc<Studio>, thread: u32, message: String, context: String) {
    let transcript = Transcript { studio: &studio, thread };
    if let Err(error) = turn(&studio, &transcript, &format!("{context}\n{message}")).await {
        transcript.push("error", &error, Value::Null);
    }
    finish(&studio, thread);
    transcript.event("done", "");
}

/// Run the turn's claude, resuming the thread's session; once more afresh
/// when that session cannot be resumed. Err: what went wrong.
async fn turn(studio: &Studio, transcript: &Transcript<'_>, prompt: &str) -> Result<(), String> {
    let agent = &studio.agent;
    let thread = transcript.thread;
    let config = McpConfig::write(
        &format!("puffin-studio-mcp-{}-{thread}.json", std::process::id()),
        studio.port(),
        &agent.mcp_token,
        json!({ "X-Studio-Thread": thread.to_string() }),
    )?;
    let system = knowledge::system_prompt(&studio.root, PERSONA);
    let mut resume = transcript.session();
    loop {
        let run = Run {
            prompt,
            system: &system,
            config: &config.path,
            model: agent.model.as_deref(),
            effort: &agent.effort,
            max_turns: MAX_TURNS,
            resume: resume.as_deref(),
            eager_tools: false,
        };
        transcript.event("start", "");
        let mut stream = Stream { effort: agent.effort.clone(), ..Stream::default() };
        let ended = run
            .stream(
                &studio.directory,
                |child| {
                    agent.running.lock().expect("agent lock").insert(thread, child);
                },
                || agent.running.lock().expect("agent lock").remove(&thread),
                |event| stream.read(event, transcript),
            )
            .await?;
        if agent.stopped.lock().expect("agent lock").remove(&thread) {
            transcript.push("notice", "stopped", Value::Null);
            return Ok(());
        }
        if stream.got_result || ended.success {
            return Ok(());
        }
        if resume.is_some() {
            // a stale session id (its transcript gone) is the usual cause
            transcript.set_session(None);
            resume = None;
            transcript.push("notice", "could not resume the conversation; starting a new one", Value::Null);
            continue;
        }
        return Err(format!("claude exited without a result{}", ended.last_words().map(|line| format!(": {line}")).unwrap_or_default()));
    }
}

/// The turn is over: the thread stops running, and the question with its
/// answer goes to the project's history (studio.rs `record`).
fn finish(studio: &Studio, thread: u32) {
    let record = {
        let mut review = studio.review.lock().expect("review lock");
        let Some(entry) = review.thread_mut(thread) else { return };
        entry.running = false;
        let last_user = entry.messages.iter().rposition(|m| m.role == "user");
        last_user.map(|index| {
            let turn = &entry.messages[index..];
            let text_of = |role: &str| turn.iter().filter(|m| m.role == role).map(|m| m.text.trim()).filter(|t| !t.is_empty()).collect::<Vec<_>>().join("\n\n");
            let stats = turn.iter().rev().find(|m| m.role == "turn").map(|m| m.data.clone()).unwrap_or(Value::Null);
            let tools = turn.iter().filter(|m| m.role == "tool").count();
            let mut data = json!({
                "line": turn[0].text,
                "thread": thread,
                "turn": entry.messages[..=index].iter().filter(|m| m.role == "user").count() - 1,
                "scope": turn[0].data["scope"],
                "status": if text_of("error").is_empty() { "ok" } else { "error" },
            });
            let object = data.as_object_mut().expect("an object");
            let answer = text_of("assistant");
            if !answer.is_empty() {
                object.insert("out".into(), json!(clip_text(&answer)));
            }
            let error = text_of("error");
            if !error.is_empty() {
                object.insert("error".into(), json!(error));
            }
            if let Some(ms) = stats["ms"].as_u64() {
                object.insert("ms".into(), json!(ms));
            }
            if !stats["cost"].is_null() {
                object.insert("cost".into(), stats["cost"].clone());
            }
            if tools > 0 {
                object.insert("tools".into(), json!(tools));
            }
            data
        })
    };
    if let Some(data) = record {
        studio.record("ask", data);
    }
    studio.publish_review();
}

/// What a turn's stream-json has shown so far, made into transcript entries.
#[derive(Default)]
struct Stream {
    effort: String,
    model: String,
    /// The thought being streamed: its block's index, when it began, its text.
    thinking: Option<(u64, Instant, String)>,
    /// Tool call id -> its transcript entry.
    calls: HashMap<String, usize>,
    last_text: String,
    got_result: bool,
}

impl Stream {
    fn read(&mut self, event: &Value, out: &Transcript) {
        for part in parts(event) {
            match part {
                Part::Session(session) => out.set_session(Some(session.to_owned())),
                Part::Init { model } => self.model = model.to_owned(),
                Part::Partial(event) => self.partial(event, out),
                Part::Text(text) => {
                    self.last_text = text.to_owned();
                    out.push("assistant", text, Value::Null);
                }
                Part::ToolUse { id, name, input } => self.call(id, name, input, out),
                Part::ToolResult { id, text, error } => self.answer(id, &text, error, out),
                Part::Result(event) => self.result(event, out),
            }
        }
    }

    fn partial(&mut self, event: &Value, out: &Transcript) {
        match event["type"].as_str() {
            Some("content_block_start") => {
                let block = &event["content_block"];
                match block["type"].as_str() {
                    Some("thinking" | "redacted_thinking") => {
                        self.thinking = Some((event["index"].as_u64().unwrap_or(0), Instant::now(), String::new()));
                        out.event("phase", "thinking");
                    }
                    Some("tool_use") => {
                        let name = tool_name(block);
                        if !HIDDEN_TOOLS.contains(&name) {
                            out.event("phase", format!("tool {name}"));
                        }
                    }
                    Some("text") => out.event("phase", "replying"),
                    _ => {}
                }
            }
            Some("content_block_delta") => {
                let delta = &event["delta"];
                match delta["type"].as_str() {
                    Some("text_delta") => out.event("delta", delta["text"].as_str().unwrap_or("")),
                    Some("thinking_delta") => {
                        if let Some((_, _, text)) = &mut self.thinking {
                            text.push_str(delta["thinking"].as_str().unwrap_or(""));
                        }
                    }
                    _ => {}
                }
            }
            Some("content_block_stop") => {
                let index = event["index"].as_u64().unwrap_or(0);
                if self.thinking.as_ref().is_some_and(|(open, ..)| *open == index) {
                    let (_, began, text) = self.thinking.take().expect("a thought is open");
                    out.push("thinking", text.trim(), json!({ "ms": began.elapsed().as_millis() as u64 }));
                }
            }
            _ => {}
        }
    }

    fn call(&mut self, id: &str, name: &str, input: &Value, out: &Transcript) {
        if HIDDEN_TOOLS.contains(&name) {
            return;
        }
        let data = json!({ "id": id, "name": name, "input": clip(input), "status": "running" });
        let index = out.push("tool", "", data);
        self.calls.insert(id.to_owned(), index);
    }

    fn answer(&mut self, id: &str, text: &str, error: bool, out: &Transcript) {
        if let Some(index) = self.calls.get(id) {
            out.update(*index, |entry| {
                entry.data["status"] = json!(if error { "error" } else { "ok" });
                // a proposal's id, for its chip
                let value = serde_json::from_str::<Value>(text).ok();
                if let Some(op) = value.as_ref().and_then(|value| value["proposed"].as_u64()) {
                    entry.data["op"] = json!(op);
                }
                // a trace, whole (it is bounded), for the tree its step shows
                if entry.data["name"] == "trace"
                    && let Some(trace) = value.as_ref().and_then(|value| value["trace"].as_str())
                {
                    entry.data["trace"] = json!(crate::toolchain::clip(trace, TRACE_KEPT));
                }
                entry.data["result"] = json!(clip_text(text));
            });
        }
    }

    fn result(&mut self, event: &Value, out: &Transcript) {
        self.got_result = true;
        let text = event["result"].as_str().unwrap_or("").trim();
        if event["is_error"].as_bool().unwrap_or(false) {
            let message = match (text, event["subtype"].as_str()) {
                ("", Some("error_max_turns")) => format!("stopped at the limit of {MAX_TURNS} steps; ask it to go on"),
                ("", subtype) => subtype.unwrap_or("error").to_owned(),
                (text, _) => text.to_owned(),
            };
            out.push("error", &message, Value::Null);
        } else if !text.is_empty() && text != self.last_text {
            out.push("assistant", text, Value::Null);
        }
        let usage = &event["usage"];
        let count = |key: &str| usage[key].as_u64().unwrap_or(0);
        out.push(
            "turn",
            "",
            json!({
                "ms": event["duration_ms"],
                "cost": event["total_cost_usd"],
                "input": count("input_tokens") + count("cache_read_input_tokens") + count("cache_creation_input_tokens"),
                "output": count("output_tokens"),
                "model": self.model,
                "effort": self.effort,
            }),
        );
    }
}

fn clip(value: &Value) -> Value {
    match value {
        Value::String(text) => json!(clip_text(text)),
        Value::Array(items) => Value::Array(items.iter().map(clip).collect()),
        Value::Object(fields) => Value::Object(fields.iter().map(|(key, value)| (key.clone(), clip(value))).collect()),
        other => other.clone(),
    }
}

fn clip_text(text: &str) -> String {
    match text.char_indices().nth(CLIP) {
        Some((end, _)) => format!("{}\n… ({} more characters)", &text[..end], text[end..].chars().count()),
        None => text.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn titles_are_first_lines_cut_short() {
        assert_eq!(title_of("\n  fix the match\nplease"), "fix the match");
        assert!(title_of(&"x".repeat(100)).ends_with('…'));
    }
}
