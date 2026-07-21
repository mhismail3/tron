//! Session metadata actuator retained beneath adaptive workers.

use serde_json::{Value, json};

use super::WorkerRuntime;
use crate::shared::protocol::events::{BaseEvent, TronEvent};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::{SESSION_NOT_FOUND, ToolError};

const MAX_SESSION_TITLE_CHARS: usize = 160;

impl WorkerRuntime {
    pub(crate) async fn set_session_title(
        &self,
        session_id: String,
        title: String,
    ) -> Result<Value, String> {
        let title = title.trim().to_owned();
        if title.is_empty() || title.chars().count() > MAX_SESSION_TITLE_CHARS {
            return Err(format!(
                "title must contain 1 to {MAX_SESSION_TITLE_CHARS} characters"
            ));
        }

        let store = self.event_store.clone();
        let update_session_id = session_id.clone();
        let update_title = title.clone();
        let (updated, session) = run_blocking_task("worker_kernel.session_set_title", move || {
            let Some(mut session) =
                store
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
            let updated = store
                .update_session_title(&update_session_id, Some(&update_title))
                .map_err(|error| ToolError::Internal {
                    message: error.to_string(),
                })?;
            session.title = Some(update_title);
            Ok((updated, session))
        })
        .await
        .map_err(|error| error.to_string())?;

        self.session_manager.invalidate_session(&session_id);
        if updated {
            let _ = self
                .orchestrator
                .broadcast()
                .emit(TronEvent::SessionUpdated {
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
                });
        }

        Ok(json!({"sessionId":session_id,"title":title,"updated":updated}))
    }
}
