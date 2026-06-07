use super::{BaseEvent, CreateSessionRequest, Deps, SessionCommandService, TronEvent};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use serde_json::json;

impl SessionCommandService {
    pub(crate) async fn create(
        deps: &Deps,
        request: CreateSessionRequest,
    ) -> Result<Value, CapabilityError> {
        let session_manager = deps.session_manager.clone();
        let working_directory = request.working_directory.clone();
        let model = request.model.clone();
        let title = request.title.clone();
        let session_id = run_blocking_task("session.create", move || {
            session_manager
                .create_session(&model, &working_directory, title.as_deref())
                .map_err(|error| CapabilityError::Internal {
                    message: error.to_string(),
                })
        })
        .await?;

        let _ = deps
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionCreated {
                base: BaseEvent::now(&session_id),
                model: request.model.clone(),
                working_directory: request.working_directory.clone(),
                title: request.title.clone(),
            });

        deps.orchestrator.init_sequence_counter(&session_id, 0);

        Ok(json!({
            "sessionId": session_id,
            "model": request.model,
            "workingDirectory": request.working_directory,
            "createdAt": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            "isActive": true,
            "isArchived": false,
            "messageCount": 0,
            "eventCount": 1,
            "inputTokens": 0,
            "outputTokens": 0,
            "cost": 0.0,
        }))
    }
}
