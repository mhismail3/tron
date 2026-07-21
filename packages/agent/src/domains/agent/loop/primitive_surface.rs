//! Live host projection for the primitive provider surface.
//!
//! Providers see only direct typed kernel and persistent-worker functions.
//! The removed `capability::execute` wrapper is never projected.

use std::collections::BTreeMap;

use serde_json::Value;

use crate::engine::{
    ActorId, ActorKind, CausalContext, EngineHostHandle, FunctionDefinition, FunctionId,
    Invocation, InvocationId, TraceId,
};
use crate::shared::protocol::model_capabilities::{CapabilityParameterSchema, ModelCapability};

#[cfg(test)]
pub(crate) async fn promote_worker_for_session(
    host: &EngineHostHandle,
    session_id: &str,
    worker_id: &str,
) {
    crate::domains::worker_kernel::promote_worker_for_session(host, session_id, worker_id, "v1")
        .await
        .expect("promote worker for test session");
}

/// Compact provider-turn awareness of the exact live engine surface.
pub(crate) fn surface_context_primer(
    snapshot: &crate::domains::worker_kernel::EngineSurfaceSnapshot,
) -> String {
    let projected = snapshot
        .tools
        .iter()
        .filter(|tool| tool.worker_id.is_some())
        .map(|tool| match &tool.worker_version {
            Some(version) => format!("{}@{}", tool.model_name, short_hash(version)),
            None => tool.model_name.clone(),
        })
        .collect::<Vec<_>>();
    let projected = if projected.is_empty() {
        "none".to_owned()
    } else {
        projected.join(", ")
    };
    format!(
        "Engine surface r{} · {} fixed tools · {}/{} workers projected · surface {} · projected: {}. Use worker_discover when the task needs an available worker not projected here.",
        snapshot.catalog_revision,
        snapshot.fixed_tool_count,
        snapshot.projected_worker_count,
        snapshot.available_worker_count,
        short_hash(&snapshot.surface_hash),
        projected,
    )
}

fn short_hash(value: &str) -> &str {
    value.get(..8).unwrap_or(value)
}

/// Atomically claims notable unseen background-worker results and formats a
/// bounded transient primer for the next relevant model turn.
pub(crate) async fn take_worker_inbox_context(
    host: &EngineHostHandle,
    surface: &ResolvedPrimitiveSurface,
    session_id: &str,
    turn: u32,
    relevance_query: Option<&str>,
    trace_id: Option<&TraceId>,
    parent_invocation_id: Option<&InvocationId>,
) -> Option<String> {
    let target = surface.targets_by_name.get("worker_inbox")?;
    if !target.model_callable {
        return None;
    }
    // INVARIANT: inbox attachment is an engine-owned projection step, not a
    // model tool call. Attribute the observation to the session while using an
    // internal runtime actor so the hidden operation satisfies its visibility
    // boundary without pretending to be a model tool call.
    let mut context = CausalContext::new(
        ActorId::new("system:agent-runtime").ok()?,
        ActorKind::System,
        trace_id.cloned().unwrap_or_else(TraceId::generate),
    )
    .with_session_id(session_id.to_owned())
    .with_idempotency_key(format!("worker-inbox-attach:{session_id}:{turn}"));
    if let Some(parent) = parent_invocation_id {
        context = context.with_parent_invocation(parent.clone());
    }
    let outcome = host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::inbox_attach").ok()?,
            serde_json::json!({
                "limit": 8,
                "relevanceQuery": relevance_query.unwrap_or_default(),
            }),
            context,
        ))
        .await;
    if outcome.error.is_some() {
        return None;
    }
    let items = outcome.value?.get("items")?.as_array()?.clone();
    if items.is_empty() {
        return None;
    }
    let body = serde_json::to_string_pretty(&items).ok()?;
    Some(format!(
        "Persistent worker inbox updates (durable, previously unseen observations):\n{body}\nUse these results when relevant. Failures are evidence for deliberate improvement, rollback, disablement, or retirement."
    ))
}

/// Controls how one model protocol call is scheduled relative to others.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ExecutionMode {
    /// Execute concurrently with all other parallel primitive calls.
    Parallel,
    /// Execute sequentially within a named group.
    Serialized(String),
}

#[derive(Clone, Debug)]
pub struct PrimitiveExecutionTarget {
    pub model_capability_id: String,
    pub function_id: FunctionId,
    pub function: FunctionDefinition,
    pub execution_mode: ExecutionMode,
    /// Whether this function is explicitly registered for model invocation.
    pub model_callable: bool,
}

#[derive(Clone, Debug)]
pub struct ResolvedPrimitiveSurface {
    pub capabilities: Vec<ModelCapability>,
    pub targets_by_name: BTreeMap<String, PrimitiveExecutionTarget>,
    /// Exact provider-neutral catalog evidence used to construct this surface.
    pub snapshot: crate::domains::worker_kernel::EngineSurfaceSnapshot,
}

#[cfg(test)]
pub(crate) async fn resolve_provider_primitive_surface(
    host: &EngineHostHandle,
    session_id: &str,
    workspace_id: Option<&str>,
) -> Result<ResolvedPrimitiveSurface, String> {
    resolve_provider_primitive_surface_for_query(host, session_id, workspace_id, None).await
}

pub(crate) async fn resolve_provider_primitive_surface_for_query(
    host: &EngineHostHandle,
    session_id: &str,
    workspace_id: Option<&str>,
    relevance_query: Option<&str>,
) -> Result<ResolvedPrimitiveSurface, String> {
    let resolved = crate::domains::worker_kernel::resolve_tool_surface(
        host,
        session_id,
        workspace_id,
        relevance_query,
    )
    .await?;
    let mut capabilities = Vec::new();
    let mut targets_by_name = BTreeMap::new();

    for resolved_function in resolved.functions {
        let target = PrimitiveExecutionTarget {
            model_capability_id: resolved_function.model_name,
            function_id: resolved_function.definition.id.clone(),
            execution_mode: execution_mode(&resolved_function.definition),
            model_callable: resolved_function.model_callable,
            function: resolved_function.definition,
        };
        let capability = model_capability_schema(&target);
        let _ = targets_by_name.insert(target.model_capability_id.clone(), target);
        capabilities.push(capability);
    }

    Ok(ResolvedPrimitiveSurface {
        capabilities,
        targets_by_name,
        snapshot: resolved.snapshot,
    })
}

fn execution_mode(function: &FunctionDefinition) -> ExecutionMode {
    let Some(mode) = function
        .metadata
        .get("capabilityExecutionMode")
        .and_then(Value::as_object)
    else {
        return ExecutionMode::Parallel;
    };
    match mode.get("kind").and_then(Value::as_str) {
        Some("serialized") => ExecutionMode::Serialized(
            mode.get("group")
                .and_then(Value::as_str)
                .unwrap_or("default")
                .to_owned(),
        ),
        _ => ExecutionMode::Parallel,
    }
}

fn model_capability_schema(target: &PrimitiveExecutionTarget) -> ModelCapability {
    if let Some(capability) = target
        .function
        .metadata
        .get("capabilitySchema")
        .and_then(|value| serde_json::from_value::<ModelCapability>(value.clone()).ok())
    {
        return capability;
    }
    ModelCapability {
        name: target.model_capability_id.clone(),
        description: target.function.description.clone(),
        parameters: parameter_schema_from_value(
            target
                .function
                .request_schema
                .clone()
                .unwrap_or_else(|| serde_json::json!({"type": "object"})),
        ),
    }
}

fn parameter_schema_from_value(value: Value) -> CapabilityParameterSchema {
    serde_json::from_value(value).unwrap_or_else(|_| CapabilityParameterSchema {
        schema_type: "object".to_owned(),
        properties: None,
        required: None,
        description: None,
        extra: serde_json::Map::new(),
    })
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::engine::{EffectClass, FunctionDefinition, WorkerId};

    struct InboxAttachHandler;

    #[async_trait::async_trait]
    impl crate::engine::InProcessFunctionHandler for InboxAttachHandler {
        async fn invoke(
            &self,
            _invocation: crate::engine::Invocation,
        ) -> crate::engine::Result<Value> {
            Ok(serde_json::json!({
                "items": [{"workerId":"background-worker","result":{"summary":"ready"}}]
            }))
        }
    }

    fn register_worker_primitive(
        host: &EngineHostHandle,
        function_name: &str,
        tool_name: &str,
        description: &str,
        dynamic: bool,
        worker_id: &str,
        routing: Value,
    ) {
        let function_id =
            FunctionId::new(format!("worker_kernel::{function_name}")).expect("worker function id");
        let mut definition = FunctionDefinition::new(
            function_id,
            WorkerId::new("worker_kernel").expect("worker id"),
            description,
            crate::engine::VisibilityScope::System,
            EffectClass::PureRead,
        )
        .with_request_schema(serde_json::json!({
            "type": "object",
            "properties": {"query": {"type": "string"}},
            "required": ["query"],
            "additionalProperties": false
        }));
        definition.metadata = serde_json::json!({
            "modelPrimitive": true,
            "modelPrimitiveName": tool_name,
            "workerDynamic": dynamic,
            "workerId": worker_id,
            "workerVersion": "v1",
            "workerRouting": routing,
            "workerProvenance": {"source": "test fixture"},
            "workerSuccessEvidence": {"completedRuns": 3}
        });
        host.register_function_for_setup(definition, Arc::new(InboxAttachHandler))
            .expect("worker function");
    }

    #[tokio::test]
    async fn non_model_functions_are_not_projected() {
        let host = EngineHostHandle::new_in_memory().expect("host");
        let mut old_builtin_like_function = FunctionDefinition::new(
            FunctionId::new("demo::read").expect("function id"),
            WorkerId::new("demo").expect("worker id"),
            "Should not be provider-facing",
            crate::engine::VisibilityScope::System,
            EffectClass::PureRead,
        );
        old_builtin_like_function.metadata =
            serde_json::json!({"modelPrimitiveName": "old_filesystem_read"});
        host.register_function_for_setup(old_builtin_like_function, Arc::new(InboxAttachHandler))
            .expect("nonprimitive function");

        let surface = resolve_provider_primitive_surface(&host, "session-a", None)
            .await
            .expect("surface");
        assert!(surface.capabilities.is_empty());
    }

    #[tokio::test]
    async fn engine_owned_inbox_attachment_crosses_internal_visibility_for_trusted_runtime() {
        let host = EngineHostHandle::new_in_memory().expect("host");
        register_worker_primitive(
            &host,
            "inbox",
            "worker_inbox",
            "Read durable worker results",
            false,
            "kernel",
            serde_json::json!({}),
        );
        let attach = FunctionDefinition::new(
            FunctionId::new("worker_kernel::inbox_attach").expect("function id"),
            WorkerId::new("worker_kernel").expect("worker id"),
            "Attach unseen inbox results",
            crate::engine::VisibilityScope::Internal,
            EffectClass::IdempotentWrite,
        )
        .with_idempotency(crate::engine::IdempotencyContract::caller_system_engine_ledger())
        .with_request_schema(serde_json::json!({"type":"object"}))
        .with_response_schema(serde_json::json!({"type":"object"}));
        host.register_function_for_setup(attach, Arc::new(InboxAttachHandler))
            .expect("internal inbox attachment");

        let surface = resolve_provider_primitive_surface(&host, "session-a", None)
            .await
            .expect("surface");
        let primer = take_worker_inbox_context(
            &host,
            &surface,
            "session-a",
            1,
            Some("background"),
            None,
            None,
        )
        .await
        .expect("inbox primer");

        assert!(primer.contains("background-worker"));
        assert!(primer.contains("ready"));
    }

    #[tokio::test]
    async fn autonomous_surface_hides_execute_and_selects_relevant_typed_workers() {
        let host = EngineHostHandle::new_in_memory().expect("host");
        register_worker_primitive(
            &host,
            "worker_upsert",
            "worker_upsert",
            "Create or update a persistent worker",
            false,
            "kernel",
            serde_json::json!({}),
        );
        register_worker_primitive(
            &host,
            "dynamic_recent_research",
            "recent_research",
            "Research recent sources and synthesize findings",
            true,
            "recent-research",
            serde_json::json!({"keywords": ["recent", "research", "sources"]}),
        );
        register_worker_primitive(
            &host,
            "dynamic_formatter",
            "format_notes",
            "Format prose notes into a clean document",
            true,
            "formatter",
            serde_json::json!({"keywords": ["format", "document"]}),
        );

        let surface = resolve_provider_primitive_surface_for_query(
            &host,
            "autonomy-session",
            None,
            Some("perform recent research with sources"),
        )
        .await
        .expect("autonomous surface");

        assert!(!surface.targets_by_name.contains_key("execute"));
        assert!(surface.targets_by_name.contains_key("worker_upsert"));
        assert!(surface.targets_by_name.contains_key("recent_research"));
        assert!(!surface.targets_by_name.contains_key("format_notes"));
        assert!(surface.targets_by_name["recent_research"].model_callable);
        assert_eq!(surface.snapshot.fixed_tool_count, 1);
        assert_eq!(surface.snapshot.projected_worker_count, 1);
        assert_eq!(surface.snapshot.available_worker_count, 2);
        assert!(
            surface
                .snapshot
                .tools
                .iter()
                .any(|tool| tool.model_name == "worker_upsert")
        );
        assert_eq!(
            surface
                .snapshot
                .tools
                .iter()
                .find(|tool| tool.model_name == "recent_research")
                .expect("relevant worker")
                .selection_reason,
            "relevance"
        );
        assert_eq!(surface.snapshot.surface_hash.len(), 64);
        let schema = surface
            .capabilities
            .iter()
            .find(|capability| capability.name == "recent_research")
            .expect("worker schema");
        assert_eq!(schema.parameters.schema_type, "object");
        assert_eq!(schema.parameters.required, Some(vec!["query".to_owned()]));
    }

    #[tokio::test]
    async fn worker_discovery_promotion_changes_the_live_session_surface() {
        let host = EngineHostHandle::new_in_memory().expect("host");
        register_worker_primitive(
            &host,
            "worker_upsert",
            "worker_upsert",
            "Create or update a persistent worker",
            false,
            "kernel",
            serde_json::json!({}),
        );
        register_worker_primitive(
            &host,
            "dynamic_formatter_promoted",
            "format_notes_promoted",
            "Format prose notes into a clean document",
            true,
            "formatter-promoted",
            serde_json::json!({"keywords": ["format", "document"]}),
        );

        let before = resolve_provider_primitive_surface_for_query(
            &host,
            "promotion-session",
            None,
            Some("astronomy ephemeris"),
        )
        .await
        .expect("surface before promotion");
        assert!(!before.targets_by_name.contains_key("format_notes_promoted"));

        promote_worker_for_session(&host, "promotion-session", "formatter-promoted").await;
        let after = resolve_provider_primitive_surface_for_query(
            &host,
            "promotion-session",
            None,
            Some("astronomy ephemeris"),
        )
        .await
        .expect("surface after promotion");
        assert!(after.targets_by_name.contains_key("format_notes_promoted"));
        assert_eq!(
            after
                .snapshot
                .tools
                .iter()
                .find(|tool| tool.model_name == "format_notes_promoted")
                .expect("promoted tool")
                .selection_reason,
            "session_promotion"
        );
    }

    #[tokio::test]
    async fn worker_discovery_promotion_survives_engine_restart() {
        let directory = tempfile::tempdir().expect("temporary engine state");
        let path = directory.path().join("engine.sqlite3");
        {
            let host = EngineHostHandle::open_sqlite(&path).expect("durable host");
            register_worker_primitive(
                &host,
                "dynamic_durable_formatter",
                "durable_formatter",
                "Format prose notes into a clean document",
                true,
                "durable-formatter",
                serde_json::json!({"keywords": ["format", "document"]}),
            );
            promote_worker_for_session(&host, "durable-session", "durable-formatter").await;
        }

        let reopened = EngineHostHandle::open_sqlite(&path).expect("reopened durable host");
        register_worker_primitive(
            &reopened,
            "dynamic_durable_formatter",
            "durable_formatter",
            "Format prose notes into a clean document",
            true,
            "durable-formatter",
            serde_json::json!({"keywords": ["format", "document"]}),
        );

        let surface = resolve_provider_primitive_surface_for_query(
            &reopened,
            "durable-session",
            None,
            Some("astronomy ephemeris"),
        )
        .await
        .expect("surface after restart");
        assert_eq!(
            surface
                .snapshot
                .tools
                .iter()
                .find(|tool| tool.model_name == "durable_formatter")
                .expect("durably promoted tool")
                .selection_reason,
            "session_promotion"
        );
    }

    #[tokio::test]
    async fn repeated_promotions_keep_the_complete_dynamic_surface_bounded() {
        let host = EngineHostHandle::new_in_memory().expect("host");
        for index in 0..15 {
            let worker_id = format!("promoted-{index:02}");
            register_worker_primitive(
                &host,
                &format!("dynamic_promoted_{index:02}"),
                &format!("promoted_tool_{index:02}"),
                "Explicitly promoted worker",
                true,
                &worker_id,
                serde_json::json!({"keywords": ["unrelated"]}),
            );
            promote_worker_for_session(&host, "bounded-session", &worker_id).await;
        }

        let surface = resolve_provider_primitive_surface_for_query(
            &host,
            "bounded-session",
            None,
            Some("astronomy ephemeris"),
        )
        .await
        .expect("bounded surface");

        assert_eq!(surface.snapshot.projected_worker_count, 12);
        assert_eq!(
            surface
                .snapshot
                .available_workers
                .iter()
                .filter(|worker| worker.projected)
                .count(),
            12
        );
        assert!(surface.targets_by_name.contains_key("promoted_tool_14"));
        assert!(!surface.targets_by_name.contains_key("promoted_tool_00"));
    }

    #[tokio::test]
    async fn promotion_for_an_old_worker_version_does_not_revive_a_recreated_worker() {
        let host = EngineHostHandle::new_in_memory().expect("host");
        register_worker_primitive(
            &host,
            "dynamic_recreated",
            "recreated_tool",
            "Recreated worker",
            true,
            "recreated",
            serde_json::json!({"keywords": ["format"]}),
        );
        crate::domains::worker_kernel::promote_worker_for_session(
            &host,
            "recreated-session",
            "recreated",
            "retired-version",
        )
        .await
        .expect("stale promotion record");

        let surface = resolve_provider_primitive_surface_for_query(
            &host,
            "recreated-session",
            None,
            Some("astronomy ephemeris"),
        )
        .await
        .expect("surface");
        assert!(!surface.targets_by_name.contains_key("recreated_tool"));
        let worker = surface
            .snapshot
            .available_workers
            .iter()
            .find(|worker| worker.worker_id == "recreated")
            .expect("available worker");
        assert!(!worker.promoted);
        assert!(!worker.projected);
    }

    #[test]
    fn surface_primer_is_compact_and_explains_hidden_workers() {
        let primer =
            surface_context_primer(&crate::domains::worker_kernel::EngineSurfaceSnapshot {
                format: 1,
                catalog_revision: 42,
                surface_hash: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
                    .to_owned(),
                fixed_tool_count: 27,
                projected_worker_count: 1,
                available_worker_count: 7,
                tools: vec![crate::domains::worker_kernel::SurfaceToolSnapshot {
                    model_name: "worker_recent_research".to_owned(),
                    function_id: "worker_kernel::dynamic_recent".to_owned(),
                    function_revision: 2,
                    owner_worker: "worker_kernel".to_owned(),
                    description: "Recent research".to_owned(),
                    input_schema: serde_json::json!({"type":"object"}),
                    output_schema: Some(serde_json::json!({"type":"object"})),
                    effect_class: "ExternalSideEffect".to_owned(),
                    risk: "high".to_owned(),
                    health: "Healthy".to_owned(),
                    exposed: true,
                    worker_id: Some("recent".to_owned()),
                    worker_version: Some("abcdef1234567890".to_owned()),
                    primitive_group: None,
                    selection_reason: "relevance".to_owned(),
                }],
                available_workers: Vec::new(),
            });
        assert!(primer.contains("r42"));
        assert!(primer.contains("1/7 workers"));
        assert!(primer.contains("worker_recent_research@abcdef12"));
        assert!(primer.contains("worker_discover"));
    }
}
