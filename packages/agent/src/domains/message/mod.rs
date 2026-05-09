//! message domain worker.
//!
//! This module owns canonical function execution for the message namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

use crate::shared::server::errors;
pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::opt_string;
use crate::shared::server::params::require_string_param;
use serde_json::Value;
use serde_json::json;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "message",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

async fn message_delete_value(payload: &Value, deps: &Deps) -> Result<Value, CapabilityError> {
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
        .emit(crate::shared::events::TronEvent::MessageDeleted {
            base: crate::shared::events::BaseEvent::now(&session_id),
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
