//! The voice builder (docs/VOICE.md): a long-running `claude -p` agent
//! (claude_cli.rs) with this server's MCP tools, which builds what the
//! author asks for as they talk. In voice mode its edits apply at once --
//! no proposals -- and each one is checked and shown as it lands.
//!
//! Instructions queue behind a run, or interrupt it (killed and resumed
//! with the new words); when a run stops with the properties failing it is
//! sent back to fix them, a bounded number of times. The builder asks the
//! author design questions on the board (docs/PLANNING.md §4), and the
//! answers come back to it as instructions.

use super::Context;
use super::places::target;
use crate::claude_cli::{McpConfig, Part, Run, parts};
use crate::mcp::{string_argument, strings_argument, tool};
use crate::props::{self, Results};
use crate::review::{Change, apply};
use crate::sexp;
use crate::studio::{Event, Studio};
use crate::toolchain::{self, Files};
use serde_json::{Value, json};
use std::fmt::Write as _;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// The header naming a voice builder's MCP calls (mcp.rs).
pub const VOICE_HEADER: &str = "x-studio-voice";
/// The review thread a voice builder reads as: it has no proposals, so it
/// sees the program as it is.
pub const VOICE_THREAD: u32 = u32::MAX - 1;
/// How many times a builder is sent back on its own to fix failing
/// properties, per instruction from the author.
const AUTO_FIXES: u32 = 2;
/// The steps one builder run may take.
const MAX_TURNS: u32 = 80;

impl Studio {
    /// Give the builder `instruction`: now, cutting off what it is doing,
    /// or after it.
    pub(super) fn instruct(self: &Arc<Self>, instruction: String, interrupt: bool, context: Context) {
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
        let mut prompt = self.builder_preamble();
        if interrupted {
            prompt.push_str("\nYou were interrupted: the author spoke while you worked. Your edits so far are applied. Take up the new words now; drop anything they make moot.\n");
        }
        prompt.push_str("\nThe author said:\n");
        for line in &batch {
            let _ = writeln!(prompt, "- {line}");
        }
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
        let outcome = match self.run_builder(prompt).await {
            Ok(outcome) => outcome,
            Err(error) => {
                self.voice_event("error", json!({ "message": error }));
                "failed"
            }
        };
        let touched = std::mem::take(&mut self.voice.state().touched);
        self.auto_arrange(&touched);
        self.voice_event("turn-end", json!({ "turn": turn, "ms": began.elapsed().as_millis() as u64, "outcome": outcome }));
    }

    /// Run the builder's claude on `prompt`, resuming its session; once more
    /// afresh, with the conversation, when that session cannot be resumed.
    /// How it ended: done, stopped or interrupted; Err: why it failed.
    async fn run_builder(self: &Arc<Self>, mut prompt: String) -> Result<&'static str, String> {
        let config = McpConfig::write(
            &format!("puffin-studio-voice-{}.json", std::process::id()),
            self.port(),
            &self.agent.mcp_token,
            json!({ "X-Studio-Thread": VOICE_THREAD.to_string(), "X-Studio-Voice": "1" }),
        )?;
        let system = crate::knowledge::system_prompt(&self.root, BUILDER);
        let mut resume = self.voice.state().session.clone();
        loop {
            let run = Run {
                prompt: &prompt,
                system: &system,
                config: &config.path,
                model: Some(&self.voice.model),
                effort: &self.voice.effort,
                max_turns: MAX_TURNS,
                resume: resume.as_deref(),
                eager_tools: true,
            };
            let mut got_result = false;
            let ended = run
                .stream(
                    &self.directory,
                    |child| self.voice.state().child = Some(child),
                    || self.voice.state().child.take(),
                    |event| got_result |= self.builder_event(event),
                )
                .await?;
            let (cut, stopped) = {
                let state = self.voice.state();
                (state.interrupted, state.stopped)
            };
            if stopped {
                return Ok("stopped");
            }
            if cut {
                return Ok("interrupted");
            }
            if got_result || ended.success {
                return Ok("done");
            }
            if resume.is_some() {
                // a session that cannot be resumed (an interrupted run can
                // leave one so): start afresh, with the conversation
                self.voice.state().session = None;
                resume = None;
                let conversation = self.voice.state().conversation.iter().cloned().collect::<Vec<_>>().join("\n");
                prompt = format!("(Your earlier conversation could not be resumed. Its last lines:\n{conversation})\n{prompt}");
                continue;
            }
            return Err(format!("the builder stopped: {}", ended.last_words().unwrap_or("no output")));
        }
    }

    /// Show one stream-json event of the builder; whether it was the result.
    fn builder_event(&self, event: &Value) -> bool {
        let mut ended = false;
        for part in parts(event) {
            match part {
                Part::Session(session) => self.voice.state().session = Some(session.to_owned()),
                Part::Init { .. } => {}
                Part::Partial(inner) => {
                    if inner["type"] == "content_block_start" {
                        match inner["content_block"]["type"].as_str() {
                            Some("thinking" | "redacted_thinking") => self.set_activity(json!({ "state": "thinking" })),
                            Some("text") => self.set_activity(json!({ "state": "talking" })),
                            _ => {}
                        }
                    }
                }
                Part::Text(text) => {
                    let turn = self.voice.state().turn;
                    self.voice_event("builder", json!({ "text": text, "turn": turn }));
                    self.converse(format!("builder: {}", toolchain::clip(text, 400)));
                }
                Part::ToolUse { id, name, input } => self.builder_step(id, name, input),
                Part::ToolResult { id, text, error } => {
                    let (turn, name) = {
                        let state = self.voice.state();
                        (state.turn, state.calls.get(id).cloned().unwrap_or_default())
                    };
                    // `say` and `show` speak for themselves in the trace
                    if !matches!(name.as_str(), "say" | "show") {
                        let (ok, summary) = step_outcome(&name, &text, error);
                        self.voice_event("step-done", json!({ "turn": turn, "id": id, "ok": ok, "summary": summary }));
                    }
                }
                Part::Result(event) => {
                    if event["is_error"].as_bool().unwrap_or(false) {
                        let text = event["result"].as_str().unwrap_or("").trim();
                        let message = if text.is_empty() { event["subtype"].as_str().unwrap_or("error").to_owned() } else { text.to_owned() };
                        self.voice_event("error", json!({ "message": format!("builder: {message}") }));
                    }
                    ended = true;
                }
            }
        }
        ended
    }

    /// A tool call of the builder: a step in the trace (but for the tools
    /// that show themselves), and what it is doing now.
    fn builder_step(&self, id: &str, name: &str, input: &Value) {
        let what = input["file"].as_str().or(input["name"].as_str()).or(input["query"].as_str()).unwrap_or("");
        let text = describe_tool(name, what);
        let turn = {
            let mut state = self.voice.state();
            state.calls.insert(id.to_owned(), name.to_owned());
            state.turn
        };
        // `say` and `show` speak for themselves in the trace
        if !matches!(name, "say" | "show" | "arrange") {
            let mut step = json!({ "turn": turn, "id": id, "tool": name, "text": text });
            if let Some(file) = input["file"].as_str() {
                step["file"] = json!(file);
            }
            if let Some(detail) = step_input(name, input) {
                step["input"] = json!(detail);
            }
            self.voice_event("step", step);
        }
        self.set_activity(json!({ "state": "working", "tool": name, "text": text }));
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
        let diagnostics = self.diagnostic_lines(20);
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
                crate::board::card_mut(board, file);
            }
            board["focus"] = json!({ "items": items, "question": id, "label": format!("question #{id}") });
            crate::board::look(board, "board");
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
        let text = |key: &str| string_argument(arguments, key);
        let note = arguments["note"].as_str().unwrap_or("").to_owned();
        match name {
            "edit" => {
                let change = Change { file: text("file")?, old: arguments["old"].as_str().unwrap_or("").to_owned(), new: text("new")? };
                self.apply_voice(change, &note).await
            }
            "write_file" => {
                let file = crate::studio::files::valid_path(&text("file")?)?;
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
                let requires = strings_argument(arguments, "requires");
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
                let about = strings_argument(arguments, "about");
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
            crate::studio::files::valid_path(&change.file)?;
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
        let warnings = report.warnings();
        if !warnings.is_empty() {
            answer["warnings"] = json!(warnings);
        }
        Ok(answer)
    }
}

/// The tools a voice builder has: the assistant's reads and checks, and
/// its own writes (applied at once).
pub fn tools() -> Value {
    const READS: [&str; 13] = [
        "list_files", "get_file", "check", "assists_at", "holes", "lint", "type_at", "facts_at", "evaluate", "trace", "evaluate_program", "search_docs", "read_doc",
    ];
    let mut out: Vec<Value> = crate::mcp::tools().as_array().cloned().unwrap_or_default().into_iter().filter(|tool| READS.contains(&tool["name"].as_str().unwrap_or(""))).collect();
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
            "Arrange what the author sees (they may also say it). Beside the definition they are in, the studio shows a working set of other definitions as live code, on the same zoomable surface as the module board. action: pull (`names` into the working set, beside their focus) / close (out of it); beside (`names` next to the definition `near`, both in the working set); show-board / show-editor (glide out to the whole program, or back in to the code); hide/unhide (rows on their cards), only (just these definitions), slice (these and what touches them), clear, bring/put-away (modules' cards), note (leave a comment, in `text`, on `names` or `modules` -- e.g. a design trade-off you noticed). Use it to put what you are talking about in front of them: pull the definitions you are explaining.",
            json!({ "action": {"type": "string"}, "names": {"type": "array", "items": {"type": "string"}}, "modules": {"type": "array", "items": {"type": "string"}}, "near": {"type": "string"}, "text": {"type": "string"} }),
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

/// Added to a builder run's prompt while the board is in plan mode.
const PLAN_MODE: &str = "\n\
PLAN MODE is on. Build the program's design, not its code: modules (require/provide), data definitions \
(define-type, define-type-alias, define-grammar), and for every function a typed signature `(: f (-> A B))` \
with its body a single typed hole: `(define (f x) ??)`. The check checks everything around the holes, and \
properties that reach a hole show as open, not failing. Write a body only when the author says to dive in, \
implement or fill in a definition -- then that one alone. Keep each module's provide list current; a helper \
nothing outside needs is `(private helper)`, a type whose representation stays home is `(opaque T)`. When a \
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

The view. The author reads one definition at a time (the focus), with a working set of others beside it \
as live code, and the module board -- cards of signatures, one row per definition -- on the same surface, \
a zoom away. Write a one-line comment above each definition saying what it is for -- the board shows it \
under the signature. Use `arrange` to put what you are talking about in front of them (pull it into the \
working set; show-board for the whole design).

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

    #[test]
    fn changed_lines_finds_the_edit() {
        assert_eq!(changed_lines("a\nb\nc\n", "a\nB\nc\n"), (2, 2));
        assert_eq!(changed_lines("a\nc\n", "a\nb1\nb2\nc\n"), (2, 3));
        assert_eq!(changed_lines("", "x\ny\n"), (1, 2));
        assert_eq!(changed_lines("a\nb\n", "a\n"), (1, 1));
    }
}
