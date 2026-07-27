//! Engine introspection and semantic policy hooks.

use std::collections::BTreeSet;

use serde_json::{Value, json};

use crate::engine::Invocation;

use super::super::types::WorkerEngineHook;
use super::Deps;
use super::support::required_string;

const CONTINUITY_CONTEXT_LIMIT: u64 = 6;
const CONTINUITY_CONTEXT_MAX_BYTES: usize = 12_000;

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
            invocation.payload.clone(),
            invocation
                .payload
                .get("originWorkerId")
                .and_then(Value::as_str),
            invocation,
        )
        .await
}

pub(super) async fn continuity_context(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, String> {
    let mut worker_input = json!({
        "action":"continuity_context",
        "query":required_string(&invocation.payload, "query")?,
        "limit":CONTINUITY_CONTEXT_LIMIT,
    });
    if let Some(project) = invocation.payload.get("project").and_then(Value::as_str) {
        worker_input["project"] = json!(project);
    }
    let Some(execution) = deps
        .runtime
        .execute_engine_hook(
            WorkerEngineHook::ContinuityContext,
            worker_input,
            invocation
                .payload
                .get("originWorkerId")
                .and_then(Value::as_str),
            invocation,
        )
        .await?
    else {
        return Ok(json!({"handled":false}));
    };
    let Some(narrative) = execution.output.get("narrative").and_then(Value::as_str) else {
        let reason = deps
            .runtime
            .reject_engine_hook_output(
                &execution,
                WorkerEngineHook::ContinuityContext,
                "output must contain a narrative string",
            )
            .await;
        return Err(reason);
    };
    let narrative =
        crate::shared::foundation::redaction::redact_sensitive_content(narrative.trim());
    if narrative.is_empty() {
        return Ok(json!({"handled":false}));
    }
    let narrative = crate::shared::foundation::text::truncate_with_suffix(
        &narrative,
        CONTINUITY_CONTEXT_MAX_BYTES,
        "…",
    );
    let sources = project_continuity_sources(execution.output.get("sources"));
    Ok(json!({
        "handled":true,
        "workerId":execution.worker_id,
        "workerVersion":execution.worker_version,
        "invocationId":execution.invocation_id,
        "narrative":narrative,
        "sources":sources,
    }))
}

fn project_continuity_sources(value: Option<&Value>) -> Vec<Value> {
    value
        .and_then(Value::as_array)
        .map(|sources| {
            sources
                .iter()
                .filter_map(|source| {
                    let memory_id = source.get("memoryId")?.as_str()?;
                    let revision = source.get("revision")?.as_u64()?;
                    let scope = source.get("scope")?.as_str()?;
                    matches!(scope, "global" | "project").then(|| {
                        let mut projected = json!({
                            "memoryId":crate::shared::foundation::redaction::redact_sensitive_content(memory_id),
                            "revision":revision,
                            "scope":scope,
                        });
                        if let Some(project) = source.get("project").and_then(Value::as_str) {
                            projected["project"] = json!(
                                crate::shared::foundation::redaction::redact_sensitive_content(project)
                            );
                        }
                        projected
                    })
                })
                .take(CONTINUITY_CONTEXT_LIMIT as usize)
                .collect()
        })
        .unwrap_or_default()
}

pub(super) async fn session_title(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    deps.runtime.enqueue_session_title_hook(invocation).await
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
    let query = invocation.payload.get("query").and_then(Value::as_str);
    if candidate_ids.len() <= 1 || super::super::retrieval::query_is_empty(query) {
        return Ok(json!({"handled":false,"rankings":[]}));
    }
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
        "invocationId":execution.invocation_id,
        "rankings":rankings,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn continuity_projection_redacts_and_bounds_sensitive_content() {
        let secret = format!("api_key={}", "a".repeat(64));
        let redacted = crate::shared::foundation::redaction::redact_sensitive_content(&secret);
        assert!(!redacted.contains(&"a".repeat(64)));
        let bounded = crate::shared::foundation::text::truncate_with_suffix(
            &"🦀".repeat(4_000),
            CONTINUITY_CONTEXT_MAX_BYTES,
            "…",
        );
        assert!(bounded.len() <= CONTINUITY_CONTEXT_MAX_BYTES);
        assert!(bounded.is_char_boundary(bounded.len()));
    }

    #[test]
    fn continuity_sources_are_bounded_validated_and_redacted() {
        let mut sources = vec![json!({
            "memoryId":format!("api_key={}", "a".repeat(64)),
            "revision":2,
            "scope":"project",
            "project":format!("api_key={}", "b".repeat(64)),
        })];
        sources.push(json!({
            "memoryId":"ignored-invalid-scope",
            "revision":1,
            "scope":"session",
        }));
        sources.extend((0..10).map(|index| {
            json!({
                "memoryId":format!("memory-{index}"),
                "revision":index + 1,
                "scope":"global",
            })
        }));

        let projected = project_continuity_sources(Some(&Value::Array(sources)));

        assert_eq!(projected.len(), CONTINUITY_CONTEXT_LIMIT as usize);
        assert!(
            !projected[0]["memoryId"]
                .as_str()
                .unwrap_or_default()
                .contains(&"a".repeat(64))
        );
        assert!(
            !projected[0]["project"]
                .as_str()
                .unwrap_or_default()
                .contains(&"b".repeat(64))
        );
        assert!(
            projected
                .iter()
                .all(|source| { matches!(source["scope"].as_str(), Some("global" | "project")) })
        );
    }
}
