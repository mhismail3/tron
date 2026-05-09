use super::*;
use crate::engine::{EngineHostHandle, StreamActorScope, StreamCursor, VisibilityScope};
use crate::shared::events::{BaseEvent, TronEvent, agent_start_event};

#[test]
fn tron_events_project_to_neutral_server_payloads() {
    let event = TronEvent::MessageUpdate {
        base: BaseEvent::now("s1"),
        content: "hello world".into(),
    };

    let projected = tron_event_to_projected(&event);

    assert_eq!(projected.server_event.event_type, "agent.text_delta");
    assert_eq!(projected.server_event.session_id.as_deref(), Some("s1"));
    assert_eq!(projected.server_event.data.unwrap()["delta"], "hello world");
    assert_eq!(projected.scope, StreamScope::Session("s1".to_owned()));
}

#[test]
fn all_session_events_project_to_system_visible_stream_scope() {
    let event = TronEvent::SessionCreated {
        base: BaseEvent::now("session-a"),
        model: "claude-opus-4-6".to_owned(),
        working_directory: "/tmp".to_owned(),
        source: None,
        profile: None,
        title: None,
    };

    let projected = tron_event_to_projected(&event);

    assert_eq!(projected.server_event.event_type, "session.created");
    assert_eq!(projected.scope, StreamScope::All);
    assert_eq!(stream_scope_payload(&projected.scope)["kind"], "all");
}

#[tokio::test]
async fn pump_publishes_runtime_events_to_engine_streams_once() {
    let (tx, rx) = broadcast::channel(8);
    let host = EngineHostHandle::new_in_memory().unwrap();
    host.subscribe_stream(
        "runtime-events".to_owned(),
        "events.session".to_owned(),
        StreamCursor(0),
        VisibilityScope::Session,
        Some("s1".to_owned()),
        None,
    )
    .await
    .unwrap();
    let cancel = CancellationToken::new();
    let pump = EngineStreamEventPump::new(
        rx,
        host.clone(),
        cancel.clone(),
        Arc::new(TurnAccumulatorMap::new()),
    );
    let handle = tokio::spawn(pump.run());

    tx.send(agent_start_event("s1")).unwrap();
    let page = poll_until_event(&host, "runtime-events", Some("s1")).await;
    cancel.cancel();
    let _ = handle.await;

    assert_eq!(page.events.len(), 1);
    let event = &page.events[0];
    assert_eq!(event.topic, "events.session");
    assert_eq!(event.visibility, VisibilityScope::Session);
    assert_eq!(event.session_id.as_deref(), Some("s1"));
    assert_eq!(event.payload["serverEvent"]["type"], "agent.start");
    assert_eq!(event.payload["streamScope"]["kind"], "session");
}

#[tokio::test]
async fn stream_scope_prevents_cross_session_delivery() {
    let (tx, rx) = broadcast::channel(8);
    let host = EngineHostHandle::new_in_memory().unwrap();
    host.subscribe_stream(
        "session-a".to_owned(),
        "events.session".to_owned(),
        StreamCursor(0),
        VisibilityScope::Session,
        Some("s1".to_owned()),
        None,
    )
    .await
    .unwrap();
    let cancel = CancellationToken::new();
    let pump = EngineStreamEventPump::new(
        rx,
        host.clone(),
        cancel.clone(),
        Arc::new(TurnAccumulatorMap::new()),
    );
    let handle = tokio::spawn(pump.run());

    tx.send(agent_start_event("s2")).unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    let page = host
        .poll_stream(
            "session-a",
            Some(StreamCursor(0)),
            10,
            &StreamActorScope::scoped(Some("s1".to_owned()), None),
        )
        .await
        .unwrap();
    cancel.cancel();
    let _ = handle.await;

    assert!(page.events.is_empty());
}

async fn poll_until_event(
    host: &EngineHostHandle,
    subscription_id: &str,
    session_id: Option<&str>,
) -> crate::engine::EngineStreamPage {
    let actor = StreamActorScope::scoped(session_id.map(ToOwned::to_owned), None);
    for _ in 0..20 {
        let page = host
            .poll_stream(subscription_id, Some(StreamCursor(0)), 10, &actor)
            .await
            .unwrap();
        if !page.events.is_empty() {
            return page;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    panic!("timed out waiting for runtime stream event");
}
