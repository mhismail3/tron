use super::{Duration, ReconstructedState};
use crate::domains::agent::r#loop::errors::RuntimeError;
use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::orchestrator::recovery::recover_incomplete_turns_for_session;
use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::domains::agent::r#loop::turn_runner::emit_persisted_tool_invocation_completed;
use crate::domains::session::event_store::EventStore;
use crate::shared::protocol::events::{BaseEvent, TronEvent};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::ToolError;
use crate::shared::server::failure::{
    FailureCategory, FailureEnvelope, FailureOrigin, RUNTIME_PERSISTENCE_ERROR,
};
use std::sync::Arc;

const SESSION_UPDATE_LOAD_ATTEMPTS: usize = 40;
const SESSION_UPDATE_LOAD_RETRY_DELAY: Duration = Duration::from_millis(25);

fn session_update_read_error_is_busy(
    error: &crate::domains::session::event_store::EventStoreError,
) -> bool {
    error.is_busy()
}

pub(in crate::domains::agent::runtime) async fn resume_prompt_session(
    session_manager: Arc<SessionManager>,
    event_store: Arc<EventStore>,
    emitter: Arc<EventEmitter>,
    session_id: String,
) -> Result<Arc<ReconstructedState>, ToolError> {
    run_blocking_task("agent.prompt.resume", move || {
        let repaired = recover_incomplete_turns_for_session(&event_store, &session_id)
            .map_err(|error| map_prompt_recovery_error(error, &session_id))?;
        if !repaired.is_empty() {
            session_manager.invalidate_session(&session_id);
            for (row, payload) in repaired {
                emit_persisted_tool_invocation_completed(&emitter, &row, &payload);
            }
        }
        session_manager
            .resume_session_for_prompt(&session_id)
            .map_err(|error| map_prompt_resume_error(error, &session_id))
    })
    .await
}

fn map_prompt_recovery_error(error: String, session_id: &str) -> ToolError {
    tracing::warn!(
        session_id,
        error,
        "prior tool lifecycle could not be repaired before prompt admission"
    );
    ToolError::from_failure(
        FailureEnvelope::new(
            RUNTIME_PERSISTENCE_ERROR,
            FailureCategory::Persistence,
            "Prior tool lifecycle could not be durably repaired",
            false,
            true,
            FailureOrigin::AgentRuntime,
        )
        .with_session_id(Some(session_id.to_owned())),
    )
}

fn map_prompt_resume_error(error: RuntimeError, session_id: &str) -> ToolError {
    let failure = match error {
        RuntimeError::Persistence(_) => FailureEnvelope::new(
            RUNTIME_PERSISTENCE_ERROR,
            FailureCategory::Persistence,
            "Session history could not be reconstructed",
            false,
            false,
            FailureOrigin::AgentRuntime,
        )
        .with_session_id(Some(session_id.to_owned())),
        other => other.to_failure(),
    };
    ToolError::from_failure(failure)
}

pub(in crate::domains::agent::runtime) async fn load_session_update_event(
    event_store: Arc<EventStore>,
    session_id: String,
) -> Result<Option<TronEvent>, ToolError> {
    run_blocking_task("agent.prompt.session_update", move || {
        let mut last_busy_error = None;

        for attempt in 1..=SESSION_UPDATE_LOAD_ATTEMPTS {
            match load_session_update_event_once(&event_store, &session_id) {
                Ok(event) => return Ok(event),
                Err(error)
                    if session_update_read_error_is_busy(&error)
                        && attempt < SESSION_UPDATE_LOAD_ATTEMPTS =>
                {
                    last_busy_error = Some(error);
                    std::thread::sleep(SESSION_UPDATE_LOAD_RETRY_DELAY);
                }
                Err(error) => {
                    return Err(ToolError::Internal {
                        message: error.to_string(),
                    });
                }
            }
        }

        Err(ToolError::Internal {
            message: last_busy_error
                .map(|error| error.to_string())
                .unwrap_or_else(|| "session update data unavailable".to_string()),
        })
    })
    .await
}

fn load_session_update_event_once(
    event_store: &EventStore,
    session_id: &str,
) -> crate::domains::session::event_store::Result<Option<TronEvent>> {
    let Some(session) = event_store.get_session(session_id)? else {
        return Ok(None);
    };

    let preview = match event_store.get_session_message_previews(&[session_id]) {
        Ok(mut previews) => previews.remove(session_id),
        Err(error) if session_update_read_error_is_busy(&error) => return Err(error),
        Err(_) => None,
    };

    let activity_lines = match event_store.get_session_activity_summaries(session_id) {
        Ok(lines) => lines,
        Err(error) if session_update_read_error_is_busy(&error) => return Err(error),
        Err(_) => Vec::new(),
    };

    let (last_user_prompt, last_assistant_response) = preview.map_or((None, None), |preview| {
        (preview.last_user_prompt, preview.last_assistant_response)
    });

    Ok(Some(TronEvent::SessionUpdated {
        base: BaseEvent::now(session_id),
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
        last_user_prompt,
        last_assistant_response,
        parent_session_id: session.parent_session_id,
        activity_lines: Some(activity_lines),
    }))
}

#[cfg(test)]
mod session_update_event_tests {
    use super::*;
    use crate::domains::session::event_store::{
        AppendOptions, ConnectionConfig, EventType, ensure_schema, new_in_memory,
    };
    use crate::shared::protocol::messages::Message;

    #[test]
    fn session_update_busy_detection_covers_busy_and_locked_reads() {
        let busy = crate::domains::session::event_store::EventStoreError::Busy {
            operation: "session_update",
            attempts: 3,
        };
        let locked = crate::domains::session::event_store::EventStoreError::Sqlite(
            rusqlite::Error::SqliteFailure(
                rusqlite::ffi::Error {
                    code: rusqlite::ffi::ErrorCode::DatabaseLocked,
                    extended_code: rusqlite::ffi::ErrorCode::DatabaseLocked as i32,
                },
                None,
            ),
        );
        let other = crate::domains::session::event_store::EventStoreError::Sqlite(
            rusqlite::Error::QueryReturnedNoRows,
        );

        assert!(session_update_read_error_is_busy(&busy));
        assert!(session_update_read_error_is_busy(&locked));
        assert!(!session_update_read_error_is_busy(&other));
    }

    #[test]
    fn session_update_retry_budget_stays_bounded() {
        assert!(SESSION_UPDATE_LOAD_ATTEMPTS >= 20);
        assert!(SESSION_UPDATE_LOAD_RETRY_DELAY <= Duration::from_millis(50));
        assert!(
            SESSION_UPDATE_LOAD_RETRY_DELAY * SESSION_UPDATE_LOAD_ATTEMPTS as u32
                <= Duration::from_secs(2)
        );
    }

    #[tokio::test]
    async fn prompt_resume_broadcasts_ordered_repairs_and_reconstructs_cached_state() {
        let pool = new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            ensure_schema(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store.create_session("m", "/tmp", Some("t"), None).unwrap();
        for (event_type, payload) in [
            (EventType::StreamTurnStart, serde_json::json!({"turn": 1})),
            (
                EventType::MessageAssistant,
                serde_json::json!({
                    "turn": 1,
                    "content": [
                        {
                            "type": "tool_invocation",
                            "id": "call-a",
                            "name": "test_tool",
                            "arguments": {"operation": "observe"}
                        },
                        {
                            "type": "tool_invocation",
                            "id": "call-b",
                            "name": "test_tool",
                            "arguments": {"operation": "observe"}
                        }
                    ],
                    "model": "m",
                    "stopReason": "tool_invocation"
                }),
            ),
            (
                EventType::ToolInvocationStarted,
                serde_json::json!({
                    "turn": 1,
                    "invocationId": "call-a",
                    "toolName": "test_tool",
                    "arguments": {"operation": "observe"}
                }),
            ),
            (
                EventType::ToolInvocationStarted,
                serde_json::json!({
                    "turn": 1,
                    "invocationId": "call-b",
                    "toolName": "test_tool",
                    "arguments": {"operation": "observe"}
                }),
            ),
            (
                EventType::TurnFailed,
                serde_json::json!({"turn": 1, "error": "terminal batch failed"}),
            ),
        ] {
            store
                .append(&AppendOptions {
                    session_id: &session.session.id,
                    event_type,
                    payload,
                    parent_id: None,
                    sequence: None,
                })
                .unwrap();
        }

        let manager = Arc::new(SessionManager::new(store.clone()));
        let stale = manager.resume_session(&session.session.id).unwrap();
        assert!(manager.is_cached(&session.session.id));
        let emitter = Arc::new(EventEmitter::new());
        let mut events = emitter.subscribe();

        let refreshed = resume_prompt_session(manager, store, emitter, session.session.id.clone())
            .await
            .expect("repair and prompt resume");

        assert!(
            !Arc::ptr_eq(&stale, &refreshed),
            "repair must invalidate the stale reconstructed projection"
        );
        let result_ids = refreshed
            .messages
            .iter()
            .filter_map(|message| match message {
                Message::ToolResult { invocation_id, .. } => Some(invocation_id.as_str()),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(result_ids, vec!["call-a", "call-b"]);
        let live_ids = std::iter::from_fn(|| events.try_recv().ok())
            .filter_map(|event| match event {
                TronEvent::ToolInvocationCompleted { invocation_id, .. } => Some(invocation_id),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(live_ids, vec!["call-a", "call-b"]);
    }
}
