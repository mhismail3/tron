//! Shared sensitive-data redaction helpers.
//!
//! Provider errors, client logs, and durable event payloads can all carry
//! provider-auth fragments when an upstream service returns a raw request,
//! header, or debug string. This helper is intentionally conservative: it masks
//! common credential shapes while leaving ordinary short status codes intact.

use std::sync::LazyLock;

use regex::Regex;

/// Redact sensitive content from text.
///
/// Matches common secret patterns (API keys, tokens, passwords) and masks
/// the secret portion. Returns the original text unchanged if no secrets match.
#[must_use]
pub fn redact_sensitive_content(text: &str) -> String {
    static PATTERNS: LazyLock<Vec<(Regex, &str)>> = LazyLock::new(|| {
        vec![
            // JSON-shaped auth fields, preserving the key and JSON quoting.
            (
                Regex::new(
                    r#"(?i)("(?:(?:api_?key)|token|authorization|bearer|access_?token|refresh_?token|client_?secret|authorization_?code|auth_?code|oauth_?code|code)"\s*:\s*")([^"]{8,})(")"#,
                )
                .unwrap(),
                "${1}****${3}",
            ),
            // Swift/Rust debug-description fields like `apiKey: "..."`.
            (
                Regex::new(
                    r#"(?i)(\b(?:(?:api_?key)|token|authorization|bearer|access_?token|refresh_?token|client_?secret|authorization_?code|auth_?code|oauth_?code|code)\s*:\s*")([^"]{8,})(")"#,
                )
                .unwrap(),
                "${1}****${3}",
            ),
            // Common unquoted key/value forms. Keep this narrower than the
            // JSON/debug-description patterns so generic provider `code=`
            // fields do not get masked.
            (
                Regex::new(
                    r"(?i)\b(api_?key|access_?token|refresh_?token|client_?secret|authorization_?code|auth_?code|oauth_?code|password|secret)\s*[:=]\s*[A-Za-z0-9._~+/=-]{8,}",
                )
                .unwrap(),
                "${1}=****",
            ),
            // Anthropic API keys (sk-ant-api03-...)
            (
                Regex::new(r"sk-ant-api\d{2}-[A-Za-z0-9_-]{10,}").unwrap(),
                "sk-ant-****",
            ),
            // OpenAI-style project keys.
            (
                Regex::new(r"sk-proj-[A-Za-z0-9_-]{10,}").unwrap(),
                "sk-proj-****",
            ),
            // AWS access keys.
            (Regex::new(r"AKIA[0-9A-Z]{16}").unwrap(), "AKIA****"),
            // GitHub PATs.
            (
                Regex::new(r"gh[pousr]_[A-Za-z0-9_]{20,}").unwrap(),
                "gh*_****",
            ),
            // Bearer tokens.
            (
                Regex::new(r"Bearer\s+[A-Za-z0-9._-]{20,}").unwrap(),
                "Bearer ****",
            ),
            // Slack tokens.
            (
                Regex::new(r"xox[bpao]-[A-Za-z0-9-]{10,}").unwrap(),
                "xox*-****",
            ),
            // Google API keys.
            (
                Regex::new(r"AIzaSy[A-Za-z0-9_-]{30,}").unwrap(),
                "AIzaSy****",
            ),
        ]
    });

    let mut result = text.to_string();
    for (pattern, replacement) in PATTERNS.iter() {
        result = pattern.replace_all(&result, *replacement).to_string();
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redacts_provider_and_oauth_secrets() {
        let text = r#"Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123456789 {"apiKey":"sk-live-abcdefghijklmnopqrstuvwxyz","accessToken":"access-token-1234567890","refreshToken":"refresh-token-1234567890","clientSecret":"client-secret-1234567890","authorizationCode":"oauth-code-1234567890"}"#;
        let result = redact_sensitive_content(text);

        for secret in [
            "abcdefghijklmnopqrstuvwxyz0123456789",
            "sk-live-abcdefghijklmnopqrstuvwxyz",
            "access-token-1234567890",
            "refresh-token-1234567890",
            "client-secret-1234567890",
            "oauth-code-1234567890",
        ] {
            assert!(!result.contains(secret), "secret leaked: {secret}");
        }
        assert!(result.contains("Bearer ****"));
        assert!(result.contains(r#""apiKey":"****""#));
        assert!(result.contains(r#""accessToken":"****""#));
    }

    #[test]
    fn redacts_known_key_shapes() {
        for (input, expected) in [
            ("sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "sk-ant-****"),
            ("sk-proj-abcdefghijklmnopqrstuvwxyz", "sk-proj-****"),
            ("AKIAIOSFODNN7EXAMPLE", "AKIA****"),
            ("ghp_xxxxxxxxxxxxxxxxxxxx123456", "gh*_****"),
            ("AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890", "AIzaSy****"),
        ] {
            let redacted = redact_sensitive_content(input);
            assert!(redacted.contains(expected), "{input} -> {redacted}");
            assert_ne!(redacted, input);
        }
    }

    #[test]
    fn leaves_non_secret_text_unchanged() {
        let text = "provider returned status code invalid_api_key";
        assert_eq!(redact_sensitive_content(text), text);
    }
}
