//! Running the `claude` CLI headless (`claude -p`), for the two agents that
//! work on the program through this server's own `/mcp` tools: the
//! assistant (agent.rs) and the voice builder (builder.rs).
//!
//! A run is told where the tools are by an MCP config file (mode 0600: it
//! holds the bearer token), gets no built-in tools at all, and streams its
//! progress as stream-json, one event a line, which the caller reads as it
//! comes, each event taken apart into the `Part`s a reader acts on. Its
//! process is handed to the caller while it runs, so that it can be
//! stopped. The quick, one-request calls go to the Messages API instead
//! (claude_api.rs).

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::process::{Child, Command};

/// The MCP server's name, which prefixes its tools: `mcp__puffin__get_file`.
pub const SERVER: &str = "puffin";
/// Refused even if a setting would allow them.
pub const DENIED: &str = "Bash,Write,Edit,NotebookEdit,Skill";

/// Why runs cannot start here, if they cannot.
pub fn unavailable() -> Option<String> {
    which("claude").is_none().then(|| "no `claude` on PATH: install Claude Code to ask the assistant".to_owned())
}

fn which(binary: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|paths| std::env::split_paths(&paths).map(|directory| directory.join(binary)).find(|path| path.is_file()))
}

/// The MCP config file of a run: our loopback `/mcp`, the bearer token and
/// `headers` (which say whom the server is serving). Removed when dropped.
pub struct McpConfig {
    pub path: PathBuf,
}

impl McpConfig {
    /// Write it as `name` in the temporary directory, mode 0600.
    pub fn write(name: &str, port: u16, token: &str, mut headers: Value) -> Result<Self, String> {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        headers["Authorization"] = json!(format!("Bearer {token}"));
        let config = json!({ "mcpServers": { SERVER: {
            "type": "http",
            "url": format!("http://127.0.0.1:{port}/mcp"),
            "headers": headers,
        }}});
        let path = std::env::temp_dir().join(name);
        std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&path)
            .and_then(|mut file| file.write_all(config.to_string().as_bytes()))
            .map_err(|error| format!("cannot write the MCP config: {error}"))?;
        Ok(Self { path })
    }
}

impl Drop for McpConfig {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// What one run is told.
pub struct Run<'a> {
    pub prompt: &'a str,
    /// Appended to Claude Code's own system prompt.
    pub system: &'a str,
    pub config: &'a Path,
    /// None: the CLI's own default.
    pub model: Option<&'a str>,
    pub effort: &'a str,
    pub max_turns: u32,
    /// The claude session to go on with.
    pub resume: Option<&'a str>,
    /// Load every tool up front: deferred behind tool search, a direct call
    /// to one fails ("No such tool available").
    pub eager_tools: bool,
}

impl Run<'_> {
    pub fn arguments(&self) -> Vec<String> {
        let mut args: Vec<String> = vec![
            "-p".into(), self.prompt.into(),
            "--output-format".into(), "stream-json".into(), "--verbose".into(),
            // partial events show "thinking…" and stream the reply as it comes
            "--include-partial-messages".into(),
            "--effort".into(), self.effort.into(),
            "--disable-slash-commands".into(),
            // only the operator's own settings: none of the repository's
            "--setting-sources".into(), "user".into(),
            "--mcp-config".into(), self.config.to_string_lossy().into_owned(), "--strict-mcp-config".into(),
            // no built-in tools at all: the studio's are the only ones
            "--tools".into(), "".into(),
            "--allowedTools".into(), format!("mcp__{SERVER}"),
            "--disallowedTools".into(), DENIED.into(),
            "--max-turns".into(), self.max_turns.to_string(),
            "--append-system-prompt".into(), self.system.into(),
            // keep the machine's details out of the system prompt, for its cache
            "--exclude-dynamic-system-prompt-sections".into(),
        ];
        if let Some(model) = self.model {
            args.extend(["--model".to_owned(), model.to_owned()]);
        }
        if let Some(session) = self.resume {
            args.extend(["--resume".to_owned(), session.to_owned()]);
        }
        args
    }

    /// Run it in `directory`, handing each stream-json event to `each` as
    /// it comes. The process is given to `hold` while it runs (so it can be
    /// killed) and taken back with `release` once its output ends. Err:
    /// it could not start.
    pub async fn stream(
        &self,
        directory: &Path,
        hold: impl FnOnce(Child),
        release: impl FnOnce() -> Option<Child>,
        mut each: impl FnMut(&Value),
    ) -> Result<Ended, String> {
        let mut command = Command::new("claude");
        command.args(self.arguments()).current_dir(directory).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
        if self.eager_tools {
            command.env("ENABLE_TOOL_SEARCH", "false");
        }
        let mut child = command.spawn().map_err(|error| format!("could not start claude: {error}"))?;
        let stdout = child.stdout.take().expect("piped stdout");
        let mut stderr = child.stderr.take().expect("piped stderr");
        hold(child);
        let stderr = tokio::spawn(async move {
            let mut text = String::new();
            let _ = stderr.read_to_string(&mut text).await;
            text
        });
        let mut lines = BufReader::new(stdout).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if let Ok(event) = serde_json::from_str::<Value>(&line) {
                each(&event);
            }
        }
        let status = match release() {
            Some(mut child) => child.wait().await.ok(),
            None => None,
        };
        Ok(Ended { success: status.is_some_and(|status| status.success()), stderr: stderr.await.unwrap_or_default() })
    }
}

/// How a run's process ended.
pub struct Ended {
    /// It exited with status 0.
    pub success: bool,
    pub stderr: String,
}

impl Ended {
    /// The last line it wrote to stderr: why it failed, usually.
    pub fn last_words(&self) -> Option<&str> {
        self.stderr.lines().rev().find(|line| !line.trim().is_empty())
    }
}

/// What one stream-json event of a run says, in the parts a reader acts
/// on. Events of a subagent (inside a parent's tool use) are not the run's
/// own and say nothing here.
pub enum Part<'a> {
    /// The claude session the run is (to be resumed by the next).
    Session(&'a str),
    /// The run began, on `model`.
    Init { model: &'a str },
    /// A partial event of the reply as it streams (`content_block_start`,
    /// `_delta`, `_stop`).
    Partial(&'a Value),
    /// A finished text block of the reply, trimmed; never empty.
    Text(&'a str),
    /// A tool call, its name without the server's prefix.
    ToolUse { id: &'a str, name: &'a str, input: &'a Value },
    /// A tool's answer.
    ToolResult { id: &'a str, text: String, error: bool },
    /// The run's last event: its outcome, cost and usage.
    Result(&'a Value),
}

/// The parts of stream-json event `event`, in order.
pub fn parts(event: &Value) -> Vec<Part<'_>> {
    let mut out = Vec::new();
    if !event["parent_tool_use_id"].is_null() {
        return out;
    }
    let blocks = || event["message"]["content"].as_array().into_iter().flatten();
    match event["type"].as_str() {
        Some("system") if event["subtype"] == "init" => {
            out.extend(event["session_id"].as_str().map(Part::Session));
            out.push(Part::Init { model: event["model"].as_str().unwrap_or("") });
        }
        Some("stream_event") => out.push(Part::Partial(&event["event"])),
        Some("assistant") => {
            for block in blocks() {
                match block["type"].as_str() {
                    Some("text") => out.extend(block["text"].as_str().map(str::trim).filter(|text| !text.is_empty()).map(Part::Text)),
                    Some("tool_use") => out.push(Part::ToolUse { id: block["id"].as_str().unwrap_or(""), name: tool_name(block), input: &block["input"] }),
                    _ => {}
                }
            }
        }
        Some("user") => {
            for block in blocks().filter(|block| block["type"] == "tool_result") {
                let error = block["is_error"].as_bool().unwrap_or(false);
                out.push(Part::ToolResult { id: block["tool_use_id"].as_str().unwrap_or(""), text: result_text(block), error });
            }
        }
        Some("result") => {
            out.extend(event["session_id"].as_str().map(Part::Session));
            out.push(Part::Result(event));
        }
        _ => {}
    }
    out
}

/// A tool's name without its MCP server's prefix.
pub fn tool_name(block: &Value) -> &str {
    let name = block["name"].as_str().unwrap_or("tool");
    name.rsplit("__").next().unwrap_or(name)
}

/// A `tool_result` block's text.
fn result_text(block: &Value) -> String {
    match &block["content"] {
        Value::String(text) => text.clone(),
        Value::Array(parts) => parts.iter().filter_map(|part| part["text"].as_str()).collect::<Vec<_>>().join("\n"),
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The run may use the studio's tools and nothing else.
    #[test]
    fn a_run_has_only_the_studios_tools() {
        let run = Run {
            prompt: "q",
            system: "sys",
            config: Path::new("/tmp/c.json"),
            model: Some("opus"),
            effort: "low",
            max_turns: 24,
            resume: Some("s1"),
            eager_tools: false,
        };
        let args = run.arguments();
        let after = |flag: &str| args[args.iter().position(|a| a == flag).unwrap() + 1].clone();
        assert_eq!(after("--allowedTools"), "mcp__puffin");
        assert_eq!(after("--disallowedTools"), "Bash,Write,Edit,NotebookEdit,Skill");
        assert_eq!(after("--tools"), "");
        assert_eq!(after("--mcp-config"), "/tmp/c.json");
        assert!(args.contains(&"--strict-mcp-config".to_owned()));
        assert_eq!(after("--resume"), "s1");
        assert_eq!(after("--model"), "opus");
        assert_eq!(after("--output-format"), "stream-json");
        assert_eq!(after("--max-turns"), "24");
    }

    #[test]
    fn a_stream_reads_as_its_parts() {
        let init = json!({ "type": "system", "subtype": "init", "session_id": "s1", "model": "opus" });
        assert!(matches!(parts(&init)[..], [Part::Session("s1"), Part::Init { model: "opus" }]));
        let said = json!({ "type": "assistant", "message": { "content": [
            { "type": "text", "text": "  On it.\n" },
            { "type": "text", "text": " " },
            { "type": "tool_use", "id": "t1", "name": "mcp__puffin__get_file", "input": { "file": "a.puf" } },
        ]}});
        assert!(matches!(parts(&said)[..], [Part::Text("On it."), Part::ToolUse { id: "t1", name: "get_file", .. }]));
        let answered = json!({ "type": "user", "message": { "content": [
            { "type": "tool_result", "tool_use_id": "t1", "content": [{ "type": "text", "text": "a" }, { "type": "text", "text": "b" }], "is_error": true },
        ]}});
        assert!(matches!(&parts(&answered)[..], [Part::ToolResult { id: "t1", text, error: true }] if text == "a\nb"));
        let inner = json!({ "type": "assistant", "parent_tool_use_id": "t0", "message": { "content": [{ "type": "text", "text": "x" }] } });
        assert!(parts(&inner).is_empty());
        let done = json!({ "type": "result", "session_id": "s1", "is_error": false });
        assert!(matches!(parts(&done)[..], [Part::Session("s1"), Part::Result(_)]));
    }

    #[test]
    fn a_config_is_private_and_goes_with_its_run() {
        use std::os::unix::fs::PermissionsExt;
        let name = format!("puffin-studio-test-{}.json", std::process::id());
        let path = {
            let config = McpConfig::write(&name, 7360, "secret", json!({ "X-Studio-Thread": "3" })).unwrap();
            let written: Value = serde_json::from_str(&std::fs::read_to_string(&config.path).unwrap()).unwrap();
            let server = &written["mcpServers"][SERVER];
            assert_eq!(server["url"], "http://127.0.0.1:7360/mcp");
            assert_eq!(server["headers"]["Authorization"], "Bearer secret");
            assert_eq!(server["headers"]["X-Studio-Thread"], "3");
            assert_eq!(std::fs::metadata(&config.path).unwrap().permissions().mode() & 0o777, 0o600);
            config.path.clone()
        };
        assert!(!path.exists());
    }
}
