use super::*;

fn context_summary_bundle(worker_id: &str, narrative: &str) -> WorkerBundle {
    let mut bundle = command_bundle(vec![
        "sh".to_owned(),
        "-c".to_owned(),
        format!(
            "printf '%s' '{}'",
            serde_json::to_string(&json!({"narrative":narrative})).unwrap()
        ),
    ]);
    bundle.worker_id = Some(worker_id.to_owned());
    bundle.tool_name = Some(format!("worker_{worker_id}"));
    bundle.name = format!("Context summary {worker_id}");
    bundle.description = format!("Summarizes context through {worker_id}");
    bundle.input_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["messages"],
        "properties":{
            "originWorkerId":{"type":"string"},
            "messages":{
                "type":"array",
                "maxItems":256,
                "items":{
                    "type":"object",
                    "additionalProperties":false,
                    "required":["role","text"],
                    "properties":{
                        "role":{"type":"string","enum":["user","assistant","tool"]},
                        "text":{"type":"string","maxLength":4096}
                    }
                }
            }
        }
    });
    bundle.output_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["narrative"],
        "properties":{"narrative":{"type":"string","minLength":1,"maxLength":40000}}
    });
    bundle.engine_hooks = vec![WorkerEngineHook::ContextSummary];
    bundle
}

fn continuity_context_bundle(worker_id: &str, narrative: &str) -> WorkerBundle {
    let mut bundle = command_bundle(vec![
        "sh".to_owned(),
        "-c".to_owned(),
        format!(
            "printf '%s' '{}'",
            serde_json::to_string(&json!({"narrative":narrative})).unwrap()
        ),
    ]);
    bundle.worker_id = Some(worker_id.to_owned());
    bundle.tool_name = Some(format!("worker_{worker_id}"));
    bundle.name = format!("Continuity context {worker_id}");
    bundle.description = format!("Recalls bounded continuity through {worker_id}");
    bundle.input_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["action","query"],
        "properties":{
            "action":{"const":"continuity_context"},
            "query":{"type":"string","minLength":1,"maxLength":12000},
            "project":{"type":"string","minLength":1,"maxLength":2048},
            "limit":{"type":"integer","minimum":1,"maximum":8}
        }
    });
    bundle.output_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["narrative"],
        "properties":{"narrative":{"type":"string","maxLength":6000}}
    });
    bundle.engine_hooks = vec![WorkerEngineHook::ContinuityContext];
    bundle
}

fn hook_invocation(actor_id: &str, actor_kind: ActorKind, key: &str) -> Invocation {
    Invocation::new_sync(
        FunctionId::new(super::super::super::CONTEXT_SUMMARY_FUNCTION).unwrap(),
        json!({"messages":[{"role":"user","text":"Preserve this task."}]}),
        CausalContext::new(
            ActorId::new(actor_id).unwrap(),
            actor_kind,
            TraceId::new(format!("trace-{key}")).unwrap(),
        )
        .with_session_id("hook-test")
        .with_idempotency_key(key),
    )
}

#[tokio::test]
async fn atomic_upsert_activates_continuity_context_without_a_binding_step() {
    let (runtime, _home) = test_runtime(None);
    let outcome = runtime
        .upsert(
            continuity_context_bundle("continuity-one", "worker-owned memory"),
            None,
        )
        .await
        .unwrap();
    let execution = runtime
        .execute_engine_hook(
            WorkerEngineHook::ContinuityContext,
            json!({
                "action":"continuity_context",
                "query":"release acceptance",
                "project":"/workspace/example",
                "limit":6
            }),
            None,
            &Invocation::new_sync(
                FunctionId::new(super::super::super::CONTINUITY_CONTEXT_FUNCTION).unwrap(),
                json!({"query":"release acceptance"}),
                CausalContext::new(
                    ActorId::new("agent:continuity-test").unwrap(),
                    ActorKind::Agent,
                    TraceId::new("trace-continuity-hook").unwrap(),
                )
                .with_session_id("continuity-hook-test")
                .with_idempotency_key("continuity-hook"),
            ),
        )
        .await
        .unwrap()
        .expect("continuity execution");

    assert_eq!(execution.worker_id, outcome.worker.worker_id);
    assert_eq!(execution.output["narrative"], "worker-owned memory");
    assert_eq!(
        runtime.engine_hook_inventory().unwrap(),
        vec![json!({
            "hook":"continuity_context",
            "workerId":outcome.worker.worker_id,
            "workerVersion":outcome.worker.active_version,
        })]
    );
}

#[tokio::test]
async fn continuity_schema_must_admit_the_full_engine_query_boundary() {
    let (runtime, _home) = test_runtime(None);
    let mut bundle = continuity_context_bundle("continuity-short-query", "valid");
    bundle.input_schema["properties"]["query"]["maxLength"] = json!(4_000);

    let error = runtime.upsert(bundle, None).await.unwrap_err();

    assert!(
        error.contains("engine hook 'continuity_context' input"),
        "{error}"
    );
    assert!(runtime.store().list(true).unwrap().is_empty());
}

#[tokio::test]
async fn continuity_request_failure_does_not_disable_its_worker() {
    let (runtime, _home) = test_runtime(None);
    let mut bundle = continuity_context_bundle("continuity-request-failure", "unused");
    bundle.runner = WorkerRunner::Command {
        command: vec![
            "sh".to_owned(),
            "-c".to_owned(),
            "printf 'request-specific failure' >&2; exit 1".to_owned(),
        ],
    };
    let outcome = runtime.upsert(bundle, None).await.unwrap();

    let error = match runtime
        .execute_engine_hook(
            WorkerEngineHook::ContinuityContext,
            json!({
                "action":"continuity_context",
                "query":"release acceptance",
                "project":"/workspace/example",
                "limit":6
            }),
            None,
            &Invocation::new_sync(
                FunctionId::new(super::super::super::CONTINUITY_CONTEXT_FUNCTION).unwrap(),
                json!({"query":"release acceptance"}),
                CausalContext::new(
                    ActorId::new("agent:continuity-failure-test").unwrap(),
                    ActorKind::Agent,
                    TraceId::new("trace-continuity-failure").unwrap(),
                )
                .with_session_id("continuity-failure-test")
                .with_idempotency_key("continuity-failure"),
            ),
        )
        .await
    {
        Ok(_) => panic!("request-specific Continuity failure must fail its invocation"),
        Err(error) => error,
    };

    assert!(error.contains("request-specific failure"), "{error}");
    let summary = runtime
        .store()
        .list(true)
        .unwrap()
        .into_iter()
        .find(|summary| summary.worker_id == outcome.worker.worker_id)
        .expect("continuity worker");
    assert!(summary.enabled);
    assert_eq!(summary.health, "healthy");
}

#[tokio::test]
async fn continuity_schema_must_reject_unbounded_narrative_before_activation() {
    let (runtime, _home) = test_runtime(None);
    let mut bundle = continuity_context_bundle("continuity-unbounded", "valid");
    bundle.output_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["narrative"],
        "properties":{"narrative":{"type":"string"}}
    });

    let error = runtime.upsert(bundle, None).await.unwrap_err();

    assert!(
        error.contains("engine hook 'continuity_context' output"),
        "{error}"
    );
    assert!(runtime.store().list(true).unwrap().is_empty());
}

#[tokio::test]
async fn atomic_upsert_activates_context_summary_hook_without_a_binding_step() {
    let (runtime, _home) = test_runtime(None);
    let outcome = runtime
        .upsert(
            context_summary_bundle("context-summary-one", "worker-owned summary"),
            None,
        )
        .await
        .unwrap();

    let result = runtime
        .invoke_engine_hook(
            WorkerEngineHook::ContextSummary,
            json!({"messages":[{"role":"user","text":"Preserve this task."}]}),
            None,
            &hook_invocation("agent:hook-test", ActorKind::Agent, "hook-one"),
        )
        .await
        .unwrap();

    assert_eq!(result["handled"], true);
    assert_eq!(result["workerId"], outcome.worker.worker_id);
    assert_eq!(result["narrative"], "worker-owned summary");
    assert_eq!(
        runtime.engine_hook_inventory().unwrap(),
        vec![json!({
            "hook":"context_summary",
            "workerId":outcome.worker.worker_id,
            "workerVersion":outcome.worker.active_version,
        })]
    );
}

#[tokio::test]
async fn context_summary_without_an_owner_uses_the_recovery_path() {
    let (runtime, _home) = test_runtime(None);

    let result = runtime
        .invoke_engine_hook(
            WorkerEngineHook::ContextSummary,
            json!({"messages":[{"role":"user","text":"Preserve this task."}]}),
            None,
            &hook_invocation("agent:hook-test", ActorKind::Agent, "hook-absent"),
        )
        .await
        .unwrap();

    assert_eq!(result, json!({"handled":false}));
}

#[tokio::test]
async fn context_summary_accepts_the_exact_estimated_token_and_byte_ceiling() {
    let (runtime, _home) = test_runtime(None);
    let narrative = "x".repeat(super::super::super::CONTEXT_SUMMARY_MAX_NARRATIVE_BYTES);
    runtime
        .upsert(
            context_summary_bundle("context-summary-exact-limit", &narrative),
            None,
        )
        .await
        .unwrap();

    let result = runtime
        .invoke_engine_hook(
            WorkerEngineHook::ContextSummary,
            json!({"messages":[{"role":"user","text":"Preserve this task."}]}),
            None,
            &hook_invocation("agent:hook-test", ActorKind::Agent, "hook-exact-limit"),
        )
        .await
        .unwrap();

    assert_eq!(
        result["narrative"].as_str().unwrap().len(),
        super::super::super::CONTEXT_SUMMARY_MAX_NARRATIVE_BYTES
    );
}

#[tokio::test]
async fn context_summary_rejects_output_above_the_estimated_token_and_byte_ceiling() {
    let (runtime, _home) = test_runtime(None);
    let narrative = "é"
        .repeat(super::super::super::CONTEXT_SUMMARY_MAX_NARRATIVE_BYTES.div_ceil("é".len()) + 1);
    let outcome = runtime
        .upsert(
            context_summary_bundle("context-summary-multibyte-overflow", &narrative),
            None,
        )
        .await
        .unwrap();

    let error = runtime
        .invoke_engine_hook(
            WorkerEngineHook::ContextSummary,
            json!({"messages":[{"role":"user","text":"Preserve this task."}]}),
            None,
            &hook_invocation(
                "agent:hook-test",
                ActorKind::Agent,
                "hook-multibyte-overflow",
            ),
        )
        .await
        .unwrap_err();

    assert!(error.contains("estimated at 10001 tokens"), "{error}");
    let worker = runtime
        .store()
        .summary(&outcome.worker.worker_id)
        .unwrap()
        .unwrap();
    assert!(!worker.enabled);
    assert_eq!(worker.health, "failed");
}

#[tokio::test]
async fn context_summary_rejects_empty_output_and_disables_the_owner() {
    let (runtime, _home) = test_runtime(None);
    let outcome = runtime
        .upsert(context_summary_bundle("context-summary-empty", ""), None)
        .await
        .unwrap();

    let error = runtime
        .invoke_engine_hook(
            WorkerEngineHook::ContextSummary,
            json!({"messages":[{"role":"user","text":"Preserve this task."}]}),
            None,
            &hook_invocation("agent:hook-test", ActorKind::Agent, "hook-empty"),
        )
        .await
        .unwrap_err();

    assert!(error.contains("does not match its schema"), "{error}");
    let worker = runtime
        .store()
        .summary(&outcome.worker.worker_id)
        .unwrap()
        .unwrap();
    assert!(!worker.enabled);
    assert_eq!(worker.health, "failed");
}

#[tokio::test(start_paused = true)]
async fn context_summary_timeout_cancels_the_run_and_disables_the_owner() {
    let (runtime, _home) = test_runtime(None);
    let mut bundle = context_summary_bundle("context-summary-timeout", "unused");
    bundle.runner = WorkerRunner::Command {
        command: vec!["sh".to_owned(), "-c".to_owned(), "sleep 120".to_owned()],
    };
    let outcome = runtime.upsert(bundle, None).await.unwrap();

    let error = runtime
        .invoke_engine_hook(
            WorkerEngineHook::ContextSummary,
            json!({"messages":[{"role":"user","text":"Preserve this task."}]}),
            None,
            &hook_invocation("agent:hook-test", ActorKind::Agent, "hook-timeout"),
        )
        .await
        .unwrap_err();

    assert!(error.contains("60-second policy ceiling"), "{error}");
    let worker = runtime
        .store()
        .summary(&outcome.worker.worker_id)
        .unwrap()
        .unwrap();
    assert!(!worker.enabled);
    assert_eq!(worker.health, "failed");
    let run = runtime
        .store()
        .runs_filtered(Some(&outcome.worker.worker_id), None, 1)
        .unwrap()
        .pop()
        .expect("timed-out hook run");
    assert_eq!(run.status, "cancelled");
}

#[tokio::test(start_paused = true)]
async fn worker_declared_invocation_ceiling_bounds_hook_runner_and_disables_it() {
    let (runtime, _home) = test_runtime(None);
    let mut bundle = context_summary_bundle("context-summary-bounded", "unused");
    bundle.execution_limits.max_invocation_seconds = Some(3);
    bundle.runner = WorkerRunner::Command {
        command: vec!["sh".to_owned(), "-c".to_owned(), "sleep 120".to_owned()],
    };
    let outcome = runtime.upsert(bundle, None).await.unwrap();

    let error = runtime
        .invoke_engine_hook(
            WorkerEngineHook::ContextSummary,
            json!({"messages":[{"role":"user","text":"Preserve this task."}]}),
            None,
            &hook_invocation("agent:hook-test", ActorKind::Agent, "hook-bounded"),
        )
        .await
        .unwrap_err();

    assert!(error.contains("exceeded 3 seconds"), "{error}");
    let worker = runtime
        .store()
        .summary(&outcome.worker.worker_id)
        .unwrap()
        .unwrap();
    assert!(!worker.enabled);
    assert_eq!(worker.health, "failed");
}

#[tokio::test]
async fn hook_owner_does_not_recursively_invoke_itself() {
    let (runtime, _home) = test_runtime(None);
    let outcome = runtime
        .upsert(
            context_summary_bundle("context-summary-self", "must not recurse"),
            None,
        )
        .await
        .unwrap();

    let result = runtime
        .invoke_engine_hook(
            WorkerEngineHook::ContextSummary,
            json!({"messages":[{"role":"user","text":"Worker child context."}]}),
            Some(&outcome.worker.worker_id),
            &hook_invocation(
                &format!("worker:{}", outcome.worker.worker_id),
                ActorKind::Worker,
                "hook-self",
            ),
        )
        .await
        .unwrap();

    assert_eq!(result, json!({"handled":false}));
    assert!(
        runtime
            .store()
            .runs_filtered(None, None, 10)
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn context_summary_accepts_a_different_worker_as_the_origin() {
    let (runtime, _home) = test_runtime(None);
    runtime
        .upsert(
            context_summary_bundle("context-summary-owner", "worker child summary"),
            None,
        )
        .await
        .unwrap();

    let result = runtime
        .invoke_engine_hook(
            WorkerEngineHook::ContextSummary,
            json!({
                "originWorkerId":"different-worker",
                "messages":[{"role":"user","text":"Worker child context."}]
            }),
            Some("different-worker"),
            &hook_invocation(
                "worker:different-worker",
                ActorKind::Worker,
                "hook-other-worker",
            ),
        )
        .await
        .unwrap();

    assert_eq!(result["handled"], true);
    assert_eq!(result["narrative"], "worker child summary");
}

#[tokio::test]
async fn incompatible_context_summary_schema_is_rejected_before_activation() {
    let (runtime, _home) = test_runtime(None);
    let mut bundle = context_summary_bundle("context-summary-invalid", "invalid");
    bundle.input_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["unrelated"],
        "properties":{"unrelated":{"type":"string"}}
    });

    let error = runtime.upsert(bundle, None).await.unwrap_err();

    assert!(error.contains("engine hook 'context_summary' input"));
    assert!(runtime.store().list(true).unwrap().is_empty());
}

#[tokio::test]
async fn context_summary_schema_must_reject_character_overflow_before_activation() {
    let (runtime, _home) = test_runtime(None);
    let mut bundle = context_summary_bundle("context-summary-unbounded-output", "valid at runtime");
    bundle.output_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["narrative"],
        "properties":{"narrative":{"type":"string","minLength":1}}
    });

    let error = runtime.upsert(bundle, None).await.unwrap_err();

    assert!(
        error.contains("engine hook 'context_summary' output"),
        "{error}"
    );
    assert!(runtime.store().list(true).unwrap().is_empty());
}

#[tokio::test]
async fn failed_current_hook_does_not_silently_reactivate_an_older_owner() {
    let (runtime, _home) = test_runtime(None);
    let older = runtime
        .upsert(
            context_summary_bundle("historical-condensation", "older summary"),
            None,
        )
        .await
        .unwrap();
    let mut current = context_summary_bundle("current-narrative", "unused");
    current.name = "Current narrative policy".to_owned();
    current.description = "Owns current semantic lifecycle condensation".to_owned();
    current.runner = WorkerRunner::Command {
        command: vec!["sh".to_owned(), "-c".to_owned(), "exit 9".to_owned()],
    };
    let current = runtime.upsert(current, None).await.unwrap();
    assert_ne!(older.worker.worker_id, current.worker.worker_id);

    let error = runtime
        .invoke_engine_hook(
            WorkerEngineHook::ContextSummary,
            json!({"messages":[{"role":"user","text":"Do not roll back."}]}),
            None,
            &hook_invocation("agent:hook-test", ActorKind::Agent, "hook-failure"),
        )
        .await
        .unwrap_err();

    assert!(error.contains("worker command exited"));
    assert!(runtime.engine_hook_inventory().unwrap().is_empty());
    assert_eq!(
        runtime
            .store()
            .summary(&older.worker.worker_id)
            .unwrap()
            .unwrap()
            .enabled,
        true
    );
    assert_eq!(
        runtime
            .store()
            .summary(&current.worker.worker_id)
            .unwrap()
            .unwrap()
            .enabled,
        false
    );
}

#[tokio::test]
async fn worker_result_and_run_history_surfaces_remain_available() {
    let context = crate::shared::server::test_support::make_test_context();
    let actor = || {
        CausalContext::new(
            ActorId::new("agent:inbox-hook-test").unwrap(),
            ActorKind::Agent,
            TraceId::generate(),
        )
        .with_session_id("inbox-hook-test")
    };
    let source_bundle = json!({
        "schemaVersion":"tron.worker_bundle.v1",
        "workerId":"background-report",
        "name":"Background Report",
        "description":"Produces a durable background report",
        "modelExposure":"internal",
        "inputSchema":{"type":"object","additionalProperties":false},
        "outputSchema":{
            "type":"object","additionalProperties":false,"required":["report"],
            "properties":{"report":{"type":"string"}}
        },
        "runner":{"kind":"command","command":["printf","{\"report\":\"ready\"}"]},
        "provenance":[{"source":"test:inbox-source"}]
    });
    let source = context
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::upsert").unwrap(),
            json!({"bundle":source_bundle}),
            actor().with_idempotency_key("upsert-inbox-source"),
        ))
        .await;
    assert_eq!(source.error, None);
    let invoked = context
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::invoke").unwrap(),
            json!({
                "workerId":"background-report",
                "input":{},
                "mode":"wait",
                "idempotencyKey":"background-report-run"
            }),
            actor().with_idempotency_key("invoke-inbox-source"),
        ))
        .await;
    assert_eq!(invoked.error, None);
    let source_invocation_id = invoked.value.as_ref().unwrap()["invocationId"]
        .as_str()
        .unwrap()
        .to_owned();
    let inbox = context
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::inbox").unwrap(),
            json!({"workerId":"background-report","limit":10}),
            actor().with_idempotency_key("read-inbox-source"),
        ))
        .await;
    assert_eq!(inbox.error, None);
    assert_eq!(inbox.value.as_ref().unwrap()["detail"], "summary");
    assert_eq!(
        inbox.value.as_ref().unwrap()["items"][0]["result"]["status"],
        "completed"
    );
    assert_eq!(
        inbox.value.as_ref().unwrap()["items"][0]["result"]["reference"]["kind"],
        "worker_result_reference"
    );
    let _inbox_id = inbox.value.unwrap()["items"][0]["inboxId"]
        .as_str()
        .unwrap()
        .to_owned();
    let full_inbox = context
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::inbox").unwrap(),
            json!({"workerId":"background-report","limit":20,"detail":"full"}),
            actor().with_idempotency_key("read-full-inbox-source"),
        ))
        .await;
    assert_eq!(full_inbox.error, None);
    let full_inbox = full_inbox.value.unwrap();
    assert_eq!(full_inbox["detail"], "full");
    assert_eq!(
        full_inbox["items"][0]["result"]["reference"]["kind"],
        "worker_result_reference"
    );
    assert!(full_inbox["items"][0]["result"].get("output").is_none());
    assert_eq!(full_inbox["returned"], 1);
    assert_eq!(full_inbox["truncated"], false);
    assert_eq!(full_inbox["contentTruncated"], false);

    let summary_runs = context
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::runs").unwrap(),
            json!({"workerId":"background-report"}),
            actor().with_idempotency_key("read-summary-runs-source"),
        ))
        .await;
    assert_eq!(summary_runs.error, None);
    let summary_runs = summary_runs.value.unwrap();
    assert_eq!(summary_runs["detail"], "summary");
    assert!(summary_runs["runs"][0]["input"]["preview"].is_string());
    assert_eq!(summary_runs["attempts"], json!({}));
    assert_eq!(summary_runs["traces"], json!({}));

    let full_runs = context
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::runs").unwrap(),
            json!({"workerId":"background-report","detail":"full"}),
            actor().with_idempotency_key("read-full-runs-source"),
        ))
        .await;
    assert_eq!(full_runs.error, None);
    let full_runs = full_runs.value.unwrap();
    assert_eq!(full_runs["runs"][0]["input"], json!({}));
    assert_eq!(
        full_runs["runs"][0]["output"]["kind"],
        "worker_result_reference"
    );
    assert!(full_runs["runs"][0]["output"].get("report").is_none());
    assert!(full_runs["attempts"].as_object().unwrap().len() == 1);
    assert!(full_runs["traces"].as_object().unwrap().len() == 1);

    let graph_runs = context
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::runs").unwrap(),
            json!({"invocationId":source_invocation_id,"detail":"graph"}),
            actor().with_idempotency_key("read-graph-runs-source"),
        ))
        .await;
    assert_eq!(graph_runs.error, None);
    let graph_runs = graph_runs.value.unwrap();
    assert_eq!(graph_runs["detail"], "graph");
    assert_eq!(graph_runs["graphs"].as_array().unwrap().len(), 1);
    let graph = &graph_runs["graphs"][0];
    assert_eq!(graph["requestedInvocationId"], source_invocation_id);
    assert_eq!(graph["stage"], "completed");
    assert_eq!(graph["status"], "completed");
    assert_eq!(graph["counts"]["completed"], 1);
    assert!(
        graph["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|node| node["kind"] == "attempt")
    );
    assert!(graph["timeline"].as_array().unwrap().iter().all(|entry| {
        !entry["summary"]
            .as_str()
            .unwrap()
            .contains("StartedFinished")
    }));

    let metric_runs = context
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::runs").unwrap(),
            json!({"invocationId":source_invocation_id,"detail":"metrics"}),
            actor().with_idempotency_key("read-metric-runs-source"),
        ))
        .await;
    assert_eq!(metric_runs.error, None);
    let metric_runs = metric_runs.value.unwrap();
    assert_eq!(metric_runs["detail"], "metrics");
    assert_eq!(metric_runs["graphs"], json!([]));
    assert_eq!(metric_runs["metrics"].as_array().unwrap().len(), 1);
    let metrics = &metric_runs["metrics"][0];
    assert_eq!(metrics["invocationId"], source_invocation_id);
    assert_eq!(metrics["workerId"], "background-report");
    assert_eq!(metrics["status"], "completed");
    assert!(metrics["timing"]["wallMs"].is_u64());
    assert!(metrics["usage"]["cost"].is_number());
    assert_eq!(metrics["usage"]["includesDescendants"], true);

    let graph_with_materialized_empty_filters = context
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::runs").unwrap(),
            json!({
                "workerId":"",
                "originSessionId":"",
                "invocationId":source_invocation_id,
                "modelToolInvocationId":"",
                "status":"completed",
                "limit":1,
                "offset":0,
                "detail":"graph"
            }),
            actor().with_idempotency_key("read-graph-runs-empty-filters"),
        ))
        .await;
    assert_eq!(graph_with_materialized_empty_filters.error, None);
    let graph_with_materialized_empty_filters =
        graph_with_materialized_empty_filters.value.unwrap();
    assert_eq!(
        graph_with_materialized_empty_filters["graphs"]
            .as_array()
            .unwrap()
            .len(),
        1
    );

    let filtered_runs = context
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::runs").unwrap(),
            json!({"status":"failed"}),
            actor().with_idempotency_key("read-failed-runs-source"),
        ))
        .await;
    assert_eq!(filtered_runs.error, None);
    assert!(
        filtered_runs.value.unwrap()["runs"]
            .as_array()
            .unwrap()
            .is_empty()
    );

    let filtered_inbox = context
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::inbox").unwrap(),
            json!({"contextAttached":false,"severity":"error"}),
            actor().with_idempotency_key("read-pending-error-inbox-source"),
        ))
        .await;
    assert_eq!(filtered_inbox.error, None);
    assert!(
        filtered_inbox.value.unwrap()["items"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn worker_run_and_inbox_history_pages_remain_fully_auditable() {
    let context = crate::shared::server::test_support::make_test_context();
    let actor = || {
        CausalContext::new(
            ActorId::new("agent:history-page-test").unwrap(),
            ActorKind::Agent,
            TraceId::generate(),
        )
        .with_session_id("history-page-test")
    };
    let bundle = json!({
        "schemaVersion":"tron.worker_bundle.v1",
        "workerId":"history-page-worker",
        "name":"History Page Worker",
        "description":"Produces deterministic audit records",
        "modelExposure":"internal",
        "inputSchema":{"type":"object","additionalProperties":false},
        "outputSchema":{
            "type":"object","additionalProperties":false,"required":["ok"],
            "properties":{"ok":{"type":"boolean"}}
        },
        "runner":{"kind":"command","command":["printf","{\"ok\":true}"]},
        "provenance":[{"source":"test:history-pages"}]
    });
    let upsert = context
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::upsert").unwrap(),
            json!({"bundle":bundle}),
            actor().with_idempotency_key("upsert-history-page-worker"),
        ))
        .await;
    assert_eq!(upsert.error, None);

    for sequence in 1..=2 {
        let invocation = context
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker_kernel::invoke").unwrap(),
                json!({
                    "workerId":"history-page-worker",
                    "input":{},
                    "mode":"wait",
                    "idempotencyKey":format!("history-page-run-{sequence}")
                }),
                actor().with_idempotency_key(format!("invoke-history-page-{sequence}")),
            ))
            .await;
        assert_eq!(invocation.error, None);
    }

    let read_page = |function_id: &'static str, offset: u64, key: &'static str| {
        let context = &context;
        let actor = actor();
        async move {
            context
                .engine_host
                .invoke(Invocation::new_sync(
                    FunctionId::new(function_id).unwrap(),
                    json!({
                        "workerId":"history-page-worker",
                        "limit":1,
                        "offset":offset,
                        "detail":"full"
                    }),
                    actor.with_idempotency_key(key),
                ))
                .await
                .value
                .unwrap()
        }
    };

    let first_runs = read_page("worker_kernel::runs", 0, "read-history-runs-1").await;
    let second_runs = read_page("worker_kernel::runs", 1, "read-history-runs-2").await;
    assert_eq!(first_runs["runs"].as_array().unwrap().len(), 1);
    assert_eq!(first_runs["nextOffset"], 1);
    assert_eq!(second_runs["runs"].as_array().unwrap().len(), 1);
    assert_eq!(second_runs["nextOffset"], Value::Null);
    assert_ne!(
        first_runs["runs"][0]["invocationId"],
        second_runs["runs"][0]["invocationId"]
    );

    let first_inbox = read_page("worker_kernel::inbox", 0, "read-history-inbox-1").await;
    let second_inbox = read_page("worker_kernel::inbox", 1, "read-history-inbox-2").await;
    assert_eq!(first_inbox["items"].as_array().unwrap().len(), 1);
    assert_eq!(first_inbox["nextOffset"], 1);
    assert_eq!(second_inbox["items"].as_array().unwrap().len(), 1);
    assert_eq!(second_inbox["nextOffset"], Value::Null);
}
