//! Canonical provider-tool surface selection and introspection.
//!
//! This module owns worker relevance, session promotion, stable ordering, and
//! provider-neutral surface evidence. Agent/provider code adapts the resolved
//! function contracts to provider schemas; it does not maintain a second
//! worker-selection implementation.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::engine::{
    ActorContext, ActorId, ActorKind, EngineHostHandle, EngineStateScope, FunctionDefinition,
    FunctionHealth, FunctionQuery,
};

const MAX_RELEVANT_WORKERS: usize = 12;
const SURFACE_FORMAT_VERSION: u32 = 1;

const PROMOTION_NAMESPACE: &str = "worker_kernel.surface_promotions";

/// Make one worker unconditionally available to the next provider turn in a
/// session.
pub(crate) async fn promote_worker_for_session(
    host: &EngineHostHandle,
    session_id: &str,
    worker_id: &str,
) -> Result<(), String> {
    host.write_engine_state(
        EngineStateScope::Session(session_id.to_owned()),
        PROMOTION_NAMESPACE,
        worker_id,
        serde_json::json!({"promoted":true}),
    )
    .await
    .map(|_| ())
    .map_err(|error| error.to_string())
}

async fn session_worker_promotions(
    host: &EngineHostHandle,
    session_id: &str,
) -> Result<BTreeSet<String>, String> {
    host.list_engine_state(
        EngineStateScope::Session(session_id.to_owned()),
        PROMOTION_NAMESPACE,
        None,
        1_024,
    )
    .await
    .map(|entries| entries.into_iter().map(|entry| entry.key).collect())
    .map_err(|error| error.to_string())
}

/// Provider-neutral evidence for one tool on a resolved model surface.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SurfaceToolSnapshot {
    pub(crate) model_name: String,
    pub(crate) function_id: String,
    pub(crate) function_revision: u64,
    pub(crate) owner_worker: String,
    pub(crate) description: String,
    pub(crate) input_schema: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) output_schema: Option<Value>,
    pub(crate) effect_class: String,
    pub(crate) risk: String,
    pub(crate) health: String,
    pub(crate) exposed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) worker_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) worker_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) primitive_group: Option<String>,
    pub(crate) selection_reason: String,
}

/// Publication and selection evidence for every enabled direct worker tool,
/// including workers not projected into this particular provider request.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AvailableWorkerToolSnapshot {
    pub(crate) worker_id: String,
    pub(crate) model_name: String,
    pub(crate) function_id: String,
    pub(crate) function_revision: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) worker_version: Option<String>,
    pub(crate) promoted: bool,
    pub(crate) projected: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) selection_reason: Option<String>,
    pub(crate) relevance_score: usize,
    pub(crate) completed_runs: u64,
    pub(crate) health: String,
}

/// Exact provider-neutral surface resolved for one agent request boundary.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct EngineSurfaceSnapshot {
    pub(crate) format: u32,
    pub(crate) catalog_revision: u64,
    pub(crate) surface_hash: String,
    pub(crate) fixed_tool_count: usize,
    pub(crate) projected_worker_count: usize,
    pub(crate) available_worker_count: usize,
    pub(crate) tools: Vec<SurfaceToolSnapshot>,
    pub(crate) available_workers: Vec<AvailableWorkerToolSnapshot>,
}

/// One live function selected for provider adaptation.
#[derive(Clone, Debug)]
pub(crate) struct ResolvedToolFunction {
    pub(crate) model_name: String,
    pub(crate) definition: FunctionDefinition,
    pub(crate) stops_turn: bool,
    pub(crate) trusted_local: bool,
}

/// Function contracts plus the exact catalog evidence used to select them.
#[derive(Clone, Debug)]
pub(crate) struct ResolvedToolSurface {
    pub(crate) functions: Vec<ResolvedToolFunction>,
    pub(crate) snapshot: EngineSurfaceSnapshot,
}

/// Resolve the exact fixed and dynamic function contracts for one provider
/// request.
pub(crate) async fn resolve_tool_surface(
    host: &EngineHostHandle,
    session_id: &str,
    workspace_id: Option<&str>,
    relevance_query: Option<&str>,
) -> Result<ResolvedToolSurface, String> {
    let actor_id =
        ActorId::new(format!("agent:{session_id}")).map_err(|error| error.to_string())?;
    let mut actor =
        ActorContext::new(actor_id, ActorKind::Agent).with_session_id(session_id.to_owned());
    if let Some(workspace_id) = workspace_id {
        actor = actor.with_workspace_id(workspace_id.to_owned());
    }
    let (catalog_revision, mut functions) = host
        .discover_with_revision(&FunctionQuery {
            actor: Some(actor),
            health: Some(FunctionHealth::Healthy),
            ..FunctionQuery::default()
        })
        .await;
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

    let promoted = session_worker_promotions(host, session_id).await?;
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
    let available_worker_count = dynamic.len();
    dynamic.sort_by(|left, right| {
        right
            .0
            .cmp(&left.0)
            .then_with(|| right.1.cmp(&left.1))
            .then_with(|| right.2.cmp(&left.2))
            .then_with(|| left.3.as_str().cmp(right.3.as_str()))
    });
    let mut selected_dynamic = dynamic
        .iter()
        .filter(|(is_promoted, _, _, _)| *is_promoted)
        .map(|(_, _, _, id)| (id.clone(), "session_promotion"))
        .collect::<BTreeMap<_, _>>();
    for (is_promoted, relevance, _, id) in &dynamic {
        if *is_promoted
            || (!query_terms.is_empty() && *relevance == 0)
            || selected_dynamic.len() >= MAX_RELEVANT_WORKERS
        {
            continue;
        }
        let reason = if *relevance > 0 {
            "relevance"
        } else {
            "default"
        };
        let _ = selected_dynamic.insert(id.clone(), reason);
    }
    let available_workers = dynamic
        .iter()
        .filter_map(|(is_promoted, relevance, successes, id)| {
            let function = functions.iter().find(|function| function.id == *id)?;
            let worker_id = function.metadata.get("workerId")?.as_str()?.to_owned();
            let model_name = model_tool_name(function)?;
            let selection_reason = selected_dynamic.get(id).map(|reason| (*reason).to_owned());
            Some(AvailableWorkerToolSnapshot {
                worker_id,
                model_name,
                function_id: id.as_str().to_owned(),
                function_revision: function.revision.0,
                worker_version: function
                    .metadata
                    .get("workerVersion")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
                promoted: *is_promoted,
                projected: selection_reason.is_some(),
                selection_reason,
                relevance_score: *relevance,
                completed_runs: *successes,
                health: serialized_key(&function.health),
            })
        })
        .collect::<Vec<_>>();

    let mut seen_names = BTreeSet::new();
    let mut resolved = Vec::new();
    let mut snapshot_tools = Vec::new();
    for function in functions {
        if function.id.namespace() == "rpc" || function.visibility.as_str() == "internal" {
            continue;
        }
        if !is_provider_primitive(&function) || function.request_schema.is_none() {
            continue;
        }
        let is_dynamic = metadata_bool(&function, "workerDynamic").unwrap_or(false);
        let selection_reason = if is_dynamic {
            let Some(reason) = selected_dynamic.get(&function.id) else {
                continue;
            };
            *reason
        } else {
            "fixed"
        };
        let Some(model_name) = model_tool_name(&function) else {
            continue;
        };
        let trusted_local = metadata_bool(&function, "modelPrimitive").unwrap_or(false);
        if !trusted_local {
            continue;
        }
        if !seen_names.insert(model_name.clone()) {
            return Err(format!(
                "duplicate model tool name {model_name} in live catalog"
            ));
        }
        let stops_turn = function_stops_turn(&function);
        snapshot_tools.push(SurfaceToolSnapshot {
            model_name: model_name.clone(),
            function_id: function.id.as_str().to_owned(),
            function_revision: function.revision.0,
            owner_worker: function.owner_worker.as_str().to_owned(),
            description: function.description.clone(),
            input_schema: function
                .request_schema
                .clone()
                .unwrap_or_else(|| serde_json::json!({"type":"object"})),
            output_schema: function.response_schema.clone(),
            effect_class: serialized_key(&function.effect_class),
            risk: function.risk_level.as_str().to_owned(),
            health: serialized_key(&function.health),
            exposed: true,
            worker_id: is_dynamic.then(|| {
                function
                    .metadata
                    .get("workerId")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned()
            }),
            worker_version: function
                .metadata
                .get("workerVersion")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            primitive_group: function
                .metadata
                .get("modelPrimitiveGroup")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            selection_reason: selection_reason.to_owned(),
        });
        resolved.push(ResolvedToolFunction {
            model_name,
            definition: function,
            stops_turn,
            trusted_local,
        });
    }

    let fixed_tool_count = snapshot_tools
        .iter()
        .filter(|tool| tool.worker_id.is_none())
        .count();
    let projected_worker_count = snapshot_tools.len().saturating_sub(fixed_tool_count);
    let surface_hash = surface_hash(&snapshot_tools)?;
    Ok(ResolvedToolSurface {
        functions: resolved,
        snapshot: EngineSurfaceSnapshot {
            format: SURFACE_FORMAT_VERSION,
            catalog_revision: catalog_revision.0,
            surface_hash,
            fixed_tool_count,
            projected_worker_count,
            available_worker_count,
            tools: snapshot_tools,
            available_workers,
        },
    })
}

/// Inspect the canonical fixed model-tool inventory independently of whether
/// autonomous mode currently projects those tools to a provider request.
pub(crate) async fn fixed_tool_inventory(
    host: &EngineHostHandle,
    resolved_surface: &EngineSurfaceSnapshot,
) -> Result<Vec<SurfaceToolSnapshot>, String> {
    let mut tools = Vec::with_capacity(super::contract::core_primitives().len());
    let inspector = ActorContext::new(
        ActorId::new("system:engine-introspection").map_err(|error| error.to_string())?,
        ActorKind::System,
    );
    for descriptor in super::contract::core_primitives() {
        let function_id =
            crate::engine::FunctionId::new(format!("worker_kernel::{}", descriptor.operation_key))
                .map_err(|error| error.to_string())?;
        let function = host
            .inspect_function(&function_id, Some(&inspector))
            .await
            .map_err(|error| error.to_string())?;
        let exposed = resolved_surface
            .tools
            .iter()
            .any(|tool| tool.function_id == function.id.as_str());
        tools.push(SurfaceToolSnapshot {
            model_name: descriptor.model_name.to_owned(),
            function_id: function.id.as_str().to_owned(),
            function_revision: function.revision.0,
            owner_worker: function.owner_worker.as_str().to_owned(),
            description: function.description.clone(),
            input_schema: function
                .request_schema
                .clone()
                .unwrap_or_else(|| serde_json::json!({"type":"object"})),
            output_schema: function.response_schema.clone(),
            effect_class: serialized_key(&function.effect_class),
            risk: function.risk_level.as_str().to_owned(),
            health: serialized_key(&function.health),
            exposed,
            worker_id: None,
            worker_version: None,
            primitive_group: Some(descriptor.group.as_str().to_owned()),
            selection_reason: "fixed".to_owned(),
        });
    }
    Ok(tools)
}

fn serialized_key<T: Serialize>(value: &T) -> String {
    serde_json::to_value(value)
        .ok()
        .and_then(|value| value.as_str().map(ToOwned::to_owned))
        .unwrap_or_else(|| "unknown".to_owned())
}

fn surface_hash(tools: &[SurfaceToolSnapshot]) -> Result<String, String> {
    let bytes = serde_json::to_vec(tools).map_err(|error| error.to_string())?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}

fn relevance_terms(value: &str) -> BTreeSet<String> {
    value
        .split(|character: char| !character.is_ascii_alphanumeric())
        .map(str::to_ascii_lowercase)
        .filter(|term| term.len() > 2)
        .collect()
}

fn is_provider_primitive(function: &FunctionDefinition) -> bool {
    metadata_bool(function, "modelPrimitive").unwrap_or(false)
}

fn model_tool_name(function: &FunctionDefinition) -> Option<String> {
    function
        .metadata
        .get("modelPrimitiveName")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
}

fn metadata_bool(function: &FunctionDefinition, key: &str) -> Option<bool> {
    function.metadata.get(key).and_then(Value::as_bool)
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn surface_hash_is_stable_and_contract_sensitive() {
        let tool = SurfaceToolSnapshot {
            model_name: "worker_demo".to_owned(),
            function_id: "worker::demo".to_owned(),
            function_revision: 1,
            owner_worker: "demo".to_owned(),
            description: "Demo worker".to_owned(),
            input_schema: serde_json::json!({"type":"object"}),
            output_schema: Some(serde_json::json!({"type":"object"})),
            effect_class: "PureRead".to_owned(),
            risk: "low".to_owned(),
            health: "Healthy".to_owned(),
            exposed: true,
            worker_id: Some("demo".to_owned()),
            worker_version: Some("abc".to_owned()),
            primitive_group: None,
            selection_reason: "relevance".to_owned(),
        };
        let first = surface_hash(std::slice::from_ref(&tool)).expect("hash");
        let second = surface_hash(std::slice::from_ref(&tool)).expect("hash");
        assert_eq!(first, second);

        let mut changed = tool;
        changed.function_revision = 2;
        assert_ne!(first, surface_hash(&[changed]).expect("changed hash"));
    }
}
