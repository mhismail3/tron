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
        if !active.bundle.exposes_model_tool() {
            continue;
        }
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
            completed_runs: evidence
                .get("completedRuns")
                .and_then(Value::as_u64)
                .unwrap_or(0),
            updated_at: worker.updated_at.clone(),
        });
        let _ = payloads.insert(worker.worker_id.clone(), (worker, active.bundle, evidence));
    }
    let include_unmatched = retrieval::query_is_empty(Some(&query));
    let ranking = retrieval::WorkerRankingOutcome::deterministic(
        retrieval::rank_workers(documents, Some(&query), &promoted),
        "deterministic_relevance",
    );
    let ranking_mechanism = ranking.mechanism.clone();
    let ranked = ranking
        .ranks
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
                "match":{
                    "score":rank.relevance_score,
                    "mechanism":ranking_mechanism.clone(),
                },
                "promoted":rank.promoted,
                "worker":worker,
                "inputSchema":bundle.effective_tool_input_schema(),
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
    let detail = invocation
        .payload
        .get("detail")
        .and_then(Value::as_str)
        .unwrap_or("contract");
    let inspection = deps
        .runtime
        .store()
        .inspect(&required_string(&invocation.payload, "workerId")?)?;
    project_inspection(inspection, detail)
}

fn project_inspection(mut inspection: Value, detail: &str) -> Result<Value, String> {
    let object = inspection
        .as_object_mut()
        .ok_or_else(|| "worker inspection must be an object".to_owned())?;
    match detail {
        "full" => {
            object.insert("detail".to_owned(), json!("full"));
        }
        "contract" => {
            let bundle = object
                .get_mut("bundle")
                .and_then(Value::as_object_mut)
                .ok_or_else(|| "worker inspection bundle must be an object".to_owned())?;
            bundle.retain(|key, _| {
                matches!(
                    key.as_str(),
                    "schemaVersion"
                        | "workerId"
                        | "name"
                        | "description"
                        | "toolName"
                        | "modelExposure"
                        | "toolInputSchema"
                        | "agentTools"
                        | "agentRole"
                        | "inputSchema"
                        | "outputSchema"
                        | "runner"
                        | "routing"
                        | "provenance"
                        | "presentation"
                        | "secretBindings"
                        | "engineHooks"
                        | "triggers"
                )
            });
            object.remove("healthHistory");
            object.remove("audit");
            object.insert("detail".to_owned(), json!("contract"));
        }
        _ => return Err("detail must be contract or full".to_owned()),
    }
    Ok(inspection)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn contract_inspection_excludes_source_and_operational_history() {
        let inspection = json!({
            "worker":{"workerId":"research"},
            "bundle":{
                "schemaVersion":"worker.bundle.v1",
                "workerId":"research",
                "modelExposure":"direct",
                "toolInputSchema":{"type":"object","required":["query"]},
                "agentTools":["web_fetch"],
                "inputSchema":{"type":"object"},
                "outputSchema":{"type":"object"},
                "runner":{"kind":"command"},
                "provenance":[],
                "files":[{"path":"large.py","content":"large source"}],
                "smokeTests":[{"command":["python3","test.py"]}],
                "healthChecks":[{"command":["python3","health.py"]}],
                "dependencies":[{"name":"large dependency"}]
            },
            "route":null,
            "versions":[],
            "triggers":[],
            "healthHistory":[{"details":"large output"}],
            "audit":[{"details":"large audit"}],
            "versionDirectory":"/workers/research/v1"
        });

        let projected = project_inspection(inspection.clone(), "contract").unwrap();
        assert_eq!(projected["detail"], "contract");
        assert!(projected.get("audit").is_none());
        assert!(projected.get("healthHistory").is_none());
        assert!(projected["bundle"].get("files").is_none());
        assert!(projected["bundle"].get("smokeTests").is_none());
        assert_eq!(
            projected["bundle"]["toolInputSchema"]["required"],
            json!(["query"])
        );
        assert_eq!(projected["bundle"]["modelExposure"], "direct");
        assert_eq!(projected["bundle"]["agentTools"], json!(["web_fetch"]));
        assert_eq!(projected["bundle"]["inputSchema"]["type"], "object");

        let full = project_inspection(inspection, "full").unwrap();
        assert_eq!(full["detail"], "full");
        assert!(full["audit"].is_array());
        assert!(full["healthHistory"].is_array());
        assert!(full["bundle"]["files"].is_array());
    }

    #[tokio::test]
    async fn model_facing_discovery_omits_internal_workers() {
        let home = tempfile::tempdir().unwrap();
        let (_context, runtime) =
            crate::shared::server::test_support::make_test_context_and_worker_runtime_at(
                home.path(),
                None,
            );
        for (worker_id, exposure) in [
            ("direct-discovery", "direct"),
            ("internal-hook", "internal"),
        ] {
            let mut bundle = json!({
                "schemaVersion":"tron.worker_bundle.v1",
                "workerId":worker_id,
                "name":worker_id,
                "description":format!("Discover {worker_id}"),
                "modelExposure":exposure,
                "inputSchema":{"type":"object"},
                "outputSchema":{"type":"object"},
                "runner":{"kind":"command","command":["python3","-c","print('{}')"]},
                "provenance":[{"source":"test:discovery"}]
            });
            if exposure == "direct" {
                bundle["toolInputSchema"] = json!({"type":"object"});
            }
            let bundle = serde_json::from_value(bundle).unwrap();
            runtime.upsert(bundle, None).await.unwrap();
        }
        let invocation = Invocation::new_sync(
            crate::engine::FunctionId::new("worker_kernel::discover").unwrap(),
            json!({"query":"discover"}),
            crate::engine::CausalContext::new(
                crate::engine::ActorId::new("agent:discovery-test").unwrap(),
                crate::engine::ActorKind::Agent,
                crate::engine::TraceId::new("trace-discovery-test").unwrap(),
            )
            .with_session_id("session-discovery-test"),
        );

        let result = discover(&invocation, &Deps { runtime }).await.unwrap();
        let workers = result["workers"].as_array().unwrap();
        assert!(
            workers
                .iter()
                .any(|worker| worker["worker"]["workerId"] == "direct-discovery")
        );
        assert!(
            workers
                .iter()
                .all(|worker| worker["worker"]["workerId"] != "internal-hook")
        );
    }
}
