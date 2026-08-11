use super::{ensure_schema, open_memory};

#[test]
fn fresh_schema_contains_only_primitive_tables() {
    let conn = open_memory();
    ensure_schema(&conn).unwrap();

    let mut stmt = conn
        .prepare(
            "SELECT name FROM sqlite_master
             WHERE type = 'table'
             AND name NOT LIKE 'sqlite_%'
             ORDER BY name",
        )
        .unwrap();
    let tables = stmt
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .collect::<std::result::Result<Vec<_>, _>>()
        .unwrap();

    assert_eq!(
        tables,
        vec![
            "agent_assignment_delivery_holds",
            "agent_deliveries",
            "agent_message_metadata",
            "agent_session_promotions",
            "agent_wait_members",
            "agent_waits",
            "blobs",
            "coordination_dependency_edges",
            "coordination_wait_dependency_nodes",
            "coordination_wait_dependency_topologies",
            "coordination_wait_inline_results",
            "coordination_wait_members",
            "coordination_waits",
            "events",
            "logs",
            "sessions",
            "storage_payload_refs",
            "terminals",
            "workspaces",
        ]
    );
}

#[test]
fn terminals_enforce_one_live_process_per_session_and_retention_indexes() {
    let conn = open_memory();
    ensure_schema(&conn).unwrap();

    let live_index: String = conn
        .query_row(
            "SELECT sql FROM sqlite_schema WHERE type='index' AND name='idx_terminals_one_running_per_session'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(live_index.contains("UNIQUE INDEX"));
    assert!(live_index.contains("WHERE state='running'"));

    let retention_index: String = conn
        .query_row(
            "SELECT sql FROM sqlite_schema WHERE type='index' AND name='idx_terminals_retention'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(retention_index.contains("retained_until"));
}

#[test]
fn schema_installation_is_idempotent() {
    let conn = open_memory();
    ensure_schema(&conn).unwrap();
    ensure_schema(&conn).unwrap();
}

#[test]
fn schema_repairs_dependency_side_tables_without_rewriting_existing_wait_tables() {
    let conn = open_memory();
    ensure_schema(&conn).unwrap();
    conn.execute_batch(
        "DROP TABLE coordination_wait_dependency_topologies;
         DROP TABLE coordination_wait_dependency_nodes;
         DROP TABLE coordination_dependency_edges;",
    )
    .unwrap();

    ensure_schema(&conn).unwrap();

    for table in [
        "coordination_waits",
        "coordination_wait_members",
        "coordination_wait_dependency_nodes",
        "coordination_wait_dependency_topologies",
        "coordination_dependency_edges",
    ] {
        let exists = conn
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name=?1)",
                [table],
                |row| row.get::<_, bool>(0),
            )
            .unwrap();
        assert!(exists, "missing repaired table {table}");
    }
}

#[test]
fn events_have_a_session_type_sequence_index() {
    let conn = open_memory();
    ensure_schema(&conn).unwrap();

    let sql: String = conn
        .query_row(
            "SELECT sql FROM sqlite_schema WHERE type='index' AND name=?1",
            ["idx_events_session_type_sequence"],
            |row| row.get(0),
        )
        .unwrap();

    assert!(sql.contains("events(session_id, type, sequence DESC)"));
}

#[test]
fn events_have_indexed_idempotent_user_input_state() {
    let conn = open_memory();
    ensure_schema(&conn).unwrap();

    let lookup_sql: String = conn
        .query_row(
            "SELECT sql FROM sqlite_schema WHERE type='index' AND name=?1",
            ["idx_events_session_invocation"],
            |row| row.get(0),
        )
        .unwrap();
    assert!(lookup_sql.contains("events(session_id, type, tool_name, invocation_id)"));

    let uniqueness_sql: String = conn
        .query_row(
            "SELECT sql FROM sqlite_schema WHERE type='index' AND name=?1",
            ["idx_events_user_input_answer_unique"],
            |row| row.get(0),
        )
        .unwrap();
    assert!(uniqueness_sql.contains("UNIQUE INDEX"));
    assert!(uniqueness_sql.contains("request_user_input_answer"));
}

#[test]
fn sessions_table_has_no_product_metadata_columns() {
    let conn = open_memory();
    ensure_schema(&conn).unwrap();

    let mut stmt = conn.prepare("PRAGMA table_info(sessions)").unwrap();
    let columns = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .collect::<std::result::Result<Vec<_>, _>>()
        .unwrap();

    assert_eq!(
        columns,
        [
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
            "message_count",
            "turn_count",
            "total_input_tokens",
            "total_output_tokens",
            "last_turn_input_tokens",
            "total_cost",
            "total_cache_read_tokens",
            "total_cache_creation_tokens",
            "tags",
        ]
    );
}
