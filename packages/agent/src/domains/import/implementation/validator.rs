//! Clean capability-native import validation.
//!
//! Runs parse → linearize → assemble → validate → transform without touching
//! the event store. Provider-native capability history is rejected instead of
//! migrated: this clean cutover does not translate old `capability_invocation` or
//! `capability_result` records into current capability events.
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
/// capability results, dropped records, etc.).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ImportWarningKind {
    /// A line in the source JSONL failed to parse.
    UnparseableLine {
        /// 1-indexed line number.
        line_number: usize,
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
    /// Sum of available server-priced token-record costs (USD).
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

    let provider_capability_blocks = count_provider_capability_history(&assembled);
    if provider_capability_blocks > 0 {
        return Err(ImportError::UnsupportedProviderCapabilityHistory {
            block_count: provider_capability_blocks,
        });
    }

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

fn count_provider_capability_history(items: &[AssembledItem]) -> usize {
    let mut count = 0;
    for item in items {
        match item {
            AssembledItem::AssistantMessage(am) => {
                for block in &am.content_blocks {
                    if block.get("type").and_then(Value::as_str) == Some("capability_invocation") {
                        count += 1;
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
                    if block.get("type").and_then(Value::as_str) == Some("capability_result") {
                        count += 1;
                    }
                }
            }
            _ => {}
        }
    }
    count
}

#[cfg(test)]
#[path = "validator_tests.rs"]
mod tests;
