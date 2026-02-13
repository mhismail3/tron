//! Error parsing and classification.
//!
//! Matches error strings against known patterns to produce user-friendly
//! [`ParsedError`] values with category, message, suggestion, and
//! retryability information.

use serde::{Deserialize, Serialize};

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

/// Error category for classification.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCategory {
    /// Invalid or expired credentials.
    Authentication,
    /// Insufficient permissions.
    Authorization,
    /// Rate limit exceeded.
    RateLimit,
    /// Network connectivity issues.
    Network,
    /// Server-side errors (5xx).
    Server,
    /// Malformed request (4xx).
    InvalidRequest,
    /// Usage quota exhausted.
    Quota,
    /// Unrecognized error.
    Unknown,
}

impl std::fmt::Display for ErrorCategory {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Authentication => write!(f, "authentication"),
            Self::Authorization => write!(f, "authorization"),
            Self::RateLimit => write!(f, "rate_limit"),
            Self::Network => write!(f, "network"),
            Self::Server => write!(f, "server"),
            Self::InvalidRequest => write!(f, "invalid_request"),
            Self::Quota => write!(f, "quota"),
            Self::Unknown => write!(f, "unknown"),
        }
    }
}

/// A parsed error with user-friendly information.
#[derive(Clone, Debug, PartialEq)]
pub struct ParsedError {
    /// Error category.
    pub category: ErrorCategory,
    /// User-friendly error message.
    pub message: String,
    /// Additional details (if available).
    pub details: Option<String>,
    /// Whether the error is retryable.
    pub is_retryable: bool,
    /// Suggested action for the user.
    pub suggestion: Option<String>,
}

/// Error severity levels.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorSeverity {
    /// Unrecoverable — the process should exit.
    Fatal,
    /// Standard error.
    Error,
    /// Non-critical issue.
    Warning,
    /// Temporary issue (retryable).
    Transient,
}

// ─────────────────────────────────────────────────────────────────────────────
// Pattern matching
// ─────────────────────────────────────────────────────────────────────────────

struct ErrorPattern {
    check: fn(&str) -> bool,
    category: ErrorCategory,
    message: &'static str,
    suggestion: Option<&'static str>,
    is_retryable: bool,
}

/// All known error patterns, checked in order.
#[allow(clippy::too_many_lines)]
fn patterns() -> &'static [ErrorPattern] {
    static PATTERNS: &[ErrorPattern] = &[
        // Authentication
        ErrorPattern {
            check: |s| s.to_lowercase().contains("invalid") && s.to_lowercase().contains("x-api-key"),
            category: ErrorCategory::Authentication,
            message: "Invalid API key",
            suggestion: Some("Run \"tron login\" to re-authenticate or check your ANTHROPIC_API_KEY"),
            is_retryable: false,
        },
        ErrorPattern {
            check: |s| s.to_lowercase().contains("authentication_error"),
            category: ErrorCategory::Authentication,
            message: "Authentication failed",
            suggestion: Some("Run \"tron login\" to re-authenticate"),
            is_retryable: false,
        },
        ErrorPattern {
            check: |s| s.contains("401"),
            category: ErrorCategory::Authentication,
            message: "Authentication required",
            suggestion: Some("Run \"tron login\" or set ANTHROPIC_API_KEY environment variable"),
            is_retryable: false,
        },
        ErrorPattern {
            check: |s| s.to_lowercase().contains("invalid") && s.to_lowercase().contains("token"),
            category: ErrorCategory::Authentication,
            message: "Invalid or expired token",
            suggestion: Some("Run \"tron login\" to get a new token"),
            is_retryable: false,
        },
        // Authorization
        ErrorPattern {
            check: |s| s.contains("403"),
            category: ErrorCategory::Authorization,
            message: "Access denied",
            suggestion: Some("Check your account permissions"),
            is_retryable: false,
        },
        ErrorPattern {
            check: |s| s.to_lowercase().contains("permission_denied"),
            category: ErrorCategory::Authorization,
            message: "Permission denied",
            suggestion: Some("Your account may not have access to this feature"),
            is_retryable: false,
        },
        // Rate limiting
        ErrorPattern {
            check: |s| s.contains("429"),
            category: ErrorCategory::RateLimit,
            message: "Rate limit exceeded",
            suggestion: Some("Wait a moment and try again"),
            is_retryable: true,
        },
        ErrorPattern {
            check: |s| {
                let lower = s.to_lowercase();
                lower.contains("rate") && lower.contains("limit")
            },
            category: ErrorCategory::RateLimit,
            message: "Rate limit exceeded",
            suggestion: Some("Wait a moment and try again"),
            is_retryable: true,
        },
        ErrorPattern {
            check: |s| s.to_lowercase().contains("too many requests"),
            category: ErrorCategory::RateLimit,
            message: "Too many requests",
            suggestion: Some("Wait a moment and try again"),
            is_retryable: true,
        },
        // Quota
        ErrorPattern {
            check: |s| s.to_lowercase().contains("quota"),
            category: ErrorCategory::Quota,
            message: "Usage quota exceeded",
            suggestion: Some("Check your account billing or upgrade your plan"),
            is_retryable: false,
        },
        ErrorPattern {
            check: |s| s.to_lowercase().contains("insufficient") && s.to_lowercase().contains("credits"),
            category: ErrorCategory::Quota,
            message: "Insufficient credits",
            suggestion: Some("Add credits to your account"),
            is_retryable: false,
        },
        // Network
        ErrorPattern {
            check: |s| s.to_uppercase().contains("ECONNREFUSED"),
            category: ErrorCategory::Network,
            message: "Connection refused",
            suggestion: Some("Check your internet connection"),
            is_retryable: true,
        },
        ErrorPattern {
            check: |s| s.to_uppercase().contains("ETIMEDOUT"),
            category: ErrorCategory::Network,
            message: "Connection timed out",
            suggestion: Some("Check your internet connection and try again"),
            is_retryable: true,
        },
        ErrorPattern {
            check: |s| s.to_uppercase().contains("ENOTFOUND"),
            category: ErrorCategory::Network,
            message: "Could not reach server",
            suggestion: Some("Check your internet connection"),
            is_retryable: true,
        },
        ErrorPattern {
            check: |s| s.to_lowercase().contains("network"),
            category: ErrorCategory::Network,
            message: "Network error",
            suggestion: Some("Check your internet connection"),
            is_retryable: true,
        },
        // Server errors
        ErrorPattern {
            check: |s| s.contains("500"),
            category: ErrorCategory::Server,
            message: "Server error",
            suggestion: Some("Try again in a moment"),
            is_retryable: true,
        },
        ErrorPattern {
            check: |s| s.contains("502"),
            category: ErrorCategory::Server,
            message: "Server temporarily unavailable",
            suggestion: Some("Try again in a moment"),
            is_retryable: true,
        },
        ErrorPattern {
            check: |s| s.contains("503"),
            category: ErrorCategory::Server,
            message: "Service temporarily unavailable",
            suggestion: Some("Try again in a moment"),
            is_retryable: true,
        },
        ErrorPattern {
            check: |s| s.to_lowercase().contains("overloaded"),
            category: ErrorCategory::Server,
            message: "API is overloaded",
            suggestion: Some("Try again in a moment"),
            is_retryable: true,
        },
        // Invalid request
        ErrorPattern {
            check: |s| s.contains("400"),
            category: ErrorCategory::InvalidRequest,
            message: "Invalid request",
            suggestion: None,
            is_retryable: false,
        },
        ErrorPattern {
            check: |s| {
                let lower = s.to_lowercase();
                lower.contains("invalid") && lower.contains("request")
            },
            category: ErrorCategory::InvalidRequest,
            message: "Invalid request",
            suggestion: None,
            is_retryable: false,
        },
    ];
    PATTERNS
}

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

/// Extract a string representation from any error-like value.
pub fn extract_error_string(error: &dyn std::fmt::Display) -> String {
    error.to_string()
}

/// Parse an error string into a user-friendly [`ParsedError`].
#[must_use]
pub fn parse_error(error_string: &str) -> ParsedError {
    for pattern in patterns() {
        if (pattern.check)(error_string) {
            return ParsedError {
                category: pattern.category,
                message: pattern.message.to_owned(),
                details: extract_details(error_string),
                is_retryable: pattern.is_retryable,
                suggestion: pattern.suggestion.map(ToOwned::to_owned),
            };
        }
    }

    let details = extract_details(error_string).or_else(|| {
        Some(error_string[..error_string.len().min(200)].to_owned())
    });

    ParsedError {
        category: ErrorCategory::Unknown,
        message: "An unexpected error occurred".into(),
        details,
        is_retryable: false,
        suggestion: None,
    }
}

/// Format an error for display.
#[must_use]
pub fn format_error(error_string: &str) -> String {
    let parsed = parse_error(error_string);
    match parsed.suggestion {
        Some(s) => format!("{}. {s}", parsed.message),
        None => parsed.message,
    }
}

/// Format an error with full details.
#[must_use]
pub fn format_error_verbose(error_string: &str) -> String {
    let parsed = parse_error(error_string);
    let mut parts = vec![parsed.message.clone()];
    if let Some(details) = &parsed.details {
        parts.push(format!("Details: {details}"));
    }
    if let Some(suggestion) = &parsed.suggestion {
        parts.push(format!("Suggestion: {suggestion}"));
    }
    parts.join("\n")
}

/// Check if an error string represents an authentication error.
#[must_use]
pub fn is_auth_error(error_string: &str) -> bool {
    let parsed = parse_error(error_string);
    parsed.category == ErrorCategory::Authentication
        || parsed.category == ErrorCategory::Authorization
}

/// Check if an error string represents a retryable error.
#[must_use]
pub fn is_retryable_error(error_string: &str) -> bool {
    parse_error(error_string).is_retryable
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

fn extract_details(error_string: &str) -> Option<String> {
    // Try to extract JSON error details by finding matching braces.
    if let Some(start) = error_string.find('{') {
        // Find the matching closing brace (accounting for nesting).
        let mut depth = 0i32;
        let mut end = None;
        for (i, ch) in error_string[start..].char_indices() {
            match ch {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if depth == 0 {
                        end = Some(start + i);
                        break;
                    }
                }
                _ => {}
            }
        }
        if let Some(end_idx) = end {
            let json_str = &error_string[start..=end_idx];
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(json_str) {
                if let Some(msg) = parsed
                    .get("error")
                    .and_then(|e| e.get("message"))
                    .and_then(serde_json::Value::as_str)
                {
                    return Some(msg.to_owned());
                }
                if let Some(msg) = parsed.get("message").and_then(serde_json::Value::as_str) {
                    return Some(msg.to_owned());
                }
            }
        }
    }

    if error_string.len() < 200 {
        return None;
    }

    None
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_401_error() {
        let parsed = parse_error("HTTP 401 Unauthorized");
        assert_eq!(parsed.category, ErrorCategory::Authentication);
        assert!(parsed.suggestion.is_some());
        assert!(!parsed.is_retryable);
    }

    #[test]
    fn parse_authentication_error() {
        let parsed = parse_error("authentication_error: invalid key");
        assert_eq!(parsed.category, ErrorCategory::Authentication);
    }

    #[test]
    fn parse_invalid_api_key() {
        let parsed = parse_error("Invalid x-api-key header");
        assert_eq!(parsed.category, ErrorCategory::Authentication);
    }

    #[test]
    fn parse_invalid_token() {
        let parsed = parse_error("Invalid token provided");
        assert_eq!(parsed.category, ErrorCategory::Authentication);
    }

    #[test]
    fn parse_403_error() {
        let parsed = parse_error("HTTP 403 Forbidden");
        assert_eq!(parsed.category, ErrorCategory::Authorization);
        assert!(!parsed.is_retryable);
    }

    #[test]
    fn parse_permission_denied() {
        let parsed = parse_error("permission_denied: not allowed");
        assert_eq!(parsed.category, ErrorCategory::Authorization);
    }

    #[test]
    fn parse_429_error() {
        let parsed = parse_error("HTTP 429 Too Many Requests");
        assert_eq!(parsed.category, ErrorCategory::RateLimit);
        assert!(parsed.is_retryable);
    }

    #[test]
    fn parse_rate_limit_text() {
        let parsed = parse_error("Rate limit exceeded");
        assert_eq!(parsed.category, ErrorCategory::RateLimit);
        assert!(parsed.is_retryable);
    }

    #[test]
    fn parse_quota_error() {
        let parsed = parse_error("Quota exceeded for model");
        assert_eq!(parsed.category, ErrorCategory::Quota);
        assert!(!parsed.is_retryable);
    }

    #[test]
    fn parse_insufficient_credits() {
        let parsed = parse_error("Insufficient credits remaining");
        assert_eq!(parsed.category, ErrorCategory::Quota);
    }

    #[test]
    fn parse_econnrefused() {
        let parsed = parse_error("connect ECONNREFUSED 127.0.0.1:443");
        assert_eq!(parsed.category, ErrorCategory::Network);
        assert!(parsed.is_retryable);
    }

    #[test]
    fn parse_etimedout() {
        let parsed = parse_error("connect ETIMEDOUT");
        assert_eq!(parsed.category, ErrorCategory::Network);
        assert!(parsed.is_retryable);
    }

    #[test]
    fn parse_enotfound() {
        let parsed = parse_error("getaddrinfo ENOTFOUND api.anthropic.com");
        assert_eq!(parsed.category, ErrorCategory::Network);
        assert!(parsed.is_retryable);
    }

    #[test]
    fn parse_network_error() {
        let parsed = parse_error("Network error occurred");
        assert_eq!(parsed.category, ErrorCategory::Network);
    }

    #[test]
    fn parse_500_error() {
        let parsed = parse_error("HTTP 500 Internal Server Error");
        assert_eq!(parsed.category, ErrorCategory::Server);
        assert!(parsed.is_retryable);
    }

    #[test]
    fn parse_502_error() {
        let parsed = parse_error("HTTP 502 Bad Gateway");
        assert_eq!(parsed.category, ErrorCategory::Server);
    }

    #[test]
    fn parse_503_error() {
        let parsed = parse_error("HTTP 503 Service Unavailable");
        assert_eq!(parsed.category, ErrorCategory::Server);
    }

    #[test]
    fn parse_overloaded() {
        let parsed = parse_error("API is overloaded, please retry");
        assert_eq!(parsed.category, ErrorCategory::Server);
    }

    #[test]
    fn parse_400_error() {
        let parsed = parse_error("HTTP 400 Bad Request");
        assert_eq!(parsed.category, ErrorCategory::InvalidRequest);
        assert!(!parsed.is_retryable);
    }

    #[test]
    fn parse_invalid_request_text() {
        let parsed = parse_error("Invalid request: missing field");
        assert_eq!(parsed.category, ErrorCategory::InvalidRequest);
    }

    #[test]
    fn parse_unknown_error() {
        let parsed = parse_error("something weird happened");
        assert_eq!(parsed.category, ErrorCategory::Unknown);
        assert!(!parsed.is_retryable);
    }

    #[test]
    fn format_error_with_suggestion() {
        let formatted = format_error("HTTP 401 Unauthorized");
        assert!(formatted.contains("Authentication required"));
        assert!(formatted.contains("tron login"));
    }

    #[test]
    fn format_error_without_suggestion() {
        let formatted = format_error("HTTP 400 Bad Request");
        assert_eq!(formatted, "Invalid request");
    }

    #[test]
    fn format_error_verbose_all_parts() {
        let formatted = format_error_verbose("HTTP 429 Too Many Requests");
        assert!(formatted.contains("Rate limit exceeded"));
        assert!(formatted.contains("Suggestion:"));
    }

    #[test]
    fn is_auth_error_positive() {
        assert!(is_auth_error("HTTP 401 Unauthorized"));
        assert!(is_auth_error("HTTP 403 Forbidden"));
    }

    #[test]
    fn is_auth_error_negative() {
        assert!(!is_auth_error("HTTP 429 Too Many Requests"));
        assert!(!is_auth_error("random error"));
    }

    #[test]
    fn is_retryable_error_positive() {
        assert!(is_retryable_error("HTTP 429 Too Many Requests"));
        assert!(is_retryable_error("ECONNREFUSED"));
        assert!(is_retryable_error("HTTP 500 Internal Server Error"));
    }

    #[test]
    fn is_retryable_error_negative() {
        assert!(!is_retryable_error("HTTP 401 Unauthorized"));
        assert!(!is_retryable_error("HTTP 400 Bad Request"));
    }

    #[test]
    fn extract_details_from_json() {
        let err = r#"Error: {"message": "detailed info"} happened"#;
        let parsed = parse_error(err);
        assert_eq!(parsed.details, Some("detailed info".into()));
    }

    #[test]
    fn extract_details_nested_error() {
        let err = r#"API Error: {"error": {"message": "nested detail"}}"#;
        let parsed = parse_error(err);
        assert_eq!(parsed.details, Some("nested detail".into()));
    }

    #[test]
    fn error_category_display() {
        assert_eq!(ErrorCategory::Authentication.to_string(), "authentication");
        assert_eq!(ErrorCategory::RateLimit.to_string(), "rate_limit");
        assert_eq!(ErrorCategory::Unknown.to_string(), "unknown");
    }
}
