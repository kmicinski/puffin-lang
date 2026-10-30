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

/// A test's studio over its own project directory, removed when dropped.
struct Fixture(Arc<Studio>);

impl std::ops::Deref for Fixture {
    type Target = Arc<Studio>;
    fn deref(&self) -> &Arc<Studio> {
        &self.0
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0.directory);
    }
}

fn studio(name: &str, files: &[(&str, &str)]) -> Option<Fixture> {
    let root = crate::repository_root();
    if !root.join("build/puffincc").is_file() || !root.join("bin/puffin-vm").is_file() {
        eprintln!("skipped: build/puffincc and bin/puffin-vm are not built");
        return None;
    }
    Some(Fixture(Studio::new(root, project(name, files), "test-token".into()).unwrap()))
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
    studio.evaluate("(define (size [e : Expr]) : Int 1)".into(), Source::buffer("main.puf", 12)).await;
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
    for name in ["list_files", "get_file", "check", "assists_at", "apply_assist", "type_at", "facts_at", "propose_edit", "evaluate", "evaluate_program", "search_docs", "read_doc"] {
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

const EXPR: &str = "\
(define-type Expr (Num Int) (Add Expr Expr))
(define (helper n) (* n 1))
(define (eval-expr [e : Expr]) : Int
  (match e
    [(Num n) (helper n)]
    [(Add a b) (+ (eval-expr a) (eval-expr b))]))
(define example (Add (Num 2) (Num 3)))
(define boom (car '()))
(eval-expr example)
";

/// The session's state of the form of `file` keyed `key` (or with that text).
fn state_of(studio: &Studio, file: &str, key: &str) -> crate::session::FormState {
    let text = studio.text_of(file).unwrap();
    let form = crate::sexp::forms(&text).into_iter().find(|f| f.key() == key || text[f.start..f.end] == *key).expect("the form");
    crate::session::Session::state(&studio.session_view(), file, &text, &form)
}

/// The latest transcript entry showing `line`.
fn entry_of(studio: &Studio, line: &str) -> crate::studio::Entry {
    studio.recent(50).into_iter().rev().find(|entry| entry.line == line).expect("the entry")
}

#[tokio::test]
async fn evaluating_a_form_loads_what_it_needs_and_the_session_knows_it() {
    use crate::repl::{At, Source};
    let Some(studio) = studio("needs", &[("expr.puf", EXPR)]) else { return };
    let last = EXPR.lines().position(|line| line == "(eval-expr example)").unwrap() + 1;
    studio.eval_form("expr.puf", At::Line(last)).await.unwrap();
    let entry = entry_of(&studio, "(eval-expr example)");
    assert_eq!(entry.status.as_deref(), Some("ok"), "{entry:?}");
    assert_eq!(entry.command, format!(",eval expr.puf:{last}"));
    assert_eq!(entry.also, ["helper", "eval-expr", "example"]);
    assert!(entry.out.contains(&("result".to_owned(), "5".to_owned())), "{entry:?}");
    for key in ["define:helper", "define:eval-expr", "define:example", "define-type:Expr"] {
        assert_eq!(state_of(&studio, "expr.puf", key).status, "current", "{key}");
    }
    assert_eq!(state_of(&studio, "expr.puf", "define:boom").status, "absent");
    let evaluated = state_of(&studio, "expr.puf", "(eval-expr example)");
    assert_eq!((evaluated.status, evaluated.result.as_deref()), ("evaluated", Some("5")));

    // an edit makes a loaded form stale; evaluating again reloads only it
    let version = studio.version_of("expr.puf").unwrap();
    let edited = EXPR.replace("(* n 1)", "(* n 10)");
    studio.edit(1, "expr.puf", version, edited).unwrap();
    assert_eq!(state_of(&studio, "expr.puf", "define:helper").status, "stale");
    studio.eval_form("expr.puf", At::Line(last)).await.unwrap();
    let again = studio.recent(1).pop().unwrap();
    assert_eq!(again.also, ["helper"]);
    assert!(again.out.contains(&("result".to_owned(), "50".to_owned())), "{again:?}");
    assert_eq!(state_of(&studio, "expr.puf", "define:helper").status, "current");

    // a failed evaluation leaves the session's forms as they were
    let boom = EXPR.lines().position(|line| line.starts_with("(define boom")).unwrap() + 1;
    studio.eval_form("expr.puf", At::Line(boom)).await.unwrap();
    assert_eq!(studio.recent(1).pop().unwrap().status.as_deref(), Some("error"));
    assert_eq!(state_of(&studio, "expr.puf", "define:boom").status, "absent");
    assert_eq!(state_of(&studio, "expr.puf", "define:helper").status, "current");

    // the prompt redefining a module's name
    studio.evaluate("(define (helper n) n)".into(), Source::Prompt).await;
    assert_eq!(state_of(&studio, "expr.puf", "define:helper").status, "redefined");

    // what the facts say of the form at a point
    let text = studio.text_of("expr.puf").unwrap();
    let at = text.find("(helper n)]").unwrap() + 1;
    let facts = studio.facts_at(&studio.files(), "expr.puf", at, true).await.unwrap();
    assert_eq!(facts["form"]["key"], "define:eval-expr");
    assert_eq!(facts["session"]["status"], "current");

    let t = thread(&studio, Scope { kind: ScopeKind::Program, ..Scope::default() });
    let told = tool(&studio, t, "facts_at", json!({ "file": "expr.puf", "pos": at })).await.unwrap();
    assert_eq!(told["form"]["key"], "define:eval-expr", "{told}");
    assert!(told["note"].as_str().unwrap().contains("not proof"));

    // a reset forgets it all
    studio.reset().await;
    assert!(studio.session_view().files.is_empty());
    assert_eq!(state_of(&studio, "expr.puf", "define:eval-expr").status, "absent");

    // a whole module loads every form
    studio.evaluate(studio.text_of("expr.puf").unwrap(), Source::File { file: "expr.puf".into() }).await;
    assert_eq!(entry_of(&studio, ",load expr.puf").status.as_deref(), Some("error"), "boom fails the whole module");
    assert_eq!(state_of(&studio, "expr.puf", "define:helper").status, "absent");
    let version = studio.version_of("expr.puf").unwrap();
    let text = studio.text_of("expr.puf").unwrap().replace("(define boom (car '()))\n", "");
    studio.edit(1, "expr.puf", version, text.clone()).unwrap();
    studio.evaluate(text, Source::File { file: "expr.puf".into() }).await;
    let loaded = state_of(&studio, "expr.puf", "define:helper");
    assert_eq!((loaded.status, loaded.by), ("current", Some("file")));
    studio.lane.reset().await;
}

#[tokio::test]
async fn a_name_used_before_its_definition_offers_to_load_it() {
    use crate::repl::{At, Source};
    let Some(studio) = studio("fix", &[("expr.puf", EXPR)]) else { return };
    studio.evaluate("(define (twice-helper n) (helper (helper n)))".into(), Source::Prompt).await;
    studio.evaluate("(twice-helper 3)".into(), Source::Prompt).await;
    let failed = entry_of(&studio, "(twice-helper 3)");
    assert_eq!(failed.status.as_deref(), Some("error"));
    assert_eq!(failed.fixes, [crate::studio::Fix { name: "helper".into(), file: "expr.puf".into(), line: 2 }]);
    // the fix is the same path as ⌘↵ on that form
    studio.eval_form("expr.puf", At::Line(2)).await.unwrap();
    studio.evaluate("(twice-helper 3)".into(), Source::Prompt).await;
    assert!(entry_of(&studio, "(twice-helper 3)").out.contains(&("result".to_owned(), "3".to_owned())));
    studio.lane.reset().await;
}

#[tokio::test]
async fn observed_calls_come_back_as_the_record() {
    use crate::repl::At;
    let Some(studio) = studio("observe", &[("expr.puf", EXPR)]) else { return };
    if !studio.toolchain.observe_available().await {
        eprintln!("skipped: this puffincc has no --repl --observe");
        return;
    }
    let last = EXPR.lines().position(|line| line == "(eval-expr example)").unwrap() + 1;
    studio.eval_form("expr.puf", At::Line(last)).await.unwrap();
    assert!(studio.lane.observing());
    studio.refresh_observations().await;
    let view = studio.session_view();
    let eval = view.observed.iter().find(|observed| observed.function == "eval-expr").expect("eval-expr observed");
    assert_eq!(eval.calls, 3);
    assert!(eval.args[0].contains(&"(adt Add)".to_owned()), "{eval:?}");
    assert!(studio.toolchain.observed.lock().unwrap().as_ref().is_some_and(|path| path.is_file()));
    // the facts at the parameter say what it received
    let text = studio.text_of("expr.puf").unwrap();
    let at = text.find("[e : Expr]").unwrap() + 1;
    let facts = studio.facts_at(&studio.files(), "expr.puf", at, true).await.unwrap();
    assert_eq!(facts["function"]["calls"], 3, "{facts}");
    assert_eq!(facts["observed"]["param"], "e", "{facts}");
    // a question about the form carries one line of it
    let line = studio.observed_line("expr.puf", at).await.expect("a line");
    assert!(line.starts_with("eval-expr e: ") && line.ends_with("over 3 calls"), "{line}");
    studio.reset().await;
    assert!(studio.toolchain.observed.lock().unwrap().is_none());
    studio.lane.reset().await;
}
