use super::support::*;

#[test]
fn sol_engine_durable_substrate_lifecycle_is_source_backed() {
    let stores = read_repo_file("packages/agent/src/engine/primitives/stores.rs");
    assert_contains_in_order(
        "primitive store sqlite bundle",
        &stores,
        &[
            "fn sqlite(path: &std::path::Path) -> Result<Self>",
            "SqliteEngineStreamStore::open(path)?",
            "SqliteEngineStateStore::open(path)?",
        ],
    );
    for forbidden in [
        "GrantStore",
        "ResourceLeaseStore",
        "CompensationStore",
        "ResourceStore",
    ] {
        assert!(
            !stores.contains(forbidden),
            "retired substrate store leaked into the primitive bundle: {forbidden}"
        );
    }

    let ledger = read_repo_file("packages/agent/src/engine/durability/ledger/sqlite_store/mod.rs");
    for required in [
        "append_catalog_change",
        "append_invocation",
        "reserve_idempotency",
        "IdempotencyStatus::InProgress",
        "complete_idempotency",
        "IdempotencyStatus::Completed",
        "list_invocations_by_session",
        "list_idempotency_by_session",
    ] {
        assert!(
            ledger.contains(required),
            "engine ledger lifecycle missing `{required}`"
        );
    }
    for retired_column in [
        "authority_grant_id",
        "authority_scopes_json",
        "resource_lease_ids_json",
        "compensation_status",
        "produced_resource_refs_json",
    ] {
        assert!(
            !ledger.contains(retired_column),
            "active ledger still owns retired column `{retired_column}`"
        );
    }

    let state = read_repo_file("packages/agent/src/engine/durability/state.rs");
    for required in [
        "revision.saturating_add(1)",
        "compare_and_set",
        "state revision conflict",
        "DELETE FROM engine_state_entries",
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
            "poll",
            "list_by_session",
            "stream_scope_visible",
        ] {
            assert!(source.contains(required), "{path} missing `{required}`");
        }
    }

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
}
