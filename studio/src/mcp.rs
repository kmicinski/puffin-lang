//! `POST /mcp`: the tools the assistant reads, checks, and changes the
//! program with, as a JSON-RPC MCP server (plain request/response HTTP, as
//! in Slog Studio). The bearer token admits a call; the `x-studio-thread`
//! header names the thread it acts for, whose pending proposals every read
//! sees applied.

use crate::agent::THREAD_HEADER;
use crate::knowledge;
use crate::review::{Change, Status};
use crate::sexp;
use crate::studio::Studio;
use crate::toolchain;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde_json::{Value, json};
use std::sync::Arc;

pub async fn handle(studio: &Arc<Studio>, headers: HeaderMap, body: String) -> Response {
    let bearer = headers.get(header::AUTHORIZATION).and_then(|value| value.to_str().ok()).and_then(|value| value.strip_prefix("Bearer "));
    if !bearer.is_some_and(|token| crate::web::same_secret(token, &studio.agent.mcp_token)) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let thread = headers.get(THREAD_HEADER).and_then(|value| value.to_str().ok()).and_then(|value| value.parse::<u32>().ok());
    let request: Value = match serde_json::from_str(&body) {
        Ok(request) => request,
        Err(error) => return rpc_error(Value::Null, -32700, &format!("parse error: {error}")),
    };
    // a notification (no id) expects no answer
    let Some(id) = request.get("id").cloned() else {
        return StatusCode::ACCEPTED.into_response();
    };
    let result = match request["method"].as_str().unwrap_or("") {
        "initialize" => json!({
            "protocolVersion": "2025-06-18",
            "capabilities": { "tools": {} },
            "serverInfo": { "name": "puffin-studio", "version": env!("CARGO_PKG_VERSION") },
        }),
        "ping" => json!({}),
        "tools/list" => json!({ "tools": tools() }),
        "tools/call" => {
            let name = request["params"]["name"].as_str().unwrap_or("");
            let arguments = &request["params"]["arguments"];
            match call(studio, thread, name, arguments).await {
                Ok(value) => {
                    let mut result = json!({
                        "content": [{ "type": "text", "text": serde_json::to_string_pretty(&value).unwrap_or_default() }],
                        "isError": false,
                    });
                    if value.is_object() {
                        result["structuredContent"] = value;
                    }
                    result
                }
                // a tool failure is a result the model reads, not a protocol error
                Err(message) => json!({ "content": [{ "type": "text", "text": message }], "isError": true }),
            }
        }
        "resources/list" => json!({ "resources": [] }),
        "prompts/list" => json!({ "prompts": [] }),
        method => return rpc_error(id, -32601, &format!("unknown method {method}")),
    };
    ([(header::CONTENT_TYPE, "application/json")], json!({ "jsonrpc": "2.0", "id": id, "result": result }).to_string()).into_response()
}

fn rpc_error(id: Value, code: i64, message: &str) -> Response {
    (
        [(header::CONTENT_TYPE, "application/json")],
        json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } }).to_string(),
    )
        .into_response()
}

/// A point in `text`: `pos` (a byte offset), or `line` and `column`
/// (1-based; the column in characters).
fn point(arguments: &Value, text: &str) -> Result<usize, String> {
    if let Some(pos) = arguments["pos"].as_u64() {
        return Ok((pos as usize).min(text.len()));
    }
    match (arguments["line"].as_u64(), arguments["column"].as_u64()) {
        (Some(line), column) => Ok(sexp::offset_of(text, line as usize, column.unwrap_or(1) as usize)),
        _ => Err("give `pos` (a byte offset) or `line` and `column` (1-based)".to_owned()),
    }
}

/// A selection's end, `end` (a byte offset), past `at`.
fn selection_end(arguments: &Value, text: &str, at: usize) -> Option<usize> {
    arguments["end"].as_u64().map(|end| (end as usize).min(text.len())).filter(|end| *end > at)
}

pub async fn call(studio: &Arc<Studio>, thread: Option<u32>, name: &str, arguments: &Value) -> Result<Value, String> {
    let thread = thread.ok_or("this MCP session names no thread; the studio's assistant runs set one")?;
    let text = |key: &str| arguments[key].as_str().map(str::to_owned).ok_or_else(|| format!("missing string argument `{key}`"));
    let note = arguments["note"].as_str().unwrap_or("").to_owned();
    let fork = || studio.fork_of(thread);
    let file_text = |fork: &toolchain::Files, file: &str| fork.get(file).cloned().ok_or_else(|| format!("there is no file {file}"));
    match name {
        "list_files" => {
            let files = fork();
            let listed: Vec<Value> = files
                .iter()
                .map(|(path, text)| json!({ "file": path, "lines": text.lines().count(), "forms": sexp::forms(text).len() }))
                .collect();
            Ok(json!({ "files": listed, "entries": toolchain::entries(&files) }))
        }
        "get_file" => {
            let file = text("file")?;
            let files = fork();
            let body = file_text(&files, &file)?;
            let forms: Vec<Value> = sexp::forms(&body)
                .iter()
                .map(|form| json!({ "key": form.key(), "line": form.line, "start": form.start, "end": form.end }))
                .collect();
            Ok(json!({ "file": file, "text": body, "forms": forms, "note": "the author's text with your pending proposals applied; start/end are byte offsets" }))
        }
        "check" => {
            let files = fork();
            let entries = toolchain::entries(&files);
            let report = studio.toolchain.check_all(&files, &entries).await;
            let mut answer = json!({ "ok": report.ok, "checked": entries, "diagnostics": report.describe() });
            if report.holed() {
                let holes: usize = files.values().map(|text| sexp::holes(text).len()).sum();
                answer["passes"] = json!(report.passes());
                answer["holes"] = json!(holes);
                answer["note"] = json!("the check stopped at the first typed hole (??): nothing past it was checked; `holes` lists them with their goals");
            }
            Ok(answer)
        }
        "assists_at" => {
            let file = text("file")?;
            let files = fork();
            let body = file_text(&files, &file)?;
            let at = point(arguments, &body)?;
            let mut args = vec![at.to_string()];
            if let Some(end) = selection_end(arguments, &body, at) {
                args.push(end.to_string());
            }
            let mut answer = studio.toolchain.assist_with(&files, "assists", &file, args).await.map_err(|report| report.describe())?;
            answer["pos"] = json!(at);
            Ok(answer)
        }
        "type_at" => {
            let file = text("file")?;
            let files = fork();
            let at = point(arguments, &file_text(&files, &file)?)?;
            let mut answer = studio.toolchain.assist(&files, "type-at", &file, Some(at)).await.map_err(|report| report.describe())?;
            answer["pos"] = json!(at);
            Ok(answer)
        }
        "holes" => {
            let files = fork();
            let holes: Vec<Value> = studio
                .all_holes(&files)
                .await
                .into_iter()
                .map(|(file, hole)| json!({ "file": file, "line": hole.line, "pos": hole.pos, "goal": hole.goal }))
                .collect();
            Ok(json!({ "holes": holes, "note": "pos is a byte offset; assists_at there lists the compiler's fill-hole candidates" }))
        }
        "lint" => {
            let files = fork();
            if studio.toolchain.observed.lock().expect("observed lock").as_ref().is_none_or(|path| !path.is_file()) {
                return Ok(json!({ "findings": [], "note": "the author's session has observed nothing yet: evaluate some calls first" }));
            }
            let mut findings = Vec::new();
            for file in files.keys().filter(|file| crate::studio::checkable(file)) {
                for finding in studio.lint_of(&files, file).await {
                    findings.push(json!({ "file": file, "line": finding.line, "pos": finding.pos, "message": finding.message, "source": finding.source }));
                }
            }
            Ok(json!({
                "findings": findings,
                "note": "matches the session saw take a shape no clause handles (seen so far, not proof); the add-missing-cases assist with source observed at pos adds them",
            }))
        }
        "facts_at" => {
            let file = text("file")?;
            let files = fork();
            let at = point(arguments, &file_text(&files, &file)?)?;
            let mut facts = studio.facts_at(&files, &file, at, true).await?;
            facts["note"] = json!("type is the checker's; session is the author's live session; observed and function are what the session's runs passed (sampled, at most 16 shapes a parameter: evidence, not proof)");
            Ok(facts)
        }
        "apply_assist" => {
            let file = text("file")?;
            let body = file_text(&fork(), &file)?;
            let at = point(arguments, &body)?;
            let end = selection_end(arguments, &body, at);
            let title = arguments["title"].as_str();
            studio.propose_assist(thread, &file, (at, end), &text("id")?, title, note).await
        }
        "propose_edit" => {
            let change = Change { file: text("file")?, old: text("old")?, new: text("new")? };
            studio.propose(thread, change, note).await
        }
        "get_proposals" => {
            let view = studio.review_view();
            let mine: Vec<Value> = view
                .ops
                .iter()
                .filter(|op| op.op.thread == thread)
                .map(|op| {
                    json!({
                        "id": op.op.id, "file": op.op.change.file, "note": op.op.note,
                        "status": op.op.status, "stale": op.op.status == Status::Pending && op.stale,
                        "conflicts": op.conflicts,
                    })
                })
                .collect();
            Ok(json!({ "proposals": mine }))
        }
        "evaluate" => studio.try_expression(&text("expr")?).await,
        "evaluate_program" => {
            let files = fork();
            let file = match arguments["file"].as_str() {
                Some(file) => file.to_owned(),
                None => toolchain::entries(&files).into_iter().next().ok_or("the program has no file to run")?,
            };
            file_text(&files, &file)?;
            Ok(studio.run_fork(&files, &file).await)
        }
        "search_docs" => Ok(knowledge::search(&studio.root, &text("query")?, 8)),
        "read_doc" => {
            let number = |key: &str, default: u64| arguments[key].as_u64().unwrap_or(default) as usize;
            knowledge::read(&studio.root, &text("path")?, number("start", 1), number("lines", 200))
        }
        _ => Err(format!("unknown tool {name}")),
    }
}

pub fn tools() -> Value {
    let object = |properties: Value, required: &[&str]| json!({ "type": "object", "properties": properties, "required": required });
    let note = json!({ "type": "string", "description": "One sentence for the author: what this changes and why. Shown over the change." });
    let file = json!({ "type": "string", "description": "A project file, as list_files names it (e.g. `main.puf`)." });
    let at = json!({
        "file": file,
        "pos": { "type": "integer", "description": "Byte offset into the file (get_file's forms give offsets)." },
        "line": { "type": "integer", "description": "1-based line, instead of pos." },
        "column": { "type": "integer", "description": "1-based column, with line." },
    });
    let mut selected = at.clone();
    selected["end"] = json!({ "type": "integer", "description": "With pos, a selection [pos, end) (byte offsets): offers extract (the selection as a new top-level function)." });
    let mut with_id = selected.clone();
    with_id["id"] = json!({ "type": "string", "description": "The assist's id, as assists_at lists it (fill-match, add-missing-cases, case-split, template, stub, fill-hole, extract, ...)." });
    with_id["title"] = json!({ "type": "string", "description": "The assist's exact title, when several share its id (each fill-hole candidate is one)." });
    with_id["note"] = note.clone();
    json!([
        {
            "name": "list_files",
            "description": "The program's files, with their sizes, and its entries (the modules nothing requires).",
            "inputSchema": object(json!({}), &[]),
        },
        {
            "name": "get_file",
            "description": "A file's text as your pending proposals leave it, with its top-level forms (key, line, byte start and end).",
            "inputSchema": object(json!({ "file": file }), &["file"]),
        },
        {
            "name": "check",
            "description": "Check the whole program as your proposals leave it (reader, resolver, types): ok, or the located errors and warnings.",
            "inputSchema": object(json!({}), &[]),
        },
        {
            "name": "assists_at",
            "description": "The compiler's deterministic edits that apply at a point -- fill a match from its scrutinee's type, add missing cases, case-split a binder, a structural-recursion template, stub an unbound function, annotate a function from observed types, fill a typed hole ?? (fill-hole: the locals of the goal type, the recursive call, constructors with new holes), and with `end` extract the selection into a function -- each with its title, source and edits. source says where the knowledge came from: type (the checker; certain), observed (values the author's session passed; seen so far, not proof), patterns (other matches and templates in the file), call-site, syntax. Prefer these to writing such code yourself; apply_assist proposes one.",
            "inputSchema": object(selected, &["file"]),
        },
        {
            "name": "apply_assist",
            "description": "Propose the edit of assist `id` at a point (see assists_at), as a proposal like propose_edit's: checked, scoped, and waiting for the author.",
            "inputSchema": object(with_id, &["file", "id"]),
        },
        {
            "name": "holes",
            "description": "Every typed hole (??) in the program as your proposals leave it: file, line, byte pos, and its goal type (the type the expression there must have). A program with holes fails to compile; its check stops at the first hole.",
            "inputSchema": object(json!({}), &[]),
        },
        {
            "name": "lint",
            "description": "The observation lint: each match with no catch-all whose parameter the author's live session saw take a shape no clause handles (file, line, byte pos of the match, message). Evidence from real runs, not proof. The add-missing-cases assist with source observed at the match adds the cases.",
            "inputSchema": object(json!({}), &[]),
        },
        {
            "name": "type_at",
            "description": "The type the checker gives the expression at a point, or null.",
            "inputSchema": object(at.clone(), &["file"]),
        },
        {
            "name": "facts_at",
            "description": "Everything known at a point, each part labelled with its layer: form (syntax: its key and lines), type and diagnostics (the checker), session (whether the author's live session has this form current, stale, or not loaded; an expression's last result), and observed/function (what the session's runs actually passed: per parameter, the call count and the shapes seen, with match patterns made from them).",
            "inputSchema": object(at, &["file"]),
        },
        {
            "name": "propose_edit",
            "description": "Propose replacing an exact piece of a file's text. `old` must occur exactly once in the file as get_file shows it; include whole forms or enough context. An empty `old` appends `new` to the file (making the file if it does not exist), when the question's scope allows. The program as it would leave it must pass the check, and the change must stay inside the question's scope, or it is refused with why. Editing text your pending proposal wrote corrects that proposal. Nothing changes until the author accepts.",
            "inputSchema": object(json!({
                "file": file,
                "old": { "type": "string", "description": "Exact text to replace, occurring once; empty to append." },
                "new": { "type": "string", "description": "Its replacement (may be empty to delete)." },
                "note": note,
            }), &["file", "old", "new", "note"]),
        },
        {
            "name": "get_proposals",
            "description": "Your proposals in this thread: status, whether each still applies (stale), and conflicts with other threads.",
            "inputSchema": object(json!({}), &[]),
        },
        {
            "name": "evaluate",
            "description": "Evaluate Puffin forms against the author's live REPL session (what they evaluated is defined there) and keep nothing. Returns printed output and results, or the error. Effects outside the session (system, write-file, reading stdin, foreign) are refused.",
            "inputSchema": object(json!({ "expr": { "type": "string", "description": "One or more forms, e.g. `(eval-expr (Add (Num 1) (Num 2)))`." } }), &["expr"]),
        },
        {
            "name": "evaluate_program",
            "description": "Compile one file of the program, as your proposals leave it, as a whole program, and run it on a throwaway VM (10 s limit): its output and exit status, or the compile errors.",
            "inputSchema": object(json!({ "file": { "type": "string", "description": "The file to run (default: the first entry)." } }), &[]),
        },
        {
            "name": "search_docs",
            "description": "Search Puffin's docs (docs/*.md: LANGUAGE, STDLIB, TYPES, MODULES, ...) and examples for words; returns the best paragraphs with file and line.",
            "inputSchema": object(json!({ "query": { "type": "string", "description": "Words or a phrase." } }), &["query"]),
        },
        {
            "name": "read_doc",
            "description": "Read lines of a doc or example search_docs named (e.g. `docs/STDLIB.md`).",
            "inputSchema": object(json!({
                "path": { "type": "string", "description": "Repository-relative path." },
                "start": { "type": "integer", "description": "First line, 1-based (default 1)." },
                "lines": { "type": "integer", "description": "How many (default 200, at most 400)." },
            }), &["path"]),
        },
    ])
}
