use super::*;

use crate::engine::{PublishStreamEvent, VisibilityScope};
use crate::shared::server::events::ServerEventPayload;
use crate::shared::server::test_support::make_test_context;
use serde_json::json;

fn test_session() -> (EngineWsSession, mpsc::Receiver<String>) {
    let ctx = Arc::new(make_test_context());
    let (tx, rx) = mpsc::channel(OUTBOUND_QUEUE_CAPACITY);
    (
        EngineWsSession::new(
            "client-1".to_owned(),
            ctx,
            tx,
            Arc::new(tokio::sync::Mutex::new(BTreeMap::new())),
            CancellationToken::new(),
        ),
        rx,
    )
}

#[tokio::test]
async fn hello_sets_defaults() {
    let (mut session, _rx) = test_session();
    assert!(
        session
            .handle_text(r#"{"type":"hello","id":"h1","protocolVersion":1,"sessionId":"s1"}"#)
            .await
    );
    assert_eq!(
        session.hello.as_ref().unwrap().session_id.as_deref(),
        Some("s1")
    );
}

#[test]
fn invoke_message_maps_to_engine_invoke_payload() {
    let value = json!({
        "type": "invoke",
        "id": "i1",
        "functionId": "system::ping",
        "payload": {"protocolVersion": 1},
        "idempotencyKey": "idem-1",
        "context": {
            "sessionId": "s1",
            "traceId": "trace-1",
            "authorityScopes": ["system.read"],
            "runtimeMetadata": {"capability.searchPolicyId": "operatorConsoleHybridLexical"}
        }
    });
    let message: InvokeMessage = serde_json::from_value(value).unwrap();
    assert_eq!(message.function_id, "system::ping");
    let context = message.context.unwrap();
    assert_eq!(context.authority_scopes, vec!["system.read".to_owned()]);
    assert_eq!(
        context.runtime_metadata.get("capability.searchPolicyId"),
        Some(&"operatorConsoleHybridLexical".to_owned())
    );
}

#[test]
fn stream_filters_match_neutral_server_event_scope() {
    let event = crate::engine::EngineStreamEvent {
        cursor: StreamCursor(7),
        topic: "events.session".to_owned(),
        payload: json!({
            "serverEvent": ServerEventPayload::new(
                "session.created",
                Some("session-a".to_owned()),
                Some(json!({"title": "Test Session"}))
            )
        }),
        visibility: VisibilityScope::System,
        session_id: None,
        workspace_id: None,
        producer: "test".to_owned(),
        trace_id: None,
        parent_invocation_id: None,
        created_at: chrono::Utc::now(),
    };

    assert!(stream_event_matches_filters(
        &event,
        Some(&json!({"sessionId": "session-a"}))
    ));
    assert!(!stream_event_matches_filters(
        &event,
        Some(&json!({"sessionId": "session-b"}))
    ));
}

#[tokio::test]
async fn stream_poll_returns_neutral_events() {
    let (mut session, _rx) = test_session();
    session.hello = Some(HelloState {
        session_id: Some("s1".to_owned()),
        workspace_id: None,
    });
    let cursor = session
        .ctx
        .engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: "events.session".to_owned(),
            payload: json!({
                "serverEvent": ServerEventPayload::new(
                    "agent.ready",
                    Some("s1".to_owned()),
                    Some(json!({"ready": true}))
                )
            }),
            visibility: VisibilityScope::Session,
            session_id: Some("s1".to_owned()),
            workspace_id: None,
            producer: "test".to_owned(),
            trace_id: None,
            parent_invocation_id: None,
        })
        .await
        .unwrap();
    assert_eq!(cursor.0, 1);

    assert!(
        session
            .handle_text(r#"{"type":"subscribe","id":"s","topic":"events.session"}"#)
            .await
    );
    let subscription_id = session
        .subscriptions
        .lock()
        .await
        .keys()
        .next()
        .unwrap()
        .clone();
    let page = session
        .ctx
        .engine_host
        .poll_stream(
            &subscription_id,
            Some(StreamCursor(0)),
            100,
            &StreamActorScope::scoped(Some("s1".to_owned()), None),
        )
        .await
        .unwrap();
    let event = server_payload_from_stream_event(&page.events[0]);
    assert_eq!(event.event_type, "agent.ready");
    assert_eq!(event.stream_cursor, Some(1));
}

#[tokio::test]
async fn subscribe_without_cursor_starts_at_topic_tail() {
    let (mut session, mut rx) = test_session();
    session.hello = Some(HelloState {
        session_id: Some("s1".to_owned()),
        workspace_id: None,
    });
    let old_cursor = session
        .ctx
        .engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: "events.session".to_owned(),
            payload: json!({
                "serverEvent": ServerEventPayload::new(
                    "agent.old",
                    Some("s1".to_owned()),
                    Some(json!({"old": true}))
                )
            }),
            visibility: VisibilityScope::Session,
            session_id: Some("s1".to_owned()),
            workspace_id: None,
            producer: "test".to_owned(),
            trace_id: None,
            parent_invocation_id: None,
        })
        .await
        .unwrap();

    assert!(
        session
            .handle_text(r#"{"type":"subscribe","id":"s","topic":"events.session"}"#)
            .await
    );
    let response = rx.recv().await.unwrap();
    let value: Value = serde_json::from_str(&response).unwrap();
    assert_eq!(
        value.pointer("/result/cursor").and_then(Value::as_u64),
        Some(old_cursor.0)
    );

    let subscription = session
        .subscriptions
        .lock()
        .await
        .values()
        .next()
        .cloned()
        .unwrap();
    assert_eq!(subscription.cursor, old_cursor);
}

#[tokio::test]
async fn topic_poll_requires_explicit_cursor() {
    let (mut session, mut rx) = test_session();
    session.hello = Some(HelloState {
        session_id: Some("s1".to_owned()),
        workspace_id: None,
    });

    assert!(
        session
            .handle_text(r#"{"type":"poll","id":"p","topic":"events.session"}"#)
            .await
    );
    let response = rx.recv().await.unwrap();
    let value: Value = serde_json::from_str(&response).unwrap();
    assert_eq!(value.get("ok").and_then(Value::as_bool), Some(false));
    assert_eq!(
        value.pointer("/error/message").and_then(Value::as_str),
        Some("topic poll requires an explicit cursor; omit cursor only for live subscribe")
    );
}

#[tokio::test]
async fn ack_response_applies_backpressure_instead_of_closing_socket() {
    let ctx = Arc::new(make_test_context());
    ctx.engine_host
        .subscribe_stream(
            "sub-ack".to_owned(),
            "events.session".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some("s1".to_owned()),
            None,
        )
        .await
        .unwrap();
    let (tx, mut rx) = mpsc::channel(1);
    tx.try_send("occupied".to_owned()).unwrap();
    let mut session = EngineWsSession::new(
        "client-ack".to_owned(),
        ctx,
        tx,
        Arc::new(tokio::sync::Mutex::new(BTreeMap::from([(
            "sub-ack".to_owned(),
            SubscriptionState {
                topic: "events.session".to_owned(),
                cursor: StreamCursor(0),
                filters: None,
                session_id: Some("s1".to_owned()),
                workspace_id: None,
            },
        )]))),
        CancellationToken::new(),
    );
    let ack_task = tokio::spawn(async move {
        session
            .handle_text(r#"{"type":"ack","id":"ack-1","subscriptionId":"sub-ack","cursor":42}"#)
            .await
    });

    tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    assert!(
        !ack_task.is_finished(),
        "ack responses should wait for outbound capacity instead of closing the socket"
    );

    assert_eq!(rx.recv().await.as_deref(), Some("occupied"));
    assert!(ack_task.await.unwrap());
    let response = tokio::time::timeout(std::time::Duration::from_secs(1), rx.recv())
        .await
        .unwrap()
        .unwrap();
    let value: Value = serde_json::from_str(&response).unwrap();
    assert_eq!(value.get("ok").and_then(Value::as_bool), Some(true));
    assert_eq!(
        value.pointer("/result/cursor").and_then(Value::as_u64),
        Some(42)
    );
}

#[tokio::test]
async fn push_subscription_advances_past_filtered_stream_pages() {
    let ctx = Arc::new(make_test_context());
    let target_session = "session-target";
    let other_session = "session-other";

    for index in 0..(STREAM_MAX_LIMIT + 1) {
        ctx.engine_host
            .publish_stream_event(PublishStreamEvent {
                topic: "events.session".to_owned(),
                payload: json!({
                    "serverEvent": ServerEventPayload::new(
                        "agent.delta",
                        Some(other_session.to_owned()),
                        Some(json!({"index": index}))
                    )
                }),
                visibility: VisibilityScope::System,
                session_id: None,
                workspace_id: None,
                producer: "test".to_owned(),
                trace_id: None,
                parent_invocation_id: None,
            })
            .await
            .unwrap();
    }
    let target_cursor = ctx
        .engine_host
        .publish_stream_event(PublishStreamEvent {
            topic: "events.session".to_owned(),
            payload: json!({
                "serverEvent": ServerEventPayload::new(
                    "agent.ready",
                    Some(target_session.to_owned()),
                    Some(json!({"ready": true}))
                )
            }),
            visibility: VisibilityScope::Session,
            session_id: Some(target_session.to_owned()),
            workspace_id: None,
            producer: "test".to_owned(),
            trace_id: None,
            parent_invocation_id: None,
        })
        .await
        .unwrap();

    let subscription_id = "sub-target".to_owned();
    ctx.engine_host
        .subscribe_stream(
            subscription_id.clone(),
            "events.session".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some(target_session.to_owned()),
            None,
        )
        .await
        .unwrap();
    let subscriptions = Arc::new(tokio::sync::Mutex::new(BTreeMap::from([(
        subscription_id.clone(),
        SubscriptionState {
            topic: "events.session".to_owned(),
            cursor: StreamCursor(0),
            filters: Some(json!({"sessionId": target_session})),
            session_id: Some(target_session.to_owned()),
            workspace_id: None,
        },
    )])));
    let (out_tx, mut out_rx) = mpsc::channel(OUTBOUND_QUEUE_CAPACITY);
    let cancel = CancellationToken::new();
    let push_task = tokio::spawn(push_subscription_events(
        ctx,
        out_tx,
        subscriptions.clone(),
        cancel.clone(),
    ));

    let delivered = tokio::time::timeout(std::time::Duration::from_secs(2), async {
        while let Some(message) = out_rx.recv().await {
            let value: Value = serde_json::from_str(&message).unwrap();
            if value.get("type").and_then(Value::as_str) == Some("event") {
                return value;
            }
        }
        panic!("stream push task closed before delivering target event");
    })
    .await
    .expect("filtered stream pages should not starve later matching events");

    cancel.cancel();
    push_task.await.unwrap();

    assert_eq!(
        delivered
            .pointer("/event/sessionId")
            .and_then(Value::as_str),
        Some(target_session)
    );
    assert_eq!(
        delivered.pointer("/event/type").and_then(Value::as_str),
        Some("agent.ready")
    );
    assert_eq!(
        delivered
            .pointer("/event/streamCursor")
            .and_then(Value::as_u64)
            .map(StreamCursor),
        Some(target_cursor)
    );
    let cursor = subscriptions
        .lock()
        .await
        .get(&subscription_id)
        .unwrap()
        .cursor;
    assert!(
        cursor >= target_cursor,
        "subscription cursor should advance to at least the delivered target cursor"
    );
}

#[tokio::test]
async fn push_subscription_applies_backpressure_to_catch_up_bursts() {
    let ctx = Arc::new(make_test_context());
    let target_session = "session-burst";
    let total_events = OUTBOUND_QUEUE_CAPACITY + 24;

    for index in 0..total_events {
        ctx.engine_host
            .publish_stream_event(PublishStreamEvent {
                topic: "events.session".to_owned(),
                payload: json!({
                    "serverEvent": ServerEventPayload::new(
                        "agent.text_delta",
                        Some(target_session.to_owned()),
                        Some(json!({"delta": index.to_string()}))
                    )
                }),
                visibility: VisibilityScope::Session,
                session_id: Some(target_session.to_owned()),
                workspace_id: None,
                producer: "test".to_owned(),
                trace_id: None,
                parent_invocation_id: None,
            })
            .await
            .unwrap();
    }

    let subscription_id = "sub-burst".to_owned();
    ctx.engine_host
        .subscribe_stream(
            subscription_id.clone(),
            "events.session".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some(target_session.to_owned()),
            None,
        )
        .await
        .unwrap();
    let subscriptions = Arc::new(tokio::sync::Mutex::new(BTreeMap::from([(
        subscription_id,
        SubscriptionState {
            topic: "events.session".to_owned(),
            cursor: StreamCursor(0),
            filters: Some(json!({"sessionId": target_session})),
            session_id: Some(target_session.to_owned()),
            workspace_id: None,
        },
    )])));
    let (out_tx, mut out_rx) = mpsc::channel(OUTBOUND_QUEUE_CAPACITY);
    let cancel = CancellationToken::new();
    let push_task = tokio::spawn(push_subscription_events(
        ctx,
        out_tx,
        subscriptions,
        cancel.clone(),
    ));

    tokio::time::sleep(PUSH_POLL_INTERVAL * 2).await;
    assert!(
        !cancel.is_cancelled(),
        "catch-up bursts must apply channel backpressure instead of closing the socket"
    );

    let mut delivered = 0usize;
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        while delivered < total_events {
            let message = out_rx.recv().await.expect("push stream should stay open");
            let value: Value = serde_json::from_str(&message).unwrap();
            if value.get("type").and_then(Value::as_str) == Some("event") {
                delivered += 1;
            }
        }
    })
    .await
    .expect("backpressured catch-up burst should drain completely");

    cancel.cancel();
    push_task.await.unwrap();
    assert_eq!(delivered, total_events);
}
