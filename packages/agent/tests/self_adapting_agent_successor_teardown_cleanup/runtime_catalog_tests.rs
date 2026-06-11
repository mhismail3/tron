use crate::support::*;

#[test]
fn saastc_external_worker_runtime_lifecycle_is_loopback_bounded() {
    let runtime_root = read_repo_file("packages/agent/src/engine/runtime/mod.rs");
    let external_mod = read_repo_file("packages/agent/src/engine/runtime/external_workers/mod.rs");
    let lifecycle =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/lifecycle.rs");
    let activation =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/activation.rs");
    let registration =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/registration.rs");

    for required in [
        "pub mod external_workers;",
        "`EngineExternalWorkerRuntime` manages connected local workers.",
        "Activation tokens bind reviewed capability-definition governance",
        "volatile worker connection",
        "does not depend on HTTP handlers, domains, app\n//! bootstrap, or provider-specific model clients",
    ] {
        assert!(
            runtime_root.contains(required),
            "runtime module docs missing retained external-worker boundary {required}"
        );
    }

    for required in [
        "pub trait ExternalWorkerInvoker",
        "pub struct ExternalWorkerConnection",
        "pub struct EngineExternalWorkerRuntime",
        "connections: BTreeMap<WorkerId, ExternalWorkerConnection>",
        "invokers: BTreeMap<WorkerId, Arc<dyn ExternalWorkerInvoker>>",
        "WorkerProtocolMessage::Hello(hello)",
        "WorkerProtocolMessage::RegisterFunction(message)",
        "WorkerProtocolMessage::RegisterTrigger(message)",
        "WorkerProtocolMessage::PublishStream(message)",
        "WorkerProtocolMessage::Heartbeat(message)",
        "WorkerProtocolMessage::Disconnect(message)",
        "Ok(None)",
    ] {
        assert!(
            external_mod.contains(required),
            "external worker runtime root missing bounded protocol marker {required}"
        );
    }

    for required in [
        "if !hello.loopback_only",
        "WorkerAuthPolicy::LoopbackBearer",
        "hello.worker.kind != WorkerKind::External",
        "hello.identity.worker_id != worker_id",
        "validate_worker_token(&hello)?",
        "self.validate_activation_hello(&hello).await?",
        "self.validate_worker_grant(&hello).await?",
        "let volatile = hello.registration_mode == WorkerRegistrationMode::Volatile;",
        "self.host.register_worker(hello.worker, volatile).await?",
        "heartbeat.sequence <= connection.heartbeat_sequence",
        "pub async fn disconnect_timed_out(&mut self, timeout: Duration)",
        "reason: \"heartbeat timeout\".to_owned()",
        "self.invokers.remove(&disconnect.worker_id)",
        ".unregister_worker(&connection.worker_id, connection.owner_actor.as_str())",
        "self.mark_durable_worker_disconnected(&connection).await?",
        "CatalogSnapshot {\n            functions,\n            triggers: Vec::new(),\n        }",
        "grant.lifecycle != EngineGrantLifecycle::Active",
        "grant_policy_hash(&grant)",
        "connection.worker_token.authority_grant_id.clone()",
    ] {
        assert!(
            lifecycle.contains(required),
            "external worker lifecycle missing retained boundedness marker {required}"
        );
    }

    for required in [
        "validate_activation_hello",
        "validate_activation_function_registration",
        "validate_activation_trigger_registration",
        "activation workers must use volatile registration",
        "activation workers cannot request system visibility",
        "activation workers may register only the expected function",
        "activation workers cannot register triggers",
        "mark_activation_connected",
        "mark_activation_registered",
        "mark_activation_disconnected",
        "expected_current_version_id",
        "mark_failed_for_activation",
    ] {
        assert!(
            activation.contains(required),
            "external worker activation binding missing retained marker {required}"
        );
    }

    for required in [
        "pub fn attach_invoker(",
        "if !self.connections.contains_key(&worker_id)",
        "validate_activation_function_registration(&connection, &definition)",
        "validate_external_capability_metadata(",
        "stamp_external_capability_metadata(&mut definition, &connection.worker_token)",
        "connection.registration_mode == WorkerRegistrationMode::Volatile",
        "self.validate_activation_trigger_registration(&connection)?",
        "validate_worker_trigger(&self.host, &connection, &message.definition).await?",
        "publish_stream",
        "stream_topic_allowed_by_token(&connection.worker_token, &message.topic)",
        "external worker trigger authority grant must match the scoped token",
        "external worker trigger target",
        "external worker stream sessionId must match the scoped worker session",
    ] {
        assert!(
            registration.contains(required),
            "external worker registration missing retained scoped marker {required}"
        );
    }

    for (path, source) in [
        (
            "packages/agent/src/engine/runtime/external_workers/mod.rs",
            external_mod.as_str(),
        ),
        (
            "packages/agent/src/engine/runtime/external_workers/lifecycle.rs",
            lifecycle.as_str(),
        ),
        (
            "packages/agent/src/engine/runtime/external_workers/activation.rs",
            activation.as_str(),
        ),
        (
            "packages/agent/src/engine/runtime/external_workers/registration.rs",
            registration.as_str(),
        ),
    ] {
        for forbidden in [
            "tokio::spawn",
            "std::process::Command",
            "launchd",
            "SMAppService",
            "tron deploy",
            "packages/agent/skills",
            "providerMetadata",
            "postReadyPayload",
            "restartLoop",
            "retryLoop",
            "worker_schedule",
            "scheduler.run",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} must not own autonomous launch/deploy/provider/schedule surface: {forbidden}"
            );
        }
    }

    let external_worker_tests =
        read_repo_file("packages/agent/src/engine/tests/runtime/external_worker.rs");
    let delivery_tests =
        read_repo_file("packages/agent/src/engine/tests/runtime/external_worker_delivery.rs");
    let activation_tests =
        read_repo_file("packages/agent/src/engine/tests/runtime/worker_activation.rs");
    for required in [
        "local_external_worker_runtime_registers_session_functions_and_disconnects_cleanly",
        "local_external_worker_hello_requires_session_scoped_token_binding",
        "local_external_worker_hello_rejects_stale_grant_revision",
        "local_external_worker_hello_rejects_tampered_grant_hash",
        "local_external_worker_lifecycle_events_publish_through_streams_and_traces",
    ] {
        assert!(
            external_worker_tests.contains(required),
            "external worker runtime tests missing retained lifecycle regression {required}"
        );
    }
    for required in [
        "local_external_worker_durable_disconnect_marks_functions_unhealthy",
        "local_external_worker_heartbeat_timeout_unregisters_volatile_capabilities",
        ".disconnect_timed_out(std::time::Duration::from_secs(30))",
    ] {
        assert!(
            delivery_tests.contains(required),
            "external worker delivery tests missing retained boundedness regression {required}"
        );
    }
    for required in [
        "worker_activation_runtime_connects_registers_invokes_and_disconnects_volatile_function",
        "worker_activation_hello_rejects_token_scope_expansion_durable_and_revoked_grant",
        "worker_activation_registration_rejects_function_metadata_and_trigger_expansion",
    ] {
        assert!(
            activation_tests.contains(required),
            "worker activation runtime tests missing retained activation regression {required}"
        );
    }
}

#[test]
fn saastc_engine_catalog_module_exports_are_retained_fabric_only() {
    let engine_mod = read_repo_file("packages/agent/src/engine/mod.rs");
    let registry_mod = read_repo_file("packages/agent/src/engine/catalog/registry/mod.rs");
    let idempotency = read_repo_file("packages/agent/src/engine/catalog/registry/idempotency.rs");
    let invocation = read_repo_file("packages/agent/src/engine/catalog/registry/invocation.rs");
    let registration = read_repo_file("packages/agent/src/engine/catalog/registry/registration.rs");

    for required in [
        "Model providers do not see that transport surface\n//! directly; agents receive one model-facing capability, `execute`",
        "engine submodules are crate-private implementation",
        "must use the narrow facade re-exports in this module",
        "pub(crate) mod authority;",
        "pub(crate) mod catalog;",
        "pub(crate) mod durability;",
        "pub(crate) mod invocation;",
        "pub(crate) mod kernel;",
        "pub(crate) mod primitives;",
        "pub(crate) mod runtime;",
        "pub use catalog::registry::LiveCatalog;",
        "pub use invocation::host::{",
        "CatalogWatchRequest, CatalogWatchResponse, EngineHost, EngineHostHandle",
        "pub use runtime::external_workers::{",
        "EngineExternalWorkerRuntime, ExternalWorkerConnection, ExternalWorkerInvoker",
        "pub use runtime::triggers::{EngineTriggerRuntime, TriggerDispatchRequest};",
        "pub use runtime::worker_protocol::{",
        "pub use runtime::worker_schedule::{",
        "pub(crate) fn is_bootstrap_authority_grant_id",
    ] {
        assert!(
            engine_mod.contains(required),
            "engine module facade missing retained export/boundary marker {required}"
        );
    }
    for forbidden in [
        "pub mod authority;",
        "pub mod catalog;",
        "pub mod durability;",
        "pub mod invocation;",
        "pub mod kernel;",
        "pub mod primitives;",
        "pub mod runtime;",
        "domains::model::providers",
        "transport::engine",
        "std::process::Command",
        "tokio::spawn",
        "launchd",
        "SMAppService",
        "tron deploy",
        "packages/agent/skills",
    ] {
        assert!(
            !engine_mod.contains(forbidden),
            "engine facade must not widen module/provider/deploy surface: {forbidden}"
        );
    }

    for required in [
        "mod authorization;",
        "mod catalog_changes;",
        "mod cleanup;",
        "mod idempotency;",
        "mod invocation;",
        "mod output_contract;",
        "mod registration;",
        "mod search;",
        "pub(in crate::engine) use idempotency::InvocationIdempotencyDecision;",
        "pub(in crate::engine) use invocation::{PreparedSyncInvocation, PreparedSyncInvocationDecision};",
        "pub(super) fn durable_result_for_invocation",
        "activation_bundle_not_persisted",
        "\"scopedWorkerToken\": {\"redacted\": true}",
        "ledger: Box<dyn EngineLedgerStore>",
        "grants: Arc<StdMutex<EngineGrantStoreBackend>>",
        "pub(in crate::engine) fn set_grant_store",
    ] {
        assert!(
            registry_mod.contains(required),
            "catalog registry module missing retained private/export marker {required}"
        );
    }

    for required in [
        "pub(in crate::engine) enum InvocationIdempotencyDecision",
        "ReplayBehavior::ReturnPrevious",
        "ReplayBehavior::NoOp",
        "ReplayBehavior::Reject",
        "ReplayBehavior::Compensate",
        "compensation replay is not executable in phase 1",
        "pub(in crate::engine) fn begin_invocation_idempotency",
        "pub(in crate::engine) fn complete_invocation_idempotency",
        "LedgerKind::InMemory | LedgerKind::EngineLedger",
        "payload_fingerprint(&invocation.payload)",
        "write_canonical_json",
    ] {
        assert!(
            idempotency.contains(required),
            "catalog idempotency missing retained reservation/replay marker {required}"
        );
    }

    for required in [
        "pub(in crate::engine) struct PreparedSyncInvocation",
        "pub(in crate::engine) enum PreparedSyncInvocationDecision",
        "policy::validate_invocation",
        "policy::validate_trigger_target_invocation",
        "self.validate_invocation_grant(&function, &invocation)",
        "self.ledger.reserve_idempotency(reservation.clone())",
        "schema::validate_payload(&function.id, \"request\"",
        "self.consume_invocation_budget(&function, &invocation)",
        "PreparedSyncInvocationDecision::Execute",
        "pub(in crate::engine) fn finish_prepared_sync_invocation",
        "pub(in crate::engine) fn finish_prepared_sync_invocation_with_contracts",
        "validate_output_contract(&function, &invocation, &value)",
        "StoredInvocationOutcome::from_result(&durable_result)",
        "append_invocation",
    ] {
        assert!(
            invocation.contains(required),
            "catalog invocation missing retained prepare/finish marker {required}"
        );
    }

    for required in [
        "pub(in crate::engine) fn hydrate_durable_catalog_from_ledger",
        "worker.lifecycle = WorkerLifecycleState::Stopped",
        "function.health = FunctionHealth::Unhealthy",
        "validate_worker_namespace_claims(&definition)?",
        "self.validate_worker_grant(&definition)?",
        "validate_reserved_function_namespace(&definition)?",
        "self.validate_function_worker_grant(&definition, owner)?",
        "policy::validate_function_registration(&definition)?",
        "let persist_durable_external = !volatile && owner.kind == WorkerKind::External;",
        "self.cleanup_owned_volatile(id)?",
        "pub fn promote_function_visibility",
        "policy::validate_trigger_registration(",
        "fn validate_worker_namespace_claims",
        "fn validate_reserved_function_namespace",
    ] {
        assert!(
            registration.contains(required),
            "catalog registration missing retained owner/durability marker {required}"
        );
    }

    for (path, source) in [
        (
            "packages/agent/src/engine/catalog/registry/idempotency.rs",
            idempotency.as_str(),
        ),
        (
            "packages/agent/src/engine/catalog/registry/invocation.rs",
            invocation.as_str(),
        ),
        (
            "packages/agent/src/engine/catalog/registry/mod.rs",
            registry_mod.as_str(),
        ),
        (
            "packages/agent/src/engine/catalog/registry/registration.rs",
            registration.as_str(),
        ),
    ] {
        for forbidden in [
            "tokio::spawn",
            "std::process::Command",
            "launchd",
            "SMAppService",
            "tron deploy",
            "packages/agent/skills",
            "domains::model::providers",
            "postReadyPayload",
            "restartLoop",
            "retryLoop",
            "worker_schedule",
            "scheduler.run",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} must not own autonomous/provider/deploy/schedule surface: {forbidden}"
            );
        }
    }
}

#[test]
fn saastc_test_quality_rows_are_source_proven_and_fixture_grants_are_operation_scoped() {
    let catalog_tests =
        read_repo_file("packages/agent/src/engine/tests/catalog/catalog_discovery.rs");
    for required in [
        "discovery_is_sorted_and_filters_visibility_namespace_effect_risk_health_and_text",
        "discovery_enforces_scoped_visibility_and_internal_requires_admin",
        "mutating_function_requires_idempotency",
        "high_risk_agent_visible_function_requires_compensation_metadata",
        "unregister_function_removes_targeting_triggers_and_revisions_remain_monotonic",
        "catalog_change_ledger_failure_does_not_mutate_registered_catalog_entries",
    ] {
        assert!(
            catalog_tests.contains(required),
            "catalog tests must retain primitive catalog ownership/idempotency coverage {required}"
        );
    }

    let resource_contracts =
        read_repo_file("packages/agent/src/engine/tests/durability/resource_contracts.rs");
    for required in [
        "resource_kernel_builtin_definitions_keep_core_kinds_and_relations",
        "resource_kernel_rejects_invalid_payload_stale_cas_and_unsupported_links",
        "agent_memory",
        "agent_rule",
        "expected_current_version_id",
        "not_allowed",
        "does not allow relation",
    ] {
        assert!(
            resource_contracts.contains(required),
            "resource contract tests must retain schema/CAS/relation coverage {required}"
        );
    }

    let fixtures = read_repo_file("packages/agent/src/engine/tests/fixtures/mod.rs");
    for required in [
        "pub(in crate::engine::tests) fn external_visible_function",
        "pub(in crate::engine::tests) fn reject_idempotency",
        "pub(in crate::engine::tests) struct CatalogChangeFailingLedger",
        "pub(in crate::engine::tests) struct CountingHandler",
        "pub(in crate::engine::tests) fn write_function",
        "pub(in crate::engine::tests) fn engine_ledger_contract",
    ] {
        assert!(
            fixtures.contains(required),
            "engine shared fixtures must stay tied to retained primitive behavior {required}"
        );
    }

    let meta_tests =
        read_repo_file("packages/agent/src/engine/tests/invocation/meta_primitives.rs");
    for required in [
        "engine_meta_discover_and_inspect_are_live_and_scope_checked",
        "engine_invoke_delegates_with_parent_causality_and_target_policy",
        "public_engine_invoke_cannot_reach_hidden_visibility_targets",
        "engine_watch_filters_catalog_changes_without_leaking_hidden_scopes",
        "engine_internal_invoke_scope_does_not_make_public_context_trusted",
    ] {
        assert!(
            meta_tests.contains(required),
            "meta primitive tests must retain public/internal trust boundary coverage {required}"
        );
    }

    let invocation_mod = read_repo_file("packages/agent/src/engine/tests/invocation/mod.rs");
    for required in [
        "mod host_invocation;",
        "mod idempotency;",
        "mod meta_primitives;",
        "mod promotion_governance;",
        "mod worker_activation;",
    ] {
        assert!(
            invocation_mod.contains(required),
            "invocation test module must keep retained primitive suites wired {required}"
        );
    }

    let runtime_mod = read_repo_file("packages/agent/src/engine/tests/runtime/mod.rs");
    for required in [
        "mod external_worker;",
        "mod triggers;",
        "mod worker_activation;",
        "mod worker_orchestration;",
        "mod worker_schedule_dispatch;",
        "mod worker_trigger_launch;",
    ] {
        assert!(
            runtime_mod.contains(required),
            "runtime test module must keep retained runtime suites wired {required}"
        );
    }

    let worker_activation_tests =
        read_repo_file("packages/agent/src/engine/tests/runtime/worker_activation.rs");
    for required in [
        "worker_activation_runtime_connects_registers_invokes_and_disconnects_volatile_function",
        "worker_activation_hello_rejects_token_scope_expansion_durable_and_revoked_grant",
        "worker_activation_registration_rejects_function_metadata_and_trigger_expansion",
        "connected_activation_runtime",
        "activation_resource_status",
    ] {
        assert!(
            worker_activation_tests.contains(required),
            "worker activation runtime tests must prove retained lifecycle behavior {required}"
        );
    }

    let saa_mod = read_repo_file("packages/agent/tests/self_adapting_agent_authorship/mod.rs");
    for required in [
        "mod resource_fixtures;",
        "mod scorecard_inventory;",
        "mod source_guards;",
        "mod support;",
    ] {
        assert!(
            saa_mod.contains(required),
            "SAA authorship invariant module must wire only retained proof modules {required}"
        );
    }

    let saa_scorecard_inventory = read_repo_file(
        "packages/agent/tests/self_adapting_agent_authorship/scorecard_inventory.rs",
    );
    for required in [
        "saa_inventory_rows_are_structured_and_reference_tracked_paths",
        "saa_evidence_rows_cover_every_closed_scorecard_checkpoint",
        "saa_closeout_artifacts_reject_stale_state_after_completion",
    ] {
        assert!(
            saa_scorecard_inventory.contains(required),
            "SAA scorecard/inventory tests must remain evidence-integrity guards {required}"
        );
    }

    let saa_invariant_root =
        read_repo_file("packages/agent/tests/self_adapting_agent_authorship_invariants.rs");
    assert!(
        saa_invariant_root.contains("mod self_adapting_agent_authorship;"),
        "SAA authorship invariant target must remain a narrow module root"
    );

    let saa_support =
        read_repo_file("packages/agent/tests/self_adapting_agent_authorship/support.rs");
    for required in [
        "fn execute_grant_shape(operation: &str) -> ExecuteGrantShape",
        "\"resource_create\" => ExecuteGrantShape",
        "\"resource_link\" => ExecuteGrantShape",
        "\"resource_inspect\" => ExecuteGrantShape",
        "remaining_invocations: 4",
        "\"operation\": operation",
        "\"allowedCapabilities\": grant_shape.allowed_capabilities",
        "\"allowedAuthorityScopes\": grant_shape.allowed_authority_scopes",
        "\"remainingInvocations\": grant_shape.remaining_invocations",
        "unsupported SAA execute fixture operation",
    ] {
        assert!(
            saa_support.contains(required),
            "SAA authorship fixture grant must stay operation scoped {required}"
        );
    }
    for forbidden in [
        "\"state::get\"",
        "\"state::set\"",
        "\"state::list\"",
        "\"state.read\"",
        "\"state.write\"",
    ] {
        assert!(
            !saa_support.contains(forbidden),
            "SAA authorship fixture grant must not preserve broad state authority {forbidden}"
        );
    }
}
