use super::{BaseEvent, Deps, SessionLifecycleService, TronEvent};
use crate::domains::session::event_store::ForkOptions;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors;
use crate::shared::server::errors::ToolError;
use serde_json::Value;
use serde_json::json;

impl SessionLifecycleService {
    pub(crate) async fn fork(
        deps: &Deps,
        session_id: String,
        from_event_id: Option<String>,
        title: Option<String>,
    ) -> Result<Value, ToolError> {
        let event_store = deps.event_store.clone();
        let session_id_for_fork = session_id.clone();
        let (new_session_id, forked_from_event_id, root_event_id) =
            run_blocking_task("session.fork", move || {
                let fork_event_id = if let Some(event_id) = from_event_id {
                    event_id
                } else {
                    let session = event_store
                        .get_session(&session_id_for_fork)
                        .map_err(|error| ToolError::NotFound {
                            code: errors::SESSION_NOT_FOUND.into(),
                            message: format!("Persistence error: {error}"),
                        })?
                        .ok_or_else(|| ToolError::NotFound {
                            code: errors::SESSION_NOT_FOUND.into(),
                            message: format!("Session not found: {session_id_for_fork}"),
                        })?;
                    session.head_event_id.ok_or_else(|| ToolError::NotFound {
                        code: errors::SESSION_NOT_FOUND.into(),
                        message: "Persistence error: Session has no head event".into(),
                    })?
                };
                let result = event_store
                    .fork(
                        &fork_event_id,
                        &ForkOptions {
                            model: None,
                            title: title.as_deref(),
                        },
                    )
                    .map_err(|error| ToolError::NotFound {
                        code: errors::SESSION_NOT_FOUND.into(),
                        message: format!("Persistence error: {error}"),
                    })?;
                Ok((result.session.id, fork_event_id, result.fork_event.id))
            })
            .await?;

        deps.orchestrator.init_sequence_counter(&new_session_id, 0);

        let _ = deps
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionForked {
                base: BaseEvent::now(&session_id),
                new_session_id: new_session_id.clone(),
            });

        Ok(json!({
            "newSessionId": new_session_id,
            "forkedFromSessionId": session_id,
            "forkedFromEventId": forked_from_event_id,
            "rootEventId": root_event_id,
        }))
    }
}
