//! Ledger response parsing for LLM-based memory ledger entries.
//!
//! The LLM is instructed via [`MEMORY_LEDGER_PROMPT`](crate::system_prompts::MEMORY_LEDGER_PROMPT)
//! to return structured JSON describing what happened in a session.
//! This module parses that response into a [`LedgerEntry`].

use serde::Deserialize;
use serde_json::Value;

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
    let cleaned = extract_json(output);

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

/// Extract JSON from an LLM response that may contain code fences and surrounding text.
///
/// Strategy 1: Code fence extraction — find `` ```json `` or `` ``` `` followed by a
/// newline, then find `\n````. Extract only the content between the fences.
///
/// Strategy 2: Brace matching — locate first `{` and walk forward tracking brace
/// depth while respecting JSON string literals (handle `\"` escapes). Extract the
/// first complete top-level JSON object.
///
/// Strategy 3: Passthrough — return trimmed input (will fail at `serde_json::from_str`).
fn extract_json(s: &str) -> String {
    let trimmed = s.trim();

    // Strategy 1: code fence extraction, then brace matching to strip any
    // trailing non-JSON text the LLM may have put inside the fence.
    if let Some(fenced) = extract_from_code_fence(trimmed) {
        return extract_by_brace_matching(&fenced).unwrap_or(fenced);
    }

    // Strategy 2: brace matching
    if let Some(json) = extract_by_brace_matching(trimmed) {
        return json;
    }

    // Strategy 3: passthrough
    trimmed.to_string()
}

/// Try to extract JSON content from inside code fences.
fn extract_from_code_fence(s: &str) -> Option<String> {
    // Find opening fence: ```json\n or ```\n
    let fence_start = s.find("```json\n").map(|i| i + 8) // skip "```json\n"
        .or_else(|| s.find("```json\r\n").map(|i| i + 9))
        .or_else(|| s.find("```\n").map(|i| i + 4))
        .or_else(|| s.find("```\r\n").map(|i| i + 5))?;

    // Find closing fence: \n``` (newline followed by triple backtick)
    let remaining = &s[fence_start..];
    let fence_end = remaining.find("\n```")
        .or_else(|| remaining.find("\r\n```"))?;

    Some(remaining[..fence_end].trim().to_string())
}

/// Try to extract the first complete JSON object by brace matching.
fn extract_by_brace_matching(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    let start = bytes.iter().position(|&b| b == b'{')?;

    let mut depth: i32 = 0;
    let mut in_string = false;
    let mut i = start;

    while i < bytes.len() {
        let b = bytes[i];

        if in_string {
            if b == b'\\' {
                // Skip escaped character
                i += 2;
                continue;
            }
            if b == b'"' {
                in_string = false;
            }
        } else {
            match b {
                b'"' => in_string = true,
                b'{' => depth += 1,
                b'}' => {
                    depth -= 1;
                    if depth == 0 {
                        return Some(s[start..=i].to_string());
                    }
                }
                _ => {}
            }
        }
        i += 1;
    }

    None // Unclosed brace
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

    // ── extract_json: code fence variations ──

    #[test]
    fn parse_code_fence_with_trailing_emoji() {
        let input = "```json\n{\"title\": \"Test\", \"entryType\": \"feature\"}\n```\n\n\u{1FACE}";
        let result = parse_ledger_response(input).unwrap();
        assert!(matches!(result, LedgerParseResult::Entry(_)));
    }

    #[test]
    fn parse_code_fence_with_trailing_text() {
        let input = "```json\n{\"title\": \"Test\", \"entryType\": \"feature\"}\n```\n\nHere's the summary!";
        let result = parse_ledger_response(input).unwrap();
        assert!(matches!(result, LedgerParseResult::Entry(_)));
    }

    #[test]
    fn parse_code_fence_with_leading_text() {
        let input = "Sure!\n```json\n{\"title\": \"Test\", \"entryType\": \"feature\"}\n```";
        let result = parse_ledger_response(input).unwrap();
        assert!(matches!(result, LedgerParseResult::Entry(_)));
    }

    #[test]
    fn parse_code_fence_with_both_surrounding() {
        let input = "Here:\n```json\n{\"title\": \"Test\", \"entryType\": \"feature\"}\n```\nDone!";
        let result = parse_ledger_response(input).unwrap();
        assert!(matches!(result, LedgerParseResult::Entry(_)));
    }

    #[test]
    fn parse_plain_fence_with_trailing() {
        let input = "```\n{\"title\": \"Test\", \"entryType\": \"feature\"}\n```\nExtra";
        let result = parse_ledger_response(input).unwrap();
        assert!(matches!(result, LedgerParseResult::Entry(_)));
    }

    #[test]
    fn parse_code_fence_multiline_json() {
        let input = "```json\n{\n  \"title\": \"T\",\n  \"entryType\": \"feature\"\n}\n```";
        let result = parse_ledger_response(input).unwrap();
        match result {
            LedgerParseResult::Entry(e) => assert_eq!(e.title, "T"),
            LedgerParseResult::Skip => panic!("expected entry"),
        }
    }

    #[test]
    fn parse_code_fence_with_trailing_text_inside_fence() {
        // LLM puts explanatory text after JSON but inside the code fence
        let input = "```json\n{\"title\": \"Test\", \"entryType\": \"feature\"}\n\nHere is the explanation of the fields.\n```";
        let result = parse_ledger_response(input).unwrap();
        assert!(matches!(result, LedgerParseResult::Entry(_)));
    }

    #[test]
    fn extract_json_fence_then_brace_match() {
        // Content inside fence has trailing text after JSON object
        let input = "```json\n{\"key\": \"value\"}\nSome explanation\n```";
        assert_eq!(extract_json(input), "{\"key\": \"value\"}");
    }

    // ── extract_json: bare JSON variations ──

    #[test]
    fn parse_bare_json_with_trailing_text() {
        let input = "{\"title\": \"Test\", \"entryType\": \"feature\"}\n\nLet me know if you need changes!";
        let result = parse_ledger_response(input).unwrap();
        assert!(matches!(result, LedgerParseResult::Entry(_)));
    }

    #[test]
    fn parse_bare_json_with_leading_text() {
        let input = "Here is the JSON:\n{\"title\": \"Test\", \"entryType\": \"feature\"}";
        let result = parse_ledger_response(input).unwrap();
        assert!(matches!(result, LedgerParseResult::Entry(_)));
    }

    #[test]
    fn parse_bare_json_with_nested_braces() {
        let input = r#"{"title":"T","entryType":"feature","files":[{"path":"a","op":"M"}]}"#;
        let result = parse_ledger_response(input).unwrap();
        match result {
            LedgerParseResult::Entry(e) => {
                assert_eq!(e.title, "T");
                assert_eq!(e.files.len(), 1);
            }
            LedgerParseResult::Skip => panic!("expected entry"),
        }
    }

    #[test]
    fn parse_bare_json_with_string_braces() {
        let input = r#"{"title":"contains {braces} in text","entryType":"feature"}"#;
        let result = parse_ledger_response(input).unwrap();
        match result {
            LedgerParseResult::Entry(e) => {
                assert_eq!(e.title, "contains {braces} in text");
            }
            LedgerParseResult::Skip => panic!("expected entry"),
        }
    }

    #[test]
    fn parse_bare_json_with_escaped_quotes() {
        let input = r#"{"title":"say \"hello\"","entryType":"feature"}"#;
        let result = parse_ledger_response(input).unwrap();
        match result {
            LedgerParseResult::Entry(e) => {
                assert_eq!(e.title, r#"say "hello""#);
            }
            LedgerParseResult::Skip => panic!("expected entry"),
        }
    }

    // ── Multiple objects ──

    #[test]
    fn parse_multiple_json_objects_takes_first() {
        let input = "{\"title\":\"First\",\"entryType\":\"feature\"}\n{\"title\":\"Second\",\"entryType\":\"bugfix\"}";
        let result = parse_ledger_response(input).unwrap();
        match result {
            LedgerParseResult::Entry(e) => assert_eq!(e.title, "First"),
            LedgerParseResult::Skip => panic!("expected entry"),
        }
    }

    // ── Skip signal ──

    #[test]
    fn parse_skip_inside_code_fence() {
        let input = "```json\n{\"skip\": true}\n```";
        let result = parse_ledger_response(input).unwrap();
        assert!(matches!(result, LedgerParseResult::Skip));
    }

    // ── Error cases ──

    #[test]
    fn parse_empty_string_errors() {
        assert!(parse_ledger_response("").is_err());
    }

    #[test]
    fn parse_whitespace_only_errors() {
        assert!(parse_ledger_response("   \n  ").is_err());
    }

    #[test]
    fn parse_no_json_at_all_errors() {
        assert!(parse_ledger_response("Just some text, no JSON").is_err());
    }

    #[test]
    fn parse_unclosed_brace_errors() {
        assert!(parse_ledger_response("{\"title\": \"oops").is_err());
    }

    #[test]
    fn parse_unclosed_fence_falls_back_to_brace_match() {
        let input = "```json\n{\"title\": \"Test\", \"entryType\": \"feature\"}";
        let result = parse_ledger_response(input).unwrap();
        assert!(matches!(result, LedgerParseResult::Entry(_)));
    }

    // ── extract_json unit tests ──

    #[test]
    fn extract_json_fence_strips_surrounding() {
        let input = "Sure!\n```json\n{\"key\": \"value\"}\n```\nDone!";
        assert_eq!(extract_json(input), "{\"key\": \"value\"}");
    }

    #[test]
    fn extract_json_bare_object() {
        let input = "Here: {\"key\": \"value\"} trailing";
        assert_eq!(extract_json(input), "{\"key\": \"value\"}");
    }

    #[test]
    fn extract_json_passthrough() {
        let input = "no json here";
        assert_eq!(extract_json(input), "no json here");
    }
}
