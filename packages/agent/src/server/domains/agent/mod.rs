//! agent domain worker.
//!
//! This module owns canonical function execution for the agent namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//!
//! ## Prompt Execution Flow
//!
//! 1. `/engine` builds an `EngineTransportRequest` for `agent::prompt`.
//! 2. The engine validates schema, authority, idempotency, approval, leases, and
//!    catalog revision before this domain handler runs.
//! 3. `agent::prompt` derives the run id, records the accepted prompt, enqueues
//!    hidden `agent::prompt_apply`, and returns the acknowledgement envelope.
//! 4. `agent::prompt_apply` acquires the session run guard and starts
//!    `agent::run_turn`.
//! 5. The turn runner resolves tools from the live engine catalog, writes session
//!    truth into the event store, and publishes neutral engine stream events.
//! 6. `/engine` subscriptions deliver those stream records to clients; the
//!    transport never owns agent behavior.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) mod operations;
pub(crate) use deps::Deps;
pub(super) use handlers::handle;

use super::*;

pub(crate) fn worker_module(
    deps: &DomainSetupContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let mut module = super::domain_worker_module(
        "agent",
        contract::STREAM_TOPICS,
        contract::capabilities()?,
        Deps::from_engine(deps),
        super::agent_handler,
    )?;
    module
        .functions
        .extend(hidden_function_registrations(deps)?);
    Ok(module)
}

pub(crate) mod commands;
pub(crate) mod prompt_queue;
pub(crate) mod runtime;

use crate::engine::{
    AuthorityRequirement, CompensationContract, CompensationKind, EffectClass, FunctionDefinition,
    FunctionId, IdempotencyContract, Provenance, RiskLevel,
};

pub(crate) fn hidden_function_registrations(
    deps: &DomainSetupContext,
) -> crate::engine::Result<Vec<DomainFunctionRegistration>> {
    let domain_deps = Deps::from_engine(deps);
    let hidden = [
        (
            "agent::prompt_apply",
            "apply a queued agent prompt command",
            agent_prompt_apply_request_schema(),
            agent_prompt_response_schema(),
        ),
        (
            "agent::run_turn",
            "start one accepted agent turn behind the engine runtime boundary",
            agent_prompt_apply_request_schema(),
            agent_prompt_response_schema(),
        ),
        (
            "agent::prompt_queue_drain",
            "drain the next queued prompt after a run completes",
            agent_prompt_queue_drain_request_schema(),
            agent_prompt_queue_drain_response_schema(),
        ),
    ];
    hidden
        .into_iter()
        .map(|(id, description, request_schema, response_schema)| {
            let mut definition = FunctionDefinition::new(
                FunctionId::new(id)?,
                catalog::worker_id("agent")?,
                description,
                VisibilityScope::Internal,
                EffectClass::ExternalSideEffect,
            )
            .with_risk(RiskLevel::High)
            .with_required_authority(AuthorityRequirement::scope("agent.write"))
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_compensation(CompensationContract::new(
                CompensationKind::ExternalIrreversible,
                "hidden prompt apply functions start or drain live agent runtime work; rollback is manual and event-store history remains authoritative",
            ))
            .with_provenance(Provenance::system())
            .with_request_schema(request_schema)
            .with_response_schema(response_schema);
            definition.metadata = json!({
                "internal": true,
                "canonicalCapability": id,
                "hiddenPromptRuntimeFunction": true,
            });
            Ok(DomainFunctionRegistration {
                definition,
                handler: Arc::new(DomainFunctionHandler {
                    method: id,
                    deps: domain_deps.clone(),
                    handler: super::agent_handler,
                }),
            })
        })
        .collect()
}

fn agent_prompt_apply_request_schema() -> Value {
    json!({
        "type": "object",
        "required": ["runId", "sessionId", "prompt"],
        "additionalProperties": false,
        "properties": {
            "runId": {"type": "string"},
            "sessionId": {"type": "string"},
            "prompt": {"type": "string"},
            "reasoningLevel": {"type": "string"},
            "images": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
            "attachments": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
            "source": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn agent_prompt_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["acknowledged", "runId"],
        "additionalProperties": false,
        "properties": {
            "acknowledged": {"type": "boolean"},
            "runId": {"type": "string"}
        }
    })
}

fn agent_prompt_queue_drain_request_schema() -> Value {
    json!({
        "type": "object",
        "required": ["sessionId", "completedRunId"],
        "additionalProperties": false,
        "properties": {
            "sessionId": {"type": "string"},
            "completedRunId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn agent_prompt_queue_drain_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["drained", "count"],
        "additionalProperties": false,
        "properties": {
            "drained": {"type": "boolean"},
            "count": {"type": "integer"},
            "runId": {"type": ["string", "null"]},
            "reason": {"type": ["string", "null"]}
        }
    })
}
