//! # tron-auth
//!
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
//!
//! # Example
//!
//! ```no_run
//! use tron_auth::storage;
//! use std::path::Path;
//!
//! let auth_path = Path::new("/home/user/.tron/auth.json");
//! let keys = storage::get_service_api_keys(auth_path, "brave");
//! ```

#![deny(unsafe_code)]

pub mod anthropic;
pub mod errors;
pub mod google;
pub mod openai;
pub mod pkce;
pub mod storage;
pub mod types;

pub use errors::AuthError;
pub use pkce::{PkcePair, generate_pkce};
pub use storage::{auth_file_path, load_auth_storage, save_auth_storage};
pub use types::{
    AuthStorage, GoogleAuth, GoogleOAuthEndpoint, GoogleProviderAuth, OAuthConfig, OAuthTokens,
    ProviderAuth, ServerAuth, ServiceAuth, calculate_expires_at, now_ms, should_refresh,
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
}
