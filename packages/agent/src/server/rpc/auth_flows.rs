//! Shared OAuth flow state for auth engine functions.
//!
//! Auth behavior is owned by canonical `auth::*` functions. Pending OAuth
//! records live here so production code does not depend on test-only RPC
//! handler fixtures.

/// In-memory state for a pending OAuth flow.
pub struct PendingOAuthFlow {
    /// PKCE code verifier (Anthropic/Google) or random state (OpenAI) for this flow.
    pub verifier: String,
    /// OAuth provider name (e.g. `"anthropic"`, `"openai-codex"`).
    pub provider: String,
    /// When this flow was initiated.
    pub created_at: std::time::Instant,
}
