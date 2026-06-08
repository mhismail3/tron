//! message domain worker.
//!
//! This module owns the small message namespace end-to-end: contract metadata,
//! registration dependencies, handler binding, and operation execution.

use crate::domains::agent::runner::orchestrator::orchestrator::Orchestrator;
use crate::domains::bindings::operation_bindings;
use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::domains::session::event_store::EventStore;
use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};
use crate::shared::server::errors;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::opt_string;
use crate::shared::server::params::require_string_param;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

const STREAM_TOPICS: &[&str] = &["message.events"];

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

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "message",
            STREAM_TOPICS,
            function_registrations(capabilities()?, domain_deps)?,
        )
    }
}

pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            "message::delete",
            "message",
            EffectClass::IrreversibleSideEffect,
            RiskLevel::High,
            Some("message.write"),
        )
        .request_schema(json!({"additionalProperties":false,"properties":{"reason":{"type":"string"},"sessionId":{"type":"string"},"targetEventId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","targetEventId"],"type":"object"}))
        .response_schema(json!({"additionalProperties":false,"properties":{"deletionEventId":{"type":"string"},"success":{"type":"boolean"},"targetType":{"type":"string"}},"required":["success","deletionEventId","targetType"],"type":"object"}))
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .compensation(CompensationContract::new(
            CompensationKind::ExternalIrreversible,
            "domain-specific tests preserve current rollback, no-op, or replay behavior",
        ))
        .stream_topics(STREAM_TOPICS.to_vec())
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
