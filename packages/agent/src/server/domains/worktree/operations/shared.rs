//! Worktree workflow operations.

use crate::server::domains::worktree::Deps;
use crate::server::shared::errors::CapabilityError;
pub(crate) fn require_coordinator(
    deps: &Deps,
) -> Result<&crate::worktree::WorktreeCoordinator, CapabilityError> {
    deps.worktree_coordinator
        .as_deref()
        .ok_or_else(|| CapabilityError::Internal {
            message: "Worktree isolation is not enabled".into(),
        })
}

pub(crate) fn require_session_working_dir(
    deps: &Deps,
    session_id: &str,
) -> Result<String, CapabilityError> {
    let session = deps
        .session_manager
        .get_session(session_id)
        .map_err(|e| CapabilityError::Internal {
            message: format!("Session lookup failed: {e}"),
        })?
        .ok_or_else(|| CapabilityError::NotFound {
            code: "SESSION_NOT_FOUND".into(),
            message: format!("Session '{session_id}' not found"),
        })?;
    Ok(session.working_directory)
}

/// Resolve the directory to diff for a session.
///
/// Prefers the coordinator's worktree path (if active), otherwise uses the
/// session's original working directory. This is intentionally lenient — getDiff
/// should work for any session, not only those with worktrees.
pub(crate) fn resolve_diff_dir(deps: &Deps, session_id: &str) -> Result<String, CapabilityError> {
    // Check coordinator for active worktree
    if let Some(ref coord) = deps.worktree_coordinator
        && let Some(dir) = coord.effective_working_dir(session_id)
    {
        return Ok(dir);
    }

    require_session_working_dir(deps, session_id)
}

// ── GetStatus ───────────────────────────────────────────────────────

/// Get worktree status for a session.
///
/// Returns enriched status including `isolated`, `hasUncommittedChanges`,
/// and `commitCount` fields that the iOS client expects.
pub struct GetStatusOperation;
