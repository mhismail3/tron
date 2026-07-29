//! Live tool-surface resolution and audited provider-stream admission.
//!
//! This phase resolves the exact model-tool surface, leases eligible durable
//! Agent Deliveries, builds the provider request from durable conversation
//! state, persists the provider-neutral v4 request audit, and only then opens
//! the model stream. It performs no optional worker execution and owns no
//! stream processing or turn completion.

use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};

use metrics::{counter, histogram};
use serde_json::{Value, json};
use tracing::{error, info, trace, warn};

use crate::domains::agent::context::context_manager::ContextManager;
use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::agent::r#loop::surface::{self, ResolvedPrimitiveSurface};
use crate::domains::agent::r#loop::types::{RunContext, TurnResult};
use crate::domains::model::responder::{ModelResponder, ModelResponse, ModelResponseRequest};
use crate::domains::session::event_store::AgentDeliverySourceKind;
use crate::shared::foundation::retry::RetryConfig;
use crate::shared::protocol::messages::Context;
use crate::shared::protocol::messages::{RequestContextBlock, RequestContextKind};
use crate::shared::protocol::model_audit::{
    AgentDeliveryManifest, AutomaticContextEvaluation, ContextManifest, SystemContextContribution,
};
use crate::shared::server::failure::{
    ENGINE_TOOL_SURFACE_FAILED, FailureCategory, FailureEnvelope, FailureOrigin,
    RUNTIME_PERSISTENCE_ERROR,
};

use super::failure::emit_turn_failure;
use super::persistence::persist_model_provider_request_audit;
use super::turn_context::{FreshWorkerResults, build_turn_context, worker_relevance_query};
use super::{interrupted_turn_result, terminalization_error_result, terminalize_cancellation};

pub(super) struct ProviderPhaseParams<'a> {
    pub turn: u32,
    pub context_manager: &'a mut ContextManager,
    pub responder: &'a Arc<dyn ModelResponder>,
    pub session_id: &'a str,
    pub emitter: &'a Arc<EventEmitter>,
    pub cancel: &'a tokio_util::sync::CancellationToken,
    pub run_context: &'a RunContext,
    pub persister: Option<&'a EventPersister>,
    pub retry_config: Option<&'a RetryConfig>,
    pub server_origin: Option<&'a str>,
    pub sequence_counter: Option<&'a AtomicI64>,
    pub engine_host: &'a crate::engine::EngineHostHandle,
    pub fresh_worker_results: &'a FreshWorkerResults,
}

pub(super) struct PreparedProviderResponse {
    pub primitive_surface: ResolvedPrimitiveSurface,
    pub response: ModelResponse,
    pub leased_delivery_ids: Vec<String>,
    pub leased_delivery_provenance: Vec<Value>,
}

fn worker_identity_from_delivery_content(content: &str) -> (Option<String>, Option<String>) {
    let Ok(value) = serde_json::from_str::<Value>(content) else {
        return (None, None);
    };
    if let Some(worker_id) = value.get("workerId").and_then(Value::as_str) {
        return (
            Some(worker_id.to_owned()),
            value
                .get("workerName")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
        );
    }
    let workers = value
        .get("results")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|result| {
            result
                .get("evidence")
                .and_then(Value::as_str)
                .and_then(|evidence| serde_json::from_str::<Value>(evidence).ok())
                .and_then(|evidence| {
                    let worker_id = evidence.get("workerId").and_then(Value::as_str)?;
                    let worker_name = evidence
                        .get("workerName")
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned);
                    Some((worker_id.to_owned(), worker_name))
                })
        })
        .collect::<Vec<_>>();
    let worker_ids = workers
        .iter()
        .map(|(worker_id, _)| worker_id.clone())
        .collect::<std::collections::BTreeSet<_>>();
    if worker_ids.len() != 1 {
        return (None, None);
    }
    let worker_names = workers
        .into_iter()
        .filter_map(|(_, worker_name)| worker_name)
        .collect::<std::collections::BTreeSet<_>>();
    (
        worker_ids.first().cloned(),
        (worker_names.len() == 1)
            .then(|| worker_names.first().cloned())
            .flatten(),
    )
}

/// Turn-local owner of the provider-neutral context and its inspection
/// evidence. Callers cannot mutate the system prompt without recording the
/// same ordered contribution.
struct ProviderContextAssembly {
    context: Context,
    message_sources: Vec<crate::domains::agent::context::message_store::MessageAuditSource>,
    system_contributions: Vec<SystemContextContribution>,
    automatic_context: Vec<AutomaticContextEvaluation>,
    agent_deliveries: Vec<AgentDeliveryManifest>,
}

fn bounded_selection_mechanism(mechanism: &str) -> &'static str {
    match mechanism {
        "semantic_hook" => "semantic_hook",
        "deterministic_trivial" => "deterministic_trivial",
        "deterministic_within_limit" => "deterministic_within_limit",
        "deterministic_fallback" => "deterministic_fallback",
        "engine_projection" => "engine_projection",
        "continuity_hook" => "continuity_hook",
        "session_promotion" => "session_promotion",
        "default" => "default",
        "child_agent_allowlist" => "child_agent_allowlist",
        "all_fit" => "all_fit",
        "none" => "none",
        _ => "other",
    }
}

fn record_context_metrics(
    manifest: &ContextManifest,
    surface: &crate::domains::worker_kernel::EngineSurfaceSnapshot,
) {
    if let Some(cache) = &manifest.cache_layout {
        for (segment, bytes) in [
            ("stable_instructions", cache.stable_instruction_bytes),
            ("fixed_tools", cache.fixed_tool_schema_bytes),
            ("dynamic_tools", cache.dynamic_tool_schema_bytes),
            ("request_context", cache.request_context_bytes),
        ] {
            #[allow(clippy::cast_precision_loss)]
            histogram!("model_context_segment_bytes", "segment" => segment).record(bytes as f64);
        }
    }
    counter!(
        "worker_surface_selection_total",
        "mechanism" => bounded_selection_mechanism(&surface.ranking_mechanism)
    )
    .increment(1);
    for evaluation in &manifest.automatic_context {
        counter!(
            "automatic_context_selection_total",
            "kind" => evaluation.kind.clone(),
            "mechanism" => bounded_selection_mechanism(&evaluation.mechanism),
            "delivery" => evaluation.delivery_channel.clone().unwrap_or_else(|| "system".to_owned())
        )
        .increment(1);
    }
}

impl ProviderContextAssembly {
    fn new(
        context: Context,
        message_sources: Vec<crate::domains::agent::context::message_store::MessageAuditSource>,
    ) -> Self {
        let mut system_contributions = Vec::new();
        if let Some(base) = context
            .system_prompt
            .as_deref()
            .filter(|base| !base.is_empty())
        {
            system_contributions.push(SystemContextContribution::new(
                "base_instructions",
                "Agent instructions",
                base,
                serde_json::json!({"owner":"agent_runtime"}),
            ));
        }
        Self {
            context,
            message_sources,
            system_contributions,
            automatic_context: Vec::new(),
            agent_deliveries: Vec::new(),
        }
    }

    fn append_system(
        &mut self,
        kind: &str,
        label: &str,
        content: &str,
        provenance: serde_json::Value,
    ) {
        if content.is_empty() {
            return;
        }
        let system_prompt = self.context.system_prompt.get_or_insert_with(String::new);
        if !system_prompt.is_empty() {
            system_prompt.push_str("\n\n");
        }
        system_prompt.push_str(content);
        self.system_contributions
            .push(SystemContextContribution::new(
                kind, label, content, provenance,
            ));
    }

    fn add_agent_delivery(
        &mut self,
        delivery: &crate::domains::session::event_store::AgentDeliveryRecord,
    ) -> Result<(), String> {
        let source_kind = serde_json::to_value(delivery.source_kind)
            .ok()
            .and_then(|value| value.as_str().map(ToOwned::to_owned))
            .ok_or_else(|| "serialize agent delivery source kind".to_owned())?;
        let intent = delivery.intent.and_then(|intent| {
            serde_json::to_value(intent)
                .ok()
                .and_then(|value| value.as_str().map(ToOwned::to_owned))
        });
        let wake_policy = serde_json::to_value(delivery.wake_policy)
            .ok()
            .and_then(|value| value.as_str().map(ToOwned::to_owned))
            .ok_or_else(|| "serialize agent delivery wake policy".to_owned())?;
        let boundary = serde_json::to_value(delivery.boundary)
            .ok()
            .and_then(|value| value.as_str().map(ToOwned::to_owned))
            .ok_or_else(|| "serialize agent delivery boundary".to_owned())?;
        let content = serde_json::to_string(&serde_json::json!({
            "deliveryId":delivery.delivery_id,
            "sourceKind":source_kind,
            "intent":intent,
            "redelivery":delivery.is_redelivery(),
            "content":delivery.content,
        }))
        .map_err(|error| error.to_string())?;
        self.context.request_context.push(RequestContextBlock {
            kind: RequestContextKind::AgentDelivery,
            content,
        });
        self.agent_deliveries.push(AgentDeliveryManifest {
            delivery_id: delivery.delivery_id.clone(),
            source_kind,
            intent,
            wake_policy,
            boundary,
            redelivery: delivery.is_redelivery(),
            provenance: serde_json::json!({
                "sourceSessionId":delivery.source_session_id,
                "sourceInvocationId":delivery.source_invocation_id,
                "traceId":delivery.source_trace_id,
                "rootInvocationId":delivery.source_root_invocation_id,
                "causalDepth":delivery.causal_depth,
                "resultInvocationId":delivery.result_invocation_id,
                "arrivedDuringRunId":delivery.arrived_during_run_id,
            }),
            content: delivery.content.clone(),
        });
        Ok(())
    }

    fn finalize(
        self,
        surface: &crate::domains::worker_kernel::EngineSurfaceSnapshot,
    ) -> Result<(Context, ContextManifest), String> {
        let tool_surface = serde_json::to_value(surface).map_err(|error| error.to_string())?;
        let manifest = ContextManifest::build(
            &self.context,
            self.system_contributions,
            tool_surface,
            self.automatic_context,
            self.agent_deliveries,
            &self.message_sources,
        )?;
        Ok((self.context, manifest))
    }
}

pub(super) async fn open_provider_response(
    params: ProviderPhaseParams<'_>,
) -> Result<PreparedProviderResponse, TurnResult> {
    let run_id = params.run_context.run_id.as_deref().unwrap_or("none");
    let trace_id = params
        .run_context
        .engine_trace_id
        .as_ref()
        .map(|id| id.as_str())
        .unwrap_or("none");
    let relevance_query = worker_relevance_query(params.context_manager.messages_slice());
    let primitive_surface = match surface::resolve_provider_primitive_surface_for_run(
        params.engine_host,
        params.session_id,
        relevance_query.as_deref(),
        params.run_context.origin_worker_id.as_deref(),
        params.run_context.worker_agent_tools.as_deref(),
        params.run_context.run_id.as_deref(),
    )
    .await
    {
        Ok(surface) => surface,
        Err(error) => {
            let error_msg = format!("failed to resolve live engine tool surface: {error}");
            error!(session_id = params.session_id, turn = params.turn, error = %error_msg);
            let failure = FailureEnvelope::new(
                ENGINE_TOOL_SURFACE_FAILED,
                FailureCategory::Engine,
                error_msg.clone(),
                true,
                true,
                FailureOrigin::Engine,
            );
            emit_turn_failure(
                params.emitter,
                params.persister,
                params.session_id,
                params.turn,
                params.run_context,
                params.sequence_counter,
                &failure,
                None,
            );
            return Err(TurnResult {
                success: false,
                error: Some(error_msg),
                stop_reason: Some(crate::domains::agent::r#loop::errors::StopReason::Error),
                ..Default::default()
            });
        }
    };
    info!(
        component = "agent.turn",
        agent_event = "primitive_surface_resolved",
        session_id = params.session_id,
        run_id,
        trace_id,
        turn = params.turn,
        tool_count = primitive_surface.tools.len(),
        catalog_revision = primitive_surface.snapshot.catalog_revision,
        surface_hash = %primitive_surface.snapshot.surface_hash,
        fixed_tool_count = primitive_surface.snapshot.fixed_tool_count,
        projected_worker_count = primitive_surface.snapshot.projected_worker_count,
        available_worker_count = primitive_surface.snapshot.available_worker_count,
        "provider primitive surface resolved"
    );
    let event_store = params
        .persister
        .map(|persister| Arc::clone(persister.event_store()));
    let trigger_delivery_ids = (params.run_context.delivery_wake_turn == Some(params.turn))
        .then_some(params.run_context.delivery_wake_ids.as_deref())
        .flatten();
    let leased_deliveries = if let Some(event_store) = event_store.as_ref() {
        match event_store.lease_agent_deliveries(
            params.session_id,
            run_id,
            params.turn,
            trigger_delivery_ids,
        ) {
            Ok(deliveries) => deliveries,
            Err(error) => {
                let error_msg = format!("failed to lease agent deliveries: {error}");
                let failure = FailureEnvelope::new(
                    RUNTIME_PERSISTENCE_ERROR,
                    FailureCategory::Persistence,
                    error_msg.clone(),
                    false,
                    false,
                    FailureOrigin::AgentRuntime,
                );
                emit_turn_failure(
                    params.emitter,
                    params.persister,
                    params.session_id,
                    params.turn,
                    params.run_context,
                    params.sequence_counter,
                    &failure,
                    None,
                );
                return Err(TurnResult {
                    success: false,
                    error: Some(error_msg),
                    stop_reason: Some(crate::domains::agent::r#loop::errors::StopReason::Error),
                    ..Default::default()
                });
            }
        }
    } else {
        Vec::new()
    };
    let mut lease_rollback = ProviderLeaseRollback::new(event_store, run_id);
    if trigger_delivery_ids.is_some_and(|ids| !ids.is_empty()) && leased_deliveries.is_empty() {
        let error_msg =
            "delivery-only run could not lease any of its durable trigger deliveries".to_owned();
        let failure = FailureEnvelope::new(
            RUNTIME_PERSISTENCE_ERROR,
            FailureCategory::Persistence,
            error_msg.clone(),
            true,
            true,
            FailureOrigin::AgentRuntime,
        );
        emit_turn_failure(
            params.emitter,
            params.persister,
            params.session_id,
            params.turn,
            params.run_context,
            params.sequence_counter,
            &failure,
            None,
        );
        return Err(TurnResult {
            success: false,
            error: Some(error_msg),
            stop_reason: Some(crate::domains::agent::r#loop::errors::StopReason::Error),
            ..Default::default()
        });
    }

    let projection = match build_turn_context(
        params.context_manager,
        params.server_origin,
        primitive_surface.tools.clone(),
        params.engine_host,
        params.session_id,
        params.run_context.engine_trace_id.as_ref(),
        params.run_context.parent_invocation_id.as_ref(),
        params.fresh_worker_results,
    )
    .await
    {
        Ok(projection) => projection,
        Err(error) => {
            let error_msg = format!("failed to project durable worker results: {error}");
            let failure = FailureEnvelope::new(
                RUNTIME_PERSISTENCE_ERROR,
                FailureCategory::Persistence,
                error_msg.clone(),
                false,
                false,
                FailureOrigin::AgentRuntime,
            );
            emit_turn_failure(
                params.emitter,
                params.persister,
                params.session_id,
                params.turn,
                params.run_context,
                params.sequence_counter,
                &failure,
                None,
            );
            return Err(TurnResult {
                success: false,
                error: Some(error_msg),
                stop_reason: Some(crate::domains::agent::r#loop::errors::StopReason::Error),
                ..Default::default()
            });
        }
    };
    let mut projected_context = projection.context;
    projected_context.cache_layout.fixed_tool_prefix_len =
        primitive_surface.snapshot.fixed_tool_count;
    let mut assembly = ProviderContextAssembly::new(
        projected_context,
        params.context_manager.message_audit_sources().to_vec(),
    );
    let surface_context = surface::surface_context_primer(&primitive_surface.snapshot);
    assembly.append_system(
        "engine_surface_primer",
        "Engine tool surface",
        &surface_context,
        serde_json::json!({
            "catalogRevision":primitive_surface.snapshot.catalog_revision,
            "surfaceHash":primitive_surface.snapshot.surface_hash,
        }),
    );
    for delivery in &leased_deliveries {
        if let Err(error) = assembly.add_agent_delivery(delivery) {
            let error_msg = format!("failed to project agent delivery: {error}");
            let failure = FailureEnvelope::new(
                RUNTIME_PERSISTENCE_ERROR,
                FailureCategory::Persistence,
                error_msg.clone(),
                false,
                false,
                FailureOrigin::AgentRuntime,
            );
            emit_turn_failure(
                params.emitter,
                params.persister,
                params.session_id,
                params.turn,
                params.run_context,
                params.sequence_counter,
                &failure,
                None,
            );
            return Err(TurnResult {
                success: false,
                error: Some(error_msg),
                stop_reason: Some(crate::domains::agent::r#loop::errors::StopReason::Error),
                ..Default::default()
            });
        }
    }
    let (context, context_manifest) = match assembly.finalize(&primitive_surface.snapshot) {
        Ok(finalized) => finalized,
        Err(error) => {
            let error_msg = format!("failed to finalize provider context manifest: {error}");
            let failure = FailureEnvelope::new(
                crate::shared::server::failure::MODEL_PROVIDER_REQUEST_AUDIT_PERSIST_FAILED,
                FailureCategory::Persistence,
                error_msg.clone(),
                false,
                false,
                FailureOrigin::AgentRuntime,
            );
            emit_turn_failure(
                params.emitter,
                params.persister,
                params.session_id,
                params.turn,
                params.run_context,
                params.sequence_counter,
                &failure,
                None,
            );
            return Err(TurnResult {
                success: false,
                error: Some(error_msg),
                stop_reason: Some(crate::domains::agent::r#loop::errors::StopReason::Error),
                ..Default::default()
            });
        }
    };
    record_context_metrics(&context_manifest, &primitive_surface.snapshot);

    let model_request = ModelResponseRequest {
        context,
        session_id: params.session_id.to_owned(),
        reasoning_level: params.run_context.reasoning_level.clone(),
        cancel: params.cancel.clone(),
        retry_config: params.retry_config.cloned(),
    };
    let model_request_audit = match params.responder.request_audit(&model_request) {
        Ok(audit) => audit.with_context_manifest(
            params.turn,
            params
                .run_context
                .engine_trace_id
                .as_ref()
                .map(|id| id.as_str().to_owned()),
            params
                .run_context
                .parent_invocation_id
                .as_ref()
                .map(|id| id.as_str().to_owned()),
            params.run_context.origin_worker_id.clone(),
            params.run_context.origin_worker_invocation_id.clone(),
            context_manifest,
        ),
        Err(error) => {
            let error_msg = error.to_string();
            let failure = error.failure().clone();
            let category = failure.category.as_str().to_owned();
            warn!(
                model = %params.responder.model(),
                status = %category,
                error = %error,
                "model provider request audit error"
            );
            emit_turn_failure(
                params.emitter,
                params.persister,
                params.session_id,
                params.turn,
                params.run_context,
                params.sequence_counter,
                &failure,
                None,
            );
            return Err(TurnResult {
                success: false,
                error: Some(error_msg),
                stop_reason: Some(crate::domains::agent::r#loop::errors::StopReason::Error),
                ..Default::default()
            });
        }
    };
    trace!(
        component = "agent.provider",
        agent_event = "model_provider_request_audit_built",
        session_id = params.session_id,
        run_id,
        trace_id,
        turn = params.turn,
        model = %params.responder.model(),
        "model provider request audit built"
    );
    if let Err(error) = persist_model_provider_request_audit(
        params.persister,
        params.session_id,
        &model_request_audit,
        params.sequence_counter,
    ) {
        let error_msg = format!("failed to persist model provider request audit: {error}");
        error!(session_id = params.session_id, turn = params.turn, error = %error_msg);
        let failure = FailureEnvelope::new(
            crate::shared::server::failure::MODEL_PROVIDER_REQUEST_AUDIT_PERSIST_FAILED,
            FailureCategory::Persistence,
            error_msg.clone(),
            false,
            false,
            FailureOrigin::AgentRuntime,
        );
        emit_turn_failure(
            params.emitter,
            params.persister,
            params.session_id,
            params.turn,
            params.run_context,
            params.sequence_counter,
            &failure,
            None,
        );
        return Err(TurnResult {
            success: false,
            error: Some(error_msg),
            stop_reason: Some(crate::domains::agent::r#loop::errors::StopReason::Error),
            ..Default::default()
        });
    }
    info!(
        component = "agent.provider",
        agent_event = "model_provider_request_audit_persisted",
        session_id = params.session_id,
        run_id,
        trace_id,
        turn = params.turn,
        model = %params.responder.model(),
        "model provider request audit persisted"
    );
    info!(
        component = "agent.provider",
        agent_event = "model_response_requested",
        session_id = params.session_id,
        run_id,
        trace_id,
        turn = params.turn,
        model = %params.responder.model(),
        "model response requested"
    );
    if let Some(started_at) = params.run_context.prompt_run_started_at
        && !params
            .run_context
            .prompt_to_provider_metric_recorded
            .swap(true, Ordering::SeqCst)
    {
        histogram!(
            "agent_prompt_to_provider_start_seconds",
            "trigger" => if params.run_context.delivery_wake_ids.is_some() {
                "delivery_wake"
            } else {
                "user_prompt"
            }
        )
        .record(started_at.elapsed().as_secs_f64());
    }
    let response = match params.responder.respond(model_request).await {
        Ok(response) => response,
        Err(error) => {
            if error.is_cancelled() || params.cancel.is_cancelled() {
                return Err(
                    match terminalize_cancellation(
                        params.emitter,
                        params.persister,
                        params.session_id,
                        params.turn,
                        params.run_context,
                        params.sequence_counter,
                        None,
                        None,
                    ) {
                        Ok(()) => interrupted_turn_result(None, None),
                        Err(error) => terminalization_error_result(error, None, None),
                    },
                );
            }
            let error_msg = error.to_string();
            let failure = error.failure().clone();
            let category = failure.category.as_str().to_owned();
            warn!(
                model = %params.responder.model(),
                status = %category,
                error = %error,
                "model response error"
            );
            emit_turn_failure(
                params.emitter,
                params.persister,
                params.session_id,
                params.turn,
                params.run_context,
                params.sequence_counter,
                &failure,
                None,
            );
            return Err(TurnResult {
                success: false,
                error: Some(error_msg),
                stop_reason: Some(crate::domains::agent::r#loop::errors::StopReason::Error),
                ..Default::default()
            });
        }
    };
    // The provider accepted this request, so every worker result included in
    // it has consumed its one-turn lease. Retain only references and bounded
    // page coordinates for token accounting, compaction, and later turns.
    params
        .context_manager
        .set_messages(projection.retained_messages);

    let leased_delivery_provenance = leased_deliveries
        .iter()
        .map(|delivery| {
            let (source_worker_id, source_worker_name) =
                if delivery.source_kind == AgentDeliverySourceKind::WorkerResult {
                    worker_identity_from_delivery_content(&delivery.content)
                } else {
                    (None, None)
                };
            json!({
                "deliveryId":delivery.delivery_id,
                "sourceKind":delivery.source_kind,
                "sourceWorkerId":source_worker_id,
                "sourceWorkerName":source_worker_name,
                "sourceSessionId":delivery.source_session_id,
                "sourceInvocationId":delivery.source_invocation_id,
                "wakePolicy":delivery.wake_policy,
                "boundary":delivery.boundary,
                "triggeredWake":trigger_delivery_ids
                    .is_some_and(|ids| ids.contains(&delivery.delivery_id)),
                "redelivery":delivery.is_redelivery(),
            })
        })
        .collect();
    let leased_delivery_ids = leased_deliveries
        .into_iter()
        .map(|delivery| delivery.delivery_id)
        .collect();
    lease_rollback.disarm();
    Ok(PreparedProviderResponse {
        primitive_surface,
        response,
        leased_delivery_ids,
        leased_delivery_provenance,
    })
}

struct ProviderLeaseRollback {
    event_store: Option<Arc<crate::domains::session::event_store::EventStore>>,
    run_id: String,
}

impl ProviderLeaseRollback {
    fn new(
        event_store: Option<Arc<crate::domains::session::event_store::EventStore>>,
        run_id: &str,
    ) -> Self {
        Self {
            event_store,
            run_id: run_id.to_owned(),
        }
    }

    fn disarm(&mut self) {
        self.event_store = None;
    }
}

impl Drop for ProviderLeaseRollback {
    fn drop(&mut self) {
        if let Some(event_store) = self.event_store.take() {
            let _ = event_store.release_agent_delivery_leases(&self.run_id);
        }
    }
}
