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
async fn explicit_session_rename_persists_and_broadcasts() {
    let (runtime, _home) = test_runtime(None);
    let created = runtime
        .event_store
        .create_session("mock", "/tmp", Some("New Session"), None)
        .unwrap();
    let session_id = created.session.id;
    let mut events = runtime.orchestrator.subscribe();

    let result = runtime
        .set_session_title(session_id.clone(), "  Durable Worker Title  ".to_owned())
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
    assert_eq!(second, json!({"handled":false,"updated":false}));
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

    runtime
        .set_session_title(session.id.clone(), "Explicit Rename".to_owned())
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

    assert_eq!(result, json!({"handled":false,"updated":false}));
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
            json!({"handled":false,"updated":false})
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
async fn invalid_session_title_policy_output_is_rejected_without_mutating_the_session() {
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
    assert!(!summary.enabled);
    assert_eq!(summary.health, "failed");
}
