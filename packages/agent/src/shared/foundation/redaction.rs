//! Authoritative sensitive-data redaction policy.
//!
//! Provider errors, client logs, and durable event payloads can all carry
//! provider-auth fragments when an upstream service returns a raw request,
//! header, or debug string. This helper is intentionally conservative: it masks
//! common credential shapes and OAuth debug-wrapper codes while leaving
//! ordinary engine status/error codes intact.

use std::sync::LazyLock;

use regex::Regex;
use serde_json::Value;

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
                    r#"(?i)("(?:(?:api_?key)|token|authorization|bearer|access_?token|refresh_?token|client_?secret|authorization_?code|auth_?code|oauth_?code)"\s*:\s*")([^"]{8,})(")"#,
                )
                .unwrap(),
                "${1}****${3}",
            ),
            // OAuth debug wrappers commonly shorten `authorizationCode` to
            // `code`; retain generic engine error-code fields while masking
            // that context-specific credential.
            (
                Regex::new(r#"(?i)(\boauth\s*\(\s*code\s*:\s*")([^"]{8,})(")"#)
                    .unwrap(),
                "${1}****${3}",
            ),
            // Swift/Rust debug-description fields like `apiKey: "..."`.
            (
                Regex::new(
                    r#"(?i)(\b(?:(?:api_?key)|token|authorization|bearer|access_?token|refresh_?token|client_?secret|authorization_?code|auth_?code|oauth_?code)\s*:\s*")([^"]{8,})(")"#,
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
            // Tron worker webhook credentials. These are deliberately
            // recognizable so a bare token is still redacted after a JSON
            // payload has been decomposed into individual string values.
            (
                Regex::new(r"trwh_[A-Za-z0-9_-]{20,}").unwrap(),
                "trwh_****",
            ),
        ]
    });

    let mut result = text.to_string();
    for (pattern, replacement) in PATTERNS.iter() {
        result = pattern.replace_all(&result, *replacement).to_string();
    }
    result
}

/// Recursively redact sensitive JSON values while retaining non-secret shape.
///
/// Unlike text-only redaction, this helper can use an object's field names.
/// That matters for generated credentials which may be opaque strings without
/// a globally recognizable prefix. Exact credential fields are masked even
/// when their values do not match one of the known textual secret shapes.
#[must_use]
pub fn redact_sensitive_json(value: &Value) -> Value {
    match value {
        Value::String(value) => Value::String(redact_sensitive_content(value)),
        Value::Array(values) => Value::Array(values.iter().map(redact_sensitive_json).collect()),
        Value::Object(values) => Value::Object(
            values
                .iter()
                .map(|(key, value)| {
                    let value = if is_sensitive_json_key(key) && !value.is_null() {
                        Value::String("****".to_owned())
                    } else {
                        redact_sensitive_json(value)
                    };
                    (key.clone(), value)
                })
                .collect(),
        ),
        other => other.clone(),
    }
}

fn is_sensitive_json_key(key: &str) -> bool {
    let normalized = key
        .chars()
        .filter(|character| !matches!(character, '_' | '-'))
        .flat_map(char::to_lowercase)
        .collect::<String>();
    matches!(
        normalized.as_str(),
        "apikey"
            | "token"
            | "authorization"
            | "bearer"
            | "accesstoken"
            | "refreshtoken"
            | "clientsecret"
            | "authorizationcode"
            | "authcode"
            | "oauthcode"
            | "password"
            | "secret"
    )
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
            ("gho_xxxxxxxxxxxxxxxxxxxx123456", "gh*_****"),
            ("xoxb-1234-5678-abcdefghijklmno", "xox*-****"),
            ("AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890", "AIzaSy****"),
            ("trwh_0123456789abcdef0123456789abcdef", "trwh_****"),
        ] {
            let redacted = redact_sensitive_content(input);
            assert!(redacted.contains(expected), "{input} -> {redacted}");
            assert_ne!(redacted, input);
        }
    }

    #[test]
    fn leaves_non_secret_and_already_masked_text_unchanged() {
        for text in [
            "provider returned status code invalid_api_key",
            "I sk-ip this line",
            "sk-ant-****",
        ] {
            assert_eq!(redact_sensitive_content(text), text);
        }
    }

    #[test]
    fn preserves_engine_error_codes_while_redacting_authorization_codes() {
        let text = r#"{"code":"INVALID_PARAMS","authorizationCode":"oauth-code-1234567890"}"#;
        let result = redact_sensitive_content(text);

        assert!(result.contains(r#""code":"INVALID_PARAMS""#));
        assert!(result.contains(r#""authorizationCode":"****""#));
        assert!(!result.contains("oauth-code-1234567890"));
    }

    #[test]
    fn redacts_debug_description_auth_fields() {
        let text = r#"AddNamedApiKeyParams(provider: "openai", apiKey: "sk-test-abcdefghijklmnopqrstuvwxyz") OAuth(code: "oauth-code-1234567890")"#;
        let result = redact_sensitive_content(text);

        assert!(!result.contains("sk-test-abcdefghijklmnopqrstuvwxyz"));
        assert!(!result.contains("oauth-code-1234567890"));
        assert!(result.contains(r#"apiKey: "****""#));
        assert!(result.contains(r#"code: "****""#));
        assert!(result.contains(r#"provider: "openai""#));
    }

    #[test]
    fn redacts_unquoted_auth_fields() {
        let text = "access_token=access-token-1234567890 client_secret:client-secret-1234567890";
        let result = redact_sensitive_content(text);

        assert!(!result.contains("access-token-1234567890"));
        assert!(!result.contains("client-secret-1234567890"));
        assert!(result.contains("access_token=****"));
        assert!(result.contains("client_secret=****"));
    }

    #[test]
    fn redacts_sensitive_json_fields_and_bare_worker_webhook_tokens() {
        let token = "trwh_0123456789abcdef0123456789abcdef";
        let payload = serde_json::json!({
            "webhooks": [{"token": token, "path": "/hooks/research"}],
            "nested": {"clientSecret": "opaque-without-known-prefix"},
            "tokenUsage": {"inputTokens": 42},
            "status": "healthy"
        });

        let redacted = redact_sensitive_json(&payload);

        assert_eq!(redacted["webhooks"][0]["token"], "****");
        assert_eq!(redacted["nested"]["clientSecret"], "****");
        assert_eq!(redacted["tokenUsage"]["inputTokens"], 42);
        assert_eq!(redacted["status"], "healthy");
        assert!(!redacted.to_string().contains(token));
        assert_eq!(redact_sensitive_content(token), "trwh_****");
    }
}
