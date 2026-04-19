//! Domain-error → RPC-error mapping.
//!
//! Each helper here turns a typed domain error into the most specific
//! `RpcError` variant available, so iOS clients see actionable codes
//! (`PROTECTED_BRANCH`, `NON_FAST_FORWARD`, …) instead of a blanket
//! `INTERNAL_ERROR`. New error mappers (event-store, cron, sandbox, …)
//! belong in this file alongside `map_worktree_error`.

use crate::events::errors::EventStoreError;
use crate::server::rpc::errors::{self as codes, RpcError};
use crate::worktree::WorktreeError;

/// Map a `WorktreeError` to the most specific `RpcError` variant available.
/// Every git workflow handler routes its coordinator errors through this
/// one function.
///
/// INVARIANT: the `match` is exhaustive over `WorktreeError` — adding a
/// new variant forces a compile error here. Do NOT add a `_` arm; every
/// variant must be classified by hand.
pub(crate) fn map_worktree_error(e: WorktreeError) -> RpcError {
    use WorktreeError as W;
    match e {
        W::NotFound { session_id } => RpcError::NotFound {
            code: codes::WORKTREE_NOT_FOUND.into(),
            message: format!("No worktree or working directory for session '{session_id}'"),
        },
        W::NotGitRepo(p) => RpcError::Custom {
            code: codes::NOT_GIT_REPO.into(),
            message: format!("Not a git repository: {p}"),
            details: None,
        },
        W::ProtectedBranch(m) => RpcError::Custom {
            code: codes::PROTECTED_BRANCH.into(),
            message: m,
            details: None,
        },
        W::NoRemoteConfigured(m) => RpcError::Custom {
            code: codes::NO_REMOTE.into(),
            message: m,
            details: None,
        },
        W::NonFastForward(m) => RpcError::Custom {
            code: codes::NON_FAST_FORWARD.into(),
            message: m,
            details: None,
        },
        W::AuthFailure(m) => RpcError::Custom {
            code: codes::GIT_AUTH_FAILED.into(),
            message: m,
            details: None,
        },
        W::NetworkTimeout(m) => RpcError::Custom {
            code: codes::GIT_NETWORK_ERROR.into(),
            message: m,
            details: None,
        },
        W::DirtyWorkingTree(m) => RpcError::Custom {
            code: codes::DIRTY_WORKING_TREE.into(),
            message: m,
            details: None,
        },
        W::PendingMergeExists => RpcError::InvalidParams {
            message: "session already has a pending merge; resolve or abort it first".into(),
        },
        W::NoPendingMerge => RpcError::InvalidParams {
            message: "session has no pending merge".into(),
        },
        W::MissingBaseBranch => RpcError::Custom {
            code: codes::MISSING_BASE_BRANCH.into(),
            message: "session has no base branch; pass `mainBranch` explicitly".into(),
            details: None,
        },
        W::RefNotFound(r) => RpcError::Custom {
            code: codes::REF_NOT_FOUND.into(),
            message: format!("ref not found: {r}"),
            details: None,
        },
        W::BranchExists(b) => RpcError::Custom {
            code: codes::BRANCH_EXISTS.into(),
            message: format!("branch already exists: {b}"),
            details: None,
        },
        W::BranchActive(b) => RpcError::Custom {
            code: codes::BRANCH_ACTIVE.into(),
            message: format!("branch is active: {b}"),
            details: None,
        },
        W::InvalidSessionState(m) => RpcError::InvalidParams { message: m },
        W::Git(m) => RpcError::Custom {
            code: codes::GIT_ERROR.into(),
            message: m,
            details: None,
        },
        // MergeConflicts is special-cased by individual handlers
        // (they return Ok({"conflicts": true, …}) rather than erroring)
        // — reaching this boundary indicates a handler bug.
        W::MergeConflicts(n) => RpcError::Internal {
            message: format!("unexpected MergeConflicts({n}) at error boundary"),
        },
        // Genuinely internal — not user-actionable. The Display
        // impl preserves the underlying detail for logs.
        W::Timeout(_) | W::Io(_) | W::EventStore(_) => RpcError::Internal {
            message: e.to_string(),
        },
    }
}

/// Map an `EventStoreError` to a typed `RpcError`. Most events / session
/// / memory / blob handlers should route their event-store calls through
/// this instead of wrapping into `RpcError::Internal { e.to_string() }`,
/// so iOS clients see actionable codes (`SESSION_NOT_FOUND`,
/// `WORKSPACE_NOT_FOUND`, `BLOB_NOT_FOUND`) instead of `INTERNAL_ERROR`.
///
/// INVARIANT: the `match` is exhaustive over `EventStoreError`. Adding
/// a variant forces a compile error here. Do NOT add a `_` arm.
pub(crate) fn map_event_store_error(e: EventStoreError) -> RpcError {
    use EventStoreError as E;
    match e {
        E::SessionNotFound(id) => RpcError::NotFound {
            code: codes::SESSION_NOT_FOUND.into(),
            message: format!("Session not found: {id}"),
        },
        E::EventNotFound(id) => RpcError::NotFound {
            code: codes::EVENT_NOT_FOUND.into(),
            message: format!("Event not found: {id}"),
        },
        E::WorkspaceNotFound(id) => RpcError::NotFound {
            code: codes::WORKSPACE_NOT_FOUND.into(),
            message: format!("Workspace not found: {id}"),
        },
        E::BlobNotFound(id) => RpcError::NotFound {
            code: codes::BLOB_NOT_FOUND.into(),
            message: format!("Blob not found: {id}"),
        },
        E::InvalidOperation(m) => RpcError::InvalidParams { message: m },
        // Genuinely internal — sqlite/pool/serde/migration/busy/internal.
        // The Display impl preserves the underlying detail for logs.
        E::Sqlite(_)
        | E::Pool(_)
        | E::Serde(_)
        | E::Migration { .. }
        | E::Busy { .. }
        | E::Internal(_) => RpcError::Internal {
            message: e.to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    //! Per-variant coverage for `map_worktree_error` and
    //! `map_event_store_error`. Each test pins one variant to its
    //! expected `RpcError` code — adding a new variant MUST come with a
    //! new test here, in addition to the compile-error the exhaustive
    //! match raises.

    use super::{map_event_store_error, map_worktree_error};
    use crate::events::errors::EventStoreError as E;
    use crate::worktree::WorktreeError as W;

    #[test]
    fn not_found_carries_inner_session_id() {
        let rpc = map_worktree_error(W::NotFound { session_id: "sid-42".into() });
        assert_eq!(rpc.code(), "WORKTREE_NOT_FOUND");
        let msg = rpc.to_string();
        assert!(msg.contains("sid-42"), "message should carry session id; got {msg}");
    }

    #[test]
    fn not_git_repo_is_typed() {
        let rpc = map_worktree_error(W::NotGitRepo("/tmp/x".into()));
        assert_eq!(rpc.code(), "NOT_GIT_REPO");
        assert!(rpc.to_string().contains("/tmp/x"));
    }

    #[test]
    fn protected_branch_preserves_message() {
        let rpc = map_worktree_error(W::ProtectedBranch("refusing to push 'main'".into()));
        assert_eq!(rpc.code(), "PROTECTED_BRANCH");
        assert!(rpc.to_string().contains("'main'"));
    }

    #[test]
    fn no_remote_is_typed() {
        let rpc = map_worktree_error(W::NoRemoteConfigured("origin missing".into()));
        assert_eq!(rpc.code(), "NO_REMOTE");
    }

    #[test]
    fn non_fast_forward_is_typed() {
        let rpc = map_worktree_error(W::NonFastForward("rejected".into()));
        assert_eq!(rpc.code(), "NON_FAST_FORWARD");
    }

    #[test]
    fn auth_failure_is_typed() {
        let rpc = map_worktree_error(W::AuthFailure("401".into()));
        assert_eq!(rpc.code(), "GIT_AUTH_FAILED");
    }

    #[test]
    fn network_timeout_is_typed() {
        let rpc = map_worktree_error(W::NetworkTimeout("timeout".into()));
        assert_eq!(rpc.code(), "GIT_NETWORK_ERROR");
    }

    #[test]
    fn dirty_working_tree_is_typed() {
        let rpc = map_worktree_error(W::DirtyWorkingTree("dirty".into()));
        assert_eq!(rpc.code(), "DIRTY_WORKING_TREE");
    }

    #[test]
    fn pending_merge_exists_is_invalid_params() {
        let rpc = map_worktree_error(W::PendingMergeExists);
        assert_eq!(rpc.code(), "INVALID_PARAMS");
        assert!(rpc.to_string().contains("pending merge"));
    }

    #[test]
    fn no_pending_merge_is_invalid_params() {
        let rpc = map_worktree_error(W::NoPendingMerge);
        assert_eq!(rpc.code(), "INVALID_PARAMS");
    }

    #[test]
    fn missing_base_branch_is_typed() {
        let rpc = map_worktree_error(W::MissingBaseBranch);
        assert_eq!(rpc.code(), "MISSING_BASE_BRANCH");
    }

    #[test]
    fn ref_not_found_is_typed() {
        let rpc = map_worktree_error(W::RefNotFound("refs/heads/x".into()));
        assert_eq!(rpc.code(), "REF_NOT_FOUND");
        assert!(rpc.to_string().contains("refs/heads/x"));
    }

    #[test]
    fn branch_exists_is_typed() {
        let rpc = map_worktree_error(W::BranchExists("feature/x".into()));
        assert_eq!(rpc.code(), "BRANCH_EXISTS");
        assert!(rpc.to_string().contains("feature/x"));
    }

    #[test]
    fn branch_active_is_typed() {
        let rpc = map_worktree_error(W::BranchActive("feature/x".into()));
        assert_eq!(rpc.code(), "BRANCH_ACTIVE");
    }

    #[test]
    fn invalid_session_state_is_invalid_params() {
        let rpc = map_worktree_error(W::InvalidSessionState("detached HEAD".into()));
        assert_eq!(rpc.code(), "INVALID_PARAMS");
        assert!(rpc.to_string().contains("detached HEAD"));
    }

    #[test]
    fn git_error_is_typed() {
        let rpc = map_worktree_error(W::Git("fatal: …".into()));
        assert_eq!(rpc.code(), "GIT_ERROR");
    }

    #[test]
    fn merge_conflicts_should_not_reach_boundary_but_is_internal() {
        // Handlers must special-case this; if one doesn't, falling
        // through to internal is the safe fallback.
        let rpc = map_worktree_error(W::MergeConflicts(3));
        assert_eq!(rpc.code(), "INTERNAL_ERROR");
        assert!(rpc.to_string().contains("MergeConflicts(3)"));
    }

    #[test]
    fn timeout_is_internal() {
        let rpc = map_worktree_error(W::Timeout(5000));
        assert_eq!(rpc.code(), "INTERNAL_ERROR");
    }

    #[test]
    fn io_error_is_internal() {
        let rpc = map_worktree_error(W::Io(std::io::Error::new(
            std::io::ErrorKind::Other,
            "disk full",
        )));
        assert_eq!(rpc.code(), "INTERNAL_ERROR");
    }

    #[test]
    fn event_store_error_is_internal() {
        let rpc = map_worktree_error(W::EventStore("sqlite locked".into()));
        assert_eq!(rpc.code(), "INTERNAL_ERROR");
    }

    // ── map_event_store_error per-variant coverage ──

    #[test]
    fn event_store_session_not_found_is_typed() {
        let rpc = map_event_store_error(E::SessionNotFound("sess-42".into()));
        assert_eq!(rpc.code(), "SESSION_NOT_FOUND");
        assert!(rpc.to_string().contains("sess-42"));
    }

    #[test]
    fn event_store_event_not_found_is_typed() {
        let rpc = map_event_store_error(E::EventNotFound("evt-7".into()));
        assert_eq!(rpc.code(), "EVENT_NOT_FOUND");
        assert!(rpc.to_string().contains("evt-7"));
    }

    #[test]
    fn event_store_workspace_not_found_is_typed() {
        let rpc = map_event_store_error(E::WorkspaceNotFound("ws-1".into()));
        assert_eq!(rpc.code(), "WORKSPACE_NOT_FOUND");
        assert!(rpc.to_string().contains("ws-1"));
    }

    #[test]
    fn event_store_blob_not_found_is_typed() {
        let rpc = map_event_store_error(E::BlobNotFound("blob-abc".into()));
        assert_eq!(rpc.code(), "BLOB_NOT_FOUND");
        assert!(rpc.to_string().contains("blob-abc"));
    }

    #[test]
    fn event_store_invalid_operation_is_invalid_params() {
        let rpc = map_event_store_error(E::InvalidOperation("can't fork".into()));
        assert_eq!(rpc.code(), "INVALID_PARAMS");
        assert!(rpc.to_string().contains("can't fork"));
    }

    #[test]
    fn event_store_sqlite_is_internal() {
        let rpc = map_event_store_error(E::Sqlite(rusqlite::Error::QueryReturnedNoRows));
        assert_eq!(rpc.code(), "INTERNAL_ERROR");
    }

    #[test]
    fn event_store_busy_is_internal() {
        let rpc = map_event_store_error(E::Busy { operation: "append", attempts: 5 });
        assert_eq!(rpc.code(), "INTERNAL_ERROR");
    }

    #[test]
    fn event_store_serde_is_internal() {
        let serde_err = serde_json::from_str::<String>("not json").unwrap_err();
        let rpc = map_event_store_error(E::Serde(serde_err));
        assert_eq!(rpc.code(), "INTERNAL_ERROR");
    }

    #[test]
    fn event_store_migration_is_internal() {
        let rpc = map_event_store_error(E::Migration { message: "v005 failed".into() });
        assert_eq!(rpc.code(), "INTERNAL_ERROR");
    }

    #[test]
    fn event_store_internal_is_internal() {
        let rpc = map_event_store_error(E::Internal("poisoned lock".into()));
        assert_eq!(rpc.code(), "INTERNAL_ERROR");
    }
}
