use super::support::*;

#[tokio::test]
async fn archive_and_unarchive_without_external_workspace_succeed() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("model", "/tmp", Some("test"))
        .unwrap();

    SessionLifecycleService::archive(&Deps::from_test_context(&ctx), sid.clone())
        .await
        .unwrap();

    let session = ctx.event_store.get_session(&sid).unwrap().unwrap();
    assert!(session.ended_at.is_some());

    SessionLifecycleService::unarchive(&Deps::from_test_context(&ctx), sid.clone())
        .await
        .unwrap();

    let session = ctx.event_store.get_session(&sid).unwrap().unwrap();
    assert!(session.ended_at.is_none());
    assert!(!ctx.session_manager.is_cached(&sid));
}

#[tokio::test]
async fn archive_preserves_live_sequence_monotonicity_after_unarchive() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("model", "/tmp", Some("sequence"))
        .unwrap();
    let counter = ctx.orchestrator.ensure_sequence_counter_at_least(&sid, 40);
    let _ = ctx.orchestrator.broadcast().emit_sequenced(
        crate::shared::protocol::events::TronEvent::AgentReady {
            base: crate::shared::protocol::events::BaseEvent::now(&sid),
        },
        &counter,
    );
    assert_eq!(counter.load(std::sync::atomic::Ordering::SeqCst), 41);

    SessionLifecycleService::archive(&Deps::from_test_context(&ctx), sid.clone())
        .await
        .unwrap();
    SessionLifecycleService::unarchive(&Deps::from_test_context(&ctx), sid.clone())
        .await
        .unwrap();

    let resumed = ctx.orchestrator.ensure_sequence_counter_at_least(&sid, 1);
    let mut events = ctx.orchestrator.subscribe();
    let _ = ctx.orchestrator.broadcast().emit_sequenced(
        crate::shared::protocol::events::TronEvent::AgentStart {
            base: crate::shared::protocol::events::BaseEvent::now(&sid),
        },
        &resumed,
    );
    let next = events.try_recv().unwrap();

    assert_eq!(next.sequence(), Some(42));
}

#[tokio::test]
async fn delete_without_external_workspace_succeeds() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("model", "/tmp", Some("test"))
        .unwrap();

    SessionLifecycleService::delete(&Deps::from_test_context(&ctx), sid.clone())
        .await
        .unwrap();

    assert!(ctx.event_store.get_session(&sid).unwrap().is_none());
}
