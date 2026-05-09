//! Auth operation implementations.
//!
//! Credential reads, credential mutation, OAuth flow state, account selection,
//! and auth stream publication live here behind canonical `auth::*` functions.

use std::collections::HashMap;
use std::path::Path;

use crate::domains::auth::provider_credentials::storage::{
    acquire_auth_file_lock, clear_provider_auth, load_auth_storage, load_or_init_for_write,
    save_auth_storage, save_named_api_key,
};
use crate::domains::auth::provider_credentials::types::{
    AccountEntry, ActiveCredential, ApiKeyEntry, OAuthTokens, ProviderAuth, ServiceAuth,
};
use crate::shared::server::error_mapping::map_auth_error;

const DEFAULT_API_KEY_LABEL: &str = "Default";
const KNOWN_PROVIDERS: &[&str] = &["anthropic", "openai-codex", "google", "minimax", "kimi"];
const KNOWN_SERVICES: &[&str] = &["brave", "exa"];
const OAUTH_PROVIDERS: &[&str] = &["anthropic", "openai-codex", "google"];
const OAUTH_FLOW_TTL_SECS: u64 = 600;

// Operation modules grouped by workflow.

mod accounts;
pub(crate) use accounts::*;
mod oauth;
pub(crate) use oauth::*;
mod provider_state;
pub(crate) use provider_state::*;
