//! Meta-test: every `[T]` (trusted-local) finding from the audit plan
//! carries an `INVARIANT:` marker in source that names the trust
//! boundary and its hardening path.
//!
//! Background: the Tron audit plan produced a set of findings tagged
//! `[T]` — accepted trade-offs under the trusted-local threat model
//! (the only callers are the user's own devices over Tailscale). Each
//! `[T]` trade-off is documented in source with an `INVARIANT:` block
//! naming:
//!   1. the current behavior,
//!   2. why it's safe under trusted-local,
//!   3. the concrete hardening path if the model changes.
//!
//! This test enforces the presence of those markers. If a future edit
//! silently strips the documentation, the marker vanishes, and this
//! test fails before the change can ship.
//!
//! To register a new `[T]` trade-off: add its (path, keyword) entry
//! to `TRUST_BOUNDARY_SITES` and commit the source-side INVARIANT
//! alongside. To remove one: only valid if the trade-off itself has
//! been hardened out of existence (e.g. real rate limiting replaces
//! the L7 documentation).

use std::path::{Path, PathBuf};

/// Sites that must document a trusted-local trust boundary.
///
/// Format: `(relative_path, required_substring_case_insensitive)`.
/// The test asserts the file contains both the literal string
/// `"INVARIANT"` and the required substring (lowercased comparison).
const TRUST_BOUNDARY_SITES: &[(&str, &str)] = &[
    // C1 — filesystem services accept arbitrary paths
    ("src/server/domains/filesystem/service.rs", "trusted-local"),
    // C2 — server binds 0.0.0.0 by default
    ("src/main.rs", "trusted-local"),
    // L8 — client-supplied bundleId trusted at register time
    ("src/server/domains/device/mod.rs", "trusted-local"),
    // L14 — `is_path_within` is lexical, no symlink resolution
    ("src/runtime/guardrails/rules/path.rs", "trusted-local"),
];

/// Sites outside the Rust crate (e.g. shell scripts) — keyed on the
/// repo root rather than `CARGO_MANIFEST_DIR`. Resolved separately.
const TRUST_BOUNDARY_REPO_SITES: &[(&str, &str)] = &[
    // L3 — launchd plist is user-writable
    ("scripts/tron", "trusted-local"),
];

fn crate_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// Walk up from `crate_root` until we hit a directory that contains a
/// top-level `scripts/` sibling — that's the workspace/repo root.
fn repo_root() -> PathBuf {
    let mut cur = crate_root();
    for _ in 0..5 {
        if cur.join("scripts").join("tron").is_file() {
            return cur;
        }
        if !cur.pop() {
            break;
        }
    }
    panic!(
        "could not locate repo root from {:?}; scripts/tron not found walking up",
        crate_root()
    );
}

fn assert_site(root: &Path, relative: &str, keyword: &str) {
    let path = root.join(relative);
    let content =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
    assert!(
        content.contains("INVARIANT"),
        "{relative} must contain an INVARIANT marker (trusted-local [T] finding)"
    );
    assert!(
        content.to_lowercase().contains(keyword),
        "{relative} must name `{keyword}` somewhere in its INVARIANT block"
    );
}

#[test]
fn every_trusted_local_finding_has_invariant_marker() {
    let crate_root = crate_root();
    for (rel, keyword) in TRUST_BOUNDARY_SITES {
        assert_site(&crate_root, rel, keyword);
    }

    let repo_root = repo_root();
    for (rel, keyword) in TRUST_BOUNDARY_REPO_SITES {
        assert_site(&repo_root, rel, keyword);
    }
}

/// Regression: the registered sites must all actually exist. A typo
/// in `TRUST_BOUNDARY_SITES` would otherwise only surface the first
/// time the specific file is read.
#[test]
fn every_registered_site_exists() {
    let crate_root = crate_root();
    for (rel, _) in TRUST_BOUNDARY_SITES {
        let path = crate_root.join(rel);
        assert!(
            path.is_file(),
            "registered site {rel} does not exist at {path:?}"
        );
    }
    let repo_root = repo_root();
    for (rel, _) in TRUST_BOUNDARY_REPO_SITES {
        let path = repo_root.join(rel);
        assert!(
            path.is_file(),
            "registered repo site {rel} does not exist at {path:?}"
        );
    }
}

#[test]
fn installed_pre_commit_hook_enforces_rustfmt_and_personal_info_guard() {
    let hook_installer = repo_root().join("scripts").join("install-hooks.sh");
    let content = std::fs::read_to_string(&hook_installer)
        .unwrap_or_else(|e| panic!("failed to read {hook_installer:?}: {e}"));

    assert!(
        content.contains("cargo fmt --all -- --check"),
        "pre-commit hook must block Rust formatting drift"
    );
    assert!(
        content.contains("personal-info-guard.sh\" --staged"),
        "pre-commit hook must keep the staged personal-info guard"
    );
}

#[test]
fn lower_layers_do_not_depend_on_server_transport_modules() {
    let crate_root = crate_root();
    for dir in ["src/settings", "src/cron", "src/mcp"] {
        let root = crate_root.join(dir);
        for path in rust_files_under(&root) {
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            assert!(
                !content.contains("crate::server::"),
                "{} must not import server transport modules",
                path.strip_prefix(&crate_root).unwrap().display()
            );
        }
    }
}

#[test]
fn readme_does_not_advertise_removed_or_fictional_contracts() {
    let readme_path = repo_root().join("README.md");
    let readme = std::fs::read_to_string(&readme_path)
        .unwrap_or_else(|e| panic!("failed to read {readme_path:?}: {e}"));
    for removed in [
        concat!("server.", "auth.", "enforced"),
        concat!("Bearer", "Auth"),
        concat!("rpc/", "ad", "apters.rs"),
        concat!(
            "Full-text",
            " search (",
            "FT",
            "S5), task management (",
            "PA",
            "RA)"
        ),
        concat!("ensure_", "bearer_token()"),
        concat!("touch_", "onboarded_sentinel()"),
        concat!("atomic self", "-update + rollback"),
    ] {
        assert!(
            !readme.contains(removed),
            "README must not advertise removed/stale contract `{removed}`"
        );
    }
}

#[test]
fn server_blocking_work_uses_the_supervisor_entrypoint() {
    let crate_root = crate_root();
    for root in [
        crate_root.join("src/server/domains"),
        crate_root.join("src/server/shared"),
    ] {
        for path in rust_files_under(&root) {
            let rel = path.strip_prefix(&crate_root).unwrap();
            if rel == Path::new("src/server/shared/context.rs") {
                continue;
            }
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            assert!(
                !content.contains("tokio::task::spawn_blocking")
                    && !content.contains("spawn_blocking("),
                "{} must route blocking work through ServerCapabilityContext::run_blocking or run_blocking_task",
                rel.display()
            );
        }
    }
}

#[test]
fn removed_server_owned_settings_store_stays_deleted() {
    let crate_root = crate_root();
    let file_name = ["settings", "_service.rs"].concat();
    assert!(
        !crate_root
            .join("src/server/domains/settings")
            .join(file_name)
            .exists(),
        "settings persistence belongs to settings::SettingsStore, not server transport code"
    );
}

#[test]
fn tron_server_transport_has_no_removed_rpc_surface() {
    let repo_root = repo_root();
    let crate_root = crate_root();

    for removed in [
        "src/server/rpc",
        concat!("src/server/transport/json", "_", "rpc"),
        concat!("src/server/engine_", "br", "idge"),
    ] {
        assert!(
            !crate_root.join(removed).exists(),
            "{removed} must stay deleted; Tron exposes the engine WebSocket protocol only"
        );
    }

    let forbidden = [
        concat!("Method", "Handler"),
        concat!("Handler", "Entry"),
        concat!("Rpc", "Capability", "Spec"),
        concat!("Json", "Rpc", "Alias", "Spec"),
        concat!("Json", "Rpc", "Request", "Id", "Seed"),
        concat!("Rpc", "Generic", "Trigger", "Handler"),
        concat!("Generic", "Trigger"),
        concat!("Json", "Rpc", "Event"),
        concat!("Broadcast", "Manager"),
        concat!("public", "_json", "_rpc"),
        concat!("rpc", "::"),
        concat!("rpc", ".read"),
        concat!("rpc", ".write"),
        concat!("/", "ws"),
    ];

    for root in [
        crate_root.join("src/server"),
        crate_root.join("src/engine"),
        repo_root.join("README.md"),
    ] {
        for path in files_to_scan(&root) {
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            for needle in forbidden {
                assert!(
                    !content.contains(needle),
                    "{} contains removed transport marker `{needle}`",
                    path.strip_prefix(&repo_root).unwrap_or(&path).display()
                );
            }
        }
    }
}

#[test]
fn server_package_uses_domain_owned_engine_layout() {
    let crate_root = crate_root();
    for removed in ["src/server/capabilities", "src/server/services"] {
        assert!(
            !crate_root.join(removed).exists(),
            "{removed} must stay deleted; server behavior is owned by domain workers"
        );
    }

    let domains_root = crate_root.join("src/server/domains");
    assert!(
        domains_root.is_dir(),
        "server domains directory must exist as the canonical worker surface"
    );
    for entry in std::fs::read_dir(&domains_root).expect("failed to read domains directory") {
        let entry = entry.expect("failed to read domain entry");
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        if !path.join("mod.rs").is_file() {
            continue;
        }
        let domain_name = path.file_name().unwrap().to_string_lossy();
        assert!(
            path.join("contract.rs").is_file(),
            "domain worker module `{domain_name}` must own a contract.rs file"
        );
        assert!(
            path.join("deps.rs").is_file(),
            "domain worker module `{domain_name}` must own a deps.rs file"
        );
        assert!(
            path.join("handlers.rs").is_file(),
            "domain worker module `{domain_name}` must own a handlers.rs operation binding file"
        );
        assert!(
            !path.join("spec.rs").exists(),
            "domain worker module `{domain_name}` must not split contract truth into spec.rs"
        );
    }
    for required in [
        "agent", "auth", "cron", "session", "settings", "tools", "worktree",
    ] {
        let domain_root = domains_root.join(required);
        assert!(
            domain_root.is_dir(),
            "domain worker module `{required}` must own its vertical slice"
        );
        assert!(
            domain_root.join("contract.rs").is_file(),
            "domain worker module `{required}` must own its capability contracts"
        );
        assert!(
            domain_root.join("deps.rs").is_file(),
            "domain worker module `{required}` must own its narrow dependency bundle"
        );
        assert!(
            domain_root.join("handlers.rs").is_file(),
            "domain worker module `{required}` must own operation bindings"
        );
        assert!(
            !domain_root.join("spec.rs").exists(),
            "domain worker module `{required}` must keep its canonical function inventory in contract.rs"
        );
    }
    for required in [
        "agent", "auth", "context", "cron", "job", "mcp", "memory", "model", "session", "tools",
        "worktree",
    ] {
        let domain_root = domains_root.join(required);
        let operations_mod = domain_root.join("operations").join("mod.rs");
        assert!(
            operations_mod.is_file(),
            "flow-critical domain worker `{required}` must expose an operations/ boundary"
        );
        let operations_content = std::fs::read_to_string(&operations_mod)
            .unwrap_or_else(|e| panic!("failed to read {operations_mod:?}: {e}"));
        assert!(
            operations_content.contains("pub(super) async fn")
                || operations_content.contains("pub(super) fn")
                || operations_content.contains("impl ")
                || operations_content.contains("InProcessFunctionHandler"),
            "flow-critical domain worker `{required}` must keep executable operation code in operations/mod.rs, not placeholder docs"
        );
    }
    assert!(
        !domains_root.join("schemas").exists(),
        "domain schemas must live in domain-owned contract modules, not a shared schemas bucket"
    );
    assert!(
        !domains_root.join("catalog/contracts.rs").exists(),
        "catalog must aggregate contracts, not own domain contract policy"
    );

    let domains_mod = std::fs::read_to_string(domains_root.join("mod.rs"))
        .expect("failed to read server/domains/mod.rs");
    assert!(
        !domains_mod.contains("async fn capability_function_value"),
        "canonical functions must carry concrete domain handlers instead of executing through a central dispatcher"
    );
    assert!(
        !domains_mod.contains("handler_for_method"),
        "domain handlers must be registered by domain worker modules, not a central method match"
    );
    assert!(
        !domains_mod.contains("EngineCapabilityDeps"),
        "domain setup must not reintroduce the broad EngineCapabilityDeps shape"
    );
    assert!(
        !domains_mod.contains("_stream_topics"),
        "domain registration must validate stream topics instead of ignoring them"
    );
    assert!(
        !domains_mod.contains("publish_engine_stream_event"),
        "domain stream publication must be owned by domain-local publishers, not a shared catch-all helper"
    );
    let catalog = std::fs::read_to_string(domains_root.join("catalog.rs"))
        .expect("failed to read server/domains/catalog.rs");
    for removed in [
        "CAPABILITY_SEEDS",
        "capability_seed!",
        "canonical_parts_for_method",
        "domain_worker_for_method",
        "domain_authority_scope_for_method",
        "capability_spec_for_method",
        "capability_specs_for_methods",
        "request_schema_for_method",
        "response_schema_for_method",
    ] {
        assert!(
            !catalog.contains(removed),
            "catalog must aggregate domain-owned contracts, not retain central `{removed}` logic"
        );
    }
    let shared_contract = std::fs::read_to_string(domains_root.join("contract.rs"))
        .expect("failed to read server/domains/contract.rs");
    for removed in [
        "match method",
        "capability_specs_for_methods",
        "capability_spec_for_method",
        "request_schema_for_method",
        "response_schema_for_method",
        "domain_authority_scope_for_method",
    ] {
        assert!(
            !shared_contract.contains(removed),
            "shared contract builder must stay method-agnostic and not retain `{removed}`"
        );
    }

    for path in rust_files_under(&domains_root) {
        let rel = path.strip_prefix(&crate_root).unwrap();
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
        assert!(
            !content.contains("capability_context"),
            "{} must not use the old broad capability_context field name",
            rel.display()
        );
        assert!(
            !content.contains("EngineCapabilityDeps"),
            "{} must not reintroduce EngineCapabilityDeps",
            rel.display()
        );
        let production_content = content
            .split("#[cfg(test)]")
            .next()
            .unwrap_or(content.as_str());
        if rel.ends_with("deps.rs") {
            assert!(
                !production_content.contains("ServerCapabilityContext"),
                "{} must not store or construct deps from the full ServerCapabilityContext",
                rel.display()
            );
        }
        let allowed_setup_boundary = rel == Path::new("src/server/domains/mod.rs")
            || rel == Path::new("src/server/domains/registration.rs");
        if !allowed_setup_boundary {
            assert!(
                !production_content.contains("&ServerCapabilityContext"),
                "{} production domain operations must take narrow deps, not &ServerCapabilityContext",
                rel.display()
            );
        }
        assert!(
            !content.contains(".stream_topics(vec![\"resource.leases\", \"catalog.changes\"])")
                && !content.contains("\"streamTopics\":[\"resource.leases\",\"catalog.changes\"]"),
            "{} must not copy engine-global stream topics into domain contracts",
            rel.display()
        );
        assert!(
            !content.contains("server_context: Arc<ServerCapabilityContext>"),
            "{} must expose narrow deps instead of storing the full ServerCapabilityContext",
            rel.display()
        );
    }
}

#[test]
fn retired_browser_stream_capabilities_stay_deleted() {
    let repo_root = repo_root();
    for root in [
        crate_root().join("src/server"),
        repo_root.join("packages/ios-app/Sources"),
        repo_root.join("packages/ios-app/Tests"),
        repo_root.join("README.md"),
    ] {
        for path in files_to_scan(&root) {
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            for removed in [
                "browser::start_stream",
                "browser::stop_stream",
                "BrowserStartStream",
                "BrowserStopStream",
                "startBrowserStream",
                "stopBrowserStream",
            ] {
                assert!(
                    !content.contains(removed),
                    "{} contains retired browser stream capability `{removed}`",
                    path.strip_prefix(&repo_root).unwrap_or(&path).display()
                );
            }
        }
    }
}

#[test]
fn domains_and_runtime_do_not_import_client_transport_modules() {
    let crate_root = crate_root();
    for root in [
        crate_root.join("src/server/domains"),
        crate_root.join("src/server/runtime"),
        crate_root.join("src/server/shared"),
    ] {
        for path in rust_files_under(&root) {
            let rel = path.strip_prefix(&crate_root).unwrap();
            if rel == Path::new("src/server/shared/test_support.rs") {
                continue;
            }
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            assert!(
                !content.contains("server::transport")
                    && !content.contains("crate::server::transport"),
                "{} must not import client transport modules",
                rel.display()
            );
        }
    }
}

#[test]
fn main_background_work_is_registered_with_shutdown() {
    let main_path = crate_root().join("src/main.rs");
    let content = std::fs::read_to_string(&main_path)
        .unwrap_or_else(|e| panic!("failed to read {main_path:?}: {e}"));
    for required in [
        "register_blocking_supervisor_shutdown(server.shutdown())",
        "shutdown.register_task(handle)",
        "server.shutdown().register_task(sandbox_cleanup)",
        "server.shutdown().register_task(eviction_task)",
        "server.shutdown().register_task(cron_cancel_forwarder)",
        "shutdown_handles.push(h)",
    ] {
        assert!(
            content.contains(required),
            "main.rs must keep shutdown ownership marker `{required}`"
        );
    }
}

fn rust_files_under(root: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    visit_rust_files(root, &mut files);
    files
}

fn files_to_scan(root: &Path) -> Vec<PathBuf> {
    if root.is_file() {
        return vec![root.to_path_buf()];
    }
    let mut files = Vec::new();
    visit_files(root, &mut files);
    files
}

fn visit_files(root: &Path, files: &mut Vec<PathBuf>) {
    if !root.exists() {
        return;
    }
    let entries = std::fs::read_dir(root)
        .unwrap_or_else(|e| panic!("failed to read directory {root:?}: {e}"));
    for entry in entries {
        let entry = entry.unwrap_or_else(|e| panic!("failed to read entry in {root:?}: {e}"));
        let path = entry.path();
        if path.is_dir() {
            visit_files(&path, files);
        } else if matches!(
            path.extension().and_then(|ext| ext.to_str()),
            Some("rs" | "md")
        ) {
            files.push(path);
        }
    }
}

fn visit_rust_files(path: &Path, files: &mut Vec<PathBuf>) {
    if path.is_file() {
        if path.extension().and_then(|ext| ext.to_str()) == Some("rs") {
            files.push(path.to_path_buf());
        }
        return;
    }

    let entries = std::fs::read_dir(path)
        .unwrap_or_else(|e| panic!("failed to read directory {path:?}: {e}"));
    for entry in entries {
        let entry = entry.unwrap_or_else(|e| panic!("failed to read directory entry: {e}"));
        visit_rust_files(&entry.path(), files);
    }
}
