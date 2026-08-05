use super::*;

async fn assert_topic_poll_reaches_visible_event_after_invisible_prefix(handle: EngineHostHandle) {
    let target_session = "session-visible";
    for index in 0..4 {
        handle
            .publish_stream_event(PublishStreamEvent {
                topic: "events.session".to_owned(),
                payload: json!({"visible": false, "index": index}),
                visibility: StreamVisibility::Session,
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
        .publish_stream_event(PublishStreamEvent {
            topic: "events.session".to_owned(),
            payload: json!({"visible": true}),
            visibility: StreamVisibility::Session,
            session_id: Some(target_session.to_owned()),
            workspace_id: None,
            producer: "test".to_owned(),
            trace_id: None,
            parent_invocation_id: None,
        })
        .await
        .unwrap();

    let actor = StreamActorScope::scoped(Some(target_session.to_owned()));
    let mut after = StreamCursor(0);
    for _ in 0..4 {
        let page = handle
            .poll_stream_topic("events.session", after, 2, &actor)
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
            "empty stream pages must advance past invisible rows"
        );
        after = page.next_cursor;
    }
    panic!("topic poll did not reach visible event after invisible prefix");
}

#[tokio::test]
async fn topic_poll_advances_past_invisible_rows_in_memory() {
    assert_topic_poll_reaches_visible_event_after_invisible_prefix(
        EngineHostHandle::new_in_memory().unwrap(),
    )
    .await;
}

#[tokio::test]
async fn topic_poll_advances_past_invisible_rows_in_sqlite() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("tron.sqlite");
    assert_topic_poll_reaches_visible_event_after_invisible_prefix(
        EngineHostHandle::open_sqlite(&path).unwrap(),
    )
    .await;
}

#[test]
fn sqlite_stream_hot_paths_are_cursor_indexed() {
    let dir = tempfile::tempdir().unwrap();
    let store = SqliteEngineStreamStore::open(dir.path().join("tron.sqlite")).unwrap();

    let latest_cursor_plan = store
        .connection()
        .query_row(
            "EXPLAIN QUERY PLAN
             SELECT COALESCE(MAX(cursor), 0)
             FROM engine_stream_events
             WHERE topic = 'events.session'",
            [],
            |row| row.get::<_, String>(3),
        )
        .unwrap();
    assert!(
        latest_cursor_plan.contains("idx_engine_stream_events_topic_cursor"),
        "latest topic cursor must use its bounded index: {latest_cursor_plan}"
    );

    let session_replay_plan = store
        .connection()
        .query_row(
            "EXPLAIN QUERY PLAN
             SELECT cursor
             FROM engine_stream_events
             WHERE session_id = 'session-a'
             ORDER BY cursor ASC",
            [],
            |row| row.get::<_, String>(3),
        )
        .unwrap();
    assert!(
        session_replay_plan.contains("idx_engine_stream_events_session_cursor"),
        "session replay must use its bounded index: {session_replay_plan}"
    );
}
