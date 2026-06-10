//! Sensitive data redaction for event payloads.
//!
//! Defense-in-depth: redacts API keys, tokens, and secrets from text
//! before storage in the event store. Each pattern requires a minimum
//! length to avoid false positives on short strings.

use std::sync::LazyLock;

use regex::Regex;

/// Redact sensitive content from text.
///
/// Matches common secret patterns (API keys, tokens, passwords) and masks
/// the secret portion. Returns the original text unchanged if no secrets found.
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
            // JSON/debug-description patterns so generic error `code=` fields
            // do not get masked.
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
            // OpenAI-style keys (sk-proj-...)
            (
                Regex::new(r"sk-proj-[A-Za-z0-9_-]{10,}").unwrap(),
                "sk-proj-****",
            ),
            // AWS access keys (AKIA...)
            (Regex::new(r"AKIA[0-9A-Z]{16}").unwrap(), "AKIA****"),
            // GitHub PATs (ghp_, gho_, ghs_, ghu_, ghr_)
            (
                Regex::new(r"gh[pousr]_[A-Za-z0-9_]{20,}").unwrap(),
                "gh*_****",
            ),
            // Bearer tokens
            (
                Regex::new(r"Bearer\s+[A-Za-z0-9._-]{20,}").unwrap(),
                "Bearer ****",
            ),
            // Slack tokens (xoxb-, xoxp-, xoxa-, xoxo-)
            (
                Regex::new(r"xox[bpao]-[A-Za-z0-9-]{10,}").unwrap(),
                "xox*-****",
            ),
            // Google API keys (AIzaSy...)
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
    fn redacts_anthropic_key() {
        let text = "key: sk-ant-api03-abcdefghijklmnopqrstuvwxyz1234567890";
        let result = redact_sensitive_content(text);
        assert!(result.contains("sk-ant-****"));
        assert!(!result.contains("abcdefghijklmnop"));
    }

    #[test]
    fn redacts_openai_key() {
        let text = "sk-proj-abcdefghijklmnopqrstuvwxyz";
        let result = redact_sensitive_content(text);
        assert!(result.contains("sk-proj-****"));
        assert!(!result.contains("abcdefghijklmnop"));
    }

    #[test]
    fn redacts_aws_key() {
        let text = "AKIAIOSFODNN7EXAMPLE";
        let result = redact_sensitive_content(text);
        assert!(result.contains("AKIA****"));
        assert!(!result.contains("IOSFODNN7EXAMPLE"));
    }

    #[test]
    fn redacts_github_pat() {
        let text = "ghp_xxxxxxxxxxxxxxxxxxxx123456";
        let result = redact_sensitive_content(text);
        assert!(result.contains("gh*_****"));
        assert!(!result.contains("xxxxxxxxxxxxxxxxxxxx"));
    }

    #[test]
    fn redacts_github_oauth() {
        let text = "gho_xxxxxxxxxxxxxxxxxxxx123456";
        let result = redact_sensitive_content(text);
        assert!(result.contains("gh*_****"));
    }

    #[test]
    fn redacts_bearer_token() {
        let text = "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.xxxxx";
        let result = redact_sensitive_content(text);
        assert!(result.contains("Bearer ****"));
        assert!(!result.contains("eyJhbGci"));
    }

    #[test]
    fn redacts_slack_token() {
        let text = "xoxb-1234-5678-abcdefghijklmno";
        let result = redact_sensitive_content(text);
        assert!(result.contains("xox*-****"));
        assert!(!result.contains("1234-5678"));
    }

    #[test]
    fn redacts_google_api_key() {
        let text = "AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890";
        let result = redact_sensitive_content(text);
        assert!(result.contains("AIzaSy****"));
        assert!(!result.contains("ABCDEFGHIJKLMNO"));
    }

    #[test]
    fn redacts_json_auth_fields() {
        let text = r#"{"apiKey":"sk-live-abcdefghijklmnopqrstuvwxyz","accessToken":"access-token-1234567890","refreshToken":"refresh-token-1234567890","clientSecret":"client-secret-1234567890","authorizationCode":"oauth-code-1234567890"}"#;
        let result = redact_sensitive_content(text);
        for secret in [
            "sk-live-abcdefghijklmnopqrstuvwxyz",
            "access-token-1234567890",
            "refresh-token-1234567890",
            "client-secret-1234567890",
            "oauth-code-1234567890",
        ] {
            assert!(!result.contains(secret), "secret leaked: {secret}");
        }
        assert!(result.contains(r#""apiKey":"****""#));
        assert!(result.contains(r#""accessToken":"****""#));
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
    fn redacts_unquoted_secret_key_values() {
        let text = "access_token=access-token-1234567890 client_secret:client-secret-1234567890";
        let result = redact_sensitive_content(text);
        assert!(!result.contains("access-token-1234567890"));
        assert!(!result.contains("client-secret-1234567890"));
        assert!(result.contains("access_token=****"));
        assert!(result.contains("client_secret=****"));
    }

    #[test]
    fn no_secrets_unchanged() {
        let text = "This is a normal text with no secrets whatsoever.";
        let result = redact_sensitive_content(text);
        assert_eq!(result, text);
    }

    #[test]
    fn multiple_secrets_all_masked() {
        let text =
            "key1=sk-ant-api03-abcdefghijklmnopqrstuvwxyz key2=ghp_xxxxxxxxxxxxxxxxxxxx123456";
        let result = redact_sensitive_content(text);
        assert!(result.contains("sk-ant-****"));
        assert!(result.contains("gh*_****"));
    }

    #[test]
    fn secret_at_start() {
        let text = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz is here";
        let result = redact_sensitive_content(text);
        assert!(result.starts_with("sk-ant-****"));
    }

    #[test]
    fn secret_at_end() {
        let text = "token is sk-ant-api03-abcdefghijklmnopqrstuvwxyz";
        let result = redact_sensitive_content(text);
        assert!(result.ends_with("sk-ant-****"));
    }

    #[test]
    fn short_sk_prefix_not_masked() {
        // "sk-ip" is too short to match the API key patterns
        let text = "I sk-ip this line";
        let result = redact_sensitive_content(text);
        assert_eq!(result, text);
    }

    #[test]
    fn already_masked_no_double_mask() {
        let text = "sk-ant-****";
        let result = redact_sensitive_content(text);
        assert_eq!(result, "sk-ant-****");
    }

    #[test]
    fn empty_string() {
        assert_eq!(redact_sensitive_content(""), "");
    }
}
