//! Shared sensitive text redaction.
//!
//! This module owns cross-boundary redaction for secrets that may otherwise
//! appear in logs, durable audit payloads, retry events, or public failure
//! envelopes.

use std::sync::LazyLock;

use regex::Regex;
use serde_json::Value;

/// Placeholder used for redacted JSON fields.
pub const REDACTED_SECRET: &str = "****";

/// Redact sensitive content from text.
///
/// Matches common secret patterns (API keys, tokens, passwords) and masks
/// the secret portion. Returns the original text unchanged if no secrets found.
#[must_use]
pub fn redact_sensitive_content(text: &str) -> String {
    static PATTERNS: LazyLock<Vec<(Regex, &str)>> = LazyLock::new(|| {
        vec![
            (
                Regex::new(
                    r#"(?i)("(?:(?:api_?key)|token|authorization|bearer|access_?token|refresh_?token|client_?secret|authorization_?code|auth_?code|oauth_?code|code)"\s*:\s*")([^"]{8,})(")"#,
                )
                .unwrap(),
                "${1}****${3}",
            ),
            (
                Regex::new(
                    r#"(?i)(\b(?:(?:api_?key)|token|authorization|bearer|access_?token|refresh_?token|client_?secret|authorization_?code|auth_?code|oauth_?code|code)\s*:\s*")([^"]{8,})(")"#,
                )
                .unwrap(),
                "${1}****${3}",
            ),
            (
                Regex::new(
                    r"(?i)\b(api_?key|access_?token|refresh_?token|client_?secret|authorization_?code|auth_?code|oauth_?code|password|secret)\s*[:=]\s*[A-Za-z0-9._~+/=-]{8,}",
                )
                .unwrap(),
                "${1}=****",
            ),
            (Regex::new(r"sk-ant-api\d{2}-[A-Za-z0-9_-]{10,}").unwrap(), "sk-ant-****"),
            (Regex::new(r"sk-proj-[A-Za-z0-9_-]{10,}").unwrap(), "sk-proj-****"),
            (Regex::new(r"AKIA[0-9A-Z]{16}").unwrap(), "AKIA****"),
            (Regex::new(r"gh[pousr]_[A-Za-z0-9_]{20,}").unwrap(), "gh*_****"),
            (Regex::new(r"Bearer\s+[A-Za-z0-9._-]{20,}").unwrap(), "Bearer ****"),
            (Regex::new(r"xox[bpao]-[A-Za-z0-9-]{10,}").unwrap(), "xox*-****"),
            (Regex::new(r"AIzaSy[A-Za-z0-9_-]{30,}").unwrap(), "AIzaSy****"),
        ]
    });

    let mut result = text.to_string();
    for (pattern, replacement) in PATTERNS.iter() {
        result = pattern.replace_all(&result, *replacement).to_string();
    }
    result
}

/// Recursively redact JSON object values whose keys conventionally carry
/// provider credentials, plus secret-looking strings anywhere in the value.
#[must_use]
pub fn redact_sensitive_json(value: &Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(key, value)| {
                    let redacted = if is_sensitive_json_key(key) {
                        Value::String(REDACTED_SECRET.to_owned())
                    } else {
                        redact_sensitive_json(value)
                    };
                    (key.clone(), redacted)
                })
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.iter().map(redact_sensitive_json).collect()),
        Value::String(text) => Value::String(redact_sensitive_content(text)),
        other => other.clone(),
    }
}

fn is_sensitive_json_key(key: &str) -> bool {
    let normalized: String = key
        .chars()
        .filter(|ch| *ch != '_' && *ch != '-' && *ch != '.')
        .flat_map(char::to_lowercase)
        .collect();
    matches!(
        normalized.as_str(),
        "apikey"
            | "xapikey"
            | "authorization"
            | "bearer"
            | "token"
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
    use serde_json::json;

    #[test]
    fn redacts_anthropic_key() {
        let result =
            redact_sensitive_content("key: sk-ant-api03-abcdefghijklmnopqrstuvwxyz1234567890");
        assert!(result.contains("sk-ant-****"));
        assert!(!result.contains("abcdefghijklmnop"));
    }

    #[test]
    fn redacts_openai_key() {
        let result = redact_sensitive_content("sk-proj-abcdefghijklmnopqrstuvwxyz");
        assert!(result.contains("sk-proj-****"));
        assert!(!result.contains("abcdefghijklmnop"));
    }

    #[test]
    fn redacts_bearer_token() {
        let result = redact_sensitive_content("Authorization: Bearer abcdefghijklmnopqrstuvwxyz");
        assert!(result.contains("Bearer ****"));
        assert!(!result.contains("abcdefghijklmnopqrstuvwxyz"));
    }

    #[test]
    fn redacts_json_auth_fields() {
        let value = json!({
            "apiKey": "sk-live-abcdefghijklmnopqrstuvwxyz",
            "headers": {
                "Authorization": "Bearer abcdefghijklmnopqrstuvwxyz",
                "x-api-key": "AIzaSyabcdefghijklmnopqrstuvwxyz1234567890"
            },
            "message": "access_token=supersecrettoken"
        });

        let redacted = redact_sensitive_json(&value);
        let text = redacted.to_string();

        for secret in [
            "sk-live-abcdefghijklmnopqrstuvwxyz",
            "abcdefghijklmnopqrstuvwxyz1234567890",
            "supersecrettoken",
        ] {
            assert!(!text.contains(secret), "secret leaked: {secret}");
        }
        assert_eq!(redacted["apiKey"], REDACTED_SECRET);
        assert_eq!(redacted["headers"]["Authorization"], REDACTED_SECRET);
        assert_eq!(redacted["headers"]["x-api-key"], REDACTED_SECRET);
    }
}
