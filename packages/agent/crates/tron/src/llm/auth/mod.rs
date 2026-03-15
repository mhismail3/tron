//! OAuth 2.0 and API key authentication for LLM providers.
//!
//! Supports two auth modes:
//! - **API key**: Direct key-based auth
//! - **OAuth**: Token-based auth with auto-refresh (Anthropic, Google, `OpenAI`)
//!
//! Auth state is persisted to `~/.tron/auth.json` with secure file permissions.
//!
//! # Provider modules
//!
//! Each provider has its own module with `load_server_auth()` for priority-based
//! auth loading:
//! - [`anthropic`]: PKCE OAuth + API key (provider key: `"anthropic"`)
//! - [`google`]: Dual-endpoint OAuth (Cloud Code Assist / Antigravity) + API key
//! - [`openai`]: OAuth + API key (provider key: `"openai-codex"`)

pub mod anthropic;
pub mod errors;
pub mod google;
pub mod openai;
pub mod pkce;
pub(crate) mod refresh;
pub mod storage;
pub mod types;

/// URL-encode a string for use in query parameters.
pub(crate) fn urlencoded(s: &str) -> String {
    percent_encoding::utf8_percent_encode(s, percent_encoding::NON_ALPHANUMERIC).to_string()
}

/// Shared HTTP client for auth operations (avoids creating one per call).
pub(crate) fn shared_auth_client() -> &'static reqwest::Client {
    use std::sync::OnceLock;
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT.get_or_init(reqwest::Client::new)
}

pub use errors::AuthError;
pub use pkce::{PkcePair, generate_pkce};
pub use storage::{auth_file_path, load_auth_storage, save_auth_storage};
pub use types::{
    AuthStorage, GoogleAuth, GoogleOAuthEndpoint, GoogleProviderAuth, OAuthConfig,
    OAuthTokenRefreshResponse, OAuthTokens, ProviderAuth, ServerAuth, ServiceAuth,
    calculate_expires_at, now_ms, should_refresh,
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn re_exports_work() {
        let _pair = generate_pkce();
        let _storage = AuthStorage::new();
        let _pa = ProviderAuth::default();
    }

    #[test]
    fn urlencoded_basic_chars() {
        assert_eq!(urlencoded("hello world"), "hello%20world");
        assert_eq!(urlencoded("a&b=c"), "a%26b%3Dc");
    }

    #[test]
    fn urlencoded_special_chars() {
        let encoded = urlencoded("#?@!$");
        assert!(encoded.contains("%23")); // #
        assert!(encoded.contains("%3F")); // ?
        assert!(encoded.contains("%40")); // @
        assert!(encoded.contains("%21")); // !
        assert!(encoded.contains("%24")); // $
    }

    #[test]
    fn urlencoded_empty() {
        assert_eq!(urlencoded(""), "");
    }

    #[test]
    fn urlencoded_alphanumeric_passthrough() {
        assert_eq!(urlencoded("abc123"), "abc123");
    }
}
