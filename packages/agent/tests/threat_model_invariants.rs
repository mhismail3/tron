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
    ("src/domains/filesystem/service.rs", "trusted-local"),
    // C2 — server binds 0.0.0.0 by default
    ("src/main.rs", "trusted-local"),
    // L8 — client-supplied bundleId trusted at register time
    ("src/domains/device/mod.rs", "trusted-local"),
    // L14 — `is_path_within` is lexical, no symlink resolution
    (
        "src/domains/agent/runner/guardrails/rules/path.rs",
        "trusted-local",
    ),
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
fn tron_dev_background_start_is_file_logged_and_health_checked() {
    let script_path = repo_root().join("scripts").join("tron");
    let content = std::fs::read_to_string(&script_path)
        .unwrap_or_else(|e| panic!("failed to read {script_path:?}: {e}"));
    let background_start = content
        .split("dev_start_background()")
        .nth(1)
        .and_then(|tail| tail.split("dev_stop()").next())
        .expect("scripts/tron must contain dev_start_background before dev_stop");

    assert!(
        background_start.contains("tron-dev-background.log"),
        "background dev startup must preserve server stdout/stderr in a file log"
    );
    assert!(
        background_start.contains("http://127.0.0.1:$PROD_PORT/health"),
        "background dev startup must wait for /health, not just a live pid"
    );
    assert!(
        background_start.contains("tail -n 80 \"$dev_log\""),
        "background dev startup failure must print the recent server log tail"
    );
    assert!(
        !background_start.contains(">/dev/null 2>&1 &"),
        "background dev startup must not discard pre-database startup failures"
    );
}

#[test]
fn program_worker_binary_is_built_and_packaged_with_tron_helper() {
    let repo_root = repo_root();
    let script_path = repo_root.join("scripts").join("tron");
    let script = std::fs::read_to_string(&script_path)
        .unwrap_or_else(|e| panic!("failed to read {script_path:?}: {e}"));
    assert!(
        script.contains("--bin tron --bin tron-program-worker"),
        "tron dev/install flows must build the server and program-worker binaries together"
    );
    assert!(
        script.contains("RELEASE_PROGRAM_WORKER="),
        "workspace script must track the release program worker beside tron"
    );
    assert!(
        script.contains("tron-program-worker.bak"),
        "deploy rollback must back up the program worker with the server binary"
    );

    let lib_path = repo_root.join("scripts").join("tron-lib.sh");
    let lib = std::fs::read_to_string(&lib_path)
        .unwrap_or_else(|e| panic!("failed to read {lib_path:?}: {e}"));
    assert!(
        lib.contains("INSTALLED_PROGRAM_WORKER=")
            && lib.contains("tron-program-worker")
            && lib.contains("Cannot create app bundle: sibling tron-program-worker missing"),
        "shared bundle creation must require and stage the sibling program-worker binary"
    );

    let bundle_script_path = repo_root
        .join("packages")
        .join("mac-app")
        .join("scripts")
        .join("bundle-agent.sh");
    let bundle_script = std::fs::read_to_string(&bundle_script_path)
        .unwrap_or_else(|e| panic!("failed to read {bundle_script_path:?}: {e}"));
    assert!(
        bundle_script.contains("--bin tron --bin tron-program-worker")
            && bundle_script.contains("STAGING_WORKER_PATH=")
            && bundle_script.contains("--worker-source"),
        "Mac helper staging must build and copy both helper executables"
    );

    for workflow in [
        ".github/workflows/ci.yml",
        ".github/workflows/release-mac.yml",
    ] {
        let path = repo_root.join(workflow);
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
        assert!(
            content.contains("--bin tron --bin tron-program-worker")
                && content.contains("tron-program-worker"),
            "{workflow} must build and validate the program-worker helper"
        );
    }
}

#[test]
fn lower_layers_do_not_depend_on_server_transport_modules() {
    let crate_root = crate_root();
    for dir in [
        "src/domains/settings/implementation",
        "src/domains/cron/implementation",
        "src/domains/mcp/product_protocol",
    ] {
        let root = crate_root.join(dir);
        for path in rust_files_under(&root) {
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            assert!(
                !content.contains("crate::app::"),
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
fn managed_skills_use_capability_native_references() {
    let skills_root = repo_root().join("packages").join("agent").join("skills");
    let forbidden = [
        (
            concat!("allowed", "Tools"),
            "use allowedContracts frontmatter",
        ),
        (
            concat!("denied", "Tools"),
            "use deniedContracts frontmatter",
        ),
        ("AskUserQuestion", "use agent::ask_user"),
        ("NotifyApp", "use notifications::send"),
        ("WebFetch", "use web::fetch"),
        ("WebSearch", "use web::search"),
        ("SpawnSubagent", "use agent::spawn_subagent"),
        ("Display(", "use display::show"),
    ];

    for path in files_to_scan(&skills_root) {
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
        for (term, replacement) in forbidden {
            assert!(
                !content.contains(term),
                "{} contains retired skill surface `{term}`; {replacement}",
                path.strip_prefix(repo_root()).unwrap().display()
            );
        }
    }
}

#[test]
fn server_blocking_work_uses_the_supervisor_entrypoint() {
    let crate_root = crate_root();
    for root in [
        crate_root.join("src/domains"),
        crate_root.join("src/shared/server"),
    ] {
        for path in rust_files_under(&root) {
            let rel = path.strip_prefix(&crate_root).unwrap();
            if rel == Path::new("src/shared/server/context.rs")
                || rel == Path::new("src/domains/capability_support/implementations/ui/input.rs")
                || rel
                    == Path::new(
                        "src/domains/capability_support/implementations/backends/process.rs",
                    )
                || rel
                    == Path::new("src/domains/session/event_store/store/event_store/auxiliary.rs")
            {
                continue;
            }
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            assert!(
                !content.contains("tokio::task::spawn_blocking")
                    && !content.contains("spawn_blocking("),
                "{} must route blocking work through ServerRuntimeContext::run_blocking or run_blocking_task",
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
            .join("src/domains/settings")
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
        ["src/server", "/rpc"].concat(),
        concat!("src/transport/json", "_", "rpc").to_string(),
        concat!("src/app/engine_", "br", "idge").to_string(),
    ] {
        assert!(
            !crate_root.join(&removed).exists(),
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
        crate_root.join("src/app"),
        crate_root.join("src/transport"),
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
fn capability_registry_authority_stays_deleted() {
    let crate_root = crate_root();
    let repo_root = repo_root();

    for removed in [
        ["src/tool", "_factory.rs"].concat(),
        "src/domains/capability_support/implementations/registry.rs".to_string(),
    ] {
        assert!(
            !crate_root.join(&removed).exists(),
            "{removed} must stay deleted; provider capabilities are capability primitives over domain-owned workers"
        );
    }

    let forbidden = [
        ["ModelCapability", "Registry"].concat(),
        ["ModelCapability", "Registry", "Config"].concat(),
        ["create_tool", "_registry"].concat(),
        ["tool", "_factory"].concat(),
        "registry.names()".to_string(),
        "registry.definitions()".to_string(),
        "registry-driven".to_string(),
    ];
    for root in [
        crate_root.join("src/main.rs"),
        crate_root.join("src/domains/agent/runner"),
        crate_root.join("src/app"),
        crate_root.join("src/domains/capability_support"),
        repo_root.join("README.md"),
    ] {
        for path in files_to_scan(&root) {
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            for needle in &forbidden {
                assert!(
                    !content.contains(needle),
                    "{} must not reintroduce deleted capability registry authority `{needle}`",
                    path.strip_prefix(&repo_root).unwrap_or(&path).display()
                );
            }
        }
    }

    assert!(
        !crate_root
            .join(["src/domains/", "tools", "/operations/execution.rs"].concat())
            .exists(),
        "legacy capability invocation handler must stay deleted"
    );
    let capability_executor_source = std::fs::read_to_string(
        crate_root.join("src/domains/agent/runner/agent/capability_invocation_executor.rs"),
    )
    .expect("failed to read agent capability executor");
    assert!(
        capability_executor_source.contains("\"search\"")
            && capability_executor_source.contains("\"inspect\"")
            && capability_executor_source.contains("\"execute\""),
        "agent capability executor must route only the three capability primitives"
    );
    for retired_runtime_term in [
        concat!("Tool", "Context"),
        concat!("capability", "_runtime"),
        concat!("Tron", "Tool"),
    ] {
        assert!(
            !capability_executor_source.contains(retired_runtime_term),
            "agent capability executor must not reintroduce the retired runtime path"
        );
    }
}

#[test]
fn retired_capability_event_surface_stays_deleted() {
    let repo_root = repo_root();
    let crate_root = crate_root();

    let forbidden_exact = [
        concat!("tool", ".", "call"),
        concat!("tool", ".", "result"),
        concat!("tool", ".", "progress"),
        concat!("error", ".", "tool"),
        concat!("tool", "_", "start"),
        concat!("tool", "_", "end"),
        concat!("tool", ".", "start"),
        concat!("tool", ".", "end"),
        concat!("tool", "Agent"),
        concat!("Tool", "Agent"),
        concat!("tool", "Count"),
        concat!("tool", "Status"),
        concat!("tool", "Order"),
        concat!("tool", "Execution", "Mode"),
        concat!("tool", "Schema"),
        concat!("local", "Tool", "Schema"),
        concat!("Tool", "Operation"),
        concat!("tool", "_", "operation"),
        concat!("agent", ".", "tool", "_"),
        concat!("tool", "::", "result"),
        concat!("Mcp", "Search"),
        concat!("Mcp", "Call"),
        concat!("Engine", "Discover"),
        concat!("Engine", "Inspect"),
        concat!("Engine", "Invoke"),
        concat!("Engine", "Watch"),
    ];

    for root in [
        crate_root.join("src"),
        crate_root.join("tests"),
        repo_root.join("README.md"),
        repo_root.join("packages/agent/docs"),
        repo_root.join("packages/agent/skills/self-inspect/reference"),
    ] {
        for path in files_to_scan(&root) {
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            for needle in &forbidden_exact {
                assert!(
                    !content.contains(needle),
                    "{} must not reintroduce retired capability event/execution marker `{needle}`",
                    path.strip_prefix(&repo_root).unwrap_or(&path).display()
                );
            }
        }
    }
}

#[test]
fn provider_tool_terms_stay_inside_protocol_boundaries() {
    let repo_root = repo_root();
    let allowed_prefixes = [
        "packages/agent/src/domains/model/provider_protocol/",
        "packages/agent/src/domains/model/providers/",
        "packages/agent/src/domains/mcp/product_protocol/",
        "packages/agent/tests/threat_model_invariants.rs",
    ];
    let forbidden = [
        concat!("model", "Tool", "Name"),
        concat!("model", "_", "tool", "_", "name"),
        concat!("tool", "Call", "Id"),
        concat!("tool", "_", "call", "_", "id"),
        concat!("tool", "_", "name"),
        concat!("tool", "Name"),
        concat!("tool", "_", "calls"),
        concat!("Tool", "Call"),
        concat!("Tool", "Result"),
        concat!("Tool", "Use"),
        concat!("tool", "_", "use"),
        concat!("tool", "_", "result"),
    ];

    for root in [
        repo_root.join("README.md"),
        repo_root.join("packages/agent/src"),
        repo_root.join("packages/agent/tests"),
        repo_root.join("packages/agent/defaults"),
    ] {
        for path in files_to_scan(&root) {
            let rel = path
                .strip_prefix(&repo_root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            if allowed_prefixes
                .iter()
                .any(|prefix| rel.starts_with(prefix))
            {
                continue;
            }
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            for needle in forbidden {
                assert!(
                    !content.contains(needle),
                    "{rel} contains provider/tool protocol term `{needle}` outside the protocol boundary"
                );
            }
        }
    }
}

#[test]
fn retired_stale_shapes_stay_deleted() {
    let crate_root = crate_root();

    let retired_shapes = [
        (
            "src/shared/protocol/capabilities.rs".to_string(),
            "pub enum ToolExecutionContract".to_string(),
        ),
        (
            "src/shared/protocol/events.rs".to_string(),
            "TurnTokenUsage".to_string(),
        ),
        (
            "src/shared/protocol/events.rs".to_string(),
            "ResponseTokenUsage".to_string(),
        ),
        (
            "src/shared/foundation/profile.rs".to_string(),
            "pub type ProfileSpec".to_string(),
        ),
        (
            "src/shared/foundation/profile.rs".to_string(),
            ["pub ", "fall", "back", ": Option<String>"].concat(),
        ),
        (
            "src/domains/import/implementation/parser.rs".to_string(),
            "pub fn parse_session(".to_string(),
        ),
        (
            "defaults/profiles/default/profile.toml".to_string(),
            ["fall", "back", " ="].concat(),
        ),
    ];

    for (relative, needle) in retired_shapes {
        let path = crate_root.join(&relative);
        let Ok(content) = std::fs::read_to_string(&path) else {
            continue;
        };
        assert!(
            !content.contains(&needle),
            "{relative} must not reintroduce retired stale shape `{needle}`"
        );
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CurrentBoundaryKind {
    Isolate,
    Recover,
}

#[derive(Clone, Copy, Debug)]
struct CurrentBoundaryAllow {
    relative_path_prefix: &'static str,
    marker: &'static str,
    kind: CurrentBoundaryKind,
    owner: &'static str,
    reason: &'static str,
    expires: &'static str,
}

const CURRENT_BOUNDARY_ALLOWLIST: &[CurrentBoundaryAllow] = &[
    CurrentBoundaryAllow {
        relative_path_prefix: "packages/agent/src/domains/mcp/product_protocol/",
        marker: "JsonRpc",
        kind: CurrentBoundaryKind::Isolate,
        owner: "domains::mcp",
        reason: "MCP itself is a current JSON-RPC product protocol; this is not the Tron engine transport.",
        expires: "none",
    },
    CurrentBoundaryAllow {
        relative_path_prefix: "packages/agent/src/domains/mcp/product_protocol/",
        marker: "jsonrpc",
        kind: CurrentBoundaryKind::Isolate,
        owner: "domains::mcp",
        reason: "MCP fixtures and wire DTOs must speak the MCP JSON-RPC product protocol.",
        expires: "none",
    },
    CurrentBoundaryAllow {
        relative_path_prefix: "packages/agent/src/domains/model/providers/",
        marker: "isLegacy",
        kind: CurrentBoundaryKind::Isolate,
        owner: "domains::model",
        reason: "Current iOS/provider model-list DTO key for retired-generation model metadata.",
        expires: "iOS DTO rename package",
    },
    CurrentBoundaryAllow {
        relative_path_prefix: "packages/agent/src/domains/model/providers/",
        marker: "isDeprecated",
        kind: CurrentBoundaryKind::Isolate,
        owner: "domains::model",
        reason: "Current iOS/provider model-list DTO key for retired provider model metadata.",
        expires: "iOS DTO rename package",
    },
    CurrentBoundaryAllow {
        relative_path_prefix: "packages/agent/src/domains/session/event_store/sqlite/migrations/v005_drop_profile_migrations.sql",
        marker: "idx_profile_migrations_legacy",
        kind: CurrentBoundaryKind::Isolate,
        owner: "domains::session",
        reason: "Historical SQLite object name that must be dropped by exact name in existing databases.",
        expires: "never; database object names are historical facts",
    },
    CurrentBoundaryAllow {
        relative_path_prefix: "packages/agent/src/domains/agent/runner/orchestrator/recovery.rs",
        marker: "recover_incomplete_turns",
        kind: CurrentBoundaryKind::Recover,
        owner: "domains::agent",
        reason: "Startup turn recovery is current product behavior that persists through the event store.",
        expires: "none",
    },
];

#[test]
fn current_architecture_terms_are_deleted_or_owned() {
    let repo_root = repo_root();
    let scan_roots = [
        repo_root.join("README.md"),
        repo_root.join("packages/agent/src"),
        repo_root.join("packages/agent/tests"),
    ];
    let retired_terms = [
        ["leg", "acy"].concat(),
        ["fall", "back"].concat(),
        ["compat", "ibility"].concat(),
        ["back", "ward"].concat(),
        ["back", "wards"].concat(),
        ["depre", "cated"].concat(),
        ["sh", "im"].concat(),
        ["bri", "dge"].concat(),
        ["adap", "ter"].concat(),
    ];
    let isolated_protocol_terms = ["JsonRpc".to_string(), "jsonrpc".to_string()];
    let old_import_markers = [
        "crate::runtime::".to_string(),
        "crate::events::".to_string(),
        "crate::tools::".to_string(),
        "crate::cron::".to_string(),
        "crate::worktree::".to_string(),
        "crate::llm::".to_string(),
        "crate::mcp::".to_string(),
        "crate::settings::".to_string(),
        "crate::skills::".to_string(),
        "crate::prompt_library::".to_string(),
        "crate::import::".to_string(),
        "crate::transcription::".to_string(),
        ["src/server", "/domains"].concat(),
    ];

    for root in scan_roots {
        for path in files_to_scan(&root) {
            if path == Path::new(file!()) {
                continue;
            }
            let rel = path
                .strip_prefix(&repo_root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            if rel == "packages/agent/tests/threat_model_invariants.rs" {
                continue;
            }
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            let lower = content.to_lowercase();

            for term in &retired_terms {
                let is_owned_current_boundary = CURRENT_BOUNDARY_ALLOWLIST.iter().any(|allow| {
                    rel.starts_with(allow.relative_path_prefix)
                        && content.contains(allow.marker)
                        && allow.marker.to_lowercase().contains(term)
                });
                assert!(
                    !lower.contains(term) || is_owned_current_boundary,
                    "{rel} contains retired architecture word `{term}`; rename/delete it or add an explicit current-boundary owner"
                );
            }
            for marker in &old_import_markers {
                assert!(
                    !content.contains(marker.as_str()),
                    "{rel} contains old root import/path `{marker}`"
                );
            }
            for marker in &isolated_protocol_terms {
                if !content.contains(marker) {
                    continue;
                }
                let allow = CURRENT_BOUNDARY_ALLOWLIST.iter().find(|allow| {
                    rel.starts_with(allow.relative_path_prefix) && allow.marker == marker
                });
                assert!(
                    allow.is_some(),
                    "{rel} contains isolated protocol marker `{marker}` without an owner/reason allowlist entry"
                );
            }
        }
    }

    for allow in CURRENT_BOUNDARY_ALLOWLIST {
        assert!(
            !allow.owner.is_empty()
                && !allow.reason.is_empty()
                && !allow.expires.is_empty()
                && matches!(
                    allow.kind,
                    CurrentBoundaryKind::Isolate | CurrentBoundaryKind::Recover
                ),
            "current-boundary allowlist entries must carry kind, owner, reason, and expiration"
        );
    }
}

#[test]
fn unified_storage_has_no_active_old_database_paths() {
    let repo_root = repo_root();
    let scan_roots = [
        repo_root.join("README.md"),
        repo_root.join("packages/agent/src"),
        repo_root.join("packages/agent/tests"),
        repo_root.join("packages/ios-app/Sources"),
        repo_root.join("packages/ios-app/Tests"),
        repo_root.join("packages/ios-app/docs"),
    ];
    let old_database_markers = ["log.db", "engine-ledger.sqlite", "tron.db", "log.db.lock"];
    for root in scan_roots {
        for path in files_to_scan(&root) {
            let rel = path
                .strip_prefix(&repo_root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            if rel == "packages/agent/src/shared/storage.rs"
                || rel == "packages/agent/tests/threat_model_invariants.rs"
            {
                continue;
            }
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            for marker in old_database_markers {
                assert!(
                    !content.contains(marker),
                    "{rel} contains retired active database path `{marker}`; use tron.sqlite or isolate it in shared::storage archive policy"
                );
            }
        }
    }
}

#[test]
fn blobs_are_owned_through_storage_payload_refs() {
    let repo_root = repo_root();
    let crate_root = crate_root();
    for path in rust_files_under(&crate_root.join("src")) {
        let rel = path
            .strip_prefix(&repo_root)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
        if !content.contains("store_content_blob(") {
            continue;
        }
        assert!(
            rel == "packages/agent/src/shared/storage.rs"
                || rel
                    == "packages/agent/src/domains/session/event_store/sqlite/repositories/blob.rs",
            "{rel} calls store_content_blob directly; use store_json_value/store_json_bytes so every blob has a storage_payload_refs owner"
        );
    }
}

#[test]
fn current_architecture_ownership_report_is_current() {
    let repo_root = repo_root();
    let crate_root = crate_root();
    let src_root = crate_root.join("src");
    let expected_top_level = [
        "app",
        "domains",
        "engine",
        "platform",
        "shared",
        "transport",
    ];
    for directory in expected_top_level {
        assert!(
            src_root.join(directory).is_dir(),
            "current architecture root `{directory}` must exist"
        );
    }
    for retired_root in [
        "runtime",
        "events",
        "tools",
        "cron",
        "worktree",
        "llm",
        "mcp",
        "settings",
        "skills",
        "prompt_library",
        "import",
        "transcription",
        "server",
    ] {
        assert!(
            !src_root.join(retired_root).exists(),
            "retired root bucket `{retired_root}` must not exist"
        );
    }

    let domain_names = std::fs::read_dir(src_root.join("domains"))
        .expect("failed to read domains root")
        .filter_map(Result::ok)
        .filter(|entry| entry.path().join("contract.rs").is_file())
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect::<Vec<_>>();
    let primitive_workers = std::fs::read_dir(src_root.join("engine/primitives"))
        .expect("failed to read primitive root")
        .filter_map(Result::ok)
        .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "rs"))
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect::<Vec<_>>();

    let report = format!(
        "Current Architecture Ownership Report\n\
         app: bootstrap, health, metrics, onboarding, shutdown\n\
         transport: /engine client protocol, /engine/workers socket transport, auth gate\n\
         engine primitives: {}\n\
         domains: {}\n\
         platform: APNs, updater/device sidecars\n\
         shared: foundation types, protocol DTOs, neutral helpers\n",
        primitive_workers.join(", "),
        domain_names.join(", "),
    );
    eprintln!("{report}");

    assert!(
        report.contains("transport: /engine")
            && report.contains("engine primitives:")
            && report.contains("domains:")
            && report.contains("platform:")
            && report.contains("shared:"),
        "ownership report must cover app, transport, engine, domains, platform, and shared"
    );
    assert!(
        repo_root.join("README.md").is_file(),
        "README remains the canonical architecture reference"
    );
}

#[test]
fn primitive_workers_are_owned_outside_host_bucket() {
    let crate_root = crate_root();
    let primitives_root = crate_root.join("src/engine/primitives");
    for primitive in [
        "stream.rs",
        "state.rs",
        "queue.rs",
        "approval.rs",
        "catalog.rs",
        "worker.rs",
        "observability.rs",
        "runtime.rs",
    ] {
        assert!(
            primitives_root.join(primitive).is_file(),
            "engine primitive worker contracts must live in src/engine/primitives/{primitive}"
        );
    }

    let host = std::fs::read_to_string(crate_root.join("src/engine/host.rs"))
        .expect("failed to read engine host");
    for removed in [
        "struct StreamPrimitiveHandler",
        "struct StatePrimitiveHandler",
        "struct QueuePrimitiveHandler",
        "struct ApprovalPrimitiveHandler",
        "fn stream_publish_schema",
        "fn state_set_schema",
        "fn queue_enqueue_schema",
        "fn approval_request_schema",
        "fn primitive_function(",
        "fn primitive_catalog_",
        "fn primitive_worker_",
        "fn primitive_trace_",
        "fn primitive_log_query",
        "fn primitive_metrics_snapshot",
        "dispatch_host_dispatched_primitive",
    ] {
        assert!(
            !host.contains(removed),
            "EngineHost must coordinate primitive execution without owning primitive contract, query, or response bucket `{removed}`"
        );
    }

    let primitive_runtime = std::fs::read_to_string(primitives_root.join("runtime.rs"))
        .expect("failed to read primitive runtime");
    for required in [
        "PrimitiveRuntimeHost",
        "catalog_list",
        "worker_list",
        "trace_get",
        "metrics_snapshot",
    ] {
        assert!(
            primitive_runtime.contains(required),
            "primitive query response shaping must live in src/engine/primitives/runtime.rs; missing `{required}`"
        );
    }
}

#[test]
fn external_workers_and_sandbox_spawn_are_first_class_engine_surfaces() {
    let crate_root = crate_root();
    let protocol = std::fs::read_to_string(crate_root.join("src/engine/protocol.rs"))
        .expect("failed to read worker protocol");
    for required in [
        "WorkerIdentity",
        "WorkerAuthPolicy",
        "WorkerRegistrationMode",
        "WorkerVisibility",
        "WorkerHealth",
        "WorkerLifecycleEvent",
        "WorkerStreamPublish",
        "PublishStream",
    ] {
        assert!(
            protocol.contains(required),
            "worker protocol must expose `{required}` for local-first worker lifecycle and stream publication"
        );
    }

    let external = std::fs::read_to_string(crate_root.join("src/engine/external.rs"))
        .expect("failed to read external worker runtime");
    for required in [
        "register_function",
        "register_trigger",
        "publish_stream",
        "publish_lifecycle_event",
        "worker.lifecycle",
        "external workers are loopback-only",
        "disconnect_timed_out",
        "mark_durable_worker_disconnected",
    ] {
        assert!(
            external.contains(required),
            "external worker runtime must keep `{required}` in the engine-owned worker lifecycle"
        );
    }

    let sandbox_contract =
        std::fs::read_to_string(crate_root.join("src/domains/sandbox/contract.rs"))
            .expect("failed to read sandbox contract");
    for required in [
        "sandbox::spawn_worker",
        "sandbox::list_spawned_workers",
        "sandbox::get_spawned_worker",
        "sandbox::stop_spawned_worker",
        "sandbox-worker",
        "sandboxAutonomy",
        "worker:{workerId}",
    ] {
        assert!(
            sandbox_contract.contains(required),
            "sandbox::spawn_worker must stay a high-risk domain-owned capability with complete engine metadata; missing `{required}`"
        );
    }
    assert!(
        !sandbox_contract.contains(".approval_required(true)"),
        "sandbox lifecycle capabilities are sandbox-autonomous and must not create user approvals"
    );

    let sandbox = std::fs::read_to_string(crate_root.join("src/domains/sandbox/mod.rs"))
        .expect("failed to read sandbox domain");
    assert!(
        sandbox.contains("\"worker::disconnect\"")
            && sandbox.contains("\"stream::publish\"")
            && !sandbox.contains(".unregister_worker("),
        "sandbox worker cleanup must route through engine worker/stream primitives, not direct catalog cleanup"
    );
}

#[test]
fn approvals_are_engine_owned_not_model_confirmation_tools() {
    let repo_root = repo_root();
    let agent_root = crate_root();
    let agent_contract = std::fs::read_to_string(agent_root.join("src/domains/agent/contract.rs"))
        .expect("failed to read agent contract");
    let agent_handlers = std::fs::read_to_string(agent_root.join("src/domains/agent/handlers.rs"))
        .expect("failed to read agent handlers");

    assert!(
        !agent_root
            .join(["src/domains/", "tools", "/operations/catalog.rs"].concat())
            .exists(),
        "approval UI must be engine-owned; GetConfirmation must not be a model-facing tool"
    );
    assert!(
        !agent_contract.contains("agent::submit_confirmation")
            && !agent_handlers.contains("submit_confirmation"),
        "model-level confirmation submission must not be a canonical agent capability"
    );
    for stale in [
        "/engine/approvals",
        "/api/approvals",
        "model-level GetConfirmation",
    ] {
        let capability_docs =
            std::fs::read_to_string(agent_root.join("src/domains/capability/mod.rs"))
                .expect("failed to read capability docs");
        assert!(
            !capability_docs.contains(stale),
            "capability guidance must not mention stale approval path `{stale}`"
        );
    }

    let ios_agent_client = std::fs::read_to_string(
        repo_root.join("packages/ios-app/Sources/Services/Network/Clients/AgentClient.swift"),
    )
    .expect("failed to read iOS agent client");
    assert!(
        !ios_agent_client.contains("submitConfirmation")
            && !ios_agent_client.contains("agent::submit_confirmation"),
        "iOS must resolve approvals through approval::resolve, never agent::submit_confirmation"
    );

    let ios_sources = repo_root.join("packages/ios-app/Sources");
    for path in files_with_extensions(&ios_sources, &["swift"]) {
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read iOS source {path:?}: {e}"));
        for stale in [
            "GetConfirmation",
            "getconfirmation",
            "submitConfirmation",
            "submit_confirmation",
            "confirmedAction",
            "confirmation_response",
        ] {
            assert!(
                !content.contains(stale),
                "{} contains stale model-confirmation approval path `{stale}`",
                path.strip_prefix(&repo_root).unwrap_or(&path).display()
            );
        }
    }
}

#[test]
fn agent_runtime_stays_engine_native() {
    let crate_root = crate_root();
    let agent_root = crate_root.join("src/domains/agent");
    let agent_mod =
        std::fs::read_to_string(agent_root.join("mod.rs")).expect("failed to read agent/mod.rs");
    for removed in [
        "hidden_function_registrations",
        "FunctionDefinition::new",
        "agent_prompt_apply_request_schema",
        "agent_prompt_queue_drain_request_schema",
    ] {
        assert!(
            !agent_mod.contains(removed),
            "agent/mod.rs must stay docs/exports only; hidden contracts belong in contract.rs, found `{removed}`"
        );
    }

    let agent_contract = std::fs::read_to_string(agent_root.join("contract.rs"))
        .expect("failed to read agent/contract.rs");
    for required in [
        "agent::prompt_apply",
        "agent::run_turn",
        "agent::prompt_queue_drain",
        ".visibility(VisibilityScope::Internal)",
    ] {
        assert!(
            agent_contract.contains(required),
            "agent hidden runtime capability contracts must live in agent/contract.rs with internal visibility; missing `{required}`"
        );
    }

    for path in rust_files_under(&agent_root) {
        let rel = path.strip_prefix(&crate_root).unwrap();
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
        let production_content = content
            .split("#[cfg(test)]")
            .next()
            .unwrap_or(content.as_str());
        for removed in [
            "crate::domains::memory::retain",
            "crate::domains::prompt_library::store",
            "record_prompt_and_prune(",
        ] {
            assert!(
                !production_content.contains(removed),
                "{} must route cross-domain side effects through engine/domain capabilities, not `{removed}`",
                rel.display()
            );
        }
        assert!(
            !production_content.contains("target_revision: None"),
            "{} must pin hidden queue handoffs to the current function revision",
            rel.display()
        );
    }

    let capability_executor = std::fs::read_to_string(
        crate_root.join("src/domains/agent/runner/agent/capability_invocation_executor.rs"),
    )
    .expect("failed to read capability_invocation_executor.rs");
    assert!(
        !capability_executor.contains("TraceId::new(format!(\"tool:"),
        "model capability child invocations must inherit the agent run trace instead of minting detached tool traces"
    );
    assert!(
        capability_executor.contains("with_parent_invocation"),
        "model capability child invocations must carry the agent run-turn invocation as parent"
    );
}

#[test]
fn server_package_uses_domain_owned_engine_layout() {
    let crate_root = crate_root();
    for removed in [
        "src/server",
        "src/runtime",
        "src/events",
        "src/tools",
        "src/settings",
        "src/cron",
        "src/worktree",
        "src/llm",
        "src/mcp",
        "src/skills",
        "src/prompt_library",
        "src/transcription",
    ] {
        assert!(
            !crate_root.join(removed).exists(),
            "{removed} must stay deleted; implementation code is owned by domains, app, transport, platform, engine, or shared"
        );
    }

    let domains_root = crate_root.join("src/domains");
    assert!(
        domains_root.is_dir(),
        "domains directory must exist as the canonical worker surface"
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
        if domain_name == "capability_support" {
            assert!(
                !path.join("contract.rs").exists()
                    && !path.join("deps.rs").exists()
                    && !path.join("handlers.rs").exists()
                    && !path.join("operations").exists(),
                "capability_support is a support namespace and must not own an active worker surface"
            );
            continue;
        }
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
    for required in ["agent", "auth", "cron", "session", "settings", "worktree"] {
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
        "agent", "auth", "context", "cron", "job", "mcp", "memory", "model", "session", "worktree",
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
            !operations_content.contains("pub(crate) async fn")
                && !operations_content.contains("pub(super) async fn")
                && !operations_content.contains("impl InProcessFunctionHandler"),
            "flow-critical domain worker `{required}` operations/mod.rs must stay an export map, not a mixed-purpose executable file"
        );
        let operation_files = std::fs::read_dir(domain_root.join("operations"))
            .unwrap_or_else(|e| panic!("failed to read operations dir for {required}: {e}"))
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| path.extension().is_some_and(|ext| ext == "rs"))
            .filter(|path| path.file_name().is_some_and(|name| name != "mod.rs"))
            .collect::<Vec<_>>();
        assert!(
            !operation_files.is_empty(),
            "flow-critical domain worker `{required}` must split executable operations into workflow files"
        );
        assert!(
            operation_files.iter().any(|path| {
                let content = std::fs::read_to_string(path)
                    .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
                content.contains("pub(crate) async fn")
                    || content.contains("pub(crate) fn")
                    || content.contains("impl ")
                    || content.contains("InProcessFunctionHandler")
            }),
            "flow-critical domain worker `{required}` operation files must contain executable operation code"
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
        .expect("failed to read domains/mod.rs");
    for removed in [
        "use std::",
        "use serde",
        "use serde_json",
        "use crate::",
        "pub(crate) use worker::",
        "pub use worker::",
    ] {
        assert!(
            !domains_mod.contains(removed),
            "root domains module must stay docs/module declarations only and not retain `{removed}`"
        );
    }
    for removed in [
        "pub(crate) struct DomainRegistrationContext",
        "pub(crate) struct DomainFunctionRegistration",
        "pub(crate) struct DomainWorkerModule",
        "pub(crate) fn domain_worker_module",
    ] {
        assert!(
            !domains_mod.contains(removed),
            "root domains module must expose worker types from worker.rs instead of defining `{removed}`"
        );
    }
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
    for removed in [
        "DomainFunctionHandler",
        "DomainHandlerFn",
        "domain_handler!",
        "domain_function_registration",
    ] {
        assert!(
            !domains_mod.contains(removed),
            "root domains module must not retain central execution plumbing `{removed}`"
        );
    }

    for required in [
        "worker.rs",
        "agent/runtime/service/request.rs",
        "agent/runtime/service/deps.rs",
        "agent/runtime/service/plan.rs",
        "agent/runtime/service/spawn.rs",
        "agent/runtime/service/execute.rs",
        "agent/runtime/service/queue.rs",
        "agent/runtime/service/events.rs",
        "agent/runtime/service/agent_build.rs",
        "agent/runtime/service/completion.rs",
        "agent/runtime/service/context.rs",
        "agent/runtime/service/hooks.rs",
        "agent/runtime/service/worktree.rs",
        "agent/runtime/runtime/user_event.rs",
        "agent/runtime/runtime/bootstrap.rs",
        "agent/runtime/runtime/pending.rs",
        "agent/runtime/runtime/session_update.rs",
        "agent/runtime/runtime/skills.rs",
        "session/commands/create.rs",
        "session/commands/archive.rs",
        "session/commands/delete.rs",
        "session/commands/fork.rs",
        "session/commands/preload.rs",
        "session/context/cache.rs",
        "session/context/dynamic.rs",
        "session/context/rules.rs",
        "session/context/types.rs",
        "context/queries/audit.rs",
        "context/queries/payload_preview.rs",
        "context/queries/prepare.rs",
        "context/queries/snapshot.rs",
        "capability_support/interactive_enrichment/payload.rs",
        "capability_support/interactive_enrichment/questions.rs",
        "capability_support/interactive_enrichment/subagent.rs",
        "memory/retain/auto_retain/decision.rs",
        "memory/retain/auto_retain/state.rs",
        "memory/retain/auto_retain/fire.rs",
        "worktree/git_workflow/branches.rs",
        "worktree/git_workflow/conflicts.rs",
        "worktree/git_workflow/finalize.rs",
        "worktree/git_workflow/merge.rs",
        "worktree/git_workflow/rebase.rs",
        "worktree/git_workflow/remote.rs",
        "worktree/git_workflow/shared.rs",
        "worktree/git_workflow/subagent.rs",
    ] {
        assert!(
            domains_root.join(required).is_file(),
            "domain readability split must keep `{required}` as an owned workflow module"
        );
    }
    let execute_lines =
        std::fs::read_to_string(domains_root.join("agent/runtime/service/execute.rs"))
            .expect("failed to read agent runtime execute spine")
            .lines()
            .count();
    assert!(
        execute_lines <= 400,
        "agent runtime execute.rs must stay a lifecycle spine, not a mixed-purpose body ({execute_lines} lines)"
    );

    for required in [
        "session/agent.rs",
        "session/lifecycle.rs",
        "session/worktree.rs",
    ] {
        assert!(
            crate_root
                .join("src/transport/runtime/streams")
                .join(required)
                .is_file(),
            "runtime stream projection must keep `{required}` split by event family"
        );
    }
    let catalog = std::fs::read_to_string(domains_root.join("catalog.rs"))
        .expect("failed to read domains/catalog.rs");
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
        .expect("failed to read domains/contract.rs");
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
        let is_test_only_file = rel.file_name().is_some_and(|name| {
            let name = name.to_string_lossy();
            name == "tests.rs" || name.ends_with("_tests.rs")
        });
        if rel.starts_with("src/domains") && !is_test_only_file {
            assert!(
                !production_content.contains("use super::*;"),
                "{} must import explicit local/shared symbols instead of parent wildcard exports",
                rel.display()
            );
            assert!(
                !production_content.contains("use crate::domains::*;"),
                "{} must not replace parent wildcard imports with the root domain prelude",
                rel.display()
            );
        }
        if rel.ends_with("deps.rs") {
            assert!(
                !production_content.contains("ServerRuntimeContext"),
                "{} must not store or construct deps from the full ServerRuntimeContext",
                rel.display()
            );
        }
        let allowed_setup_boundary = rel == Path::new("src/domains/mod.rs")
            || rel == Path::new("src/domains/registration.rs")
            || rel == Path::new("src/domains/worker.rs");
        if !allowed_setup_boundary {
            assert!(
                !production_content.contains("&ServerRuntimeContext"),
                "{} production domain operations must take narrow deps, not &ServerRuntimeContext",
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
            !content.contains("server_context: Arc<ServerRuntimeContext>"),
            "{} must expose narrow deps instead of storing the full ServerRuntimeContext",
            rel.display()
        );
        let is_stream_publisher = rel
            .file_name()
            .is_some_and(|name| name == "stream.rs" || name == "callbacks.rs");
        let is_runtime_primitive = rel.starts_with("src/domains/cron/callbacks.rs");
        if rel.starts_with("src/domains") && !is_stream_publisher && !is_runtime_primitive {
            assert!(
                !production_content.contains("publish_stream_event(")
                    && !production_content.contains("PublishStreamEvent"),
                "{} must publish domain events through typed domain stream publishers",
                rel.display()
            );
        }
        if rel.ends_with("handlers.rs") {
            assert!(
                production_content.contains("operation_bindings!"),
                "{} must use a declarative local operation binding table",
                rel.display()
            );
            for removed in [
                "match operation_key",
                "match key",
                "struct FunctionHandler",
                "impl InProcessFunctionHandler",
            ] {
                assert!(
                    !production_content.contains(removed),
                    "{} must not reintroduce handler-owned dispatch shape `{removed}`",
                    rel.display()
                );
            }
            assert!(
                !production_content.contains("\"agent::prompt\" =>")
                    && !production_content.contains("\"auth::get\" =>")
                    && !production_content.contains("\"worktree::get_status\" =>")
                    && !production_content.contains("\"git::clone\" =>")
                    && !production_content.contains("\"cron::list\" =>")
                    && !production_content.contains("\"mcp::status\" =>")
                    && !production_content.contains("\"job::background\" =>")
                    && !production_content
                        .contains(&format!("\"{}\" =>", concat!("tool", "::result")))
                    && !production_content.contains("\"session::create\" =>"),
                "{} must bind by domain operation key, not canonical function id",
                rel.display()
            );
        }
    }
}

#[test]
fn retired_browser_stream_capabilities_stay_deleted() {
    let repo_root = repo_root();
    for root in [
        crate_root().join("src/domains"),
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
        crate_root.join("src/domains"),
        crate_root.join("src/transport/runtime"),
        crate_root.join("src/shared/server"),
    ] {
        for path in rust_files_under(&root) {
            let rel = path.strip_prefix(&crate_root).unwrap();
            if rel == Path::new("src/shared/server/test_support.rs") {
                continue;
            }
            let content = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));
            assert!(
                !content.contains("server::transport") && !content.contains("crate::transport::"),
                "{} must not import client transport modules",
                rel.display()
            );
        }
    }
}

#[test]
fn domains_do_not_import_other_domains_private_operations() {
    let crate_root = crate_root();
    let domains_root = crate_root.join("src/domains");
    for path in rust_files_under(&domains_root) {
        let rel = path.strip_prefix(&crate_root).unwrap();
        let content = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read {path:?}: {e}"));

        let Some(domain_name) = rel
            .components()
            .nth(2)
            .and_then(|component| component.as_os_str().to_str())
        else {
            continue;
        };

        for needle in ["crate::domains::", "super::super::"] {
            for line in content.lines().filter(|line| line.contains(needle)) {
                if !line.contains("::operations")
                    && !line.contains("::runtime::")
                    && !line.contains("::service")
                {
                    continue;
                }
                assert!(
                    line.contains(&format!("domains::{domain_name}::operations"))
                        || line.contains(&format!("domains::{domain_name}::runtime::"))
                        || line.contains(&format!("domains::{domain_name}::service"))
                        || line.contains("super::super::operations"),
                    "{} must not import another domain's private operations, runtime workflows, or services: {line}",
                    rel.display()
                );
            }
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

fn files_with_extensions(root: &Path, extensions: &[&str]) -> Vec<PathBuf> {
    let mut files = Vec::new();
    visit_files_with_extensions(root, extensions, &mut files);
    files
}

fn visit_files_with_extensions(root: &Path, extensions: &[&str], files: &mut Vec<PathBuf>) {
    if !root.exists() {
        return;
    }
    let entries = std::fs::read_dir(root)
        .unwrap_or_else(|e| panic!("failed to read directory {root:?}: {e}"));
    for entry in entries {
        let entry = entry.unwrap_or_else(|e| panic!("failed to read entry in {root:?}: {e}"));
        let path = entry.path();
        if path.is_dir() {
            visit_files_with_extensions(&path, extensions, files);
        } else if path
            .extension()
            .and_then(|ext| ext.to_str())
            .is_some_and(|ext| extensions.contains(&ext))
        {
            files.push(path);
        }
    }
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
