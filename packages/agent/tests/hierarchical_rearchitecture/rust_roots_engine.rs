use super::support::*;

#[test]
fn rust_source_root_has_only_allowed_entry_files() {
    let allowed = HashSet::from(["lib.rs", "main.rs"]);
    let mut unexpected = Vec::new();
    for entry in std::fs::read_dir(repo_path("packages/agent/src"))
        .expect("Rust source root should be readable")
    {
        let path = entry.expect("source root entry should be readable").path();
        if path.extension().and_then(|extension| extension.to_str()) == Some("rs") {
            let file_name = path
                .file_name()
                .and_then(|name| name.to_str())
                .expect("Rust source file should have UTF-8 name");
            if !allowed.contains(file_name) {
                unexpected.push(
                    path.strip_prefix(repo_root())
                        .unwrap()
                        .display()
                        .to_string(),
                );
            }
        }
    }

    assert!(
        unexpected.is_empty(),
        "Rust source root must contain only true crate entry files; move these into owned modules: {unexpected:#?}"
    );
}

#[test]
fn rust_app_transport_shared_roots_are_owned() {
    let required = [
        "packages/agent/src/app/cli/mod.rs",
        "packages/agent/src/app/bootstrap/mod.rs",
        "packages/agent/src/app/bootstrap/config.rs",
        "packages/agent/src/app/bootstrap/server.rs",
        "packages/agent/src/app/health/mod.rs",
        "packages/agent/src/app/health/metrics.rs",
        "packages/agent/src/app/lifecycle/mod.rs",
        "packages/agent/src/app/lifecycle/onboarding/mod.rs",
        "packages/agent/src/app/lifecycle/shutdown.rs",
        "packages/agent/src/transport/http/auth.rs",
        "packages/agent/src/transport/engine/contracts.rs",
        "packages/agent/src/transport/engine/mod.rs",
        "packages/agent/src/transport/engine/socket/mod.rs",
        "packages/agent/src/transport/runtime/setup.rs",
        "packages/agent/src/shared/foundation/mod.rs",
        "packages/agent/src/shared/protocol/mod.rs",
        "packages/agent/src/shared/observability/mod.rs",
        "packages/agent/src/shared/storage/mod.rs",
    ];
    let banned = [
        "packages/agent/src/main_cli.rs",
        "packages/agent/src/main_runtime.rs",
        "packages/agent/src/main_tests.rs",
        "packages/agent/src/app/config.rs",
        "packages/agent/src/app/disk.rs",
        "packages/agent/src/app/health.rs",
        "packages/agent/src/app/metrics.rs",
        "packages/agent/src/app/onboarding",
        "packages/agent/src/app/server.rs",
        "packages/agent/src/app/shutdown.rs",
        "packages/agent/src/transport/auth.rs",
        "packages/agent/src/transport/contracts.rs",
        "packages/agent/src/transport/engine.rs",
        "packages/agent/src/transport/engine_ws",
        "packages/agent/src/transport/engine_ws.rs",
        "packages/agent/src/transport/setup.rs",
        "packages/agent/src/shared/errors",
        "packages/agent/src/shared/logging",
        "packages/agent/src/shared/storage.rs",
        "packages/agent/src/shared/foundation/paths.rs",
        "packages/agent/src/shared/foundation/profile.rs",
        "packages/agent/src/shared/protocol/events.rs",
        "packages/agent/src/shared/protocol/messages.rs",
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
        "Rust app/transport/shared HRA-2 roots are not clean; missing: {missing:#?}; old paths still present: {present_banned:#?}"
    );
}

#[test]
fn rust_engine_root_has_no_unowned_flat_modules() {
    let mut unexpected = Vec::new();
    for entry in
        std::fs::read_dir(repo_path("packages/agent/src/engine")).expect("engine root readable")
    {
        let path = entry.expect("engine entry should be readable").path();
        if path.extension().and_then(|extension| extension.to_str()) == Some("rs")
            && path.file_name().and_then(|name| name.to_str()) != Some("mod.rs")
        {
            unexpected.push(
                path.strip_prefix(repo_root())
                    .unwrap()
                    .display()
                    .to_string(),
            );
        }
    }

    assert!(
        unexpected.is_empty(),
        "Rust engine root must be subsystem folders plus mod.rs, not unowned flat modules: {unexpected:#?}"
    );
}

#[test]
fn rust_engine_subsystem_roots_are_owned() {
    let required_files = [
        "packages/agent/src/engine/authority/mod.rs",
        "packages/agent/src/engine/authority/grants/mod.rs",
        "packages/agent/src/engine/catalog/mod.rs",
        "packages/agent/src/engine/catalog/registry/mod.rs",
        "packages/agent/src/engine/durability/mod.rs",
        "packages/agent/src/engine/durability/ledger/mod.rs",
        "packages/agent/src/engine/durability/queue/mod.rs",
        "packages/agent/src/engine/durability/resources/store/mod.rs",
        "packages/agent/src/engine/invocation/mod.rs",
        "packages/agent/src/engine/invocation/host/mod.rs",
        "packages/agent/src/engine/kernel/mod.rs",
        "packages/agent/src/engine/kernel/types/mod.rs",
        "packages/agent/src/engine/kernel/types/catalog.rs",
        "packages/agent/src/engine/kernel/types/function.rs",
        "packages/agent/src/engine/kernel/types/trigger.rs",
        "packages/agent/src/engine/kernel/types/worker.rs",
        "packages/agent/src/engine/primitives/resource/mod.rs",
        "packages/agent/src/engine/primitives/ui/mod.rs",
        "packages/agent/src/engine/runtime/mod.rs",
        "packages/agent/src/engine/runtime/external_workers/mod.rs",
        "packages/agent/src/engine/runtime/worker_protocol.rs",
    ];
    let banned_paths = [
        "packages/agent/src/engine/capabilities.rs",
        "packages/agent/src/engine/compensation.rs",
        "packages/agent/src/engine/discovery.rs",
        "packages/agent/src/engine/errors.rs",
        "packages/agent/src/engine/external.rs",
        "packages/agent/src/engine/grants",
        "packages/agent/src/engine/grants.rs",
        "packages/agent/src/engine/host",
        "packages/agent/src/engine/host.rs",
        "packages/agent/src/engine/ids.rs",
        "packages/agent/src/engine/invocation.rs",
        "packages/agent/src/engine/ledger",
        "packages/agent/src/engine/ledger.rs",
        "packages/agent/src/engine/leases.rs",
        "packages/agent/src/engine/policy.rs",
        "packages/agent/src/engine/protocol.rs",
        "packages/agent/src/engine/queue",
        "packages/agent/src/engine/queue.rs",
        "packages/agent/src/engine/registry",
        "packages/agent/src/engine/registry.rs",
        "packages/agent/src/engine/resources",
        "packages/agent/src/engine/schema.rs",
        "packages/agent/src/engine/state.rs",
        "packages/agent/src/engine/streams.rs",
        "packages/agent/src/engine/triggers.rs",
        "packages/agent/src/engine/types.rs",
        "packages/agent/src/engine/primitives/resource.rs",
        "packages/agent/src/engine/primitives/ui.rs",
    ];

    let missing: Vec<_> = required_files
        .iter()
        .copied()
        .filter(|path| !repo_path(path).exists())
        .collect();
    let present_banned: Vec<_> = banned_paths
        .iter()
        .copied()
        .filter(|path| repo_path(path).exists())
        .collect();

    assert!(
        missing.is_empty() && present_banned.is_empty(),
        "Rust engine HRA-3/HRA-4 subsystem roots are not clean; missing: {missing:#?}; old paths still present: {present_banned:#?}"
    );
}

#[test]
fn rust_engine_has_no_same_name_file_folder_pairs() {
    let mut pairs = Vec::new();
    let mut source_files = Vec::new();
    list_source_files(
        &repo_path("packages/agent/src/engine"),
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
        "Rust engine must not retain avoidable same-name file/folder module pairs: {pairs:#?}"
    );
}

#[test]
fn rust_non_session_domains_have_no_same_name_file_folder_pairs() {
    let mut pairs = Vec::new();
    let mut source_files = Vec::new();
    list_source_files(
        &repo_path("packages/agent/src/domains"),
        &["rs"],
        &mut source_files,
    );
    for file in source_files {
        let relative = file
            .strip_prefix(repo_root())
            .unwrap()
            .display()
            .to_string();
        if relative.starts_with("packages/agent/src/domains/session/") {
            continue;
        }
        let sibling_folder = file.with_extension("");
        if sibling_folder.is_dir() {
            pairs.push(relative);
        }
    }

    assert!(
        pairs.is_empty(),
        "Non-session Rust domains must not retain avoidable same-name file/folder module pairs after HRA-5: {pairs:#?}"
    );
}
