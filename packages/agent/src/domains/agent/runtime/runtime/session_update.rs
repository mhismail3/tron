use super::{Duration, ReconstructedState};
use crate::domains::agent::r#loop::errors::RuntimeError;
use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::domains::session::event_store::EventStore;
use crate::shared::protocol::events::{BaseEvent, TronEvent};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
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
    session_id: String,
) -> Result<Arc<ReconstructedState>, CapabilityError> {
    run_blocking_task("agent.prompt.resume", move || {
        session_manager
            .resume_session_for_prompt(&session_id)
            .map_err(|error| map_prompt_resume_error(error, &session_id))
    })
    .await
}

fn map_prompt_resume_error(error: RuntimeError, session_id: &str) -> CapabilityError {
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
    CapabilityError::from_failure(failure)
}

pub(in crate::domains::agent::runtime) async fn load_session_update_event(
    event_store: Arc<EventStore>,
    session_id: String,
) -> Result<Option<TronEvent>, CapabilityError> {
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
                    return Err(CapabilityError::Internal {
                        message: error.to_string(),
                    });
                }
            }
        }

        Err(CapabilityError::Internal {
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
}
