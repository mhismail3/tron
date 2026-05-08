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
pub(crate) mod spec;

use super::*;
#[derive(Clone)]
pub(crate) struct Deps {
    agent_deps: Option<crate::server::shared::context::AgentDeps>,
    capability_context: Arc<ServerCapabilityContext>,
    engine_host: crate::engine::EngineHostHandle,
    event_store: Arc<EventStore>,
    job_manager: Option<Arc<dyn crate::tools::traits::JobManagerOps>>,
    orchestrator: Arc<Orchestrator>,
    output_buffer_registry:
        Option<Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>>,
    process_manager: Option<Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    profile_runtime: Arc<ProfileRuntime>,
    session_manager: Arc<SessionManager>,
    skill_registry: Arc<parking_lot::RwLock<SkillRegistry>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &EngineCapabilityDeps) -> Self {
        Self {
            agent_deps: deps.agent_deps.clone(),
            capability_context: deps.capability_context.clone(),
            engine_host: deps.engine_host.clone(),
            event_store: deps.event_store.clone(),
            job_manager: deps.job_manager.clone(),
            orchestrator: deps.orchestrator.clone(),
            output_buffer_registry: deps.output_buffer_registry.clone(),
            process_manager: deps.process_manager.clone(),
            profile_runtime: deps.profile_runtime.clone(),
            session_manager: deps.session_manager.clone(),
            skill_registry: deps.skill_registry.clone(),
        }
    }
}

pub(crate) mod commands;
pub(crate) mod prompt_queue;
pub(crate) mod runtime;

use crate::core::events::{BaseEvent, TronEvent};
use crate::engine::policy::ENGINE_INTERNAL_INVOKE_SCOPE;
use crate::engine::queue::publish_queue_lifecycle_event;
use crate::engine::{
    AuthorityRequirement, CompensationContract, CompensationKind, EffectClass, EngineQueueDrainer,
    EnqueueInvocation, FunctionDefinition, FunctionId, IdempotencyContract, Provenance, RiskLevel,
};
use crate::events::EventType;
use crate::server::domains::agent::commands::AgentCommandService;
use crate::server::domains::agent::prompt_queue::PromptQueueService;
use crate::server::domains::agent::runtime::runtime::{
    format_subagent_results, get_pending_subagent_results,
};
use crate::server::domains::agent::runtime::service::{
    PromptEngineCausality, PromptRequest, drain_prompt_queue, spawn_prompt_run,
};
use crate::server::shared::errors;
use crate::server::shared::validation;
use serde::Deserialize;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "agent::prompt" => prompt_value(invocation, deps).await,
        "agent::prompt_apply" => prompt_apply_value(Some(payload), invocation, deps).await,
        "agent::run_turn" => run_turn_value(Some(payload), invocation, deps).await,
        "agent::prompt_queue_drain" => {
            prompt_queue_drain_value(Some(payload), invocation, deps).await
        }
        "agent::status" => status_value(Some(payload), deps).await,
        "agent::abort" => abort_value(Some(payload), deps).await,
        "agent::abort_tool" => abort_tool_value(Some(payload), deps).await,
        "agent::queue_prompt" => queue_prompt_value(Some(payload), invocation, deps).await,
        "agent::dequeue_prompt" => dequeue_prompt_value(Some(payload), invocation, deps).await,
        "agent::clear_queue" => clear_queue_value(Some(payload), invocation, deps).await,
        "agent::deliver_subagent_results" => {
            deliver_subagent_results_value(Some(payload), deps).await
        }
        "agent::submit_confirmation" => submit_confirmation_value(Some(payload), deps).await,
        "agent::submit_answers" => submit_answers_value(Some(payload), deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("agent method {method} is not engine-owned"),
        }),
    }
}

pub(crate) fn hidden_function_registrations(
    deps: &EngineCapabilityDeps,
) -> crate::engine::Result<Vec<DomainFunctionRegistration>> {
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
                    deps: deps.clone(),
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

struct PromptSubmission {
    session_id: String,
    prompt: String,
    reasoning_level: Option<String>,
    images: Option<Vec<Value>>,
    attachments: Option<Vec<Value>>,
    source: Option<String>,
}

async fn prompt_value(invocation: &Invocation, deps: &Deps) -> Result<Value, CapabilityError> {
    let (submission, _, _) = validate_prompt_submission(Some(&invocation.payload), deps).await?;
    let run_id = uuid::Uuid::now_v7().to_string();
    let mut apply_payload = invocation.payload.clone();
    let Some(object) = apply_payload.as_object_mut() else {
        return Err(CapabilityError::InvalidParams {
            message: "agent.prompt params must be an object".into(),
        });
    };
    object.insert("runId".to_owned(), json!(run_id));
    publish_prompt_stream(
        invocation,
        deps,
        &submission.session_id,
        "accepted",
        json!({}),
    )
    .await;
    enqueue_and_sync_drain_agent_function(
        invocation,
        deps,
        &submission.session_id,
        "agent::prompt_apply",
        "agent::prompt_apply",
        apply_payload,
    )
    .await
}

async fn prompt_apply_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let run_id = require_string_param(params, "runId")?;
    let (submission, _session, _agent_deps) = validate_prompt_submission(params, deps).await?;

    publish_prompt_stream(
        invocation,
        deps,
        &submission.session_id,
        "apply_started",
        json!({"runId": run_id}),
    )
    .await;
    enqueue_and_sync_drain_agent_function(
        invocation,
        deps,
        &submission.session_id,
        "agent::run_turn",
        "agent::run_turn",
        params.cloned().unwrap_or_else(|| json!({})),
    )
    .await
}

async fn run_turn_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let run_id = require_string_param(params, "runId")?;
    let (submission, session, agent_deps) = validate_prompt_submission(params, deps).await?;

    let started_run = deps
        .orchestrator
        .begin_run(&submission.session_id, &run_id)
        .map_err(|e| CapabilityError::Custom {
            code: e.category().to_uppercase(),
            message: e.to_string(),
            details: None,
        })?;

    record_prompt_history(deps, &submission.prompt, submission.source.as_deref());
    publish_prompt_stream(
        invocation,
        deps,
        &submission.session_id,
        "run_turn_started",
        json!({
            "runId": run_id,
            "model": session.latest_model,
            "provider": "unknown",
            "catalogRevision": invocation.causal_context.catalog_revision.0,
        }),
    )
    .await;
    spawn_prompt_run(
        &deps.capability_context,
        &agent_deps,
        &session,
        started_run,
        run_id.clone(),
        PromptRequest {
            session_id: submission.session_id,
            prompt: submission.prompt,
            reasoning_level: submission.reasoning_level,
            images: submission.images,
            attachments: submission.attachments,
            message_metadata: None,
            engine_causality: Some(PromptEngineCausality::from_invocation(invocation)),
        },
    );

    Ok(json!({
        "acknowledged": true,
        "runId": run_id,
    }))
}

async fn prompt_queue_drain_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let session =
        AgentCommandService::load_prompt_session(&deps.capability_context, &session_id).await?;
    let agent_deps = deps
        .agent_deps
        .as_ref()
        .ok_or_else(|| CapabilityError::NotAvailable {
            message: "Agent execution dependencies are not configured".into(),
        })?;
    let outcome = drain_prompt_queue(
        &deps.event_store,
        &deps.orchestrator,
        &deps.session_manager,
        &session_id,
        &session.latest_model,
        &session.working_directory,
        deps.orchestrator.broadcast().clone(),
        agent_deps.provider_factory.clone(),
        agent_deps.tool_factory.clone(),
        agent_deps.guardrails.clone(),
        deps.capability_context.health_tracker.clone(),
        deps.capability_context.context_artifacts.clone(),
        deps.skill_registry.clone(),
        deps.capability_context.memory_registry.clone(),
        deps.profile_runtime.clone(),
        deps.capability_context.subagent_manager.clone(),
        deps.capability_context
            .shutdown_coordinator
            .as_ref()
            .map(|coord| coord.token()),
        deps.capability_context.worktree_coordinator.clone(),
        deps.process_manager.clone(),
        deps.job_manager.clone(),
        deps.output_buffer_registry.clone(),
        deps.capability_context.hook_abort_tracker.clone(),
        deps.capability_context.origin.clone(),
        deps.engine_host.clone(),
        Some(PromptEngineCausality::from_invocation(invocation)),
    )?;
    publish_prompt_stream(
        invocation,
        deps,
        &session_id,
        "queue_drained",
        serde_json::to_value(&outcome).unwrap_or_else(|_| json!({})),
    )
    .await;
    serde_json::to_value(outcome).map_err(|e| CapabilityError::Internal {
        message: format!("Failed to serialize prompt queue drain outcome: {e}"),
    })
}

async fn validate_prompt_submission(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<
    (
        PromptSubmission,
        crate::events::sqlite::row_types::SessionRow,
        crate::server::shared::context::AgentDeps,
    ),
    CapabilityError,
> {
    let session_id = require_string_param(params, "sessionId")?;
    let prompt = require_string_param(params, "prompt")?;
    validation::validate_string_param(&prompt, "prompt", validation::MAX_PROMPT_LENGTH)?;
    let images = opt_array(params, "images").cloned();
    let attachments = opt_array(params, "attachments").cloned();
    validate_attachment_arrays(images.as_deref(), attachments.as_deref())?;

    if let Some(active_run_id) = deps.orchestrator.get_run_id(&session_id) {
        return Err(CapabilityError::Custom {
            code: errors::SESSION_BUSY.into(),
            message: format!("Session '{session_id}' is already processing run '{active_run_id}'"),
            details: Some(json!({ "runId": active_run_id })),
        });
    }

    let session =
        AgentCommandService::load_prompt_session(&deps.capability_context, &session_id).await?;
    let agent_deps =
        deps.agent_deps
            .as_ref()
            .cloned()
            .ok_or_else(|| CapabilityError::NotAvailable {
                message: "Agent execution dependencies are not configured".into(),
            })?;
    Ok((
        PromptSubmission {
            session_id,
            prompt,
            reasoning_level: opt_string(params, "reasoningLevel"),
            images,
            attachments,
            source: opt_string(params, "source"),
        },
        session,
        agent_deps,
    ))
}

fn validate_attachment_arrays(
    images: Option<&[Value]>,
    attachments: Option<&[Value]>,
) -> Result<(), CapabilityError> {
    if let Some(images) = images {
        for image in images {
            if let Some(data) = image.get("data").and_then(Value::as_str) {
                validation::validate_attachment_size(data)?;
            }
        }
    }
    if let Some(attachments) = attachments {
        for attachment in attachments {
            if let Some(data) = attachment.get("data").and_then(Value::as_str) {
                validation::validate_attachment_size(data)?;
            }
        }
    }
    Ok(())
}

async fn enqueue_and_sync_drain_agent_function(
    invocation: &Invocation,
    deps: &Deps,
    session_id: &str,
    function_id: &str,
    idempotency_prefix: &str,
    payload: Value,
) -> Result<Value, CapabilityError> {
    let function_id = FunctionId::new(function_id).map_err(|e| CapabilityError::Internal {
        message: e.to_string(),
    })?;
    let mut authority_scopes = invocation.causal_context.authority_scopes.clone();
    if !authority_scopes
        .iter()
        .any(|scope| scope == ENGINE_INTERNAL_INVOKE_SCOPE)
    {
        authority_scopes.push(ENGINE_INTERNAL_INVOKE_SCOPE.to_owned());
    }
    let item = deps
        .engine_host
        .enqueue_invocation(EnqueueInvocation {
            queue: "agent".to_owned(),
            function_id,
            target_revision: None,
            payload,
            actor_id: invocation.causal_context.actor_id.clone(),
            actor_kind: invocation.causal_context.actor_kind.clone(),
            authority_grant_id: invocation.causal_context.authority_grant_id.clone(),
            authority_scopes,
            trace_id: invocation.causal_context.trace_id.clone(),
            parent_invocation_id: Some(invocation.id.clone()),
            trigger_id: invocation.causal_context.trigger_id.clone(),
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            idempotency_key: Some(format!("{idempotency_prefix}:{}", invocation.id)),
        })
        .await
        .map_err(crate::server::shared::error_mapping::engine_error_to_capability_error)?;
    publish_queue_lifecycle_event(&deps.engine_host, "enqueue", &item, None).await;
    publish_prompt_stream(
        invocation,
        deps,
        invocation
            .causal_context
            .session_id
            .as_deref()
            .unwrap_or_default(),
        "apply_enqueued",
        json!({"receiptId": item.receipt_id, "queue": item.queue, "function": idempotency_prefix}),
    )
    .await;

    let drained = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        EngineQueueDrainer::drain_receipt(&deps.engine_host, &item.receipt_id, "engine-agent-sync"),
    )
    .await
    .map_err(|_| CapabilityError::Internal {
        message: format!(
            "Timed out waiting for queued prompt command receipt {}",
            item.receipt_id
        ),
    })?
    .map_err(crate::server::shared::error_mapping::engine_error_to_capability_error)?;
    let Some(result) = drained else {
        return Err(CapabilityError::Internal {
            message: format!(
                "Queued prompt command receipt {} was not claimable",
                item.receipt_id
            ),
        });
    };
    if let Some(error) = &result.error {
        publish_prompt_stream(
            invocation,
            deps,
            session_id,
            "apply_failed",
            json!({
                "receiptId": item.receipt_id,
                "error": error.to_string(),
            }),
        )
        .await;
    }
    crate::server::shared::error_mapping::result_to_capability_value(result)
}

fn record_prompt_history(deps: &Deps, prompt: &str, source: Option<&str>) {
    let is_cron = source
        .map(|source| source.starts_with("cron"))
        .unwrap_or(false);
    let prompt_library_settings = crate::settings::get_settings().prompt_library.clone();
    if is_cron || !prompt_library_settings.history_enabled {
        return;
    }
    let pool = deps.event_store.pool().clone();
    let text_for_history = prompt.to_owned();
    let auto_prune = prompt_library_settings.history_auto_prune;
    let max_entries = auto_prune
        .then_some(prompt_library_settings.history_max_entries)
        .filter(|n| *n > 0);
    let max_age_days = auto_prune
        .then_some(prompt_library_settings.history_max_age_days)
        .filter(|n| *n > 0);
    deps.capability_context
        .spawn_blocking_detached("agent.prompt.history", move || {
            match crate::prompt_library::store::record_prompt_and_prune(
                &pool,
                &text_for_history,
                max_entries,
                max_age_days,
            ) {
                Ok(outcome) => {
                    let char_count = text_for_history.chars().count();
                    tracing::debug!(char_count, ?outcome, "recorded prompt history");
                }
                Err(e) => {
                    tracing::warn!(error = %e, "failed to record prompt history");
                }
            }
            Ok(())
        });
}

async fn publish_prompt_stream(
    invocation: &Invocation,
    deps: &Deps,
    session_id: &str,
    action: &str,
    payload: Value,
) {
    let _ = deps
        .engine_host
        .publish_stream_event(crate::engine::PublishStreamEvent {
            topic: "agent.queue".to_owned(),
            payload: json!({
                "type": format!("agent.prompt.{action}"),
                "action": action,
                "sessionId": session_id,
                "payload": payload,
            }),
            visibility: crate::engine::VisibilityScope::Session,
            session_id: Some(session_id.to_owned()),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: "agent::prompt".to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await;
}

async fn status_value(params: Option<&Value>, deps: &Deps) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let event_store = deps.event_store.clone();
    let sid_for_check = session_id.clone();
    let session_exists = run_blocking_task("agent.status.session_check", move || {
        event_store
            .get_session(&sid_for_check)
            .map(|opt| opt.is_some())
            .map_err(crate::server::shared::error_mapping::map_event_store_error)
    })
    .await?;
    if !session_exists {
        return Err(CapabilityError::NotFound {
            code: "SESSION_NOT_FOUND".into(),
            message: format!("Session '{session_id}' not found"),
        });
    }

    let run_id = deps.orchestrator.get_run_id(&session_id);
    let phase = if run_id.is_some() {
        "processing"
    } else {
        "idle"
    };
    let current_tool = deps
        .orchestrator
        .turn_accumulators()
        .current_running_tool(&session_id);
    let event_store = deps.event_store.clone();
    let sid_for_latest = session_id.clone();
    let latest_timestamp = run_blocking_task("agent.status.latest_event", move || {
        let pool = event_store.pool().clone();
        let conn = pool.get().map_err(|e| CapabilityError::Internal {
            message: format!("DB connection failed: {e}"),
        })?;
        crate::events::sqlite::repositories::event::EventRepo::get_latest(&conn, &sid_for_latest)
            .map(|opt| opt.map(|row| row.timestamp))
            .map_err(crate::server::shared::error_mapping::map_event_store_error)
    })
    .await?;
    let time_since_last_event_ms = latest_timestamp
        .as_deref()
        .and_then(|ts| chrono::DateTime::parse_from_rfc3339(ts).ok())
        .and_then(|parsed| {
            let now = chrono::Utc::now();
            let delta = now.signed_duration_since(parsed.with_timezone(&chrono::Utc));
            delta.num_milliseconds().try_into().ok()
        })
        .map(|ms: i64| ms.max(0));
    let current_tool_value = current_tool.map(|snap| {
        json!({
            "name": snap.tool_name,
            "toolCallId": snap.tool_call_id,
            "startedAt": snap.started_at,
        })
    });

    Ok(json!({
        "sessionId": session_id,
        "phase": phase,
        "runId": run_id,
        "currentTool": current_tool_value,
        "lastEventTimestamp": latest_timestamp,
        "timeSinceLastEventMs": time_since_last_event_ms,
    }))
}

async fn abort_value(params: Option<&Value>, deps: &Deps) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    AgentCommandService::abort(&deps.capability_context, &session_id)
}

async fn abort_tool_value(params: Option<&Value>, deps: &Deps) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let tool_call_id = require_string_param(params, "toolCallId")?;
    AgentCommandService::abort_tool(&deps.capability_context, &session_id, &tool_call_id)
}

async fn queue_prompt_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let prompt = require_string_param(params, "prompt")?;
    validation::validate_string_param(&prompt, "prompt", validation::MAX_PROMPT_LENGTH)?;

    let event_store = deps.event_store.clone();
    let sid = session_id.clone();
    let prompt_for_queue = prompt.clone();
    let item = run_blocking_task("agent::queue_prompt", move || {
        PromptQueueService::enqueue(&event_store, &sid, &prompt_for_queue)
    })
    .await?;

    let _ = deps
        .orchestrator
        .broadcast()
        .emit(TronEvent::MessageQueued {
            base: BaseEvent::now(&session_id),
            queue_id: item.queue_id.clone(),
            text: item.text.clone(),
            position: item.position,
        });
    publish_agent_queue_stream(invocation, deps, &session_id, "queued", json!(&item)).await;

    serde_json::to_value(&item).map_err(|e| CapabilityError::Internal {
        message: format!("Failed to serialize queue item: {e}"),
    })
}

async fn dequeue_prompt_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let queue_id = require_string_param(params, "queueId")?;

    let event_store = deps.event_store.clone();
    let sid = session_id.clone();
    let qid = queue_id.clone();
    run_blocking_task("agent::dequeue_prompt", move || {
        PromptQueueService::dequeue(&event_store, &sid, &qid, "cancelled")
    })
    .await?;

    let _ = deps
        .orchestrator
        .broadcast()
        .emit(TronEvent::MessageDequeued {
            base: BaseEvent::now(&session_id),
            queue_id: queue_id.clone(),
            reason: "cancelled".into(),
        });
    publish_agent_queue_stream(
        invocation,
        deps,
        &session_id,
        "dequeued",
        json!({"queueId": queue_id, "reason": "cancelled"}),
    )
    .await;

    Ok(json!({ "ok": true }))
}

async fn clear_queue_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let event_store = deps.event_store.clone();
    let sid = session_id.clone();

    let pending = run_blocking_task("agent.clearQueue.query", {
        let es = event_store.clone();
        let s = sid.clone();
        move || PromptQueueService::get_pending_queue(&es, &s)
    })
    .await?;

    let cleared = run_blocking_task("agent::clear_queue", move || {
        PromptQueueService::clear_queue(&event_store, &sid)
    })
    .await?;

    for item in &pending {
        let _ = deps
            .orchestrator
            .broadcast()
            .emit(TronEvent::MessageDequeued {
                base: BaseEvent::now(&session_id),
                queue_id: item.queue_id.clone(),
                reason: "cleared".into(),
            });
    }
    publish_agent_queue_stream(
        invocation,
        deps,
        &session_id,
        "cleared",
        json!({"cleared": cleared, "items": pending}),
    )
    .await;

    Ok(json!({ "cleared": cleared }))
}

async fn submit_confirmation_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let action = require_string_param(params, "action")?;
    let decision = require_string_param(params, "decision")?;
    let note = params
        .and_then(|p| p.get("note"))
        .and_then(Value::as_str)
        .map(String::from);
    let mut lines = vec![
        "[Confirmation response]".to_string(),
        String::new(),
        format!("Action: {action}"),
        format!("Decision: {decision}"),
    ];
    if let Some(ref note) = note
        && !note.is_empty()
    {
        lines.push(format!("Note: {note}"));
    }
    let prompt = lines.join("\n");
    let mut metadata_obj = serde_json::Map::new();
    let _ = metadata_obj.insert("messageKind".into(), json!("confirmation_response"));
    let _ = metadata_obj.insert("confirmationDecision".into(), json!(decision));
    if let Some(ref n) = note
        && !n.is_empty()
    {
        let _ = metadata_obj.insert("confirmationNote".into(), json!(n));
    }
    start_or_queue_prompt(
        deps,
        session_id,
        prompt,
        Some(Value::Object(metadata_obj)),
        "agent.submitConfirmation.queue",
        true,
    )
    .await
}

#[derive(Deserialize)]
struct AnswerSubmission {
    question: String,
    #[serde(default)]
    #[serde(rename = "selectedValues")]
    selected_values: Vec<String>,
    #[serde(rename = "otherValue")]
    other_value: Option<String>,
}

async fn submit_answers_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let questions_value =
        params
            .and_then(|p| p.get("questions"))
            .ok_or_else(|| CapabilityError::InvalidParams {
                message: "Missing required param: questions".into(),
            })?;
    let answers: Vec<AnswerSubmission> =
        serde_json::from_value(questions_value.clone()).map_err(|e| {
            CapabilityError::InvalidParams {
                message: format!("Invalid questions format: {e}"),
            }
        })?;
    if answers.is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "questions array must not be empty".into(),
        });
    }
    let mut lines = vec!["[Answers to your questions]".to_string(), String::new()];
    for answer in &answers {
        lines.push(format!("**{}**", answer.question));
        if let Some(ref other) = answer.other_value {
            if !other.is_empty() {
                lines.push(format!("Answer: [Other] {other}"));
            } else if !answer.selected_values.is_empty() {
                lines.push(format!("Answer: {}", answer.selected_values.join(", ")));
            } else {
                lines.push("Answer: (no selection)".to_string());
            }
        } else if !answer.selected_values.is_empty() {
            lines.push(format!("Answer: {}", answer.selected_values.join(", ")));
        } else {
            lines.push("Answer: (no selection)".to_string());
        }
        lines.push(String::new());
    }
    start_or_queue_prompt(
        deps,
        session_id,
        lines.join("\n"),
        Some(json!({
            "messageKind": "answered_questions",
            "answerCount": answers.len(),
        })),
        "agent.submitAnswers.queue",
        true,
    )
    .await
}

async fn deliver_subagent_results_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let session =
        load_prompt_session(deps, &session_id, "agent.deliverSubagentResults.verify").await?;
    let event_store = deps.event_store.clone();
    let sid = session_id.clone();
    let (prompt, count) = run_blocking_task("agent.deliverSubagentResults.format", move || {
        let pending = get_pending_subagent_results(&event_store, &sid);
        if pending.is_empty() {
            return Err(CapabilityError::NotFound {
                code: "NO_PENDING_RESULTS".into(),
                message: "No unconsumed subagent results found".into(),
            });
        }
        let count = pending.len();
        let event_ids: Vec<String> = pending.iter().map(|(id, _)| id.clone()).collect();
        let formatted =
            format_subagent_results(&pending).ok_or_else(|| CapabilityError::Internal {
                message: "Failed to format subagent results".into(),
            })?;
        let _ = event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: EventType::SubagentResultsConsumed,
            payload: json!({
                "consumedEventIds": event_ids,
                "count": count,
            }),
            parent_id: None,
            sequence: None,
        });
        Ok((formatted, count))
    })
    .await?;
    let metadata = json!({
        "messageKind": "subagent_results_delivered",
        "subagentCount": count,
    });
    start_or_queue_prompt_with_loaded_session(
        deps,
        session,
        session_id,
        prompt,
        Some(metadata),
        "agent.deliverSubagentResults.queue",
        false,
        Some(json!({"subagentCount": count})),
    )
    .await
}

async fn start_or_queue_prompt(
    deps: &Deps,
    session_id: String,
    prompt: String,
    message_metadata: Option<Value>,
    queue_task: &'static str,
    require_agent_deps: bool,
) -> Result<Value, CapabilityError> {
    let session =
        AgentCommandService::load_prompt_session(&deps.capability_context, &session_id).await?;
    start_or_queue_prompt_with_loaded_session(
        deps,
        session,
        session_id,
        prompt,
        message_metadata,
        queue_task,
        require_agent_deps,
        None,
    )
    .await
}

async fn start_or_queue_prompt_with_loaded_session(
    deps: &Deps,
    session: crate::events::sqlite::row_types::SessionRow,
    session_id: String,
    prompt: String,
    message_metadata: Option<Value>,
    queue_task: &'static str,
    require_agent_deps: bool,
    extra_success_fields: Option<Value>,
) -> Result<Value, CapabilityError> {
    let run_id = uuid::Uuid::now_v7().to_string();
    if let Some(agent_deps) = deps.agent_deps.as_ref() {
        if let Ok(started_run) = deps.orchestrator.begin_run(&session_id, &run_id) {
            spawn_prompt_run(
                &deps.capability_context,
                agent_deps,
                &session,
                started_run,
                run_id.clone(),
                PromptRequest {
                    session_id,
                    prompt,
                    reasoning_level: None,
                    images: None,
                    attachments: None,
                    message_metadata,
                    engine_causality: None,
                },
            );
            let mut result = json!({
                "acknowledged": true,
                "queued": false,
                "runId": run_id,
            });
            merge_success_fields(&mut result, extra_success_fields);
            return Ok(result);
        }
    } else if require_agent_deps {
        return Err(CapabilityError::NotAvailable {
            message: "Agent execution dependencies are not configured".into(),
        });
    }

    let event_store = deps.event_store.clone();
    let sid = session_id.clone();
    let queued_metadata = message_metadata.clone();
    let _ = run_blocking_task(queue_task, move || {
        PromptQueueService::enqueue_with_metadata(&event_store, &sid, &prompt, queued_metadata)
            .map_err(|e| CapabilityError::Internal {
                message: e.to_string(),
            })
    })
    .await?;
    let mut result = json!({
        "acknowledged": true,
        "queued": true,
    });
    merge_success_fields(&mut result, extra_success_fields);
    Ok(result)
}

fn merge_success_fields(target: &mut Value, extra: Option<Value>) {
    let Some(Value::Object(extra)) = extra else {
        return;
    };
    if let Some(target) = target.as_object_mut() {
        for (key, value) in extra {
            let _ = target.insert(key, value);
        }
    }
}

async fn load_prompt_session(
    deps: &Deps,
    session_id: &str,
    task: &'static str,
) -> Result<crate::events::sqlite::row_types::SessionRow, CapabilityError> {
    let session_manager = deps.session_manager.clone();
    let sid_check = session_id.to_owned();
    run_blocking_task(task, move || {
        session_manager
            .get_session(&sid_check)
            .map_err(|e| CapabilityError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| CapabilityError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{sid_check}' not found"),
            })
    })
    .await
}

async fn publish_agent_queue_stream(
    invocation: &Invocation,
    deps: &Deps,
    session_id: &str,
    action: &str,
    payload: Value,
) {
    let _ = deps
        .engine_host
        .publish_stream_event(crate::engine::PublishStreamEvent {
            topic: "agent.queue".to_owned(),
            payload: json!({
                "action": action,
                "sessionId": session_id,
                "payload": payload,
            }),
            visibility: crate::engine::VisibilityScope::Session,
            session_id: Some(session_id.to_owned()),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: "agent::queue".to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await;
}
