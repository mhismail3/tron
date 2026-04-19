//! RPC error codes and error type.

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

// ── Typed git workflow errors ───────────────────────────────────────
//
// Every git workflow handler (`git.push`, `git.syncMain`,
// `worktree.commit`, `worktree.finalizeSession`, etc.) maps its
// `WorktreeError` variants to these codes via `map_worktree_error` in
// `handlers/mod.rs`. Clients switch on the code to show a friendly
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
        assert_eq!(unique.len(), codes.len(), "event-store error codes must be distinct");
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
