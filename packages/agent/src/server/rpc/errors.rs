//! RPC error codes and error type.
//!
//! # INVARIANT: not-found messages echo caller-supplied IDs under
//! trusted-local
//!
//! `NotFound` errors today carry a human-readable `message` that
//! includes the caller-supplied identifier, e.g. `"Session 'abc123' not
//! found"`. This is deliberate: iOS surfaces the message directly in
//! diagnostic UI, and under the trusted-local threat model (the only
//! callers are the user's own devices over Tailscale) the identifier
//! is already known to the caller.
//!
//! If the threat model ever changes (shared Tailnet, multi-user host,
//! adversarial client), that echo becomes a low-value information
//! leak. The forward-compat mechanism is [`format_not_found`] +
//! [`ErrorRedactMode`] — flip [`current_redact_mode`] to `Redact` (or
//! wire it to a `settings.errors.redactMode` setting), and every
//! caller routed through the helper emits opaque `"Session not
//! found"` messages instead. Call sites that format `NotFound`
//! messages by hand today should migrate to the helper as a side
//! effect of any touch.
//!
//! Regression guard: `tests::error_messages_redact_mode_removes_user_input`
//! (in this file's `#[cfg(test)] mod tests`).

use crate::server::rpc::types::RpcErrorBody;

// ── Error code constants ────────────────────────────────────────────

/// Invalid or missing parameters.
pub const INVALID_PARAMS: &str = "INVALID_PARAMS";
/// Unexpected internal error.
pub const INTERNAL_ERROR: &str = "INTERNAL_ERROR";
/// Method not found in the registry.
pub const METHOD_NOT_FOUND: &str = "METHOD_NOT_FOUND";
/// Resource or feature not available.
pub const NOT_AVAILABLE: &str = "NOT_AVAILABLE";
/// Generic not-found.
pub const NOT_FOUND: &str = "NOT_FOUND";
/// Session does not exist.
pub const SESSION_NOT_FOUND: &str = "SESSION_NOT_FOUND";
/// File does not exist.
pub const FILE_NOT_FOUND: &str = "FILE_NOT_FOUND";
/// Generic file I/O error.
pub const FILE_ERROR: &str = "FILE_ERROR";
/// Filesystem operation error.
pub const FILESYSTEM_ERROR: &str = "FILESYSTEM_ERROR";
/// Resource already exists.
pub const ALREADY_EXISTS: &str = "ALREADY_EXISTS";
/// Git operation error.
pub const GIT_ERROR: &str = "GIT_ERROR";
/// Session is currently processing a prompt from another connection.
pub const SESSION_BUSY: &str = "SESSION_BUSY";
/// Engine idempotency key replay/conflict could not be accepted.
pub const IDEMPOTENCY_CONFLICT: &str = "IDEMPOTENCY_CONFLICT";

// ── Typed git workflow errors ───────────────────────────────────────
//
// Every git workflow handler (`git.push`, `git.syncMain`,
// `worktree.commit`, `worktree.finalizeSession`, etc.) maps its
// `WorktreeError` variants to these codes via `map_worktree_error` in
// `error_mapping.rs`. Clients switch on the code to show a friendly
// message instead of a generic "internal error".

/// Push/finalize refused because the target branch is in the user's
/// protected-branches list and `overrideProtected` was not set.
pub const PROTECTED_BRANCH: &str = "PROTECTED_BRANCH";
/// The requested remote isn't configured for this repository
/// (e.g. `git push` with no `origin`).
pub const NO_REMOTE: &str = "NO_REMOTE";
/// Push rejected because the upstream ref moved since the last fetch.
pub const NON_FAST_FORWARD: &str = "NON_FAST_FORWARD";
/// Remote authentication failed (SSH key rejected, HTTPS 401, etc.).
pub const GIT_AUTH_FAILED: &str = "GIT_AUTH_FAILED";
/// Remote network operation timed out or host was unreachable.
pub const GIT_NETWORK_ERROR: &str = "GIT_NETWORK_ERROR";
/// Session has no worktree AND no resolvable fallback working directory.
pub const WORKTREE_NOT_FOUND: &str = "WORKTREE_NOT_FOUND";
/// Operation refused because the working tree has uncommitted changes.
pub const DIRTY_WORKING_TREE: &str = "DIRTY_WORKING_TREE";
/// `rebaseOnMain` called without a `mainBranch` override and the
/// session has no recorded base branch.
pub const MISSING_BASE_BRANCH: &str = "MISSING_BASE_BRANCH";
/// A git ref the caller named could not be resolved to a commit.
pub const REF_NOT_FOUND: &str = "REF_NOT_FOUND";
/// Create-branch refused because the branch already exists.
pub const BRANCH_EXISTS: &str = "BRANCH_EXISTS";
/// Delete/rename refused because the branch is currently checked out
/// in another worktree.
pub const BRANCH_ACTIVE: &str = "BRANCH_ACTIVE";
/// The target directory isn't a git repository.
pub const NOT_GIT_REPO: &str = "NOT_GIT_REPO";

// ── Typed event-store errors ─────────────────────────────────────────
//
// `EventStoreError` variants get mapped to these codes via
// `map_event_store_error`. Most callers in the events / session /
// memory / blob handlers should use it rather than wrapping into
// `RpcError::Internal`.

/// Requested event was not found.
pub const EVENT_NOT_FOUND: &str = "EVENT_NOT_FOUND";
/// Requested workspace was not found.
pub const WORKSPACE_NOT_FOUND: &str = "WORKSPACE_NOT_FOUND";
/// Requested blob was not found.
pub const BLOB_NOT_FOUND: &str = "BLOB_NOT_FOUND";

// ── Typed cron errors ────────────────────────────────────────────────
//
// `CronError` variants get mapped to these codes via
// `map_cron_error`. Most callers in the cron handler should use it
// rather than wrapping into `RpcError::Internal`.

/// Cron job not found.
pub const CRON_NOT_FOUND: &str = "CRON_NOT_FOUND";
/// Duplicate cron job name.
pub const CRON_DUPLICATE_NAME: &str = "CRON_DUPLICATE_NAME";
/// Invalid cron expression syntax.
pub const CRON_INVALID_EXPRESSION: &str = "CRON_INVALID_EXPRESSION";
/// Invalid IANA timezone.
pub const CRON_INVALID_TIMEZONE: &str = "CRON_INVALID_TIMEZONE";
/// Cron job execution timed out.
pub const CRON_TIMED_OUT: &str = "CRON_TIMED_OUT";
/// Cron job execution was cancelled (shutdown or job disabled).
pub const CRON_CANCELLED: &str = "CRON_CANCELLED";

// ── Typed auth errors ────────────────────────────────────────────────
//
// `AuthError` variants get mapped to these codes via `map_auth_error`.

/// No authentication configured for the requested provider.
pub const AUTH_NOT_CONFIGURED: &str = "AUTH_NOT_CONFIGURED";
/// OAuth token has expired and refresh failed.
pub const AUTH_TOKEN_EXPIRED: &str = "AUTH_TOKEN_EXPIRED";
/// OAuth flow returned an error from the upstream provider.
pub const AUTH_OAUTH_ERROR: &str = "AUTH_OAUTH_ERROR";

// ── Typed import errors ──────────────────────────────────────────────
//
// `ImportError` variants get mapped to these codes via `map_import_error`.

/// Source session file was not found at the requested path.
pub const IMPORT_SESSION_NOT_FOUND: &str = "IMPORT_SESSION_NOT_FOUND";
/// Source session was already imported (idempotent guard).
pub const IMPORT_ALREADY_IMPORTED: &str = "IMPORT_ALREADY_IMPORTED";
/// Source session had no importable records after parsing.
pub const IMPORT_EMPTY_SESSION: &str = "IMPORT_EMPTY_SESSION";
/// No Claude Code projects directory found.
pub const IMPORT_NO_CLAUDE_DIRECTORY: &str = "IMPORT_NO_CLAUDE_DIRECTORY";

// ── Version handshake (L6) ──────────────────────────────────────────
//
// `system.ping` requires a numeric `protocolVersion` from the client
// and returns the server's current version plus a compatibility
// verdict. Version numbers are monotonic integers bumped only on
// breaking wire-format changes — field adds that old clients can
// safely ignore do NOT bump the protocol version.

/// Client advertised a protocol version below
/// [`MIN_CLIENT_PROTOCOL_VERSION`]. The server refuses to serve
/// requests; the client must upgrade.
pub const CLIENT_VERSION_UNSUPPORTED: &str = "CLIENT_VERSION_UNSUPPORTED";

/// RPC error type returned by handlers.
#[derive(Debug, thiserror::Error)]
pub enum RpcError {
    /// Required parameter missing or wrong type.
    #[error("{message}")]
    InvalidParams {
        /// Description of what is wrong.
        message: String,
    },

    /// Requested resource not found.
    #[error("{message}")]
    NotFound {
        /// Specific error code (e.g. `SESSION_NOT_FOUND`).
        code: String,
        /// Human-readable message.
        message: String,
    },

    /// Internal server error.
    #[error("{message}")]
    Internal {
        /// Description.
        message: String,
    },

    /// Feature or resource not available.
    #[error("{message}")]
    NotAvailable {
        /// Description.
        message: String,
    },

    /// Domain-specific error with arbitrary code.
    #[error("{message}")]
    Custom {
        /// Machine-readable code.
        code: String,
        /// Human-readable message.
        message: String,
        /// Optional structured details.
        details: Option<serde_json::Value>,
    },
}

impl RpcError {
    /// Machine-readable error code for this variant.
    pub fn code(&self) -> &str {
        match self {
            Self::InvalidParams { .. } => INVALID_PARAMS,
            Self::NotFound { code, .. } | Self::Custom { code, .. } => code,
            Self::Internal { .. } => INTERNAL_ERROR,
            Self::NotAvailable { .. } => NOT_AVAILABLE,
        }
    }

    /// Convert to the wire-format error body.
    pub fn to_error_body(&self) -> RpcErrorBody {
        RpcErrorBody {
            code: self.code().to_owned(),
            message: self.to_string(),
            details: match self {
                Self::Custom { details, .. } => details.clone(),
                _ => None,
            },
        }
    }
}

/// Serialize a value to JSON, mapping errors to [`RpcError::Internal`].
pub fn to_json_value<T: serde::Serialize>(val: &T) -> Result<serde_json::Value, RpcError> {
    serde_json::to_value(val).map_err(|e| RpcError::Internal {
        message: e.to_string(),
    })
}

// ── NotFound message formatting (M1) ────────────────────────────────

/// How `NotFound` error messages render caller-supplied identifiers.
///
/// See the module-level INVARIANT for why [`Echo`] is the current
/// default and when to flip to [`Redact`].
///
/// [`Echo`]: ErrorRedactMode::Echo
/// [`Redact`]: ErrorRedactMode::Redact
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorRedactMode {
    /// Echo the caller-supplied identifier in the message — the
    /// trusted-local default. Example: `"Session 'abc123' not found"`.
    Echo,
    /// Produce an opaque message with no caller-supplied content.
    /// Example: `"Session not found"`.
    Redact,
}

/// Current error-message redaction mode.
///
/// Today this always returns [`ErrorRedactMode::Echo`] by design — the
/// trusted-local threat model permits echoing identifiers. When the
/// threat model changes, route this through a
/// `settings.errors.redactMode` setting (or equivalent runtime flag)
/// and every call site using [`format_not_found`] flips at once.
pub fn current_redact_mode() -> ErrorRedactMode {
    ErrorRedactMode::Echo
}

/// Format a `NotFound` error message under the configured redact mode.
///
/// Call sites that construct `NotFound` messages via `format!(...)`
/// with a user-supplied id should migrate to this helper — it is the
/// single choke point that honors [`current_redact_mode`].
pub fn format_not_found(kind: &str, id: &str) -> String {
    format_not_found_with_mode(current_redact_mode(), kind, id)
}

/// Mode-parameterized variant of [`format_not_found`]. Exposed for
/// tests that need to pin the rendering without mutating global state.
pub fn format_not_found_with_mode(mode: ErrorRedactMode, kind: &str, id: &str) -> String {
    match mode {
        ErrorRedactMode::Echo => format!("{kind} '{id}' not found"),
        ErrorRedactMode::Redact => format!("{kind} not found"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invalid_params_code() {
        let err = RpcError::InvalidParams {
            message: "bad".into(),
        };
        assert_eq!(err.code(), INVALID_PARAMS);
        assert_eq!(err.to_string(), "bad");
    }

    #[test]
    fn not_found_code() {
        let err = RpcError::NotFound {
            code: SESSION_NOT_FOUND.into(),
            message: "gone".into(),
        };
        assert_eq!(err.code(), SESSION_NOT_FOUND);
    }

    #[test]
    fn internal_code() {
        let err = RpcError::Internal {
            message: "boom".into(),
        };
        assert_eq!(err.code(), INTERNAL_ERROR);
    }

    #[test]
    fn custom_code_and_details() {
        let err = RpcError::Custom {
            code: "MY_CODE".into(),
            message: "custom".into(),
            details: Some(serde_json::json!({"x": 1})),
        };
        assert_eq!(err.code(), "MY_CODE");
        let body = err.to_error_body();
        assert_eq!(body.code, "MY_CODE");
        assert_eq!(body.details.unwrap()["x"], 1);
    }

    #[test]
    fn session_busy_code() {
        let err = RpcError::Custom {
            code: SESSION_BUSY.into(),
            message: "Session is processing a prompt from another connection".into(),
            details: None,
        };
        assert_eq!(err.code(), SESSION_BUSY);
        let body = err.to_error_body();
        assert_eq!(body.code, "SESSION_BUSY");
        assert!(body.message.contains("processing"));
    }

    #[test]
    fn new_git_error_codes_have_distinct_values() {
        let codes = [
            PROTECTED_BRANCH,
            NO_REMOTE,
            NON_FAST_FORWARD,
            GIT_AUTH_FAILED,
            GIT_NETWORK_ERROR,
            WORKTREE_NOT_FOUND,
            DIRTY_WORKING_TREE,
            MISSING_BASE_BRANCH,
            REF_NOT_FOUND,
            BRANCH_EXISTS,
            BRANCH_ACTIVE,
            NOT_GIT_REPO,
            GIT_ERROR,
        ];
        let unique: std::collections::HashSet<_> = codes.iter().collect();
        assert_eq!(unique.len(), codes.len(), "error codes must be distinct");
    }

    #[test]
    fn event_store_codes_are_distinct() {
        let codes = [
            SESSION_NOT_FOUND,
            EVENT_NOT_FOUND,
            WORKSPACE_NOT_FOUND,
            BLOB_NOT_FOUND,
        ];
        let unique: std::collections::HashSet<_> = codes.iter().collect();
        assert_eq!(
            unique.len(),
            codes.len(),
            "event-store error codes must be distinct"
        );
    }

    #[test]
    fn cron_codes_are_distinct() {
        let codes = [
            CRON_NOT_FOUND,
            CRON_DUPLICATE_NAME,
            CRON_INVALID_EXPRESSION,
            CRON_INVALID_TIMEZONE,
            CRON_TIMED_OUT,
            CRON_CANCELLED,
        ];
        let unique: std::collections::HashSet<_> = codes.iter().collect();
        assert_eq!(
            unique.len(),
            codes.len(),
            "cron error codes must be distinct"
        );
    }

    #[test]
    fn auth_codes_are_distinct() {
        let codes = [AUTH_NOT_CONFIGURED, AUTH_TOKEN_EXPIRED, AUTH_OAUTH_ERROR];
        let unique: std::collections::HashSet<_> = codes.iter().collect();
        assert_eq!(
            unique.len(),
            codes.len(),
            "auth error codes must be distinct"
        );
    }

    #[test]
    fn import_codes_are_distinct() {
        let codes = [
            IMPORT_SESSION_NOT_FOUND,
            IMPORT_ALREADY_IMPORTED,
            IMPORT_EMPTY_SESSION,
            IMPORT_NO_CLAUDE_DIRECTORY,
        ];
        let unique: std::collections::HashSet<_> = codes.iter().collect();
        assert_eq!(
            unique.len(),
            codes.len(),
            "import error codes must be distinct"
        );
    }

    // ── M1: not-found message redaction contract ─────────────────────

    /// Under the trusted-local threat model the helper echoes the
    /// caller-supplied identifier — iOS diagnostic UI relies on it.
    #[test]
    fn format_not_found_echoes_id_under_trusted_local() {
        assert_eq!(
            format_not_found("Session", "abc123"),
            "Session 'abc123' not found"
        );
        assert_eq!(current_redact_mode(), ErrorRedactMode::Echo);
    }

    /// Forward-compat contract: if the threat model ever shifts and
    /// `current_redact_mode` flips to [`ErrorRedactMode::Redact`], no
    /// caller-supplied content may leak into the message. Every single
    /// ID passed in gets dropped — pin the contract here so a future
    /// change to the formatter can't reintroduce the leak silently.
    #[test]
    fn error_messages_redact_mode_removes_user_input() {
        let victims = [
            ("Session", "abc123"),
            ("Snippet", "../../etc/passwd"),
            ("Event", "<script>alert(1)</script>"),
            ("Workspace", "  leading-space-id  "),
            ("Session", ""),
        ];
        for (kind, id) in victims {
            let msg = format_not_found_with_mode(ErrorRedactMode::Redact, kind, id);
            assert_eq!(
                msg,
                format!("{kind} not found"),
                "redact must drop id {id:?}"
            );
            assert!(
                !msg.contains(id) || id.is_empty(),
                "redact mode must not leak id {id:?} (got {msg:?})"
            );
        }
    }

    #[test]
    fn format_not_found_with_mode_is_pure() {
        // Repeated calls with identical inputs return identical output
        // — the formatter never consults global state other than the
        // explicitly-passed mode.
        let a = format_not_found_with_mode(ErrorRedactMode::Echo, "A", "1");
        let b = format_not_found_with_mode(ErrorRedactMode::Echo, "A", "1");
        assert_eq!(a, b);
    }

    #[test]
    fn to_error_body_without_details() {
        let err = RpcError::NotAvailable {
            message: "nope".into(),
        };
        assert_eq!(err.code(), NOT_AVAILABLE);
        let body = err.to_error_body();
        assert_eq!(body.code, NOT_AVAILABLE);
        assert_eq!(body.message, "nope");
        assert!(body.details.is_none());
    }
}
