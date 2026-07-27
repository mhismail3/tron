//! Canonical session-title mutation and live projection.
//!
//! The Session domain owns both explicit replacement and automatic
//! compare-and-set. Worker Kernel may orchestrate a semantic title proposal,
//! but it cannot mutate session metadata itself.

use std::sync::Arc;

use serde_json::{Value, json};

use super::Deps;
use super::event_store::{EventStore, SessionRow};
use crate::domains::agent::r#loop::orchestrator::core::Orchestrator;
use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::engine::Invocation;
use crate::shared::protocol::events::{BaseEvent, TronEvent};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::{SESSION_NOT_FOUND, ToolError};

pub(crate) const MAX_SESSION_TITLE_CHARS: usize = 160;

/// Execute the conditional model tool against its current causal session.
pub(crate) async fn session_set_title_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let session_id = causal_session_id(invocation.causal_context.session_id.as_deref())?;
    let title = invocation
        .payload
        .get("title")
        .and_then(Value::as_str)
        .ok_or_else(|| ToolError::InvalidParams {
            message: "title is required".to_owned(),
        })?;
    set_title(
        Arc::clone(&deps.event_store),
        &deps.session_manager,
        &deps.orchestrator,
        session_id,
        title.to_owned(),
    )
    .await
}

/// Apply an explicit title replacement.
pub(crate) async fn set_title(
    event_store: Arc<EventStore>,
    session_manager: &SessionManager,
    orchestrator: &Orchestrator,
    session_id: String,
    title: String,
) -> Result<Value, ToolError> {
    let title = validated_title(&title)?;
    let update_session_id = session_id.clone();
    let update_title = title.clone();
    let (updated, session) = run_blocking_task("session.set_title", move || {
        let Some(mut session) = event_store
            .get_session(&update_session_id)
            .map_err(|error| ToolError::Internal {
                message: error.to_string(),
            })?
        else {
            return Err(ToolError::NotFound {
                code: SESSION_NOT_FOUND.to_owned(),
                message: format!("session not found: {update_session_id}"),
            });
        };
        let updated = event_store
            .update_session_title(&update_session_id, Some(&update_title))
            .map_err(|error| ToolError::Internal {
                message: error.to_string(),
            })?;
        session.title = Some(update_title);
        Ok((updated, session))
    })
    .await?;

    if updated {
        publish_title_update(session_manager, orchestrator, &session_id, session);
    }

    Ok(json!({"sessionId":session_id,"title":title,"updated":updated}))
}

/// Apply an automatic proposal only while the session is still untitled.
pub(crate) async fn set_title_if_untitled(
    event_store: Arc<EventStore>,
    session_manager: &SessionManager,
    orchestrator: &Orchestrator,
    session_id: String,
    title: String,
) -> Result<(bool, SessionRow), ToolError> {
    let title = validated_title(&title)?;
    let update_session_id = session_id.clone();
    let update_title = title.clone();
    let (updated, session) = run_blocking_task("session.set_title_if_untitled", move || {
        let updated = event_store
            .set_session_title_if_untitled(&update_session_id, &update_title)
            .map_err(|error| ToolError::Internal {
                message: error.to_string(),
            })?;
        let Some(session) = event_store
            .get_session(&update_session_id)
            .map_err(|error| ToolError::Internal {
                message: error.to_string(),
            })?
        else {
            return Err(ToolError::NotFound {
                code: SESSION_NOT_FOUND.to_owned(),
                message: format!("session not found: {update_session_id}"),
            });
        };
        Ok((updated, session))
    })
    .await?;

    if updated {
        publish_title_update(session_manager, orchestrator, &session_id, session.clone());
    }
    Ok((updated, session))
}

fn validated_title(title: &str) -> Result<String, ToolError> {
    let title = title.trim().to_owned();
    if title.is_empty() || title.chars().count() > MAX_SESSION_TITLE_CHARS {
        return Err(ToolError::InvalidParams {
            message: format!("title must contain 1 to {MAX_SESSION_TITLE_CHARS} characters"),
        });
    }
    Ok(title)
}

fn causal_session_id(causal_session_id: Option<&str>) -> Result<String, ToolError> {
    causal_session_id
        .map(str::trim)
        .filter(|session_id| !session_id.is_empty())
        .map(ToOwned::to_owned)
        .ok_or_else(|| ToolError::InvalidParams {
            message: "session_set_title requires a current causal session".to_owned(),
        })
}

fn publish_title_update(
    session_manager: &SessionManager,
    orchestrator: &Orchestrator,
    session_id: &str,
    session: SessionRow,
) {
    session_manager.invalidate_session(session_id);
    let _ = orchestrator.broadcast().emit(TronEvent::SessionUpdated {
        base: BaseEvent::now(&session.id),
        title: session.title,
        model: Some(session.latest_model),
        event_count: Some(session.event_count),
        turn_count: Some(session.turn_count),
        message_count: Some(session.message_count),
        input_tokens: Some(session.total_input_tokens),
        output_tokens: Some(session.total_output_tokens),
        last_turn_input_tokens: Some(session.last_turn_input_tokens),
        cache_read_tokens: Some(session.total_cache_read_tokens),
        cache_creation_tokens: Some(session.total_cache_creation_tokens),
        cost: Some(session.total_cost),
        last_activity: session.last_activity_at,
        is_active: false,
        last_user_prompt: None,
        last_assistant_response: None,
        parent_session_id: session.parent_session_id,
        activity_lines: None,
        labels: None,
        organization_group: None,
        organization_changed: None,
        is_archived: None,
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn title_validation_trims_and_enforces_the_product_bound() {
        assert_eq!(
            validated_title("  Durable title  ").unwrap(),
            "Durable title"
        );
        assert!(validated_title("   ").is_err());
        assert!(validated_title(&"x".repeat(MAX_SESSION_TITLE_CHARS + 1)).is_err());
    }

    #[test]
    fn explicit_title_requires_the_current_causal_session() {
        assert_eq!(causal_session_id(Some("session-1")).unwrap(), "session-1");
        assert!(causal_session_id(None).is_err());
        assert!(causal_session_id(Some(" ")).is_err());
    }
}
