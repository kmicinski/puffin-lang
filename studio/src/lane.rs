//! The live lane: one VM session that survives errors (docs/STUDIO.md §2.2).
//!
//! The real session is `puffin-vm --serve`: commands on stdin, one a line
//! (`load PATH`, `try PATH`, `quit`); program output on stdout and stderr;
//! each REPL result one stdout line `\x1fR` + the value; and every command
//! ending in one stdout line `\x1fOK`, `\x1fERR <status>` or `\x1fINT`. The
//! session forks per evaluation, so the pid we spawned exits after the
//! first success: the lane watches its pipes, never the pid, and interrupts
//! with SIGINT to the process group it fixed at spawn.
//!
//! A session's first unit is the prelude. When the compiler can observe
//! (`--repl --observe`, docs/STUDIO.md §3.1), the observer
//! (`studio/observe.puf`) is the second, and the session is observing: the
//! units compiled for it may report their arguments, and traced functions
//! print their calls (its runtime does both). Otherwise observation and
//! tracing are off for that session.
//!
//! Until `--serve` exists the lane replays: every loaded unit runs again,
//! in a fresh `puffin-vm --session`, before the new one; a marker unit
//! between them says where the new unit's output starts. Effects repeat
//! and results print as plain output, but definitions accumulate and an
//! error leaves the session as it was.

use crate::toolchain::Toolchain;
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::sync::Mutex as StdMutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::{Mutex, mpsc};

/// The byte that starts every framing line, always at the start of a line
/// (serve mode ends a partial line of output first). A result's own
/// newlines travel as 0x1e.
pub const MARK: u8 = 0x1f;

/// What a session's stdout carries, read frame by frame.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Frame {
    /// Program output, as it came (a line, or part of one).
    Out(String),
    /// A REPL result, rendered.
    Result(String),
    /// The command ended.
    Done(Status),
    /// The replay marker: what came before was replayed.
    Replayed,
}

/// How a command ended.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "status", content = "detail", rename_all = "kebab-case")]
pub enum Status {
    Ok,
    /// The unit failed; the session is as it was. The VM's status.
    Err(String),
    Interrupted,
    /// The session ended: it must be started again.
    Dead(String),
}

/// The replay marker unit prints this line.
const REPLAY_MARK: &str = "\u{1f}STUDIO-REPLAYED";

/// Splits a session's stdout into frames. Bytes go in as they arrive;
/// whole frames come out, and output with no newline yet comes out at the
/// end of each chunk, so long-running programs show progress.
#[derive(Default)]
pub struct Framer {
    /// Output not yet passed on (a partial UTF-8 character at most, after
    /// a chunk).
    pending: Vec<u8>,
    /// The framing line being read, after its 0x1f.
    marker: Option<Vec<u8>>,
    /// Whether the last byte read ended a line (or none came yet): a frame
    /// starts only at the start of a line.
    mid_line: bool,
}

impl Framer {
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<Frame> {
        let mut out = Vec::new();
        for &byte in bytes {
            if let Some(marker) = &mut self.marker {
                if byte == b'\n' {
                    let line = String::from_utf8_lossy(marker).into_owned();
                    self.marker = None;
                    out.push(frame_of(&line));
                } else {
                    marker.push(byte);
                }
            } else if byte == MARK && !self.mid_line {
                self.flush_into(&mut out, true);
                self.marker = Some(Vec::new());
            } else {
                self.pending.push(byte);
                self.mid_line = byte != b'\n';
                if byte == b'\n' {
                    self.flush_into(&mut out, true);
                }
            }
        }
        self.flush_into(&mut out, false);
        out
    }

    /// Pass on pending output; unless `all`, keep a partial character back.
    fn flush_into(&mut self, out: &mut Vec<Frame>, all: bool) {
        if self.pending.is_empty() {
            return;
        }
        let keep = if all {
            0
        } else {
            match std::str::from_utf8(&self.pending) {
                Ok(_) => 0,
                Err(error) if error.error_len().is_none() => self.pending.len() - error.valid_up_to(),
                Err(_) => 0,
            }
        };
        let cut = self.pending.len() - keep;
        if cut == 0 {
            return;
        }
        let text = String::from_utf8_lossy(&self.pending[..cut]).into_owned();
        self.pending.drain(..cut);
        match out.last_mut() {
            Some(Frame::Out(previous)) => previous.push_str(&text),
            _ => out.push(Frame::Out(text)),
        }
    }

    /// Whatever is left when the stream ends.
    pub fn finish(&mut self) -> Vec<Frame> {
        let mut out = Vec::new();
        if let Some(marker) = self.marker.take() {
            self.pending.push(MARK);
            self.pending.extend(marker);
        }
        self.flush_into(&mut out, true);
        out
    }
}

/// One framing line (after its 0x1f) as a frame.
fn frame_of(line: &str) -> Frame {
    let line = line.strip_suffix('\r').unwrap_or(line);
    if let Some(value) = line.strip_prefix('R') {
        // newlines inside a result travel as 0x1e
        return Frame::Result(value.replace('\u{1e}', "\n"));
    }
    match line {
        "OK" => Frame::Done(Status::Ok),
        "INT" => Frame::Done(Status::Interrupted),
        _ if line == &REPLAY_MARK[1..] => Frame::Replayed,
        _ => match line.strip_prefix("ERR") {
            Some(status) => Frame::Done(Status::Err(status.trim().to_owned())),
            // not ours: program output that happened to hold the byte
            None => Frame::Out(format!("\u{1f}{line}\n")),
        },
    }
}

/// What the lane is doing, as the status strip shows it.
#[derive(Clone, Debug, Serialize)]
pub struct LaneStatus {
    /// "idle" (no session yet), "starting", "ready", "busy", or "failed".
    pub state: &'static str,
    /// "serve" or "replay".
    pub mode: &'static str,
    pub detail: String,
}

/// Where a command's output goes, frame by frame: stdout's frames, and
/// stderr's lines as `(true, line)`.
pub type Sink<'a> = &'a mut (dyn FnMut(Output) + Send);

#[derive(Clone, Debug)]
pub enum Output {
    Out(String),
    Err(String),
    Result(String),
}

/// The `--serve` session process.
struct Served {
    stdin: ChildStdin,
    stdout: ChildStdout,
    stderr: mpsc::UnboundedReceiver<String>,
    framer: Framer,
    /// Kept so the first pid is reaped; it exits after the first success.
    _child: Child,
}

/// The replaying stand-in: the units loaded so far.
struct Replay {
    units: Vec<PathBuf>,
    marker: PathBuf,
}

enum Session {
    Served(Served),
    Replay(Replay),
}

pub struct Lane {
    toolchain: Arc<Toolchain>,
    session: Mutex<Option<Session>>,
    /// The session's process group, for interrupting without the lock.
    group: StdMutex<Option<i32>>,
    status: StdMutex<LaneStatus>,
    on_status: Box<dyn Fn(LaneStatus) + Send + Sync>,
    /// The session running has the observer loaded.
    observing: AtomicBool,
    /// Counts the sessions started, so state learned of one is not taken
    /// for the next.
    generation: AtomicU64,
}

impl Lane {
    pub fn new(toolchain: Arc<Toolchain>, on_status: Box<dyn Fn(LaneStatus) + Send + Sync>) -> Self {
        Self {
            toolchain,
            session: Mutex::new(None),
            group: StdMutex::new(None),
            status: StdMutex::new(LaneStatus { state: "idle", mode: "serve", detail: String::new() }),
            on_status,
            observing: AtomicBool::new(false),
            generation: AtomicU64::new(0),
        }
    }

    /// Whether the session running has the observer: units for it may be
    /// compiled with `--observe`.
    pub fn observing(&self) -> bool {
        self.observing.load(Ordering::SeqCst)
    }

    /// Which session is running (or ran last).
    pub fn generation(&self) -> u64 {
        self.generation.load(Ordering::SeqCst)
    }

    /// Start the session if none runs, so the next unit knows whether it
    /// is observing.
    pub async fn ensure(&self) -> Result<(), String> {
        let mut session = self.session.lock().await;
        if session.is_none() {
            match self.start().await {
                Ok(started) => *session = Some(started),
                Err(error) => {
                    self.set_status("failed", self.mode_name(None), error.clone());
                    return Err(error);
                }
            }
        }
        Ok(())
    }

    /// `try` unit `pbc` against the running session, quietly: no status
    /// changes, and no session started for it. None when no session runs.
    pub async fn try_quietly(&self, pbc: &Path, sink: Sink<'_>) -> Option<Status> {
        let mut session = self.session.lock().await;
        let status = match session.as_mut()? {
            Session::Served(served) => served.command("try", pbc, sink).await,
            Session::Replay(replay) => self.replay(replay, pbc, false, sink).await,
        };
        if let Status::Dead(why) = &status {
            *session = None;
            *self.group.lock().expect("group lock") = None;
            self.observing.store(false, Ordering::SeqCst);
            self.set_status("idle", self.status().mode, format!("the session ended: {why}"));
        }
        Some(status)
    }

    pub fn status(&self) -> LaneStatus {
        self.status.lock().expect("status lock").clone()
    }

    fn set_status(&self, state: &'static str, mode: &'static str, detail: impl Into<String>) {
        let status = LaneStatus { state, mode, detail: detail.into() };
        *self.status.lock().expect("status lock") = status.clone();
        (self.on_status)(status);
    }

    /// Run unit `pbc`: `load` it as the session's next state, or `try` it
    /// and keep nothing. Starts the session if none runs.
    pub async fn run(&self, pbc: &Path, keep: bool, sink: Sink<'_>) -> Status {
        let mut session = self.session.lock().await;
        if session.is_none() {
            match self.start().await {
                Ok(started) => *session = Some(started),
                Err(error) => {
                    self.set_status("failed", self.mode_name(None), error.clone());
                    return Status::Dead(error);
                }
            }
        }
        let mode = self.mode_name(session.as_ref());
        self.set_status("busy", mode, "");
        let status = match session.as_mut().expect("a session") {
            Session::Served(served) => served.command(if keep { "load" } else { "try" }, pbc, sink).await,
            Session::Replay(replay) => self.replay(replay, pbc, keep, sink).await,
        };
        if let Status::Dead(why) = &status {
            *session = None;
            *self.group.lock().expect("group lock") = None;
            self.observing.store(false, Ordering::SeqCst);
            self.set_status("idle", mode, format!("the session ended: {why}"));
        } else {
            self.set_status("ready", mode, if mode == "replay" { REPLAY_NOTE } else { "" });
        }
        status
    }

    fn mode_name(&self, session: Option<&Session>) -> &'static str {
        match session {
            Some(Session::Replay(_)) => "replay",
            Some(Session::Served(_)) => "serve",
            None => self.status().mode,
        }
    }

    /// A new session: `--serve` when the VM has it, else a replay; the
    /// prelude is its first unit either way, and the observer its second
    /// when the compiler can observe.
    async fn start(&self) -> Result<Session, String> {
        let serve = self.toolchain.serve_available().await;
        let mode = if serve { "serve" } else { "replay" };
        self.generation.fetch_add(1, Ordering::SeqCst);
        self.observing.store(false, Ordering::SeqCst);
        self.set_status("starting", mode, "");
        let prelude = self.toolchain.fresh("prelude").with_extension("pbc");
        self.toolchain.compile_prelude(&prelude).await?;
        let observer = self.compile_observer().await;
        if !serve {
            let marker_source = self.toolchain.fresh("marker").with_extension("puf");
            std::fs::write(&marker_source, format!("(display \"{REPLAY_MARK}\\n\")\n")).map_err(|error| error.to_string())?;
            let marker = marker_source.with_extension("pbc");
            let source = marker_source.to_string_lossy().into_owned();
            let output = self.toolchain.compile_unit(&self.toolchain.scratch, &source, &marker, false).await?;
            if !output.success {
                return Err(format!("cannot compile the replay marker: {}", output.stdout.trim()));
            }
            self.set_status("ready", mode, REPLAY_NOTE);
            let mut units = vec![prelude];
            if let Some(observer) = observer {
                units.push(observer);
                self.observing.store(true, Ordering::SeqCst);
            }
            return Ok(Session::Replay(Replay { units, marker }));
        }
        let mut child = Command::new(&self.toolchain.vm)
            .arg("--serve")
            .current_dir(&self.toolchain.scratch)
            .process_group(0)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| format!("cannot start {} --serve: {error}", self.toolchain.vm.display()))?;
        let group = child.id().map(|id| id as i32);
        *self.group.lock().expect("group lock") = group;
        let stdin = child.stdin.take().expect("piped stdin");
        let stdout = child.stdout.take().expect("piped stdout");
        let stderr = child.stderr.take().expect("piped stderr");
        let (lines, receiver) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            let mut reader = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = reader.next_line().await {
                if lines.send(line).is_err() {
                    break;
                }
            }
        });
        let mut served = Served { stdin, stdout, stderr: receiver, framer: Framer::default(), _child: child };
        let mut prelude_output = String::new();
        let mut sink = |output: Output| {
            if let Output::Out(text) | Output::Err(text) = output {
                prelude_output.push_str(&text);
            }
        };
        match served.command("load", &prelude, &mut sink).await {
            Status::Ok => {}
            other => return Err(format!("the prelude did not load ({other:?}): {}", prelude_output.trim())),
        }
        // an observer that does not load leaves the session unobserved
        if let Some(observer) = observer
            && served.command("load", &observer, &mut |_| {}).await == Status::Ok
        {
            self.observing.store(true, Ordering::SeqCst);
            // a failed evaluation's observations die with its fork: the
            // observer spills new shapes to a file as it sees them
            if let Some(spill) = self.compile_spill_to().await {
                let _ = served.command("load", &spill, &mut |_| {}).await;
            }
        }
        Ok(Session::Served(served))
    }

    /// Where the observer spills its record as new shapes arrive.
    pub fn spill_path(&self) -> PathBuf {
        self.toolchain.scratch.join("spill.sexp")
    }

    /// The unit `(#%observe-spill-to! "SPILL")`.
    async fn compile_spill_to(&self) -> Option<PathBuf> {
        let spill = self.spill_path();
        let _ = std::fs::remove_file(&spill);
        let source = self.toolchain.fresh("spill-to").with_extension("puf");
        let path = spill.to_string_lossy().replace('\\', "\\\\").replace('"', "\\\"");
        std::fs::write(&source, format!("(#%observe-spill-to! \"{path}\")\n")).ok()?;
        let out = source.with_extension("pbc");
        let compiled = self.toolchain.compile_unit(&self.toolchain.scratch, &source.to_string_lossy(), &out, false).await.ok()?;
        (compiled.success && out.is_file()).then_some(out)
    }

    /// The observer unit, when the compiler can observe and it compiles.
    async fn compile_observer(&self) -> Option<PathBuf> {
        let source = self.toolchain.root.join("studio/observe.puf");
        if !source.is_file() || !self.toolchain.observe_available().await {
            return None;
        }
        let out = self.toolchain.fresh("observer").with_extension("pbc");
        let compiled = self.toolchain.compile_unit(&self.toolchain.scratch, &source.to_string_lossy(), &out, false).await.ok()?;
        (compiled.success && out.is_file()).then_some(out)
    }

    async fn replay(&self, replay: &mut Replay, pbc: &Path, keep: bool, sink: Sink<'_>) -> Status {
        let mut command = Command::new(&self.toolchain.vm);
        command.arg("--session").args(&replay.units).arg(&replay.marker).arg(pbc);
        command
            .current_dir(&self.toolchain.scratch)
            .process_group(0)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => return Status::Dead(format!("cannot start {}: {error}", self.toolchain.vm.display())),
        };
        *self.group.lock().expect("group lock") = child.id().map(|id| id as i32);
        let mut stdout = child.stdout.take().expect("piped stdout");
        let stderr = child.stderr.take().expect("piped stderr");
        let mut errors = BufReader::new(stderr).lines();
        let mut framer = Framer::default();
        let mut replayed = false;
        let mut buffer = [0u8; 8192];
        let mut stderr_open = true;
        let mut early: Vec<String> = Vec::new();
        loop {
            tokio::select! {
                read = stdout.read(&mut buffer) => match read {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        for frame in framer.feed(&buffer[..n]) {
                            match frame {
                                Frame::Replayed => replayed = true,
                                Frame::Out(text) if replayed => sink(Output::Out(text)),
                                Frame::Result(text) if replayed => sink(Output::Result(text)),
                                _ => {}
                            }
                        }
                    }
                },
                line = errors.next_line(), if stderr_open => match line {
                    Ok(Some(line)) if replayed => sink(Output::Err(format!("{line}\n"))),
                    Ok(Some(line)) => early.push(line),
                    _ => stderr_open = false,
                },
            }
        }
        for frame in framer.finish() {
            if let Frame::Out(text) = frame
                && replayed
            {
                sink(Output::Out(text));
            }
        }
        while stderr_open {
            match errors.next_line().await {
                Ok(Some(line)) if replayed => sink(Output::Err(format!("{line}\n"))),
                Ok(Some(line)) => early.push(line),
                _ => stderr_open = false,
            }
        }
        let status = child.wait().await;
        // stderr read before the marker came on stdout: the pipes race, so
        // a failure shows it (the replayed units succeeded once already)
        if status.as_ref().is_ok_and(|status| !status.success()) {
            for line in early.drain(..) {
                sink(Output::Err(format!("{line}\n")));
            }
        }
        *self.group.lock().expect("group lock") = None;
        use std::os::unix::process::ExitStatusExt;
        match status {
            Ok(status) if status.success() => {
                if keep {
                    replay.units.push(pbc.to_path_buf());
                }
                Status::Ok
            }
            Ok(status) if status.signal() == Some(libc::SIGINT) => Status::Interrupted,
            Ok(status) if !replayed => Status::Err(format!(
                "an earlier unit failed on replay (exit {})",
                status.code().map_or_else(|| "by a signal".to_owned(), |code| code.to_string())
            )),
            Ok(status) => Status::Err(status.code().map_or_else(|| "killed".to_owned(), |code| code.to_string())),
            Err(error) => Status::Dead(error.to_string()),
        }
    }

    /// SIGINT to the session's process group: the evaluation in flight
    /// stops, the session stays.
    pub fn interrupt(&self) -> Result<(), String> {
        let group = *self.group.lock().expect("group lock");
        let Some(group) = group else { return Err("nothing is running".to_owned()) };
        signal(group, libc::SIGINT)
    }

    /// End the session; the next command starts a fresh one.
    pub async fn reset(&self) {
        if let Some(group) = *self.group.lock().expect("group lock") {
            let _ = signal(group, libc::SIGKILL);
        }
        let mut session = self.session.lock().await;
        if let Some(Session::Served(mut served)) = session.take() {
            let _ = served.stdin.write_all(b"quit\n").await;
        }
        *self.group.lock().expect("group lock") = None;
        self.observing.store(false, Ordering::SeqCst);
        let mode = self.status().mode;
        self.set_status("idle", mode, "reset: the next evaluation starts a fresh session");
    }
}

const REPLAY_NOTE: &str = "puffin-vm has no --serve yet: each evaluation replays the session's units";

fn signal(group: i32, signal: i32) -> Result<(), String> {
    // SAFETY: kill(2) with a negative pid signals that process group.
    let sent = unsafe { libc::kill(-group, signal) };
    if sent == 0 { Ok(()) } else { Err(format!("cannot signal the session: {}", std::io::Error::last_os_error())) }
}

impl Served {
    /// Send `VERB PATH` and pass on what comes back until its last frame.
    async fn command(&mut self, verb: &str, path: &Path, sink: Sink<'_>) -> Status {
        let line = format!("{verb} {}\n", path.display());
        if let Err(error) = self.stdin.write_all(line.as_bytes()).await.and(self.stdin.flush().await) {
            return Status::Dead(format!("cannot write to the session: {error}"));
        }
        let mut buffer = [0u8; 8192];
        let status = loop {
            tokio::select! {
                read = self.stdout.read(&mut buffer) => match read {
                    Ok(0) | Err(_) => {
                        for frame in self.framer.finish() {
                            if let Frame::Out(text) = frame { sink(Output::Out(text)); }
                        }
                        break Status::Dead("the VM closed its output".to_owned());
                    }
                    Ok(n) => {
                        let mut done = None;
                        for frame in self.framer.feed(&buffer[..n]) {
                            match frame {
                                Frame::Out(text) => sink(Output::Out(text)),
                                Frame::Result(text) => sink(Output::Result(text)),
                                Frame::Done(status) => done = Some(status),
                                Frame::Replayed => {}
                            }
                        }
                        if let Some(status) = done { break status; }
                    }
                },
                Some(line) = self.stderr.recv() => sink(Output::Err(format!("{line}\n"))),
            }
        };
        // stderr written just before the last frame
        tokio::time::sleep(Duration::from_millis(5)).await;
        while let Ok(line) = self.stderr.try_recv() {
            sink(Output::Err(format!("{line}\n")));
        }
        status
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed_all(chunks: &[&[u8]]) -> Vec<Frame> {
        let mut framer = Framer::default();
        let mut out: Vec<Frame> = chunks.iter().flat_map(|chunk| framer.feed(chunk)).collect();
        out.extend(framer.finish());
        // adjacent output merges, as a reader would show it
        let mut merged: Vec<Frame> = Vec::new();
        for frame in out.drain(..) {
            match (merged.last_mut(), frame) {
                (Some(Frame::Out(previous)), Frame::Out(text)) => previous.push_str(&text),
                (_, frame) => merged.push(frame),
            }
        }
        merged
    }

    #[test]
    fn frames_split_output_results_and_ends() {
        let frames = feed_all(&[b"hi\n\x1fR42\n\x1fOK\n"]);
        assert_eq!(frames, [Frame::Out("hi\n".into()), Frame::Result("42".into()), Frame::Done(Status::Ok)]);
        let frames = feed_all(&[b"\x1fERR 1\n"]);
        assert_eq!(frames, [Frame::Done(Status::Err("1".into()))]);
        assert_eq!(feed_all(&[b"\x1fINT\n"]), [Frame::Done(Status::Interrupted)]);
    }

    /// Frames start lines: serve mode ends a partial line before one, and a
    /// 0x1f inside a line of output is output.
    #[test]
    fn frames_only_start_lines() {
        let frames = feed_all(&[b"no newline\n\x1fR(1 2)\n\x1fOK\n"]);
        assert_eq!(frames, [Frame::Out("no newline\n".into()), Frame::Result("(1 2)".into()), Frame::Done(Status::Ok)]);
        let frames = feed_all(&[b"a\x1fOK\n\x1fOK\n"]);
        assert_eq!(frames, [Frame::Out("a\x1fOK\n".into()), Frame::Done(Status::Ok)]);
        assert_eq!(feed_all(&[b"\x1fERR signal 11\n"]), [Frame::Done(Status::Err("signal 11".into()))]);
    }

    #[test]
    fn newlines_inside_a_result_come_back() {
        assert_eq!(feed_all(&[b"\x1fRline one\x1eline two\n"]), [Frame::Result("line one\nline two".into())]);
    }

    /// Bytes arrive in arbitrary chunks: inside a frame, inside a UTF-8
    /// character.
    #[test]
    fn frames_survive_any_chunking() {
        let whole = "λx\n\x1fR\"é\"\n\x1fOK\n".as_bytes();
        for cut in 0..whole.len() {
            let frames = feed_all(&[&whole[..cut], &whole[cut..]]);
            assert_eq!(
                frames,
                [Frame::Out("λx\n".into()), Frame::Result("\"é\"".into()), Frame::Done(Status::Ok)],
                "cut at {cut}"
            );
        }
    }

    #[test]
    fn partial_output_comes_out_per_chunk() {
        let mut framer = Framer::default();
        assert_eq!(framer.feed(b"..."), [Frame::Out("...".into())]);
        assert_eq!(framer.feed(b"\xce"), []);
        assert_eq!(framer.feed(b"\xbb\n"), [Frame::Out("λ\n".into())]);
        // a 0x1f after a partial line passed on is still mid-line
        assert_eq!(framer.feed(b"x"), [Frame::Out("x".into())]);
        assert_eq!(framer.feed(b"\x1fR1\n"), [Frame::Out("\x1fR1\n".into())]);
    }

    #[test]
    fn the_replay_marker_and_stray_bytes() {
        let frames = feed_all(&[b"old\n\x1fSTUDIO-REPLAYED\nnew\n"]);
        assert_eq!(frames, [Frame::Out("old\n".into()), Frame::Replayed, Frame::Out("new\n".into())]);
        assert_eq!(feed_all(&[b"\x1fweird\n"]), [Frame::Out("\x1fweird\n".into())]);
    }
}
