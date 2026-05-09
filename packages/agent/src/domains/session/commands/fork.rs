use super::{BaseEvent, Deps, SessionCommandService, TronEvent};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors;
use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use serde_json::json;

impl SessionCommandService {
    pub(crate) async fn fork(
        deps: &Deps,
        session_id: String,
        from_event_id: Option<String>,
        title: Option<String>,
    ) -> Result<Value, CapabilityError> {
        let session_manager = deps.session_manager.clone();
        let session_id_for_fork = session_id.clone();
        let title_for_fork = title.clone();
        let (new_session_id, forked_from_event_id, root_event_id) =
            run_blocking_task("session.fork", move || {
                let result = session_manager
                    .fork_session(
                        &session_id_for_fork,
                        from_event_id.as_deref(),
                        None,
                        title_for_fork.as_deref(),
                    )
                    .map_err(|error| CapabilityError::NotFound {
                        code: errors::SESSION_NOT_FOUND.into(),
                        message: error.to_string(),
                    })?;
                Ok((
                    result.new_session_id,
                    result.forked_from_event_id,
                    result.root_event_id,
                ))
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
