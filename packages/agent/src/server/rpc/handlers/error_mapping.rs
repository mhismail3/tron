//! Domain-error → RPC-error mapping.
//!
//! Each helper here turns a typed domain error into the most specific
//! `RpcError` variant available, so iOS clients see actionable codes
//! (`PROTECTED_BRANCH`, `NON_FAST_FORWARD`, …) instead of a blanket
//! `INTERNAL_ERROR`. New error mappers (event-store, cron, sandbox, …)
//! belong in this file alongside `map_worktree_error`.

use crate::cron::errors::CronError;
use crate::events::errors::EventStoreError;
use crate::import::errors::ImportError;
use crate::llm::auth::errors::AuthError;
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
        E::DuplicateImport { existing_session_id } => RpcError::Custom {
            code: codes::IMPORT_ALREADY_IMPORTED.into(),
            message: format!(
                "This source has already been imported into session '{existing_session_id}'."
            ),
            details: Some(serde_json::json!({
                "tronSessionId": existing_session_id,
            })),
        },
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

/// Map a `CronError` to a typed `RpcError`. The cron handler should
/// route its `crate::cron::*` calls through this instead of wrapping
/// into `RpcError::Internal { e.to_string() }`, so iOS clients see
/// actionable codes (`CRON_NOT_FOUND`, `CRON_DUPLICATE_NAME`,
/// `CRON_INVALID_EXPRESSION`, …) instead of `INTERNAL_ERROR`.
///
/// INVARIANT: the `match` is exhaustive over `CronError`. Adding a
/// variant forces a compile error here. Do NOT add a `_` arm.
pub(crate) fn map_cron_error(e: CronError) -> RpcError {
    use CronError as C;
    match e {
        C::NotFound(id) => RpcError::NotFound {
            code: codes::CRON_NOT_FOUND.into(),
            message: format!("Cron job not found: {id}"),
        },
        C::DuplicateName(name) => RpcError::Custom {
            code: codes::CRON_DUPLICATE_NAME.into(),
            message: format!("A cron job named '{name}' already exists"),
            details: None,
        },
        C::InvalidExpression(m) => RpcError::Custom {
            code: codes::CRON_INVALID_EXPRESSION.into(),
            message: format!("Invalid cron expression: {m}"),
            details: None,
        },
        C::InvalidTimezone(m) => RpcError::Custom {
            code: codes::CRON_INVALID_TIMEZONE.into(),
            message: format!("Invalid timezone: {m}"),
            details: None,
        },
        C::Validation(m) => RpcError::InvalidParams { message: m },
        C::TimedOut => RpcError::Custom {
            code: codes::CRON_TIMED_OUT.into(),
            message: "Cron job execution timed out".into(),
            details: None,
        },
        C::Cancelled(m) => RpcError::Custom {
            code: codes::CRON_CANCELLED.into(),
            message: format!("Cron job cancelled: {m}"),
            details: None,
        },
        // Genuinely internal — config / DB / execution / IO errors.
        C::Config(_) | C::Database(_) | C::Execution(_) | C::Io(_) => RpcError::Internal {
            message: e.to_string(),
        },
    }
}

/// Map an `ImportError` to a typed `RpcError`. The import handler
/// routes its `crate::import::*` calls through this so iOS clients can
/// distinguish "file missing" from "already imported" from "empty
/// session" from a real internal error.
///
/// INVARIANT: the `match` is exhaustive over `ImportError`. Adding a
/// variant forces a compile error here. Do NOT add a `_` arm.
pub(crate) fn map_import_error(e: ImportError) -> RpcError {
    use ImportError as I;
    match e {
        I::SessionNotFound { path } => RpcError::NotFound {
            code: codes::IMPORT_SESSION_NOT_FOUND.into(),
            message: format!("Session file not found: {}", path.display()),
        },
        I::AlreadyImported { tron_session_id } => RpcError::Custom {
            code: codes::IMPORT_ALREADY_IMPORTED.into(),
            message: format!(
                "Session already imported as Tron session {tron_session_id}"
            ),
            details: Some(serde_json::json!({
                "existingSessionId": tron_session_id,
            })),
        },
        I::EmptySession => RpcError::Custom {
            code: codes::IMPORT_EMPTY_SESSION.into(),
            message: "Empty session: no importable records after parsing".into(),
            details: None,
        },
        I::NoClaudeDirectory { path } => RpcError::NotFound {
            code: codes::IMPORT_NO_CLAUDE_DIRECTORY.into(),
            message: format!("No Claude Code directory found at {}", path.display()),
        },
        // Database errors flatten to event-store typed errors so the
        // client can still see SESSION_NOT_FOUND etc. for downstream
        // failures during the import write phase.
        I::Database(es) => map_event_store_error(es),
        // I/O is genuinely internal — disk full, perm denied, etc.
        I::Io { .. } => RpcError::Internal {
            message: e.to_string(),
        },
    }
}

/// Map an `AuthError` to a typed `RpcError`. The `auth/*` handlers
/// route their `crate::llm::auth::*` calls through this so iOS clients
/// can disambiguate "user not signed in" from "OAuth failed" from
/// "transient network glitch".
///
/// INVARIANT: the `match` is exhaustive over `AuthError`. Adding a
/// variant forces a compile error here. Do NOT add a `_` arm.
pub(crate) fn map_auth_error(e: AuthError) -> RpcError {
    use AuthError as A;
    match e {
        A::NotConfigured(provider) => RpcError::NotFound {
            code: codes::AUTH_NOT_CONFIGURED.into(),
            message: format!("No auth configured for provider: {provider}"),
        },
        A::TokenExpired(m) => RpcError::Custom {
            code: codes::AUTH_TOKEN_EXPIRED.into(),
            message: format!("Token expired and refresh failed: {m}"),
            details: None,
        },
        A::OAuth { status, message } => RpcError::Custom {
            code: codes::AUTH_OAUTH_ERROR.into(),
            message: format!("OAuth error ({status}): {message}"),
            details: None,
        },
        // Stored auth.json carries an unknown/legacy field — not a
        // configuration gap, but the user has to act (re-authenticate).
        // Mapped to NotFound so the iOS settings page nudges them to the
        // sign-in screen rather than showing an opaque internal error.
        A::MalformedProviderAuth { provider, details } => RpcError::NotFound {
            code: codes::AUTH_NOT_CONFIGURED.into(),
            message: format!(
                "Malformed auth for {provider}: {details}. Re-authenticate via `tron auth {provider}`."
            ),
        },
        // Genuinely internal — IO / JSON / HTTP transport failures.
        // The Display impl preserves the underlying detail for logs.
        A::Http(_) | A::Json(_) | A::Io(_) => RpcError::Internal {
            message: e.to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    //! Per-variant coverage for the typed-error mappers. Each test pins
    //! one variant to its expected `RpcError` code — adding a new
    //! variant MUST come with a new test here, in addition to the
    //! compile-error the exhaustive match raises.

    use super::{
        map_auth_error, map_cron_error, map_event_store_error, map_import_error, map_worktree_error,
    };
    use crate::cron::errors::CronError as C;
    use crate::events::errors::EventStoreError as E;
    use crate::import::errors::ImportError as I;
    use crate::llm::auth::errors::AuthError as A;
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

    // ── map_cron_error per-variant coverage ──

    #[test]
    fn cron_not_found_is_typed() {
        let rpc = map_cron_error(C::NotFound("cron_42".into()));
        assert_eq!(rpc.code(), "CRON_NOT_FOUND");
        assert!(rpc.to_string().contains("cron_42"));
    }

    #[test]
    fn cron_duplicate_name_is_typed() {
        let rpc = map_cron_error(C::DuplicateName("daily-summary".into()));
        assert_eq!(rpc.code(), "CRON_DUPLICATE_NAME");
        assert!(rpc.to_string().contains("daily-summary"));
    }

    #[test]
    fn cron_invalid_expression_is_typed() {
        let rpc = map_cron_error(C::InvalidExpression("bad cron".into()));
        assert_eq!(rpc.code(), "CRON_INVALID_EXPRESSION");
        assert!(rpc.to_string().contains("bad cron"));
    }

    #[test]
    fn cron_invalid_timezone_is_typed() {
        let rpc = map_cron_error(C::InvalidTimezone("Mars/Olympus".into()));
        assert_eq!(rpc.code(), "CRON_INVALID_TIMEZONE");
        assert!(rpc.to_string().contains("Mars/Olympus"));
    }

    #[test]
    fn cron_validation_is_invalid_params() {
        let rpc = map_cron_error(C::Validation("name too short".into()));
        assert_eq!(rpc.code(), "INVALID_PARAMS");
        assert!(rpc.to_string().contains("name too short"));
    }

    #[test]
    fn cron_timed_out_is_typed() {
        let rpc = map_cron_error(C::TimedOut);
        assert_eq!(rpc.code(), "CRON_TIMED_OUT");
    }

    #[test]
    fn cron_cancelled_is_typed() {
        let rpc = map_cron_error(C::Cancelled("shutdown".into()));
        assert_eq!(rpc.code(), "CRON_CANCELLED");
        assert!(rpc.to_string().contains("shutdown"));
    }

    #[test]
    fn cron_config_is_internal() {
        let rpc = map_cron_error(C::Config("corrupt yaml".into()));
        assert_eq!(rpc.code(), "INTERNAL_ERROR");
    }

    #[test]
    fn cron_database_is_internal() {
        let rpc = map_cron_error(C::Database("locked".into()));
        assert_eq!(rpc.code(), "INTERNAL_ERROR");
    }

    #[test]
    fn cron_execution_is_internal() {
        let rpc = map_cron_error(C::Execution("shell exit 1".into()));
        assert_eq!(rpc.code(), "INTERNAL_ERROR");
    }

    #[test]
    fn cron_io_is_internal() {
        let rpc = map_cron_error(C::Io(std::io::Error::new(std::io::ErrorKind::Other, "disk")));
        assert_eq!(rpc.code(), "INTERNAL_ERROR");
    }

    // ── map_auth_error per-variant coverage ──

    #[test]
    fn auth_not_configured_is_typed() {
        let rpc = map_auth_error(A::NotConfigured("anthropic".into()));
        assert_eq!(rpc.code(), "AUTH_NOT_CONFIGURED");
        assert!(rpc.to_string().contains("anthropic"));
    }

    #[test]
    fn auth_token_expired_is_typed() {
        let rpc = map_auth_error(A::TokenExpired("refresh returned 403".into()));
        assert_eq!(rpc.code(), "AUTH_TOKEN_EXPIRED");
        assert!(rpc.to_string().contains("refresh returned 403"));
    }

    #[test]
    fn auth_oauth_error_is_typed() {
        let rpc = map_auth_error(A::OAuth { status: 401, message: "invalid_grant".into() });
        assert_eq!(rpc.code(), "AUTH_OAUTH_ERROR");
        assert!(rpc.to_string().contains("invalid_grant"));
        assert!(rpc.to_string().contains("401"));
    }

    #[test]
    fn auth_io_is_internal() {
        let rpc = map_auth_error(A::Io(std::io::Error::new(std::io::ErrorKind::NotFound, "x")));
        assert_eq!(rpc.code(), "INTERNAL_ERROR");
    }

    #[test]
    fn auth_json_is_internal() {
        let serde_err = serde_json::from_str::<String>("not json").unwrap_err();
        let rpc = map_auth_error(A::Json(serde_err));
        assert_eq!(rpc.code(), "INTERNAL_ERROR");
    }

    /// R3: malformed provider auth (e.g. legacy Google `endpoint` field)
    /// surfaces to the iOS settings page as AUTH_NOT_CONFIGURED so the
    /// user is nudged to the sign-in screen, and the message preserves
    /// the re-auth command.
    #[test]
    fn auth_malformed_provider_auth_is_not_configured() {
        let rpc = map_auth_error(A::MalformedProviderAuth {
            provider: "google".into(),
            details: "unknown field `endpoint`".into(),
        });
        assert_eq!(rpc.code(), "AUTH_NOT_CONFIGURED");
        let msg = rpc.to_string();
        assert!(msg.contains("google"));
        assert!(msg.contains("endpoint"));
        assert!(msg.contains("tron auth google"));
    }

    // ── map_import_error per-variant coverage ──

    #[test]
    fn import_session_not_found_is_typed() {
        let rpc = map_import_error(I::SessionNotFound {
            path: std::path::PathBuf::from("/x/missing.jsonl"),
        });
        assert_eq!(rpc.code(), "IMPORT_SESSION_NOT_FOUND");
        assert!(rpc.to_string().contains("missing.jsonl"));
    }

    #[test]
    fn import_already_imported_is_typed_with_details() {
        let rpc = map_import_error(I::AlreadyImported {
            tron_session_id: "sess_42".into(),
        });
        assert_eq!(rpc.code(), "IMPORT_ALREADY_IMPORTED");
        assert!(rpc.to_string().contains("sess_42"));
        // Details payload carries the session id for clients to follow.
        let body = rpc.to_error_body();
        assert_eq!(
            body.details.unwrap()["existingSessionId"],
            "sess_42"
        );
    }

    #[test]
    fn import_empty_session_is_typed() {
        let rpc = map_import_error(I::EmptySession);
        assert_eq!(rpc.code(), "IMPORT_EMPTY_SESSION");
    }

    #[test]
    fn import_no_claude_directory_is_typed() {
        let rpc = map_import_error(I::NoClaudeDirectory {
            path: std::path::PathBuf::from("/no/such/dir"),
        });
        assert_eq!(rpc.code(), "IMPORT_NO_CLAUDE_DIRECTORY");
        assert!(rpc.to_string().contains("/no/such/dir"));
    }

    #[test]
    fn import_database_delegates_to_event_store() {
        // Database errors should surface their typed event-store code
        // (SESSION_NOT_FOUND in this case), not the bare "Database: …".
        let rpc = map_import_error(I::Database(E::SessionNotFound("sess-x".into())));
        assert_eq!(rpc.code(), "SESSION_NOT_FOUND");
    }

    #[test]
    fn import_io_is_internal() {
        let rpc = map_import_error(I::Io {
            path: std::path::PathBuf::from("/x"),
            source: std::io::Error::new(std::io::ErrorKind::PermissionDenied, "no"),
        });
        assert_eq!(rpc.code(), "INTERNAL_ERROR");
    }
}
