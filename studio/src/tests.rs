//! The studio end to end, over the real compiler and VM of the repository
//! (`build/puffincc`, `bin/puffin-vm`): edits and saves, checks, REPL
//! evaluation with the session's types carried between units, and the
//! assistant's MCP tools with a proposal's round trip, typed holes, the
//! observation lint, extract and rename, pinned tests, and tracing --
//! the author's `,trace` and the assistant's `trace` -- everything
//! but spawning claude. Tests that need a binary that is not built say so and
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
    for name in ["list_files", "get_file", "check", "assists_at", "apply_assist", "type_at", "facts_at", "propose_edit", "evaluate", "evaluate_program", "search_docs", "read_doc", "holes", "lint", "trace"] {
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

#[tokio::test]
async fn a_failed_evaluations_shapes_survive_its_fork() {
    use crate::repl::Source;
    let Some(studio) = studio("spill", &[("calc.puf", "(define (interp e)\n  (match e\n    [`(add ,a ,b) 0]))\n")]) else { return };
    if !studio.toolchain.observe_available().await {
        eprintln!("skipped: this puffincc has no --repl --observe");
        return;
    }
    studio.eval_form("calc.puf", crate::repl::At::Line(1)).await.unwrap();
    studio.evaluate("(interp '(add 1 2))".into(), Source::Prompt).await;
    // no clause matches a mul: the evaluation fails, its fork with it
    studio.evaluate("(interp '(mul 1 2))".into(), Source::Prompt).await;
    assert_eq!(entry_of(&studio, "(interp '(mul 1 2))").status.as_deref(), Some("error"));
    studio.refresh_observations().await;
    let view = studio.session_view();
    let interp = view.observed.iter().find(|observed| observed.function == "interp").expect("interp observed");
    assert!(interp.args[0].contains(&"(list mul 3)".to_owned()), "the failed call's shape was kept: {interp:?}");
    assert!(interp.args[0].contains(&"(list add 3)".to_owned()), "{interp:?}");
    studio.lane.reset().await;
}

const HOLES: &str = "\
(define-type Expr (Num Int) (Add Expr Expr))
(define (depth [e : Expr]) : Int
  (match e
    [(Num n) ??]
    [(Add a b) (+ 1 (depth a))]))
(define (size [e : Expr]) : Int
  (+ 1 ??))
";

#[tokio::test]
async fn holes_are_not_errors_and_have_goals() {
    let Some(studio) = studio("holes", &[("h.puf", HOLES)]) else { return };
    if !studio.toolchain.facts_available().await {
        eprintln!("skipped: this puffincc has no --assist facts");
        return;
    }
    let report = studio.toolchain.check(&studio.files(), "h.puf").await;
    assert!(!report.ok && report.holed() && report.passes(), "{report:?}");
    assert!(report.diagnostics.iter().all(|d| d.severity != "error"), "{report:?}");
    studio.check_files(&["h.puf".to_owned()]).await;
    let holes = studio.holes_view();
    let marks = &holes["h.puf"];
    assert_eq!(marks.items.len(), 2);
    assert_eq!(marks.items[0].goal.as_deref(), Some("Int"), "{marks:?}");
    assert_eq!((marks.items[0].line, marks.items[1].line), (4, 7));

    // the assistant sees them, and the compiler's candidates for one
    let t = thread(&studio, Scope { kind: ScopeKind::Program, ..Scope::default() });
    let listed = tool(&studio, t, "holes", json!({})).await.unwrap();
    assert_eq!(listed["holes"].as_array().unwrap().len(), 2, "{listed}");
    assert_eq!(listed["holes"][0]["goal"], "Int");
    let pos = listed["holes"][0]["pos"].as_u64().unwrap();
    let found = tool(&studio, t, "assists_at", json!({ "file": "h.puf", "pos": pos })).await.unwrap();
    let fills: Vec<&str> = found["assists"].as_array().unwrap().iter().filter(|a| a["id"] == "fill-hole").filter_map(|a| a["title"].as_str()).collect();
    assert!(fills.len() >= 2, "{found}");
    // a fill picked by title; the program keeps its other hole and still passes
    let title = fills.iter().find(|title| title.contains(" n ")).expect("a fill with n");
    let proposed = tool(&studio, t, "apply_assist", json!({ "file": "h.puf", "pos": pos, "id": "fill-hole", "title": title })).await.unwrap();
    assert!(proposed["checks"].as_str().unwrap().contains("hole"), "{proposed}");
    let fork = tool(&studio, t, "get_file", json!({ "file": "h.puf" })).await.unwrap();
    assert!(fork["text"].as_str().unwrap().contains("[(Num n) n]"), "{fork}");
    // the assistant may leave a hole of its own
    let left = tool(&studio, t, "propose_edit", json!({ "file": "h.puf", "old": "(+ 1 (depth a))", "new": "(+ 1 (max ?? ??))", "note": "which branch counts is your call" })).await;
    assert!(left.is_ok(), "{left:?}");
    // and filling them all leaves a program that checks
    studio.accept(&[proposed["proposed"].as_u64().unwrap() as u32]).await.unwrap();
    assert!(studio.text_of("h.puf").unwrap().contains("[(Num n) n]"));
}

#[tokio::test]
async fn a_selection_extracts_and_a_name_renames() {
    let text = "(define (g a b c d)\n  (+ a (* b (- c d))))\n";
    let Some(studio) = studio("extract", &[("g.puf", text), ("user.puf", "(require \"g.puf\")\n(g 1 2 3 4)\n")]) else { return };
    if !studio.toolchain.assist_available().await {
        return;
    }
    let start = text.find("(* b").unwrap();
    let end = start + "(* b (- c d))".len();
    let t = thread(&studio, Scope { kind: ScopeKind::Program, ..Scope::default() });
    let found = tool(&studio, t, "assists_at", json!({ "file": "g.puf", "pos": start, "end": end })).await.unwrap();
    let extract = found["assists"].as_array().unwrap().iter().find(|a| a["id"] == "extract").expect("extract offered").clone();
    assert!(extract["title"].as_str().unwrap().contains("(extracted b c d)"), "{extract}");
    let proposed = tool(&studio, t, "apply_assist", json!({ "file": "g.puf", "pos": start, "end": end, "id": "extract" })).await.unwrap();
    assert!(proposed["proposed"].is_u64(), "{proposed}");

    if !studio.toolchain.rename_available().await {
        eprintln!("skipped: this puffincc has no --assist rename");
        return;
    }
    let at = text.find("a b c d").unwrap();
    let edits = studio.toolchain.rename(&studio.files(), "g.puf", at, "x").await.unwrap();
    assert_eq!(edits.as_array().unwrap().len(), 2, "{edits}");
    assert!(studio.toolchain.rename(&studio.files(), "g.puf", 0, "x").await.is_err());
    assert!(studio.toolchain.rename(&studio.files(), "g.puf", at, "two words").await.is_err());
    // a top-level name other modules use: the rename says they still do
    let note = crate::web::importers_note(&studio.files(), "g.puf", text.find("g a").unwrap()).expect("a note");
    assert!(note.contains("user.puf"), "{note}");
    assert!(crate::web::importers_note(&studio.files(), "g.puf", at).is_none());
}

const SHAPES: &str = "\
(define (ev e)
  (match e
    [`(num ,n) n]
    [`(add ,a ,b) (+ (ev a) (ev b))]))
";

#[tokio::test]
async fn shapes_no_clause_handles_are_linted() {
    use crate::repl::Source;
    let Some(studio) = studio("lint", &[("s.puf", SHAPES)]) else { return };
    if !studio.toolchain.observe_available().await || !studio.toolchain.lint_available().await {
        eprintln!("skipped: this puffincc cannot observe or lint");
        return;
    }
    // the session runs a version of ev with a catch-all; the module's has none
    studio.evaluate("(define (ev e) (match e [`(num ,n) n] [`(add ,a ,b) (+ (ev a) (ev b))] [_ 0]))".into(), Source::Prompt).await;
    studio.evaluate("(ev '(add (num 1) (neg 2)))".into(), Source::Prompt).await;
    assert_eq!(entry_of(&studio, "(ev '(add (num 1) (neg 2)))").status.as_deref(), Some("ok"));
    // the refresh lints every module
    studio.refresh_observations().await;
    let lint = studio.lint_view();
    let findings = &lint["s.puf"].items;
    assert_eq!(findings.len(), 1, "{findings:?}");
    assert!(findings[0].message.contains("neg"), "{findings:?}");
    assert_eq!((findings[0].line, findings[0].source.as_str()), (2, "observed"));
    let t = thread(&studio, Scope { kind: ScopeKind::Program, ..Scope::default() });
    let told = tool(&studio, t, "lint", json!({})).await.unwrap();
    assert_eq!(told["findings"][0]["file"], "s.puf", "{told}");
    // the facts of the form list it; the fix is the observed add-missing-cases
    let facts = studio.facts_at(&studio.files(), "s.puf", 20, false).await.unwrap();
    assert_eq!(facts["lint"].as_array().unwrap().len(), 1, "{facts}");
    let fix = studio.toolchain.assist(&studio.files(), "assists", "s.puf", Some(findings[0].pos + 1)).await.unwrap();
    assert!(fix["assists"].as_array().unwrap().iter().any(|a| a["id"] == "add-missing-cases" && a["source"] == "observed"), "{fix}");
    // a reset forgets the record, and with it the findings
    studio.reset().await;
    assert!(studio.lint_view().is_empty());
    studio.lane.reset().await;
}

const PINNED: &str = "\
(define-type Expr (Num Int) (Add Expr Expr))
(define (eval-expr [e : Expr]) : Int
  (match e [(Num n) n] [(Add a b) (+ (eval-expr a) (eval-expr b))]))
(define example (Add (Num 2) (Num 12)))
(println \"expr.puf loaded\")
";

#[tokio::test]
async fn results_pin_as_checks_and_test_runs_them() {
    use crate::repl::Source;
    let Some(studio) = studio("pin", &[("expr.puf", PINNED)]) else { return };
    studio.evaluate(PINNED.into(), Source::File { file: "expr.puf".into() }).await;
    for line in ["(eval-expr example)", "(Add (Num 1) (Num 2))", "\"a \\\"quoted\\\" string\"", "(define z 1)"] {
        studio.evaluate(line.into(), Source::Prompt).await;
    }
    for line in ["(eval-expr example)", "(Add (Num 1) (Num 2))"] {
        let entry = entry_of(&studio, line);
        assert_eq!(entry.status.as_deref(), Some("ok"), "{entry:?}");
    }
    let id = |line: &str| entry_of(&studio, line).id;
    studio.pin(id("(eval-expr example)")).unwrap();
    studio.pin(id("(Add (Num 1) (Num 2))")).unwrap();
    studio.pin(id("\"a \\\"quoted\\\" string\"")).unwrap();
    assert!(studio.pin(id("(eval-expr example)")).unwrap_err().contains("already"));
    assert!(studio.pin(id("(define z 1)")).is_err());
    let tests = studio.text_of("tests.puf").unwrap();
    assert_eq!(crate::sexp::requires(&tests), ["expr.puf"]);
    assert!(tests.contains("(check-printed '(eval-expr example) (eval-expr example) \"14\")"), "{tests}");
    assert_eq!(studio.recent(1).pop().unwrap().line, ",pin 7".replace('7', &id("\"a \\\"quoted\\\" string\"").to_string()));

    // the author breaks one check; ,test says which, by line
    let version = studio.version_of("tests.puf").unwrap();
    studio.edit(1, "tests.puf", version, tests.replace("\"14\")", "\"15\")")).unwrap();
    let ran = studio.entry(studio.run_tests().await).expect("a test entry");
    let run = ran.tests.clone().unwrap_or_else(|| panic!("checks: {ran:?}\n{}", studio.text_of("tests.puf").unwrap()));
    assert_eq!((run.passed, run.failed, run.not_run), (2, 1, 0), "{ran:?}");
    let failed = run.results.iter().find(|result| !result.ok).unwrap();
    assert_eq!(failed.expression, "(eval-expr example)");
    let text = studio.text_of("tests.puf").unwrap();
    assert!(crate::sexp::line_of(&text, text.find("\"15\"").unwrap()) == failed.line, "{run:?}");
    assert!(failed.detail.contains("got      14"), "{failed:?}");
    // the module's own top-level effect ran once, ahead of the checks
    assert!(ran.out.iter().any(|(stream, text)| stream == "out" && text == "expr.puf loaded\n"), "{:?}", ran.out);
    assert_eq!(ran.status.as_deref(), Some("failed"));
    studio.lane.reset().await;
}

const TRACED: &str = "\
(define-type Expr (Num Int) (Add Expr Expr))
(define (eval-expr [e : Expr]) : Int
  (match e [(Num n) n] [(Add a b) (+ (eval-expr a) (eval-expr b))]))
(define example (Add (Num 2) (Add (Num 3) (Num 4))))
(define (count-down n) (if (eq? n 0) 'done (count-down (- n 1))))
";

/// What entry `entry` printed on stdout.
fn printed(entry: &crate::studio::Entry) -> String {
    entry.out.iter().filter(|(stream, _)| stream == "out").map(|(_, text)| text.as_str()).collect()
}

async fn can_trace(studio: &Studio) -> bool {
    let can = studio.toolchain.trace_available().await && studio.toolchain.observe_available().await;
    if !can {
        eprintln!("skipped: this puffincc cannot trace (--repl --trace) or observe");
    }
    can
}

#[tokio::test]
async fn traced_calls_print_nested_and_untrace_stops_them() {
    use crate::repl::{At, Source};
    let Some(studio) = studio("trace", &[("expr.puf", TRACED)]) else { return };
    if !can_trace(&studio).await {
        return;
    }
    // ,trace evaluates the define again at once, by ⌘↵'s path
    studio.trace(vec!["eval-expr".into()], true).await;
    let traced = studio.recent(1).pop().unwrap();
    assert_eq!((traced.command.as_str(), traced.status.as_deref()), (",trace eval-expr", Some("ok")), "{traced:?}");
    assert_eq!(studio.traced_names(), ["eval-expr"]);
    assert_eq!(state_of(&studio, "expr.puf", "define:eval-expr").status, "current");
    studio.eval_form("expr.puf", At::Line(4)).await.unwrap();
    studio.evaluate("(eval-expr example)".into(), Source::Prompt).await;
    let entry = entry_of(&studio, "(eval-expr example)");
    let out = printed(&entry);
    assert!(out.starts_with("> (eval-expr (Add (Num 2) (Add (Num 3) (Num 4))))\n| > (eval-expr (Num 2))\n| < 2\n"), "{out}");
    assert!(out.contains("| | > (eval-expr (Num 3))\n"), "{out}");
    assert!(out.ends_with("< 9\n"), "{out}");
    assert!(entry.out.contains(&("result".to_owned(), "9".to_owned())));

    // a name nothing defines yet is traced from its next definition
    studio.trace(vec!["twice".into()], true).await;
    assert!(printed(&studio.recent(1).pop().unwrap()).contains("its next definition is traced"));
    studio.evaluate("(define (twice x) (* 2 x))".into(), Source::Prompt).await;
    studio.evaluate("(twice 4)".into(), Source::Prompt).await;
    assert_eq!(printed(&entry_of(&studio, "(twice 4)")), "> (twice 4)\n< 8\n");
    // one the prompt defined is evaluated again from its text, traced or not
    studio.evaluate("(define (thrice x) (* 3 x))".into(), Source::Prompt).await;
    studio.trace(vec!["thrice".into()], true).await;
    assert_eq!(studio.recent(1).pop().unwrap().command, ",trace thrice");
    studio.evaluate("(thrice 2)".into(), Source::Prompt).await;
    assert_eq!(printed(&entry_of(&studio, "(thrice 2)")), "> (thrice 2)\n< 6\n");
    studio.trace(vec!["thrice".into()], false).await;
    studio.evaluate("(thrice 2)".into(), Source::Prompt).await;
    assert_eq!(printed(&entry_of(&studio, "(thrice 2)")), "");

    // ,untrace evaluates it again untraced
    studio.trace(vec!["eval-expr".into()], false).await;
    assert_eq!(studio.recent(1).pop().unwrap().command, ",untrace eval-expr");
    studio.evaluate("(eval-expr example)".into(), Source::Prompt).await;
    assert_eq!(printed(&entry_of(&studio, "(eval-expr example)")), "");

    // only a function define traces
    studio.trace(vec!["example".into()], true).await;
    let refused = studio.recent(1).pop().unwrap();
    assert_eq!(refused.status.as_deref(), Some("error"));
    assert!(refused.error.unwrap().contains("not a function define"));
    // a reset keeps the set: the next load traces again
    studio.reset().await;
    assert_eq!(studio.traced_names(), ["twice"]);
    studio.evaluate("(define (twice x) (+ x x))".into(), Source::Prompt).await;
    studio.evaluate("(twice 5)".into(), Source::Prompt).await;
    assert_eq!(printed(&entry_of(&studio, "(twice 5)")), "> (twice 5)\n< 10\n");
    studio.lane.reset().await;
}

#[tokio::test]
async fn the_assistant_traces_without_touching_the_session() {
    use crate::repl::Source;
    let Some(studio) = studio("trace-tool", &[("expr.puf", TRACED)]) else { return };
    if !can_trace(&studio).await {
        return;
    }
    let t = thread(&studio, Scope { kind: ScopeKind::Program, ..Scope::default() });
    let traced = tool(&studio, t, "trace", json!({ "names": ["eval-expr"], "expr": "(eval-expr example)" })).await.unwrap();
    assert_eq!((traced["ok"].as_bool(), traced["calls"].as_u64()), (Some(true), Some(5)), "{traced}");
    assert!(traced["trace"].as_str().unwrap().starts_with("> (eval-expr (Add (Num 2)"), "{traced}");
    assert_eq!(traced["results"], json!(["9"]));
    // nothing was kept: not the definitions, not the traced set
    assert_eq!(state_of(&studio, "expr.puf", "define:eval-expr").status, "absent");
    assert!(studio.traced_names().is_empty());
    studio.evaluate("(eval-expr (Num 1))".into(), Source::Prompt).await;
    assert_eq!(entry_of(&studio, "(eval-expr (Num 1))").status.as_deref(), Some("error"));

    // a proposal is traced before the author accepts it
    let proposed = tool(&studio, t, "propose_edit", json!({ "file": "expr.puf", "old": "[(Num n) n]", "new": "[(Num n) (* 10 n)]", "note": "tens" })).await;
    assert!(proposed.is_ok(), "{proposed:?}");
    let fixed = tool(&studio, t, "trace", json!({ "names": ["eval-expr"], "expr": "(eval-expr example)" })).await.unwrap();
    assert_eq!(fixed["results"], json!(["90"]), "{fixed}");

    // a long trace comes back cut, and counted
    let long = tool(&studio, t, "trace", json!({ "names": "count-down", "expr": "(count-down 300)" })).await.unwrap();
    assert_eq!((long["lines"].as_u64(), long["calls"].as_u64()), (Some(602), Some(301)), "{long}");
    assert_eq!(long["trace"].as_str().unwrap().lines().count(), crate::trace::TRACE_LINES);
    assert!(long["cut"].as_str().unwrap().contains("402 more lines"), "{long}");

    // a function the prompt defined is traced from the session's text, and stays untraced there
    studio.evaluate("(define (sq x) (* x x))".into(), Source::Prompt).await;
    let squared = tool(&studio, t, "trace", json!({ "names": ["sq"], "expr": "(sq 3)" })).await.unwrap();
    assert_eq!(squared["trace"], "> (sq 3)\n< 9\n", "{squared}");
    studio.evaluate("(sq 3)".into(), Source::Prompt).await;
    assert_eq!(printed(&entry_of(&studio, "(sq 3)")), "");

    // what evaluate refuses, trace refuses
    assert!(tool(&studio, t, "trace", json!({ "names": ["count-down"], "expr": "(system \"ls\")" })).await.unwrap_err().contains("refuses"));
    assert!(tool(&studio, t, "trace", json!({ "names": ["nope"], "expr": "1" })).await.unwrap_err().contains("nothing defines nope"));
    studio.lane.reset().await;
}
