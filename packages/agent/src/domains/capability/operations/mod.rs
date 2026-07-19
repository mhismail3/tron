//! Primitive execute operations for the bare engine loop.
//!
//! `capability::execute` is the only model-facing tool on this branch. It
//! performs one direct host primitive operation, rejects bootstrap grants,
//! requires trusted context and durable least-privilege authority before any
//! trace mutation, then records canonical-operation trace evidence before
//! structural payload validation. It revalidates each durable
//! grant's exact operation claim, canonical risk, static authority scopes,
//! base resource kinds/selectors, and network policy before dispatch.
//! Module-owned program-execution
//! follow-ups must prove the inspected module runtime's delegated job ref
//! matches the requested job resource before status, cancellation, or cleanup
//! can read or mutate job state; procedural module-pack operations similarly
//! require exact procedural resource selectors and remain metadata-only review
//! records rather than activation, prompt injection, or code execution. The
//! short `content` string returned by each operation is model-facing navigation
//! guidance: it must expose the decisive next action and point to structured
//! evidence fields instead of acting as a UI-only prose summary.
//! Context compact/clear caller-key replay deliberately re-enters this domain
//! instead of returning the generic engine-ledger outcome: context control owns
//! durable requested/finalized action repair and per-invocation stop semantics.
//! Cooperative cancellation is selected around operation dispatch only; the
//! execute owner terminalizes its already-started trace before returning the
//! engine's typed cancellation result.

use std::future::Future;
use std::time::Instant;

use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;

use super::Deps;
use crate::engine::{EngineError, Invocation};
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::error_mapping::capability_error_to_engine;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::failure::RUNTIME_CANCELLED;
use tracing::{info, warn};

mod capability_binding;
mod catalog;
mod common;
mod context;
mod context_control;
mod device;
mod dispatch;
mod filesystem;
mod git;
mod goals;
mod import_history;
mod import_preview;
mod jobs;
mod logs;
mod media;
mod memory;
mod module_authoring;
mod module_dependencies;
mod module_install;
mod module_lifecycle;
mod module_manifest;
mod module_program_execution;
mod module_runtime;
mod module_validation;
mod notifications;
mod operation_contract;
mod procedural;
mod process;
mod program_execution;
mod prompt_artifacts;
mod replay;
mod repository_tree;
mod scheduler;
mod state;
mod subagents;
mod tool_sources;
mod trace;
mod update_diagnostics;
mod web;
mod web_research;
mod worker_packages;

#[cfg(test)]
mod module_program_execution_tests;
#[cfg(test)]
mod tests;

use common::{
    compact_json, error_capability_result, internal, invalid, ok_result, optional_str,
    optional_u64, required_str, result_value,
};
use context::{validate_execute_authority, validate_execute_identity};
use trace::{complete_trace_record, started_rejected_trace_record, started_trace_record};

pub(crate) use operation_contract::provider_result_text;
pub(crate) use operation_contract::validate_payload as validate_operation_payload;
pub(crate) use operation_contract::{
    AuthorityPolicy, ConditionalAuthority, OperationBindingMetadata, OperationEffect, OperationId,
    ResourceKindPolicy, SelectorAddition, WorkerPackageKindSource, authority_policy,
    binding_metadata as operation_binding_metadata, effect as operation_effect,
    host_request_schema as operation_host_request_schema, is_supported_operation,
    operation_list_text, operation_presentation,
    required_payload_fields as operation_required_payload_fields, risk as operation_risk,
    supported_operation_names,
};

/// Operations whose durable domain record, not the generic engine ledger,
/// owns caller-key replay and interrupted-finalization repair.
pub(crate) fn operation_replays_through_handler(operation: &str) -> bool {
    matches!(
        OperationId::parse(operation),
        Some(OperationId::ContextControlCompact | OperationId::ContextControlClear)
    )
}

pub(crate) async fn execute_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    execute_value_with_cancellation(invocation, deps, None).await
}

pub(super) async fn execute_value_cancellable(
    invocation: &Invocation,
    deps: &Deps,
    cancellation: &CancellationToken,
) -> Result<Value, EngineError> {
    match execute_value_with_cancellation(invocation, deps, Some(cancellation)).await {
        Ok(value) => Ok(value),
        Err(error) if error.code() == RUNTIME_CANCELLED => Err(EngineError::InvocationCancelled),
        Err(error) => Err(capability_error_to_engine(error)),
    }
}

async fn execute_value_with_cancellation(
    invocation: &Invocation,
    deps: &Deps,
    cancellation: Option<&CancellationToken>,
) -> Result<Value, CapabilityError> {
    let attempted_operation = invocation
        .payload
        .get("operation")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|operation| !operation.is_empty())
        .unwrap_or("<missing-operation>")
        .to_owned();
    if attempted_operation == OperationId::ReplayManifest.as_str() {
        operation_contract::validate_payload(&invocation.payload)?;
        validate_execute_authority(invocation, &attempted_operation, &deps.engine_host).await?;
        info!(
            component = "agent.execute",
            agent_event = "execute_operation_trace_bypassed",
            operation = %attempted_operation,
            trace_id = %invocation.causal_context.trace_id.as_str(),
            invocation_id = %invocation.id.as_str(),
            session_id = invocation.causal_context.session_id.as_deref().unwrap_or("none"),
            "primitive execute operation bypassed trace mutation"
        );
        let result = await_operation(
            dispatch::execute_operation(OperationId::ReplayManifest, invocation, deps, Utc::now()),
            cancellation,
        )
        .await?;
        return result_value(result);
    }

    let Some(operation_id) = OperationId::parse(&attempted_operation) else {
        validate_execute_identity(invocation, &attempted_operation, &deps.engine_host).await?;
        return trace_rejected_operation(invocation, deps, &attempted_operation);
    };

    let operation = attempted_operation;
    validate_execute_authority(invocation, &operation, &deps.engine_host).await?;
    let operation_at = Utc::now();
    execute_traced_operation(
        invocation,
        deps,
        &operation,
        operation_at,
        async {
            operation_contract::validate_payload(&invocation.payload)?;
            dispatch::execute_operation(operation_id, invocation, deps, operation_at).await
        },
        cancellation,
    )
    .await
}

async fn execute_traced_operation<F>(
    invocation: &Invocation,
    deps: &Deps,
    operation: &str,
    operation_at: DateTime<Utc>,
    dispatch: F,
    cancellation: Option<&CancellationToken>,
) -> Result<Value, CapabilityError>
where
    F: Future<Output = Result<CapabilityResult, CapabilityError>>,
{
    let started_at = operation_at.to_rfc3339();
    let start = Instant::now();
    let mut trace_record = started_trace_record(invocation, deps, &operation, &started_at)?;
    deps.event_store
        .append_trace_record(&trace_record)
        .map_err(|error| internal(format!("record trace start: {error}")))?;
    info!(
        component = "agent.execute",
        agent_event = "execute_operation_started",
        operation = %operation,
        trace_id = %invocation.causal_context.trace_id.as_str(),
        invocation_id = %invocation.id.as_str(),
        parent_invocation_id = invocation
            .causal_context
            .parent_invocation_id
            .as_ref()
            .map(|id| id.as_str())
            .unwrap_or("none"),
        session_id = invocation.causal_context.session_id.as_deref().unwrap_or("none"),
        workspace_id = invocation.causal_context.workspace_id.as_deref().unwrap_or("none"),
        actor_kind = ?invocation.causal_context.actor_kind,
        actor_id = %invocation.causal_context.actor_id.as_str(),
        "primitive execute operation started"
    );
    info!(
        component = "agent.execute",
        agent_event = "execute_trace_record_started",
        operation = %operation,
        trace_record_id = %trace_record.id,
        trace_id = %trace_record.trace_id,
        invocation_id = %trace_record.invocation_id,
        provider_invocation_id = trace_record.provider_invocation_id.as_deref().unwrap_or("none"),
        session_id = trace_record.session_id.as_deref().unwrap_or("none"),
        turn = trace_record.turn.unwrap_or_default(),
        "primitive execute trace record started"
    );

    let result = await_operation(dispatch, cancellation).await;
    match result {
        Ok(result) => {
            complete_trace_record(
                &mut trace_record,
                invocation,
                &result,
                None,
                start.elapsed(),
            );
            deps.event_store
                .update_trace_record(&trace_record)
                .map_err(|error| internal(format!("record trace completion: {error}")))?;
            info!(
                component = "agent.execute",
                agent_event = "execute_operation_completed",
                operation = %operation,
                trace_record_id = %trace_record.id,
                trace_id = %trace_record.trace_id,
                invocation_id = %trace_record.invocation_id,
                status = %trace_record.status,
                duration_ms = trace_record.duration_ms.unwrap_or_default(),
                session_id = trace_record.session_id.as_deref().unwrap_or("none"),
                turn = trace_record.turn.unwrap_or_default(),
                "primitive execute operation completed"
            );
            result_value(result)
        }
        Err(error) => {
            let provider_error = redact_provider_visible_error(error);
            let status = if provider_error.code() == RUNTIME_CANCELLED {
                "cancelled"
            } else {
                "failed"
            };
            complete_trace_record(
                &mut trace_record,
                invocation,
                &error_capability_result(provider_error.to_string(), json!({"status": status})),
                Some(&provider_error),
                start.elapsed(),
            );
            deps.event_store
                .update_trace_record(&trace_record)
                .map_err(|store_error| internal(format!("record trace failure: {store_error}")))?;
            warn!(
                component = "agent.execute",
                agent_event = if status == "cancelled" {
                    "execute_operation_cancelled"
                } else {
                    "execute_operation_failed"
                },
                operation = %operation,
                trace_record_id = %trace_record.id,
                trace_id = %trace_record.trace_id,
                invocation_id = %trace_record.invocation_id,
                status = %trace_record.status,
                duration_ms = trace_record.duration_ms.unwrap_or_default(),
                session_id = trace_record.session_id.as_deref().unwrap_or("none"),
                turn = trace_record.turn.unwrap_or_default(),
                error = %provider_error,
                "primitive execute operation failed"
            );
            Err(provider_error)
        }
    }
}

async fn await_operation<F>(
    operation: F,
    cancellation: Option<&CancellationToken>,
) -> Result<CapabilityResult, CapabilityError>
where
    F: Future<Output = Result<CapabilityResult, CapabilityError>>,
{
    match cancellation {
        Some(cancellation) => {
            if cancellation.is_cancelled() {
                return Err(cancelled_capability_error());
            }
            tokio::select! {
                biased;
                result = operation => result,
                () = cancellation.cancelled() => Err(cancelled_capability_error()),
            }
        }
        None => operation.await,
    }
}

fn cancelled_capability_error() -> CapabilityError {
    CapabilityError::Custom {
        code: RUNTIME_CANCELLED.to_owned(),
        message: "Operation cancelled".to_owned(),
        details: Some(json!({"status": "cancelled"})),
    }
}

fn trace_rejected_operation(
    invocation: &Invocation,
    deps: &Deps,
    attempted_operation: &str,
) -> Result<Value, CapabilityError> {
    let started_at = Utc::now().to_rfc3339();
    let start = Instant::now();
    let mut trace_record =
        started_rejected_trace_record(invocation, deps, attempted_operation, &started_at)?;
    deps.event_store
        .append_trace_record(&trace_record)
        .map_err(|error| internal(format!("record rejected trace start: {error}")))?;

    let error = operation_contract::validate_payload(&invocation.payload)
        .expect_err("unknown operation must fail canonical payload validation");
    let provider_error = redact_provider_visible_error(error);
    complete_trace_record(
        &mut trace_record,
        invocation,
        &error_capability_result(provider_error.to_string(), json!({"status": "failed"})),
        Some(&provider_error),
        start.elapsed(),
    );
    deps.event_store
        .update_trace_record(&trace_record)
        .map_err(|error| internal(format!("record rejected trace failure: {error}")))?;
    warn!(
        component = "agent.execute",
        agent_event = "execute_operation_rejected",
        operation = %attempted_operation,
        trace_record_id = %trace_record.id,
        trace_id = %trace_record.trace_id,
        invocation_id = %trace_record.invocation_id,
        error = %provider_error,
        "unsupported primitive execute operation was recorded without its raw request"
    );
    Err(provider_error)
}

fn redact_provider_visible_error(error: CapabilityError) -> CapabilityError {
    match error {
        CapabilityError::InvalidParams { message } => CapabilityError::InvalidParams {
            message: redact_authority_material(&message),
        },
        CapabilityError::NotFound { code, message } => CapabilityError::NotFound {
            code,
            message: redact_authority_material(&message),
        },
        CapabilityError::Internal { message } => CapabilityError::Internal {
            message: redact_authority_material(&message),
        },
        CapabilityError::NotAvailable { message } => CapabilityError::NotAvailable {
            message: redact_authority_material(&message),
        },
        CapabilityError::Custom {
            code,
            message,
            details,
        } => CapabilityError::Custom {
            code,
            message: redact_authority_material(&message),
            details: details.map(redact_authority_material_in_value),
        },
    }
}

fn redact_authority_material_in_value(value: Value) -> Value {
    match value {
        Value::String(value) => Value::String(redact_authority_material(&value)),
        Value::Array(values) => Value::Array(
            values
                .into_iter()
                .map(redact_authority_material_in_value)
                .collect(),
        ),
        Value::Object(values) => Value::Object(
            values
                .into_iter()
                .map(|(key, value)| (key, redact_authority_material_in_value(value)))
                .collect(),
        ),
        other => other,
    }
}

fn redact_authority_material(message: &str) -> String {
    redact_token_after_marker(
        &redact_token_after_marker(message, "authority grant "),
        "authorityGrantId ",
    )
}

fn redact_token_after_marker(message: &str, marker: &str) -> String {
    let mut output = String::with_capacity(message.len());
    let mut remaining = message;
    while let Some(index) = remaining.find(marker) {
        let (before, after_before) = remaining.split_at(index);
        output.push_str(before);
        output.push_str(marker);
        output.push_str("<redacted>");
        let after_marker = &after_before[marker.len()..];
        let consumed = after_marker
            .char_indices()
            .find_map(|(idx, ch)| ch.is_whitespace().then_some(idx))
            .unwrap_or(after_marker.len());
        remaining = &after_marker[consumed..];
    }
    output.push_str(remaining);
    output
}
