use super::support::*;

#[test]
fn sol_observability_recovery_lifecycle_is_source_backed() {
    let server = read_repo_file("packages/agent/src/app/bootstrap/server.rs");
    for required in [
        ".route(\"/health\", get(health_handler))",
        ".route(\"/metrics\", get(metrics_handler))",
        ".route(\"/health/deep\", get(deep_health_handler))",
        "health::health_check(state.start_time, connections, sessions)",
        "run_blocking(\"http.health.deep\"",
        "health::deep_health_check(",
        "state.metrics_handle.render()",
    ] {
        assert!(
            server.contains(required),
            "server observability route missing `{required}`"
        );
    }

    let health = read_repo_file("packages/agent/src/app/health/mod.rs");
    assert_contains_in_order(
        "deep health owner checks",
        &health,
        &[
            "check_database(event_store)",
            "check_settings(",
            "check_auth(",
            "check_binary(",
            "check_disk(tron_home)",
            "let has_fail",
            "let has_warn",
        ],
    );
    for required in [
        "session_count_for_health()",
        "\"sessions\": session_count",
        "load_settings_from_path(path)",
        "serde_json::from_str::<serde_json::Value>",
        "\"providers\": count",
        "PermissionsExt",
        "available_megabytes(tron_home)",
        "\"freeMb\": mb",
    ] {
        assert!(
            health.contains(required),
            "deep health source-backed evidence missing `{required}`"
        );
    }

    let metrics = read_repo_file("packages/agent/src/app/health/metrics.rs");
    for required in [
        "install_recorder()",
        "PrometheusBuilder::new()",
        "render(handle: &PrometheusHandle)",
        "ENGINE_REQUESTS_TOTAL",
        "ENGINE_ERRORS_TOTAL",
        "PROVIDER_ERRORS_TOTAL",
        "CAPABILITY_INVOCATIONS_TOTAL",
        "AUTH_REFRESH_TOTAL",
        "WS_CONNECTION_DURATION_SECONDS",
    ] {
        assert!(
            metrics.contains(required),
            "metrics observability surface missing `{required}`"
        );
    }

    let observability = read_repo_file("packages/agent/src/shared/observability/mod.rs");
    for required in [
        "init_subscriber_with_sqlite",
        "SqliteTransport::new(conn, config)",
        "transport.handle()",
        "spawn_flush_task(handle: TransportHandle)",
        "handle.flush()",
    ] {
        assert!(
            observability.contains(required),
            "SQLite log subscriber lifecycle missing `{required}`"
        );
    }
    let transport = read_repo_file("packages/agent/src/shared/observability/transport.rs");
    assert_contains_in_order(
        "SQLite log transport lifecycle",
        &transport,
        &[
            "struct TransportInner",
            "batch: Vec<PendingEntry>",
            "conn: Connection",
            "pub fn handle(&self) -> TransportHandle",
            "fn flush_batch",
            "write_batch(&guard.conn, &entries)",
        ],
    );
    for required in [
        "Immediate flush",
        "Threshold flush",
        "Periodic flush",
        "INSERT INTO logs",
        "session_id",
        "workspace_id",
        "trace_id",
        "error_message",
    ] {
        assert!(
            transport.contains(required),
            "SQLite log transport evidence missing `{required}`"
        );
    }

    let logs_domain = read_repo_file("packages/agent/src/domains/logs/mod.rs");
    for required in [
        "CapabilityContract::new(",
        "\"logs::ingest\"",
        "EffectClass::AppendOnlyEvent",
        "IdempotencyContract::caller_system_engine_ledger()",
        "\"logs::recent\"",
        "EffectClass::PureRead",
        "MAX_RECENT_LIMIT",
        "run_blocking_task(\"logs::ingest\"",
        "run_blocking_task(\"logs::recent\"",
    ] {
        assert!(
            logs_domain.contains(required),
            "logs domain observability lifecycle missing `{required}`"
        );
    }
    let log_ops = read_repo_file("packages/agent/src/domains/capability/operations/logs.rs");
    for required in [
        "optional_u64(&invocation.payload, \"limit\")?",
        ".clamp(1, 500)",
        "log_recent requires trusted current session context",
        "LogSessionFilter::SessionAndGlobal(&session_id)",
        "list_recent_logs",
        "\"primitiveOperation\": \"log_recent\"",
    ] {
        assert!(
            log_ops.contains(required),
            "execute log_recent evidence missing `{required}`"
        );
    }
    let log_store =
        read_repo_file("packages/agent/src/domains/session/event_store/store/event_store/logs.rs");
    assert_contains_in_order(
        "durable log ingestion lifecycle",
        &log_store,
        &[
            "MAX_CLIENT_LOG_INGEST_ENTRIES",
            "MAX_CLIENT_LOG_MESSAGE_BYTES",
            "with_global_write_lock",
            "insert_client_logs",
            "INSERT OR IGNORE INTO logs",
            "truncate_client_log_message",
            "query_recent_logs",
        ],
    );

    let storage = read_repo_file("packages/agent/src/engine/primitives/storage.rs");
    for required in [
        "storage::stats",
        "EffectClass::PureRead",
        "storage::checkpoint",
        "storage::export_snapshot",
        "storage::retention_run",
        "EffectClass::IdempotentWrite",
        "IdempotencyContract::caller_session_engine_ledger()",
    ] {
        assert!(
            storage.contains(required),
            "storage primitive recovery contract missing `{required}`"
        );
    }
    let primitive_runtime = read_repo_file("packages/agent/src/engine/primitives/runtime.rs");
    for required in [
        "fn storage_stats(host: &dyn PrimitiveRuntimeHost)",
        "host.storage_stats()?",
        "fn storage_retention_run(",
        "verboseRetentionDays",
        "host.storage_retention_run(dry_run, verbose_retention_days)?",
    ] {
        assert!(
            primitive_runtime.contains(required),
            "storage primitive runtime dispatch missing `{required}`"
        );
    }
    let maintenance = read_repo_file("packages/agent/src/shared/storage/maintenance.rs");
    assert_contains_in_order(
        "retention observability lifecycle",
        &maintenance,
        &[
            "pub fn retention_run",
            "let started_at",
            "let rows_deleted = count_verbose_logs",
            "DELETE FROM logs",
            "let expired_refs_deleted = count_expired_payload_refs",
            "DELETE FROM storage_payload_refs",
            "let blobs_deleted = count_unowned_blobs",
            "DELETE FROM blobs",
            "let finished_at",
            "INSERT INTO storage_retention_runs",
            "StorageRetentionReport",
        ],
    );
    for required in [
        "pub fn checkpoint_database",
        "INSERT INTO storage_checkpoints",
        "pub fn export_snapshot",
        "VACUUM INTO ?1",
        "INSERT INTO storage_exports",
        "fn count_verbose_logs",
        "SELECT COUNT(*) FROM logs",
        "fn count_expired_payload_refs",
        "SELECT COUNT(*) FROM storage_payload_refs",
        "fn count_unowned_blobs",
        "SELECT COUNT(*) FROM blobs",
        "pub fn enforce_size_budget",
        "let before = storage_stats(path)?",
        "let retention = retention_run(path, false, verbose_retention_days)?",
        "let checkpoint = checkpoint_database(path)?",
    ] {
        assert!(
            maintenance.contains(required),
            "storage maintenance recovery evidence missing `{required}`"
        );
    }
    let stats = read_repo_file("packages/agent/src/shared/storage/stats.rs");
    for required in [
        "pub fn storage_stats(path: &Path)",
        "table_stats(&conn)?",
        "payload_owner_stats(&conn)?",
        "unowned_blob_count(&conn)?",
        "expired_pending_payload_refs(&conn)?",
        "blob_dedupe_ratio(&conn)?",
        "storage_payload_refs",
        "owner_kind",
        "retention_class",
    ] {
        assert!(
            stats.contains(required),
            "storage stats owner evidence missing `{required}`"
        );
    }

    let replay_op = read_repo_file("packages/agent/src/domains/capability/operations/replay.rs");
    for required in [
        "replay_manifest requires a current session",
        "ReplayDeps::new(",
        "deps.event_store.clone()",
        "deps.engine_host.clone()",
        "\"primitiveOperation\": \"replay_manifest\"",
    ] {
        assert!(
            replay_op.contains(required),
            "execute replay_manifest evidence missing `{required}`"
        );
    }
    let replay = read_repo_file("packages/agent/src/domains/session/replay/mod.rs");
    assert_contains_in_order(
        "replay manifest read-only lifecycle",
        &replay,
        &[
            "ReplayDeps",
            "read_session_snapshot",
            ".engine_host",
            "replay_snapshot",
            "build_manifest_value",
            "section_hashes",
            "canonical_hash",
        ],
    );
    for required in [
        "REPLAY_MANIFEST_FORMAT",
        "\"tron.replay.v1\"",
        "get_events_by_session",
        "resolve_event_payloads",
        "list_trace_records_for_replay",
        "provider_audits",
        "engine_idempotency_entries",
        "engine_invocations",
        "engine_streams",
        "engine_queue_items",
        "replay_hash",
    ] {
        assert!(
            replay.contains(required),
            "replay manifest durable evidence missing `{required}`"
        );
    }
    let primitive_trace_tests = read_repo_file("packages/agent/tests/primitive_trace_execution.rs");
    for required in [
        "execute_replay_manifest_is_read_only_and_does_not_create_trace_record",
        "replay_manifest must not mutate trace records",
        "execute_log_recent_exposes_bounded_session_trace_logs",
        "sessionless log_recent must fail closed",
    ] {
        assert!(
            primitive_trace_tests.contains(required),
            "observability/replay regression test missing `{required}`"
        );
    }

    let recovery = read_repo_file("packages/agent/src/domains/agent/loop/orchestrator/recovery.rs");
    assert_contains_in_order(
        "crash recovery evidence",
        &recovery,
        &[
            "found orphaned journals, starting crash recovery",
            "recover_single_turn",
            "crash recovery completed",
        ],
    );
    assert_contains_in_order(
        "single-turn recovery cleanup",
        &recovery,
        &[
            "found orphaned journals, starting crash recovery",
            "recover_single_turn",
            "StreamingJournal::load_recovery",
            "event_store.append",
            "fs::remove_file",
            "cleanup_empty_session_dir",
        ],
    );

    let shutdown = read_repo_file("packages/agent/src/app/lifecycle/shutdown.rs");
    assert_contains_in_order(
        "shutdown drain visibility lifecycle",
        &shutdown,
        &[
            "register_phase_callback",
            "register_task",
            "self.close()",
            "self.run_phase_callbacks().await",
            "waiting for tasks to complete",
            "shutdown_drain_seconds",
            "shutdown timed out, aborting remaining tasks",
            "abort_all",
        ],
    );
    for required in [
        "shutdown_tracked_tasks",
        "shutdown_tasks_registered_total",
        "shutdown_tasks_rejected_total",
        "shutdown_tasks_aborted_total",
        "shutdown_timeouts_total",
        "shutdown_callback_seconds",
        "shutdown_callback_panics_total",
        "shutdown_callback_timeouts_total",
        "remaining = self.tracked_task_count()",
    ] {
        assert!(
            shutdown.contains(required),
            "shutdown drain observability missing `{required}`"
        );
    }

    let inventory = inventory_by_path();
    for required in [
        "packages/agent/src/app/bootstrap/server.rs",
        "packages/agent/src/app/health/mod.rs",
        "packages/agent/src/app/health/metrics.rs",
        "packages/agent/src/app/lifecycle/shutdown.rs",
        "packages/agent/src/domains/agent/loop/orchestrator/recovery.rs",
        "packages/agent/src/domains/capability/operations/logs.rs",
        "packages/agent/src/domains/capability/operations/replay.rs",
        "packages/agent/src/domains/logs/mod.rs",
        "packages/agent/src/domains/session/event_store/store/event_store/logs.rs",
        "packages/agent/src/domains/session/replay/mod.rs",
        "packages/agent/src/engine/primitives/storage.rs",
        "packages/agent/src/shared/observability/mod.rs",
        "packages/agent/src/shared/observability/transport.rs",
        "packages/agent/src/shared/storage/maintenance.rs",
        "packages/agent/src/shared/storage/stats.rs",
    ] {
        assert!(
            inventory
                .get(required)
                .is_some_and(|rows| rows.iter().any(|row| row.sol_rows.contains("SOL-9"))),
            "SOL inventory must tag {required} as part of SOL-9"
        );
    }
}

#[test]
fn final_closeout_is_complete() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let readme = read_repo_file("README.md");

    for required in [
        "Current score: **100/100**",
        "Status: **complete**",
        "| SOL-0 | Campaign harness, red static gate, README links, scorecard/evidence/inventory scaffolding | 5 | passed_after_fix |",
        "| SOL-1 | Whole-repo state inventory for Rust server, iOS app, scripts/CI state, docs-owned state claims | 10 | passed_after_fix |",
        "| SOL-2 | Truth taxonomy for every state surface | 8 | passed_after_fix |",
        "| SOL-3 | Server bootstrap lifecycle | 10 | passed_after_fix |",
        "| SOL-4 | Runtime task and memory lifecycle | 12 | passed_after_fix |",
        "| SOL-5 | Engine durable substrate lifecycle | 14 | passed_after_fix |",
        "| SOL-6 | Session/event-store lifecycle | 10 | passed_after_fix |",
        "| SOL-7 | Settings/auth/secrets lifecycle | 10 | passed_after_fix |",
        "| SOL-8 | iOS projection and local state lifecycle | 14 | passed_after_fix |",
        "| SOL-9 | Observability/recovery evidence | 4 | passed_after_fix |",
        "| SOL-10 | Final closeout | 3 | passed_after_fix |",
        "No open loops remain.",
    ] {
        assert!(
            scorecard.contains(required),
            "SOL final scorecard missing required closeout text: {required}"
        );
    }

    for required in [
        "Current score: **100/100**",
        "Status: **complete**",
        "| SOL-10 | passed_after_fix |",
        "Full closeout verification",
        "clean worktree proof",
    ] {
        assert!(
            evidence.contains(required),
            "SOL final evidence missing required closeout text: {required}"
        );
    }

    for (name, content) in [
        ("scorecard", scorecard.as_str()),
        ("evidence", evidence.as_str()),
        ("inventory", inventory.as_str()),
        ("inventory_tsv", tsv.as_str()),
        ("readme", readme.as_str()),
    ] {
        for forbidden in [
            "Status: **active**",
            "Not started.",
            "pending |",
            "| pending |",
            "Open loops",
            "must still",
            "may close only",
            "remaining proof",
            "deletion pending",
        ] {
            assert!(
                !content.contains(forbidden),
                "{name} contains stale SOL closeout wording: {forbidden}"
            );
        }
    }
}
