//! Canonical OAuth provider routing, flow state, and auth operations.
//!
//! Engine functions own pending-flow TTL and event publication; contributor
//! shell code owns only terminal/browser/callback interaction. Both use the
//! provider configuration, PKCE construction, and exchange logic in `flows`.
//! The contributor callback bridge additionally requests independent CSRF
//! state because it can return and validate that value. This root also keeps
//! contributor completion behind the auth domain's locked storage boundary.

use std::path::Path;

use crate::domains::auth::credentials::{AuthError, OAuthTokens};

pub(crate) mod flows;
mod operations;

pub(crate) use operations::*;

pub(crate) const OAUTH_PROVIDERS: &[&str] = &["anthropic", "openai-codex", "google"];
pub(crate) const OAUTH_FLOW_TTL_SECS: u64 = 600;

pub(crate) fn contributor_auth_storage_is_initialized(path: &Path) -> Result<bool, AuthError> {
    Ok(crate::domains::auth::credentials::load_auth_storage(path)?
        .and_then(|storage| storage.bearer_token)
        .is_some_and(|token| !token.trim().is_empty()))
}

pub(crate) fn save_contributor_oauth_tokens(
    path: &Path,
    provider: &str,
    label: &str,
    tokens: &OAuthTokens,
) -> Result<bool, AuthError> {
    let _lock = crate::domains::auth::credentials::acquire_auth_file_lock(path)?;
    if !contributor_auth_storage_is_initialized(path)? {
        return Ok(false);
    }
    crate::domains::auth::credentials::storage::save_account_oauth_tokens(
        path, provider, label, tokens,
    )?;
    Ok(true)
}
