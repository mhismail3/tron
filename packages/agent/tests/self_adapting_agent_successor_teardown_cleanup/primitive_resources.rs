use crate::support::*;

#[test]
fn saastc_primitive_surface_keeps_internal_source_proven_contracts() {
    let primitives = read_repo_file("packages/agent/src/engine/primitives/mod.rs");
    let runtime = read_repo_file("packages/agent/src/engine/primitives/runtime.rs");
    let stores = read_repo_file("packages/agent/src/engine/primitives/stores.rs");
    let activation_governance =
        read_repo_file("packages/agent/src/engine/primitives/worker_activation_governance.rs");
    let workers = read_repo_file("packages/agent/src/engine/primitives/workers.rs");
    let activation_fixture =
        read_repo_file("packages/agent/src/engine/tests/fixtures/worker_activation.rs");
    let activation_tests =
        read_repo_file("packages/agent/src/engine/tests/invocation/worker_activation.rs");

    for required in [
        "pub(in crate::engine) mod runtime;",
        "mod stores;",
        "mod worker_activation_governance;",
        "pub(in crate::engine) use stores::{",
        "pub(in crate::engine) use workers::{primitive_function_definitions, primitive_workers};",
        "worker::issue_activation",
        "`storage::*` is the",
    ] {
        assert!(
            primitives.contains(required),
            "primitive module root missing retained internal contract marker {required}"
        );
    }

    for required in [
        "pub(in crate::engine) trait PrimitiveRuntimeHost",
        "fn discover_functions(",
        "fn inspect_resource(",
        "fn derive_authority_grant(",
        "fn store_worker_activation_bundle(",
        "match invocation.function_id.as_str()",
        "worker::ISSUE_ACTIVATION_FUNCTION => worker_issue_activation(host, invocation)",
        "storage::RETENTION_RUN_FUNCTION => storage_retention_run(host, invocation)",
    ] {
        assert!(
            runtime.contains(required),
            "primitive runtime missing retained dispatch/store boundary {required}"
        );
    }
    for forbidden in [
        "tokio::spawn",
        "launchd",
        "SMAppService",
        "tron deploy",
        "providerMetadata",
        "postReadyPayload",
        "retryLoop",
        "restartLoop",
    ] {
        assert!(
            !runtime.contains(forbidden),
            "primitive runtime must not expose autonomous/provider/deploy surface {forbidden}"
        );
    }

    for required in [
        "pub(in crate::engine) enum ResourceStoreBackend",
        "fn register_type(",
        "fn create(",
        "fn update(",
        "fn link(",
        "fn inspect(",
        "fn list_page(",
        "builtin_resource_type_definitions()",
        "WorkerActivationBundleVault::new()",
        "WorkerProcessSupervisorRegistry::production()",
        "OnceLock<Weak<AsyncMutex<EngineHost>>>",
    ] {
        assert!(
            stores.contains(required),
            "primitive stores missing retained backend/host marker {required}"
        );
    }

    for required in [
        "candidate.resource.kind != \"capability_definition\"",
        "candidate.resource.lifecycle != \"reviewed\"",
        "ensure_candidate_scope_matches_request",
        "ensure_decision_approves_activation",
        "ensure_evidence_verified",
        "ensure_activation_chain",
        "EngineResourceScope::System => actor.actor_kind.is_admin_like()",
        "governance_fingerprint",
    ] {
        assert!(
            activation_governance.contains(required),
            "worker activation governance missing retained primitive guard {required}"
        );
    }

    for required in [
        ".with_namespace_claim(\"worker_activation\")",
        ".with_namespace_claim(\"worker_launch_plan\")",
        ".with_namespace_claim(\"worker_autostart_plan\")",
        ".with_namespace_claim(\"worker_trigger_launch_attempt\")",
        ".with_namespace_claim(\"worker_schedule_plan\")",
        ".with_namespace_claim(\"worker_schedule_tick\")",
        ".with_namespace_claim(\"worker_schedule_scan_state\")",
        ".with_namespace_claim(\"worker_process\")",
        "registrations.extend(worker::registrations(stores)?);",
        "registrations.extend(storage::registrations()?);",
    ] {
        assert!(
            workers.contains(required),
            "primitive worker assembly missing retained namespace/registration {required}"
        );
    }

    for required in [
        "pub resource_scope: Option<VisibilityScope>",
        "unwrap_or(&config.target_visibility)",
        "\"scope\": resource_scope.as_str()",
    ] {
        assert!(
            activation_fixture.contains(required),
            "worker activation fixture missing scoped governance regression support {required}"
        );
    }
    for required in [
        "system_scoped.resource_scope = Some(VisibilityScope::System)",
        "mutating_causal(\"saawa-system-governance\").with_scope(\"worker.activate\")",
        "scope is incompatible with activation target",
    ] {
        assert!(
            activation_tests.contains(required),
            "worker activation tests missing system-governance authority regression {required}"
        );
    }
}

#[test]
fn saastc_resource_substrate_keeps_only_retained_safe_resource_contracts() {
    let sqlite_store =
        read_repo_file("packages/agent/src/engine/durability/resources/store/mod.rs");
    let memory_store =
        read_repo_file("packages/agent/src/engine/durability/resources/store/memory.rs");
    for source in [&sqlite_store, &memory_store] {
        assert!(
            !source.contains("pub fn list_types"),
            "resource stores must not expose the removed type-catalog listing API"
        );
    }

    let definitions =
        read_repo_file("packages/agent/src/engine/durability/resources/definitions.rs");
    let agent_records = read_repo_file(
        "packages/agent/src/engine/durability/resources/agent_record_definitions.rs",
    );
    let schedule_records = read_repo_file(
        "packages/agent/src/engine/durability/resources/worker_schedule_definitions.rs",
    );
    let validation = read_repo_file("packages/agent/src/engine/durability/resources/validation.rs");
    let types = read_repo_file("packages/agent/src/engine/durability/resources/types.rs");
    let primitive_stores = read_repo_file("packages/agent/src/engine/primitives/stores.rs");
    let store_tests =
        read_repo_file("packages/agent/src/engine/durability/resources/store/tests.rs");

    for required in [
        "agent_record_resource_type_definitions()",
        "worker_schedule_resource_type_definitions()",
        "\"worker_activation\"",
        "\"tron.resource.worker_activation.v1\"",
        "\"worker_process\"",
        "\"tron.resource.worker_process.v1\"",
        "\"additionalProperties\": false",
        "\"tokenFingerprint\"",
        "\"tokenStorage\"",
        "\"registrationMode\"",
        "\"volatile\"",
        "\"networkPolicy\"",
        "\"loopback\"",
        "\"restartPolicy\"",
        "\"none\"",
        "\"duplicatePolicy\"",
        "\"idempotency_key_replay_v1\"",
    ] {
        assert!(
            definitions.contains(required),
            "resource definitions missing retained safe worker contract marker {required}"
        );
    }
    for forbidden in [
        "scopedWorkerToken",
        "activationBundle",
        "postReadyPayload",
        "restartLoop",
        "retryLoop",
        "launchd",
        "SMAppService",
        "apiKey",
        "accessToken",
        "refreshToken",
        "clientSecret",
        "password",
        "credential",
    ] {
        assert!(
            !definitions.contains(forbidden),
            "resource definitions must not persist forbidden worker/secret surface {forbidden}"
        );
    }

    for required in [
        "\"agent_memory\"",
        "\"tron.resource.agent_memory.v1\"",
        "\"agent_rule\"",
        "\"tron.resource.agent_rule.v1\"",
        "\"required\": [\"statement\", \"status\", \"scope\", \"provenance\", \"evidenceRefs\"]",
        "\"additionalProperties\": false",
        "\"supersededByResourceId\"",
        "\"revokedByResourceId\"",
    ] {
        assert!(
            agent_records.contains(required),
            "agent record definitions missing retained authorship marker {required}"
        );
    }

    for required in [
        "\"worker_schedule_plan\"",
        "\"worker_schedule_tick\"",
        "\"worker_schedule_scan_state\"",
        "\"additionalProperties\": false",
        "\"pageSize\": {\"type\": \"integer\", \"minimum\": 1, \"maximum\": 500}",
        "\"maxPerPoll\": {\"type\": \"integer\", \"minimum\": 1, \"maximum\": 500}",
    ] {
        assert!(
            schedule_records.contains(required),
            "schedule resource definitions missing retained bounded-state marker {required}"
        );
    }

    for required in [
        "validate_create_request",
        "validate_update_request",
        "validate_link_request",
        "validate_list_page_request",
        "validate_resource_payload",
        "schema::validate_payload",
        "validate_ui_surface_payload",
    ] {
        assert!(
            validation.contains(required),
            "resource validation missing retained gate {required}"
        );
    }
    for required in [
        "expected_current_version_id",
        "ResourceListCursor",
        "next_cursor",
        "has_more",
        "EngineResourceVersionState",
        "may_be_current",
    ] {
        assert!(
            types.contains(required),
            "resource types missing retained determinism/CAS/page marker {required}"
        );
    }
    for required in [
        "pub(in crate::engine) enum ResourceStoreBackend",
        "fn register_type(",
        "fn create(",
        "fn update(",
        "fn link(",
        "fn inspect(",
        "fn list(",
        "fn list_page(",
        "builtin_resource_type_definitions()",
    ] {
        assert!(
            primitive_stores.contains(required),
            "PrimitiveStores resource backend missing retained access marker {required}"
        );
    }
    assert!(
        !primitive_stores.contains("list_types("),
        "PrimitiveStores must not reintroduce resource type catalog listing"
    );

    for required in [
        "resource_payloads_must_match_registered_schema_before_persisting",
        "sqlite_resource_store_round_trips_full_substrate",
        "sqlite_resource_pages_match_in_memory_cursor_semantics",
        "resource_list_is_filtered_by_kind_scope_and_lifecycle",
    ] {
        assert!(
            store_tests.contains(required),
            "resource store tests missing retained regression {required}"
        );
    }
}
