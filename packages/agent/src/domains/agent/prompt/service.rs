//! Shared command-side services for agent tools.
//!
//! Prompt admission reads durable session metadata from the session domain's
//! persistence dependency directly.

use serde_json::{Value, json};

use crate::domains::agent::Deps;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::{self, ToolError};

pub(crate) struct AgentCommandService;

impl AgentCommandService {
    pub(crate) async fn load_prompt_session(
        deps: &Deps,
        session_id: &str,
    ) -> Result<crate::domains::session::event_store::SessionRow, ToolError> {
        let event_store = deps.event_store.clone();
        let session_id = session_id.to_owned();
        run_blocking_task("agent.prompt.load_session", move || {
            event_store
                .get_session(&session_id)
                .map_err(|error| ToolError::Internal {
                    message: format!("Persistence error: {error}"),
                })?
                .ok_or_else(|| ToolError::NotFound {
                    code: errors::SESSION_NOT_FOUND.into(),
                    message: format!("Session '{session_id}' not found"),
                })
        })
        .await
    }

    pub(crate) fn abort(deps: &Deps, session_id: &str) -> Result<Value, ToolError> {
        let aborted = deps
            .orchestrator
            .abort(session_id)
            .map_err(|error| ToolError::Internal {
                message: error.to_string(),
            })?;

        Ok(json!({ "aborted": aborted }))
    }

    /// Abort a single in-flight tool invocation without aborting the surrounding turn.
    ///
    /// Returns `{ "aborted": true }` if the tool invocation was in flight (its child
    /// `CancellationToken` was cancelled) or `{ "aborted": false }` when
    /// there is no matching invocation — the call already finished, the id is
    /// wrong, or the session has no matching per-invocation abort entry. Callers treat both
    /// as "nothing to do" rather than errors.
    pub(crate) fn abort_invocation(
        deps: &Deps,
        session_id: &str,
        invocation_id: &str,
    ) -> Result<Value, ToolError> {
        let aborted = deps
            .orchestrator
            .invocation_abort_registry()
            .abort(session_id, invocation_id);
        Ok(json!({ "aborted": aborted }))
    }
}
