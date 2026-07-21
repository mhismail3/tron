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
            "blobs",
            "events",
            "logs",
            "sessions",
            "storage_checkpoints",
            "storage_exports",
            "storage_payload_refs",
            "storage_retention_runs",
            "workspaces",
        ]
    );
}

#[test]
fn schema_installation_is_idempotent() {
    let conn = open_memory();
    ensure_schema(&conn).unwrap();
    ensure_schema(&conn).unwrap();
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
