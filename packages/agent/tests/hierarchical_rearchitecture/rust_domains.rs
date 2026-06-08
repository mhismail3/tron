use super::support::*;

#[test]
fn rust_session_domain_uses_lifecycle_query_reconstruction_owners() {
    let required = [
        "packages/agent/src/domains/session/lifecycle/mod.rs",
        "packages/agent/src/domains/session/query/mod.rs",
        "packages/agent/src/domains/session/reconstruction/mod.rs",
    ];
    let banned = [
        "packages/agent/src/domains/session/commands",
        "packages/agent/src/domains/session/operations.rs",
        "packages/agent/src/domains/session/queries.rs",
        "packages/agent/src/domains/session/reconstruct.rs",
    ];

    let missing: Vec<_> = required
        .iter()
        .copied()
        .filter(|path| !repo_path(path).exists())
        .collect();
    let present_banned: Vec<_> = banned
        .iter()
        .copied()
        .filter(|path| repo_path(path).exists())
        .collect();

    assert!(
        missing.is_empty() && present_banned.is_empty(),
        "Session domain must use lifecycle/query/reconstruction ownership after HRA-6; missing: {missing:#?}; old paths still present: {present_banned:#?}"
    );
}

#[test]
fn rust_session_event_store_has_no_same_name_file_folder_pairs() {
    let mut pairs = Vec::new();
    let mut source_files = Vec::new();
    list_source_files(
        &repo_path("packages/agent/src/domains/session/event_store"),
        &["rs"],
        &mut source_files,
    );
    for file in source_files {
        let sibling_folder = file.with_extension("");
        if sibling_folder.is_dir() {
            pairs.push(
                file.strip_prefix(repo_root())
                    .unwrap()
                    .display()
                    .to_string(),
            );
        }
    }

    assert!(
        pairs.is_empty(),
        "Session event-store must not retain avoidable same-name file/folder module pairs after HRA-6: {pairs:#?}"
    );
}

#[test]
fn rust_session_event_store_uses_owned_modules_without_path_attrs() {
    let required = [
        "packages/agent/src/domains/session/event_store/envelope/mod.rs",
        "packages/agent/src/domains/session/event_store/factory/mod.rs",
        "packages/agent/src/domains/session/event_store/reconstruction/mod.rs",
        "packages/agent/src/domains/session/event_store/store/event_store/mod.rs",
        "packages/agent/src/domains/session/event_store/sqlite/repositories/session/mod.rs",
        "packages/agent/src/domains/session/event_store/sqlite/migrations/tests/mod.rs",
    ];
    let banned = [
        "packages/agent/src/domains/session/event_store/event",
        "packages/agent/src/domains/session/event_store/store/event_store.rs",
        "packages/agent/src/domains/session/event_store/store/tests.rs",
        "packages/agent/src/domains/session/event_store/sqlite/repositories/session.rs",
        "packages/agent/src/domains/session/event_store/sqlite/repositories/session/tests.rs",
        "packages/agent/src/domains/session/event_store/sqlite/migrations/tests.rs",
    ];

    let missing: Vec<_> = required
        .iter()
        .copied()
        .filter(|path| !repo_path(path).exists())
        .collect();
    let present_banned: Vec<_> = banned
        .iter()
        .copied()
        .filter(|path| repo_path(path).exists())
        .collect();
    let session_event_store_source =
        read_repo_file("packages/agent/src/domains/session/event_store/mod.rs");

    assert!(
        missing.is_empty() && present_banned.is_empty(),
        "Session event-store must expose owned module files after HRA-6; missing: {missing:#?}; old paths still present: {present_banned:#?}"
    );
    assert!(
        !session_event_store_source.contains("#[path ="),
        "Session event-store root must not route around owned module paths with #[path] aliases"
    );
}

#[test]
fn rust_session_event_repository_tests_are_behavior_split() {
    let required = [
        "packages/agent/src/domains/session/event_store/sqlite/repositories/event/tests/append_order_counters.rs",
        "packages/agent/src/domains/session/event_store/sqlite/repositories/event/tests/pagination_filters.rs",
        "packages/agent/src/domains/session/event_store/sqlite/repositories/event/tests/payload_blob_resolution.rs",
        "packages/agent/src/domains/session/event_store/sqlite/repositories/event/tests/reconstruction_state.rs",
    ];
    let missing: Vec<_> = required
        .iter()
        .copied()
        .filter(|path| !repo_path(path).exists())
        .collect();

    assert!(
        missing.is_empty(),
        "Session event repository tests must be split by behavior after HRA-6: {missing:#?}"
    );
    assert!(
        !repo_path(
            "packages/agent/src/domains/session/event_store/sqlite/repositories/event/tests.rs"
        )
        .exists(),
        "Session event repository must not retain one oversized tests.rs after HRA-6"
    );
}

#[test]
fn rust_domain_root_has_only_owned_boundaries() {
    let required = [
        "packages/agent/src/domains/registration/mod.rs",
        "packages/agent/src/domains/registration/bindings.rs",
        "packages/agent/src/domains/registration/catalog.rs",
        "packages/agent/src/domains/registration/contract.rs",
        "packages/agent/src/domains/registration/worker.rs",
    ];
    let banned = [
        "packages/agent/src/domains/bindings.rs",
        "packages/agent/src/domains/catalog.rs",
        "packages/agent/src/domains/contract.rs",
        "packages/agent/src/domains/registration.rs",
        "packages/agent/src/domains/resource_projection.rs",
        "packages/agent/src/domains/worker.rs",
    ];

    let missing: Vec<_> = required
        .iter()
        .copied()
        .filter(|path| !repo_path(path).exists())
        .collect();
    let present_banned: Vec<_> = banned
        .iter()
        .copied()
        .filter(|path| repo_path(path).exists())
        .collect();

    assert!(
        missing.is_empty() && present_banned.is_empty(),
        "Domain root must be a map of domain owners plus registration helpers; missing: {missing:#?}; old loose helpers still present: {present_banned:#?}"
    );
}

#[test]
fn rust_agent_domain_uses_prompt_loop_context_owners() {
    let required = [
        "packages/agent/src/domains/agent/prompt/mod.rs",
        "packages/agent/src/domains/agent/prompt/commands.rs",
        "packages/agent/src/domains/agent/prompt/prompt.rs",
        "packages/agent/src/domains/agent/prompt/service.rs",
        "packages/agent/src/domains/agent/loop/mod.rs",
        "packages/agent/src/domains/agent/loop/turn_runner/mod.rs",
        "packages/agent/src/domains/agent/loop/orchestrator/mod.rs",
        "packages/agent/src/domains/agent/context/mod.rs",
        "packages/agent/src/domains/agent/context/context_manager/mod.rs",
    ];
    let banned = [
        "packages/agent/src/domains/agent/commands.rs",
        "packages/agent/src/domains/agent/operations",
        "packages/agent/src/domains/agent/runner",
    ];

    let missing: Vec<_> = required
        .iter()
        .copied()
        .filter(|path| !repo_path(path).exists())
        .collect();
    let present_banned: Vec<_> = banned
        .iter()
        .copied()
        .filter(|path| repo_path(path).exists())
        .collect();

    assert!(
        missing.is_empty() && present_banned.is_empty(),
        "Agent domain must use prompt/loop/context ownership after HRA-5; missing: {missing:#?}; old paths still present: {present_banned:#?}"
    );
}

#[test]
fn rust_auth_domain_uses_oauth_and_credentials_owners() {
    let required = [
        "packages/agent/src/domains/auth/oauth/mod.rs",
        "packages/agent/src/domains/auth/oauth/flows.rs",
        "packages/agent/src/domains/auth/oauth/operations.rs",
        "packages/agent/src/domains/auth/credentials/mod.rs",
        "packages/agent/src/domains/auth/credentials/accounts.rs",
        "packages/agent/src/domains/auth/credentials/provider_state.rs",
        "packages/agent/src/domains/auth/credentials/storage/mod.rs",
    ];
    let banned = [
        "packages/agent/src/domains/auth/flows.rs",
        "packages/agent/src/domains/auth/operations",
        "packages/agent/src/domains/auth/provider_credentials",
    ];

    let missing: Vec<_> = required
        .iter()
        .copied()
        .filter(|path| !repo_path(path).exists())
        .collect();
    let present_banned: Vec<_> = banned
        .iter()
        .copied()
        .filter(|path| repo_path(path).exists())
        .collect();

    assert!(
        missing.is_empty() && present_banned.is_empty(),
        "Auth domain must use oauth/ and credentials/ ownership after HRA-5; missing: {missing:#?}; old paths still present: {present_banned:#?}"
    );
}

#[test]
fn rust_model_domain_uses_routing_and_protocol_owners() {
    let required = [
        "packages/agent/src/domains/model/routing/mod.rs",
        "packages/agent/src/domains/model/routing/catalog.rs",
        "packages/agent/src/domains/model/routing/presets.rs",
        "packages/agent/src/domains/model/routing/models/mod.rs",
        "packages/agent/src/domains/model/protocol/mod.rs",
        "packages/agent/src/domains/model/protocol/capability_parsing.rs",
        "packages/agent/src/domains/model/protocol/id_remapping.rs",
    ];
    let banned = [
        "packages/agent/src/domains/model/catalog.rs",
        "packages/agent/src/domains/model/operations",
        "packages/agent/src/domains/model/presets.rs",
        "packages/agent/src/domains/model/provider_protocol",
        "packages/agent/src/domains/model/providers/models",
    ];

    let missing: Vec<_> = required
        .iter()
        .copied()
        .filter(|path| !repo_path(path).exists())
        .collect();
    let present_banned: Vec<_> = banned
        .iter()
        .copied()
        .filter(|path| repo_path(path).exists())
        .collect();

    assert!(
        missing.is_empty() && present_banned.is_empty(),
        "Model domain must use routing/ and protocol/ ownership after HRA-5; missing: {missing:#?}; old paths still present: {present_banned:#?}"
    );
}

#[test]
fn rust_capability_execute_operations_are_decomposed() {
    let required = [
        "packages/agent/src/domains/capability/operations/filesystem.rs",
        "packages/agent/src/domains/capability/operations/logs.rs",
        "packages/agent/src/domains/capability/operations/process.rs",
        "packages/agent/src/domains/capability/operations/state.rs",
        "packages/agent/src/domains/capability/operations/trace.rs",
    ];
    let missing: Vec<_> = required
        .iter()
        .copied()
        .filter(|path| !repo_path(path).exists())
        .collect();
    let root = repo_path("packages/agent/src/domains/capability/operations/mod.rs");
    let root_source = read_repo_file("packages/agent/src/domains/capability/operations/mod.rs");

    assert!(
        missing.is_empty(),
        "capability::execute operations must be decomposed by primitive concern: {missing:#?}"
    );
    assert!(
        source_line_count(&root) <= 500,
        "capability operations root should be dispatch/audit glue only after HRA-5"
    );
    for banned in [
        "async fn file_read",
        "async fn file_write",
        "async fn process_run",
        "fn trace_list",
        "fn trace_get",
        "async fn log_recent",
    ] {
        assert!(
            !root_source.contains(banned),
            "capability operations root must not retain primitive body `{banned}`"
        );
    }
}

#[test]
fn rust_settings_domain_keeps_worker_root_thin() {
    let root = read_repo_file("packages/agent/src/domains/settings/mod.rs");
    assert!(
        repo_path("packages/agent/src/domains/settings/profile/operations.rs").exists(),
        "settings operation bodies should live under the settings profile owner"
    );
    assert!(
        !repo_path("packages/agent/src/domains/settings/implementation").exists()
            && !repo_path("packages/agent/src/domains/settings/operations.rs").exists(),
        "settings domain must not retain old implementation/ or root operations paths after HRA-5"
    );
    for banned in [
        "async fn settings_update_value",
        "async fn settings_reset_to_defaults_value",
        "async fn read_sparse_settings_snapshot",
        "async fn rollback_sparse_settings",
        "async fn reload_profile_runtime_or_rollback",
    ] {
        assert!(
            !root.contains(banned),
            "settings root must stay registration/docs only and not retain `{banned}`"
        );
    }
}

#[test]
fn rust_engine_tests_are_mirrored_by_subsystem() {
    let required = [
        "packages/agent/src/engine/tests/authority/mod.rs",
        "packages/agent/src/engine/tests/catalog/mod.rs",
        "packages/agent/src/engine/tests/durability/mod.rs",
        "packages/agent/src/engine/tests/invocation/mod.rs",
        "packages/agent/src/engine/tests/kernel/mod.rs",
        "packages/agent/src/engine/tests/runtime/mod.rs",
        "packages/agent/src/engine/tests/fixtures/mod.rs",
    ];
    let banned = [
        "packages/agent/src/engine/tests/catalog_discovery.rs",
        "packages/agent/src/engine/tests/external_worker.rs",
        "packages/agent/src/engine/tests/external_worker_soak.rs",
        "packages/agent/src/engine/tests/grant_authority.rs",
        "packages/agent/src/engine/tests/host_invocation.rs",
        "packages/agent/src/engine/tests/idempotency.rs",
        "packages/agent/src/engine/tests/ids_types.rs",
        "packages/agent/src/engine/tests/ledger_idempotency.rs",
        "packages/agent/src/engine/tests/meta_primitives.rs",
        "packages/agent/src/engine/tests/resource_kernel.rs",
        "packages/agent/src/engine/tests/restart_chaos.rs",
        "packages/agent/src/engine/tests/state_queue.rs",
        "packages/agent/src/engine/tests/streams.rs",
        "packages/agent/src/engine/tests/support.rs",
        "packages/agent/src/engine/tests/triggers.rs",
    ];

    let missing: Vec<_> = required
        .iter()
        .copied()
        .filter(|path| !repo_path(path).exists())
        .collect();
    let present_banned: Vec<_> = banned
        .iter()
        .copied()
        .filter(|path| repo_path(path).exists())
        .collect();

    assert!(
        missing.is_empty() && present_banned.is_empty(),
        "Engine tests must mirror engine subsystem owners after HRA-7; missing: {missing:#?}; old flat test files still present: {present_banned:#?}"
    );
}
