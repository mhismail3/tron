//! message domain worker.
//!
//! This module owns canonical function execution for the message namespace and keeps
//! domain services, schemas, and tests beside the worker that uses them.

pub(crate) mod spec;

use super::*;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    match method {
        "message::delete" => message_delete_value(&invocation.payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("message method {method} is not engine-owned"),
        }),
    }
}

async fn message_delete_value(
    payload: &Value,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    let event_id = require_string_param(Some(payload), "targetEventId")?;
    let reason = opt_string(Some(payload), "reason");

    let deletion_event = deps
        .event_store
        .delete_message(&session_id, &event_id, reason.as_deref())
        .map_err(|error| {
            let message = error.to_string();
            if message.contains("not found") {
                CapabilityError::NotFound {
                    code: errors::NOT_FOUND.into(),
                    message: format!("Event '{event_id}' not found"),
                }
            } else {
                CapabilityError::Internal { message }
            }
        })?;

    let _ = deps
        .orchestrator
        .broadcast()
        .emit(crate::core::events::TronEvent::MessageDeleted {
            base: crate::core::events::BaseEvent::now(&session_id),
            target_event_id: event_id.clone(),
            target_type: deletion_event.event_type.clone(),
            target_turn: None,
            reason,
        });

    Ok(json!({
        "success": true,
        "deletionEventId": deletion_event.id,
        "targetType": deletion_event.event_type,
    }))
}
