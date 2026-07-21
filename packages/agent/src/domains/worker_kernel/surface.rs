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
    ActorContext, ActorId, ActorKind, DirectWorkerToolContract, EngineHostHandle, EngineStateScope,
    FunctionDefinition, FunctionHealth,
};

const MAX_RELEVANT_WORKERS: usize = 12;
const MAX_STORED_SESSION_PROMOTIONS: usize = 50;
const SURFACE_FORMAT_VERSION: u32 = 1;

const PROMOTION_NAMESPACE: &str = "worker_kernel.surface_promotions";
const EVIDENCE_NAMESPACE: &str = "worker_kernel.surface_evidence";

/// Make one worker unconditionally available to the next provider turn in a
/// session.
pub(crate) async fn promote_worker_for_session(
    host: &EngineHostHandle,
    session_id: &str,
    worker_id: &str,
    worker_version: &str,
) -> Result<(), String> {
    let scope = EngineStateScope::Session(session_id.to_owned());
    host.write_engine_state(
        scope.clone(),
        PROMOTION_NAMESPACE,
        worker_id,
        serde_json::json!({"workerVersion":worker_version}),
    )
    .await
    .map_err(|error| error.to_string())?;

    let promotions = session_worker_promotion_entries(host, session_id).await?;
    for promotion in promotions.into_iter().skip(MAX_STORED_SESSION_PROMOTIONS) {
        host.delete_engine_state(scope.clone(), PROMOTION_NAMESPACE, &promotion.worker_id)
            .await
            .map_err(|error| error.to_string())?;
    }
    Ok(())
}

pub(super) async fn session_worker_promotions(
    host: &EngineHostHandle,
    session_id: &str,
) -> Result<BTreeSet<String>, String> {
    session_worker_promotion_entries(host, session_id)
        .await
        .map(|entries| entries.into_iter().map(|entry| entry.worker_id).collect())
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct SessionWorkerPromotion {
    worker_id: String,
    worker_version: Option<String>,
    updated_at: chrono::DateTime<chrono::Utc>,
}

async fn session_worker_promotion_entries(
    host: &EngineHostHandle,
    session_id: &str,
) -> Result<Vec<SessionWorkerPromotion>, String> {
    let mut entries = host
        .list_engine_state(
            EngineStateScope::Session(session_id.to_owned()),
            PROMOTION_NAMESPACE,
            None,
            500,
        )
        .await
        .map_err(|error| error.to_string())?
        .into_iter()
        .map(|entry| SessionWorkerPromotion {
            worker_id: entry.key,
            worker_version: entry
                .value
                .get("workerVersion")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            updated_at: entry.updated_at,
        })
        .collect::<Vec<_>>();
    entries.sort_by(|left, right| {
        right
            .updated_at
            .cmp(&left.updated_at)
            .then_with(|| left.worker_id.cmp(&right.worker_id))
    });
    Ok(entries)
}

/// Publish rebuildable operational evidence without changing the worker's
/// function contract revision. This keeps successful runs from invalidating a
/// model surface that is already in flight.
pub(super) async fn publish_worker_surface_evidence(
    host: &EngineHostHandle,
    worker_id: &str,
    evidence: Value,
) -> Result<(), String> {
    host.write_engine_state(
        EngineStateScope::System,
        EVIDENCE_NAMESPACE,
        worker_id,
        evidence,
    )
    .await
    .map(|_| ())
    .map_err(|error| error.to_string())
}

async fn worker_surface_evidence(
    host: &EngineHostHandle,
    functions: &[FunctionDefinition],
) -> Result<BTreeMap<String, Value>, String> {
    let mut evidence = BTreeMap::new();
    for worker_id in functions
        .iter()
        .filter_map(direct_worker_contract)
        .map(|worker| worker.worker_id.as_str())
    {
        if evidence.contains_key(worker_id) {
            continue;
        }
        if let Some(entry) = host
            .read_engine_state(EngineStateScope::System, EVIDENCE_NAMESPACE, worker_id)
            .await
            .map_err(|error| error.to_string())?
        {
            let _ = evidence.insert(worker_id.to_owned(), entry.value);
        }
    }
    Ok(evidence)
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
    pub(crate) model_callable: bool,
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
    relevance_query: Option<&str>,
) -> Result<ResolvedToolSurface, String> {
    let actor_id =
        ActorId::new(format!("agent:{session_id}")).map_err(|error| error.to_string())?;
    let actor = ActorContext::new(actor_id, ActorKind::Agent);
    let (catalog_revision, mut functions) = host.visible_functions_with_revision(&actor).await;
    functions.retain(|function| function.health == FunctionHealth::Healthy);
    functions.sort_by_key(|function| {
        (
            function
                .model_tool
                .as_ref()
                .and_then(|tool| tool.order)
                .unwrap_or(u16::MAX),
            function.id.as_str().to_owned(),
        )
    });

    let promotion_entries = session_worker_promotion_entries(host, session_id).await?;
    let evidence = worker_surface_evidence(host, &functions).await?;
    let dynamic_documents = functions
        .iter()
        .filter_map(|function| {
            let worker = direct_worker_contract(function)?;
            Some(retrieval_document(
                function,
                worker,
                evidence.get(&worker.worker_id),
            ))
        })
        .collect::<Vec<_>>();
    let available_worker_count = dynamic_documents.len();
    let applicable_promotions = promotion_entries
        .iter()
        .filter(|promotion| {
            functions.iter().any(|function| {
                direct_worker_contract(function).is_some_and(|worker| {
                    worker.worker_id == promotion.worker_id
                        && Some(worker.worker_version.as_str())
                            == promotion.worker_version.as_deref()
                })
            })
        })
        .map(|promotion| promotion.worker_id.clone())
        .collect::<BTreeSet<_>>();
    let ranked =
        super::retrieval::rank_workers(dynamic_documents, relevance_query, &applicable_promotions);
    let query_is_empty = super::retrieval::query_is_empty(relevance_query);
    let mut selected_dynamic = BTreeMap::new();
    for promotion in &promotion_entries {
        if selected_dynamic.len() >= MAX_RELEVANT_WORKERS {
            break;
        }
        let Some(rank) = ranked
            .iter()
            .find(|rank| rank.worker_id == promotion.worker_id && rank.promoted)
        else {
            continue;
        };
        let _ = selected_dynamic.insert(rank.key.clone(), "session_promotion");
    }
    for rank in &ranked {
        if selected_dynamic.contains_key(&rank.key)
            || (!query_is_empty && rank.relevance_score == 0)
            || selected_dynamic.len() >= MAX_RELEVANT_WORKERS
        {
            continue;
        }
        let reason = if rank.relevance_score > 0 {
            "relevance"
        } else {
            "default"
        };
        let _ = selected_dynamic.insert(rank.key.clone(), reason);
    }
    let available_workers = ranked
        .iter()
        .filter_map(|rank| {
            let function = functions
                .iter()
                .find(|function| function.id.as_str() == rank.key)?;
            let model_name = model_tool_name(function)?;
            let selection_reason = selected_dynamic
                .get(function.id.as_str())
                .map(|reason| (*reason).to_owned());
            Some(AvailableWorkerToolSnapshot {
                worker_id: rank.worker_id.clone(),
                model_name,
                function_id: function.id.as_str().to_owned(),
                function_revision: function.revision.0,
                worker_version: direct_worker_contract(function)
                    .map(|worker| worker.worker_version.clone()),
                promoted: rank.promoted,
                projected: selection_reason.is_some(),
                selection_reason,
                relevance_score: rank.relevance_score,
                completed_runs: rank.completed_runs,
                health: function.health.as_str().to_owned(),
            })
        })
        .collect::<Vec<_>>();
    let mut seen_names = BTreeSet::new();
    let mut resolved = Vec::new();
    let mut snapshot_tools = Vec::new();
    for function in functions {
        if !is_provider_primitive(&function) || function.request_schema.is_none() {
            continue;
        }
        let direct_worker = direct_worker_contract(&function).cloned();
        let is_dynamic = direct_worker.is_some();
        let selection_reason = if is_dynamic {
            let Some(reason) = selected_dynamic.get(function.id.as_str()) else {
                continue;
            };
            *reason
        } else {
            "fixed"
        };
        let Some(model_name) = model_tool_name(&function) else {
            continue;
        };
        let model_callable = function
            .model_tool
            .as_ref()
            .is_some_and(|tool| tool.callable);
        if !model_callable {
            continue;
        }
        if !seen_names.insert(model_name.clone()) {
            return Err(format!(
                "duplicate model tool name {model_name} in live catalog"
            ));
        }
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
            effect_class: function.effect_class.as_str().to_owned(),
            risk: function.risk_level.as_str().to_owned(),
            health: function.health.as_str().to_owned(),
            exposed: true,
            worker_id: direct_worker
                .as_ref()
                .map(|worker| worker.worker_id.clone()),
            worker_version: direct_worker
                .as_ref()
                .map(|worker| worker.worker_version.clone()),
            primitive_group: function
                .model_tool
                .as_ref()
                .and_then(|tool| tool.group.clone()),
            selection_reason: selection_reason.to_owned(),
        });
        resolved.push(ResolvedToolFunction {
            model_name,
            definition: function,
            model_callable,
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
            .inspect_function(&function_id, &inspector)
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
            effect_class: function.effect_class.as_str().to_owned(),
            risk: function.risk_level.as_str().to_owned(),
            health: function.health.as_str().to_owned(),
            exposed,
            worker_id: None,
            worker_version: None,
            primitive_group: Some(descriptor.group.as_str().to_owned()),
            selection_reason: "fixed".to_owned(),
        });
    }
    Ok(tools)
}

fn surface_hash(tools: &[SurfaceToolSnapshot]) -> Result<String, String> {
    let bytes = serde_json::to_vec(tools).map_err(|error| error.to_string())?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}

fn retrieval_document(
    function: &FunctionDefinition,
    worker: &DirectWorkerToolContract,
    evidence: Option<&Value>,
) -> super::retrieval::WorkerRetrievalDocument {
    super::retrieval::WorkerRetrievalDocument {
        key: function.id.as_str().to_owned(),
        worker_id: worker.worker_id.clone(),
        name: worker.worker_name.clone(),
        description: function.description.clone(),
        intents: worker.intents.clone(),
        examples: worker.examples.clone(),
        provenance: worker.provenance.clone(),
        completed_runs: evidence
            .and_then(|evidence| evidence.pointer("/successEvidence/completedRuns"))
            .and_then(Value::as_u64)
            .unwrap_or(0),
        updated_at: evidence
            .and_then(|evidence| evidence.get("updatedAt"))
            .and_then(Value::as_str)
            .unwrap_or(&worker.updated_at)
            .to_owned(),
    }
}

fn is_provider_primitive(function: &FunctionDefinition) -> bool {
    function.model_tool.is_some()
}

fn model_tool_name(function: &FunctionDefinition) -> Option<String> {
    function.model_tool.as_ref().map(|tool| tool.name.clone())
}

fn direct_worker_contract(function: &FunctionDefinition) -> Option<&DirectWorkerToolContract> {
    function.model_tool.as_ref()?.worker.as_ref()
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

    #[tokio::test]
    async fn session_promotion_storage_prunes_oldest_records() {
        let host = EngineHostHandle::new_in_memory().expect("host");
        for index in 0..55 {
            promote_worker_for_session(
                &host,
                "promotion-retention",
                &format!("worker-{index:02}"),
                "v1",
            )
            .await
            .expect("promotion");
        }

        let promotions = session_worker_promotions(&host, "promotion-retention")
            .await
            .expect("promotions");
        assert_eq!(promotions.len(), MAX_STORED_SESSION_PROMOTIONS);
        assert!(promotions.contains("worker-54"));
        assert!(!promotions.contains("worker-00"));
    }
}
