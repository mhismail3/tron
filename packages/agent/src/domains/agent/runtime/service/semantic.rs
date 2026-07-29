//! Optional semantic preparation that never gates provider admission.
//!
//! Continuity is scoped to its originating run. A result can join a later
//! natural turn only while that run remains active; otherwise its durable
//! delivery is marked stale for audit.

use std::sync::Arc;

use crate::domains::agent::r#loop::orchestrator::core::Orchestrator;
use crate::domains::session::event_store::{
    AgentDeliveryBoundary, AgentDeliveryIntent, AgentDeliverySourceKind, AgentDeliveryTarget,
    AgentDeliveryWakePolicy, EventStore, NewAgentDelivery,
};
use crate::engine::{
    ActorId, ActorKind, CausalContext, EngineHostHandle, FunctionId, Invocation, InvocationId,
    TraceId,
};

#[derive(Clone)]
pub(super) struct OptionalContextPreparation {
    pub(super) host: EngineHostHandle,
    pub(super) event_store: Arc<EventStore>,
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) shutdown_token: Option<tokio_util::sync::CancellationToken>,
    pub(super) session_id: String,
    pub(super) workspace_id: String,
    pub(super) run_id: String,
    pub(super) query: String,
    pub(super) project: Option<String>,
    pub(super) trace_id: TraceId,
    pub(super) parent_invocation_id: Option<InvocationId>,
    pub(super) causal_depth: u32,
    pub(super) allow_semantic_ranking: bool,
}

pub(super) fn spawn_optional_context_preparation(args: OptionalContextPreparation) {
    let shutdown_token = args.shutdown_token.clone();
    drop(tokio::spawn(async move {
        if let Some(shutdown_token) = shutdown_token {
            tokio::select! {
                () = shutdown_token.cancelled() => {}
                () = run_optional_preparation(args) => {}
            }
        } else {
            run_optional_preparation(args).await;
        }
    }));
}

async fn run_optional_preparation(args: OptionalContextPreparation) {
    let continuity = args.clone();
    tokio::join!(run_continuity(continuity), run_semantic_ranking(args));
}

async fn run_semantic_ranking(args: OptionalContextPreparation) {
    if !args.allow_semantic_ranking
        || args.orchestrator.active_run_id(&args.session_id).as_deref()
            != Some(args.run_id.as_str())
    {
        return;
    }
    let _ = crate::domains::agent::r#loop::surface::prepare_semantic_surface(
        &args.host,
        &args.session_id,
        &args.run_id,
        Some(&args.query),
    )
    .await;
    if args.orchestrator.active_run_id(&args.session_id).as_deref() != Some(args.run_id.as_str()) {
        crate::domains::agent::r#loop::surface::clear_semantic_surface(
            &args.session_id,
            &args.run_id,
        );
    }
}

async fn run_continuity(args: OptionalContextPreparation) {
    let Ok(actor_id) = ActorId::new("system:continuity-preparation") else {
        return;
    };
    let Ok(function_id) =
        FunctionId::new(crate::domains::worker_kernel::CONTINUITY_CONTEXT_FUNCTION)
    else {
        return;
    };
    let mut causal = CausalContext::new(actor_id, ActorKind::System, args.trace_id.clone())
        .with_session_id(args.session_id.clone())
        .with_workspace_id(args.workspace_id.clone())
        .with_trigger_depth(args.causal_depth)
        .with_idempotency_key(format!("continuity-async:{}", args.run_id));
    if let Some(parent) = args.parent_invocation_id {
        causal = causal.with_parent_invocation(parent);
    }
    let mut payload = serde_json::json!({"query":args.query});
    if let Some(project) = args.project {
        payload["project"] = serde_json::json!(project);
    }
    let outcome = args
        .host
        .invoke(Invocation::new_sync(function_id, payload, causal))
        .await;
    if outcome.error.is_some()
        || outcome
            .value
            .as_ref()
            .and_then(|value| value.get("handled"))
            .and_then(serde_json::Value::as_bool)
            != Some(true)
    {
        return;
    }
    let Some(value) = outcome.value else {
        return;
    };
    let Some(narrative) = value
        .get("narrative")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return;
    };
    let content = match serde_json::to_string(&serde_json::json!({
        "kind":"continuity",
        "label":"Untrusted saved continuity reference",
        "narrative":narrative,
        "sources":value.get("sources").cloned().unwrap_or_else(|| serde_json::json!([])),
    })) {
        Ok(content) => content,
        Err(_) => return,
    };
    args.orchestrator
        .with_stable_active_run(&args.session_id, |active_run_id| {
            let created = args.event_store.create_agent_delivery(&NewAgentDelivery {
                idempotency_key: format!("continuity-delivery:{}", args.run_id),
                source_kind: AgentDeliverySourceKind::Continuity,
                intent: Some(AgentDeliveryIntent::Information),
                source_session_id: Some(args.session_id.clone()),
                source_workspace_id: args.workspace_id,
                source_invocation_id: value
                    .get("invocationId")
                    .and_then(serde_json::Value::as_str)
                    .map(ToOwned::to_owned),
                source_trace_id: Some(args.trace_id.as_str().to_owned()),
                source_root_invocation_id: None,
                causal_depth: args.causal_depth,
                target: AgentDeliveryTarget::Session {
                    session_id: args.session_id.clone(),
                },
                wake_policy: AgentDeliveryWakePolicy::Passive,
                boundary: AgentDeliveryBoundary::NextTurn,
                originating_run_id: Some(args.run_id.clone()),
                arrived_during_run_id: active_run_id.map(ToOwned::to_owned),
                defer_until_run_id: None,
                result_invocation_id: None,
                content,
                not_before: None,
                expires_at: None,
            });
            if created.is_ok() && active_run_id != Some(args.run_id.as_str()) {
                let _ = args
                    .event_store
                    .stale_run_scoped_deliveries(AgentDeliverySourceKind::Continuity, &args.run_id);
            }
        });
}
