use super::support::*;

#[test]
fn retained_registered_contracts_do_not_encode_approval_or_policy_planes() {
    for (label, path) in [
        (
            "agent contract",
            "packages/agent/src/domains/agent/contract.rs",
        ),
        (
            "auth contract",
            "packages/agent/src/domains/auth/contract.rs",
        ),
        (
            "message domain",
            "packages/agent/src/domains/message/mod.rs",
        ),
        (
            "model contract",
            "packages/agent/src/domains/model/contract.rs",
        ),
        (
            "session contract",
            "packages/agent/src/domains/session/contract.rs",
        ),
        (
            "settings contract",
            "packages/agent/src/domains/settings/contract.rs",
        ),
        ("system domain", "packages/agent/src/domains/system/mod.rs"),
    ] {
        let source = read_repo_file(path);
        assert_absent(
            &source,
            &[
                ".approval_required(",
                ".high_risk_contract(",
                "approvalRequired",
                "approval required",
                "guardrail",
                "policy",
            ],
            label,
        );
    }
}

#[test]
fn engine_registration_policy_has_no_approval_metadata_exceptions() {
    let policy = read_repo_file("packages/agent/src/engine/kernel/policy.rs");
    assert_absent(
        &policy,
        &[
            "requires approval metadata",
            "requires_approval_for_agent_visibility",
            "sandboxAutonomy",
            "conditionalApproval",
            "approvalRequiredFor",
            "highRiskContract",
        ],
        "engine registration policy",
    );

    let types = [
        read_repo_file("packages/agent/src/engine/kernel/types/mod.rs"),
        read_repo_file("packages/agent/src/engine/kernel/types/catalog.rs"),
        read_repo_file("packages/agent/src/engine/kernel/types/function.rs"),
        read_repo_file("packages/agent/src/engine/kernel/types/trigger.rs"),
        read_repo_file("packages/agent/src/engine/kernel/types/worker.rs"),
    ]
    .join("\n");
    assert_absent(
        &types,
        &[
            "requires_approval_for_agent_visibility",
            "requires explicit approval metadata",
        ],
        "engine effect helpers",
    );
}

#[test]
fn self_authored_worker_pack_primitives_are_not_registered_or_left_on_disk() {
    let primitives = read_repo_file("packages/agent/src/engine/primitives/mod.rs");
    assert_absent(
        &primitives,
        &[
            "MODULE_WORKER_ID",
            "module::registrations",
            "primitive_worker(MODULE_WORKER_ID",
            ".with_namespace_claim(\"worker_package\")",
            ".with_namespace_claim(\"module_config\")",
            ".with_namespace_claim(\"activation_record\")",
        ],
        "engine primitive registration",
    );

    let runtime = read_repo_file("packages/agent/src/engine/primitives/runtime.rs");
    assert_absent(
        &runtime,
        &[
            "mod worker_protocol",
            "worker::PROTOCOL_GUIDE_FUNCTION",
            "worker_protocol::guide",
        ],
        "host-dispatched primitive runtime",
    );

    let worker = read_repo_file("packages/agent/src/engine/primitives/worker.rs");
    assert_absent(
        &worker,
        &[
            "PROTOCOL_GUIDE_FUNCTION",
            "worker::protocol_guide",
            "worker::spawn",
            "sandbox-created",
            "pythonTemplate",
            "spawnWorkerPayloadExample",
            "worker pack",
        ],
        "worker primitive contracts",
    );

    for path in [
        "packages/agent/src/engine/primitives/module.rs",
        "packages/agent/src/engine/primitives/module",
        "packages/agent/src/engine/primitives/action_summary.rs",
        "packages/agent/src/engine/primitives/control/actions.rs",
        "packages/agent/src/engine/primitives/runtime/worker_protocol.rs",
        "packages/agent/src/engine/primitives/runtime/worker_protocol_template.py",
        "packages/agent/src/engine/primitives/ui/authoring",
        "packages/agent/src/engine/primitives/ui/authoring/source_control.rs",
        "packages/agent/src/engine/primitives/ui/authoring/actions.rs",
        "packages/agent/src/engine/host/module_jobs.rs",
        "packages/agent/src/engine/tests/module_activation.rs",
        "packages/agent/src/engine/tests/module_activation",
    ] {
        assert_repo_path_absent(path, "self-authored worker-pack substrate");
    }

    let readme = read_repo_file("README.md");
    assert_absent(
        &readme,
        &[
            "module::",
            "worker::spawn",
            "worker::protocol_guide",
            "worker pack",
            "worker packs",
            "sandbox-created",
        ],
        "README",
    );
}

#[test]
fn capability_registry_recipe_and_conformance_scaffolding_is_deleted() {
    for path in [
        "packages/agent/src/domains/capability/registry",
        "packages/agent/src/domains/capability/embeddings.rs",
        "packages/agent/src/domains/capability/types.rs",
        "packages/agent/src/domains/capability/operations/admin.rs",
        "packages/agent/src/domains/capability/operations/audit.rs",
        "packages/agent/src/domains/capability/operations/execute.rs",
        "packages/agent/src/domains/capability/operations/inspect.rs",
        "packages/agent/src/domains/capability/operations/presentation.rs",
        "packages/agent/src/domains/capability/operations/run.rs",
        "packages/agent/src/domains/capability/operations/schema_validation.rs",
        "packages/agent/src/domains/capability/operations/search.rs",
        "packages/agent/src/domains/capability/operations/target_arguments.rs",
        "packages/agent/src/domains/capability/operations/target_resolution.rs",
        "packages/agent/src/domains/capability/operations/tests",
    ] {
        assert_repo_path_absent(path, "capability catalog scaffold");
    }

    for (label, path) in [
        (
            "capability module docs",
            "packages/agent/src/domains/capability/mod.rs",
        ),
        (
            "capability contract",
            "packages/agent/src/domains/capability/contract.rs",
        ),
        (
            "primitive execute implementation",
            "packages/agent/src/domains/capability/operations/mod.rs",
        ),
    ] {
        let source = read_repo_file(path);
        assert_absent(
            &source,
            &[
                "capability registry",
                "registry",
                "recipe",
                "recipes",
                "plugin",
                "plugins",
                "binding",
                "bindings",
                "capability conformance",
                "conformance scaffold",
                "vector search",
                "policy profile",
                "policy-profile",
                "capability::search",
                "capability::inspect",
            ],
            label,
        );
    }

    let readme = read_repo_file("README.md");
    assert_absent(
        &readme,
        &[
            "capability registry",
            "capability-registry",
            "registry/index projection",
            "capability::registry",
            "CapabilityRegistrySnapshot",
            "capability recipes",
            "capability::search",
            "capability::inspect",
            "vector search",
            "policy profile",
            "policy-profile",
        ],
        "README capability substrate references",
    );
}

#[test]
fn agent_trace_records_are_first_class_and_agent_visible() {
    let migration = read_repo_file(
        "packages/agent/src/domains/session/event_store/sqlite/migrations/v001_schema.sql",
    );
    for required in [
        "CREATE TABLE IF NOT EXISTS trace_records",
        "trace_id",
        "invocation_id",
        "parent_invocation_id",
        "provider_invocation_id",
        "session_id",
        "workspace_id",
        "turn",
        "model_primitive_name",
        "operation",
        "status",
        "record_json",
        "idx_trace_records_trace",
        "idx_trace_records_session",
        "idx_trace_records_invocation",
    ] {
        assert!(
            migration.contains(required),
            "fresh schema must persist first-class trace record field/index: {required}"
        );
    }

    let trace_types = read_repo_file("packages/agent/src/domains/session/event_store/trace.rs");
    for required in [
        "AGENT_TRACE_VERSION",
        "TRON_TRACE_METADATA_KEY",
        "AgentTraceRecord",
        "provider_invocation_id",
        "model_primitive_name",
        "record_json: Value",
        "AgentTraceListOptions",
    ] {
        assert!(
            trace_types.contains(required),
            "trace type module missing required primitive trace type text: {required}"
        );
    }

    let trace_repo = read_repo_file(
        "packages/agent/src/domains/session/event_store/sqlite/repositories/trace.rs",
    );
    for required in [
        "INSERT INTO trace_records",
        "UPDATE trace_records",
        "FROM trace_records",
        "WHERE session_id = ?1 AND trace_id = ?2",
        "ORDER BY timestamp DESC",
        "serde_json::from_str",
    ] {
        assert!(
            trace_repo.contains(required),
            "trace repository missing durable query/storage behavior: {required}"
        );
    }

    let trace_log = read_repo_file(
        "packages/agent/src/domains/session/event_store/store/event_store/trace_log.rs",
    );
    for required in [
        "append_trace_record",
        "update_trace_record",
        "get_trace_record",
        "list_trace_records",
    ] {
        assert!(
            trace_log.contains(required),
            "event store trace log missing required method: {required}"
        );
    }

    let contract = read_repo_file("packages/agent/src/domains/capability/contract.rs");
    for required in [
        "trace_list",
        "trace_get",
        "log_recent",
        "inspect agent trace/log records",
        "\"traceRecordId\"",
        "\"traceId\"",
    ] {
        assert!(
            contract.contains(required),
            "execute contract must expose agent-visible trace query operation: {required}"
        );
    }

    let operations = read_repo_source_trees(&["packages/agent/src/domains/capability/operations"]);
    for required in [
        "append_trace_record(&trace_record)",
        "update_trace_record(&trace_record)",
        "execute_operation(&operation",
        "\"trace_list\" => trace_list",
        "\"trace_get\" => trace_get",
        "\"log_recent\" => log_recent",
        "AgentTraceListOptions",
        "AGENT_TRACE_VERSION",
        "TRON_TRACE_METADATA_KEY",
        "\"providerInvocationId\"",
        "\"modelId\"",
        "\"provider\"",
        "\"workingDirectory\"",
        "workingDirectoryError",
        "\"authority\"",
        "\"requestHash\"",
        "\"resultHash\"",
        "\"content_hash\"",
        "\"model_id\"",
        "RUNTIME_METADATA_PROVIDER_TYPE",
        "trace_working_directory_metadata",
        "normalize_working_directory",
        "git_vcs",
        "execute::log_recent",
    ] {
        assert!(
            operations.contains(required),
            "execute operation trace wrapper missing primitive trace behavior: {required}"
        );
    }
    assert_absent(
        &operations,
        &[
            "observability::trace_get",
            "observability::trace_list",
            "capability::search",
            "capability::inspect",
        ],
        "primitive execute trace path",
    );

    let primitive_surface =
        read_repo_file("packages/agent/src/domains/agent/loop/primitive_surface.rs");
    assert!(
        primitive_surface.contains("\"capability.execute\""),
        "primitive surface resolver must authorize the one execute primitive"
    );
    assert_absent(
        &primitive_surface,
        &["capability.search", "capability.inspect"],
        "primitive surface resolver",
    );
    assert_repo_path_absent(
        "packages/agent/src/domains/capability_support",
        "top-level capability_support domain abstraction",
    );

    let executor = read_repo_file(
        "packages/agent/src/domains/agent/loop/capability_invocation_executor/mod.rs",
    );
    for required in [
        "RUNTIME_METADATA_PROVIDER_INVOCATION_ID",
        "RUNTIME_METADATA_PROVIDER_TYPE",
        "RUNTIME_METADATA_WORKING_DIRECTORY",
        "RUNTIME_METADATA_MODEL_PRIMITIVE_NAME",
        "RUNTIME_METADATA_TURN",
        "RUNTIME_METADATA_RUN_ID",
        ".with_scope(\"capability.execute\")",
    ] {
        assert!(
            executor.contains(required),
            "capability executor must attach trusted trace runtime metadata: {required}"
        );
    }
    assert_absent(
        &executor,
        &["capability.search", "capability.inspect"],
        "capability executor authority envelope",
    );

    let integration_test = read_repo_file("packages/agent/tests/primitive_trace_execution.rs");
    for required in [
        "execute_filesystem_write_records_agent_trace_and_trace_list_exposes_it",
        "execute_process_run_expands_home_alias_in_trace_working_directory",
        "execute_log_recent_exposes_bounded_session_trace_logs",
        "\"operation\": \"trace_list\"",
        "\"operation\": \"trace_get\"",
        "\"operation\": \"process_run\"",
        "\"operation\": \"log_recent\"",
        "\"provider-call-write-1\"",
        "\"provider-call-get-1\"",
        "\"provider-call-pwd-1\"",
        "\"gpt-5.5\"",
        "\"workingDirectory\"",
        "\"model_id\"",
        "\"content_hash\"",
    ] {
        assert!(
            integration_test.contains(required),
            "trace integration proof missing required evidence assertion: {required}"
        );
    }

    let readme = read_repo_file("README.md");
    for required in [
        "trace_list",
        "trace_get",
        "trace_records",
        "provider type",
        "canonical working directory",
    ] {
        assert!(
            readme.contains(required),
            "README must document primitive traceability surface: {required}"
        );
    }
    assert_absent(
        &readme,
        &["observability::trace_get", "observability::trace_list"],
        "README model-visible trace documentation",
    );
}

#[test]
fn primitive_branch_has_no_product_update_surface() {
    assert_repo_path_absent(
        "packages/agent/src/platform/updater",
        "server user-mode updater module",
    );
    assert_repo_path_absent(
        "packages/agent/src/domains/settings/implementation/types/update.rs",
        "server update settings schema",
    );

    let retained_source = read_repo_source_trees(&[
        "packages/agent/src",
        "packages/ios-app/Sources",
        "packages/ios-app/Tests",
        "packages/mac-app/Sources",
        "packages/mac-app/Tests",
    ]);
    assert_absent(
        &retained_source,
        &[
            "platform::updater",
            "pub mod updater",
            "system::check_for_updates",
            "system::get_update_status",
            "SystemCheckForUpdatesResult",
            "SystemUpdateStatusResult",
            "checkForUpdates",
            "getUpdateStatus",
            "UpdateSettings",
            "UpdateChannel",
            "UpdateFrequency",
            "UpdateAction",
            "updateEnabled",
            "updateChannel",
            "updateFrequency",
            "updateAction",
            "updater-state.json",
            "auto-update.pause",
            "server.update_available",
            "release_fetcher",
            "updater_state_path",
        ],
        "retained source product update surface",
    );

    let scripts = ["scripts/tron", "scripts/tron-lib.sh"]
        .into_iter()
        .map(read_repo_file)
        .collect::<Vec<_>>()
        .join("\n");
    assert_absent(
        &scripts,
        &["self-update", "auto-update.pause", "updater-state.json"],
        "CLI product update surface",
    );

    let bundled_profile = read_repo_file("packages/agent/defaults/profiles/default/profile.toml");
    assert_absent(
        &bundled_profile,
        &["[settings.server.update]", "server.update"],
        "bundled default profile update settings",
    );
}
