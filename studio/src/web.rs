//! HTTP: the page, its static assets, Monaco from the repository's
//! `web/node_modules`, one WebSocket per browser tab carrying edits and
//! commands in and events out, and `/mcp` for the assistant.
//!
//! Only the WebSocket and `/mcp` can read or change anything, so only they
//! are guarded: the WebSocket by the launch token (carried in the page's
//! fragment, sent in the handshake) and a same-origin `Origin`; `/mcp` by
//! its bearer token. The page and its assets hold no data. The server
//! binds 127.0.0.1 only.

use crate::ask::Context;
use crate::repl::{At, Source};
use crate::sexp;
use crate::studio::{Refused, Studio};
use axum::Router;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode, Uri, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::sync::{broadcast, mpsc};

struct Web {
    studio: Arc<Studio>,
    token: String,
    next_connection: AtomicU64,
}

pub fn router(studio: Arc<Studio>, token: String) -> Router {
    let web = Arc::new(Web { studio, token, next_connection: AtomicU64::new(1) });
    Router::new()
        .route("/", get(|| async { page(asset_text("index.html")) }))
        .route("/static/{name}", get(|Path(name): Path<String>| async move { asset(&name) }))
        .route("/vs/{*path}", get(monaco))
        .route("/ws", get(socket))
        .route(
            "/mcp",
            post(|State(web): State<Arc<Web>>, headers: HeaderMap, body: String| async move {
                crate::mcp::handle(&web.studio, headers, body).await
            }),
        )
        .with_state(web)
}

fn page(html: String) -> Response {
    ([(header::CONTENT_TYPE, "text/html; charset=utf-8"), (header::CACHE_CONTROL, "no-cache")], html).into_response()
}

/// The browser client, compiled in; with PUFFIN_STUDIO_WEB set, read from
/// that directory instead, so the client can change without a rebuild.
macro_rules! assets {
    ($($name:literal),* $(,)?) => {
        fn bundled(name: &str) -> Option<&'static str> {
            match name {
                $($name => Some(include_str!(concat!("../web/", $name))),)*
                // the playground's generated primitive names (tools/gen-prim-names.rkt)
                "prim-names.js" => Some(include_str!("../../web/src/engine/prim-names.js")),
                _ => None,
            }
        }
    };
}

assets!(
    "index.html", "studio.css", "assist.css", "diff.css", "main.js", "editor.js", "lexer.js", "sexp.js", "paredit.js",
    "files.js", "repl.js", "assist.js", "assists.js", "markdown.js", "hunks.js", "inline-diff.js", "proposals.js",
    "versions.js", "session.js", "facts.js",
);

fn asset_text(name: &str) -> String {
    if let Some(dir) = std::env::var_os("PUFFIN_STUDIO_WEB")
        && name != "prim-names.js"
        && let Ok(text) = std::fs::read_to_string(std::path::Path::new(&dir).join(name))
    {
        return text;
    }
    bundled(name).unwrap_or_default().to_owned()
}

fn asset(name: &str) -> Response {
    if bundled(name).is_none() {
        return StatusCode::NOT_FOUND.into_response();
    }
    let kind = if name.ends_with(".css") { "text/css; charset=utf-8" } else { "text/javascript; charset=utf-8" };
    ([(header::CONTENT_TYPE, kind), (header::CACHE_CONTROL, "no-cache")], asset_text(name)).into_response()
}

/// Monaco's AMD build, from the repository's web/node_modules.
async fn monaco(State(web): State<Arc<Web>>, Path(path): Path<String>) -> Response {
    if path.split('/').any(|part| part == ".." || part.is_empty()) {
        return StatusCode::NOT_FOUND.into_response();
    }
    let file = web.studio.root.join("web/node_modules/monaco-editor/min/vs").join(&path);
    let Ok(bytes) = tokio::fs::read(&file).await else { return StatusCode::NOT_FOUND.into_response() };
    let kind = match file.extension().and_then(|e| e.to_str()) {
        Some("js") => "text/javascript; charset=utf-8",
        Some("css") => "text/css; charset=utf-8",
        Some("ttf") => "font/ttf",
        Some("svg") => "image/svg+xml",
        Some("json") => "application/json",
        _ => "application/octet-stream",
    };
    ([(header::CONTENT_TYPE, kind), (header::CACHE_CONTROL, "max-age=3600")], bytes).into_response()
}

/// Whether two secrets are equal, in time independent of where they differ.
pub fn same_secret(given: &str, expected: &str) -> bool {
    given.len() == expected.len() && given.bytes().zip(expected.bytes()).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0
}

/// Whether a request's `Origin`, if any, is the host it was sent to.
pub fn same_origin(headers: &HeaderMap) -> bool {
    let Some(origin) = headers.get(header::ORIGIN).and_then(|value| value.to_str().ok()) else { return true };
    let host = headers.get(header::HOST).and_then(|value| value.to_str().ok()).unwrap_or("");
    origin.strip_prefix("http://").is_some_and(|rest| rest == host)
}

/// The value of `key` in `a=1&b=2`, undecoded (tokens are hex).
fn field<'a>(query: &'a str, key: &str) -> Option<&'a str> {
    query.split('&').find_map(|pair| pair.split_once('=').filter(|(name, _)| *name == key).map(|(_, value)| value))
}

/// What a tab asks of the studio.
#[derive(Debug, Deserialize)]
#[serde(tag = "t", rename_all = "kebab-case")]
enum Request {
    /// The whole text of `file`, edited from version `base`.
    Edit { file: String, base: u64, text: String },
    Save,
    NewFile { path: String },
    /// The tab shows `file`: check it if nothing is known of it.
    Focus { file: String },
    /// Evaluate in the live session: `source` "prompt", "buffer" (text of
    /// `file` starting on `line`: a selection), or "file" (the whole module).
    Eval {
        text: String,
        source: String,
        #[serde(default)]
        file: Option<String>,
        #[serde(default)]
        line: Option<usize>,
    },
    /// Evaluate the form of `file` at UTF-16 offset `pos` or on `line`,
    /// with the definitions it needs (⌘↵, `,eval FILE:LINE`).
    EvalForm {
        file: String,
        #[serde(default)]
        pos: Option<usize>,
        #[serde(default)]
        line: Option<usize>,
    },
    Interrupt,
    Reset,
    /// The assists at UTF-16 offset `pos` of `file`; answered with `seq`.
    Assists { seq: u64, file: String, pos: usize },
    TypeAt { seq: u64, file: String, pos: usize },
    /// The facts at UTF-16 offset `pos` of `file`; `full` for the Facts
    /// panel (every parameter's patterns), else for a hover.
    Facts {
        seq: u64,
        file: String,
        pos: usize,
        #[serde(default)]
        full: bool,
    },
    /// A gesture's command, for the transcript.
    Echo { line: String },
    Ask {
        thread: Option<u32>,
        message: String,
        #[serde(default)]
        context: Context,
    },
    StopThread { thread: u32 },
    Accept { ops: Vec<u32> },
    Reject { op: u32 },
    AcceptChangeset { changeset: u32 },
    Versions { file: String },
    VersionText { id: u64 },
    Restore { id: u64 },
}

/// Messages for one tab only; everything else is a broadcast `Event`.
#[derive(Debug, Serialize)]
#[serde(tag = "t", rename_all = "kebab-case")]
enum Reply<'a> {
    Init(&'a crate::studio::Snapshot),
    /// The edit making `file`'s `version` was taken.
    Ack { file: &'a str, version: u64 },
    /// The edit was refused: this is the current text.
    Stale { file: &'a str, version: u64, text: &'a str },
    /// The edit was refused: `file` is not in the project.
    Gone { file: &'a str },
    Notice { message: &'a str },
    Assists { seq: u64, version: u64, assists: Value, error: Option<String> },
    Type { seq: u64, r#type: Value, error: Option<String> },
    Facts { seq: u64, version: u64, facts: Value, error: Option<String> },
    Asked { thread: Option<u32>, message: &'a str, error: Option<String> },
    Versions { file: &'a str, versions: Vec<crate::versions::Version> },
    VersionText { id: u64, file: String, text: String },
}

fn json<T: Serialize>(value: &T) -> String {
    serde_json::to_string(value).expect("studio messages serialize")
}

async fn socket(State(web): State<Arc<Web>>, uri: Uri, headers: HeaderMap, upgrade: WebSocketUpgrade) -> Response {
    let admitted = uri.query().and_then(|query| field(query, "token")).is_some_and(|given| same_secret(given, &web.token));
    if !admitted || !same_origin(&headers) {
        return StatusCode::FORBIDDEN.into_response();
    }
    let connection = web.next_connection.fetch_add(1, Ordering::SeqCst);
    upgrade.on_upgrade(move |socket| serve(socket, web.studio.clone(), connection))
}

async fn serve(mut socket: WebSocket, studio: Arc<Studio>, connection: u64) {
    let mut events = studio.subscribe();
    let (direct, mut replies) = mpsc::unbounded_channel::<String>();
    if send_init(&mut socket, &studio).await.is_err() {
        return;
    }
    loop {
        let outgoing = tokio::select! {
            incoming = socket.recv() => match incoming {
                Some(Ok(Message::Text(text))) => {
                    handle(&studio, connection, &text, &direct);
                    continue;
                }
                Some(Ok(_)) => continue,
                Some(Err(_)) | None => return,
            },
            reply = replies.recv() => reply.expect("the sender lives in this loop"),
            event = events.recv() => match event {
                // a tab's own edit is already on its screen
                Ok(crate::studio::Event::Text { origin, .. }) if origin == connection => continue,
                Ok(event) => json(&event),
                Err(broadcast::error::RecvError::Lagged(_)) => {
                    if send_init(&mut socket, &studio).await.is_err() {
                        return;
                    }
                    continue;
                }
                Err(broadcast::error::RecvError::Closed) => return,
            },
        };
        if socket.send(Message::Text(outgoing.into())).await.is_err() {
            return;
        }
    }
}

async fn send_init(socket: &mut WebSocket, studio: &Studio) -> Result<(), axum::Error> {
    let snapshot = studio.snapshot().await;
    socket.send(Message::Text(json(&Reply::Init(&snapshot)).into())).await
}

/// Tell the tab why its request failed, if it did.
fn notice(direct: &mpsc::UnboundedSender<String>, outcome: Result<(), String>) {
    if let Err(message) = outcome {
        let _ = direct.send(json(&Reply::Notice { message: &message }));
    }
}

/// The UTF-16 offset `pos` of `file` as a byte offset; the assists there,
/// their edits back in UTF-16 offsets; and the version they are for.
async fn assists_at(studio: &Studio, file: &str, pos: usize) -> (u64, Value, Option<String>) {
    let files = studio.files();
    let version = studio.version_of(file).unwrap_or(0);
    let Some(text) = files.get(file) else { return (version, json!([]), Some(format!("no file {file}"))) };
    let at = sexp::byte_of_utf16(text, pos);
    match studio.toolchain.assist(&files, "assists", file, Some(at)).await {
        Ok(answer) => {
            let mut assists = answer["assists"].clone();
            for assist in assists.as_array_mut().into_iter().flatten() {
                for edit in assist["edits"].as_array_mut().into_iter().flatten() {
                    for key in ["start", "end"] {
                        let byte = edit[key].as_u64().unwrap_or(0) as usize;
                        edit[key] = json!(sexp::utf16_of_byte(text, byte));
                    }
                }
                assist["pos"] = json!(at);
            }
            let stopped = answer["stopped"].as_str().map(str::to_owned);
            (version, assists, stopped)
        }
        Err(report) => (version, json!([]), Some(report.describe())),
    }
}

/// Edits are answered at once; everything that runs a process runs as its
/// own task, so this tab can still interrupt it.
fn handle(studio: &Arc<Studio>, connection: u64, text: &str, direct: &mpsc::UnboundedSender<String>) {
    let request = match serde_json::from_str::<Request>(text) {
        Ok(request) => request,
        Err(error) => {
            let _ = direct.send(json(&Reply::Notice { message: &format!("unreadable request: {error}") }));
            return;
        }
    };
    let studio = studio.clone();
    let direct = direct.clone();
    let reply = |message: String| {
        let _ = direct.send(message);
    };
    match request {
        Request::Edit { file, base, text } => reply(match studio.edit(connection, &file, base, text) {
            Ok(version) => json(&Reply::Ack { file: &file, version }),
            Err(Refused::Stale { version, text }) => json(&Reply::Stale { file: &file, version, text: &text }),
            Err(Refused::NoFile) => json(&Reply::Gone { file: &file }),
        }),
        Request::Save => notice(&direct, studio.save()),
        Request::NewFile { path } => notice(&direct, studio.new_file(&path)),
        Request::Focus { file } => {
            tokio::spawn(async move { studio.check_if_unknown(&file).await });
        }
        Request::Eval { text, source, file, line } => {
            let source = match (source.as_str(), file) {
                ("buffer", Some(file)) => Source::buffer(file, line.unwrap_or(1)),
                ("file", Some(file)) => Source::File { file },
                _ => Source::Prompt,
            };
            let text = match &source {
                Source::File { file } => studio.text_of(file).unwrap_or_default(),
                _ => text,
            };
            tokio::spawn(async move { studio.evaluate(text, source).await });
        }
        Request::EvalForm { file, pos, line } => {
            tokio::spawn(async move {
                let text = studio.text_of(&file).unwrap_or_default();
                let at = match (pos, line) {
                    (Some(pos), _) => At::Pos(sexp::byte_of_utf16(&text, pos)),
                    (None, line) => At::Line(line.unwrap_or(1)),
                };
                notice(&direct, studio.eval_form(&file, at).await);
            });
        }
        Request::Interrupt => notice(&direct, studio.lane.interrupt()),
        Request::Reset => {
            tokio::spawn(async move {
                studio.reset().await;
                studio.echo(",reset");
            });
        }
        Request::Assists { seq, file, pos } => {
            tokio::spawn(async move {
                let (version, assists, error) = assists_at(&studio, &file, pos).await;
                let _ = direct.send(json(&Reply::Assists { seq, version, assists, error }));
            });
        }
        Request::TypeAt { seq, file, pos } => {
            tokio::spawn(async move {
                let files = studio.files();
                let text = files.get(&file).cloned().unwrap_or_default();
                let at = sexp::byte_of_utf16(&text, pos);
                let (kind, error) = match studio.toolchain.assist(&files, "type-at", &file, Some(at)).await {
                    Ok(answer) => (answer["type"].clone(), None),
                    Err(report) => (Value::Null, Some(report.describe())),
                };
                let _ = direct.send(json(&Reply::Type { seq, r#type: kind, error }));
            });
        }
        Request::Facts { seq, file, pos, full } => {
            tokio::spawn(async move {
                let files = studio.files();
                let version = studio.version_of(&file).unwrap_or(0);
                let text = files.get(&file).cloned().unwrap_or_default();
                let at = sexp::byte_of_utf16(&text, pos);
                let (facts, error) = match studio.facts_at(&files, &file, at, full).await {
                    Ok(facts) => (facts, None),
                    Err(error) => (Value::Null, Some(error)),
                };
                let _ = direct.send(json(&Reply::Facts { seq, version, facts, error }));
            });
        }
        Request::Echo { line } => studio.echo(&line),
        Request::Ask { thread, message, context } => {
            let (thread, error) = match studio.ask(thread, message.clone(), context) {
                Ok(thread) => (Some(thread), None),
                Err(error) => (None, Some(error)),
            };
            reply(json(&Reply::Asked { thread, message: &message, error }));
        }
        Request::StopThread { thread } => {
            studio.stop_thread(thread);
        }
        Request::Accept { ops } => {
            tokio::spawn(async move { notice(&direct, studio.accept(&ops).await) });
        }
        Request::Reject { op } => notice(&direct, studio.reject(op)),
        Request::AcceptChangeset { changeset } => {
            tokio::spawn(async move { notice(&direct, studio.accept_changeset(changeset).await) });
        }
        Request::Versions { file } => reply(json(&Reply::Versions { file: &file, versions: studio.versions_of(&file) })),
        Request::VersionText { id } => match studio.version_text(id) {
            Some((file, text)) => reply(json(&Reply::VersionText { id, file, text })),
            None => notice(&direct, Err(format!("no version {id}"))),
        },
        Request::Restore { id } => notice(&direct, studio.restore(id)),
    }
}
