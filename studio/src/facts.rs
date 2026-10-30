//! What is known at a point of the program, layer by layer (docs/STUDIO.md
//! §3), each part labelled with the layer it came from:
//!
//! - syntax: the top-level form at the point (its key and span), from the
//!   studio's form scanner;
//! - checker: the type at the point (`--assist facts`, else `type-at`), and
//!   the diagnostics within the form;
//! - session: whether the live session has the form current, stale, or not
//!   at all, and an expression's last result (session.rs);
//! - observed: what the session saw a function receive, per parameter
//!   (§3.1): the shapes from the record, and the patterns the compiler makes
//!   of them when `facts` answers.
//!
//! The hover, the Facts panel, the assistant's `facts_at`, and the line of
//! observations a question carries all read this one answer.

use crate::session::{Observed, Session};
use crate::sexp;
use crate::studio::Studio;
use crate::toolchain::Files;
use serde_json::{Value, json};

/// The parameters a panel asks the compiler about, at most.
const PARAMS_ASKED: usize = 6;

impl Studio {
    /// The facts at byte `pos` of `file` in `files`. With `full`, every
    /// parameter of the function there gets the compiler's patterns, which
    /// takes one more compiler run each.
    pub async fn facts_at(&self, files: &Files, file: &str, pos: usize, full: bool) -> Result<Value, String> {
        let text = files.get(file).ok_or_else(|| format!("there is no file {file}"))?;
        let pos = pos.min(text.len());
        let facts = self.toolchain.facts_available().await;
        let (kind, mut observed, error) = if facts {
            match self.toolchain.assist(files, "facts", file, Some(pos)).await {
                Ok(answer) => (answer["type"].clone(), answer["observed"].clone(), None),
                Err(report) => (Value::Null, Value::Null, Some(report.describe())),
            }
        } else if self.toolchain.assist_available().await {
            match self.toolchain.assist(files, "type-at", file, Some(pos)).await {
                Ok(answer) => (answer["type"].clone(), Value::Null, None),
                Err(report) => (Value::Null, Value::Null, Some(report.describe())),
            }
        } else {
            (Value::Null, Value::Null, None)
        };
        let form = sexp::form_at(text, pos);
        let Some(form) = form else {
            return Ok(json!({ "file": file, "pos": pos, "form": null, "type": kind, "observed": observed, "error": error }));
        };
        let end_line = sexp::line_of(text, form.end);
        let diagnostics: Vec<Value> = self
            .diagnostics_of(file)
            .into_iter()
            .filter(|d| d.line >= form.line && d.line <= end_line)
            .map(|d| json!({ "severity": d.severity, "message": d.message, "line": d.line }))
            .collect();
        let view = self.session_view();
        let state = Session::state(&view, file, text, &form);
        let function = sexp::params(text, &form).and_then(|(name, params)| {
            let observed = view.observed.iter().find(|observed| observed.function == name)?.clone();
            Some((observed, params))
        });
        // no observation from the compiler: the parameter at the point, from the record
        if observed.is_null()
            && let Some((record, params)) = &function
            && let Some((start, end)) = sexp::atom_at(text, pos)
            && let Some(index) = params.iter().position(|(param, _)| *param == text[start..end])
        {
            observed = json!({
                "function": record.function, "param": params[index].0, "index": index, "calls": record.calls,
                "shapes": record.args.get(index).cloned().unwrap_or_default(), "patterns": null,
            });
        }
        let function = match function {
            Some((record, params)) => Some(self.function_facts(files, file, &record, &params, facts && full).await),
            None => None,
        };
        Ok(json!({
            "file": file,
            "pos": pos,
            "form": { "key": form.key(), "line": form.line, "end_line": end_line, "start": form.start, "end": form.end, "source": "syntax" },
            "type": kind,
            "type_source": "checker",
            "diagnostics": diagnostics,
            "session": state,
            "observed": observed,
            "function": function,
            "error": error,
        }))
    }

    /// What was observed of `record`'s function, parameter by parameter;
    /// with `patterns`, each with the compiler's patterns from its binder.
    async fn function_facts(&self, files: &Files, file: &str, record: &Observed, params: &[(String, usize)], patterns: bool) -> Value {
        let mut out = Vec::new();
        for (index, (param, at)) in params.iter().enumerate() {
            let mut made = Value::Null;
            if patterns
                && index < PARAMS_ASKED
                && let Ok(answer) = self.toolchain.assist(files, "facts", file, Some(*at)).await
                && answer["observed"]["index"].as_u64() == Some(index as u64)
            {
                made = answer["observed"]["patterns"].clone();
            }
            out.push(json!({
                "name": param,
                "index": index,
                "shapes": record.args.get(index).cloned().unwrap_or_default(),
                "patterns": made,
            }));
        }
        json!({ "name": record.function, "calls": record.calls, "params": out, "source": "observed" })
    }

    /// One line of what the session observed of the function at byte `pos`
    /// of `file`, for a question's context; None when nothing was.
    pub async fn observed_line(&self, file: &str, pos: usize) -> Option<String> {
        let files = self.files();
        let facts = self.facts_at(&files, file, pos, true).await.ok()?;
        let function = facts.get("function").filter(|function| !function.is_null())?;
        let params = function["params"].as_array()?;
        let strings = |value: &Value| -> Vec<String> {
            value.as_array().into_iter().flatten().filter_map(|item| item.as_str().map(str::to_owned)).collect()
        };
        let observed = Observed {
            function: function["name"].as_str()?.to_owned(),
            calls: function["calls"].as_u64()?,
            args: params.iter().map(|param| strings(&param["shapes"])).collect(),
        };
        let names: Vec<String> = params.iter().filter_map(|param| param["name"].as_str().map(str::to_owned)).collect();
        let patterns: Vec<Vec<String>> = params.iter().map(|param| strings(&param["patterns"])).collect();
        Some(crate::session::summary(&observed, &names, &patterns))
    }
}
