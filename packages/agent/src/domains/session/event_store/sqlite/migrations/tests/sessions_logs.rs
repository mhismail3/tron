use super::*;

// ── sessions shape + use_worktree CHECK ───────────────────────────────

#[test]
fn sessions_table_has_expected_columns() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    let columns: Vec<String> = conn
        .prepare("PRAGMA table_info(sessions)")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .filter_map(std::result::Result::ok)
        .collect();

    let expected = [
        "id",
        "workspace_id",
        "head_event_id",
        "root_event_id",
        "title",
        "latest_model",
        "working_directory",
        "parent_session_id",
        "fork_from_event_id",
        "created_at",
        "last_activity_at",
        "ended_at",
        "event_count",
        "turn_count",
        "total_input_tokens",
        "total_output_tokens",
        "total_cost",
        "total_cache_read_tokens",
        "total_cache_creation_tokens",
        "spawning_session_id",
        "spawn_type",
        "spawn_task",
        "origin",
        "source",
        "profile",
        "use_worktree",
    ];
    for col in &expected {
        assert!(
            columns.contains(&col.to_string()),
            "sessions table missing column: {col}"
        );
    }
}

#[test]
fn origin_columns_exist_in_sessions_and_logs() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    for (table, col) in &[("sessions", "origin"), ("logs", "origin")] {
        let cols: Vec<String> = conn
            .prepare(&format!("PRAGMA table_info({table})"))
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();
        assert!(
            cols.contains(&(*col).to_string()),
            "{table} table missing {col} column"
        );
    }
}

#[test]
fn sessions_workspace_fk_enforced() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    let result = conn.execute(
        "INSERT INTO sessions (id, workspace_id, latest_model, working_directory,
                               created_at, last_activity_at)
         VALUES ('sess_1', 'nonexistent', 'claude-3', '/tmp',
                 '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
        [],
    );
    assert!(result.is_err());
}

#[test]
fn sessions_use_worktree_round_trips_true_false_null() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    conn.execute(
        "INSERT INTO workspaces (id, path, created_at, last_activity_at)
         VALUES ('ws_1', '/tmp/test', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
        [],
    )
    .unwrap();

    for (sid, value) in &[
        ("sess_null", "NULL"),
        ("sess_true", "1"),
        ("sess_false", "0"),
    ] {
        conn.execute(
            &format!(
                "INSERT INTO sessions (id, workspace_id, latest_model, working_directory,
                                       created_at, last_activity_at, use_worktree)
                 VALUES ('{sid}', 'ws_1', 'claude-3', '/tmp/test',
                         '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z', {value})"
            ),
            [],
        )
        .unwrap();
    }

    let null_val: Option<i64> = conn
        .query_row(
            "SELECT use_worktree FROM sessions WHERE id = 'sess_null'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    let true_val: Option<i64> = conn
        .query_row(
            "SELECT use_worktree FROM sessions WHERE id = 'sess_true'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    let false_val: Option<i64> = conn
        .query_row(
            "SELECT use_worktree FROM sessions WHERE id = 'sess_false'",
            [],
            |r| r.get(0),
        )
        .unwrap();

    assert!(null_val.is_none());
    assert_eq!(true_val, Some(1));
    assert_eq!(false_val, Some(0));
}

#[test]
fn sessions_use_worktree_check_rejects_invalid_on_insert() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    conn.execute(
        "INSERT INTO workspaces (id, path, created_at, last_activity_at)
         VALUES ('ws_1', '/tmp/test', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
        [],
    )
    .unwrap();

    // 0, 1, and NULL all accepted.
    for value in &["0", "1", "NULL"] {
        let id = format!("sess_{value}");
        conn.execute(
            &format!(
                "INSERT INTO sessions (id, workspace_id, latest_model, working_directory,
                                       created_at, last_activity_at, use_worktree)
                 VALUES ('{id}', 'ws_1', 'claude-3', '/tmp/test',
                         '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z', {value})"
            ),
            [],
        )
        .unwrap_or_else(|e| panic!("value {value} should be accepted: {e}"));
    }

    // 2 must be rejected.
    let err = conn.execute(
        "INSERT INTO sessions (id, workspace_id, latest_model, working_directory,
                               created_at, last_activity_at, use_worktree)
         VALUES ('sess_two', 'ws_1', 'claude-3', '/tmp/test',
                 '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z', 2)",
        [],
    );
    assert!(err.is_err(), "use_worktree = 2 must be rejected on INSERT");
    let msg = err.unwrap_err().to_string();
    assert!(
        msg.contains("CHECK constraint failed") && msg.contains("use_worktree"),
        "expected CHECK failure mentioning use_worktree, got: {msg}"
    );

    // Negative values rejected.
    let err_neg = conn.execute(
        "INSERT INTO sessions (id, workspace_id, latest_model, working_directory,
                               created_at, last_activity_at, use_worktree)
         VALUES ('sess_neg', 'ws_1', 'claude-3', '/tmp/test',
                 '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z', -1)",
        [],
    );
    assert!(
        err_neg.is_err(),
        "use_worktree = -1 must be rejected on INSERT"
    );
}

#[test]
fn sessions_use_worktree_check_rejects_invalid_on_update() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    conn.execute(
        "INSERT INTO workspaces (id, path, created_at, last_activity_at)
         VALUES ('ws_1', '/tmp/test', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO sessions (id, workspace_id, latest_model, working_directory,
                               created_at, last_activity_at, use_worktree)
         VALUES ('s1', 'ws_1', 'claude-3', '/tmp/test',
                 '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z', NULL)",
        [],
    )
    .unwrap();

    // Valid UPDATE succeeds.
    conn.execute("UPDATE sessions SET use_worktree = 1 WHERE id = 's1'", [])
        .unwrap();

    // Invalid UPDATE rejected; pre-existing value preserved.
    let err = conn.execute("UPDATE sessions SET use_worktree = 99 WHERE id = 's1'", []);
    assert!(err.is_err(), "use_worktree = 99 must be rejected on UPDATE");

    let val: Option<i64> = conn
        .query_row(
            "SELECT use_worktree FROM sessions WHERE id = 's1'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(val, Some(1), "row should retain pre-rejection value");
}

// ── retired notification read state ───────────────────────────────────

#[test]
fn fresh_schema_omits_retired_notification_read_state() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();
    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name = 'notification_read_state'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(count, 0);
}

// ── iOS client log dedup ──────────────────────────────────────────────

#[test]
fn ios_client_dedup_index_prevents_duplicates() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    conn.execute(
        "INSERT INTO logs (timestamp, level, level_num, component, message, origin)
         VALUES ('2026-03-03T14:30:05.100Z', 'info', 30, 'ios.WebSocket', 'connected', 'ios-client')",
        [],
    )
    .unwrap();

    let dup = conn.execute(
        "INSERT INTO logs (timestamp, level, level_num, component, message, origin)
         VALUES ('2026-03-03T14:30:05.100Z', 'info', 30, 'ios.WebSocket', 'connected', 'ios-client')",
        [],
    );
    assert!(dup.is_err());

    // INSERT OR IGNORE is idempotent.
    conn.execute(
        "INSERT OR IGNORE INTO logs (timestamp, level, level_num, component, message, origin)
         VALUES ('2026-03-03T14:30:05.100Z', 'info', 30, 'ios.WebSocket', 'connected', 'ios-client')",
        [],
    )
    .unwrap();

    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM logs WHERE origin = 'ios-client'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(count, 1);
}

#[test]
fn ios_dedup_does_not_affect_server_logs() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    // Server logs with matching timestamp+component+message insert freely.
    for origin in &["localhost:9847", "localhost:9846"] {
        conn.execute(
            "INSERT INTO logs (timestamp, level, level_num, component, message, origin)
             VALUES ('2026-03-03T14:30:05.100Z', 'info', 30, 'EventStore', 'test', ?1)",
            [origin],
        )
        .unwrap();
    }

    let count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM logs WHERE origin != 'ios-client'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(count, 2);
}
