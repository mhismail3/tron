use super::*;

#[test]
fn insert_and_get() {
    let conn = setup();
    let event = make_event("evt_1", 1, EventType::SessionStart, None, json!({}));
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    assert_eq!(row.id, "evt_1");
    assert_eq!(row.session_id, "sess_1");
    assert_eq!(row.sequence, 1);
    assert_eq!(row.depth, 0);
    assert_eq!(row.event_type, "session.start");
}

#[test]
fn insert_extracts_role() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::MessageUser,
        None,
        json!({"content": "hi"}),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    assert_eq!(row.role.as_deref(), Some("user"));
}

#[test]
fn insert_extracts_model_primitive_name() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::CapabilityInvocationStarted,
        None,
        json!({"modelPrimitiveName": "execute", "invocationId": "tc_1"}),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    assert_eq!(row.model_primitive_name.as_deref(), Some("execute"));
    assert_eq!(row.invocation_id.as_deref(), Some("tc_1"));
}

#[test]
fn insert_extracts_tokens() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::MessageAssistant,
        None,
        json!({
            "content": "hello",
            "tokenUsage": {
                "inputTokens": 100,
                "outputTokens": 50,
                "cacheReadTokens": 25
            }
        }),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    assert_eq!(row.input_tokens, Some(100));
    assert_eq!(row.output_tokens, Some(50));
    assert_eq!(row.cache_read_tokens, Some(25));
}

#[test]
fn insert_computes_depth() {
    let conn = setup();
    let e1 = make_event("evt_1", 1, EventType::SessionStart, None, json!({}));
    let e2 = make_event("evt_2", 2, EventType::MessageUser, Some("evt_1"), json!({}));
    let e3 = make_event(
        "evt_3",
        3,
        EventType::MessageAssistant,
        Some("evt_2"),
        json!({}),
    );

    EventRepo::insert(&conn, &e1).unwrap();
    EventRepo::insert(&conn, &e2).unwrap();
    EventRepo::insert(&conn, &e3).unwrap();

    assert_eq!(
        EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap().depth,
        0
    );
    assert_eq!(
        EventRepo::get_by_id(&conn, "evt_2").unwrap().unwrap().depth,
        1
    );
    assert_eq!(
        EventRepo::get_by_id(&conn, "evt_3").unwrap().unwrap().depth,
        2
    );
}

#[test]
fn get_by_session() {
    let conn = setup();
    for i in 1..=5 {
        let parent = format!("evt_{}", i - 1);
        let event = make_event(
            &format!("evt_{i}"),
            i,
            EventType::MessageUser,
            if i == 1 { None } else { Some(parent.as_str()) },
            json!({}),
        );
        EventRepo::insert(&conn, &event).unwrap();
    }

    let events = EventRepo::get_by_session(&conn, "sess_1", &ListEventsOptions::default()).unwrap();
    assert_eq!(events.len(), 5);
    assert_eq!(events[0].sequence, 1);
    assert_eq!(events[4].sequence, 5);
}

#[test]
fn get_by_session_with_limit() {
    let conn = setup();
    for i in 1..=5 {
        let event = make_event(
            &format!("evt_{i}"),
            i,
            EventType::MessageUser,
            None,
            json!({}),
        );
        EventRepo::insert(&conn, &event).unwrap();
    }

    let events = EventRepo::get_by_session(
        &conn,
        "sess_1",
        &ListEventsOptions {
            limit: Some(3),
            offset: None,
        },
    )
    .unwrap();
    assert_eq!(events.len(), 3);
}

#[test]
fn get_ancestors_chain() {
    let conn = setup();
    let e1 = make_event("evt_1", 1, EventType::SessionStart, None, json!({}));
    let e2 = make_event("evt_2", 2, EventType::MessageUser, Some("evt_1"), json!({}));
    let e3 = make_event(
        "evt_3",
        3,
        EventType::MessageAssistant,
        Some("evt_2"),
        json!({}),
    );
    let e4 = make_event(
        "evt_4",
        4,
        EventType::CapabilityInvocationStarted,
        Some("evt_3"),
        json!({}),
    );
    let e5 = make_event(
        "evt_5",
        5,
        EventType::CapabilityInvocationCompleted,
        Some("evt_4"),
        json!({}),
    );

    EventRepo::insert(&conn, &e1).unwrap();
    EventRepo::insert(&conn, &e2).unwrap();
    EventRepo::insert(&conn, &e3).unwrap();
    EventRepo::insert(&conn, &e4).unwrap();
    EventRepo::insert(&conn, &e5).unwrap();

    let ancestors = EventRepo::get_ancestors(&conn, "evt_5").unwrap();
    assert_eq!(ancestors.len(), 5);
    assert_eq!(ancestors[0].id, "evt_1");
    assert_eq!(ancestors[4].id, "evt_5");
}

#[test]
fn get_ancestors_root_only() {
    let conn = setup();
    let e1 = make_event("evt_1", 1, EventType::SessionStart, None, json!({}));
    EventRepo::insert(&conn, &e1).unwrap();

    let ancestors = EventRepo::get_ancestors(&conn, "evt_1").unwrap();
    assert_eq!(ancestors.len(), 1);
    assert_eq!(ancestors[0].id, "evt_1");
}

#[test]
fn get_children() {
    let conn = setup();
    let e1 = make_event("evt_1", 1, EventType::SessionStart, None, json!({}));
    let e2 = make_event("evt_2", 2, EventType::MessageUser, Some("evt_1"), json!({}));
    let e3 = make_event(
        "evt_3",
        3,
        EventType::MessageAssistant,
        Some("evt_1"),
        json!({}),
    );

    EventRepo::insert(&conn, &e1).unwrap();
    EventRepo::insert(&conn, &e2).unwrap();
    EventRepo::insert(&conn, &e3).unwrap();

    let children = EventRepo::get_children(&conn, "evt_1").unwrap();
    assert_eq!(children.len(), 2);
}

#[test]
fn get_descendants() {
    let conn = setup();
    let e1 = make_event("evt_1", 1, EventType::SessionStart, None, json!({}));
    let e2 = make_event("evt_2", 2, EventType::MessageUser, Some("evt_1"), json!({}));
    let e3 = make_event(
        "evt_3",
        3,
        EventType::MessageAssistant,
        Some("evt_2"),
        json!({}),
    );

    EventRepo::insert(&conn, &e1).unwrap();
    EventRepo::insert(&conn, &e2).unwrap();
    EventRepo::insert(&conn, &e3).unwrap();

    let desc = EventRepo::get_descendants(&conn, "evt_1").unwrap();
    assert_eq!(desc.len(), 2); // evt_2 and evt_3, not evt_1 itself
}

#[test]
fn get_since() {
    let conn = setup();
    for i in 1..=5 {
        let event = make_event(
            &format!("evt_{i}"),
            i,
            EventType::MessageUser,
            None,
            json!({}),
        );
        EventRepo::insert(&conn, &event).unwrap();
    }

    let events = EventRepo::get_since(&conn, "sess_1", 3).unwrap();
    assert_eq!(events.len(), 2);
    assert_eq!(events[0].sequence, 4);
    assert_eq!(events[1].sequence, 5);
}

#[test]
fn get_latest() {
    let conn = setup();
    for i in 1..=3 {
        let event = make_event(
            &format!("evt_{i}"),
            i,
            EventType::MessageUser,
            None,
            json!({}),
        );
        EventRepo::insert(&conn, &event).unwrap();
    }

    let latest = EventRepo::get_latest(&conn, "sess_1").unwrap().unwrap();
    assert_eq!(latest.sequence, 3);
}

#[test]
fn get_latest_empty() {
    let conn = setup();
    let latest = EventRepo::get_latest(&conn, "sess_1").unwrap();
    assert!(latest.is_none());
}

#[test]
fn count_by_session() {
    let conn = setup();
    assert_eq!(EventRepo::count_by_session(&conn, "sess_1").unwrap(), 0);

    for i in 1..=3 {
        let event = make_event(
            &format!("evt_{i}"),
            i,
            EventType::MessageUser,
            None,
            json!({}),
        );
        EventRepo::insert(&conn, &event).unwrap();
    }
    assert_eq!(EventRepo::count_by_session(&conn, "sess_1").unwrap(), 3);
}

#[test]
fn count_by_type() {
    let conn = setup();
    EventRepo::insert(
        &conn,
        &make_event("evt_1", 1, EventType::MessageUser, None, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event("evt_2", 2, EventType::MessageAssistant, None, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event("evt_3", 3, EventType::MessageUser, None, json!({})),
    )
    .unwrap();

    assert_eq!(
        EventRepo::count_by_type(&conn, "sess_1", "message.user").unwrap(),
        2
    );
    assert_eq!(
        EventRepo::count_by_type(&conn, "sess_1", "message.assistant").unwrap(),
        1
    );
}

#[test]
fn exists_event() {
    let conn = setup();
    EventRepo::insert(
        &conn,
        &make_event("evt_1", 1, EventType::SessionStart, None, json!({})),
    )
    .unwrap();

    assert!(EventRepo::exists(&conn, "evt_1").unwrap());
    assert!(!EventRepo::exists(&conn, "evt_nonexistent").unwrap());
}

#[test]
fn delete_event() {
    let conn = setup();
    EventRepo::insert(
        &conn,
        &make_event("evt_1", 1, EventType::SessionStart, None, json!({})),
    )
    .unwrap();

    assert!(EventRepo::delete(&conn, "evt_1").unwrap());
    assert!(!EventRepo::exists(&conn, "evt_1").unwrap());
}

#[test]
fn delete_by_session() {
    let conn = setup();
    for i in 1..=3 {
        let event = make_event(
            &format!("evt_{i}"),
            i,
            EventType::MessageUser,
            None,
            json!({}),
        );
        EventRepo::insert(&conn, &event).unwrap();
    }

    let deleted = EventRepo::delete_by_session(&conn, "sess_1").unwrap();
    assert_eq!(deleted, 3);
    assert_eq!(EventRepo::count_by_session(&conn, "sess_1").unwrap(), 0);
}

#[test]
fn token_usage_summary() {
    let conn = setup();
    EventRepo::insert(
        &conn,
        &make_event(
            "evt_1",
            1,
            EventType::MessageAssistant,
            None,
            json!({
                "tokenUsage": {"inputTokens": 100, "outputTokens": 50, "cacheReadTokens": 20}
            }),
        ),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event(
            "evt_2",
            2,
            EventType::MessageAssistant,
            None,
            json!({
                "tokenUsage": {"inputTokens": 200, "outputTokens": 100}
            }),
        ),
    )
    .unwrap();

    let summary = EventRepo::get_token_usage_summary(&conn, "sess_1").unwrap();
    assert_eq!(summary.input_tokens, 300);
    assert_eq!(summary.output_tokens, 150);
    assert_eq!(summary.cache_read_tokens, 20);
}

#[test]
fn token_usage_summary_empty() {
    let conn = setup();
    let summary = EventRepo::get_token_usage_summary(&conn, "sess_1").unwrap();
    assert_eq!(summary.input_tokens, 0);
    assert_eq!(summary.output_tokens, 0);
}

// ── Batch operations ─────────────────────────────────────────────

#[test]
fn get_by_ids_basic() {
    let conn = setup();
    EventRepo::insert(
        &conn,
        &make_event("evt_1", 1, EventType::MessageUser, None, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event("evt_2", 2, EventType::MessageAssistant, None, json!({})),
    )
    .unwrap();

    let ids = ["evt_1", "evt_2"];
    let map = EventRepo::get_by_ids(&conn, &ids).unwrap();
    assert_eq!(map.len(), 2);
    assert!(map.contains_key("evt_1"));
    assert!(map.contains_key("evt_2"));
}

#[test]
fn get_by_ids_empty() {
    let conn = setup();
    let map = EventRepo::get_by_ids(&conn, &[]).unwrap();
    assert!(map.is_empty());
}

#[test]
fn get_by_ids_missing_omitted() {
    let conn = setup();
    EventRepo::insert(
        &conn,
        &make_event("evt_1", 1, EventType::MessageUser, None, json!({})),
    )
    .unwrap();

    let ids = ["evt_1", "evt_nonexistent"];
    let map = EventRepo::get_by_ids(&conn, &ids).unwrap();
    assert_eq!(map.len(), 1);
}
