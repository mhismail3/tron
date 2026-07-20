//! Live host projection for the primitive provider surface.
//!
//! Providers see only direct typed kernel and persistent-worker functions.
//! The removed `capability::execute` wrapper is never projected.

use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::sync::{OnceLock, RwLock};

use serde_json::Value;

use crate::engine::{
    ActorContext, ActorId, ActorKind, AuthorityGrantId, CausalContext, EngineHostHandle,
    FunctionDefinition, FunctionHealth, FunctionId, FunctionQuery, Invocation, InvocationId,
    TraceId,
};
use crate::shared::protocol::model_capabilities::{CapabilityParameterSchema, ModelCapability};

const MAX_RELEVANT_WORKERS: usize = 12;

static SESSION_WORKER_PROMOTIONS: OnceLock<RwLock<BTreeMap<String, BTreeSet<String>>>> =
    OnceLock::new();

pub(crate) fn promote_worker_for_session(session_id: &str, worker_id: &str) {
    let promotions = SESSION_WORKER_PROMOTIONS.get_or_init(|| RwLock::new(BTreeMap::new()));
    if let Ok(mut promotions) = promotions.write() {
        let _ = promotions
            .entry(session_id.to_owned())
            .or_default()
            .insert(worker_id.to_owned());
    }
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
    if !target.trusted_local {
        return None;
    }
    let mut context = CausalContext::trusted_local(
        ActorId::new(format!("agent:{session_id}")).ok()?,
        ActorKind::Agent,
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
    pub stops_turn: bool,
    pub execution_mode: ExecutionMode,
    /// Trusted-local calls bypass per-invocation capability grants.
    pub trusted_local: bool,
}

#[derive(Clone, Debug)]
pub struct ResolvedPrimitiveSurface {
    pub capabilities: Vec<ModelCapability>,
    pub targets_by_name: BTreeMap<String, PrimitiveExecutionTarget>,
    pub turn_stopping_capabilities: HashSet<String>,
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
    let resolved =
        resolve_primitive_targets(host, session_id, workspace_id, relevance_query).await?;
    let mut capabilities = Vec::new();
    let mut targets_by_name = BTreeMap::new();
    let mut turn_stopping_capabilities = resolved.turn_stopping_capabilities;

    for target in resolved.targets {
        let capability = model_capability_schema(&target);
        if target.stops_turn {
            let _ = turn_stopping_capabilities.insert(target.model_capability_id.clone());
        }
        let _ = targets_by_name.insert(target.model_capability_id.clone(), target);
        capabilities.push(capability);
    }

    Ok(ResolvedPrimitiveSurface {
        capabilities,
        targets_by_name,
        turn_stopping_capabilities,
    })
}

struct ResolvedPrimitiveTargets {
    targets: Vec<PrimitiveExecutionTarget>,
    turn_stopping_capabilities: HashSet<String>,
}

async fn resolve_primitive_targets(
    host: &EngineHostHandle,
    session_id: &str,
    workspace_id: Option<&str>,
    relevance_query: Option<&str>,
) -> Result<ResolvedPrimitiveTargets, String> {
    let actor_id =
        ActorId::new(format!("agent:{session_id}")).map_err(|error| error.to_string())?;
    let observation_id =
        AuthorityGrantId::new("trusted-local-observation").map_err(|error| error.to_string())?;
    let mut actor = ActorContext::new(actor_id, ActorKind::Agent, observation_id)
        .with_session_id(session_id.to_owned());
    if let Some(workspace_id) = workspace_id {
        actor = actor.with_workspace_id(workspace_id.to_owned());
    }
    let mut functions = host
        .discover(&FunctionQuery {
            actor: Some(actor),
            health: Some(FunctionHealth::Healthy),
            ..FunctionQuery::default()
        })
        .await;
    let turn_stopping_capabilities = turn_stopping_primitive_names(&functions);
    functions.sort_by_key(|function| {
        (
            function
                .metadata
                .get("capabilityOrder")
                .and_then(Value::as_u64)
                .unwrap_or(u64::MAX),
            function.id.as_str().to_owned(),
        )
    });
    let promoted = SESSION_WORKER_PROMOTIONS
        .get()
        .and_then(|promotions| promotions.read().ok())
        .and_then(|promotions| promotions.get(session_id).cloned())
        .unwrap_or_default();
    let query_terms = relevance_query.map(relevance_terms).unwrap_or_default();
    let mut dynamic = functions
        .iter()
        .filter(|function| metadata_bool(function, "workerDynamic").unwrap_or(false))
        .map(|function| {
            let worker_id = function
                .metadata
                .get("workerId")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let searchable = format!(
                "{} {} {}",
                function.description,
                function
                    .metadata
                    .get("workerRouting")
                    .map(Value::to_string)
                    .unwrap_or_default(),
                function
                    .metadata
                    .get("workerProvenance")
                    .map(Value::to_string)
                    .unwrap_or_default(),
            )
            .to_ascii_lowercase();
            let relevance = query_terms
                .iter()
                .filter(|term| searchable.contains(term.as_str()))
                .count();
            let successes = function
                .metadata
                .pointer("/workerSuccessEvidence/completedRuns")
                .and_then(Value::as_u64)
                .unwrap_or(0);
            (
                promoted.contains(worker_id),
                relevance,
                successes,
                function.id.clone(),
            )
        })
        .collect::<Vec<_>>();
    dynamic.sort_by(|left, right| {
        right
            .0
            .cmp(&left.0)
            .then_with(|| right.1.cmp(&left.1))
            .then_with(|| right.2.cmp(&left.2))
            .then_with(|| left.3.as_str().cmp(right.3.as_str()))
    });
    let selected_dynamic = dynamic
        .into_iter()
        .filter(|(is_promoted, relevance, _, _)| {
            *is_promoted || query_terms.is_empty() || *relevance > 0
        })
        .take(MAX_RELEVANT_WORKERS)
        .map(|(_, _, _, id)| id)
        .collect::<BTreeSet<_>>();

    let mut seen_names = BTreeSet::new();
    let mut targets = Vec::new();
    for function in functions {
        if function.id.namespace() == "rpc" || function.visibility.as_str() == "internal" {
            continue;
        }
        if !is_provider_primitive(&function) || function.request_schema.is_none() {
            continue;
        }
        if metadata_bool(&function, "workerDynamic").unwrap_or(false)
            && !selected_dynamic.contains(&function.id)
        {
            continue;
        }
        let Some(model_capability_id) = model_capability_id(&function) else {
            continue;
        };
        let trusted_local = function
            .metadata
            .get("modelPrimitive")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if !trusted_local || !seen_names.insert(model_capability_id.clone()) {
            continue;
        }
        targets.push(PrimitiveExecutionTarget {
            stops_turn: metadata_bool(&function, "stopsTurn").unwrap_or(false),
            execution_mode: execution_mode(&function),
            model_capability_id,
            function_id: function.id.clone(),
            trusted_local,
            function,
        });
    }
    Ok(ResolvedPrimitiveTargets {
        targets,
        turn_stopping_capabilities,
    })
}

fn relevance_terms(value: &str) -> BTreeSet<String> {
    value
        .split(|character: char| !character.is_ascii_alphanumeric())
        .map(str::to_ascii_lowercase)
        .filter(|term| term.len() > 2)
        .collect()
}

fn is_provider_primitive(function: &FunctionDefinition) -> bool {
    function
        .metadata
        .get("modelPrimitive")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn model_capability_id(function: &FunctionDefinition) -> Option<String> {
    function
        .metadata
        .get("modelPrimitiveName")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

fn metadata_bool(function: &FunctionDefinition, key: &str) -> Option<bool> {
    function.metadata.get(key).and_then(Value::as_bool)
}

fn turn_stopping_primitive_names(functions: &[FunctionDefinition]) -> HashSet<String> {
    functions
        .iter()
        .filter(|function| function_stops_turn(function))
        .filter_map(model_capability_id)
        .collect()
}

fn function_stops_turn(function: &FunctionDefinition) -> bool {
    metadata_bool(function, "stopsTurn").unwrap_or(false)
        || function
            .metadata
            .get("lifecycle")
            .and_then(|value| value.get("stopsTurn"))
            .and_then(Value::as_bool)
            .unwrap_or(false)
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
    use super::*;
    use crate::engine::{
        ActorId, AuthorityGrantId, EffectClass, FunctionDefinition, WorkerDefinition, WorkerId,
        WorkerKind,
    };

    fn worker(id: &str, namespace: &str) -> WorkerDefinition {
        WorkerDefinition::new(
            WorkerId::new(id).expect("worker id"),
            WorkerKind::System,
            ActorId::new("system").expect("actor id"),
            AuthorityGrantId::new("engine-transport").expect("grant id"),
        )
        .with_namespace_claim(namespace)
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
            "workerRouting": routing,
            "workerProvenance": {"source": "test fixture"},
            "workerSuccessEvidence": {"completedRuns": 3}
        });
        host.register_function_for_setup(definition, None, false)
            .expect("worker function");
    }

    #[tokio::test]
    async fn non_model_functions_are_not_projected() {
        let host = EngineHostHandle::new_in_memory().expect("host");
        host.register_worker_for_setup(worker("demo", "demo"), false)
            .expect("demo worker");
        let mut old_builtin_like_function = FunctionDefinition::new(
            FunctionId::new("demo::read").expect("function id"),
            WorkerId::new("demo").expect("worker id"),
            "Should not be provider-facing",
            crate::engine::VisibilityScope::System,
            EffectClass::PureRead,
        );
        old_builtin_like_function.metadata =
            serde_json::json!({"modelPrimitiveName": "old_filesystem_read"});
        host.register_function_for_setup(old_builtin_like_function, None, false)
            .expect("nonprimitive function");

        let surface = resolve_provider_primitive_surface(&host, "session-a", None)
            .await
            .expect("surface");
        assert!(surface.capabilities.is_empty());
    }

    #[tokio::test]
    async fn autonomous_surface_hides_execute_and_selects_relevant_typed_workers() {
        let host = EngineHostHandle::new_in_memory().expect("host");
        host.register_worker_for_setup(worker("worker_kernel", "worker_kernel"), false)
            .expect("worker kernel");
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
        assert!(surface.targets_by_name["recent_research"].trusted_local);
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
        host.register_worker_for_setup(worker("worker_kernel", "worker_kernel"), false)
            .expect("worker kernel");
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

        promote_worker_for_session("promotion-session", "formatter-promoted");
        let after = resolve_provider_primitive_surface_for_query(
            &host,
            "promotion-session",
            None,
            Some("astronomy ephemeris"),
        )
        .await
        .expect("surface after promotion");
        assert!(after.targets_by_name.contains_key("format_notes_promoted"));
    }
}
