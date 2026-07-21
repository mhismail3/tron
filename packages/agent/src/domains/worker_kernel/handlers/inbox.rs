//! Durable worker results, run evidence, and adaptive inbox context.

use std::collections::BTreeSet;

use serde_json::{Value, json};

use crate::engine::Invocation;

use super::super::types::WorkerEngineHook;
use super::Deps;

pub(super) async fn inbox(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let limit = invocation
        .payload
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(100)
        .min(500) as u32;
    let worker_id = invocation.payload.get("workerId").and_then(Value::as_str);
    Ok(json!({"items":deps.runtime.store().inbox(worker_id, limit)?}))
}

pub(super) async fn inbox_attach(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let limit = invocation
        .payload
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(8)
        .min(32) as u32;
    let query = invocation
        .payload
        .get("relevanceQuery")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let candidates = deps.runtime.store().unseen_inbox_context_candidates(64)?;
    if candidates.is_empty() {
        return Ok(json!({"handled":false,"items":[],"narrative":""}));
    }
    let candidate_ids = candidates
        .iter()
        .filter_map(|candidate| candidate.get("inboxId").and_then(Value::as_str))
        .collect::<BTreeSet<_>>();
    let execution = deps
        .runtime
        .execute_engine_hook(
            WorkerEngineHook::InboxContext,
            json!({"query":query,"items":candidates}),
            invocation
                .payload
                .get("originWorkerId")
                .and_then(Value::as_str),
            invocation,
        )
        .await?;
    let Some(execution) = execution else {
        let items = deps
            .runtime
            .store()
            .take_notable_unseen(Some(query), limit)?;
        let narrative = deterministic_inbox_context(&items);
        return Ok(json!({"handled":false,"items":items,"narrative":narrative}));
    };
    let Some(consumed) = execution.output["consumedInboxIds"].as_array() else {
        let reason = deps
            .runtime
            .reject_engine_hook_output(
                &execution,
                WorkerEngineHook::InboxContext,
                "consumedInboxIds must be an array",
            )
            .await;
        return Err(reason);
    };
    let mut seen = BTreeSet::new();
    let mut consumed_ids = Vec::new();
    for inbox_id in consumed {
        let inbox_id = inbox_id.as_str().unwrap_or_default();
        if consumed_ids.len() >= limit as usize
            || !candidate_ids.contains(inbox_id)
            || !seen.insert(inbox_id)
        {
            let reason = deps
                .runtime
                .reject_engine_hook_output(
                    &execution,
                    WorkerEngineHook::InboxContext,
                    "consumedInboxIds must contain at most limit unique IDs from the supplied candidate set",
                )
                .await;
            return Err(reason);
        }
        consumed_ids.push(inbox_id.to_owned());
    }
    let Some(narrative) = execution.output["narrative"].as_str() else {
        let reason = deps
            .runtime
            .reject_engine_hook_output(
                &execution,
                WorkerEngineHook::InboxContext,
                "narrative must be a string",
            )
            .await;
        return Err(reason);
    };
    let narrative = narrative.trim().to_owned();
    let items = deps
        .runtime
        .store()
        .claim_unseen_inbox_context(&consumed_ids)?;
    let narrative = if consumed_ids.is_empty() || items.is_empty() {
        String::new()
    } else {
        narrative
    };
    Ok(json!({
        "handled":true,
        "workerId":execution.worker_id,
        "workerVersion":execution.worker_version,
        "items":items,
        "narrative":narrative,
    }))
}

fn deterministic_inbox_context(items: &[Value]) -> String {
    if items.is_empty() {
        return String::new();
    }
    let body = serde_json::to_string_pretty(items).unwrap_or_else(|_| "[]".to_owned());
    format!(
        "Persistent worker inbox updates (durable, previously unseen observations):\n{body}\nUse these results when relevant. Failures are evidence for deliberate improvement, rollback, disablement, or retirement."
    )
}

pub(super) async fn runs(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let worker_id = invocation.payload.get("workerId").and_then(Value::as_str);
    let limit = invocation
        .payload
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(100)
        .min(500) as u32;
    let runs = deps.runtime.store().runs(worker_id, limit)?;
    let mut attempts = serde_json::Map::new();
    let mut traces = serde_json::Map::new();
    for run in &runs {
        let _ = attempts.insert(
            run.invocation_id.clone(),
            Value::Array(deps.runtime.store().attempts(&run.invocation_id)?),
        );
        if !traces.contains_key(&run.trace_id)
            && let Some(trace) = deps.runtime.store().trace(&run.trace_id)?
        {
            let _ = traces.insert(run.trace_id.clone(), trace);
        }
    }
    Ok(json!({"runs":runs,"attempts":attempts,"traces":traces}))
}
