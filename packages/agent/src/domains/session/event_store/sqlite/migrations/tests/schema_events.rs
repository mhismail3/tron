use super::*;

// ── Index presence ────────────────────────────────────────────────────

#[test]
fn indexes_are_created() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    let indexes: Vec<String> = conn
        .prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%'")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .filter_map(std::result::Result::ok)
        .collect();

    let expected = [
        // events
        "idx_events_session_seq",
        "idx_events_session_sequence_unique",
        // sessions
        "idx_sessions_workspace",
        "idx_sessions_created",
        "idx_sessions_origin",
        "idx_sessions_source",
        "idx_sessions_profile",
        // blobs / branches / workspaces
        "idx_blobs_hash",
        "idx_branches_session",
        "idx_workspaces_path",
        // logs
        "idx_logs_ios_client_dedup",
        // device_tokens
        "idx_device_tokens_identity",
        "idx_device_tokens_session",
        "idx_device_tokens_token",
        "idx_device_tokens_workspace",
        // cron
        "idx_cron_jobs_enabled_next",
        "idx_cron_runs_job_started",
        "idx_cron_runs_status",
        "idx_cron_runs_created",
    ];
    for idx in &expected {
        assert!(indexes.contains(&idx.to_string()), "missing index: {idx}");
    }

    // Guard against the old (pre-consolidation) noisy indexes sneaking back
    let removed = [
        "idx_logs_timestamp",
        "idx_logs_trace_id",
        "idx_logs_origin",
        "idx_logs_session_time",
        "idx_logs_level_time",
        "idx_logs_component_time",
        "idx_logs_workspace_time",
        "idx_logs_parent_trace",
        "idx_events_parent",
        "idx_events_type",
        "idx_events_invocation_id",
        "idx_events_model",
        "idx_events_latency",
        "idx_events_timestamp",
        "idx_logs_event",
    ];
    for idx in &removed {
        assert!(
            !indexes.contains(&idx.to_string()),
            "{idx} should not exist"
        );
    }
}

#[test]
fn no_triggers_exist() {
    // Fresh schema uses inline CHECK constraints instead of BEFORE triggers;
    // SQLite cannot add CHECK constraints to an existing table with ALTER.
    // Guard against triggers creeping back.
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    let triggers: Vec<String> = conn
        .prepare("SELECT name FROM sqlite_master WHERE type = 'trigger'")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .filter_map(std::result::Result::ok)
        .collect();

    assert!(
        triggers.is_empty(),
        "no triggers expected; found: {triggers:?}"
    );
}

#[test]
fn retired_v1_tables_absent() {
    // Confirm removed tables from prior schema revisions don't leak back
    // through copy-paste.
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    let tables: Vec<String> = conn
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .filter_map(std::result::Result::ok)
        .collect();

    for removed in &[
        "projects",
        "areas",
        "tasks",
        "task_dependencies",
        "profile_migrations",
    ] {
        assert!(
            !tables.contains(&removed.to_string()),
            "{removed} should not exist"
        );
    }
}

// ── events table column shape + invariants ────────────────────────────

#[test]
fn events_table_has_expected_columns() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    let columns: Vec<String> = conn
        .prepare("PRAGMA table_info(events)")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .filter_map(std::result::Result::ok)
        .collect();

    let expected = [
        "id",
        "session_id",
        "parent_id",
        "sequence",
        "depth",
        "type",
        "timestamp",
        "payload",
        "content_blob_id",
        "workspace_id",
        "role",
        "model_primitive_name",
        "invocation_id",
        "turn",
        "input_tokens",
        "output_tokens",
        "cache_read_tokens",
        "cache_creation_tokens",
        "checksum",
        "model",
        "latency_ms",
        "stop_reason",
        "has_thinking",
        "provider_type",
        "cost",
    ];
    for col in &expected {
        assert!(
            columns.contains(&col.to_string()),
            "events table missing column: {col}"
        );
    }
}

#[test]
fn events_check_constraint_appears_in_schema() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    let sql: String = conn
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'events'",
            [],
            |row| row.get(0),
        )
        .unwrap();

    assert!(
        sql.contains("CHECK (payload IS NOT NULL OR content_blob_id IS NOT NULL)"),
        "events table missing payload/content_blob CHECK; got: {sql}"
    );
}

#[test]
fn events_null_payload_rejected() {
    // Belt-and-suspenders: payload is NOT NULL at the column level today,
    // so a literal NULL payload is caught by NOT NULL first. If a future
    // change relaxes NOT NULL, the table-level CHECK becomes the binding
    // enforcement. The test's role is that the row is rejected, not which
    // constraint catches it.
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    seed_workspace_and_session(&conn, "ws_1", "s1");

    let err = conn.execute(
        "INSERT INTO events (id, session_id, sequence, type, timestamp, payload,
                             content_blob_id, workspace_id)
         VALUES ('e_empty', 's1', 1, 'message.user', '2026-01-01T00:00:00Z', NULL,
                 NULL, 'ws_1')",
        [],
    );
    assert!(
        err.is_err(),
        "NULL payload + NULL content_blob_id must be rejected"
    );
}

#[test]
fn events_unique_session_sequence_enforced() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    seed_workspace_and_session(&conn, "ws_1", "s1");

    conn.execute(
        "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
         VALUES ('e1', 's1', 1, 'message.user', '2026-01-01T00:00:00Z',
                 '{\"content\":\"hello\"}', 'ws_1')",
        [],
    )
    .unwrap();

    let duplicate = conn.execute(
        "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
         VALUES ('e2', 's1', 1, 'message.assistant', '2026-01-01T00:00:00Z',
                 '{\"content\":\"world\"}', 'ws_1')",
        [],
    );
    assert!(duplicate.is_err());
}

#[test]
fn events_turn_metadata_columns_are_nullable() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();
    seed_workspace_and_session(&conn, "ws_1", "s1");

    // Insert event WITHOUT the denormalized columns — they should default to NULL
    conn.execute(
        "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
         VALUES ('evt_1', 's1', 1, 'message.user', '2025-01-01T00:00:00Z', '{}', 'ws_1')",
        [],
    )
    .unwrap();

    let (model, latency, stop, thinking, provider, cost): (
        Option<String>,
        Option<i64>,
        Option<String>,
        Option<i64>,
        Option<String>,
        Option<f64>,
    ) = conn
        .query_row(
            "SELECT model, latency_ms, stop_reason, has_thinking, provider_type, cost
             FROM events WHERE id = 'evt_1'",
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                ))
            },
        )
        .unwrap();

    assert!(model.is_none());
    assert!(latency.is_none());
    assert!(stop.is_none());
    assert!(thinking.is_none());
    assert!(provider.is_none());
    assert!(cost.is_none());
}

#[test]
fn events_turn_metadata_columns_can_be_populated() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();
    seed_workspace_and_session(&conn, "ws_1", "s1");

    conn.execute(
        "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id,
                             model, latency_ms, stop_reason, has_thinking, provider_type, cost)
         VALUES ('evt_1', 's1', 1, 'message.assistant', '2025-01-01T00:00:00Z', '{}', 'ws_1',
                 'claude-opus-4-6', 1500, 'end_turn', 1, 'anthropic', 0.015)",
        [],
    )
    .unwrap();

    let (model, latency, stop, thinking, provider, cost): (String, i64, String, i64, String, f64) =
        conn.query_row(
            "SELECT model, latency_ms, stop_reason, has_thinking, provider_type, cost
             FROM events WHERE id = 'evt_1'",
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                ))
            },
        )
        .unwrap();

    assert_eq!(model, "claude-opus-4-6");
    assert_eq!(latency, 1500);
    assert_eq!(stop, "end_turn");
    assert_eq!(thinking, 1);
    assert_eq!(provider, "anthropic");
    assert!((cost - 0.015).abs() < f64::EPSILON);
}

// ── events FK behavior (replaces v008 rebuild tests with plain invariants) ─

#[test]
fn events_self_referential_parent_id_fk_enforced() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();
    seed_workspace_and_session(&conn, "ws_1", "s1");

    // root event, then child referencing root
    conn.execute(
        "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
         VALUES ('e_root', 's1', 1, 'message.user', '2026-01-01T00:00:00Z', '{}', 'ws_1')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO events (id, session_id, parent_id, sequence, type, timestamp,
                             payload, workspace_id)
         VALUES ('e_child', 's1', 'e_root', 2, 'message.assistant', '2026-01-01T00:00:01Z',
                 '{}', 'ws_1')",
        [],
    )
    .unwrap();

    // parent_id pointing at a nonexistent row is rejected
    let err = conn.execute(
        "INSERT INTO events (id, session_id, parent_id, sequence, type, timestamp,
                             payload, workspace_id)
         VALUES ('e_bad', 's1', 'e_missing', 3, 'message.user', '2026-01-01T00:00:02Z',
                 '{}', 'ws_1')",
        [],
    );
    assert!(err.is_err(), "events.parent_id FK must reject missing id");
}

#[test]
fn branches_fk_to_events_enforced() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();
    seed_workspace_and_session(&conn, "ws_1", "s1");

    conn.execute(
        "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
         VALUES ('e1', 's1', 1, 'message.user', '2026-01-01T00:00:00Z', '{}', 'ws_1')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO branches (id, session_id, name, root_event_id, head_event_id,
                               created_at, last_activity_at)
         VALUES ('b1', 's1', 'main', 'e1', 'e1',
                 '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
        [],
    )
    .unwrap();

    let err = conn.execute(
        "INSERT INTO branches (id, session_id, name, root_event_id, head_event_id,
                               created_at, last_activity_at)
         VALUES ('b_bad', 's1', 'orphan', 'e_missing', 'e_missing',
                 '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
        [],
    );
    assert!(err.is_err(), "branches FK to events must reject missing id");
}
