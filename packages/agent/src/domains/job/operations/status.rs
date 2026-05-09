//! Job workflow operations.
use super::Invocation;
use crate::domains::job::Deps;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::require_string_param;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

pub(crate) fn job_list_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    if let Some(ref jm) = deps.job_manager {
        Ok(json!({ "jobs": jm.list_jobs(&session_id) }))
    } else if let Some(ref pm) = deps.process_manager {
        Ok(json!({ "jobs": pm.list_processes(&session_id) }))
    } else {
        Ok(json!({ "jobs": [] }))
    }
}

pub(crate) fn persist_user_action(
    event_store: &Arc<crate::domains::session::event_store::EventStore>,
    session_id: &str,
    job_id: &str,
    action: &str,
    label: &str,
) {
    match event_store.append(&crate::domains::session::event_store::AppendOptions {
        session_id,
        event_type: crate::domains::session::event_store::EventType::NotificationUserJobAction,
        payload: json!({
            "jobId": job_id,
            "action": action,
            "label": label,
        }),
        parent_id: None,
        sequence: None,
    }) {
        Ok(event) => tracing::info!(
            job_id,
            action,
            session_id,
            event_id = %event.id,
            "persisted user job action"
        ),
        Err(error) => tracing::error!(
            job_id,
            action,
            session_id,
            error = %error,
            "failed to persist user job action"
        ),
    }
}

pub(crate) async fn publish_job_stream(
    invocation: &Invocation,
    deps: &Deps,
    session_id: &str,
    job_id: &str,
    action: &str,
) {
    crate::domains::job::stream::JobStreamPublisher::new(&deps.engine_host)
        .status(invocation, session_id, job_id, action)
        .await;
}
