use super::support::*;
use crate::domains::session::event_store::{AppendOptions, EventType};
use crate::shared::server::errors::{CapabilityError, SESSION_NOT_FOUND};

#[tokio::test]
async fn fork_defaults_to_head_and_initializes_runtime_sequence() {
    let ctx = make_test_context();
    let source_id = ctx
        .session_manager
        .create_session("test-model", "/tmp", Some("source"))
        .unwrap();
    let source = ctx.event_store.get_session(&source_id).unwrap().unwrap();
    let source_head = source.head_event_id.unwrap();

    let response = SessionLifecycleService::fork(
        &Deps::from_test_context(&ctx),
        source_id.clone(),
        None,
        Some("forked".into()),
    )
    .await
    .unwrap();

    let new_session_id = response["newSessionId"].as_str().unwrap();
    assert_ne!(new_session_id, source_id);
    assert_eq!(response["forkedFromSessionId"], source_id);
    assert_eq!(response["forkedFromEventId"], source_head);
    assert!(!response["rootEventId"].as_str().unwrap().is_empty());
    assert_eq!(ctx.orchestrator.current_sequence(new_session_id), Some(0));

    let forked = ctx
        .event_store
        .get_session(new_session_id)
        .unwrap()
        .unwrap();
    assert_eq!(
        forked.parent_session_id.as_deref(),
        Some(source_id.as_str())
    );
    assert_eq!(forked.title.as_deref(), Some("forked"));
}

#[tokio::test]
async fn fork_uses_explicit_event_and_rejects_missing_event() {
    let ctx = make_test_context();
    let source_id = ctx
        .session_manager
        .create_session("test-model", "/tmp", Some("source"))
        .unwrap();
    let target = ctx
        .event_store
        .append(&AppendOptions {
            session_id: &source_id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"text": "target"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    let _later = ctx
        .event_store
        .append(&AppendOptions {
            session_id: &source_id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"text": "later"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let response = SessionLifecycleService::fork(
        &Deps::from_test_context(&ctx),
        source_id.clone(),
        Some(target.id.clone()),
        None,
    )
    .await
    .unwrap();
    assert_eq!(response["forkedFromEventId"], target.id);

    let error = SessionLifecycleService::fork(
        &Deps::from_test_context(&ctx),
        source_id,
        Some("missing-event".into()),
        None,
    )
    .await
    .unwrap_err();
    match error {
        CapabilityError::NotFound { code, message } => {
            assert_eq!(code, SESSION_NOT_FOUND);
            assert!(message.starts_with("Persistence error: "));
        }
        other => panic!("expected not-found fork error, got {other:?}"),
    }
}
