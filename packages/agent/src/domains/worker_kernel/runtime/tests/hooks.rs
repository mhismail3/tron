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
    assert!(runtime.store().runs(None, 10).unwrap().is_empty());
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
