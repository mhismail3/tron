//! # Stop Reason Mapping
//!
//! Maps provider-specific stop/finish reasons to unified [`StopReason`] values.
//! Each provider uses different strings for the same concepts.

/// Map an `OpenAI` stop reason to a unified stop reason string.
///
/// `OpenAI` Responses API uses:
/// - `"stop"` -> normal completion
/// - `"length"` -> max tokens reached
/// - `"tool_calls"` -> model wants to call tools
/// - `"content_filter"` -> blocked by safety filter
/// - `null` -> default to `end_turn`
pub fn map_openai_stop_reason(reason: Option<&str>) -> &'static str {
    match reason {
        Some("length") => "max_tokens",
        Some("tool_calls") => "tool_use",
        _ => "end_turn",
    }
}

/// Map a Google/Gemini finish reason to a unified stop reason string.
///
/// Gemini API uses:
/// - `"STOP"` -> normal completion
/// - `"MAX_TOKENS"` -> max tokens reached
/// - `"SAFETY"` -> blocked by safety filter
/// - `"RECITATION"` -> blocked for recitation
/// - `"OTHER"` -> other reason
pub fn map_google_stop_reason(reason: &str) -> &'static str {
    match reason {
        "MAX_TOKENS" => "max_tokens",
        _ => "end_turn",
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // -- OpenAI ---------------------------------------------------------------

    #[test]
    fn openai_stop() {
        assert_eq!(map_openai_stop_reason(Some("stop")), "end_turn");
    }

    #[test]
    fn openai_length() {
        assert_eq!(map_openai_stop_reason(Some("length")), "max_tokens");
    }

    #[test]
    fn openai_tool_calls() {
        assert_eq!(map_openai_stop_reason(Some("tool_calls")), "tool_use");
    }

    #[test]
    fn openai_content_filter() {
        assert_eq!(map_openai_stop_reason(Some("content_filter")), "end_turn");
    }

    #[test]
    fn openai_null() {
        assert_eq!(map_openai_stop_reason(None), "end_turn");
    }

    #[test]
    fn openai_unknown() {
        assert_eq!(map_openai_stop_reason(Some("something_new")), "end_turn");
    }

    // -- Google ---------------------------------------------------------------

    #[test]
    fn google_stop() {
        assert_eq!(map_google_stop_reason("STOP"), "end_turn");
    }

    #[test]
    fn google_max_tokens() {
        assert_eq!(map_google_stop_reason("MAX_TOKENS"), "max_tokens");
    }

    #[test]
    fn google_safety() {
        assert_eq!(map_google_stop_reason("SAFETY"), "end_turn");
    }

    #[test]
    fn google_recitation() {
        assert_eq!(map_google_stop_reason("RECITATION"), "end_turn");
    }

    #[test]
    fn google_other() {
        assert_eq!(map_google_stop_reason("OTHER"), "end_turn");
    }

    #[test]
    fn google_unknown() {
        assert_eq!(map_google_stop_reason("SOMETHING_ELSE"), "end_turn");
    }
}
