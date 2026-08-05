use super::*;
use crate::shared::protocol::events::TronEvent;

fn session_title_bundle(worker_id: &str, command_output: Value) -> WorkerBundle {
    let mut bundle = command_bundle(vec![
        "printf".to_owned(),
        serde_json::to_string(&command_output).unwrap(),
    ]);
    bundle.worker_id = Some(worker_id.to_owned());
    bundle.name = "Session Title".to_owned();
    bundle.description = "Names an untitled ordinary session after its first exchange".to_owned();
    bundle.tool_name = Some(format!("worker_{worker_id}"));
    bundle.input_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["userPrompt","assistantResponse"],
        "properties":{
            "userPrompt":{"type":"string","maxLength":4096},
            "assistantResponse":{"type":"string","maxLength":4096}
        }
    });
    bundle.output_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["title"],
        "properties":{"title":{"type":"string","minLength":1,"maxLength":160}}
    });
    bundle.engine_hooks = vec![WorkerEngineHook::SessionTitle];
    bundle
}

fn session_organization_bundle() -> WorkerBundle {
    let mut bundle = command_bundle(vec![
        "printf".to_owned(),
        serde_json::to_string(&json!({
            "status":"proposed",
            "proposal":{
                "sessionId":"sess-proposal",
                "labels":["Work"],
                "group":null,
                "archiveAction":"preserve",
                "reason":"Keep current work active."
            }
        }))
        .unwrap(),
    ]);
    bundle.worker_id = Some("session-organizer".to_owned());
    bundle.name = "Session Organizer".to_owned();
    bundle.description = "Proposes bounded session organization once after naming".to_owned();
    bundle.tool_name = Some("worker_sessions".to_owned());
    bundle.input_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["action","session","userPrompt","assistantResponse"],
        "properties":{
            "action":{"const":"session_organization"},
            "session":{
                "type":"object",
                "additionalProperties":false,
                "required":["sessionId","workingDirectory","labels","isArchived"],
                "properties":{
                    "sessionId":{"type":"string","minLength":1},
                    "title":{"type":["string","null"]},
                    "workingDirectory":{"type":"string"},
                    "labels":{"type":"array","maxItems":12,"items":{"type":"string"}},
                    "group":{"type":["string","null"]},
                    "isArchived":{"type":"boolean"}
                }
            },
            "userPrompt":{"type":"string","maxLength":4096},
            "assistantResponse":{"type":"string","maxLength":4096}
        }
    });
    bundle.output_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["status","proposal"],
        "properties":{
            "status":{"const":"proposed"},
            "proposal":{
                "type":"object",
                "additionalProperties":false,
                "required":["sessionId","labels","group","archiveAction","reason"],
                "properties":{
                    "sessionId":{"type":"string","minLength":1},
                    "labels":{"type":"array","maxItems":12,"items":{"type":"string","minLength":1,"maxLength":64}},
                    "group":{"type":["string","null"],"maxLength":80},
                    "archiveAction":{"type":"string","enum":["preserve","archive","restore"]},
                    "reason":{"type":"string","minLength":1,"maxLength":512}
                }
            },
            "sessionOrganizationMutations":{"type":"array","maxItems":16}
        }
    });
    bundle.engine_hooks = vec![WorkerEngineHook::SessionOrganization];
    bundle
}

fn session_title_invocation(session_id: &str, key: &str) -> Invocation {
    Invocation::new_sync(
        FunctionId::new(super::super::super::SESSION_TITLE_FUNCTION).unwrap(),
        json!({
            "userPrompt":"Build a reliable work ledger.",
            "assistantResponse":"I created and verified the worker."
        }),
        CausalContext::new(
            ActorId::new("system:session-title-test").unwrap(),
            ActorKind::System,
            TraceId::new(format!("trace-{key}")).unwrap(),
        )
        .with_session_id(session_id)
        .with_idempotency_key(key),
    )
}

async fn await_queued_title(runtime: &Arc<WorkerRuntime>, result: &Value) -> InvocationRecord {
    let invocation_id = result["invocationId"]
        .as_str()
        .expect("title invocation id");
    let (record, timed_out) = runtime
        .await_invocation(invocation_id, Duration::from_secs(2))
        .await
        .unwrap();
    assert!(!timed_out);
    record
}

#[tokio::test]
async fn session_title_admission_receipts_satisfy_the_engine_contract() {
    let (runtime, _home) = test_runtime(None);
    let unhandled_session = runtime
        .event_store
        .create_session("mock", "/tmp", None, None)
        .unwrap()
        .session;
    let unhandled = runtime
        .host()
        .invoke(session_title_invocation(
            &unhandled_session.id,
            "title-contract-unhandled",
        ))
        .await;
    assert!(unhandled.error.is_none(), "{:?}", unhandled.error);
    assert_eq!(
        unhandled.value,
        Some(json!({"handled":false,"queued":false,"updated":false}))
    );

    runtime
        .upsert(
            session_title_bundle(
                "session-title-policy",
                json!({"title":"Contract-Checked Title"}),
            ),
            None,
        )
        .await
        .unwrap();
    let handled_session = runtime
        .event_store
        .create_session("mock", "/tmp", None, None)
        .unwrap()
        .session;
    let handled = runtime
        .host()
        .invoke(session_title_invocation(
            &handled_session.id,
            "title-contract-handled",
        ))
        .await;
    assert!(handled.error.is_none(), "{:?}", handled.error);
    let receipt = handled.value.expect("session-title admission receipt");
    assert_eq!(receipt["handled"], true);
    assert_eq!(receipt["queued"], true);
    assert_eq!(receipt["updated"], false);
    assert!(receipt["invocationId"].is_string());
    assert_eq!(receipt["workerId"], "session-title-policy");
    assert!(receipt["workerVersion"].is_string());
    let completed = await_queued_title(&runtime, &receipt).await;
    let events = runtime
        .host()
        .poll_stream_topic(
            "worker.invocations",
            StreamCursor(0),
            100,
            &StreamActorScope::all(),
        )
        .await
        .unwrap()
        .events
        .into_iter()
        .filter(|event| event.payload["invocationId"] == completed.invocation_id)
        .collect::<Vec<_>>();
    assert!(!events.is_empty());
    assert!(
        events
            .iter()
            .all(|event| event.session_id.as_deref() == Some(handled_session.id.as_str())),
        "engine hooks must invalidate only their durable origin session"
    );
}

#[tokio::test]
async fn explicit_session_rename_persists_and_broadcasts() {
    let (runtime, _home) = test_runtime(None);
    let created = runtime
        .event_store
        .create_session("mock", "/tmp", Some("New Session"), None)
        .unwrap();
    let session_id = created.session.id;
    let mut events = runtime.orchestrator.subscribe();

    let result = crate::domains::session::title::set_title(
        runtime.event_store.clone(),
        &runtime.session_manager,
        &runtime.orchestrator,
        session_id.clone(),
        "  Durable Worker Title  ".to_owned(),
    )
    .await
    .unwrap();

    assert_eq!(result["sessionId"], session_id);
    assert_eq!(result["title"], "Durable Worker Title");
    assert_eq!(result["updated"], true);
    assert_eq!(
        runtime
            .event_store
            .get_session(&session_id)
            .unwrap()
            .unwrap()
            .title
            .as_deref(),
        Some("Durable Worker Title")
    );
    let event = events.recv().await.unwrap();
    assert!(matches!(
        event,
        TronEvent::SessionUpdated { title: Some(title), .. }
            if title == "Durable Worker Title"
    ));
}

#[tokio::test]
async fn session_title_hook_names_the_original_untitled_session_once() {
    let (runtime, _home) = test_runtime(None);
    runtime
        .upsert(session_organization_bundle(), None)
        .await
        .unwrap();
    let worker = runtime
        .upsert(
            session_title_bundle(
                "session-title-policy",
                json!({"title":"Build a Reliable Work Ledger"}),
            ),
            None,
        )
        .await
        .unwrap();
    let session = runtime
        .event_store
        .create_session("mock", "/tmp", None, None)
        .unwrap()
        .session;

    let first = runtime
        .enqueue_session_title_hook(&session_title_invocation(&session.id, "title-first"))
        .await
        .unwrap();
    assert_eq!(first["handled"], true);
    assert_eq!(first["queued"], true);
    assert_eq!(first["updated"], false);
    assert_eq!(first["workerId"], worker.worker.worker_id);
    let completed_title = await_queued_title(&runtime, &first).await;
    assert_eq!(completed_title.status, "completed");
    assert_eq!(
        runtime
            .event_store
            .get_session(&session.id)
            .unwrap()
            .unwrap()
            .title
            .as_deref(),
        Some("Build a Reliable Work Ledger")
    );
    for _ in 0..100 {
        if runtime
            .store()
            .runs_filtered(Some("session-organizer"), None, 10)
            .unwrap()
            .len()
            == 1
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    let second = runtime
        .enqueue_session_title_hook(&session_title_invocation(&session.id, "title-second"))
        .await
        .unwrap();
    assert_eq!(
        second,
        json!({"handled":false,"queued":false,"updated":false})
    );
    assert_eq!(
        runtime
            .store()
            .runs_filtered(Some("session-title-policy"), None, 10)
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        runtime
            .store()
            .runs_filtered(Some("session-organizer"), None, 10)
            .unwrap()
            .len(),
        1,
        "later turns cannot enqueue another one-shot organizer invocation"
    );
    let dispatches = runtime
        .store()
        .worker_dispatches_for_source(&completed_title.invocation_id)
        .unwrap();
    assert_eq!(dispatches.len(), 1);
    assert_eq!(
        dispatches[0]["route"],
        super::super::session_organization::SESSION_ORGANIZATION_AFTER_TITLE_ROUTE
    );
    assert_eq!(dispatches[0]["targetWorkerId"], "session-organizer");
}

#[tokio::test]
async fn session_title_hook_returns_after_durable_admission_and_cannot_overwrite_rename() {
    let (runtime, _home) = test_runtime(None);
    let mut bundle =
        session_title_bundle("session-title-policy", json!({"title":"Generated Title"}));
    bundle.runner = WorkerRunner::Command {
        command: vec![
            "sh".to_owned(),
            "-c".to_owned(),
            "sleep 0.15; printf '{\"title\":\"Generated Title\"}'".to_owned(),
        ],
    };
    runtime.upsert(bundle, None).await.unwrap();
    let session = runtime
        .event_store
        .create_session("mock", "/tmp", None, None)
        .unwrap()
        .session;

    let queued = runtime
        .enqueue_session_title_hook(&session_title_invocation(&session.id, "title-detached"))
        .await
        .unwrap();
    assert_eq!(queued["handled"], true);
    let invocation_id = queued["invocationId"].as_str().unwrap();
    let admitted = runtime.store().invocation(invocation_id).unwrap().unwrap();
    assert!(matches!(admitted.status.as_str(), "queued" | "running"));
    assert_eq!(admitted.interaction_mode, WorkerInteractionMode::Background);
    assert!(admitted.detached_at.is_some());
    assert!(
        runtime
            .event_store
            .get_session(&session.id)
            .unwrap()
            .unwrap()
            .title
            .is_none()
    );

    crate::domains::session::title::set_title(
        runtime.event_store.clone(),
        &runtime.session_manager,
        &runtime.orchestrator,
        session.id.clone(),
        "Explicit Rename".to_owned(),
    )
    .await
    .unwrap();
    assert_eq!(
        await_queued_title(&runtime, &queued).await.status,
        "completed"
    );
    assert_eq!(
        runtime
            .event_store
            .get_session(&session.id)
            .unwrap()
            .unwrap()
            .title
            .as_deref(),
        Some("Explicit Rename")
    );
}

#[tokio::test]
async fn session_title_replay_after_apply_before_terminal_is_safe_and_dispatches_organizer_once() {
    let (runtime, home) = test_runtime(None);
    runtime
        .upsert(session_organization_bundle(), None)
        .await
        .unwrap();
    let title_worker = runtime
        .upsert(
            session_title_bundle(
                "session-title-policy",
                json!({"title":"Restart-Safe Session Title"}),
            ),
            None,
        )
        .await
        .unwrap();
    let session = runtime
        .event_store
        .create_session("mock", "/tmp", None, None)
        .unwrap()
        .session;
    let input = json!({
        "userPrompt":"Prove the title replay boundary.",
        "assistantResponse":"The title should survive a restart."
    });
    let (running, replayed) = runtime
        .store()
        .begin_invocation_with_context(
            &title_worker.worker.worker_id,
            &title_worker.version,
            &input,
            "title-crash-window",
            "trace-title-crash-window",
            0,
            "engine_hook:session_title",
            Some(&session.id),
            WorkerInteractionMode::Background,
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();
    assert!(!replayed);
    assert!(
        runtime
            .store()
            .claim_running(&running.invocation_id)
            .unwrap()
    );

    // Simulate a crash in the intentional window after tron.sqlite accepted
    // the compare-and-set but before workers.sqlite committed terminal effects.
    let prepared_before_crash = runtime
        .apply_session_title_result(&running, &json!({"title":"Restart-Safe Session Title"}))
        .await
        .unwrap();
    assert!(prepared_before_crash.is_some());
    assert_eq!(
        runtime
            .event_store
            .get_session(&session.id)
            .unwrap()
            .unwrap()
            .title
            .as_deref(),
        Some("Restart-Safe Session Title")
    );
    let host = runtime.host.clone();
    let orchestrator = runtime.orchestrator.clone();
    let session_manager = runtime.session_manager.clone();
    let event_store = runtime.event_store.clone();
    let settings_runtime = runtime.settings_runtime.clone();
    runtime.shutdown().await;
    drop(runtime);

    let restarted = WorkerRuntime::new(
        WorkerStore::open(home.path().to_path_buf()).unwrap(),
        host,
        orchestrator,
        session_manager,
        event_store,
        settings_runtime,
    )
    .unwrap();
    restarted.reconcile_orphaned_invocations(true).await;
    let completed = restarted
        .invoke(InvokeRequest {
            worker_id: title_worker.worker.worker_id.clone(),
            input,
            idempotency_key: "title-crash-window".to_owned(),
            trace_id: "trace-title-crash-window".to_owned(),
            causal_depth: 0,
            trigger_kind: "engine_hook:session_title".to_owned(),
            origin_session_id: Some(session.id.clone()),
            model: None,
            reasoning_level: None,
        })
        .await
        .unwrap();
    assert_eq!(completed.invocation_id, running.invocation_id);
    assert_eq!(completed.status, "completed", "{:?}", completed.error);
    assert_eq!(completed.attempt_count, 2);
    assert_eq!(
        restarted
            .event_store
            .get_session(&session.id)
            .unwrap()
            .unwrap()
            .title
            .as_deref(),
        Some("Restart-Safe Session Title")
    );

    let replay = restarted
        .invoke(InvokeRequest {
            worker_id: title_worker.worker.worker_id,
            input: completed.input.clone(),
            idempotency_key: "title-crash-window".to_owned(),
            trace_id: "trace-title-crash-window".to_owned(),
            causal_depth: 0,
            trigger_kind: "engine_hook:session_title".to_owned(),
            origin_session_id: Some(session.id),
            model: None,
            reasoning_level: None,
        })
        .await
        .unwrap();
    assert_eq!(replay.invocation_id, completed.invocation_id);
    assert_eq!(
        restarted
            .store()
            .worker_dispatches_for_source(&completed.invocation_id)
            .unwrap()
            .len(),
        1,
        "replay must retain one immutable Session Organizer handoff"
    );
    assert_eq!(
        restarted
            .store()
            .runs_filtered(Some("session-organizer"), None, 10)
            .unwrap()
            .len(),
        1,
        "replay must not queue a second Session Organizer invocation"
    );
}

#[tokio::test]
async fn absent_session_title_policy_leaves_the_session_untitled() {
    let (runtime, _home) = test_runtime(None);
    let session = runtime
        .event_store
        .create_session("mock", "/tmp", None, None)
        .unwrap()
        .session;

    let result = runtime
        .enqueue_session_title_hook(&session_title_invocation(&session.id, "title-absent"))
        .await
        .unwrap();

    assert_eq!(
        result,
        json!({"handled":false,"queued":false,"updated":false})
    );
    assert!(
        runtime
            .event_store
            .get_session(&session.id)
            .unwrap()
            .unwrap()
            .title
            .is_none()
    );
    assert!(
        runtime
            .store()
            .runs_filtered(None, None, 10)
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn session_title_hook_preserves_explicit_and_worker_session_titles() {
    let (runtime, _home) = test_runtime(None);
    runtime
        .upsert(
            session_title_bundle(
                "session-title-policy",
                json!({"title":"Must Not Be Applied"}),
            ),
            None,
        )
        .await
        .unwrap();
    let explicit = runtime
        .event_store
        .create_session("mock", "/tmp", Some("Explicit"), None)
        .unwrap()
        .session;
    let worker_session = runtime
        .event_store
        .create_worker_session("mock", "/tmp", None, None)
        .unwrap()
        .session;

    for (session_id, key) in [
        (explicit.id.as_str(), "title-explicit"),
        (worker_session.id.as_str(), "title-worker"),
    ] {
        assert_eq!(
            runtime
                .enqueue_session_title_hook(&session_title_invocation(session_id, key))
                .await
                .unwrap(),
            json!({"handled":false,"queued":false,"updated":false})
        );
    }
    assert_eq!(
        runtime
            .event_store
            .get_session(&explicit.id)
            .unwrap()
            .unwrap()
            .title
            .as_deref(),
        Some("Explicit")
    );
    assert!(
        runtime
            .event_store
            .get_session(&worker_session.id)
            .unwrap()
            .unwrap()
            .title
            .is_none()
    );
    assert!(
        runtime
            .store()
            .runs_filtered(Some("session-title-policy"), None, 10)
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn invalid_session_title_policy_output_is_rejected_without_disabling_the_worker() {
    let (runtime, _home) = test_runtime(None);
    runtime
        .upsert(
            session_title_bundle("session-title-policy", json!({"title":"   "})),
            None,
        )
        .await
        .unwrap();
    let session = runtime
        .event_store
        .create_session("mock", "/tmp", None, None)
        .unwrap()
        .session;

    let queued = runtime
        .enqueue_session_title_hook(&session_title_invocation(&session.id, "title-invalid"))
        .await
        .unwrap();
    let failed = await_queued_title(&runtime, &queued).await;

    assert_eq!(failed.status, "failed");
    assert!(
        failed
            .error
            .as_deref()
            .is_some_and(|error| error.contains("session_title"))
    );
    assert!(
        runtime
            .event_store
            .get_session(&session.id)
            .unwrap()
            .unwrap()
            .title
            .is_none()
    );
    let summary = runtime
        .store()
        .summary("session-title-policy")
        .unwrap()
        .unwrap();
    assert!(
        summary.enabled,
        "a request-specific optional hook failure must not disable its reusable owner"
    );
    assert_eq!(summary.health, "healthy");
}
