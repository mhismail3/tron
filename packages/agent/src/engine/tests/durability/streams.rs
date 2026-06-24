use super::*;

#[tokio::test]
async fn stream_primitive_subscribe_poll_and_unsubscribe_are_scoped() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let subscribe = handle
        .invoke(host_invocation(
            "stream::subscribe",
            json!({
                "subscriptionId": "sub-a",
                "topic": "events.session",
                "sessionId": "session-a"
            }),
            mutating_causal("stream-subscribe").with_scope("stream.write"),
        ))
        .await;
    assert_eq!(subscribe.error, None);
    assert_eq!(subscribe.value.as_ref().unwrap()["subscriptionId"], "sub-a");

    handle
        .publish_stream_event(super::PublishStreamEvent {
            topic: "events.session".to_owned(),
            payload: json!({"visible": true}),
            visibility: VisibilityScope::Session,
            session_id: Some("session-a".to_owned()),
            workspace_id: None,
            producer: "test".to_owned(),
            trace_id: Some(trace("stream-trace")),
            parent_invocation_id: None,
        })
        .await
        .unwrap();
    handle
        .publish_stream_event(super::PublishStreamEvent {
            topic: "events.session".to_owned(),
            payload: json!({"visible": false}),
            visibility: VisibilityScope::Session,
            session_id: Some("session-b".to_owned()),
            workspace_id: None,
            producer: "test".to_owned(),
            trace_id: Some(trace("stream-trace")),
            parent_invocation_id: None,
        })
        .await
        .unwrap();

    let poll = handle
        .invoke(host_invocation(
            "stream::poll",
            json!({"subscriptionId": "sub-a", "limit": 10}),
            causal()
                .with_scope("stream.read")
                .with_session_id("session-a"),
        ))
        .await;
    assert_eq!(poll.error, None);
    let events = poll.value.as_ref().unwrap()["events"].as_array().unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["payload"], json!({"visible": true}));

    let hidden = handle
        .poll_stream(
            "sub-a",
            Some(StreamCursor(0)),
            10,
            &StreamActorScope::scoped(Some("session-b".to_owned()), None),
        )
        .await;
    assert!(matches!(
        hidden,
        Err(EngineError::PolicyViolation(message)) if message.contains("not visible")
    ));

    let unsubscribe = handle
        .invoke(host_invocation(
            "stream::unsubscribe",
            json!({"subscriptionId": "sub-a"}),
            mutating_causal("stream-unsubscribe").with_scope("stream.write"),
        ))
        .await;
    assert_eq!(unsubscribe.error, None);
    assert_eq!(unsubscribe.value.as_ref().unwrap()["unsubscribed"], true);
}

#[tokio::test]
async fn stream_primitive_subscribe_without_after_cursor_starts_at_topic_tail() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let old_cursor = handle
        .publish_stream_event(super::PublishStreamEvent {
            topic: "events.session".to_owned(),
            payload: json!({"old": true}),
            visibility: VisibilityScope::Session,
            session_id: Some("session-a".to_owned()),
            workspace_id: None,
            producer: "test".to_owned(),
            trace_id: Some(trace("stream-tail-trace")),
            parent_invocation_id: None,
        })
        .await
        .unwrap();

    let subscribe = handle
        .invoke(host_invocation(
            "stream::subscribe",
            json!({
                "subscriptionId": "sub-tail",
                "topic": "events.session",
                "sessionId": "session-a"
            }),
            mutating_causal("stream-subscribe-tail").with_scope("stream.write"),
        ))
        .await;
    assert_eq!(subscribe.error, None);
    assert_eq!(subscribe.value.as_ref().unwrap()["cursor"], old_cursor.0);

    handle
        .publish_stream_event(super::PublishStreamEvent {
            topic: "events.session".to_owned(),
            payload: json!({"new": true}),
            visibility: VisibilityScope::Session,
            session_id: Some("session-a".to_owned()),
            workspace_id: None,
            producer: "test".to_owned(),
            trace_id: Some(trace("stream-tail-trace")),
            parent_invocation_id: None,
        })
        .await
        .unwrap();

    let poll = handle
        .invoke(host_invocation(
            "stream::poll",
            json!({"subscriptionId": "sub-tail", "limit": 10}),
            causal()
                .with_scope("stream.read")
                .with_session_id("session-a"),
        ))
        .await;
    assert_eq!(poll.error, None);
    let events = poll.value.as_ref().unwrap()["events"].as_array().unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["payload"], json!({"new": true}));
}

async fn assert_stream_poll_reaches_visible_event_after_invisible_prefix(handle: EngineHostHandle) {
    let target_session = "session-visible";
    for index in 0..4 {
        handle
            .publish_stream_event(super::PublishStreamEvent {
                topic: "events.session".to_owned(),
                payload: json!({"visible": false, "index": index}),
                visibility: VisibilityScope::Session,
                session_id: Some("session-hidden".to_owned()),
                workspace_id: None,
                producer: "test".to_owned(),
                trace_id: None,
                parent_invocation_id: None,
            })
            .await
            .unwrap();
    }
    let target_cursor = handle
        .publish_stream_event(super::PublishStreamEvent {
            topic: "events.session".to_owned(),
            payload: json!({"visible": true}),
            visibility: VisibilityScope::Session,
            session_id: Some(target_session.to_owned()),
            workspace_id: None,
            producer: "test".to_owned(),
            trace_id: None,
            parent_invocation_id: None,
        })
        .await
        .unwrap();

    handle
        .subscribe_stream(
            "sub-visible".to_owned(),
            "events.session".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some(target_session.to_owned()),
            None,
        )
        .await
        .unwrap();
    let actor = StreamActorScope::scoped(Some(target_session.to_owned()), None);
    let mut after = StreamCursor(0);
    for _ in 0..4 {
        let page = handle
            .poll_stream("sub-visible", Some(after), 2, &actor)
            .await
            .unwrap();
        if let Some(event) = page.events.first() {
            assert_eq!(event.cursor, target_cursor);
            assert_eq!(event.payload, json!({"visible": true}));
            assert!(page.next_cursor >= target_cursor);
            return;
        }
        assert!(
            page.next_cursor > after,
            "empty stream pages must still advance past visibility-filtered rows"
        );
        after = page.next_cursor;
    }
    panic!("stream poll did not reach visible event after invisible prefix");
}

#[tokio::test]
async fn stream_poll_advances_past_visibility_filtered_rows_in_memory() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    assert_stream_poll_reaches_visible_event_after_invisible_prefix(handle).await;
}

#[tokio::test]
async fn stream_poll_advances_past_visibility_filtered_rows_in_sqlite() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tron.sqlite");
    let handle = EngineHostHandle::open_sqlite(&path).unwrap();
    assert_stream_poll_reaches_visible_event_after_invisible_prefix(handle).await;
}
