//! The assistant: headless `claude -p` runs whose only tools are this
//! server's own `/mcp` endpoint (mcp.rs), as in Slog Studio's agent.rs. It
//! is just another MCP client: everything it writes is a proposal the
//! author accepts or rejects (review.rs), and it never mutates the author's
//! session (`evaluate` runs with `try`).
//!
//! Each question is a thread: its own claude session (resumed for
//! follow-ups) and transcript, and one changeset per turn. The MCP config a
//! run gets carries a header naming its thread, so the server attributes
//! its proposals. Progress streams to every tab as `Event::Agent`.

use crate::knowledge;
use crate::review::Message;
use crate::studio::Studio;
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::process::{Child, Command};

/// The header a run's MCP config carries: its thread id.
pub const THREAD_HEADER: &str = "x-studio-thread";
/// The MCP server's name, which prefixes its tools: `mcp__puffin__get_file`.
pub const SERVER: &str = "puffin";

/// How the assistant works. With the reference it makes the system prompt,
/// which stays the same for every run so that runs share its prompt cache;
/// what differs per run goes in the message.
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
apply_assist to propose it, rather than writing it yourself. type_at says the type at a point.
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
- Answer briefly: a sentence or two, then any code. No preamble, no headings. Put \
expressions you suggest the author run in a ```repl block, one per line (a form may span \
lines); each becomes a chip that runs it at the prompt. Show other Puffin in ```puffin \
blocks. Do not repeat a proposed change as a code block: the author sees it in the editor.";

/// Refused even if a setting would allow them.
const DENIED: &str = "Bash,Write,Edit,NotebookEdit,Skill";
/// The steps a turn may take.
const MAX_TURNS: u32 = 24;
/// Claude Code's own plumbing, never shown.
const HIDDEN_TOOLS: [&str; 1] = ["ToolSearch"];
/// How much of a tool's input string or result a transcript keeps.
const CLIP: usize = 4000;

pub struct Agent {
    /// The bearer token `/mcp` requires; it never leaves this machine except
    /// in the 0600 config file a run reads.
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
            effort: std::env::var("PUFFIN_STUDIO_EFFORT").unwrap_or_else(|_| "medium".to_owned()),
            running: Mutex::new(HashMap::new()),
            stopped: Mutex::new(HashSet::new()),
        }
    }

    /// Why the assistant cannot run, if it cannot.
    pub fn unavailable() -> Option<String> {
        which("claude").is_none().then(|| "no `claude` on PATH: install Claude Code to ask the assistant".to_owned())
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

    /// The MCP config for one run (mode 0600): our loopback `/mcp`, the
    /// bearer token, and the header naming the thread.
    pub fn write_config(&self, port: u16, thread: u32) -> Result<PathBuf, String> {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let config = json!({ "mcpServers": { SERVER: {
            "type": "http",
            "url": format!("http://127.0.0.1:{port}/mcp"),
            "headers": {
                "Authorization": format!("Bearer {}", self.mcp_token),
                "X-Studio-Thread": thread.to_string(),
            },
        }}});
        let path = std::env::temp_dir().join(format!("puffin-studio-mcp-{}-{thread}.json", std::process::id()));
        std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&path)
            .and_then(|mut file| file.write_all(config.to_string().as_bytes()))
            .map_err(|error| format!("cannot write the MCP config: {error}"))?;
        Ok(path)
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

/// The arguments of one run.
pub fn arguments(prompt: &str, config: &str, system: &str, effort: &str, model: Option<&str>, resume: Option<&str>) -> Vec<String> {
    let mut args: Vec<String> = vec![
        "-p".into(), prompt.into(),
        "--output-format".into(), "stream-json".into(), "--verbose".into(),
        // partial events show "thinking…" and stream the reply as it comes
        "--include-partial-messages".into(),
        "--effort".into(), effort.into(),
        "--disable-slash-commands".into(),
        // only the operator's own settings: none of the repository's
        "--setting-sources".into(), "user".into(),
        "--mcp-config".into(), config.into(), "--strict-mcp-config".into(),
        // no built-in tools at all: the studio's are the only ones
        "--tools".into(), "".into(),
        "--allowedTools".into(), format!("mcp__{SERVER}"),
        "--disallowedTools".into(), DENIED.into(),
        "--max-turns".into(), MAX_TURNS.to_string(),
        "--append-system-prompt".into(), system.into(),
        // keep the machine's details out of the system prompt, for its cache
        "--exclude-dynamic-system-prompt-sections".into(),
    ];
    if let Some(model) = model {
        args.extend(["--model".to_owned(), model.to_owned()]);
    }
    if let Some(session) = resume {
        args.extend(["--resume".to_owned(), session.to_owned()]);
    }
    args
}

/// One turn of `thread`: run claude until it finishes, streaming its
/// progress. `context` leads the message, not the system prompt.
pub async fn run(studio: Arc<Studio>, thread: u32, message: String, context: String) {
    let transcript = Transcript { studio: &studio, thread };
    let agent = &studio.agent;
    let config = match agent.write_config(studio.port(), thread) {
        Ok(path) => path,
        Err(error) => {
            transcript.push("error", &error, Value::Null);
            finish(&studio, thread);
            transcript.event("done", "");
            return;
        }
    };
    let system = format!("# The Puffin reference\n\n{}\n\n# Your role\n\n{PERSONA}", knowledge::reference(&studio.root));
    let mut resume = transcript.session();
    loop {
        let args = arguments(
            &format!("{context}\n{message}"),
            &config.to_string_lossy(),
            &system,
            &agent.effort,
            agent.model.as_deref(),
            resume.as_deref(),
        );
        transcript.event("start", "");
        let mut child = match Command::new("claude")
            .args(&args)
            .current_dir(&studio.directory)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
        {
            Ok(child) => child,
            Err(error) => {
                transcript.push("error", &format!("could not start claude: {error}"), Value::Null);
                break;
            }
        };
        let stdout = child.stdout.take().expect("piped stdout");
        let mut stderr = child.stderr.take().expect("piped stderr");
        agent.running.lock().expect("agent lock").insert(thread, child);
        let stderr_text = tokio::spawn(async move {
            let mut text = String::new();
            let _ = stderr.read_to_string(&mut text).await;
            text
        });
        let mut lines = BufReader::new(stdout).lines();
        let mut stream = Stream { effort: agent.effort.clone(), ..Stream::default() };
        while let Ok(Some(line)) = lines.next_line().await {
            if let Ok(event) = serde_json::from_str::<Value>(&line) {
                stream.read(&event, &transcript);
            }
        }
        let child = agent.running.lock().expect("agent lock").remove(&thread);
        let status = match child {
            Some(mut child) => child.wait().await.ok(),
            None => None,
        };
        let stderr_text = stderr_text.await.unwrap_or_default();
        if agent.stopped.lock().expect("agent lock").remove(&thread) {
            transcript.push("notice", "stopped", Value::Null);
            break;
        }
        let failed = !stream.got_result && !status.is_some_and(|status| status.success());
        if failed && resume.is_some() {
            // a stale session id (its transcript gone) is the usual cause
            transcript.set_session(None);
            resume = None;
            transcript.push("notice", "could not resume the conversation; starting a new one", Value::Null);
            continue;
        }
        if failed {
            let last = stderr_text.lines().rev().find(|line| !line.trim().is_empty()).map(|line| format!(": {line}")).unwrap_or_default();
            transcript.push("error", &format!("claude exited without a result{last}"), Value::Null);
        }
        break;
    }
    let _ = std::fs::remove_file(&config);
    finish(&studio, thread);
    transcript.event("done", "");
}

fn finish(studio: &Studio, thread: u32) {
    if let Some(entry) = studio.review.lock().expect("review lock").thread_mut(thread) {
        entry.running = false;
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
        if !event["parent_tool_use_id"].is_null() {
            return;
        }
        match event["type"].as_str() {
            Some("system") if event["subtype"] == "init" => {
                if let Some(session) = event["session_id"].as_str() {
                    out.set_session(Some(session.to_owned()));
                }
                self.model = event["model"].as_str().unwrap_or("").to_owned();
            }
            Some("stream_event") => self.partial(&event["event"], out),
            Some("assistant") => {
                for block in event["message"]["content"].as_array().into_iter().flatten() {
                    match block["type"].as_str() {
                        Some("text") => {
                            let text = block["text"].as_str().unwrap_or("").trim();
                            if !text.is_empty() {
                                self.last_text = text.to_owned();
                                out.push("assistant", text, Value::Null);
                            }
                        }
                        Some("tool_use") => self.call(block, out),
                        _ => {}
                    }
                }
            }
            Some("user") => {
                for block in event["message"]["content"].as_array().into_iter().flatten() {
                    if block["type"] == "tool_result" {
                        self.answer(block, out);
                    }
                }
            }
            Some("result") => self.result(event, out),
            _ => {}
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

    fn call(&mut self, block: &Value, out: &Transcript) {
        let name = tool_name(block);
        if HIDDEN_TOOLS.contains(&name) {
            return;
        }
        let id = block["id"].as_str().unwrap_or("").to_owned();
        let data = json!({ "id": id, "name": name, "input": clip(&block["input"]), "status": "running" });
        let index = out.push("tool", "", data);
        self.calls.insert(id, index);
    }

    fn answer(&mut self, block: &Value, out: &Transcript) {
        let text = match &block["content"] {
            Value::String(text) => text.clone(),
            Value::Array(parts) => parts.iter().filter_map(|part| part["text"].as_str()).collect::<Vec<_>>().join("\n"),
            _ => String::new(),
        };
        let error = block["is_error"].as_bool().unwrap_or(false);
        if let Some(index) = block["tool_use_id"].as_str().and_then(|id| self.calls.get(id)) {
            out.update(*index, |entry| {
                entry.data["status"] = json!(if error { "error" } else { "ok" });
                // a proposal's id, for its chip
                if let Some(op) = serde_json::from_str::<Value>(&text).ok().and_then(|value| value["proposed"].as_u64()) {
                    entry.data["op"] = json!(op);
                }
                entry.data["result"] = json!(clip_text(&text));
            });
        }
    }

    fn result(&mut self, event: &Value, out: &Transcript) {
        self.got_result = true;
        if let Some(session) = event["session_id"].as_str() {
            out.set_session(Some(session.to_owned()));
        }
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

/// A tool's name without its MCP server's prefix.
fn tool_name(block: &Value) -> &str {
    let name = block["name"].as_str().unwrap_or("tool");
    name.rsplit("__").next().unwrap_or(name)
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

fn which(binary: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths).map(|directory| directory.join(binary)).find(|path| path.is_file())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The run may use the studio's tools and nothing else.
    #[test]
    fn a_run_has_only_the_studios_tools() {
        let args = arguments("q", "/tmp/c.json", "sys", "low", Some("opus"), Some("s1"));
        let after = |flag: &str| args[args.iter().position(|a| a == flag).unwrap() + 1].clone();
        assert_eq!(after("--allowedTools"), "mcp__puffin");
        assert_eq!(after("--disallowedTools"), "Bash,Write,Edit,NotebookEdit,Skill");
        assert_eq!(after("--tools"), "");
        assert_eq!(after("--mcp-config"), "/tmp/c.json");
        assert!(args.contains(&"--strict-mcp-config".to_owned()));
        assert_eq!(after("--resume"), "s1");
        assert_eq!(after("--model"), "opus");
        assert_eq!(after("--output-format"), "stream-json");
    }

    #[test]
    fn titles_are_first_lines_cut_short() {
        assert_eq!(title_of("\n  fix the match\nplease"), "fix the match");
        assert!(title_of(&"x".repeat(100)).ends_with('…'));
    }
}
