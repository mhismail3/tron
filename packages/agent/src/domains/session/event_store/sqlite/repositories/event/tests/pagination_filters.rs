use super::*;

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
