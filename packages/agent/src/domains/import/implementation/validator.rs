//! Dry-run import validation (M28).
//!
//! Runs the full import pipeline — parse → linearize → assemble →
//! transform — without touching the event store, producing a validation
//! report that surfaces errors and warnings BEFORE a DB transaction is
//! opened.
//!
//! # Why
//!
//! The parser historically swallowed unparseable lines with a single
//! `debug!` log. A user whose session file had ten truncated records had
//! no visibility into the loss — the import silently wrote the successful
//! records and returned a happy `ImportResult`. M28 promotes those
//! silent skips (and a handful of semantic issues the transformer
//! previously ignored) to first-class warnings the caller can render.
//!
//! The DB-write phase (`EventStore::import_atomic`) already runs the
//! whole pipeline inside a single transaction, so "pre-validate before
//! writing" is the structural default. M28 makes the dry-run OBSERVABLE.
//!
//! # Two-phase semantics
//!
//! Callers can either:
//! - [`validate_session`]: run phase one only, get a report without
//!   writing anything.
//! - Use [`crate::domains::import::import_session`]: runs validation internally
//!   and attaches the warnings to [`ImportResult`].
//!
//! Both paths share a single implementation (`validate_and_prepare`) so
//! they can never drift.

use std::collections::{HashMap, HashSet};
use std::path::Path;

use serde_json::Value;

use crate::domains::import::assembler::{AssembledItem, assemble};
use crate::domains::import::errors::ImportError;
use crate::domains::import::parser::{ParseWarning, parse_session_detailed};
use crate::domains::import::transformer::{TransformResult, TronEventSpec, transform};
use crate::domains::import::tree::linearize;

/// Category of a non-fatal import warning.
///
/// Warnings never block the import; they're surfaced to the user so they
/// know the resulting session may differ from the source file (missing
/// tool results, dropped records, etc.).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ImportWarningKind {
    /// A line in the source JSONL failed to parse.
    UnparseableLine {
        /// 1-indexed line number.
        line_number: usize,
    },
    /// A `tool_result` block references a `tool_use_id` that never
    /// appeared as a tool call. The result will be written with no
    /// matching call — reconstruction may render it as an orphan.
    OrphanToolResult {
        /// The `tool_use_id` that had no matching call.
        tool_call_id: String,
    },
    /// A `tool_use` block had no corresponding `tool_result`. Common
    /// for interrupted sessions (user closed Claude Code before the
    /// tool finished). Imported as-is; reconstruction renders the call
    /// with no outcome.
    OrphanToolUse {
        /// The `tool_use_id` that had no matching result.
        tool_call_id: String,
    },
    /// No assistant message carried a model ID. The importer falls
    /// back to the default model (`claude-sonnet-4-20250514`).
    AssistantMissingModel,
}

/// A non-fatal import warning.
#[derive(Debug, Clone)]
pub struct ImportWarning {
    /// Category — see [`ImportWarningKind`].
    pub kind: ImportWarningKind,
    /// Human-readable message.
    pub message: String,
}

impl ImportWarning {
    fn parse(warning: &ParseWarning) -> Self {
        Self {
            kind: ImportWarningKind::UnparseableLine {
                line_number: warning.line_number,
            },
            message: format!(
                "Line {} failed to parse ({}). Snippet: {}",
                warning.line_number, warning.reason, warning.snippet
            ),
        }
    }

    fn orphan_tool_result(tool_call_id: String) -> Self {
        let message = format!(
            "Tool result references tool_use_id '{tool_call_id}' but no matching tool call was found in the session."
        );
        Self {
            kind: ImportWarningKind::OrphanToolResult { tool_call_id },
            message,
        }
    }

    fn orphan_tool_use(tool_call_id: String) -> Self {
        let message = format!(
            "Tool call '{tool_call_id}' has no matching result — the turn may have been interrupted."
        );
        Self {
            kind: ImportWarningKind::OrphanToolUse { tool_call_id },
            message,
        }
    }

    fn assistant_missing_model() -> Self {
        Self {
            kind: ImportWarningKind::AssistantMissingModel,
            message:
                "No assistant message carried a model ID. Imported session uses the default model."
                    .to_string(),
        }
    }
}

/// Lightweight preview of what the import would produce if executed.
///
/// Mirrors the stats on [`crate::domains::import::ImportResult`] without the DB
/// side-effects, so callers can render a preview before committing.
#[derive(Debug, Clone)]
pub struct ImportPreview {
    /// Session title (from a `custom-title` record, if present).
    pub title: Option<String>,
    /// Primary model used, or the default model when absent.
    pub model: String,
    /// Number of conversation turns.
    pub turn_count: i64,
    /// Number of user + assistant messages.
    pub message_count: i64,
    /// Aggregate input tokens.
    pub total_input_tokens: i64,
    /// Aggregate output tokens.
    pub total_output_tokens: i64,
    /// Aggregate estimated cost (USD).
    pub total_cost: f64,
}

/// Full validation report.
#[derive(Debug, Clone)]
pub struct ImportValidation {
    /// Count of records that parsed successfully.
    pub records_parsed: usize,
    /// Count of non-blank lines inspected.
    pub lines_total: usize,
    /// Count of Tron events that would be written.
    pub events_ready: usize,
    /// Non-fatal warnings — never empty when the source file has issues.
    pub warnings: Vec<ImportWarning>,
    /// Preview stats.
    pub preview: ImportPreview,
}

/// Internal bundle returned by the full pipeline so `import_session`
/// doesn't have to re-run parse/linearize/assemble/transform.
pub(crate) struct ValidatedImport {
    pub validation: ImportValidation,
    pub events: Vec<TronEventSpec>,
    pub model: String,
}

/// Run the pipeline WITHOUT writing to the event store.
///
/// Returns [`ImportError::EmptySession`] if no importable events result —
/// this mirrors `import_session`'s precondition, so callers see the same
/// hard error whether they pre-validate or go straight to import.
pub fn validate_session(path: &Path) -> Result<ImportValidation, ImportError> {
    Ok(validate_and_prepare(path)?.validation)
}

/// Internal helper: run the pipeline and produce both the validation
/// report and the event specs ready for `EventStore::import_atomic`.
///
/// Shared between `validate_session` (public dry-run API) and
/// `import_session` (executing write) so the two can never drift.
pub(crate) fn validate_and_prepare(path: &Path) -> Result<ValidatedImport, ImportError> {
    let parse_outcome = parse_session_detailed(path)?;
    let mut warnings: Vec<ImportWarning> = parse_outcome
        .warnings
        .iter()
        .map(ImportWarning::parse)
        .collect();

    let records = parse_outcome.records;
    let records_parsed = records.len();
    let lines_total = parse_outcome.total_non_blank_lines;

    let linear = linearize(records);
    let assembled = assemble(linear);

    if assembled.is_empty() {
        return Err(ImportError::EmptySession);
    }

    // Detect orphan tool calls / results BEFORE transform, so the
    // warnings carry the original `tool_use_id`s without depending on
    // transformer output ordering.
    warnings.extend(detect_tool_orphans(&assembled));

    let result = transform(assembled);

    if result.events.is_empty() {
        return Err(ImportError::EmptySession);
    }

    if result.model.is_empty() {
        warnings.push(ImportWarning::assistant_missing_model());
    }

    let TransformResult {
        events,
        title,
        model,
        total_input_tokens,
        total_output_tokens,
        total_cost,
        turn_count,
        message_count,
    } = result;

    let resolved_model = if model.is_empty() {
        "claude-sonnet-4-20250514".to_string()
    } else {
        model
    };

    let events_ready = events.len();

    let validation = ImportValidation {
        records_parsed,
        lines_total,
        events_ready,
        warnings,
        preview: ImportPreview {
            title,
            model: resolved_model.clone(),
            turn_count,
            message_count,
            total_input_tokens,
            total_output_tokens,
            total_cost,
        },
    };

    Ok(ValidatedImport {
        validation,
        events,
        model: resolved_model,
    })
}

/// Walk assembled items collecting `tool_use_id`s on both sides and
/// report any mismatch.
///
/// A session file generally pairs each `tool_use` block (on an assistant
/// record) with exactly one `tool_result` block (on a subsequent user
/// record). Claude Code CAN emit an interrupted session where a call has
/// no result (user killed the agent) or an out-of-order session where a
/// result references a call that didn't make it into the file. Neither
/// is fatal, but both are worth surfacing.
fn detect_tool_orphans(items: &[AssembledItem]) -> Vec<ImportWarning> {
    let mut tool_uses: HashSet<String> = HashSet::new();
    let mut tool_results: HashSet<String> = HashSet::new();
    // Preserve first-seen order for deterministic warning output.
    let mut use_order: Vec<String> = Vec::new();
    let mut result_order: Vec<String> = Vec::new();
    let mut seen_in_uses: HashMap<String, ()> = HashMap::new();
    let mut seen_in_results: HashMap<String, ()> = HashMap::new();

    for item in items {
        match item {
            AssembledItem::AssistantMessage(am) => {
                for block in &am.content_blocks {
                    if block.get("type").and_then(Value::as_str) != Some("tool_use") {
                        continue;
                    }
                    if let Some(id) = block.get("id").and_then(Value::as_str) {
                        let id = id.to_string();
                        if tool_uses.insert(id.clone())
                            && seen_in_uses.insert(id.clone(), ()).is_none()
                        {
                            use_order.push(id);
                        }
                    }
                }
            }
            AssembledItem::UserMessage { record, .. } => {
                let Some(msg) = &record.message else { continue };
                let Some(content) = &msg.content else {
                    continue;
                };
                let Some(blocks) = content.as_array() else {
                    continue;
                };
                for block in blocks {
                    if block.get("type").and_then(Value::as_str) != Some("tool_result") {
                        continue;
                    }
                    if let Some(id) = block.get("tool_use_id").and_then(Value::as_str) {
                        let id = id.to_string();
                        if tool_results.insert(id.clone())
                            && seen_in_results.insert(id.clone(), ()).is_none()
                        {
                            result_order.push(id);
                        }
                    }
                }
            }
            _ => {}
        }
    }

    let mut warnings = Vec::new();
    for id in use_order {
        if !tool_results.contains(&id) {
            warnings.push(ImportWarning::orphan_tool_use(id));
        }
    }
    for id in result_order {
        if !tool_uses.contains(&id) {
            warnings.push(ImportWarning::orphan_tool_result(id));
        }
    }

    warnings
}

#[cfg(test)]
#[path = "validator_tests.rs"]
mod tests;
