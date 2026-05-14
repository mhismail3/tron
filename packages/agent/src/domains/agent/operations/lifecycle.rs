//! Capability lifecycle persistence and live-event helpers for agent-owned
//! interactive and async capabilities.

use super::{BaseEvent, EventType, TronEvent};
use crate::domains::agent::Deps;
use crate::domains::capability::registry::open_capability_registry_store;
use crate::domains::capability::types::{CapabilityPauseRecord, CapabilityRunRecord};
use crate::engine::Invocation;
use crate::shared::events::CapabilityEventIdentity;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use serde_json::{Value, json};

pub(super) fn string_param_or_context(
    params: Option<&Value>,
    invocation: &Invocation,
    key: &str,
) -> Result<String, CapabilityError> {
    if let Some(value) = params
        .and_then(|p| p.get(key))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
    {
        return Ok(value.to_owned());
    }
    if key == "sessionId"
        && let Some(session_id) = invocation.causal_context.session_id.as_deref()
    {
        return Ok(session_id.to_owned());
    }
    Err(CapabilityError::InvalidParams {
        message: format!("Missing required param: {key}"),
    })
}

pub(super) async fn persist_pause_record(
    deps: &Deps,
    record: CapabilityPauseRecord,
) -> Result<(), CapabilityError> {
    let storage_path = deps
        .engine_host
        .storage_path_for_setup()
        .map_err(crate::shared::server::error_mapping::engine_error_to_capability_error)?;
    run_blocking_task("agent.lifecycle.pause.record", move || {
        let store = open_capability_registry_store(storage_path)
            .map_err(|message| CapabilityError::Internal { message })?;
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .record_pause(&record)
            .map_err(|message| CapabilityError::Internal { message })
    })
    .await
}

pub(super) async fn resolve_pause_record(
    deps: &Deps,
    pause_id: &str,
    status: &str,
    resolution: Value,
) -> Result<(), CapabilityError> {
    let storage_path = deps
        .engine_host
        .storage_path_for_setup()
        .map_err(crate::shared::server::error_mapping::engine_error_to_capability_error)?;
    let pause_id = pause_id.to_owned();
    let status = status.to_owned();
    run_blocking_task("agent.lifecycle.pause.resolve", move || {
        let store = open_capability_registry_store(storage_path)
            .map_err(|message| CapabilityError::Internal { message })?;
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        match store
            .resolve_pause(&pause_id, &status, resolution)
            .map_err(|message| CapabilityError::Internal { message })?
        {
            Some(record) if record.status == "pending" => Ok(()),
            Some(record) => Err(CapabilityError::Custom {
                code: "PAUSE_ALREADY_RESOLVED".to_owned(),
                message: format!("Pause {pause_id} is already {}", record.status),
                details: Some(json!({"pauseId": pause_id, "status": record.status})),
            }),
            None => Err(CapabilityError::NotFound {
                code: "PAUSE_NOT_FOUND".to_owned(),
                message: format!("Pause {pause_id} was not found"),
            }),
        }
    })
    .await
}

pub(super) async fn persist_run_record(
    deps: &Deps,
    record: CapabilityRunRecord,
) -> Result<(), CapabilityError> {
    let storage_path = deps
        .engine_host
        .storage_path_for_setup()
        .map_err(crate::shared::server::error_mapping::engine_error_to_capability_error)?;
    run_blocking_task("agent.lifecycle.run.record", move || {
        let store = open_capability_registry_store(storage_path)
            .map_err(|message| CapabilityError::Internal { message })?;
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .record_run(&record)
            .map_err(|message| CapabilityError::Internal { message })
    })
    .await
}

pub(super) async fn persist_run_status(
    deps: &Deps,
    run_id: &str,
    status: &str,
    details: Value,
) -> Result<(), CapabilityError> {
    let storage_path = deps
        .engine_host
        .storage_path_for_setup()
        .map_err(crate::shared::server::error_mapping::engine_error_to_capability_error)?;
    let run_id = run_id.to_owned();
    let status = status.to_owned();
    run_blocking_task("agent.lifecycle.run.status", move || {
        let store = open_capability_registry_store(storage_path)
            .map_err(|message| CapabilityError::Internal { message })?;
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        let _ = store
            .update_run_status(&run_id, &status, details)
            .map_err(|message| CapabilityError::Internal { message })?;
        Ok(())
    })
    .await
}

pub(super) async fn persist_lifecycle_event(
    deps: &Deps,
    session_id: &str,
    event_type: EventType,
    payload: Value,
) -> Result<(), CapabilityError> {
    let event_store = deps.event_store.clone();
    let session_id = session_id.to_owned();
    run_blocking_task("agent.lifecycle.event.persist", move || {
        event_store
            .append(&crate::domains::session::event_store::AppendOptions {
                session_id: &session_id,
                event_type,
                payload,
                parent_id: None,
                sequence: None,
            })
            .map(|_| ())
            .map_err(|error| CapabilityError::Internal {
                message: format!("persist capability lifecycle event: {error}"),
            })
    })
    .await
}

pub(super) fn emit_run_status(
    deps: &Deps,
    session_id: &str,
    invocation: &Invocation,
    contract_id: &str,
    payload: Value,
) {
    let run_id = payload
        .get("runId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let status = payload
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("running")
        .to_owned();
    let invocation_id = payload
        .get("invocationId")
        .and_then(Value::as_str)
        .unwrap_or(invocation.id.as_str())
        .to_owned();
    let identity = agent_capability_identity(invocation, contract_id);
    let _ = deps
        .orchestrator
        .broadcast()
        .emit(TronEvent::CapabilityRunStatus {
            base: BaseEvent::now(session_id).with_trace_context(
                Some(invocation.causal_context.trace_id.as_str().to_owned()),
                Some(invocation.id.as_str().to_owned()),
            ),
            run_id,
            invocation_id,
            status,
            stream_topic: Some("agent.runtime".to_owned()),
            child_invocations: Vec::new(),
            details: Some(payload),
            capability_identity: identity,
        });
}

pub(super) fn agent_capability_identity(
    invocation: &Invocation,
    contract_id: &str,
) -> CapabilityEventIdentity {
    CapabilityEventIdentity {
        model_primitive_name: Some("execute".to_owned()),
        contract_id: Some(contract_id.to_owned()),
        implementation_id: Some(format!(
            "first_party.agent.v1.{}",
            contract_id
                .rsplit_once("::")
                .map(|(_, name)| name)
                .unwrap_or(contract_id)
        )),
        function_id: Some(contract_id.to_owned()),
        plugin_id: Some("first_party.agent".to_owned()),
        worker_id: Some("agent".to_owned()),
        trust_tier: Some("first_party_signed".to_owned()),
        risk_level: Some("Medium".to_owned()),
        effect_class: Some("ExternalSideEffect".to_owned()),
        trace_id: Some(invocation.causal_context.trace_id.as_str().to_owned()),
        root_invocation_id: Some(invocation.id.as_str().to_owned()),
        binding_decision_id: invocation
            .causal_context
            .runtime_metadata
            .get("bindingDecisionId")
            .cloned(),
        ..CapabilityEventIdentity::default()
    }
}
