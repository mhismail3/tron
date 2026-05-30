use super::*;

// ── device_tokens identity (bundle_id + COALESCE UNIQUE) ──────────────

#[test]
fn device_tokens_has_bundle_id_column() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    let columns: Vec<String> = conn
        .prepare("PRAGMA table_info(device_tokens)")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .filter_map(std::result::Result::ok)
        .collect();

    assert!(columns.contains(&"bundle_id".to_string()));
}

#[test]
fn device_tokens_bundle_id_round_trips() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    conn.execute(
        "INSERT INTO device_tokens (id, device_token, platform, environment, bundle_id,
                                    created_at, last_used_at, is_active)
         VALUES ('dt_1', 'aa', 'ios', 'sandbox', 'com.tron.mobile.beta',
                 '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
        [],
    )
    .unwrap();

    let bundle_id: String = conn
        .query_row(
            "SELECT bundle_id FROM device_tokens WHERE id = 'dt_1'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(bundle_id, "com.tron.mobile.beta");
}

/// Post-R5: `bundle_id` is NOT NULL — every registration carries its
/// APNs topic. An INSERT that omits bundle_id must be rejected by the
/// schema, so clients cannot register without a bundle and the send
/// path always uses the persisted topic.
#[test]
fn device_tokens_bundle_id_is_not_null() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    let err = conn.execute(
        "INSERT INTO device_tokens (id, device_token, platform, environment,
                                    created_at, last_used_at, is_active)
         VALUES ('dt_2', 'bb', 'ios', 'production',
                 '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
        [],
    );
    assert!(
        err.is_err(),
        "INSERT without bundle_id must be rejected by NOT NULL constraint"
    );

    // Also reject an explicit NULL.
    let err_explicit = conn.execute(
        "INSERT INTO device_tokens (id, device_token, platform, environment, bundle_id,
                                    created_at, last_used_at, is_active)
         VALUES ('dt_null', 'cc', 'ios', 'production', NULL,
                 '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
        [],
    );
    assert!(
        err_explicit.is_err(),
        "INSERT with explicit NULL bundle_id must be rejected"
    );
}

#[test]
fn device_tokens_unique_allows_same_token_across_workspaces() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    conn.execute(
        "INSERT INTO workspaces (id, path, created_at, last_activity_at)
         VALUES ('ws_1', '/t1', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
                ('ws_2', '/t2', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
        [],
    )
    .unwrap();

    conn.execute(
        "INSERT INTO device_tokens (id, device_token, workspace_id, platform, environment,
                                    bundle_id, created_at, last_used_at, is_active)
         VALUES ('dt_a', 'zz', 'ws_1', 'ios', 'production', 'com.tron.mobile',
                 '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO device_tokens (id, device_token, workspace_id, platform, environment,
                                    bundle_id, created_at, last_used_at, is_active)
         VALUES ('dt_b', 'zz', 'ws_2', 'ios', 'production', 'com.tron.mobile',
                 '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
        [],
    )
    .unwrap();

    // Full-identity duplicate (same token, same workspace, same bundle) rejected.
    let dup = conn.execute(
        "INSERT INTO device_tokens (id, device_token, workspace_id, platform, environment,
                                    bundle_id, created_at, last_used_at, is_active)
         VALUES ('dt_dup', 'zz', 'ws_1', 'ios', 'production', 'com.tron.mobile',
                 '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
        [],
    );
    assert!(
        dup.is_err(),
        "duplicate (token, ios, ws_1, bundle) must be rejected by UNIQUE index"
    );
}

/// COALESCE(workspace_id, '') collapses NULL to a single canonical
/// sentinel so a workspace-less token can't register twice as "(token,
/// ios, NULL, bundle)" (SQLite's native UNIQUE treats NULL as
/// distinct). `bundle_id` is NOT NULL so only workspace_id needs the
/// COALESCE widening; a concrete bundle participates in the index
/// directly.
#[test]
fn device_tokens_unique_collapses_null_workspace() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    conn.execute(
        "INSERT INTO device_tokens (id, device_token, platform, environment, bundle_id,
                                    created_at, last_used_at, is_active)
         VALUES ('dt_null1', 'nn', 'ios', 'production', 'com.tron.mobile',
                 '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
        [],
    )
    .unwrap();

    let dup = conn.execute(
        "INSERT INTO device_tokens (id, device_token, platform, environment, bundle_id,
                                    created_at, last_used_at, is_active)
         VALUES ('dt_null2', 'nn', 'ios', 'production', 'com.tron.mobile',
                 '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
        [],
    );
    assert!(
        dup.is_err(),
        "two (token, ios, NULL ws, same bundle) rows must be rejected by COALESCE index"
    );
}

/// The consolidated schema must NOT carry the retired narrow
/// UNIQUE(device_token, platform): two registrations with the same token
/// and platform but distinct workspaces must both succeed.
#[test]
fn device_tokens_no_narrow_unique() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    conn.execute(
        "INSERT INTO workspaces (id, path, created_at, last_activity_at)
         VALUES ('ws_1', '/t1', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'),
                ('ws_2', '/t2', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
        [],
    )
    .unwrap();

    conn.execute(
        "INSERT INTO device_tokens (id, device_token, workspace_id, platform, environment,
                                    bundle_id, created_at, last_used_at, is_active)
         VALUES ('dt_a', 'aa', 'ws_1', 'ios', 'production', 'com.tron.mobile',
                 '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
        [],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO device_tokens (id, device_token, workspace_id, platform, environment,
                                    bundle_id, created_at, last_used_at, is_active)
         VALUES ('dt_b', 'aa', 'ws_2', 'ios', 'production', 'com.tron.mobile',
                 '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
        [],
    )
    .unwrap_or_else(|e| panic!("same token in two workspaces must succeed: {e}"));
}

#[test]
fn device_tokens_auxiliary_indexes_exist() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    let indexes: Vec<String> = conn
        .prepare(
            "SELECT name FROM sqlite_master
             WHERE type = 'index' AND tbl_name = 'device_tokens' ORDER BY name",
        )
        .unwrap()
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .filter_map(std::result::Result::ok)
        .collect();

    for expected in &[
        "idx_device_tokens_identity",
        "idx_device_tokens_session",
        "idx_device_tokens_token",
        "idx_device_tokens_workspace",
    ] {
        assert!(
            indexes.contains(&expected.to_string()),
            "missing {expected}; found: {indexes:?}"
        );
    }
}

// ── retired prompt library tables ─────────────────────────────────────

#[test]
fn fresh_schema_omits_retired_prompt_tables() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    let table_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'table' AND name IN ('prompt_history', 'prompt_snippets')",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        table_count, 0,
        "fresh v4 schema must not create retired prompt-library tables"
    );
}

#[test]
fn fresh_schema_omits_retired_prompt_indexes() {
    let conn = open_memory();
    run_migrations(&conn).unwrap();

    let index_count: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master
             WHERE type = 'index'
               AND name IN (
                 'idx_prompt_history_last_used',
                 'idx_prompt_history_use_count',
                 'idx_prompt_snippets_updated'
               )",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        index_count, 0,
        "fresh v4 schema must not create retired prompt-library indexes"
    );
}
