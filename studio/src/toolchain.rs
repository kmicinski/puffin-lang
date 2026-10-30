//! The assist lane (docs/STUDIO.md §2.1): one puffincc process per request
//! over a scratch copy of the program, so a fatal error is a reply, never a
//! dead server. Also the compiles the live lane needs (`--repl` units and
//! the prelude) and the preview lane's throwaway runs.
//!
//! `build/puffincc` and `bin/puffin-vm` are black boxes, found by probing:
//! `--assist` and `--serve` are used once they answer, re-probed whenever
//! the binary changes, and until then the studio falls back (a check is a
//! bytecode compile; assists are unavailable). A binary being replaced
//! underneath us fails to start, or dies by a signal; such runs are tried
//! again.

use crate::sexp;
use serde::Serialize;
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime};
use tokio::io::AsyncReadExt;
use tokio::process::Command;

/// A project's files: path relative to the project -> text.
pub type Files = BTreeMap<String, String>;

/// How long one compiler run may take.
const COMPILE_LIMIT: Duration = Duration::from_secs(60);
/// Tries for a run that fails to start or dies by a signal.
const TRIES: u32 = 3;

/// One located message: an error from stdout, a warning from stderr.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Diagnostic {
    /// The project file it names; empty when it names none.
    pub file: String,
    /// 1-based; 0 when unlocated.
    pub line: usize,
    /// "error" or "warning".
    pub severity: &'static str,
    pub message: String,
}

/// A check's answer.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Report {
    pub ok: bool,
    pub diagnostics: Vec<Diagnostic>,
}

impl Report {
    /// The errors, one a line, as an agent reads them.
    pub fn describe(&self) -> String {
        self.diagnostics
            .iter()
            .map(|d| match (d.file.as_str(), d.line) {
                ("", _) | (_, 0) => format!("{}: {}", d.severity, d.message),
                (file, line) => format!("{}: {} [{file}:{line}]", d.severity, d.message),
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn failure(message: impl Into<String>) -> Self {
        Report {
            ok: false,
            diagnostics: vec![Diagnostic { file: String::new(), line: 0, severity: "error", message: message.into() }],
        }
    }
}

/// `msg [file:line]` -> (msg, Some((file, line))).
pub fn located(text: &str) -> (String, Option<(String, usize)>) {
    let text = text.trim_end();
    if let Some(open) = text.rfind(" [")
        && text.ends_with(']')
    {
        let inside = &text[open + 2..text.len() - 1];
        if let Some((file, line)) = inside.rsplit_once(':')
            && let Ok(line) = line.parse::<usize>()
            && !file.is_empty()
        {
            return (text[..open].to_owned(), Some((file.to_owned(), line)));
        }
    }
    (text.to_owned(), None)
}

/// The diagnostics of one puffincc run: its `error: ...` (stdout, or the
/// whole of stdout when it says nothing in that form) unless it succeeded,
/// and every `typecheck warning: ...` on stderr. `[file:line]` names a file
/// by base name; `resolve` maps it to the project's path.
pub fn diagnostics(succeeded: bool, stdout: &str, stderr: &str, resolve: &dyn Fn(&str) -> String) -> Vec<Diagnostic> {
    let mut out = Vec::new();
    let make = |severity: &'static str, text: &str| {
        let (message, at) = located(text);
        let (file, line) = at.map(|(file, line)| (resolve(&file), line)).unwrap_or_default();
        Diagnostic { file, line, severity, message }
    };
    for line in stderr.lines() {
        if let Some(rest) = line.strip_prefix("typecheck warning: ") {
            out.push(make("warning", rest));
        }
    }
    if !succeeded {
        let errors: Vec<&str> = stdout
            .lines()
            .chain(stderr.lines())
            .filter_map(|line| line.strip_prefix("error: "))
            .collect();
        if errors.is_empty() {
            let text = [stdout.trim(), stderr.trim()].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join("\n");
            out.push(make("error", if text.is_empty() { "the compiler failed without a message" } else { &text }));
        } else {
            for error in errors {
                out.push(make("error", error));
            }
        }
    }
    out
}

/// What a probe found, for the binary as it was then.
#[derive(Default)]
struct Probe {
    stamp: Option<SystemTime>,
    works: bool,
}

pub struct Toolchain {
    pub root: PathBuf,
    pub puffincc: PathBuf,
    pub vm: PathBuf,
    /// This run's scratch directory: workspaces, units, the prelude.
    pub scratch: PathBuf,
    counter: AtomicU64,
    assist: Mutex<Probe>,
    serve: Mutex<Probe>,
}

/// The output of one run.
#[derive(Debug, Default)]
pub struct Output {
    pub success: bool,
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub timed_out: bool,
}

/// A scratch copy of the program, removed when dropped.
pub struct Workspace {
    pub dir: PathBuf,
}

impl Drop for Workspace {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

impl Workspace {
    pub fn path(&self, file: &str) -> PathBuf {
        self.dir.join(file)
    }
}

impl Drop for Toolchain {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.scratch);
    }
}

impl Toolchain {
    pub fn new(root: PathBuf) -> std::io::Result<Self> {
        // one directory per toolchain, so studios in one process never share
        static TOOLCHAINS: AtomicU64 = AtomicU64::new(0);
        let n = TOOLCHAINS.fetch_add(1, Ordering::SeqCst);
        let scratch = std::env::temp_dir().join(format!("puffin-studio-{}-{n}", std::process::id()));
        std::fs::create_dir_all(&scratch)?;
        Ok(Self {
            puffincc: std::env::var_os("PUFFIN_STUDIO_PUFFINCC").map_or_else(|| root.join("build/puffincc"), PathBuf::from),
            vm: std::env::var_os("PUFFIN_STUDIO_VM").map_or_else(|| root.join("bin/puffin-vm"), PathBuf::from),
            root,
            scratch,
            counter: AtomicU64::new(0),
            assist: Mutex::new(Probe::default()),
            serve: Mutex::new(Probe::default()),
        })
    }

    /// A fresh directory under the scratch directory.
    pub fn fresh(&self, what: &str) -> PathBuf {
        let n = self.counter.fetch_add(1, Ordering::SeqCst);
        self.scratch.join(format!("{what}-{n}"))
    }

    /// Write `files` to a fresh workspace.
    pub fn workspace(&self, files: &Files) -> Result<Workspace, String> {
        let dir = self.fresh("ws");
        let workspace = Workspace { dir };
        for (path, text) in files {
            let target = workspace.dir.join(path);
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent).map_err(|error| format!("scratch: {error}"))?;
            }
            std::fs::write(&target, text).map_err(|error| format!("scratch: {error}"))?;
        }
        std::fs::create_dir_all(&workspace.dir).map_err(|error| format!("scratch: {error}"))?;
        Ok(workspace)
    }

    /// Run `program` with `args` in `cwd`, `stdin` written to it, within
    /// `limit`; a run that fails to start or dies by a signal is tried again.
    pub async fn run(&self, program: &Path, args: &[String], cwd: &Path, limit: Duration) -> Result<Output, String> {
        let mut last = String::new();
        for attempt in 0..TRIES {
            if attempt > 0 {
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
            let spawned = Command::new(program)
                .args(args)
                .current_dir(cwd)
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .kill_on_drop(true)
                .spawn();
            let mut child = match spawned {
                Ok(child) => child,
                Err(error) => {
                    last = format!("cannot run {}: {error}", program.display());
                    continue;
                }
            };
            let mut stdout = child.stdout.take().expect("piped stdout");
            let mut stderr = child.stderr.take().expect("piped stderr");
            let reading = async {
                let (mut out, mut err) = (Vec::new(), Vec::new());
                let _ = tokio::join!(stdout.read_to_end(&mut out), stderr.read_to_end(&mut err));
                let status = child.wait().await;
                (out, err, status)
            };
            match tokio::time::timeout(limit, reading).await {
                Err(_) => {
                    return Ok(Output { timed_out: true, ..Output::default() });
                }
                Ok((out, err, status)) => {
                    let status = status.map_err(|error| error.to_string())?;
                    let output = Output {
                        success: status.success(),
                        code: status.code(),
                        stdout: String::from_utf8_lossy(&out).into_owned(),
                        stderr: String::from_utf8_lossy(&err).into_owned(),
                        timed_out: false,
                    };
                    // killed by a signal, saying nothing: most likely the
                    // binary was swapped mid-run
                    if output.code.is_none() && output.stdout.is_empty() && attempt + 1 < TRIES {
                        last = "the compiler died by a signal".to_owned();
                        continue;
                    }
                    return Ok(output);
                }
            }
        }
        Err(last)
    }

    async fn puffincc(&self, args: &[String], cwd: &Path) -> Result<Output, String> {
        self.run(&self.puffincc, args, cwd, COMPILE_LIMIT).await
    }

    // ---- Probes ------------------------------------------------------------

    fn stamp(path: &Path) -> Option<SystemTime> {
        std::fs::metadata(path).and_then(|meta| meta.modified()).ok()
    }

    /// Whether `puffincc --assist` answers, for the binary as it is now.
    pub async fn assist_available(&self) -> bool {
        let stamp = Self::stamp(&self.puffincc);
        {
            let probe = self.assist.lock().expect("probe lock");
            if probe.stamp.is_some() && probe.stamp == stamp {
                return probe.works;
            }
        }
        let works = self.probe_assist().await;
        *self.assist.lock().expect("probe lock") = Probe { stamp, works };
        works
    }

    async fn probe_assist(&self) -> bool {
        let Ok(workspace) = self.workspace(&Files::from([("probe.puf".to_owned(), "(define probe 1)\n".to_owned())])) else {
            return false;
        };
        let args = ["--assist", "check", "probe.puf"].map(String::from);
        match self.puffincc(&args, &workspace.dir).await {
            Ok(output) => {
                output.success
                    && serde_json::from_str::<Value>(output.stdout.trim()).is_ok_and(|value| value["ok"] == Value::Bool(true))
            }
            Err(_) => false,
        }
    }

    /// Whether `puffin-vm --serve` runs, for the binary as it is now: it
    /// must take `quit` and exit cleanly.
    pub async fn serve_available(&self) -> bool {
        let stamp = Self::stamp(&self.vm);
        {
            let probe = self.serve.lock().expect("probe lock");
            if probe.stamp.is_some() && probe.stamp == stamp {
                return probe.works;
            }
        }
        let works = self.probe_serve().await;
        *self.serve.lock().expect("probe lock") = Probe { stamp, works };
        works
    }

    async fn probe_serve(&self) -> bool {
        use tokio::io::AsyncWriteExt;
        let Ok(mut child) = Command::new(&self.vm)
            .arg("--serve")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
        else {
            return false;
        };
        if let Some(mut stdin) = child.stdin.take() {
            let _ = stdin.write_all(b"quit\n").await;
        }
        let mut out = String::new();
        if let Some(mut stdout) = child.stdout.take() {
            let _ = tokio::time::timeout(Duration::from_secs(3), stdout.read_to_string(&mut out)).await;
        }
        match tokio::time::timeout(Duration::from_secs(3), child.wait()).await {
            Ok(Ok(status)) => status.success() && !out.contains("usage"),
            _ => false,
        }
    }

    // ---- The assist lane -----------------------------------------------------

    /// Check `entry` of `files`: `--assist check`, or the bytecode compile
    /// when `--assist` is not there.
    pub async fn check(&self, files: &Files, entry: &str) -> Report {
        let workspace = match self.workspace(files) {
            Ok(workspace) => workspace,
            Err(error) => return Report::failure(error),
        };
        let args: Vec<String> = if self.assist_available().await {
            vec!["--assist".into(), "check".into(), entry.into()]
        } else {
            let out = workspace.path("studio-check.pbc");
            vec!["-t".into(), "bytecode".into(), entry.into(), "-o".into(), out.to_string_lossy().into_owned()]
        };
        match self.puffincc(&args, &workspace.dir).await {
            Ok(output) if output.timed_out => Report::failure("the check timed out"),
            Ok(output) => {
                let resolve = |base: &str| resolve(files, entry, base);
                let diagnostics = diagnostics(output.success, &output.stdout, &output.stderr, &resolve);
                Report { ok: output.success, diagnostics }
            }
            Err(error) => Report::failure(error),
        }
    }

    /// Check every entry of `files` (each module as a program of its own),
    /// merging what they report.
    pub async fn check_all(&self, files: &Files, entries: &[String]) -> Report {
        let reports = futures_join(entries.iter().map(|entry| self.check(files, entry))).await;
        let mut merged = Report { ok: true, diagnostics: Vec::new() };
        for report in reports {
            merged.ok &= report.ok;
            for diagnostic in report.diagnostics {
                if !merged.diagnostics.contains(&diagnostic) {
                    merged.diagnostics.push(diagnostic);
                }
            }
        }
        merged
    }

    /// One `--assist OP FILE [POS]` answer as JSON, or the report of why
    /// there is none (the program does not read or check; or no assist).
    pub async fn assist(&self, files: &Files, op: &str, file: &str, pos: Option<usize>) -> Result<Value, Report> {
        if !self.assist_available().await {
            return Err(Report::failure("assists unavailable: this puffincc has no --assist"));
        }
        let workspace = self.workspace(files).map_err(Report::failure)?;
        let mut args = vec!["--assist".to_owned(), op.to_owned(), file.to_owned()];
        if let Some(pos) = pos {
            args.push(pos.to_string());
        }
        let output = self.puffincc(&args, &workspace.dir).await.map_err(Report::failure)?;
        if output.timed_out {
            return Err(Report::failure("the assist timed out"));
        }
        if op == "assists" {
            // one assist a line, then {"done":true}; an error may stop it
            // part way, and what was printed before it stands
            let (assists, done) = assist_lines(&output.stdout);
            let resolve = |base: &str| resolve(files, file, base);
            let stopped = Report { ok: false, diagnostics: diagnostics(done, &output.stdout, &output.stderr, &resolve) };
            if assists.is_empty() && !done {
                return Err(stopped);
            }
            let stopped = (!done).then(|| stopped.describe());
            return Ok(serde_json::json!({ "assists": assists, "complete": done, "stopped": stopped }));
        }
        if !output.success {
            let resolve = |base: &str| resolve(files, file, base);
            return Err(Report { ok: false, diagnostics: diagnostics(false, &output.stdout, &output.stderr, &resolve) });
        }
        serde_json::from_str(output.stdout.trim())
            .map_err(|error| Report::failure(format!("puffincc --assist {op} answered no JSON ({error}): {}", output.stdout.trim())))
    }

    // ---- The live and preview lanes' compiles ----------------------------------

    /// Compile the REPL unit `source` (a path in `dir`) to `out`.
    pub async fn compile_unit(&self, dir: &Path, source: &str, out: &Path) -> Result<Output, String> {
        let args = vec!["--repl".to_owned(), source.to_owned(), "-o".to_owned(), out.to_string_lossy().into_owned()];
        self.puffincc(&args, dir).await
    }

    /// Compile the prelude unit, a session's first, to `out`.
    pub async fn compile_prelude(&self, out: &Path) -> Result<(), String> {
        let args = vec!["--repl-prelude".to_owned(), "-o".to_owned(), out.to_string_lossy().into_owned()];
        let output = self.puffincc(&args, &self.scratch).await?;
        if output.success && out.is_file() {
            Ok(())
        } else {
            Err(format!("cannot compile the prelude unit: {}{}", output.stdout.trim(), output.stderr.trim()))
        }
    }

    /// Compile `entry` of `files` as a whole program and run it on a
    /// throwaway VM within `limit`: the preview lane.
    pub async fn run_program(&self, files: &Files, entry: &str, limit: Duration) -> Value {
        let workspace = match self.workspace(files) {
            Ok(workspace) => workspace,
            Err(error) => return serde_json::json!({ "ok": false, "error": error }),
        };
        let pbc = workspace.path("studio-run.pbc");
        let args = vec!["-t".into(), "bytecode".into(), entry.to_owned(), "-o".into(), pbc.to_string_lossy().into_owned()];
        let compiled = match self.puffincc(&args, &workspace.dir).await {
            Ok(output) => output,
            Err(error) => return serde_json::json!({ "ok": false, "error": error }),
        };
        if !compiled.success {
            let resolve = |base: &str| resolve(files, entry, base);
            let report = Report { ok: false, diagnostics: diagnostics(false, &compiled.stdout, &compiled.stderr, &resolve) };
            return serde_json::json!({ "ok": false, "phase": "compile", "errors": report.describe() });
        }
        let ran = self.run(&self.vm, &[pbc.to_string_lossy().into_owned()], &workspace.dir, limit).await;
        match ran {
            Err(error) => serde_json::json!({ "ok": false, "phase": "run", "error": error }),
            Ok(output) if output.timed_out => {
                serde_json::json!({ "ok": false, "phase": "run", "error": format!("no answer within {} s", limit.as_secs()) })
            }
            Ok(output) => serde_json::json!({
                "ok": output.success,
                "phase": "run",
                "exit": output.code,
                "stdout": clip(&output.stdout, 6000),
                "stderr": clip(&output.stderr, 3000),
            }),
        }
    }
}

/// `--assist assists` output: the assists, one JSON object a line, and
/// whether the final `{"done":true}` came. Lines that are not JSON (an
/// error that stopped the checker) are skipped.
pub fn assist_lines(stdout: &str) -> (Vec<Value>, bool) {
    let mut assists = Vec::new();
    let mut done = false;
    for line in stdout.lines() {
        let Ok(value) = serde_json::from_str::<Value>(line.trim()) else { continue };
        if value["done"] == Value::Bool(true) {
            done = true;
        } else if value["id"].is_string() {
            assists.push(value);
        }
    }
    (assists, done)
}

/// The project file `[base:line]` names: `entry` when its base name is
/// that, else the first file with that base name.
pub fn resolve(files: &Files, entry: &str, base: &str) -> String {
    let base_of = |path: &str| path.rsplit('/').next().unwrap_or(path).to_owned();
    if base_of(entry) == base {
        return entry.to_owned();
    }
    files.keys().find(|path| base_of(path) == base).cloned().unwrap_or_else(|| base.to_owned())
}

/// The modules of `files` no other module requires: what a whole-program
/// check compiles. A program whose files all require each other in a
/// cycle (an error the compiler reports) is checked from every file.
pub fn entries(files: &Files) -> Vec<String> {
    let modules: Vec<&String> = files.keys().filter(|path| path.ends_with(".puf") || path.ends_with(".scm")).collect();
    let mut required = std::collections::BTreeSet::new();
    for path in &modules {
        let dir = path.rsplit_once('/').map_or("", |(dir, _)| dir);
        for target in sexp::requires(&files[*path]) {
            required.insert(normalize(dir, &target));
        }
    }
    let roots: Vec<String> = modules.iter().filter(|path| !required.contains(path.as_str())).map(|path| (*path).clone()).collect();
    if roots.is_empty() { modules.into_iter().cloned().collect() } else { roots }
}

/// `target` relative to directory `dir`, with `.` and `..` resolved.
pub fn normalize(dir: &str, target: &str) -> String {
    let mut parts: Vec<&str> = if dir.is_empty() { Vec::new() } else { dir.split('/').collect() };
    for part in target.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            part => parts.push(part),
        }
    }
    parts.join("/")
}

/// The files `entry` requires, transitively, itself included.
pub fn closure(files: &Files, entry: &str) -> Vec<String> {
    let mut seen = vec![entry.to_owned()];
    let mut at = 0;
    while at < seen.len() {
        let path = seen[at].clone();
        at += 1;
        let Some(text) = files.get(&path) else { continue };
        let dir = path.rsplit_once('/').map_or("", |(dir, _)| dir).to_owned();
        for target in sexp::requires(text) {
            let next = normalize(&dir, &target);
            if !seen.contains(&next) {
                seen.push(next);
            }
        }
    }
    seen
}

/// At most `limit` bytes of `text`, cut at a character boundary.
pub fn clip(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_owned();
    }
    let mut end = limit;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}\n… ({} more bytes)", &text[..end], text.len() - end)
}

/// Await every future, in order. (Checks are tens of milliseconds each.)
async fn futures_join<F: std::future::Future>(futures: impl Iterator<Item = F>) -> Vec<F::Output> {
    let mut out = Vec::new();
    for future in futures {
        out.push(future.await);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages_are_located_by_their_suffix() {
        assert_eq!(
            located("typecheck: car expects 1 arguments, got 2 [a.puf:5]"),
            ("typecheck: car expects 1 arguments, got 2".to_owned(), Some(("a.puf".to_owned(), 5)))
        );
        assert_eq!(located("reader-unterminated-list"), ("reader-unterminated-list".to_owned(), None));
        assert_eq!(located("odd [thing]"), ("odd [thing]".to_owned(), None));
    }

    #[test]
    fn errors_come_from_stdout_and_warnings_from_stderr() {
        let files = Files::from([("main.puf".to_owned(), String::new()), ("lib/m.puf".to_owned(), String::new())]);
        let resolve = |base: &str| resolve(&files, "main.puf", base);
        let found = diagnostics(
            false,
            "error: typecheck: car expects 1 arguments, got 2 [m.puf:2]\n",
            "typecheck warning: match on Expr is not exhaustive: missing Add [main.puf:3]\n",
            &resolve,
        );
        assert_eq!(found.len(), 2);
        assert_eq!((found[0].severity, found[0].file.as_str(), found[0].line), ("warning", "main.puf", 3));
        assert_eq!((found[1].severity, found[1].file.as_str(), found[1].line), ("error", "lib/m.puf", 2));
        // a failure with no `error:` line still says something
        let bare = diagnostics(false, "", "segfault\n", &resolve);
        assert_eq!(bare[0].message, "segfault");
        assert!(diagnostics(true, "", "", &resolve).is_empty());
    }

    #[test]
    fn assists_come_one_a_line_and_stand_when_an_error_stops_them() {
        let out = "{\"id\":\"fill-match\",\"title\":\"Fill match on Expr\",\"source\":\"type\",\"edits\":[]}\n{\"done\":true}\n";
        let (assists, done) = assist_lines(out);
        assert_eq!((assists.len(), done), (1, true));
        let stopped = "{\"id\":\"stub\",\"title\":\"Stub f\",\"source\":\"call-site\",\"edits\":[]}\nerror: typecheck: oops [a.puf:3]\n";
        let (assists, done) = assist_lines(stopped);
        assert_eq!((assists[0]["id"].as_str(), done), (Some("stub"), false));
    }

    #[test]
    fn entries_are_the_modules_nothing_requires() {
        let files = Files::from([
            ("main.puf".to_owned(), "(require \"lib/vec.puf\")\n(dot 1 2)".to_owned()),
            ("lib/vec.puf".to_owned(), "(require \"../util.puf\")\n(provide dot)".to_owned()),
            ("util.puf".to_owned(), "(provide twice)".to_owned()),
            ("scratch.puf".to_owned(), "1".to_owned()),
        ]);
        assert_eq!(entries(&files), ["main.puf", "scratch.puf"]);
        assert_eq!(closure(&files, "main.puf"), ["main.puf", "lib/vec.puf", "util.puf"]);
        assert_eq!(normalize("a/b", "../c.puf"), "a/c.puf");
    }
}
