use super::*;

// ── Migrator mechanics ────────────────────────────────────────────────

#[test]
fn run_migrations_creates_all_tables() {
    let conn = open_memory();
    let result = run_migrations(&conn).unwrap();
    assert_eq!(result.applied, 4);
    assert_eq!(result.max_version_applied, 5);

    let tables: Vec<String> = conn
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .filter_map(std::result::Result::ok)
        .collect();

    let expected = [
        "blobs",
        "branches",
        "constitution_context_blocks",
        "constitution_home_audit",
        "constitution_resolution_audit",
        "cron_jobs",
        "cron_runs",
        "device_tokens",
        "events",
        "logs",
        "schema_version",
        "sessions",
        "workspaces",
    ];
    for table in &expected {
        assert!(
            tables.contains(&table.to_string()),
            "missing table: {table}"
        );
    }
}

#[test]
fn run_migrations_creates_no_fts_tables() {
    // FTS was in the original v001 draft; consolidated schema deliberately
    // omits it. Guard against a future reintroduction without conscious
    // decision.
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    let fts: Vec<String> = conn
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE '%_fts'")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .filter_map(std::result::Result::ok)
        .collect();

    assert!(fts.is_empty(), "no FTS tables should exist; found: {fts:?}");
}

#[test]
fn run_migrations_is_idempotent() {
    let conn = open_memory();
    let first = run_migrations(&conn).unwrap();
    assert_eq!(first.applied, 4);

    let second = run_migrations(&conn).unwrap();
    assert_eq!(second.applied, 0);
    assert_eq!(second.max_version_applied, 0);
}

#[test]
fn current_version_starts_at_zero() {
    let conn = open_memory();
    ensure_version_table(&conn).unwrap();
    assert_eq!(current_version(&conn).unwrap(), 0);
}

#[test]
fn current_version_after_migration() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();
    assert_eq!(current_version(&conn).unwrap(), 5);
}

#[test]
fn latest_version_matches_migrations() {
    assert_eq!(latest_version(), 5);
}

#[test]
fn schema_version_records_applied_migration() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    let (version, desc): (u32, String) = conn
        .query_row(
            "SELECT version, description FROM schema_version WHERE version = 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();

    assert_eq!(version, 1);
    assert!(
        desc.contains("Consolidated"),
        "description missing expected text: {desc}"
    );

    let (version, desc): (u32, String) = conn
        .query_row(
            "SELECT version, description FROM schema_version WHERE version = 2",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();

    assert_eq!(version, 2);
    assert!(
        desc.contains("Constitution"),
        "description missing expected text: {desc}"
    );

    let (version, desc): (u32, String) = conn
        .query_row(
            "SELECT version, description FROM schema_version WHERE version = 4",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();

    assert_eq!(version, 4);
    assert!(
        desc.contains("Session execution profile"),
        "description missing expected text: {desc}"
    );

    let (version, desc): (u32, String) = conn
        .query_row(
            "SELECT version, description FROM schema_version WHERE version = 5",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();

    assert_eq!(version, 5);
    assert!(
        desc.contains("Drop retired profile migration ledger"),
        "description missing expected text: {desc}"
    );
}

#[test]
fn session_profile_migration_backfills_chat_source() {
    let conn = open_memory();
    ensure_version_table(&conn).unwrap();
    for migration in &MIGRATIONS[..2] {
        apply_migration(&conn, migration).unwrap();
    }

    conn.execute(
        "INSERT INTO workspaces (id, path, name, created_at, last_activity_at)
         VALUES ('w1', '/tmp', 'tmp', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO sessions
         (id, workspace_id, latest_model, working_directory, created_at, last_activity_at, source)
         VALUES
         ('normal-session', 'w1', 'm', '/tmp', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', NULL),
         ('chat-session', 'w1', 'm', '/tmp', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 'chat')",
        [],
    )
    .unwrap();

    run_migrations(&conn).unwrap();

    let normal_profile: String = conn
        .query_row(
            "SELECT profile FROM sessions WHERE id = 'normal-session'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let chat_profile: String = conn
        .query_row(
            "SELECT profile FROM sessions WHERE id = 'chat-session'",
            [],
            |row| row.get(0),
        )
        .unwrap();

    assert_eq!(normal_profile, "normal");
    assert_eq!(chat_profile, "chat");
}

#[test]
fn post_migration_fk_check_accepts_empty_schema() {
    // The safety-net FK check must be a no-op on an empty fresh schema.
    // If this ever regresses, run_migrations() will return Err and every
    // downstream test will fail loudly.
    let conn = open_memory();
    run_migrations(&conn).unwrap(); // unwrap asserts the FK check passed
}
