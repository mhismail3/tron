use super::{BaseEvent, Deps, SessionCommandService, TronEvent};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use serde_json::json;

impl SessionCommandService {
    pub(crate) async fn delete(deps: &Deps, session_id: String) -> Result<Value, CapabilityError> {
        let session_manager = deps.session_manager.clone();
        let session_id_for_delete = session_id.clone();
        run_blocking_task("session.delete", move || {
            session_manager
                .delete_session(&session_id_for_delete)
                .map_err(|error| CapabilityError::Internal {
                    message: error.to_string(),
                })?;
            Ok(())
        })
        .await?;

        deps.orchestrator.remove_sequence_counter(&session_id);
        deps.orchestrator.remove_compaction_handler(&session_id);

        let _ = deps
            .orchestrator
            .broadcast()
            .emit(TronEvent::SessionDeleted {
                base: BaseEvent::now(&session_id),
            });

        Ok(json!({ "deleted": true }))
    }
}
