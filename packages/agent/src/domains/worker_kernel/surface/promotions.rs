//! Session-scoped worker promotions and rebuildable worker success evidence.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;

use crate::engine::{EngineHostHandle, EngineStateScope, FunctionDefinition};

use super::filtering::direct_worker_contract;

pub(super) const MAX_STORED_SESSION_PROMOTIONS: usize = 50;
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

pub(in crate::domains::worker_kernel) async fn session_worker_promotions(
    host: &EngineHostHandle,
    session_id: &str,
) -> Result<BTreeSet<String>, String> {
    session_worker_promotion_entries(host, session_id)
        .await
        .map(|entries| entries.into_iter().map(|entry| entry.worker_id).collect())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct SessionWorkerPromotion {
    pub(super) worker_id: String,
    pub(super) worker_version: Option<String>,
    updated_at: chrono::DateTime<chrono::Utc>,
}

pub(super) async fn session_worker_promotion_entries(
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
pub(in crate::domains::worker_kernel) async fn publish_worker_surface_evidence(
    host: &EngineHostHandle,
    worker_id: &str,
    evidence: Value,
) -> Result<(), String> {
    host.write_engine_state(
        EngineStateScope::Profile,
        EVIDENCE_NAMESPACE,
        worker_id,
        evidence,
    )
    .await
    .map(|_| ())
    .map_err(|error| error.to_string())
}

pub(super) async fn worker_surface_evidence(
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
            .read_engine_state(EngineStateScope::Profile, EVIDENCE_NAMESPACE, worker_id)
            .await
            .map_err(|error| error.to_string())?
        {
            let _ = evidence.insert(worker_id.to_owned(), entry.value);
        }
    }
    Ok(evidence)
}
