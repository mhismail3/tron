use super::{ActivitySummaryLine, Duration, EventPersister, MessagePreview, ReconstructedState};
use crate::domains::agent::r#loop::orchestrator::session_manager::SessionManager;
use crate::domains::session::event_store::EventStore;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use std::sync::Arc;

pub struct ResumedPromptSession {
    pub state: ReconstructedState,
    pub persister: Arc<EventPersister>,
}

pub struct SessionUpdateData {
    pub session: crate::domains::session::event_store::sqlite::row_types::SessionRow,
    pub preview: Option<MessagePreview>,
    pub activity_lines: Vec<ActivitySummaryLine>,
}

const SESSION_UPDATE_LOAD_ATTEMPTS: usize = 40;
const SESSION_UPDATE_LOAD_RETRY_DELAY: Duration = Duration::from_millis(25);

fn session_update_read_error_is_busy(
    error: &crate::domains::session::event_store::EventStoreError,
) -> bool {
    matches!(
        error,
        crate::domains::session::event_store::EventStoreError::Busy { .. }
    ) || matches!(
        error,
        crate::domains::session::event_store::EventStoreError::Sqlite(sqlite_error)
            if crate::domains::session::event_store::sqlite::contention::is_rusqlite_busy(sqlite_error)
    )
}

pub async fn resume_prompt_session(
    session_manager: Arc<SessionManager>,
    session_id: String,
) -> Result<ResumedPromptSession, CapabilityError> {
    run_blocking_task("agent.prompt.resume", move || {
        let active = session_manager
            .resume_session(&session_id)
            .map_err(|error| CapabilityError::Internal {
                message: error.to_string(),
            })?;
        Ok(ResumedPromptSession {
            state: active.state.clone(),
            persister: active.context.persister.clone(),
        })
    })
    .await
}

pub async fn load_session_update_data(
    _session_manager: Arc<SessionManager>,
    event_store: Arc<EventStore>,
    session_id: String,
) -> Result<Option<SessionUpdateData>, CapabilityError> {
    run_blocking_task("agent.prompt.session_update", move || {
        let mut last_busy_error = None;

        for attempt in 1..=SESSION_UPDATE_LOAD_ATTEMPTS {
            match load_session_update_data_once(&event_store, &session_id) {
                Ok(data) => return Ok(data),
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

fn load_session_update_data_once(
    event_store: &EventStore,
    session_id: &str,
) -> crate::domains::session::event_store::Result<Option<SessionUpdateData>> {
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

    Ok(Some(SessionUpdateData {
        session,
        preview,
        activity_lines,
    }))
}

#[cfg(test)]
mod session_update_data_tests {
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
