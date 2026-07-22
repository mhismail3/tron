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
            "messages":{
                "type":"array",
                "items":{
                    "type":"object",
                    "additionalProperties":false,
                    "required":["role","text"],
                    "properties":{
                        "role":{"enum":["user","assistant","tool"]},
                        "text":{"type":"string"}
                    }
                }
            }
        }
    });
    bundle.output_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["narrative"],
        "properties":{"narrative":{"type":"string","minLength":1}}
    });
    bundle.engine_hooks = vec![WorkerEngineHook::ContextSummary];
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
async fn inbox_context_worker_selects_claims_and_narrates_unseen_results() {
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
        inbox.value.as_ref().unwrap()["items"][0]["result"]["preview"],
        "{\"output\":{\"report\":\"ready\"},\"status\":\"completed\"}"
    );
    let inbox_id = inbox.value.unwrap()["items"][0]["inboxId"]
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
        full_inbox["items"][0]["result"],
        json!({"output":{"report":"ready"},"status":"completed"})
    );
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
    assert_eq!(full_runs["runs"][0]["output"], json!({"report":"ready"}));
    assert!(full_runs["attempts"].as_object().unwrap().len() == 1);
    assert!(full_runs["traces"].as_object().unwrap().len() == 1);

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
            json!({"seen":false,"severity":"error"}),
            actor().with_idempotency_key("read-unseen-error-inbox-source"),
        ))
        .await;
    assert_eq!(filtered_inbox.error, None);
    assert!(
        filtered_inbox.value.unwrap()["items"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    let hook_output = serde_json::to_string(&json!({
        "consumedInboxIds":[inbox_id],
        "narrative":"The background report is ready."
    }))
    .unwrap();
    let mut hook_bundle = json!({
        "schemaVersion":"tron.worker_bundle.v1",
        "workerId":"inbox-narrator",
        "name":"Inbox Narrator",
        "description":"Selects unseen worker results and creates transient context",
        "inputSchema":{
            "type":"object","additionalProperties":false,"required":["query","items"],
            "properties":{
                "query":{"type":"string"},
                "items":{"type":"array","items":{
                    "type":"object","additionalProperties":false,
                    "required":["inboxId","invocationId","workerId","severity","resultPreview","createdAt","triggerKind","workerName","workerDescription"],
                    "properties":{
                        "inboxId":{"type":"string"},"invocationId":{"type":"string"},
                        "workerId":{"type":"string"},"severity":{"type":"string"},
                        "resultPreview":{"type":"string"},"createdAt":{"type":"string"},
                        "triggerKind":{"type":"string"},"workerName":{"type":"string"},
                        "workerDescription":{"type":"string"}
                    }
                }}
            }
        },
        "outputSchema":{
            "type":"object","additionalProperties":false,
            "required":["consumedInboxIds","narrative"],
            "properties":{
                "consumedInboxIds":{"type":"array","maxItems":32,"uniqueItems":true,"items":{"type":"string","minLength":1}},
                "narrative":{"type":"string"}
            }
        },
        "runner":{"kind":"command","command":["printf",hook_output]},
        "engineHooks":["inbox_context"],
        "provenance":[{"source":"test:inbox-narrator"}]
    });
    let hook = context
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::upsert").unwrap(),
            json!({"bundle":hook_bundle.clone()}),
            actor().with_idempotency_key("upsert-inbox-hook"),
        ))
        .await;
    assert_eq!(hook.error, None);

    let attached = context
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::inbox_attach").unwrap(),
            json!({"relevanceQuery":"background report","limit":8}),
            CausalContext::new(
                ActorId::new("system:inbox-hook-test").unwrap(),
                ActorKind::System,
                TraceId::generate(),
            )
            .with_session_id("inbox-hook-test")
            .with_idempotency_key("attach-inbox-context"),
        ))
        .await;
    assert_eq!(attached.error, None);
    let attached = attached.value.unwrap();
    assert_eq!(attached["handled"], true);
    assert_eq!(attached["narrative"], "The background report is ready.");
    assert_eq!(attached["items"].as_array().unwrap().len(), 1);

    let inbox = context
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::inbox").unwrap(),
            json!({"workerId":"background-report","limit":10}),
            actor().with_idempotency_key("read-claimed-inbox-source"),
        ))
        .await;
    assert_eq!(inbox.value.unwrap()["items"][0]["seen"], true);

    let invoked = context
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::invoke").unwrap(),
            json!({
                "workerId":"background-report",
                "input":{},
                "mode":"wait",
                "idempotencyKey":"background-report-run-invalid"
            }),
            actor().with_idempotency_key("invoke-inbox-source-invalid"),
        ))
        .await;
    assert_eq!(invoked.error, None);
    hook_bundle["runner"]["command"] = json!([
        "printf",
        "{\"consumedInboxIds\":[\"not-a-candidate\"],\"narrative\":\"invalid\"}"
    ]);
    let hook = context
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::upsert").unwrap(),
            json!({"bundle":hook_bundle}),
            actor().with_idempotency_key("update-inbox-hook-invalid"),
        ))
        .await;
    assert_eq!(hook.error, None);
    let rejected = context
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::inbox_attach").unwrap(),
            json!({"relevanceQuery":"background report","limit":8}),
            CausalContext::new(
                ActorId::new("system:inbox-hook-test").unwrap(),
                ActorKind::System,
                TraceId::generate(),
            )
            .with_session_id("inbox-hook-test")
            .with_idempotency_key("attach-invalid-inbox-context"),
        ))
        .await;
    assert!(rejected.error.is_some());
    let inspection = context
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::inspect").unwrap(),
            json!({"workerId":"inbox-narrator"}),
            actor().with_idempotency_key("inspect-invalid-inbox-hook"),
        ))
        .await
        .value
        .unwrap();
    assert_eq!(inspection["worker"]["enabled"], false);
    assert_eq!(inspection["healthHistory"][0]["status"], "failed");
}
