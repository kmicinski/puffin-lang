//! The studio end to end, over the real compiler and VM of the repository
//! (`build/puffincc`, `bin/puffin-vm`): edits and saves, checks, REPL
//! evaluation with the session's types carried between units, and the
//! assistant's MCP tools with a proposal's round trip -- everything but
//! spawning claude. Tests that need a binary that is not built say so and
//! pass.

use crate::review::{Scope, ScopeKind, Status};
use crate::studio::{Refused, Studio};
use axum::http::HeaderMap;
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::Arc;

const MAIN: &str = "(define-type Expr\n  (Num Int)\n  (Add Expr Expr))\n\n(define (ev [e : Expr]) : Int\n  (match e\n    [(Num n) n]\n    [(Add a b) (+ (ev a) (ev b))]))\n\n(define (twice x) (* 2 x))\n";

/// A fresh project directory holding `files`.
fn project(name: &str, files: &[(&str, &str)]) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("puffin-studio-test-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    for (path, text) in files {
        std::fs::write(dir.join(path), text).unwrap();
    }
    dir
}

fn studio(name: &str, files: &[(&str, &str)]) -> Option<Arc<Studio>> {
    let root = crate::repository_root();
    if !root.join("build/puffincc").is_file() || !root.join("bin/puffin-vm").is_file() {
        eprintln!("skipped: build/puffincc and bin/puffin-vm are not built");
        return None;
    }
    Some(Studio::new(root, project(name, files), "test-token".into()).unwrap())
}

#[tokio::test]
async fn edits_need_their_base_and_save_writes_them() {
    let Some(studio) = studio("edit", &[("main.puf", MAIN)]) else { return };
    let version = studio.version_of("main.puf").unwrap();
    let edited = format!("{MAIN}(twice 21)\n");
    let next = studio.edit(1, "main.puf", version, edited.clone()).unwrap();
    assert!(matches!(studio.edit(2, "main.puf", version, "x".into()), Err(Refused::Stale { .. })));
    assert_eq!(studio.edit(1, "nope.puf", 0, "x".into()), Err(Refused::NoFile));
    assert!(next > version);
    studio.save().unwrap();
    assert_eq!(std::fs::read_to_string(studio.directory.join("main.puf")).unwrap(), edited);
    let versions = studio.versions_of("main.puf");
    assert_eq!(versions.iter().map(|v| v.origin).collect::<Vec<_>>(), ["open", "save"]);
    // a restore is a new version
    studio.restore(versions[0].id).unwrap();
    assert_eq!(studio.text_of("main.puf").unwrap(), MAIN);
    assert_eq!(studio.versions_of("main.puf").last().unwrap().origin, "restore");
}

#[tokio::test]
async fn checks_locate_errors_and_warnings() {
    let broken = "(define-type T (A Int) (B))\n(define (f [t : T]) : Int\n  (match t [(A n) n]))\n(car 1 2)\n";
    let Some(studio) = studio("check", &[("main.puf", broken), ("ok.puf", "(define x 1)\n")]) else { return };
    let report = studio.toolchain.check(&studio.files(), "main.puf").await;
    assert!(!report.ok);
    let error = report.diagnostics.iter().find(|d| d.severity == "error").expect("an error");
    assert_eq!((error.file.as_str(), error.line), ("main.puf", 4), "{report:?}");
    assert!(report.diagnostics.iter().any(|d| d.severity == "warning" && d.line == 2), "{report:?}");
    assert!(studio.toolchain.check(&studio.files(), "ok.puf").await.ok);
}

/// What entry `id` printed, as (stream, text).
fn output_of(studio: &Studio, line: &str) -> (Option<String>, Vec<(String, String)>) {
    let entry = studio.recent(50).into_iter().rev().find(|entry| entry.line == line).expect("the entry");
    (entry.status, entry.out)
}

#[tokio::test]
async fn the_live_session_keeps_definitions_and_types_and_survives_errors() {
    let Some(studio) = studio("repl", &[("main.puf", MAIN)]) else { return };
    use crate::repl::Source;
    studio.evaluate("(define-type Shape (Circle Int) (Sq Int))".into(), Source::Prompt).await;
    studio.evaluate("(define (area s) (match s [(Circle r) (* 3 (* r r))] [(Sq x) (* x x)]))".into(), Source::Prompt).await;
    // a later unit matches on the earlier unit's type: its declaration rides along
    studio.evaluate("(area (Sq 3))".into(), Source::Prompt).await;
    let (status, out) = output_of(&studio, "(area (Sq 3))");
    assert_eq!(status.as_deref(), Some("ok"));
    assert!(out.contains(&("result".to_owned(), "9".to_owned())), "{out:?}");
    // a runtime error leaves the session as it was
    studio.evaluate("(error 'boom)".into(), Source::Prompt).await;
    assert_eq!(output_of(&studio, "(error 'boom)").0.as_deref(), Some("error"));
    // a unit that does not compile never reaches it
    studio.evaluate("(car 1 2)".into(), Source::Prompt).await;
    assert_eq!(output_of(&studio, "(car 1 2)").0.as_deref(), Some("compile-error"));
    studio.evaluate("(area (Circle 1))".into(), Source::Prompt).await;
    assert!(output_of(&studio, "(area (Circle 1))").1.contains(&("result".to_owned(), "3".to_owned())));
    // a form from a buffer brings its module's types
    studio.evaluate("(define (size [e : Expr]) : Int 1)".into(), Source::Buffer { file: "main.puf".into(), line: 12 }).await;
    assert_eq!(output_of(&studio, "(define (size [e : Expr]) : Int 1)").0.as_deref(), Some("ok"));
    studio.evaluate("(size (Num 3))".into(), Source::Prompt).await;
    assert!(output_of(&studio, "(size (Num 3))").1.contains(&("result".to_owned(), "1".to_owned())));
    // a whole module loads as one unit; then its definitions are there
    studio.evaluate(MAIN.into(), Source::File { file: "main.puf".into() }).await;
    assert_eq!(output_of(&studio, ",load main.puf").0.as_deref(), Some("ok"));
    studio.evaluate("(ev (Add (Num 1) (Num (twice 2))))".into(), Source::Prompt).await;
    assert!(output_of(&studio, "(ev (Add (Num 1) (Num (twice 2))))").1.contains(&("result".to_owned(), "5".to_owned())));
    // the assistant's evaluate keeps nothing
    let tried = studio.try_expression("(define kept 1) (+ kept 1)").await.unwrap();
    assert_eq!(tried["results"], json!(["2"]), "{tried}");
    studio.evaluate("kept".into(), Source::Prompt).await;
    assert_ne!(output_of(&studio, "kept").0.as_deref(), Some("ok"));
    assert!(studio.try_expression("(system \"ls\")").await.is_err());
    studio.lane.reset().await;
}

/// A thread with a turn in progress at `scope`, as a question would make.
fn thread(studio: &Studio, scope: Scope) -> u32 {
    let mut review = studio.review.lock().unwrap();
    let id = review.new_thread("test".into());
    review.open_changeset(id, "test".into(), scope);
    id
}

async fn tool(studio: &Arc<Studio>, thread: u32, name: &str, arguments: Value) -> Result<Value, String> {
    crate::mcp::call(studio, Some(thread), name, &arguments).await
}

#[tokio::test]
async fn mcp_lists_tools_and_admits_only_its_token() {
    let Some(studio) = studio("mcp", &[("main.puf", MAIN)]) else { return };
    let body = json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" }).to_string();
    let refused = crate::mcp::handle(&studio, HeaderMap::new(), body.clone()).await;
    assert_eq!(refused.status(), 401);
    let mut headers = HeaderMap::new();
    headers.insert("authorization", "Bearer test-token".parse().unwrap());
    let answer = crate::mcp::handle(&studio, headers, body).await;
    let bytes = axum::body::to_bytes(answer.into_body(), 1 << 20).await.unwrap();
    let listed: Value = serde_json::from_slice(&bytes).unwrap();
    let names: Vec<&str> = listed["result"]["tools"].as_array().unwrap().iter().filter_map(|t| t["name"].as_str()).collect();
    for name in ["list_files", "get_file", "check", "assists_at", "apply_assist", "type_at", "propose_edit", "evaluate", "evaluate_program", "search_docs", "read_doc"] {
        assert!(names.contains(&name), "{name} in {names:?}");
    }
}

#[tokio::test]
async fn a_proposal_is_checked_scoped_forked_accepted_and_goes_stale() {
    let Some(studio) = studio("propose", &[("main.puf", MAIN)]) else { return };
    let form = "(define (twice x) (* 2 x))";
    let near = MAIN.find(form).unwrap();
    let t = thread(&studio, Scope { kind: ScopeKind::Form, file: "main.puf".into(), region: Some(form.into()), near });

    // refused: fails the check
    let failing = tool(&studio, t, "propose_edit", json!({ "file": "main.puf", "old": "(* 2 x)", "new": "(car 2 x)", "note": "" })).await;
    assert!(failing.unwrap_err().contains("fails the check"));
    // refused: outside the form
    let outside = tool(&studio, t, "propose_edit", json!({ "file": "main.puf", "old": "[(Num n) n]", "new": "[(Num n) 0]", "note": "" })).await;
    assert!(outside.unwrap_err().contains("outside the form"));
    // proposed: it checks and stays in scope; the text is untouched
    let proposed = tool(&studio, t, "propose_edit", json!({ "file": "main.puf", "old": "(* 2 x)", "new": "(+ x x)", "note": "adds instead" })).await.unwrap();
    let id = proposed["proposed"].as_u64().unwrap() as u32;
    assert_eq!(studio.text_of("main.puf").unwrap(), MAIN);
    // the thread reads its fork; the program runs as the fork
    let read = tool(&studio, t, "get_file", json!({ "file": "main.puf" })).await.unwrap();
    assert!(read["text"].as_str().unwrap().contains("(+ x x)"));
    let ran = tool(&studio, t, "evaluate_program", json!({ "file": "main.puf" })).await.unwrap();
    assert_eq!(ran["ok"], json!(true), "{ran}");

    // accepted: applied, re-checked, and a version
    studio.accept(&[id]).await.unwrap();
    assert!(studio.text_of("main.puf").unwrap().contains("(define (twice x) (+ x x))"));
    assert_eq!(studio.versions_of("main.puf").last().unwrap().origin, "accept");
    assert!(studio.accept(&[id]).await.is_err());

    // a second proposal whose text the author then edits goes stale
    let t2 = thread(&studio, Scope { kind: ScopeKind::Program, ..Scope::default() });
    let next = tool(&studio, t2, "propose_edit", json!({ "file": "main.puf", "old": "(+ x x)", "new": "(* x 2)", "note": "" })).await.unwrap();
    let next = next["proposed"].as_u64().unwrap() as u32;
    let version = studio.version_of("main.puf").unwrap();
    let text = studio.text_of("main.puf").unwrap().replace("(+ x x)", "(- x 0)");
    studio.edit(1, "main.puf", version, text).unwrap();
    let view = studio.review_view();
    let op = view.ops.iter().find(|op| op.op.id == next).unwrap();
    assert!(op.stale && op.op.status == Status::Pending);
    assert!(studio.accept(&[next]).await.unwrap_err().contains("cannot be accepted"));
    studio.reject(next).unwrap();

    // a new module, in program scope, by an empty old text
    let made = tool(&studio, t2, "propose_edit", json!({ "file": "util.puf", "old": "", "new": "(provide inc)\n(define (inc x) (+ x 1))", "note": "a helper" })).await.unwrap();
    studio.accept(&[made["proposed"].as_u64().unwrap() as u32]).await.unwrap();
    assert!(studio.text_of("util.puf").unwrap().contains("(define (inc x)"));
}

#[tokio::test]
async fn the_compilers_assists_become_proposals() {
    let Some(studio) = studio("assist", &[("main.puf", "(define-type Expr (Num Int) (Add Expr Expr))\n(define (ev [e : Expr]) : Int\n  (match e))\n")]) else { return };
    if !studio.toolchain.assist_available().await {
        eprintln!("skipped: this puffincc has no --assist");
        return;
    }
    let text = studio.text_of("main.puf").unwrap();
    let pos = text.find("(match e)").unwrap() + 1;
    let t = thread(&studio, Scope { kind: ScopeKind::Program, ..Scope::default() });
    let found = tool(&studio, t, "assists_at", json!({ "file": "main.puf", "pos": pos })).await.unwrap();
    assert!(found["assists"].as_array().unwrap().iter().any(|a| a["id"] == "fill-match"), "{found}");
    let proposed = tool(&studio, t, "apply_assist", json!({ "file": "main.puf", "pos": pos, "id": "fill-match" })).await.unwrap();
    assert!(proposed["proposed"].is_u64(), "{proposed}");
    let fork = tool(&studio, t, "get_file", json!({ "file": "main.puf" })).await.unwrap();
    assert!(fork["text"].as_str().unwrap().contains("[(Num n)"), "{fork}");
}
