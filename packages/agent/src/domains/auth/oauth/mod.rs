//! OAuth flow state and canonical auth OAuth operations.

pub(crate) mod flows;
mod operations;

pub(crate) use operations::*;

pub(crate) const OAUTH_PROVIDERS: &[&str] = &["anthropic", "openai-codex", "google"];
pub(crate) const OAUTH_FLOW_TTL_SECS: u64 = 600;
