use super::support::*;
use crate::domains::session::event_store::{AppendOptions, EventType};
use crate::shared::server::errors::{CapabilityError, EVENT_NOT_FOUND};

fn request(session_id: &str, from_event_id: Option<String>) -> ForkSessionRequest {
    ForkSessionRequest {
        session_id: session_id.to_owned(),
        from_event_id,
        expected_head_event_id: None,
        title: None,
        causal_session_id: Some(session_id.to_owned()),
        causal_workspace_id: None,
        idempotency_key: None,
    }
}

fn append_completed_turn(
    ctx: &crate::shared::server::context::ServerRuntimeContext,
    session_id: &str,
    turn: i64,
) -> (
    crate::domains::session::event_store::EventRow,
    crate::domains::session::event_store::EventRow,
) {
    let assistant = ctx
        .event_store
        .append(&AppendOptions {
            session_id,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({"content": "done", "turn": turn}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    let boundary = ctx
        .event_store
        .append(&AppendOptions {
            session_id,
            event_type: EventType::StreamTurnEnd,
            payload: serde_json::json!({"turn": turn, "stopReason": "end_turn"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    (assistant, boundary)
}

#[tokio::test]
async fn fork_defaults_to_head_and_initializes_runtime_sequence() {
    let ctx = make_test_context();
    let source_id = ctx
        .session_manager
        .create_session("test-model", "/tmp", Some("source"))
        .unwrap();
    let (_, source_boundary) = append_completed_turn(&ctx, &source_id, 1);

    let mut fork_request = request(&source_id, None);
    fork_request.title = Some("forked".into());
    let response = SessionLifecycleService::fork(&Deps::from_test_context(&ctx), fork_request)
        .await
        .unwrap();

    let new_session_id = response["newSessionId"].as_str().unwrap();
    assert_ne!(new_session_id, source_id);
    assert_eq!(response["forkedFromSessionId"], source_id);
    assert_eq!(response["forkedFromEventId"], source_boundary.id);
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
async fn fork_normalizes_assistant_selector_and_rejects_missing_event() {
    let ctx = make_test_context();
    let source_id = ctx
        .session_manager
        .create_session("test-model", "/tmp", Some("source"))
        .unwrap();
    let (assistant, boundary) = append_completed_turn(&ctx, &source_id, 1);

    let response = SessionLifecycleService::fork(
        &Deps::from_test_context(&ctx),
        request(&source_id, Some(assistant.id)),
    )
    .await
    .unwrap();
    assert_eq!(response["forkedFromEventId"], boundary.id);

    let error = SessionLifecycleService::fork(
        &Deps::from_test_context(&ctx),
        request(&source_id, Some("missing-event".into())),
    )
    .await
    .unwrap_err();
    match error {
        CapabilityError::NotFound { code, message } => {
            assert_eq!(code, EVENT_NOT_FOUND);
            assert!(message.contains("missing-event"));
        }
        other => panic!("expected not-found fork error, got {other:?}"),
    }
}

#[tokio::test]
async fn fork_rejects_cross_session_and_nonterminal_event_selectors() {
    let ctx = make_test_context();
    let source_id = ctx
        .session_manager
        .create_session("test-model", "/tmp", Some("source"))
        .unwrap();
    let other_id = ctx
        .session_manager
        .create_session("test-model", "/tmp", Some("other"))
        .unwrap();
    let (other_assistant, _) = append_completed_turn(&ctx, &other_id, 1);

    let cross_session = SessionLifecycleService::fork(
        &Deps::from_test_context(&ctx),
        request(&source_id, Some(other_assistant.id)),
    )
    .await
    .unwrap_err();
    assert_eq!(cross_session.code(), EVENT_NOT_FOUND);

    let user = ctx
        .event_store
        .append(&AppendOptions {
            session_id: &source_id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "not complete", "turn": 1}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    let nonterminal = SessionLifecycleService::fork(
        &Deps::from_test_context(&ctx),
        request(&source_id, Some(user.id)),
    )
    .await
    .unwrap_err();
    assert!(matches!(nonterminal, CapabilityError::InvalidParams { .. }));
}

#[tokio::test]
async fn fork_validates_causal_scope_and_expected_head() {
    let ctx = make_test_context();
    let source_id = ctx
        .session_manager
        .create_session("test-model", "/tmp", Some("source"))
        .unwrap();
    let (_, boundary) = append_completed_turn(&ctx, &source_id, 1);

    let mut wrong_session = request(&source_id, None);
    wrong_session.causal_session_id = Some("different-session".into());
    assert!(matches!(
        SessionLifecycleService::fork(&Deps::from_test_context(&ctx), wrong_session)
            .await
            .unwrap_err(),
        CapabilityError::InvalidParams { .. }
    ));

    let mut stale = request(&source_id, None);
    stale.expected_head_event_id = Some("stale-head".into());
    let error = SessionLifecycleService::fork(&Deps::from_test_context(&ctx), stale)
        .await
        .unwrap_err();
    assert_eq!(error.code(), "SESSION_HEAD_CHANGED");

    let mut exact = request(&source_id, None);
    exact.expected_head_event_id = Some(boundary.id);
    SessionLifecycleService::fork(&Deps::from_test_context(&ctx), exact)
        .await
        .unwrap();
}

#[tokio::test]
async fn fork_retry_with_same_idempotency_key_converges_on_one_child() {
    let ctx = make_test_context();
    let source_id = ctx
        .session_manager
        .create_session("test-model", "/tmp", Some("source"))
        .unwrap();
    let (_, original_boundary) = append_completed_turn(&ctx, &source_id, 1);

    let mut first_request = request(&source_id, None);
    first_request.idempotency_key = Some("branch-user-action-1".into());
    first_request.expected_head_event_id = Some(original_boundary.id.clone());
    let first = SessionLifecycleService::fork(&Deps::from_test_context(&ctx), first_request)
        .await
        .unwrap();
    let child_id = first["newSessionId"].as_str().unwrap();
    // The source is allowed to advance after the committed response is lost.
    // Replay lookup must precede both HEAD resolution and freshness checks.
    let source_advanced = ctx
        .event_store
        .append(&AppendOptions {
            session_id: &source_id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "source progressed", "turn": 2}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    let child_event = ctx
        .event_store
        .append(&AppendOptions {
            session_id: child_id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "child progressed", "turn": 1}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    let mut retry_request = request(&source_id, None);
    retry_request.idempotency_key = Some("branch-user-action-1".into());
    retry_request.expected_head_event_id = Some(original_boundary.id);
    let retry = SessionLifecycleService::fork(&Deps::from_test_context(&ctx), retry_request)
        .await
        .unwrap();

    assert_eq!(first["newSessionId"], retry["newSessionId"]);
    assert_eq!(first["rootEventId"], retry["rootEventId"]);
    assert_eq!(first["replayed"], false);
    assert_eq!(retry["replayed"], true);
    assert_ne!(retry["forkedFromEventId"], source_advanced.id);
    assert_eq!(
        ctx.orchestrator.current_sequence(child_id),
        Some(child_event.sequence)
    );
    let children = ctx
        .event_store
        .list_sessions(&crate::domains::session::event_store::ListSessionsOptions::default())
        .unwrap()
        .into_iter()
        .filter(|session| session.parent_session_id.as_deref() == Some(source_id.as_str()))
        .count();
    assert_eq!(children, 1);
}

#[tokio::test]
async fn fork_retry_preserves_the_original_assistant_selector_after_source_advances() {
    let ctx = make_test_context();
    let source_id = ctx
        .session_manager
        .create_session("test-model", "/tmp", Some("source"))
        .unwrap();
    let (assistant, boundary) = append_completed_turn(&ctx, &source_id, 1);
    let mut first_request = request(&source_id, Some(assistant.id.clone()));
    first_request.expected_head_event_id = Some(boundary.id.clone());
    first_request.idempotency_key = Some("assistant-selector-replay".into());
    let first = SessionLifecycleService::fork(&Deps::from_test_context(&ctx), first_request)
        .await
        .unwrap();

    let _ = ctx
        .event_store
        .append(&AppendOptions {
            session_id: &source_id,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "source advanced", "turn": 2}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    let mut retry = request(&source_id, Some(assistant.id));
    retry.expected_head_event_id = Some(boundary.id.clone());
    retry.idempotency_key = Some("assistant-selector-replay".into());
    let replay = SessionLifecycleService::fork(&Deps::from_test_context(&ctx), retry)
        .await
        .unwrap();

    assert_eq!(replay["newSessionId"], first["newSessionId"]);
    assert_eq!(replay["forkedFromEventId"], boundary.id);
    assert_eq!(replay["replayed"], true);
}
