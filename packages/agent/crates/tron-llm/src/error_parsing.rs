//! Shared API error response parsing across all providers.
//!
//! Handles multiple error envelope formats:
//! - Standard: `{"error": {"message": "...", "type": "..."}}`
//! - Google:   `{"error": {"message": "...", "status": "..."}}`
//! - Detail:   `{"detail": "..."}`
//! - Flat:     `{"message": "...", "code": "..."}`

use serde_json::Value;

/// Parsed API error information.
pub struct ApiErrorInfo {
    /// Human-readable error message.
    pub message: String,
    /// Provider-specific error code (e.g., `"overloaded_error"`, `"NOT_FOUND"`).
    pub code: Option<String>,
    /// Whether the request can be retried (429 or 5xx).
    pub retryable: bool,
}

/// Parse an API error response body into structured error info.
///
/// Tries multiple JSON error formats in order of specificity, falling back
/// to the raw body text if nothing matches.
pub fn parse_api_error(body: &str, status: u16) -> ApiErrorInfo {
    let retryable = status == 429 || status >= 500;

    if let Ok(json) = serde_json::from_str::<Value>(body) {
        // Standard envelope: {"error": {"message": "...", "type": "..."}}
        if let Some(msg) = json["error"]["message"].as_str() {
            let code = json["error"]["type"]
                .as_str()
                .or_else(|| json["error"]["status"].as_str())
                .map(String::from);
            return ApiErrorInfo {
                message: msg.to_string(),
                code,
                retryable,
            };
        }

        // Alternative: {"detail": "..."} or {"message": "..."}
        if let Some(msg) = json["detail"].as_str().or_else(|| json["message"].as_str()) {
            let code = json["code"]
                .as_str()
                .or_else(|| json["type"].as_str())
                .map(String::from);
            return ApiErrorInfo {
                message: msg.to_string(),
                code,
                retryable,
            };
        }

        // Valid JSON but unrecognized structure — include raw body
        return ApiErrorInfo {
            message: format!("HTTP {status}: {body}"),
            code: None,
            retryable,
        };
    }

    // Not JSON
    ApiErrorInfo {
        message: format!("HTTP {status}: {body}"),
        code: None,
        retryable,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anthropic_standard_format() {
        let body = r#"{"error":{"type":"overloaded_error","message":"Overloaded"}}"#;
        let info = parse_api_error(body, 529);
        assert_eq!(info.message, "Overloaded");
        assert_eq!(info.code.as_deref(), Some("overloaded_error"));
        assert!(info.retryable);
    }

    #[test]
    fn google_status_format() {
        let body = r#"{"error":{"status":"NOT_FOUND","message":"Model not found"}}"#;
        let info = parse_api_error(body, 404);
        assert_eq!(info.message, "Model not found");
        assert_eq!(info.code.as_deref(), Some("NOT_FOUND"));
        assert!(!info.retryable);
    }

    #[test]
    fn openai_detail_format() {
        let body = r#"{"detail":"Model not found"}"#;
        let info = parse_api_error(body, 404);
        assert_eq!(info.message, "Model not found");
        assert!(info.code.is_none());
        assert!(!info.retryable);
    }

    #[test]
    fn openai_flat_message_format() {
        let body = r#"{"message":"Invalid model","code":"model_not_found"}"#;
        let info = parse_api_error(body, 400);
        assert_eq!(info.message, "Invalid model");
        assert_eq!(info.code.as_deref(), Some("model_not_found"));
        assert!(!info.retryable);
    }

    #[test]
    fn unrecognized_json_includes_body() {
        let body = r#"{"error":{}}"#;
        let info = parse_api_error(body, 400);
        assert!(info.message.contains("400"));
        assert!(info.message.contains(r#"{"error":{}}"#));
        assert!(info.code.is_none());
        assert!(!info.retryable);
    }

    #[test]
    fn non_json_body() {
        let info = parse_api_error("Bad Gateway", 502);
        assert!(info.message.contains("502"));
        assert!(info.message.contains("Bad Gateway"));
        assert!(info.code.is_none());
        assert!(info.retryable);
    }

    #[test]
    fn retryable_429() {
        let body = r#"{"error":{"type":"rate_limit_error","message":"Rate limited"}}"#;
        let info = parse_api_error(body, 429);
        assert!(info.retryable);
    }

    #[test]
    fn retryable_500() {
        let body = r#"{"error":{"type":"server_error","message":"Internal error"}}"#;
        let info = parse_api_error(body, 500);
        assert!(info.retryable);
    }

    #[test]
    fn retryable_503() {
        let info = parse_api_error("Service Unavailable", 503);
        assert!(info.retryable);
    }

    #[test]
    fn not_retryable_400() {
        let body = r#"{"error":{"type":"invalid_request","message":"Bad request"}}"#;
        let info = parse_api_error(body, 400);
        assert!(!info.retryable);
    }

    #[test]
    fn not_retryable_401() {
        let body = r#"{"error":{"type":"auth_error","message":"Unauthorized"}}"#;
        let info = parse_api_error(body, 401);
        assert!(!info.retryable);
    }

    #[test]
    fn empty_body() {
        let info = parse_api_error("", 500);
        assert_eq!(info.message, "HTTP 500: ");
        assert!(info.retryable);
    }

    #[test]
    fn type_preferred_over_status_when_both_present() {
        let body = r#"{"error":{"type":"overloaded","status":"UNAVAILABLE","message":"busy"}}"#;
        let info = parse_api_error(body, 503);
        assert_eq!(info.code.as_deref(), Some("overloaded"));
    }
}
