//! Shared command-side services for session capabilities.

use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::shared::events::{BaseEvent, TronEvent};
use metrics::{counter, histogram};

use crate::domains::session::Deps;
use crate::domains::session::context::{ContextArtifactsService, RuleFileLevel};
use crate::shared::server::errors::CapabilityError;

pub(super) fn resolve_session_profile(
    deps: &Deps,
    requested: Option<&str>,
    model: &str,
    source: Option<&str>,
) -> Result<String, CapabilityError> {
    deps.profile_runtime
        .plan_session(crate::domains::agent::runner::SessionPlanRequest {
            requested_profile: requested.map(str::to_string),
            model: model.to_string(),
            source: source.map(str::to_string),
            entrypoint: None,
        })
        .map(|plan| plan.profile_name)
        .map_err(|error| CapabilityError::InvalidParams {
            message: format!("invalid session profile: {error}"),
        })
}

/// Release worktree for a session if one is active.
///
/// Logs and swallows errors — archive/delete must not fail due to worktree issues.
/// Mirrors the invariant in `SessionManager::end_session()`: worktree is released
/// BEFORE the session is marked as ended.
pub(super) async fn release_worktree_if_active(deps: &Deps, session_id: &str) {
    if let Some(ref coord) = deps.worktree_coordinator {
        if let Err(e) = coord.release(session_id).await {
            tracing::warn!(
                session_id,
                error = %e,
                "failed to release worktree during session cleanup"
            );
        }
    }
}

pub(crate) struct CreateSessionRequest {
    pub(crate) working_directory: String,
    pub(crate) model: String,
    pub(crate) title: Option<String>,
    pub(crate) source: Option<String>,
    pub(crate) profile: Option<String>,
    /// Per-session worktree override.
    /// `None` defers to the global isolation mode; `Some(true)` forces
    /// isolation, `Some(false)` forces passthrough.
    pub(crate) use_worktree: Option<bool>,
}

pub(crate) struct SessionCommandService;

mod archive;
mod create;
mod delete;
mod fork;
mod preload;
use preload::spawn_optimistic_context_preload;

#[cfg(test)]
mod tests;
