//! Authenticated message mutation for conversation clients.
//!
//! This module owns the small message namespace end-to-end: contract metadata,
//! registration dependencies, handler binding, and operation execution.

use crate::domains::agent::r#loop::orchestrator::core::Orchestrator;
use crate::domains::registration::bindings::operation_bindings;
use crate::domains::registration::composition::{
    DomainFunctionRegistration, DomainRegistrationContext,
};
use crate::domains::registration::contract::FunctionContract;
use crate::domains::session::event_store::EventStore;
use crate::engine::{
    EffectClass, FunctionDefinition, IdempotencyContract, Result as EngineResult, RiskLevel,
};
use crate::shared::server::errors;
use crate::shared::server::errors::ToolError;
use crate::shared::server::params::opt_string;
use crate::shared::server::params::require_string_param;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    event_store: Arc<EventStore>,
    orchestrator: Arc<Orchestrator>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            event_store: deps.event_store.clone(),
            orchestrator: deps.orchestrator.clone(),
        }
    }
}

pub(crate) fn function_registrations(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<Vec<DomainFunctionRegistration>> {
    bind_functions(function_definitions()?, Deps::from_engine(deps))
}

pub(crate) fn function_definitions() -> EngineResult<Vec<FunctionDefinition>> {
    Ok(vec![
        FunctionContract::new(
            "message::delete",
            "message",
            EffectClass::IrreversibleSideEffect,
            RiskLevel::High)
        .request_schema(json!({"additionalProperties":false,"properties":{"reason":{"type":"string"},"sessionId":{"type":"string"},"targetEventId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","targetEventId"],"type":"object"}))
        .response_schema(json!({"additionalProperties":false,"properties":{"deletionEventId":{"type":"string"},"success":{"type":"boolean"},"targetType":{"type":"string"}},"required":["success","deletionEventId","targetType"],"type":"object"}))
        .idempotency(IdempotencyContract::session())
        .build()?,
    ])
}

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "delete" => |invocation, deps| {
            message_delete_value(&invocation.payload, deps).await
        },
    ];
}

async fn message_delete_value(payload: &Value, deps: &Deps) -> Result<Value, ToolError> {
    let session_id = require_string_param(Some(payload), "sessionId")?;
    let event_id = require_string_param(Some(payload), "targetEventId")?;
    let reason = opt_string(Some(payload), "reason");

    let deletion_event = deps
        .event_store
        .delete_message(&session_id, &event_id, reason.as_deref())
        .map_err(|error| {
            let message = error.to_string();
            if message.contains("not found") {
                ToolError::NotFound {
                    code: errors::NOT_FOUND.into(),
                    message: format!("Event '{event_id}' not found"),
                }
            } else {
                ToolError::Internal { message }
            }
        })?;

    let _ = deps.orchestrator.broadcast().emit(
        crate::shared::protocol::events::TronEvent::MessageDeleted {
            base: crate::shared::protocol::events::BaseEvent::now(&session_id),
            target_event_id: event_id.clone(),
            target_type: deletion_event.event_type.clone(),
            target_turn: None,
            reason,
        },
    );

    Ok(json!({
        "success": true,
        "deletionEventId": deletion_event.id,
        "targetType": deletion_event.event_type,
    }))
}
