//! Engine introspection, semantic hooks, session title, and core proposals.

use std::collections::BTreeSet;

use serde_json::{Value, json};

use crate::engine::Invocation;

use super::super::types::WorkerEngineHook;
use super::Deps;
use super::support::{required_content, required_string};

pub(super) async fn session_set_title(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, String> {
    deps.runtime
        .set_session_title(
            title_target_session_id(invocation.causal_context.session_id.as_deref())?,
            required_string(&invocation.payload, "title")?,
        )
        .await
}

fn title_target_session_id(causal_session_id: Option<&str>) -> Result<String, String> {
    causal_session_id
        .map(str::trim)
        .filter(|session_id| !session_id.is_empty())
        .map(ToOwned::to_owned)
        .ok_or_else(|| "session_set_title requires a current causal session".to_owned())
}

pub(super) async fn core_proposal_create(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, String> {
    let test_command = invocation
        .payload
        .get("testCommand")
        .and_then(Value::as_array)
        .ok_or_else(|| "testCommand must be an array".to_owned())?
        .iter()
        .map(|value| {
            value
                .as_str()
                .map(ToOwned::to_owned)
                .ok_or_else(|| "testCommand entries must be strings".to_owned())
        })
        .collect::<Result<Vec<_>, _>>()?;
    serde_json::to_value(
        deps.runtime
            .create_core_proposal(
                required_string(&invocation.payload, "title")?,
                required_string(&invocation.payload, "intent")?,
                required_string(&invocation.payload, "repositoryPath")?,
                required_content(&invocation.payload, "patch")?,
                test_command,
            )
            .await?,
    )
    .map_err(|error| error.to_string())
}

pub(super) async fn engine_surface_snapshot(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, String> {
    deps.runtime
        .engine_surface_snapshot(
            invocation.causal_context.session_id.as_deref(),
            invocation
                .payload
                .get("relevanceQuery")
                .and_then(Value::as_str),
        )
        .await
}

pub(super) async fn context_summary(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime
        .invoke_engine_hook(
            WorkerEngineHook::ContextSummary,
            json!({"messages": invocation.payload["messages"].clone()}),
            invocation
                .payload
                .get("originWorkerId")
                .and_then(Value::as_str),
            invocation,
        )
        .await
}

pub(super) async fn session_title(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.apply_session_title_hook(invocation).await
}

pub(super) async fn worker_relevance(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, String> {
    let candidates = invocation
        .payload
        .get("candidates")
        .and_then(Value::as_array)
        .ok_or_else(|| "worker relevance candidates must be an array".to_owned())?;
    let candidate_ids = candidates
        .iter()
        .filter_map(|candidate| candidate.get("workerId").and_then(Value::as_str))
        .collect::<BTreeSet<_>>();
    let Some(execution) = deps
        .runtime
        .execute_engine_hook(
            WorkerEngineHook::WorkerRelevance,
            json!({
                "query":invocation.payload["query"].clone(),
                "candidates":candidates,
            }),
            invocation
                .payload
                .get("originWorkerId")
                .and_then(Value::as_str),
            invocation,
        )
        .await?
    else {
        return Ok(json!({"handled":false,"rankings":[]}));
    };
    let rankings = execution.output["rankings"]
        .as_array()
        .ok_or_else(|| "worker relevance hook returned no rankings array".to_owned())?;
    let mut seen = BTreeSet::new();
    for ranking in rankings {
        let worker_id = ranking["workerId"].as_str().unwrap_or_default();
        if !candidate_ids.contains(worker_id) || !seen.insert(worker_id) {
            let reason = deps
                .runtime
                .reject_engine_hook_output(
                    &execution,
                    WorkerEngineHook::WorkerRelevance,
                    "rankings must contain unique IDs from the supplied candidate set",
                )
                .await;
            return Err(reason);
        }
    }
    Ok(json!({
        "handled":true,
        "workerId":execution.worker_id,
        "workerVersion":execution.worker_version,
        "rankings":rankings,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_title_targets_the_causal_session_without_a_synthetic_current_id() {
        assert_eq!(
            title_target_session_id(Some("sess_current")).unwrap(),
            "sess_current"
        );
        assert!(
            title_target_session_id(None)
                .unwrap_err()
                .contains("requires a current causal session")
        );
    }
}

pub(super) async fn core_proposal_list(
    _invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, String> {
    Ok(json!({"proposals":deps.runtime.list_core_proposals()?}))
}

pub(super) async fn core_proposal_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, String> {
    serde_json::to_value(
        deps.runtime
            .inspect_core_proposal(&required_string(&invocation.payload, "proposalId")?)?,
    )
    .map_err(|error| error.to_string())
}

pub(super) async fn core_proposal_apply(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, String> {
    serde_json::to_value(
        deps.runtime
            .apply_core_proposal(
                &required_string(&invocation.payload, "proposalId")?,
                &required_string(&invocation.payload, "approvalSessionId")?,
                &required_string(&invocation.payload, "approvalMessageId")?,
            )
            .await?,
    )
    .map_err(|error| error.to_string())
}
