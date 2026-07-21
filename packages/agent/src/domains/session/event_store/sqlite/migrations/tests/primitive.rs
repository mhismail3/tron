use super::{open_memory, run_migrations};

#[test]
fn fresh_schema_contains_only_primitive_tables() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

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
            "schema_version",
            "sessions",
            "storage_checkpoints",
            "storage_exports",
            "storage_metadata",
            "storage_payload_refs",
            "storage_retention_runs",
            "workspaces",
        ]
    );
}

#[test]
fn schema_version_is_single_fresh_migration() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    let versions = conn
        .prepare("SELECT version FROM schema_version ORDER BY version")
        .unwrap()
        .query_map([], |row| row.get::<_, i64>(0))
        .unwrap()
        .collect::<std::result::Result<Vec<_>, _>>()
        .unwrap();

    assert_eq!(versions, vec![1]);
}

#[test]
fn sessions_table_has_no_product_metadata_columns() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    let mut stmt = conn.prepare("PRAGMA table_info(sessions)").unwrap();
    let columns = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .collect::<std::result::Result<Vec<_>, _>>()
        .unwrap();

    for retired in [
        "origin".to_owned(),
        "source".to_owned(),
        "profile".to_owned(),
        ["use_", "work", "tree"].concat(),
        "spawning_session_id".to_owned(),
        "spawn_type".to_owned(),
        "spawn_task".to_owned(),
    ] {
        assert!(
            !columns.iter().any(|column| column == &retired),
            "retired session column remained: {retired}"
        );
    }
}
