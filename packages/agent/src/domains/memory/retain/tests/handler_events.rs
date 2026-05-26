use super::support::*;

#[tokio::test]
async fn handler_requires_session_id() {
    use crate::shared::server::test_support::make_test_context;
    let ctx = make_test_context();
    let err = trigger_manual_retain(
        Some(&serde_json::json!({})),
        &crate::domains::memory::Deps::from_engine(
            &crate::domains::worker::DomainRegistrationContext::from_context(&ctx),
        ),
        None,
    )
    .await
    .unwrap_err();
    assert_eq!(err.code(), "INVALID_PARAMS");
}

#[tokio::test]
async fn handler_returns_nothing_new_for_empty_session() {
    use crate::shared::server::test_support::make_test_context;
    let ctx = make_test_context();

    // Create a session first so the handler can find it
    let cr = ctx
        .event_store
        .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
        .unwrap();

    let deps = RetainDeps::from_test_context(&ctx);
    let result = trigger_retain(&deps, cr.session.id.clone(), RetainSource::Manual, None)
        .await
        .unwrap();
    // No events since boundary (sequence 0 => empty since) => nothing_new
    assert_eq!(result["retained"], false);
}

#[tokio::test]
async fn auto_source_persists_trigger_event() {
    use crate::domains::session::event_store::EventType;
    use crate::shared::server::test_support::make_test_context;
    let ctx = make_test_context();

    let cr = ctx
        .event_store
        .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
        .unwrap();
    let session_id = cr.session.id.clone();

    let deps = RetainDeps::from_test_context(&ctx);
    let _ = trigger_retain(
        &deps,
        session_id.clone(),
        RetainSource::Auto { interval_fired: 5 },
        None,
    )
    .await
    .unwrap();

    let row = ctx
        .event_store
        .get_latest_event_by_type(&session_id, "memory.auto_retain_triggered")
        .unwrap()
        .expect("auto-retain trigger event should be persisted");
    assert_eq!(row.event_type, "memory.auto_retain_triggered");

    let payload: serde_json::Value = serde_json::from_str(&row.payload).unwrap();
    assert_eq!(payload["intervalFired"], 5);
    assert_eq!(payload["sessionId"], session_id);
    let _ = EventType::MemoryAutoRetainTriggered; // compile-time check that the variant exists
}

#[tokio::test]
async fn trigger_retain_skips_when_already_in_flight() {
    use crate::shared::server::test_support::make_test_context;
    let ctx = make_test_context();

    let cr = ctx
        .event_store
        .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
        .unwrap();
    let session_id = cr.session.id.clone();

    // Take the slot directly (simulating a still-running retain background task).
    let _held = ctx
        .orchestrator
        .try_begin_retain(&session_id)
        .expect("fresh session must be claimable");

    let deps = RetainDeps::from_test_context(&ctx);
    let result = trigger_retain(&deps, session_id.clone(), RetainSource::Manual, None)
        .await
        .unwrap();
    assert_eq!(result["retained"], false);
    assert_eq!(result["reason"], "in_flight");

    // Also true for auto.
    let result_auto = trigger_retain(
        &deps,
        session_id.clone(),
        RetainSource::Auto { interval_fired: 5 },
        None,
    )
    .await
    .unwrap();
    assert_eq!(result_auto["reason"], "in_flight");

    // No auto-retain event persisted (the guard short-circuits before any I/O).
    let row = ctx
        .event_store
        .get_latest_event_by_type(&session_id, "memory.auto_retain_triggered")
        .unwrap();
    assert!(
        row.is_none(),
        "blocked auto retain must not persist the trigger event"
    );
}

#[tokio::test]
async fn manual_source_does_not_persist_trigger_event() {
    use crate::shared::server::test_support::make_test_context;
    let ctx = make_test_context();

    let cr = ctx
        .event_store
        .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
        .unwrap();
    let session_id = cr.session.id.clone();

    let deps = RetainDeps::from_test_context(&ctx);
    let _ = trigger_retain(&deps, session_id.clone(), RetainSource::Manual, None)
        .await
        .unwrap();

    let row = ctx
        .event_store
        .get_latest_event_by_type(&session_id, "memory.auto_retain_triggered")
        .unwrap();
    assert!(
        row.is_none(),
        "manual retain must not produce an auto_retain_triggered event"
    );
}

#[tokio::test]
async fn emit_auto_retain_failed_persists_event_with_reason() {
    use crate::shared::server::test_support::make_test_context;
    let ctx = make_test_context();

    let cr = ctx
        .event_store
        .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
        .unwrap();
    let session_id = cr.session.id.clone();

    let broadcast = Arc::clone(ctx.orchestrator.broadcast());

    emit_auto_retain_failed(
        &ctx.event_store,
        &broadcast,
        &session_id,
        7,
        "subagent spawn failed: subsession cap reached",
    )
    .await;

    let row = ctx
        .event_store
        .get_latest_event_by_type(&session_id, "memory.auto_retain_failed")
        .unwrap()
        .expect("auto_retain_failed event should be persisted");
    assert_eq!(row.event_type, "memory.auto_retain_failed");

    let payload: serde_json::Value = serde_json::from_str(&row.payload).unwrap();
    assert_eq!(payload["intervalFired"], 7);
    assert_eq!(payload["sessionId"], session_id);
    assert!(
        payload["reason"]
            .as_str()
            .unwrap_or("")
            .contains("subsession cap reached"),
        "reason should be preserved verbatim; got {:?}",
        payload["reason"]
    );
}

#[tokio::test]
async fn auto_retain_triggered_and_failed_land_in_order() {
    use crate::shared::server::test_support::make_test_context;
    let ctx = make_test_context();

    let cr = ctx
        .event_store
        .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
        .unwrap();
    let session_id = cr.session.id.clone();

    // Step 1: record the triggered event.
    emit_auto_retain_triggered(&RetainDeps::from_test_context(&ctx), &session_id, 3).await;

    // Step 2: record the failed event.
    let broadcast = Arc::clone(ctx.orchestrator.broadcast());
    emit_auto_retain_failed(&ctx.event_store, &broadcast, &session_id, 3, "test failure").await;

    let triggered = ctx
        .event_store
        .get_latest_event_by_type(&session_id, "memory.auto_retain_triggered")
        .unwrap()
        .expect("triggered must exist");
    let failed = ctx
        .event_store
        .get_latest_event_by_type(&session_id, "memory.auto_retain_failed")
        .unwrap()
        .expect("failed must exist");

    assert!(
        triggered.sequence < failed.sequence,
        "triggered must come before failed; got triggered.seq={} failed.seq={}",
        triggered.sequence,
        failed.sequence
    );
}

#[tokio::test]
async fn manual_retain_never_emits_auto_retain_failed() {
    use crate::shared::server::test_support::make_test_context;
    let ctx = make_test_context();

    let cr = ctx
        .event_store
        .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
        .unwrap();
    let session_id = cr.session.id.clone();

    // Seed a user message so the retain pipeline has content to summarize.
    let _ = ctx
        .event_store
        .append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MessageUser,
            payload: json!({"text": "hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let deps = RetainDeps::from_test_context(&ctx);
    let _ = trigger_retain(&deps, session_id.clone(), RetainSource::Manual, None)
        .await
        .unwrap();

    // trigger_retain spawns the background task; give it a moment to complete.
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;

    let failed = ctx
        .event_store
        .get_latest_event_by_type(&session_id, "memory.auto_retain_failed")
        .unwrap();
    assert!(
        failed.is_none(),
        "manual retain must never produce an auto_retain_failed event"
    );
}
