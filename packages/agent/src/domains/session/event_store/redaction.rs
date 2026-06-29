//! Sensitive data redaction for event payloads.
//!
//! The event store re-exports the shared foundation redactor so event-log
//! repositories keep their domain-local import while provider/model surfaces
//! can use the same policy without depending on the session domain.
//!
//! Delegated auth-secret coverage remains: `access_?token`,
//! `refresh_?token`, `client_?secret`, and `authorization_?code`.

pub use crate::shared::foundation::redaction::redact_sensitive_content;

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
