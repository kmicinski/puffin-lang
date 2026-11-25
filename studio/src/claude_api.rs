//! Direct calls to the Claude Messages API, for the latency-critical parts
//! of voice mode (voice.rs): turning an utterance into an action takes one
//! short request, where a `claude -p` run would first spend a second or
//! two starting up.
//!
//! Credentials come from the same environment the claude CLI reads, so a
//! studio that can run the assistant can make these calls too:
//! `ANTHROPIC_API_KEY` (sent as `x-api-key`), else `CLAUDE_CODE_OAUTH_TOKEN`
//! or `ANTHROPIC_AUTH_TOKEN` (sent as a bearer token). `ANTHROPIC_BASE_URL`
//! points elsewhere (the deployment's `puffin-ai` broker, which swaps a
//! placeholder token for the real one), and `ANTHROPIC_CUSTOM_HEADERS`
//! ("Name: value" lines) are sent with every request, as the CLI does.

use serde_json::{Value, json};
use std::time::Duration;

/// The fast model: routing an utterance, summarizing for the voice.
pub const FAST_MODEL: &str = "claude-haiku-5-5";
/// The frontier model: research over the web.
pub const DEEP_MODEL: &str = "claude-opus-5-5";
/// Explaining code on an excursion (excursion.rs): good and quick.
pub const EXPLAIN_MODEL: &str = "claude-sonnet-5-5";

const VERSION: &str = "2023-06-01";
/// What OAuth tokens need on the Messages API.
const OAUTH_BETA: &str = "oauth-2025-04-20";
/// The first system block an OAuth (subscription) token's requests carry.
const OAUTH_IDENTITY: &str = "You are Claude Code, Anthropic's official CLI for Claude.";

#[derive(Clone)]
enum Auth {
    Key(String),
    Bearer(String),
}

#[derive(Clone)]
pub struct Api {
    http: reqwest::Client,
    base: String,
    auth: Auth,
    headers: Vec<(String, String)>,
}

impl Api {
    /// The API as this process's environment configures it, if it does.
    pub fn from_env() -> Option<Self> {
        let var = |name: &str| std::env::var(name).ok().filter(|value| !value.trim().is_empty());
        let auth = match (var("ANTHROPIC_API_KEY"), var("CLAUDE_CODE_OAUTH_TOKEN").or_else(|| var("ANTHROPIC_AUTH_TOKEN"))) {
            (Some(key), _) => Auth::Key(key),
            (None, Some(token)) => Auth::Bearer(token),
            (None, None) => return None,
        };
        let base = var("ANTHROPIC_BASE_URL").unwrap_or_else(|| "https://api.anthropic.com".to_owned());
        let headers = var("ANTHROPIC_CUSTOM_HEADERS")
            .unwrap_or_default()
            .lines()
            .filter_map(|line| line.split_once(':'))
            .map(|(name, value)| (name.trim().to_owned(), value.trim().to_owned()))
            .filter(|(name, _)| !name.is_empty())
            .collect();
        let http = reqwest::Client::builder().connect_timeout(Duration::from_secs(5)).build().ok()?;
        Some(Self { http, base: base.trim_end_matches('/').to_owned(), auth, headers })
    }

    fn oauth(&self) -> bool {
        matches!(self.auth, Auth::Bearer(_))
    }

    /// The system prompt as blocks; with an OAuth token, after the identity
    /// block such tokens' requests start with.
    pub fn system(&self, text: &str) -> Value {
        let mut blocks = Vec::new();
        if self.oauth() {
            blocks.push(json!({ "type": "text", "text": OAUTH_IDENTITY }));
        }
        blocks.push(json!({ "type": "text", "text": text, "cache_control": { "type": "ephemeral" } }));
        Value::Array(blocks)
    }

    /// One Messages request: the response, or why there is none.
    pub async fn messages(&self, mut body: Value, betas: &[&str], timeout: Duration) -> Result<Value, String> {
        if body.get("system").is_some_and(Value::is_string) {
            let text = body["system"].as_str().unwrap_or("").to_owned();
            body["system"] = self.system(&text);
        }
        let mut request = self
            .http
            .post(format!("{}/v1/messages", self.base))
            .timeout(timeout)
            .header("anthropic-version", VERSION)
            .header("content-type", "application/json");
        let mut beta: Vec<&str> = betas.to_vec();
        match &self.auth {
            Auth::Key(key) => request = request.header("x-api-key", key),
            Auth::Bearer(token) => {
                request = request.bearer_auth(token);
                beta.push(OAUTH_BETA);
            }
        }
        if !beta.is_empty() {
            request = request.header("anthropic-beta", beta.join(","));
        }
        for (name, value) in &self.headers {
            request = request.header(name, value);
        }
        let response = request.json(&body).send().await.map_err(|error| format!("the API is unreachable: {error}"))?;
        let status = response.status();
        let text = response.text().await.map_err(|error| format!("the API's answer was cut off: {error}"))?;
        let value: Value = serde_json::from_str(&text).map_err(|_| format!("the API answered {status}: {}", clip(&text, 300)))?;
        if !status.is_success() {
            let message = value["error"]["message"].as_str().unwrap_or(&text);
            return Err(format!("the API refused ({status}): {}", clip(message, 300)));
        }
        Ok(value)
    }

    /// A request whose answer is JSON in the given schema (structured
    /// output), parsed.
    pub async fn structured(&self, model: &str, effort: &str, system: &str, user: &str, schema: Value, max_tokens: u32, timeout: Duration) -> Result<Value, String> {
        let body = json!({
            "model": model,
            "max_tokens": max_tokens,
            "system": system,
            "output_config": { "effort": effort, "format": { "type": "json_schema", "schema": schema } },
            "messages": [{ "role": "user", "content": user }],
        });
        let response = self.messages(body, &[], timeout).await?;
        if response["stop_reason"] == "refusal" {
            return Err("the model declined".to_owned());
        }
        let text = text_of(&response);
        serde_json::from_str(&text).map_err(|error| format!("unreadable structured answer ({error}): {}", clip(&text, 200)))
    }

    /// Research with the server-side web tools: search and fetch run on
    /// Anthropic's side, so this works from a studio with no route to the
    /// web of its own. Continues paused turns; returns the answer's text
    /// with the sources it cites.
    pub async fn research(&self, question: &str) -> Result<String, String> {
        let system = "You research for a programmer who is building software by voice. Find the source they \
            point at (a paper, a spec, a page) with web search and fetch, read it, and answer with what they need \
            to write the code: definitions, rules, the exact formal content (grammars, transition rules, \
            equations) transcribed faithfully, and short notes on anything ambiguous. Cite each source by URL. \
            Plain text, no preamble.";
        let tools = json!([
            // the basic variants: the dynamic-filtering ones (_20260209) fail
            // under a subscription token through the broker (tested 2026-11-18)
            { "type": "web_search_20250305", "name": "web_search", "max_uses": 5 },
            { "type": "web_fetch_20250910", "name": "web_fetch", "max_uses": 4, "max_content_tokens": 60000 },
        ]);
        let mut messages = vec![json!({ "role": "user", "content": question })];
        let mut answer = String::new();
        for _ in 0..4 {
            let body = json!({
                "model": DEEP_MODEL,
                "max_tokens": 16000,
                "system": system,
                "output_config": { "effort": "low" },
                "tools": tools,
                "messages": messages,
            });
            let response = self.messages(body, &[], Duration::from_secs(300)).await?;
            answer.push_str(&text_of(&response));
            if response["stop_reason"] != "pause_turn" {
                break;
            }
            messages.push(json!({ "role": "assistant", "content": response["content"] }));
        }
        if answer.trim().is_empty() { Err("the research found nothing to say".to_owned()) } else { Ok(answer) }
    }
}

/// A response's text blocks, joined.
pub fn text_of(response: &Value) -> String {
    response["content"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|block| block["type"] == "text")
        .filter_map(|block| block["text"].as_str())
        .collect::<Vec<_>>()
        .join("")
}

fn clip(text: &str, max: usize) -> String {
    if text.len() <= max {
        return text.to_owned();
    }
    let mut end = max;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &text[..end])
}

/// Structured output wants every object closed and every property
/// required: a schema the API refuses would fail every request made with
/// it. Panics, naming the place, where `schema` is not so.
#[cfg(test)]
pub fn assert_strict(schema: &Value, path: &str) {
    match schema["type"].as_str() {
        Some("object") => {
            assert_eq!(schema["additionalProperties"], json!(false), "{path}: additionalProperties");
            let properties = schema["properties"].as_object().unwrap_or_else(|| panic!("{path}: properties"));
            let mut required: Vec<&str> = schema["required"].as_array().unwrap_or_else(|| panic!("{path}: required")).iter().map(|r| r.as_str().unwrap()).collect();
            required.sort_unstable();
            assert_eq!(properties.keys().map(String::as_str).collect::<Vec<_>>(), required, "{path}: every property required");
            for (key, property) in properties {
                assert_strict(property, &format!("{path}.{key}"));
            }
        }
        Some("array") => assert_strict(&schema["items"], &format!("{path}[]")),
        Some("string" | "integer" | "boolean" | "number") => {
            if let Some(choices) = schema["enum"].as_array() {
                assert!(!choices.is_empty() && choices.iter().all(Value::is_string), "{path}: enum");
            }
        }
        other => panic!("{path}: type {other:?}"),
    }
}
