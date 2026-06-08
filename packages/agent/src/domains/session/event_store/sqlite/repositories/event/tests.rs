use super::*;
use crate::domains::session::event_store::sqlite::migrations::run_migrations;
use crate::domains::session::event_store::types::EventType;
use crate::domains::session::event_store::types::SessionEvent;
use serde_json::Value;
use serde_json::json;

fn setup() -> Connection {
    let conn = Connection::open_in_memory().unwrap();
    conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
        .unwrap();
    run_migrations(&conn).unwrap();

    // Create workspace and session
    conn.execute(
        "INSERT INTO workspaces (id, path, created_at, last_activity_at)
         VALUES ('ws_1', '/tmp/test', datetime('now'), datetime('now'))",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
         VALUES ('sess_1', 'ws_1', 'claude-3', '/tmp/test', datetime('now'), datetime('now'))",
        [],
    )
    .unwrap();
    conn
}

fn make_event(
    id: &str,
    seq: i64,
    event_type: EventType,
    parent_id: Option<&str>,
    payload: Value,
) -> SessionEvent {
    SessionEvent {
        id: id.to_string(),
        parent_id: parent_id.map(String::from),
        session_id: "sess_1".to_string(),
        workspace_id: "ws_1".to_string(),
        timestamp: "2025-01-01T00:00:00Z".to_string(),
        event_type,
        sequence: seq,
        checksum: None,
        payload,
    }
}

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

// ── Type-filtered queries ────────────────────────────────────────

#[test]
fn get_by_types_basic() {
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
        &make_event(
            "evt_3",
            3,
            EventType::CapabilityInvocationStarted,
            None,
            json!({}),
        ),
    )
    .unwrap();

    let types = ["message.user", "message.assistant"];
    let results = EventRepo::get_by_types(&conn, "sess_1", &types, None).unwrap();
    assert_eq!(results.len(), 2);
}

#[test]
fn get_by_types_empty_types() {
    let conn = setup();
    let results = EventRepo::get_by_types(&conn, "sess_1", &[], None).unwrap();
    assert!(results.is_empty());
}

#[test]
fn get_by_types_with_limit() {
    let conn = setup();
    for i in 1..=5 {
        EventRepo::insert(
            &conn,
            &make_event(
                &format!("evt_{i}"),
                i,
                EventType::MessageUser,
                None,
                json!({}),
            ),
        )
        .unwrap();
    }

    let types = ["message.user"];
    let results = EventRepo::get_by_types(&conn, "sess_1", &types, Some(3)).unwrap();
    assert_eq!(results.len(), 3);
}

// ── Workspace-scoped queries ─────────────────────────────────────

#[test]
fn get_by_workspace_and_types_basic() {
    let conn = setup();
    EventRepo::insert(
        &conn,
        &make_event("evt_1", 1, EventType::MessageUser, None, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event(
            "evt_2",
            2,
            EventType::CapabilityInvocationStarted,
            None,
            json!({}),
        ),
    )
    .unwrap();

    let types = ["message.user"];
    let results = EventRepo::get_by_workspace_and_types(&conn, "ws_1", &types, None, None).unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].id, "evt_1");
}

#[test]
fn get_by_workspace_and_types_empty_types() {
    let conn = setup();
    let results = EventRepo::get_by_workspace_and_types(&conn, "ws_1", &[], None, None).unwrap();
    assert!(results.is_empty());
}

#[test]
fn get_by_workspace_and_types_with_limit_offset() {
    let conn = setup();
    for i in 1..=5 {
        EventRepo::insert(
            &conn,
            &make_event(
                &format!("evt_{i}"),
                i,
                EventType::MessageUser,
                None,
                json!({}),
            ),
        )
        .unwrap();
    }

    let types = ["message.user"];
    let results =
        EventRepo::get_by_workspace_and_types(&conn, "ws_1", &types, Some(2), Some(1)).unwrap();
    assert_eq!(results.len(), 2);
}

#[test]
fn count_by_workspace_and_types_basic() {
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
        &make_event(
            "evt_3",
            3,
            EventType::CapabilityInvocationStarted,
            None,
            json!({}),
        ),
    )
    .unwrap();

    let types = ["message.user", "message.assistant"];
    let count = EventRepo::count_by_workspace_and_types(&conn, "ws_1", &types).unwrap();
    assert_eq!(count, 2);
}

#[test]
fn count_by_workspace_and_types_empty_types() {
    let conn = setup();
    let count = EventRepo::count_by_workspace_and_types(&conn, "ws_1", &[]).unwrap();
    assert_eq!(count, 0);
}

// ── Multi-workspace queries ───────────────────────────────────

fn make_event_for_ws(
    id: &str,
    seq: i64,
    session_id: &str,
    workspace_id: &str,
    event_type: EventType,
    payload: Value,
) -> SessionEvent {
    SessionEvent {
        id: id.to_string(),
        parent_id: None,
        session_id: session_id.to_string(),
        workspace_id: workspace_id.to_string(),
        timestamp: "2025-01-01T00:00:00Z".to_string(),
        event_type,
        sequence: seq,
        checksum: None,
        payload,
    }
}

fn setup_multi_workspace(conn: &Connection) {
    conn.execute(
        "INSERT INTO workspaces (id, path, created_at, last_activity_at)
         VALUES ('ws_2', '/tmp/test2', datetime('now'), datetime('now'))",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
         VALUES ('sess_2', 'ws_2', 'claude-3', '/tmp/test2', datetime('now'), datetime('now'))",
        [],
    ).unwrap();
    conn.execute(
        "INSERT INTO workspaces (id, path, created_at, last_activity_at)
         VALUES ('ws_3', '/tmp/test3', datetime('now'), datetime('now'))",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
         VALUES ('sess_3', 'ws_3', 'claude-3', '/tmp/test3', datetime('now'), datetime('now'))",
        [],
    ).unwrap();
}

#[test]
fn get_by_workspaces_and_types_basic() {
    let conn = setup();
    setup_multi_workspace(&conn);
    EventRepo::insert(
        &conn,
        &make_event_for_ws("e1", 1, "sess_1", "ws_1", EventType::MessageUser, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event_for_ws("e2", 1, "sess_2", "ws_2", EventType::MessageUser, json!({})),
    )
    .unwrap();

    let results = EventRepo::get_by_workspaces_and_types(
        &conn,
        &["ws_1", "ws_2"],
        &["message.user"],
        None,
        None,
    )
    .unwrap();
    assert_eq!(results.len(), 2);
}

#[test]
fn get_by_workspaces_and_types_excludes_others() {
    let conn = setup();
    setup_multi_workspace(&conn);
    EventRepo::insert(
        &conn,
        &make_event_for_ws("e1", 1, "sess_1", "ws_1", EventType::MessageUser, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event_for_ws("e2", 1, "sess_2", "ws_2", EventType::MessageUser, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event_for_ws("e3", 1, "sess_3", "ws_3", EventType::MessageUser, json!({})),
    )
    .unwrap();

    let results = EventRepo::get_by_workspaces_and_types(
        &conn,
        &["ws_1", "ws_2"],
        &["message.user"],
        None,
        None,
    )
    .unwrap();
    assert_eq!(results.len(), 2);
    let ids: Vec<&str> = results.iter().map(|r| r.id.as_str()).collect();
    assert!(!ids.contains(&"e3"));
}

#[test]
fn get_by_workspaces_and_types_empty_ids() {
    let conn = setup();
    let results =
        EventRepo::get_by_workspaces_and_types(&conn, &[], &["message.user"], None, None).unwrap();
    assert!(results.is_empty());
}

#[test]
fn get_by_workspaces_and_types_limit_offset() {
    let conn = setup();
    setup_multi_workspace(&conn);
    EventRepo::insert(
        &conn,
        &make_event_for_ws("e1", 1, "sess_1", "ws_1", EventType::MessageUser, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event_for_ws("e2", 2, "sess_1", "ws_1", EventType::MessageUser, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event_for_ws("e3", 1, "sess_2", "ws_2", EventType::MessageUser, json!({})),
    )
    .unwrap();

    let results = EventRepo::get_by_workspaces_and_types(
        &conn,
        &["ws_1", "ws_2"],
        &["message.user"],
        Some(2),
        Some(1),
    )
    .unwrap();
    assert_eq!(results.len(), 2);
}

#[test]
fn count_by_workspaces_and_types_basic() {
    let conn = setup();
    setup_multi_workspace(&conn);
    EventRepo::insert(
        &conn,
        &make_event_for_ws("e1", 1, "sess_1", "ws_1", EventType::MessageUser, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event_for_ws("e2", 2, "sess_1", "ws_1", EventType::MessageUser, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event_for_ws("e3", 1, "sess_2", "ws_2", EventType::MessageUser, json!({})),
    )
    .unwrap();

    let count =
        EventRepo::count_by_workspaces_and_types(&conn, &["ws_1", "ws_2"], &["message.user"])
            .unwrap();
    assert_eq!(count, 3);
}

#[test]
fn count_by_workspaces_and_types_empty_ids() {
    let conn = setup();
    let count = EventRepo::count_by_workspaces_and_types(&conn, &[], &["message.user"]).unwrap();
    assert_eq!(count, 0);
}

// ── Global (all-workspace) queries ────────────────────────────

#[test]
fn get_all_by_types_basic() {
    let conn = setup();
    EventRepo::insert(
        &conn,
        &make_event("e1", 1, EventType::MessageUser, None, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event("e2", 2, EventType::MessageUser, None, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event(
            "e3",
            3,
            EventType::CapabilityInvocationStarted,
            None,
            json!({}),
        ),
    )
    .unwrap();

    let results = EventRepo::get_all_by_types(&conn, &["message.user"], None, None).unwrap();
    assert_eq!(results.len(), 2);
}

#[test]
fn get_all_by_types_cross_workspace() {
    let conn = setup();
    setup_multi_workspace(&conn);
    EventRepo::insert(
        &conn,
        &make_event_for_ws("e1", 1, "sess_1", "ws_1", EventType::MessageUser, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event_for_ws("e2", 1, "sess_2", "ws_2", EventType::MessageUser, json!({})),
    )
    .unwrap();

    let results = EventRepo::get_all_by_types(&conn, &["message.user"], None, None).unwrap();
    assert_eq!(results.len(), 2);
}

#[test]
fn get_all_by_types_empty_types() {
    let conn = setup();
    let results = EventRepo::get_all_by_types(&conn, &[], None, None).unwrap();
    assert!(results.is_empty());
}

#[test]
fn get_all_by_types_with_limit_offset() {
    let conn = setup();
    for i in 1..=5 {
        EventRepo::insert(
            &conn,
            &make_event(&format!("e{i}"), i, EventType::MessageUser, None, json!({})),
        )
        .unwrap();
    }

    let results = EventRepo::get_all_by_types(&conn, &["message.user"], Some(2), Some(1)).unwrap();
    assert_eq!(results.len(), 2);
}

#[test]
fn get_all_by_types_respects_type_filter() {
    let conn = setup();
    EventRepo::insert(
        &conn,
        &make_event("e1", 1, EventType::MessageUser, None, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event(
            "e2",
            2,
            EventType::CapabilityInvocationStarted,
            None,
            json!({}),
        ),
    )
    .unwrap();

    let results = EventRepo::get_all_by_types(&conn, &["message.user"], None, None).unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].event_type, "message.user");
}

#[test]
fn count_all_by_types_basic() {
    let conn = setup();
    EventRepo::insert(
        &conn,
        &make_event("e1", 1, EventType::MessageUser, None, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event("e2", 2, EventType::MessageUser, None, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event("e3", 3, EventType::MessageUser, None, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event(
            "e4",
            4,
            EventType::CapabilityInvocationStarted,
            None,
            json!({}),
        ),
    )
    .unwrap();

    let count = EventRepo::count_all_by_types(&conn, &["message.user"]).unwrap();
    assert_eq!(count, 3);
}

#[test]
fn count_all_by_types_empty_types() {
    let conn = setup();
    let count = EventRepo::count_all_by_types(&conn, &[]).unwrap();
    assert_eq!(count, 0);
}

#[test]
fn count_all_by_types_cross_workspace() {
    let conn = setup();
    setup_multi_workspace(&conn);
    EventRepo::insert(
        &conn,
        &make_event_for_ws("e1", 1, "sess_1", "ws_1", EventType::MessageUser, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event_for_ws("e2", 2, "sess_1", "ws_1", EventType::MessageUser, json!({})),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event_for_ws("e3", 1, "sess_2", "ws_2", EventType::MessageUser, json!({})),
    )
    .unwrap();

    let count = EventRepo::count_all_by_types(&conn, &["message.user"]).unwrap();
    assert_eq!(count, 3);
}

// ── Per-turn metadata extraction ────────────────────────────────

#[test]
fn extract_model_from_payload() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::MessageAssistant,
        None,
        json!({
            "content": "hello",
            "model": "claude-opus-4-6"
        }),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    assert_eq!(row.model.as_deref(), Some("claude-opus-4-6"));
}

#[test]
fn extract_latency_from_payload() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::MessageAssistant,
        None,
        json!({
            "content": "hello",
            "latency": 1234
        }),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    assert_eq!(row.latency_ms, Some(1234));
}

#[test]
fn extract_stop_reason_from_payload() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::MessageAssistant,
        None,
        json!({
            "content": "hello",
            "stopReason": "end_turn"
        }),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    assert_eq!(row.stop_reason.as_deref(), Some("end_turn"));
}

#[test]
fn extract_has_thinking_bool_from_payload() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::MessageAssistant,
        None,
        json!({
            "content": "hello",
            "hasThinking": true
        }),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    assert_eq!(row.has_thinking, Some(1));
}

#[test]
fn extract_has_thinking_false_from_payload() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::MessageAssistant,
        None,
        json!({
            "content": "hello",
            "hasThinking": false
        }),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    assert_eq!(row.has_thinking, Some(0));
}

#[test]
fn extract_provider_type_from_payload() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::MessageAssistant,
        None,
        json!({
            "content": "hello",
            "providerType": "google"
        }),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    assert_eq!(row.provider_type.as_deref(), Some("google"));
}

#[test]
fn extract_cost_from_payload() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::MessageAssistant,
        None,
        json!({
            "content": "hello",
            "cost": 0.0042
        }),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    let cost = row.cost.unwrap();
    assert!(
        (cost - 0.0042).abs() < f64::EPSILON,
        "cost should be ~0.0042, got {cost}"
    );
}

#[test]
fn new_columns_null_when_not_in_payload() {
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
    assert!(
        row.model.is_none(),
        "model should be None for user messages"
    );
    assert!(row.latency_ms.is_none(), "latency_ms should be None");
    assert!(row.stop_reason.is_none(), "stop_reason should be None");
    assert!(row.has_thinking.is_none(), "has_thinking should be None");
    assert!(row.provider_type.is_none(), "provider_type should be None");
    assert!(row.cost.is_none(), "cost should be None");
}

#[test]
fn extract_all_per_turn_fields_together() {
    let conn = setup();
    let event = make_event(
        "evt_1",
        1,
        EventType::MessageAssistant,
        None,
        json!({
            "content": "thinking response",
            "model": "claude-opus-4-6",
            "latency": 2500,
            "stopReason": "end_turn",
            "hasThinking": true,
            "providerType": "anthropic",
            "cost": 0.015,
            "tokenUsage": {
                "inputTokens": 500,
                "outputTokens": 200,
                "cacheReadTokens": 100
            }
        }),
    );
    EventRepo::insert(&conn, &event).unwrap();

    let row = EventRepo::get_by_id(&conn, "evt_1").unwrap().unwrap();
    assert_eq!(row.model.as_deref(), Some("claude-opus-4-6"));
    assert_eq!(row.latency_ms, Some(2500));
    assert_eq!(row.stop_reason.as_deref(), Some("end_turn"));
    assert_eq!(row.has_thinking, Some(1));
    assert_eq!(row.provider_type.as_deref(), Some("anthropic"));
    assert!((row.cost.unwrap() - 0.015).abs() < f64::EPSILON);
    assert_eq!(row.input_tokens, Some(500));
    assert_eq!(row.output_tokens, Some(200));
}

#[test]
fn query_events_by_model() {
    let conn = setup();
    EventRepo::insert(
        &conn,
        &make_event(
            "evt_1",
            1,
            EventType::MessageAssistant,
            None,
            json!({
                "model": "claude-opus-4-6"
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
                "model": "claude-opus-4-6"
            }),
        ),
    )
    .unwrap();
    EventRepo::insert(
        &conn,
        &make_event(
            "evt_3",
            3,
            EventType::MessageAssistant,
            None,
            json!({
                "model": "gpt-4"
            }),
        ),
    )
    .unwrap();

    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM events WHERE session_id = 'sess_1' AND model = 'claude-opus-4-6'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        count, 2,
        "should find exactly 2 events with claude-opus-4-6 model"
    );
}

#[test]
fn per_turn_columns_survive_ancestor_cte() {
    let conn = setup();
    let e1 = make_event("evt_1", 1, EventType::MessageUser, None, json!({}));
    let e2 = make_event(
        "evt_2",
        2,
        EventType::MessageAssistant,
        Some("evt_1"),
        json!({
            "model": "claude-opus-4-6",
            "latency": 1000,
            "stopReason": "end_turn",
            "hasThinking": false,
            "providerType": "anthropic",
            "cost": 0.01
        }),
    );
    EventRepo::insert(&conn, &e1).unwrap();
    EventRepo::insert(&conn, &e2).unwrap();

    let ancestors = EventRepo::get_ancestors(&conn, "evt_2").unwrap();
    assert_eq!(ancestors.len(), 2);
    // The assistant message (last in chain) should have per-turn fields.
    let assistant = &ancestors[1];
    assert_eq!(assistant.model.as_deref(), Some("claude-opus-4-6"));
    assert_eq!(assistant.latency_ms, Some(1000));
    assert_eq!(assistant.stop_reason.as_deref(), Some("end_turn"));
    assert_eq!(assistant.provider_type.as_deref(), Some("anthropic"));
}

#[test]
fn per_turn_columns_survive_descendant_cte() {
    let conn = setup();
    let e1 = make_event("evt_1", 1, EventType::MessageUser, None, json!({}));
    let e2 = make_event(
        "evt_2",
        2,
        EventType::MessageAssistant,
        Some("evt_1"),
        json!({
            "model": "gpt-4",
            "providerType": "openai"
        }),
    );
    EventRepo::insert(&conn, &e1).unwrap();
    EventRepo::insert(&conn, &e2).unwrap();

    let desc = EventRepo::get_descendants(&conn, "evt_1").unwrap();
    assert_eq!(desc.len(), 1);
    assert_eq!(desc[0].model.as_deref(), Some("gpt-4"));
    assert_eq!(desc[0].provider_type.as_deref(), Some("openai"));
}

// ── get_latest_events tests ──

#[test]
fn get_latest_events_all() {
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

    let events = EventRepo::get_latest_events(&conn, "sess_1", None).unwrap();
    assert_eq!(events.len(), 5);
    assert_eq!(events[0].sequence, 1);
    assert_eq!(events[4].sequence, 5);
}

#[test]
fn get_latest_events_with_limit() {
    let conn = setup();
    for i in 1..=10 {
        let event = make_event(
            &format!("evt_{i}"),
            i,
            EventType::MessageUser,
            None,
            json!({}),
        );
        EventRepo::insert(&conn, &event).unwrap();
    }

    let events = EventRepo::get_latest_events(&conn, "sess_1", Some(3)).unwrap();
    assert_eq!(events.len(), 3);
    // Should be the LAST 3 events, in ASC order
    assert_eq!(events[0].sequence, 8);
    assert_eq!(events[1].sequence, 9);
    assert_eq!(events[2].sequence, 10);
}

#[test]
fn get_latest_events_empty_session() {
    let conn = setup();
    let events = EventRepo::get_latest_events(&conn, "sess_1", Some(5)).unwrap();
    assert!(events.is_empty());
}

// ── get_events_before tests ──

#[test]
fn get_events_before_basic() {
    let conn = setup();
    for i in 1..=10 {
        let event = make_event(
            &format!("evt_{i}"),
            i,
            EventType::MessageUser,
            None,
            json!({}),
        );
        EventRepo::insert(&conn, &event).unwrap();
    }

    let events = EventRepo::get_events_before(&conn, "sess_1", 5, None).unwrap();
    assert_eq!(events.len(), 4); // sequences 1, 2, 3, 4
    assert_eq!(events[0].sequence, 1);
    assert_eq!(events[3].sequence, 4);
}

#[test]
fn get_events_before_with_limit() {
    let conn = setup();
    for i in 1..=10 {
        let event = make_event(
            &format!("evt_{i}"),
            i,
            EventType::MessageUser,
            None,
            json!({}),
        );
        EventRepo::insert(&conn, &event).unwrap();
    }

    // Get last 2 events before sequence 8
    let events = EventRepo::get_events_before(&conn, "sess_1", 8, Some(2)).unwrap();
    assert_eq!(events.len(), 2);
    // Should be sequences 6, 7 (the last 2 before 8, in ASC order)
    assert_eq!(events[0].sequence, 6);
    assert_eq!(events[1].sequence, 7);
}

#[test]
fn get_events_before_first_returns_empty() {
    let conn = setup();
    let event = make_event("evt_1", 1, EventType::MessageUser, None, json!({}));
    EventRepo::insert(&conn, &event).unwrap();

    let events = EventRepo::get_events_before(&conn, "sess_1", 1, None).unwrap();
    assert!(events.is_empty());
}

// ── has_events_before tests ──

#[test]
fn has_events_before_true() {
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

    assert!(EventRepo::has_events_before(&conn, "sess_1", 3).unwrap());
}

#[test]
fn has_events_before_false() {
    let conn = setup();
    let event = make_event("evt_1", 1, EventType::MessageUser, None, json!({}));
    EventRepo::insert(&conn, &event).unwrap();

    assert!(!EventRepo::has_events_before(&conn, "sess_1", 1).unwrap());
}

#[test]
fn has_events_before_empty_session() {
    let conn = setup();
    assert!(!EventRepo::has_events_before(&conn, "sess_1", 100).unwrap());
}

// ── Phase 6 edge case tests ──

#[test]
fn get_latest_events_limit_zero_returns_empty() {
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
    let events = EventRepo::get_latest_events(&conn, "sess_1", Some(0)).unwrap();
    assert!(events.is_empty());
}

#[test]
fn get_events_before_sequence_zero_returns_empty() {
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
    // Nothing has sequence < 0
    let events = EventRepo::get_events_before(&conn, "sess_1", 0, None).unwrap();
    assert!(events.is_empty());
}

#[test]
fn get_events_before_limit_zero_returns_empty() {
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
    let events = EventRepo::get_events_before(&conn, "sess_1", 3, Some(0)).unwrap();
    assert!(events.is_empty());
}

#[test]
fn has_events_before_sequence_zero_returns_false() {
    let conn = setup();
    let event = make_event("evt_1", 1, EventType::MessageUser, None, json!({}));
    EventRepo::insert(&conn, &event).unwrap();
    assert!(!EventRepo::has_events_before(&conn, "sess_1", 0).unwrap());
}

#[test]
fn get_latest_events_limit_larger_than_total() {
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
    // limit=100 but only 3 events exist
    let events = EventRepo::get_latest_events(&conn, "sess_1", Some(100)).unwrap();
    assert_eq!(events.len(), 3);
    assert_eq!(events[0].sequence, 1);
    assert_eq!(events[2].sequence, 3);
}

#[test]
fn sequence_gaps_dont_break_queries() {
    let conn = setup();
    // Insert events with sequence gaps: 1, 5, 10
    let e1 = make_event("evt_1", 1, EventType::MessageUser, None, json!({}));
    let e2 = make_event("evt_5", 5, EventType::MessageUser, None, json!({}));
    let e3 = make_event("evt_10", 10, EventType::MessageUser, None, json!({}));
    EventRepo::insert(&conn, &e1).unwrap();
    EventRepo::insert(&conn, &e2).unwrap();
    EventRepo::insert(&conn, &e3).unwrap();

    // get_latest_events returns all 3 in order
    let events = EventRepo::get_latest_events(&conn, "sess_1", None).unwrap();
    assert_eq!(events.len(), 3);
    assert_eq!(events[0].sequence, 1);
    assert_eq!(events[1].sequence, 5);
    assert_eq!(events[2].sequence, 10);

    // get_events_before with gap
    let events = EventRepo::get_events_before(&conn, "sess_1", 7, None).unwrap();
    assert_eq!(events.len(), 2); // seq 1 and 5
    assert_eq!(events[0].sequence, 1);
    assert_eq!(events[1].sequence, 5);

    // has_events_before across gap
    assert!(EventRepo::has_events_before(&conn, "sess_1", 7).unwrap());
    assert!(!EventRepo::has_events_before(&conn, "sess_1", 1).unwrap());
}
