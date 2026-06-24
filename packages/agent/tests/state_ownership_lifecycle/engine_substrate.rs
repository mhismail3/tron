use super::support::*;

#[test]
fn sol_engine_durable_substrate_lifecycle_is_source_backed() {
    let compensation = read_repo_file("packages/agent/src/engine/authority/compensation.rs");
    assert_contains_in_order(
        "compensation audit-only lifecycle",
        &compensation,
        &[
            "Compensation is intentionally recorded before Tron attempts any automated",
            "pub enum EngineCompensationStatus",
            "Recorded",
            "Self::Recorded => \"recorded\"",
            "status: EngineCompensationStatus::Recorded",
            "\"engine_compensation\"",
            "\"audit\"",
        ],
    );
    assert!(
        !compensation.contains("Succeeded") && !compensation.contains("RolledBack"),
        "compensation must remain explicit audit-only state until a rollback owner is implemented"
    );

    let invocation_support =
        read_repo_file("packages/agent/src/engine/invocation/host/invocation_support.rs");
    for required in [
        "acquire_resource_lease_for_invocation",
        "release_resource_lease_sync",
        "record_compensation_for_result_sync",
        "\"resource_lease.acquired\"",
        "\"resource_lease.released\"",
        "\"compensation.recorded\"",
    ] {
        assert!(
            invocation_support.contains(required),
            "engine host contract bookkeeping missing `{required}`"
        );
    }

    let meta_invocation =
        read_repo_file("packages/agent/src/engine/invocation/host/meta_invocation.rs");
    assert_contains_in_order(
        "host-dispatched primitive contract finalization",
        &meta_invocation,
        &[
            "let compensation_contract = function.compensation.clone();",
            "let lease_result = self.acquire_resource_lease_for_invocation",
            "release_after_primary(self.release_resource_lease_sync",
            "finish_meta_invocation_with_contracts",
            "complete_invocation_idempotency",
            "record_compensation_for_result_sync",
            "record_invocation_result_with_contracts",
        ],
    );

    let ledger = read_repo_file("packages/agent/src/engine/durability/ledger/sqlite_store/mod.rs");
    for required in [
        "append_catalog_change",
        "upsert_durable_worker_definition",
        "remove_durable_worker_definition",
        "upsert_durable_function_definition",
        "remove_durable_function_definition",
        "append_invocation",
        "resource_lease_ids_json",
        "compensation_status",
        "produced_resource_refs_json",
        "reserve_idempotency",
        "IdempotencyStatus::InProgress",
        "complete_idempotency",
        "IdempotencyStatus::Completed",
        "\"engine_invocation\"",
        "\"engine_idempotency\"",
        "list_invocations_by_session",
        "list_idempotency_by_session",
    ] {
        assert!(
            ledger.contains(required),
            "engine ledger lifecycle missing `{required}`"
        );
    }

    let queue = read_repo_file("packages/agent/src/engine/durability/queue/mod.rs");
    for required in [
        "pub enum QueueItemStatus",
        "Ready",
        "Leased",
        "Completed",
        "Cancelled",
        "DeadLettered",
        "pub struct EngineQueueAttemptRecord",
        "resource_lease_ids",
        "compensation_status",
        "compensation_id",
    ] {
        assert!(
            queue.contains(required),
            "engine queue model lifecycle missing `{required}`"
        );
    }
    for path in [
        "packages/agent/src/engine/durability/queue/memory.rs",
        "packages/agent/src/engine/durability/queue/sqlite_store.rs",
    ] {
        let source = read_repo_file(path);
        for required in [
            "QueueItemStatus::Ready",
            "QueueItemStatus::Leased",
            "QueueItemStatus::Completed",
            "QueueItemStatus::Cancelled",
            "QueueItemStatus::DeadLettered",
            "lease_owner = None",
            "lease_expires_at = None",
            "attempt_records.push",
            "list_by_session",
        ] {
            assert!(source.contains(required), "{path} missing `{required}`");
        }
    }
    let sqlite_queue = read_repo_file("packages/agent/src/engine/durability/queue/sqlite_store.rs");
    assert!(
        sqlite_queue.contains("attempt_records_json"),
        "SQLite queue store must persist attempt records"
    );

    let resources = read_repo_file("packages/agent/src/engine/durability/resources/store/mod.rs");
    for required in [
        "register_type",
        "resource.created",
        "append_version_inner",
        "EngineResourceVersionState::Available",
        "store_json_value",
        "\"engine_resource_version\"",
        "update_resource_pointer",
        "resource.version.created",
        "resource.linked",
        "expected_current_version_id",
        "version conflict",
        "inspect",
        "list",
    ] {
        assert!(
            resources.contains(required),
            "engine resource store lifecycle missing `{required}`"
        );
    }

    let state = read_repo_file("packages/agent/src/engine/durability/state.rs");
    for required in [
        "revision.saturating_add(1)",
        "compare_and_set",
        "state revision conflict",
        "DELETE FROM engine_state_entries",
        "\"engine_state_entry\"",
        "list(",
    ] {
        assert!(
            state.contains(required),
            "engine state store lifecycle missing `{required}`"
        );
    }

    for path in [
        "packages/agent/src/engine/durability/streams/memory.rs",
        "packages/agent/src/engine/durability/streams/sqlite_store.rs",
    ] {
        let source = read_repo_file(path);
        for required in [
            "publish",
            "subscribe",
            "latest_cursor",
            "unsubscribe",
            "acknowledge",
            "poll",
            "list_by_session",
            "stream_scope_visible",
        ] {
            assert!(source.contains(required), "{path} missing `{required}`");
        }
    }
    let sqlite_stream =
        read_repo_file("packages/agent/src/engine/durability/streams/sqlite_store.rs");
    for required in [
        "engine_stream_events",
        "engine_stream_subscriptions",
        "active = 0",
        "SET cursor = CASE",
        "\"engine_stream_event\"",
    ] {
        assert!(
            sqlite_stream.contains(required),
            "SQLite stream lifecycle missing `{required}`"
        );
    }

    let stores = read_repo_file("packages/agent/src/engine/primitives/stores.rs");
    assert_contains_in_order(
        "primitive store sqlite bundle",
        &stores,
        &[
            "fn sqlite(path: &std::path::Path) -> Result<Self>",
            "SqliteEngineStreamStore::open(path)?",
            "SqliteEngineStateStore::open(path)?",
            "SqliteEngineQueueStore::open(path)?",
            "SqliteEngineResourceLeaseStore::open(path)?",
            "SqliteEngineResourceStore::open(path)?",
            "SqliteEngineGrantStore::open(path)?",
            "SqliteEngineCompensationStore::open(path)?",
            "stores.install_builtin_resource_types()?",
        ],
    );

    let storage_schema = read_repo_file("packages/agent/src/shared/storage/schema.rs");
    for required in [
        "CREATE TABLE IF NOT EXISTS storage_checkpoints",
        "CREATE TABLE IF NOT EXISTS storage_exports",
        "CREATE TABLE IF NOT EXISTS storage_retention_runs",
        "CREATE TABLE IF NOT EXISTS storage_payload_refs",
        "retention_class",
        "expires_at",
    ] {
        assert!(
            storage_schema.contains(required),
            "shared storage schema missing `{required}`"
        );
    }
    let payloads = read_repo_file("packages/agent/src/shared/storage/payloads.rs");
    for required in [
        "store_owned_payload_ref",
        "storage_payload_refs",
        "owner_kind",
        "owner_id",
        "field_name",
        "retention_class",
        "resolve_payload_ref_envelope",
    ] {
        assert!(
            payloads.contains(required),
            "shared payload-ref lifecycle missing `{required}`"
        );
    }
    let maintenance = read_repo_file("packages/agent/src/shared/storage/maintenance.rs");
    for required in [
        "checkpoint_database",
        "export_snapshot",
        "retention_run",
        "DELETE FROM storage_payload_refs",
        "storage_checkpoints",
        "storage_exports",
        "storage_retention_runs",
    ] {
        assert!(
            maintenance.contains(required),
            "shared storage maintenance lifecycle missing `{required}`"
        );
    }
    let stats = read_repo_file("packages/agent/src/shared/storage/stats.rs");
    for required in [
        "payload_owner_stats",
        "expired_pending_payload_refs",
        "storage_payload_refs",
        "unowned_blob_count",
        "PayloadOwnerStorageStats",
    ] {
        assert!(
            stats.contains(required),
            "storage stats missing `{required}`"
        );
    }

    let inventory = inventory_by_path();
    for required in [
        "packages/agent/src/engine/authority/compensation.rs",
        "packages/agent/src/engine/authority/grants/mod.rs",
        "packages/agent/src/engine/authority/leases.rs",
        "packages/agent/src/engine/catalog/registry/idempotency.rs",
        "packages/agent/src/engine/catalog/registry/invocation.rs",
        "packages/agent/src/engine/durability/ledger/sqlite_store/mod.rs",
        "packages/agent/src/engine/durability/queue/sqlite_store.rs",
        "packages/agent/src/engine/durability/resources/store/mod.rs",
        "packages/agent/src/engine/durability/state.rs",
        "packages/agent/src/engine/durability/streams/sqlite_store.rs",
        "packages/agent/src/engine/invocation/host/meta_invocation.rs",
        "packages/agent/src/engine/primitives/stores.rs",
        "packages/agent/src/shared/storage/maintenance.rs",
        "packages/agent/src/shared/storage/mod.rs",
        "packages/agent/src/shared/storage/payloads.rs",
        "packages/agent/src/shared/storage/schema.rs",
        "packages/agent/src/shared/storage/stats.rs",
    ] {
        assert!(
            inventory
                .get(required)
                .is_some_and(|rows| rows.iter().any(|row| row.sol_rows.contains("SOL-5"))),
            "SOL inventory must tag {required} as part of SOL-5"
        );
    }
}
