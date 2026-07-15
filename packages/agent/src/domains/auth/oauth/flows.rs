//! Shared OAuth flow construction and pending state.
//!
//! Provider policy, PKCE construction, optional independent CSRF state, and
//! code exchange live here so engine functions and contributor CLI
//! orchestration use one implementation.
//! Pending OAuth records also live here so production code does not depend on
//! transport test fixtures.

use std::path::Path;

use crate::domains::auth::credentials::{AuthError, OAuthTokens};

fn load_google_config(
    auth_path: &Path,
) -> Result<Option<crate::domains::auth::credentials::google::GoogleOAuthConfig>, AuthError> {
    let Some(auth) =
        crate::domains::auth::credentials::storage::get_google_provider_auth(auth_path)?
    else {
        return Ok(None);
    };
    let Some(client_id) = auth.client_id else {
        return Ok(None);
    };
    let base = crate::domains::auth::credentials::google::cloud_code_assist_config();
    Ok(Some(
        crate::domains::auth::credentials::google::GoogleOAuthConfig {
            oauth: crate::domains::auth::credentials::OAuthConfig {
                client_id,
                client_secret: auth.client_secret,
                ..base.oauth
            },
            ..base
        },
    ))
}

/// Prepare a canonical PKCE flow for the engine's existing flow-ID/code contract.
///
/// `Ok(None)` means either an unknown provider or Google without its required
/// user-owned client ID; callers retain their surface-specific error wording.
pub(crate) fn prepare_oauth_flow(
    provider: &str,
    auth_path: &Path,
) -> Result<Option<OAuthFlowStart>, AuthError> {
    prepare_oauth_flow_inner(provider, auth_path, None)
}

/// Prepare a PKCE flow whose callback coordinator will return OAuth state.
pub(crate) fn prepare_oauth_flow_with_state(
    provider: &str,
    auth_path: &Path,
) -> Result<Option<OAuthFlowStart>, AuthError> {
    if !matches!(provider, "anthropic" | "openai-codex") {
        return Ok(None);
    }
    let state = crate::domains::auth::credentials::pkce::generate_state();
    prepare_oauth_flow_inner(provider, auth_path, Some(state))
}

fn prepare_oauth_flow_inner(
    provider: &str,
    auth_path: &Path,
    state: Option<String>,
) -> Result<Option<OAuthFlowStart>, AuthError> {
    let pair = crate::domains::auth::credentials::pkce::generate_pkce();
    let (auth_url, redirect_uri) = match provider {
        "anthropic" => {
            let config = crate::domains::auth::credentials::anthropic::default_config();
            (
                crate::domains::auth::credentials::anthropic::get_authorization_url_with_state(
                    &config,
                    &pair.challenge,
                    state.as_deref(),
                ),
                config.redirect_uri,
            )
        }
        "openai-codex" => {
            let config = crate::domains::auth::credentials::openai::default_config();
            (
                crate::domains::auth::credentials::openai::get_authorization_url_with_state(
                    &config,
                    &pair.challenge,
                    state.as_deref(),
                ),
                config.redirect_uri,
            )
        }
        "google" => {
            debug_assert!(state.is_none());
            let Some(config) = load_google_config(auth_path)? else {
                return Ok(None);
            };
            (
                crate::domains::auth::credentials::google::get_authorization_url(
                    &config,
                    &pair.challenge,
                ),
                config.oauth.redirect_uri,
            )
        }
        _ => return Ok(None),
    };
    Ok(Some(OAuthFlowStart {
        auth_url,
        verifier: pair.verifier,
        state,
        redirect_uri,
    }))
}

/// Exchange a code through the same provider implementation used for refresh.
pub(crate) async fn exchange_oauth_code(
    provider: &str,
    auth_path: &Path,
    code: &str,
    verifier: &str,
    state: Option<&str>,
) -> Result<Option<OAuthTokens>, AuthError> {
    let tokens = match provider {
        "anthropic" => {
            let config = crate::domains::auth::credentials::anthropic::default_config();
            crate::domains::auth::credentials::anthropic::exchange_code_for_tokens(
                &config, code, verifier, state,
            )
            .await?
        }
        "openai-codex" => {
            let config = crate::domains::auth::credentials::openai::default_config();
            crate::domains::auth::credentials::openai::exchange_code_for_tokens(
                &config, code, verifier,
            )
            .await?
        }
        "google" => {
            let Some(config) = load_google_config(auth_path)? else {
                return Ok(None);
            };
            crate::domains::auth::credentials::google::exchange_code_for_tokens(
                &config, code, verifier,
            )
            .await?
        }
        _ => return Ok(None),
    };
    Ok(Some(tokens))
}

/// Provider-owned values needed by a browser/callback coordinator.
pub(crate) struct OAuthFlowStart {
    pub(crate) auth_url: String,
    pub(crate) verifier: String,
    pub(crate) state: Option<String>,
    pub(crate) redirect_uri: String,
}

/// In-memory state for a pending OAuth flow.
pub struct PendingOAuthFlow {
    /// PKCE code verifier retained only by the server.
    pub verifier: String,
    /// OAuth provider name (e.g. `"anthropic"`, `"openai-codex"`).
    pub provider: String,
    /// When this flow was initiated.
    pub created_at: std::time::Instant,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_and_unconfigured_providers_do_not_create_flows() {
        let auth_path = tempfile::tempdir().unwrap().path().join("auth.json");
        assert!(prepare_oauth_flow("openai", &auth_path).unwrap().is_none());
        assert!(prepare_oauth_flow("google", &auth_path).unwrap().is_none());
        assert!(
            prepare_oauth_flow_with_state("google", &auth_path)
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn default_provider_begin_keeps_verifier_out_of_authorization_url() {
        let auth_path = tempfile::tempdir().unwrap().path().join("auth.json");
        for provider in ["anthropic", "openai-codex"] {
            let flow = prepare_oauth_flow_with_state(provider, &auth_path)
                .unwrap()
                .unwrap();
            let state = flow.state.as_deref().unwrap();
            assert!(flow.auth_url.contains("code_challenge="));
            assert!(flow.auth_url.contains("code_challenge_method=S256"));
            assert_ne!(state, flow.verifier);
            assert!(flow.auth_url.contains(&format!("state={state}")));
            assert!(!flow.auth_url.contains(&flow.verifier));
        }
    }

    #[test]
    fn engine_flow_omits_state_that_its_wire_contract_cannot_return() {
        let auth_path = tempfile::tempdir().unwrap().path().join("auth.json");
        let flow = prepare_oauth_flow("openai-codex", &auth_path)
            .unwrap()
            .unwrap();
        assert!(flow.state.is_none());
        assert!(!flow.auth_url.contains("state="));
        assert!(!flow.auth_url.contains(&flow.verifier));
    }

    #[test]
    fn google_flow_uses_user_owned_client_configuration() {
        let dir = tempfile::tempdir().unwrap();
        let auth_path = dir.path().join("auth.json");
        let mut storage = crate::domains::auth::credentials::AuthStorage::new();
        storage.set_google_auth(&crate::domains::auth::credentials::GoogleProviderAuth {
            client_id: Some("configured-client".into()),
            ..Default::default()
        });
        crate::domains::auth::credentials::save_auth_storage(&auth_path, &mut storage).unwrap();

        let flow = prepare_oauth_flow("google", &auth_path).unwrap().unwrap();
        assert!(flow.auth_url.contains("client_id=configured-client"));
        assert!(flow.state.is_none());
        assert!(!flow.auth_url.contains("state="));
        assert!(!flow.auth_url.contains(&flow.verifier));
        assert_eq!(flow.redirect_uri, "http://localhost:45289");
    }
}
