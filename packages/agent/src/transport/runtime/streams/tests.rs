use super::*;
use crate::engine::{EngineHostHandle, StreamActorScope, StreamCursor, VisibilityScope};
use crate::shared::protocol::events::{BaseEvent, TronEvent, agent_start_event};

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
fn tron_event_projection_preserves_engine_trace_context() {
    let event = TronEvent::MessageUpdate {
        base: BaseEvent::now("s1")
            .with_trace_context(Some("trace-1".to_owned()), Some("invocation-1".to_owned())),
        content: "hello world".into(),
    };

    let projected = tron_event_to_projected(&event);

    assert_eq!(projected.server_event.trace_id.as_deref(), Some("trace-1"));
    assert_eq!(
        projected.server_event.parent_invocation_id.as_deref(),
        Some("invocation-1")
    );
}

#[test]
fn agent_complete_projects_to_idle_lifecycle_phase() {
    let event = TronEvent::AgentEnd {
        base: BaseEvent::now("s1"),
        error: None,
    };

    let projected = tron_event_to_projected(&event);

    assert_eq!(projected.server_event.event_type, "agent.complete");
    assert_eq!(projected.server_event.data.unwrap()["agentPhase"], "idle");
}

#[test]
fn all_session_events_project_to_system_visible_stream_scope() {
    let event = TronEvent::SessionCreated {
        base: BaseEvent::now("session-a"),
        model: "claude-opus-4-6".to_owned(),
        working_directory: "/tmp".to_owned(),
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
    let cancel = CancellationToken::new();
    let pump = EngineStreamEventPump::new(rx, host.clone(), cancel.clone());
    let handle = tokio::spawn(pump.run());

    tx.send(agent_start_event("s1")).unwrap();
    let page = poll_until_event(&host, Some("s1")).await;
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
async fn pump_persists_runtime_event_trace_context() {
    let (tx, rx) = broadcast::channel(8);
    let host = EngineHostHandle::new_in_memory().unwrap();
    let cancel = CancellationToken::new();
    let pump = EngineStreamEventPump::new(rx, host.clone(), cancel.clone());
    let handle = tokio::spawn(pump.run());

    tx.send(TronEvent::MessageUpdate {
        base: BaseEvent::now("s1")
            .with_trace_context(Some("trace-1".to_owned()), Some("invocation-1".to_owned())),
        content: "hello".to_owned(),
    })
    .unwrap();
    let page = poll_until_event(&host, Some("s1")).await;
    cancel.cancel();
    let _ = handle.await;

    let event = &page.events[0];
    assert_eq!(
        event.trace_id.as_ref().map(ToString::to_string),
        Some("trace-1".to_owned())
    );
    assert_eq!(
        event.parent_invocation_id.as_ref().map(ToString::to_string),
        Some("invocation-1".to_owned())
    );
    assert_eq!(event.payload["serverEvent"]["traceId"], "trace-1");
    assert_eq!(
        event.payload["serverEvent"]["parentInvocationId"],
        "invocation-1"
    );
}

#[tokio::test]
async fn lag_beyond_source_capacity_publishes_recovery_marker() {
    let (tx, rx) = broadcast::channel(2);
    let host = EngineHostHandle::new_in_memory().unwrap();
    let mut pump = EngineStreamEventPump::new(rx, host.clone(), CancellationToken::new());

    for _ in 0..5 {
        tx.send(agent_start_event("s1")).unwrap();
    }
    let lagged = pump.rx.recv().await;
    assert!(matches!(
        &lagged,
        Err(broadcast::error::RecvError::Lagged(3))
    ));
    assert!(pump.handle_tron_recv(lagged).await);

    let page = poll_until_event(&host, None).await;
    assert_eq!(page.events.len(), 1);
    let event = &page.events[0];
    assert_eq!(
        event.payload["serverEvent"]["type"],
        "stream.recovery_required"
    );
    assert_eq!(event.payload["serverEvent"]["data"]["reason"], "source_lag");
    assert_eq!(event.payload["serverEvent"]["data"]["droppedEventCount"], 3);
    assert_eq!(event.payload["streamScope"]["kind"], "all");
    assert_eq!(event.visibility, VisibilityScope::System);
}

#[tokio::test]
async fn stream_scope_prevents_cross_session_delivery() {
    let (tx, rx) = broadcast::channel(8);
    let host = EngineHostHandle::new_in_memory().unwrap();
    let cancel = CancellationToken::new();
    let pump = EngineStreamEventPump::new(rx, host.clone(), cancel.clone());
    let handle = tokio::spawn(pump.run());

    tx.send(agent_start_event("s2")).unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    let page = host
        .poll_stream_topic(
            "events.session",
            StreamCursor(0),
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
    session_id: Option<&str>,
) -> crate::engine::EngineStreamPage {
    let actor = StreamActorScope::scoped(session_id.map(ToOwned::to_owned), None);
    for _ in 0..20 {
        let page = host
            .poll_stream_topic("events.session", StreamCursor(0), 10, &actor)
            .await
            .unwrap();
        if !page.events.is_empty() {
            return page;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    panic!("timed out waiting for runtime stream event");
}
