//! Ledger response parsing for LLM-based memory ledger entries.
//!
//! The LLM is instructed via [`MEMORY_LEDGER_PROMPT`](crate::system_prompts::MEMORY_LEDGER_PROMPT)
//! to return structured JSON describing what happened in a session.
//! This module parses that response into a [`LedgerEntry`].

use futures::StreamExt;
use serde::Deserialize;
use serde_json::Value;
use tracing::warn;

use crate::summarizer::serialize_messages;
use crate::system_prompts::MEMORY_LEDGER_PROMPT;
use tron_core::events::StreamEvent;
use tron_core::messages::{Context, Message};
use tron_llm::provider::{Provider, ProviderStreamOptions};

// =============================================================================
// Types
// =============================================================================

/// Parsed ledger entry from the LLM response.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LedgerEntry {
    /// Short descriptive title (under 80 chars).
    pub title: String,
    /// Entry type: feature, bugfix, refactor, docs, config, research, conversation.
    pub entry_type: String,
    /// Status: `completed`, `partial`, `in_progress`.
    #[serde(default = "default_status")]
    pub status: String,
    /// Relevant tags.
    #[serde(default)]
    pub tags: Vec<String>,
    /// What the user asked for (1 sentence).
    #[serde(default)]
    pub input: String,
    /// What was done (1-3 bullet points).
    #[serde(default)]
    pub actions: Vec<String>,
    /// Files affected with operation and purpose.
    #[serde(default)]
    pub files: Vec<LedgerFileEntry>,
    /// Decisions made with rationale.
    #[serde(default)]
    pub decisions: Vec<LedgerDecision>,
    /// Patterns or insights worth remembering.
    #[serde(default)]
    pub lessons: Vec<String>,
    /// Key reasoning from thinking blocks.
    #[serde(default)]
    pub thinking_insights: Vec<String>,
}

/// File entry in a ledger record.
#[derive(Clone, Debug, Deserialize)]
pub struct LedgerFileEntry {
    /// Relative file path.
    pub path: String,
    /// Operation: C (create), M (modify), D (delete).
    pub op: String,
    /// Purpose description.
    #[serde(default)]
    pub why: String,
}

/// Decision in a ledger record.
#[derive(Clone, Debug, Deserialize)]
pub struct LedgerDecision {
    /// What was chosen.
    pub choice: String,
    /// Why it was chosen.
    pub reason: String,
}

fn default_status() -> String {
    "completed".into()
}

/// Result of parsing a ledger response.
#[derive(Clone, Debug)]
pub enum LedgerParseResult {
    /// Worth recording.
    Entry(Box<LedgerEntry>),
    /// Trivial interaction, skip.
    Skip,
}

// =============================================================================
// Parsing
// =============================================================================

/// Parse the LLM response for a ledger entry.
///
/// Returns `Ok(Skip)` if the LLM decided the interaction was trivial.
/// Returns `Ok(Entry(..))` if the interaction is worth recording.
/// Returns `Err(..)` if the response couldn't be parsed.
pub fn parse_ledger_response(output: &str) -> Result<LedgerParseResult, String> {
    let cleaned = strip_code_fences(output.trim());

    let parsed: Value =
        serde_json::from_str(&cleaned).map_err(|e| format!("invalid JSON: {e}"))?;

    // Check for skip
    if parsed.get("skip").and_then(Value::as_bool) == Some(true) {
        return Ok(LedgerParseResult::Skip);
    }

    // Parse as entry
    let entry: LedgerEntry =
        serde_json::from_value(parsed).map_err(|e| format!("invalid ledger entry: {e}"))?;

    if entry.title.is_empty() {
        return Err("empty title".into());
    }

    Ok(LedgerParseResult::Entry(Box::new(entry)))
}

/// Strip markdown code fences from a response string.
fn strip_code_fences(s: &str) -> String {
    let trimmed = s.trim();
    if let Some(rest) = trimmed.strip_prefix("```json") {
        rest.strip_suffix("```")
            .unwrap_or(rest)
            .trim()
            .to_string()
    } else if let Some(rest) = trimmed.strip_prefix("```") {
        rest.strip_suffix("```")
            .unwrap_or(rest)
            .trim()
            .to_string()
    } else {
        trimmed.to_string()
    }
}

// =============================================================================
// LLM ledger helper
// =============================================================================

/// Attempt to write a ledger entry using the LLM provider.
///
/// Returns `None` if the provider call fails or the response is unparseable,
/// signalling the caller to fall back to `KeywordSummarizer`.
pub async fn try_llm_ledger(
    provider: &dyn Provider,
    messages: &[Message],
) -> Option<LedgerParseResult> {
    let transcript = serialize_messages(messages);
    if transcript.is_empty() {
        return None;
    }

    let context = Context {
        system_prompt: Some(MEMORY_LEDGER_PROMPT.to_owned()),
        messages: vec![Message::user(&transcript)],
        ..Default::default()
    };

    let options = ProviderStreamOptions {
        max_tokens: Some(4096),
        enable_thinking: Some(false),
        ..Default::default()
    };

    let mut stream = match provider.stream(&context, &options).await {
        Ok(s) => s,
        Err(e) => {
            warn!(error = %e, "LLM call failed for ledger writer");
            return None;
        }
    };

    let mut text = String::new();
    while let Some(event) = stream.next().await {
        match event {
            Ok(StreamEvent::Done { message, .. }) => {
                let complete: String = message
                    .content
                    .iter()
                    .filter_map(|c| c.as_text())
                    .collect::<Vec<_>>()
                    .join("");
                if !complete.is_empty() {
                    text = complete;
                }
            }
            Ok(StreamEvent::TextDelta { delta }) => {
                text.push_str(&delta);
            }
            Err(e) => {
                warn!(error = %e, "Stream error during ledger LLM call");
                return None;
            }
            _ => {}
        }
    }

    if text.is_empty() {
        warn!("LLM returned empty response for ledger writer");
        return None;
    }

    match parse_ledger_response(&text) {
        Ok(result) => Some(result),
        Err(e) => {
            warn!(error = %e, "Failed to parse ledger LLM response");
            None
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_valid_entry() {
        let response = r#"{
            "title": "Fix login bug",
            "entryType": "bugfix",
            "status": "completed",
            "tags": ["auth", "login"],
            "input": "Fix the login page crash",
            "actions": ["Modified auth.rs to handle null tokens"],
            "files": [{"path": "src/auth.rs", "op": "M", "why": "Null token handling"}],
            "decisions": [{"choice": "Guard clause", "reason": "Simpler than refactoring"}],
            "lessons": ["Always validate tokens before use"],
            "thinkingInsights": ["The crash was caused by expired token cache"]
        }"#;
        let result = parse_ledger_response(response).unwrap();
        match result {
            LedgerParseResult::Entry(entry) => {
                assert_eq!(entry.title, "Fix login bug");
                assert_eq!(entry.entry_type, "bugfix");
                assert_eq!(entry.status, "completed");
                assert_eq!(entry.tags, vec!["auth", "login"]);
                assert_eq!(entry.input, "Fix the login page crash");
                assert_eq!(entry.actions.len(), 1);
                assert_eq!(entry.files.len(), 1);
                assert_eq!(entry.files[0].path, "src/auth.rs");
                assert_eq!(entry.files[0].op, "M");
                assert_eq!(entry.decisions.len(), 1);
                assert_eq!(entry.decisions[0].choice, "Guard clause");
                assert_eq!(entry.lessons.len(), 1);
                assert_eq!(entry.thinking_insights.len(), 1);
            }
            LedgerParseResult::Skip => panic!("expected entry, got skip"),
        }
    }

    #[test]
    fn parse_skip_response() {
        let response = r#"{"skip": true}"#;
        let result = parse_ledger_response(response).unwrap();
        assert!(matches!(result, LedgerParseResult::Skip));
    }

    #[test]
    fn parse_skip_false_treated_as_entry() {
        let response = r#"{"skip": false, "title": "Test", "entryType": "feature"}"#;
        let result = parse_ledger_response(response).unwrap();
        assert!(matches!(result, LedgerParseResult::Entry(_)));
    }

    #[test]
    fn parse_minimal_entry() {
        let response = r#"{"title": "Test feature", "entryType": "feature"}"#;
        let result = parse_ledger_response(response).unwrap();
        match result {
            LedgerParseResult::Entry(entry) => {
                assert_eq!(entry.title, "Test feature");
                assert_eq!(entry.entry_type, "feature");
                assert_eq!(entry.status, "completed");
                assert!(entry.tags.is_empty());
                assert!(entry.actions.is_empty());
                assert!(entry.files.is_empty());
                assert!(entry.decisions.is_empty());
                assert!(entry.lessons.is_empty());
                assert!(entry.thinking_insights.is_empty());
            }
            LedgerParseResult::Skip => panic!("expected entry"),
        }
    }

    #[test]
    fn parse_with_code_fences() {
        let response = "```json\n{\"title\": \"Test\", \"entryType\": \"feature\"}\n```";
        let result = parse_ledger_response(response).unwrap();
        assert!(matches!(result, LedgerParseResult::Entry(_)));
    }

    #[test]
    fn parse_with_plain_code_fences() {
        let response = "```\n{\"title\": \"Test\", \"entryType\": \"feature\"}\n```";
        let result = parse_ledger_response(response).unwrap();
        assert!(matches!(result, LedgerParseResult::Entry(_)));
    }

    #[test]
    fn parse_empty_title_errors() {
        let response = r#"{"title": "", "entryType": "feature"}"#;
        assert!(parse_ledger_response(response).is_err());
    }

    #[test]
    fn parse_invalid_json_errors() {
        assert!(parse_ledger_response("not json at all").is_err());
    }

    #[test]
    fn parse_missing_title_errors() {
        let response = r#"{"entryType": "feature"}"#;
        assert!(parse_ledger_response(response).is_err());
    }

    #[test]
    fn parse_with_whitespace() {
        let response = "  \n  {\"title\": \"Test\", \"entryType\": \"feature\"} \n  ";
        let result = parse_ledger_response(response).unwrap();
        assert!(matches!(result, LedgerParseResult::Entry(_)));
    }

    #[test]
    fn parse_files_with_missing_why() {
        let response = r#"{
            "title": "Test",
            "entryType": "feature",
            "files": [{"path": "src/main.rs", "op": "M"}]
        }"#;
        match parse_ledger_response(response).unwrap() {
            LedgerParseResult::Entry(entry) => {
                assert_eq!(entry.files[0].why, "");
            }
            LedgerParseResult::Skip => panic!("expected entry"),
        }
    }

    #[test]
    fn parse_multiple_files_and_decisions() {
        let response = r#"{
            "title": "Refactor auth system",
            "entryType": "refactor",
            "files": [
                {"path": "src/auth.rs", "op": "M", "why": "Extract trait"},
                {"path": "src/auth_impl.rs", "op": "C", "why": "New impl"}
            ],
            "decisions": [
                {"choice": "Trait-based auth", "reason": "Extensibility"},
                {"choice": "Keep backwards compat", "reason": "Existing users"}
            ]
        }"#;
        match parse_ledger_response(response).unwrap() {
            LedgerParseResult::Entry(entry) => {
                assert_eq!(entry.files.len(), 2);
                assert_eq!(entry.decisions.len(), 2);
            }
            LedgerParseResult::Skip => panic!("expected entry"),
        }
    }

    #[test]
    fn strip_json_code_fence() {
        let input = "```json\n{\"key\": \"value\"}\n```";
        assert_eq!(strip_code_fences(input), "{\"key\": \"value\"}");
    }

    #[test]
    fn strip_plain_code_fence() {
        let input = "```\n{\"key\": \"value\"}\n```";
        assert_eq!(strip_code_fences(input), "{\"key\": \"value\"}");
    }

    #[test]
    fn no_code_fence_passthrough() {
        let input = "{\"key\": \"value\"}";
        assert_eq!(strip_code_fences(input), input);
    }
}
