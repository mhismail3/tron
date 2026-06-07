//! Live host projection for the primitive provider surface.
//!
//! Providers see exactly one function, `execute`, resolved from the retained
//! `capability::execute` host primitive at each model-call boundary.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use serde_json::Value;

use crate::domains::capability::contract::EXECUTE_FUNCTION_ID;
use crate::engine::{
    ActorContext, ActorId, ActorKind, AuthorityGrantId, EngineHostHandle, FunctionDefinition,
    FunctionHealth, FunctionId, FunctionQuery,
};
use crate::shared::model_capabilities::{CapabilityParameterSchema, ModelCapability};

const PRIMITIVE_SURFACE_GRANT: &str = "agent-primitive-surface";

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
}

#[derive(Clone, Debug)]
pub struct ResolvedPrimitiveSurface {
    pub capabilities: Vec<ModelCapability>,
    pub targets_by_name: BTreeMap<String, PrimitiveExecutionTarget>,
    pub turn_stopping_capabilities: HashSet<String>,
}

pub(crate) async fn resolve_provider_primitive_surface(
    host: &EngineHostHandle,
    session_id: &str,
    workspace_id: Option<&str>,
) -> Result<ResolvedPrimitiveSurface, String> {
    let resolved = resolve_primitive_targets(host, session_id, workspace_id).await?;
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
) -> Result<ResolvedPrimitiveTargets, String> {
    let actor = primitive_surface_actor(session_id, workspace_id)?;
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

    let mut seen_names = BTreeSet::new();
    let mut targets = Vec::new();
    for function in functions {
        if function.id.namespace() == "rpc" || function.visibility.as_str() == "internal" {
            continue;
        }
        if !is_capability_primitive(&function) || function.request_schema.is_none() {
            continue;
        }
        let Some(model_capability_id) = model_capability_id(&function) else {
            continue;
        };
        if !authority_is_available(&function) || !seen_names.insert(model_capability_id.clone()) {
            continue;
        }
        targets.push(PrimitiveExecutionTarget {
            stops_turn: metadata_bool(&function, "stopsTurn").unwrap_or(false),
            execution_mode: execution_mode(&function),
            model_capability_id,
            function_id: function.id.clone(),
            function,
        });
    }
    Ok(ResolvedPrimitiveTargets {
        targets,
        turn_stopping_capabilities,
    })
}

fn primitive_surface_actor(
    session_id: &str,
    workspace_id: Option<&str>,
) -> Result<ActorContext, String> {
    let mut actor = ActorContext::new(
        ActorId::new(format!("agent:{session_id}")).map_err(|error| error.to_string())?,
        ActorKind::Agent,
        AuthorityGrantId::new(PRIMITIVE_SURFACE_GRANT).map_err(|error| error.to_string())?,
    )
    .with_scope("capability.execute")
    .with_session_id(session_id.to_owned());
    if let Some(workspace_id) = workspace_id {
        actor = actor.with_workspace_id(workspace_id.to_owned());
    }
    Ok(actor)
}

fn authority_is_available(function: &FunctionDefinition) -> bool {
    function
        .required_authority
        .scopes
        .iter()
        .all(|scope| matches!(scope.as_str(), "capability.execute"))
}

fn is_capability_primitive(function: &FunctionDefinition) -> bool {
    function.id.as_str() == EXECUTE_FUNCTION_ID
        && function
            .metadata
            .get("capabilityPrimitive")
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
    use crate::domains::catalog::function_definition_for_capability;
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

    fn merge_metadata(target: &mut Value, extra: Value) {
        match (target, extra) {
            (Value::Object(target), Value::Object(extra)) => {
                for (key, value) in extra {
                    let _ = target.insert(key, value);
                }
            }
            (target, extra) if !extra.is_null() => {
                *target = extra;
            }
            _ => {}
        }
    }

    fn register_execute(host: &EngineHostHandle) {
        host.register_worker_for_setup(worker("capability", "capability"), false)
            .expect("capability worker");
        for spec in crate::domains::capability::contract::capabilities().expect("capabilities") {
            let mut definition = function_definition_for_capability(&spec);
            merge_metadata(
                &mut definition.metadata,
                crate::domains::capability::contract::model_metadata(definition.id.as_str()),
            );
            host.register_function_for_setup(definition, None, false)
                .expect("capability function");
        }
    }

    #[tokio::test]
    async fn provider_surface_contains_only_execute() {
        let host = EngineHostHandle::new_in_memory().expect("host");
        register_execute(&host);
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
        assert!(surface.targets_by_name.contains_key("execute"));
    }

    #[tokio::test]
    async fn provider_prompt_surface_stays_tiny() {
        let host = EngineHostHandle::new_in_memory().expect("host");
        register_execute(&host);
        let surface = resolve_provider_primitive_surface(&host, "session-a", None)
            .await
            .expect("surface");
        assert_eq!(surface.capabilities.len(), 1);
        assert_eq!(surface.capabilities[0].name, "execute");
    }
}
