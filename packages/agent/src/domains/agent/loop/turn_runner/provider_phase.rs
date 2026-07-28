//! Live tool-surface resolution and audited provider-stream admission.
//!
//! This phase resolves the exact model-tool surface, claims relevant worker
//! inbox context, builds the provider request from durable conversation state,
//! persists the provider-neutral request audit, and only then opens the model
//! stream. It owns no stream processing or turn completion.

use std::sync::Arc;
use std::sync::atomic::AtomicI64;

use tracing::{error, info, trace, warn};

use crate::domains::agent::context::context_manager::ContextManager;
use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::agent::r#loop::surface::{self, ResolvedPrimitiveSurface};
use crate::domains::agent::r#loop::types::{RunContext, TurnResult};
use crate::domains::model::responder::{ModelResponder, ModelResponse, ModelResponseRequest};
use crate::shared::foundation::retry::RetryConfig;
use crate::shared::protocol::messages::Context;
use crate::shared::protocol::model_audit::{
    AutomaticContextEvaluation, ContextManifest, SystemContextContribution,
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
}

/// Turn-local owner of the provider-neutral context and its inspection
/// evidence. Callers cannot mutate the system prompt without recording the
/// same ordered contribution.
struct ProviderContextAssembly {
    context: Context,
    message_sources: Vec<crate::domains::agent::context::message_store::MessageAuditSource>,
    system_contributions: Vec<SystemContextContribution>,
    automatic_context: Vec<AutomaticContextEvaluation>,
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

    fn add_automatic_context(&mut self, evaluation: AutomaticContextEvaluation) {
        if let Some(narrative) = evaluation.narrative.as_deref() {
            self.append_system(
                &format!("{}_context", evaluation.kind),
                if evaluation.kind == "continuity" {
                    "Continuity context"
                } else {
                    "Worker Inbox context"
                },
                narrative,
                serde_json::json!({
                    "outcome":evaluation.outcome,
                    "mechanism":evaluation.mechanism,
                    "workerId":evaluation.worker_id,
                    "workerVersion":evaluation.worker_version,
                    "invocationId":evaluation.invocation_id,
                    "sources":evaluation.sources,
                }),
            );
        }
        self.automatic_context.push(evaluation);
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
    let primitive_surface = match surface::resolve_provider_primitive_surface_for_query(
        params.engine_host,
        params.session_id,
        relevance_query.as_deref(),
        params.run_context.origin_worker_id.as_deref(),
        params.run_context.worker_agent_tools.as_deref(),
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
    let (worker_inbox_context, continuity_context) = tokio::join!(
        surface::take_worker_inbox_context(
            params.engine_host,
            &primitive_surface,
            params.session_id,
            params.turn,
            relevance_query.as_deref(),
            params.run_context.origin_worker_id.as_deref(),
            params.run_context.engine_trace_id.as_ref(),
            params.run_context.parent_invocation_id.as_ref(),
        ),
        surface::take_continuity_context(
            params.engine_host,
            params.session_id,
            params.turn,
            relevance_query.as_deref(),
            Some(params.context_manager.get_working_directory()),
            params.run_context.origin_worker_id.as_deref(),
            params.run_context.engine_trace_id.as_ref(),
            params.run_context.parent_invocation_id.as_ref(),
        )
    );

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
    let mut assembly = ProviderContextAssembly::new(
        projection.context,
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
    assembly.add_automatic_context(continuity_context);
    assembly.add_automatic_context(worker_inbox_context);
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

    Ok(PreparedProviderResponse {
        primitive_surface,
        response,
    })
}
