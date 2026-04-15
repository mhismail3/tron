//! OAuth 2.0 and API key authentication for LLM providers.
//!
//! Supports two auth modes:
//! - **API key**: Direct key-based auth
//! - **OAuth**: Token-based auth with auto-refresh (Anthropic, Google, `OpenAI`)
//!
//! Auth state is persisted to `~/.tron/system/auth.json` with secure file permissions.
//!
//! # Provider modules
//!
//! Each provider has its own module with `load_server_auth()` for priority-based
//! auth loading:
//! - [`anthropic`]: PKCE OAuth + API key (provider key: `"anthropic"`)
//! - [`google`]: Cloud Code Assist OAuth + API key
//! - [`openai`]: OAuth + API key (provider key: `"openai-codex"`)

pub mod anthropic;
pub mod errors;
pub mod google;
pub mod openai;
pub mod pkce;
pub(crate) mod refresh;
pub mod storage;
pub mod types;

/// Encode set matching Python's `urllib.parse.quote()` defaults: encode everything
/// except alphanumerics, `_.-~`, and `/` (slash preserved like Python's `safe='/'`).
const QUERY_ENCODE_SET: &percent_encoding::AsciiSet = &percent_encoding::NON_ALPHANUMERIC
    .remove(b'_')
    .remove(b'.')
    .remove(b'-')
    .remove(b'~')
    .remove(b'/');

/// URL-encode a string for use in query parameters (matches Python `urllib.parse.quote`).
pub(crate) fn urlencoded(s: &str) -> String {
    percent_encoding::utf8_percent_encode(s, QUERY_ENCODE_SET).to_string()
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
    ActiveCredential, ApiKeyEntry, AuthStorage, GoogleAuth, GoogleProviderAuth, OAuthConfig,
    OAuthTokenRefreshResponse, OAuthTokens, ProviderAuth, ServerAuth, ServiceAuth,
    calculate_expires_at, now_ms, should_refresh,
};

// ─── Credential resolution ──────────────────────────────────────────────────

/// A resolved credential reference from a [`ProviderAuth`].
#[derive(Debug)]
pub enum ResolvedCredential<'a> {
    /// An OAuth account (needs token refresh handling).
    OAuthAccount(&'a types::AccountEntry),
    /// A named API key.
    ApiKey(&'a types::ApiKeyEntry),
}

/// Resolve which credential to use for a provider.
///
/// Resolution order:
/// 1. `credential_override` (for session pinning — keeps in-progress sessions stable)
/// 2. `pa.active_credential` (user's explicit selection)
/// 3. Fallback: `accounts[0]` → `api_keys[0]`
///
/// If a referenced credential no longer exists (was deleted), falls through to
/// the next level. This means a deleted pinned credential gracefully degrades
/// to the user's active selection, then to the first available credential.
pub fn resolve_credential<'a>(
    pa: &'a ProviderAuth,
    credential_override: Option<&ActiveCredential>,
) -> Option<ResolvedCredential<'a>> {
    // Try override first, then active_credential, then fallback
    for source in [credential_override, pa.active_credential.as_ref()] {
        if let Some(cred) = source {
            if let Some(resolved) = lookup_credential(pa, cred) {
                return Some(resolved);
            }
            // Referenced credential doesn't exist — fall through
        }
    }

    // Fallback: first available account, then first available API key
    if let Some(accounts) = &pa.accounts {
        if let Some(acct) = accounts.first() {
            return Some(ResolvedCredential::OAuthAccount(acct));
        }
    }
    if let Some(api_keys) = &pa.api_keys {
        if let Some(key) = api_keys.first() {
            return Some(ResolvedCredential::ApiKey(key));
        }
    }

    None
}

/// Look up a specific credential by type and label.
fn lookup_credential<'a>(
    pa: &'a ProviderAuth,
    cred: &ActiveCredential,
) -> Option<ResolvedCredential<'a>> {
    match cred {
        ActiveCredential::OAuth { label } => pa
            .accounts
            .as_ref()?
            .iter()
            .find(|a| a.label == *label)
            .map(ResolvedCredential::OAuthAccount),
        ActiveCredential::ApiKey { label } => pa
            .api_keys
            .as_ref()?
            .iter()
            .find(|k| k.label == *label)
            .map(ResolvedCredential::ApiKey),
    }
}

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

    #[test]
    fn urlencoded_preserves_slashes() {
        let encoded = urlencoded("https://console.anthropic.com/oauth/code/callback");
        assert!(encoded.contains("https%3A//console.anthropic.com/oauth/code/callback"));
    }

    #[test]
    fn urlencoded_preserves_safe_chars() {
        assert_eq!(urlencoded("a_b.c-d~e"), "a_b.c-d~e");
    }

    // ── resolve_credential ──

    fn make_account(label: &str) -> types::AccountEntry {
        types::AccountEntry {
            label: label.to_string(),
            oauth: OAuthTokens {
                access_token: format!("tok-{label}"),
                refresh_token: "ref".to_string(),
                expires_at: now_ms() + 3_600_000,
            },
        }
    }

    fn make_api_key(label: &str) -> ApiKeyEntry {
        ApiKeyEntry {
            label: label.to_string(),
            key: format!("sk-{label}"),
        }
    }

    #[test]
    fn resolve_credential_active_oauth() {
        let pa = ProviderAuth {
            accounts: Some(vec![make_account("a1"), make_account("a2")]),
            active_credential: Some(ActiveCredential::OAuth {
                label: "a2".to_string(),
            }),
            ..Default::default()
        };
        let resolved = resolve_credential(&pa, None).unwrap();
        match resolved {
            ResolvedCredential::OAuthAccount(acct) => assert_eq!(acct.label, "a2"),
            _ => panic!("expected OAuthAccount"),
        }
    }

    #[test]
    fn resolve_credential_active_api_key() {
        let pa = ProviderAuth {
            api_keys: Some(vec![make_api_key("k1"), make_api_key("k2")]),
            active_credential: Some(ActiveCredential::ApiKey {
                label: "k2".to_string(),
            }),
            ..Default::default()
        };
        let resolved = resolve_credential(&pa, None).unwrap();
        match resolved {
            ResolvedCredential::ApiKey(k) => assert_eq!(k.label, "k2"),
            _ => panic!("expected ApiKey"),
        }
    }

    #[test]
    fn resolve_credential_override_beats_active() {
        let pa = ProviderAuth {
            accounts: Some(vec![make_account("a1"), make_account("a2")]),
            active_credential: Some(ActiveCredential::OAuth {
                label: "a1".to_string(),
            }),
            ..Default::default()
        };
        let override_cred = ActiveCredential::OAuth {
            label: "a2".to_string(),
        };
        let resolved = resolve_credential(&pa, Some(&override_cred)).unwrap();
        match resolved {
            ResolvedCredential::OAuthAccount(acct) => assert_eq!(acct.label, "a2"),
            _ => panic!("expected OAuthAccount"),
        }
    }

    #[test]
    fn resolve_credential_deleted_override_falls_to_active() {
        let pa = ProviderAuth {
            accounts: Some(vec![make_account("a1")]),
            active_credential: Some(ActiveCredential::OAuth {
                label: "a1".to_string(),
            }),
            ..Default::default()
        };
        let override_cred = ActiveCredential::OAuth {
            label: "deleted".to_string(),
        };
        let resolved = resolve_credential(&pa, Some(&override_cred)).unwrap();
        match resolved {
            ResolvedCredential::OAuthAccount(acct) => assert_eq!(acct.label, "a1"),
            _ => panic!("expected OAuthAccount"),
        }
    }

    #[test]
    fn resolve_credential_deleted_active_falls_to_first() {
        let pa = ProviderAuth {
            accounts: Some(vec![make_account("a1")]),
            active_credential: Some(ActiveCredential::OAuth {
                label: "deleted".to_string(),
            }),
            ..Default::default()
        };
        let resolved = resolve_credential(&pa, None).unwrap();
        match resolved {
            ResolvedCredential::OAuthAccount(acct) => assert_eq!(acct.label, "a1"),
            _ => panic!("expected OAuthAccount"),
        }
    }

    #[test]
    fn resolve_credential_no_active_uses_first_account() {
        let pa = ProviderAuth {
            accounts: Some(vec![make_account("a1"), make_account("a2")]),
            ..Default::default()
        };
        let resolved = resolve_credential(&pa, None).unwrap();
        match resolved {
            ResolvedCredential::OAuthAccount(acct) => assert_eq!(acct.label, "a1"),
            _ => panic!("expected OAuthAccount"),
        }
    }

    #[test]
    fn resolve_credential_no_accounts_uses_first_api_key() {
        let pa = ProviderAuth {
            api_keys: Some(vec![make_api_key("k1")]),
            ..Default::default()
        };
        let resolved = resolve_credential(&pa, None).unwrap();
        match resolved {
            ResolvedCredential::ApiKey(k) => assert_eq!(k.label, "k1"),
            _ => panic!("expected ApiKey"),
        }
    }

    #[test]
    fn resolve_credential_accounts_before_api_keys_in_fallback() {
        let pa = ProviderAuth {
            accounts: Some(vec![make_account("a1")]),
            api_keys: Some(vec![make_api_key("k1")]),
            ..Default::default()
        };
        let resolved = resolve_credential(&pa, None).unwrap();
        match resolved {
            ResolvedCredential::OAuthAccount(acct) => assert_eq!(acct.label, "a1"),
            _ => panic!("expected OAuthAccount over ApiKey in fallback"),
        }
    }

    #[test]
    fn resolve_credential_empty_provider_returns_none() {
        let pa = ProviderAuth::default();
        assert!(resolve_credential(&pa, None).is_none());
    }

    #[test]
    fn resolve_credential_empty_arrays_returns_none() {
        let pa = ProviderAuth {
            accounts: Some(vec![]),
            api_keys: Some(vec![]),
            ..Default::default()
        };
        assert!(resolve_credential(&pa, None).is_none());
    }

    #[test]
    fn resolve_credential_override_deleted_active_deleted_falls_to_first() {
        let pa = ProviderAuth {
            accounts: Some(vec![make_account("a1")]),
            api_keys: Some(vec![make_api_key("k1")]),
            active_credential: Some(ActiveCredential::OAuth {
                label: "deleted".to_string(),
            }),
            ..Default::default()
        };
        let override_cred = ActiveCredential::ApiKey {
            label: "also-deleted".to_string(),
        };
        // Both override and active point to deleted creds → fallback to first account
        let resolved = resolve_credential(&pa, Some(&override_cred)).unwrap();
        match resolved {
            ResolvedCredential::OAuthAccount(acct) => assert_eq!(acct.label, "a1"),
            _ => panic!("expected fallback to first account"),
        }
    }
}
