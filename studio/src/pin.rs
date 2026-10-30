//! Pinned tests (docs/STUDIO.md §5 item 10): a transcript result kept as a
//! check in the project's `tests.puf`, and `,test`, which compiles that file
//! as a whole program and runs it on a throwaway VM.
//!
//! A check compares printed renderings, since a printed value does not
//! always read back as data (an ADT instance prints as `(Num 1)`):
//!
//! ```text
//! (check-printed '(eval-expr example) (eval-expr example) "14")
//! ```
//!
//! `tests.puf` is ordinary Puffin. The studio writes its header: a comment
//! saying what the file is, a `require` of each module the pinned
//! expressions use, and the definition of `check-printed`, which prints one
//! `ok` or `FAIL` line a check and never calls `error`, so one failure does
//! not stop the rest. An expression that fails at run time still ends the
//! run; the checks after it count as not run.
//!
//! Requiring a module runs its top-level expressions once, at the start of
//! the run: their printed output is shown with the results.

use crate::repl;
use crate::session::{self, SessionView};
use crate::sexp;
use crate::studio::{Entry, Studio, checkable};
use crate::toolchain::{Files, Ran};
use serde::Serialize;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// The file pinned checks go to, in the project's directory.
pub const TESTS: &str = "tests.puf";
/// How long one `,test` run may take.
const TEST_LIMIT: Duration = Duration::from_secs(30);

const HEADER: &str = "\
;; tests.puf -- checks pinned from the Puffin Studio transcript.
;;
;; The studio keeps this file: pinning a result (pin, by an evaluation in
;; the transcript, or ,pin N) adds a require for each module the expression
;; uses and one check-printed form, and ,test runs the whole file as a
;; program. It is ordinary Puffin: edit, reorder, or delete checks freely.
;;
;; A check compares printed renderings, as the transcript shows values,
;; since a printed value does not always read back as data: an ADT instance
;; prints as (Num 1).
";

const CHECKER: &str = "\
;; Print ok or FAIL for one check. It never calls error, so one failure
;; does not stop the checks after it.
(define (check-printed quoted value expected)
  (let ([got (check-printed/render value)])
    (if (string=? got expected)
        (println (string-append \"ok   \" (value->string quoted)))
        (println (string-concat (list \"FAIL \" (value->string quoted)
                                      \"\\n  expected \" expected
                                      \"\\n  got      \" got))))))

;; A value as the transcript prints it. In a whole program a required
;; module's constructors print with their module-mangled spelling
;; (Num_expr_40a9c49b); this drops the _module_hash suffix again.
(define (check-printed/render value)
  (let ([text (value->string value)])
    (check-printed/unmangle text 0 0 '())))

(define (check-printed/unmangle text i from pieces)
  (if (>= i (string-length text))
      (string-concat (reverse (cons (substring text from i) pieces)))
      (let ([end (check-printed/suffix text i)])
        (if (< end 0)
            (check-printed/unmangle text (+ i 1) from pieces)
            (check-printed/unmangle text end end (cons (substring text from i) pieces))))))

;; The end of a suffix _module_hhhhhhhh at i (eight hex digits, then a
;; delimiter), or -1.
(define (check-printed/suffix text i)
  (if (eq? (string-byte text i) 95)
      (check-printed/module text (+ i 1) (+ i 1))
      -1))

(define (check-printed/module text j start)
  (cond
    [(>= j (string-length text)) -1]
    [(eq? (string-byte text j) 95) (if (> j start) (check-printed/hash text (+ j 1) 0) -1)]
    [(check-printed/delimiter? text j) -1]
    [else (check-printed/module text (+ j 1) start)]))

(define (check-printed/hash text j count)
  (cond
    [(eq? count 8) (if (or (>= j (string-length text)) (check-printed/delimiter? text j)) j -1)]
    [(>= j (string-length text)) -1]
    [(check-printed/hex? (string-byte text j)) (check-printed/hash text (+ j 1) (+ count 1))]
    [else -1]))

(define (check-printed/hex? b)
  (or (and (>= b 48) (<= b 57)) (and (>= b 97) (<= b 102))))

(define (check-printed/delimiter? text j)
  (let ([b (string-byte text j)])
    (or (eq? b 32) (eq? b 40) (eq? b 41) (eq? b 10) (eq? b 91) (eq? b 93))))
";

/// One `,test` run: how many checks passed, failed, or never ran (the run
/// stopped before them), each that ran, and the line of the check the run
/// stopped in, if it stopped.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct TestRun {
    pub passed: usize,
    pub failed: usize,
    pub not_run: usize,
    pub results: Vec<TestResult>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stopped: Option<usize>,
}

/// One check: its line in tests.puf, whether it passed, the expression it
/// checks, and for a failure what was expected and got.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct TestResult {
    pub line: usize,
    pub ok: bool,
    pub expression: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub detail: String,
}

/// `text` as a Puffin string literal.
pub fn literal(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// The expression an entry evaluated and the result it printed, when it
/// can be pinned: a successful evaluation of one expression, from the
/// prompt or a buffer, that printed a result.
pub fn pinnable(entry: &Entry) -> Result<(String, String), String> {
    if entry.kind != "eval" || !matches!(entry.origin.as_str(), "prompt" | "buffer") {
        return Err("only an evaluation's result can be pinned".to_owned());
    }
    if entry.status.as_deref() != Some("ok") {
        return Err("only a successful evaluation can be pinned".to_owned());
    }
    let expression = entry.line.trim();
    let forms = sexp::forms(expression);
    let [form] = forms.as_slice() else { return Err("pin one expression at a time".to_owned()) };
    if !session::expression(form) {
        return Err("a definition has no result to pin".to_owned());
    }
    let mut results = entry.out.iter().filter(|(stream, _)| stream == "result").map(|(_, text)| text.clone());
    let expected = results.next_back().ok_or("it printed no result to pin")?;
    Ok((expression.to_owned(), expected))
}

/// The check that `expression` prints as `expected`.
pub fn check_form(expression: &str, expected: &str) -> String {
    format!("(check-printed '{expression} {expression} {})", literal(expected))
}

/// The modules `expression` uses: `from` (the module it was evaluated from,
/// if any), then for each name it mentions that no chosen module defines,
/// the module that defines it (a function, value, type, or constructor),
/// preferring the one the session loaded it from.
pub fn modules_for(files: &Files, expression: &str, from: Option<&str>, view: &SessionView) -> Vec<String> {
    let mut chosen: Vec<String> = from.filter(|file| files.contains_key(*file) && *file != TESTS).map(str::to_owned).into_iter().collect();
    let defined = |file: &str| -> Vec<String> {
        let text = &files[file];
        let mut names: Vec<String> = sexp::forms(text).iter().filter(|form| session::definition(form)).filter_map(|form| form.name.clone()).collect();
        names.extend(sexp::constructors(text));
        names
    };
    let candidates: Vec<&String> = files.keys().filter(|file| checkable(file) && *file != TESTS).collect();
    for name in sexp::mentions(expression) {
        if chosen.iter().any(|file| defined(file).contains(&name)) {
            continue;
        }
        let defining: Vec<&&String> = candidates.iter().filter(|file| defined(file).contains(&name)).collect();
        let loaded = defining.iter().find(|file| {
            view.files.get(file.as_str()).is_some_and(|forms| forms.keys().any(|key| key.rsplit(':').next() == Some(name.as_str())))
        });
        if let Some(file) = loaded.or(defining.first()) {
            chosen.push((**file).clone());
        }
    }
    chosen
}

/// tests.puf as `existing` (None: no file yet) with `form` appended, a
/// `require` for each of `modules` it lacks, and the checker if it has none.
pub fn with_pin(existing: Option<&str>, modules: &[String], form: &str) -> String {
    let requires = |missing: &[&String]| missing.iter().map(|module| format!("(require {})\n", literal(module))).collect::<String>();
    let Some(text) = existing.filter(|text| !text.trim().is_empty()) else {
        let missing: Vec<&String> = modules.iter().collect();
        let block = requires(&missing);
        let block = if block.is_empty() { String::new() } else { format!("\n{block}") };
        return format!("{HEADER}{block}\n{CHECKER}\n{form}\n");
    };
    let present: Vec<String> = sexp::requires(text).iter().map(|path| crate::toolchain::normalize("", path)).collect();
    let missing: Vec<&String> = modules.iter().filter(|module| !present.contains(module)).collect();
    let mut text = text.to_owned();
    if !missing.is_empty() {
        let block = requires(&missing);
        let (at, _) = repl::insertion_point(&text);
        if at > 0 {
            text.insert_str(at, &format!("\n{}", block.trim_end()));
        } else {
            let first = sexp::forms(&text).first().map_or(text.len(), |form| form.start);
            text.insert_str(first, &format!("{block}\n"));
        }
    }
    if !text.ends_with('\n') {
        text.push('\n');
    }
    if !sexp::forms(&text).iter().any(|f| f.head.as_deref() == Some("define") && f.name.as_deref() == Some("check-printed")) {
        text.push('\n');
        text.push_str(CHECKER);
    }
    text.push_str(form);
    text.push('\n');
    text
}

/// A run's checks from what it printed: each `ok` or `FAIL` line, in order,
/// is the next `check-printed` form of `tests`; a failure's indented lines
/// say what was expected. The rest of the output is returned as it came.
pub fn results(stdout: &str, tests: &str) -> (TestRun, String) {
    let lines = checks(tests);
    let mut run = TestRun::default();
    let mut rest = String::new();
    for line in stdout.lines() {
        let (ok, expression) = if let Some(expression) = line.strip_prefix("ok ") {
            (true, expression)
        } else if let Some(expression) = line.strip_prefix("FAIL ") {
            (false, expression)
        } else {
            match run.results.last_mut() {
                Some(failed) if !failed.ok && line.starts_with("  ") => {
                    if !failed.detail.is_empty() {
                        failed.detail.push('\n');
                    }
                    failed.detail.push_str(line.trim());
                }
                _ => {
                    rest.push_str(line);
                    rest.push('\n');
                }
            }
            continue;
        };
        // the expression as tests.puf writes it, not as its datum prints
        let (line, expression) = lines.get(run.results.len()).cloned().unwrap_or_else(|| (0, expression.trim().to_owned()));
        run.results.push(TestResult { line, ok, expression, detail: String::new() });
    }
    run.passed = run.results.iter().filter(|result| result.ok).count();
    run.failed = run.results.len() - run.passed;
    run.not_run = lines.len().saturating_sub(run.results.len());
    (run, rest)
}

/// The line of each `check-printed` form of `tests`, in order.
pub fn check_lines(tests: &str) -> Vec<usize> {
    checks(tests).into_iter().map(|(line, _)| line).collect()
}

/// Each `check-printed` form of `tests`: its line, and the expression it
/// quotes, as written.
pub fn checks(tests: &str) -> Vec<(usize, String)> {
    sexp::forms(tests)
        .iter()
        .filter(|form| form.head.as_deref() == Some("check-printed"))
        .map(|form| {
            let body = &tests[form.start..form.end];
            let after = body.find("check-printed").map_or(body.len(), |at| at + "check-printed".len());
            let quoted = sexp::forms(&body[after..]).first().map(|datum| body[after + datum.start..after + datum.end].to_owned()).unwrap_or_default();
            (form.line, quoted.strip_prefix('\'').unwrap_or(&quoted).to_owned())
        })
        .collect()
}

impl Studio {
    /// Pin transcript entry `id`: its expression and printed result become
    /// a check at the end of tests.puf, made if missing. Says what was
    /// pinned.
    pub fn pin(&self, id: u64) -> Result<String, String> {
        let entry = self.entry(id).ok_or_else(|| format!("no transcript entry {id}"))?;
        let (expression, expected) = pinnable(&entry)?;
        let files = self.files();
        let form = check_form(&expression, &expected);
        let existing = files.get(TESTS).cloned();
        if existing.as_deref().is_some_and(|text| text.contains(&form)) {
            return Err(format!("{expression} is pinned already"));
        }
        let from = entry.file.as_deref().filter(|_| entry.origin == "buffer");
        let modules = modules_for(&files, &expression, from, &self.session_view());
        let text = with_pin(existing.as_deref(), &modules, &form);
        self.replace(TESTS, text, "pin", &format!("pinned #{id}"));
        self.echo(&format!(",pin {id}"));
        Ok(format!("pinned {expression} ⇒ {expected} in {TESTS}"))
    }

    /// `,test`: compile tests.puf as a whole program, run it on a throwaway
    /// VM, and show its checks in the transcript, as the entry it returns.
    pub async fn run_tests(self: &Arc<Self>) -> u64 {
        let id = self.begin(Entry { kind: "test", line: ",test".into(), file: Some(TESTS.into()), ..Entry::default() });
        let started = Instant::now();
        let files = self.files();
        let Some(tests) = files.get(TESTS).cloned() else {
            self.finish(id, "error", Some(format!("no {TESTS} yet: pin a result first (pin, by an evaluation, or ,pin N)")), 0);
            return id;
        };
        let ran = self.toolchain.build_and_run(&files, TESTS, TEST_LIMIT).await;
        let ms = || started.elapsed().as_millis() as u64;
        match ran {
            Ran::Unbuilt(report) => {
                // a program with a typed hole does not compile: say which, and what to do
                let hole = report.diagnostics.iter().find(|d| d.severity == "hole" && !report.diagnostics.iter().any(|e| e.severity == "error"));
                let error = match hole {
                    Some(d) => format!(
                        "{} has a typed hole (??) on line {}: {TESTS} cannot compile until it is filled (F8 goes to it; ⌘. lists what fits)",
                        if d.file.is_empty() { TESTS } else { d.file.as_str() },
                        d.line
                    ),
                    None => report.describe(),
                };
                self.finish(id, "compile-error", Some(error), ms())
            }
            Ran::Failed(error) => self.finish(id, "error", Some(error), ms()),
            Ran::Ran(output) => {
                let (mut run, rest) = results(&output.stdout, &tests);
                if !output.success {
                    run.stopped = check_lines(&tests).get(run.results.len()).copied();
                }
                if !rest.is_empty() {
                    self.output(id, "out", rest);
                }
                if !output.stderr.is_empty() {
                    self.output(id, "err", output.stderr.clone());
                }
                let error = (!output.success).then(|| {
                    let total = run.results.len() + run.not_run;
                    let place = run.stopped.map(|line| format!(" in the check on line {line}")).unwrap_or_default();
                    format!("the run stopped{place} (exit {}) after {} of {total} checks", output.code.unwrap_or(-1), run.results.len())
                });
                let status = if output.success && run.failed == 0 && run.not_run == 0 { "ok" } else { "failed" };
                self.finish_entry(id, status, error, ms(), Vec::new(), Some(run));
            }
        }
        id
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn eval(line: &str, results: &[&str]) -> Entry {
        Entry {
            kind: "eval",
            origin: "prompt".into(),
            line: line.into(),
            status: Some("ok".into()),
            out: results.iter().map(|text| ("result".to_owned(), (*text).to_owned())).collect(),
            ..Entry::default()
        }
    }

    #[test]
    fn a_pin_is_one_expression_and_its_printed_result() {
        assert_eq!(pinnable(&eval("(ev example)", &["14"])).unwrap(), ("(ev example)".into(), "14".into()));
        assert!(pinnable(&eval("(define x 1)", &[])).is_err());
        assert!(pinnable(&eval("(f 1) (f 2)", &["1", "2"])).is_err());
        assert!(pinnable(&eval("(println 1)", &[])).is_err());
        let failed = Entry { status: Some("error".into()), ..eval("(f 1)", &["1"]) };
        assert!(pinnable(&failed).is_err());
        assert_eq!(check_form("(f \"a\")", "a \"b\"\nc"), "(check-printed '(f \"a\") (f \"a\") \"a \\\"b\\\"\\nc\")");
    }

    #[test]
    fn pins_require_the_modules_their_names_come_from() {
        let files = Files::from([
            ("expr.puf".to_owned(), "(define-type Expr (Num Int) (Add Expr Expr))\n(define (ev e) 1)\n".to_owned()),
            ("util.puf".to_owned(), "(define (twice x) (* 2 x))\n(define ev 2)\n".to_owned()),
            ("tests.puf".to_owned(), "(define (twice x) x)\n".to_owned()),
        ]);
        let view = SessionView::default();
        assert_eq!(modules_for(&files, "(ev (Add (Num 1) (Num 2)))", None, &view), ["expr.puf"]);
        assert_eq!(modules_for(&files, "(twice (ev 'twice))", None, &view), ["expr.puf", "util.puf"]);
        assert_eq!(modules_for(&files, "(twice 2)", Some("expr.puf"), &view), ["expr.puf", "util.puf"]);
        assert!(modules_for(&files, "(+ 1 2)", None, &view).is_empty());
    }

    #[test]
    fn tests_puf_is_made_then_grows() {
        let made = with_pin(None, &["expr.puf".into()], "(check-printed '(ev x) (ev x) \"1\")");
        assert!(made.starts_with(";; tests.puf"));
        let forms = sexp::forms(&made);
        assert_eq!(forms[0].key(), "require:expr.puf");
        assert_eq!(forms[1].key(), "define:check-printed");
        assert!(made.ends_with("(check-printed '(ev x) (ev x) \"1\")\n"));
        let grown = with_pin(Some(&made), &["expr.puf".into(), "lib/util.puf".into()], "(check-printed 'y y \"2\")");
        let forms = sexp::forms(&grown);
        assert_eq!(forms[1].key(), "require:lib/util.puf");
        assert_eq!(sexp::requires(&grown).len(), 2);
        assert_eq!(forms.iter().filter(|f| f.head.as_deref() == Some("check-printed")).count(), 2);
        // a file of the author's own gets the checker, and its requires first
        let own = with_pin(Some(";; mine\n(define z 1)"), &["a.puf".into()], "(check-printed 'z z \"1\")");
        let forms = sexp::forms(&own);
        assert_eq!((forms[0].key(), forms[1].key()), ("require:a.puf".to_owned(), "define:z".to_owned()));
        assert!(forms.iter().any(|f| f.key() == "define:check-printed"));
    }

    #[test]
    fn a_runs_output_is_its_checks_by_line() {
        let tests = "(require \"e.puf\")\n(define (check-printed q v e) 1)\n(check-printed 'a a \"1\")\n(check-printed '(f 'b) (f 'b) \"2\")\n(check-printed 'c c \"3\")\n";
        let out = "e.puf loaded\nok   a\nFAIL (f (quote b))\n  expected 2\n  got      3\n";
        let (run, rest) = results(out, tests);
        assert_eq!((run.passed, run.failed, run.not_run), (1, 1, 1));
        assert_eq!((run.results[1].line, run.results[1].expression.as_str()), (4, "(f 'b)"));
        assert_eq!(run.results[1].detail, "expected 2\ngot      3");
        assert_eq!(rest, "e.puf loaded\n");
    }
}
