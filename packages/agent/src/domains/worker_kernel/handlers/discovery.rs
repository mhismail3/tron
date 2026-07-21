//! Worker inventory, inspection, relevance ranking, and session promotion.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};

use crate::engine::Invocation;

use super::super::{retrieval, surface};
use super::Deps;
use super::support::required_string;

pub(super) async fn discover(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let query = required_string(&invocation.payload, "query")?;
    let limit = invocation
        .payload
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(12)
        .min(50) as usize;
    let promoted = match invocation.causal_context.session_id.as_deref() {
        Some(session_id) => {
            surface::session_worker_promotions(deps.runtime.host(), session_id).await?
        }
        None => BTreeSet::new(),
    };
    let mut payloads = BTreeMap::new();
    let mut documents = Vec::new();
    for worker in deps
        .runtime
        .store()
        .list(false)?
        .into_iter()
        .filter(|worker| worker.enabled)
    {
        let Ok(active) = deps.runtime.store().load_active(&worker.worker_id) else {
            continue;
        };
        let Ok(evidence) = deps.runtime.store().success_evidence(&worker.worker_id) else {
            continue;
        };
        documents.push(retrieval::WorkerRetrievalDocument {
            key: worker.worker_id.clone(),
            worker_id: worker.worker_id.clone(),
            name: worker.name.clone(),
            description: worker.description.clone(),
            intents: active.bundle.routing.intents.clone(),
            examples: active.bundle.routing.examples.clone(),
            provenance: active
                .bundle
                .provenance
                .iter()
                .map(|source| {
                    source.revision.as_ref().map_or_else(
                        || source.source.clone(),
                        |revision| format!("{}@{revision}", source.source),
                    )
                })
                .collect(),
            completed_runs: evidence
                .get("completedRuns")
                .and_then(Value::as_u64)
                .unwrap_or(0),
            updated_at: worker.updated_at.clone(),
        });
        let _ = payloads.insert(worker.worker_id.clone(), (worker, active.bundle, evidence));
    }
    let include_unmatched = retrieval::query_is_empty(Some(&query));
    let origin_worker_id = (invocation.causal_context.actor_kind
        == crate::engine::ActorKind::Worker)
        .then(|| {
            invocation
                .causal_context
                .actor_id
                .as_str()
                .strip_prefix("worker:")
        })
        .flatten();
    let ranked = retrieval::rank_workers_with_hook(
        deps.runtime.host(),
        invocation
            .causal_context
            .session_id
            .as_deref()
            .unwrap_or("worker-discover"),
        origin_worker_id,
        documents,
        Some(&query),
        &promoted,
    )
    .await
    .into_iter()
    .filter(|rank| include_unmatched || rank.relevance_score > 0)
    .take(limit)
    .collect::<Vec<_>>();
    if let Some(session_id) = invocation.causal_context.session_id.as_deref() {
        for rank in &ranked {
            let Some((worker, _, _)) = payloads.get(&rank.worker_id) else {
                continue;
            };
            surface::promote_worker_for_session(
                deps.runtime.host(),
                session_id,
                &rank.worker_id,
                &worker.active_version,
            )
            .await?;
        }
    }
    Ok(json!({
        "query": query,
        "workers": ranked.into_iter().filter_map(|rank| {
            let (worker, bundle, evidence) = payloads.remove(&rank.worker_id)?;
            Some(json!({
                "score":rank.relevance_score,
                "promoted":rank.promoted,
                "worker":worker,
                "inputSchema":bundle.input_schema,
                "outputSchema":bundle.output_schema,
                "routing":bundle.routing,
                "provenance":bundle.provenance,
                "successEvidence":evidence,
            }))
        }).collect::<Vec<_>>()
    }))
}
pub(super) async fn list(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let include_retired = invocation
        .payload
        .get("includeRetired")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    Ok(json!({
        "workers": deps.runtime.store().list(include_retired)?,
        "stopAll": deps.runtime.store().stop_all()?,
    }))
}

pub(super) async fn inspect(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime
        .store()
        .inspect(&required_string(&invocation.payload, "workerId")?)
}
