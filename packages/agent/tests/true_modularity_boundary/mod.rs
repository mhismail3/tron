//! Static gates for the True Modularity Boundary campaign.

mod support;

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use support::*;

#[test]
fn true_modularity_scorecard_stays_formalized() {
    let scorecard = read_repo_file("packages/agent/docs/true-modularity-boundary-scorecard.md");
    let manifest =
        read_repo_file("packages/agent/docs/true-modularity-boundary-evidence-manifest.md");
    let readme = read_repo_file("README.md");

    for required in [
        "# True Modularity Boundary Scorecard",
        "Status: **active**",
        "Current score: **5/100**",
        "Branch: `codex/primitive-engine-teardown`",
        "This scorecard formalizes the True Modularity Boundary campaign.",
        "## Boundary Taxonomy",
        "`facade`",
        "`contract`",
        "`adapter`",
        "`implementation`",
        "`composition-root`",
        "`test-support`",
        "`generated-wire-dto`",
        "| TMB-0 | Create the campaign harness | 5 | passed_after_fix |",
        "| TMB-1 | Define boundary taxonomy and inventory | 8 | open |",
        "| TMB-2 | Build the model response black box | 15 | open |",
        "| TMB-3 | Narrow engine facade ownership | 12 | open |",
        "| TMB-4 | Harden domain worker boundaries | 10 | open |",
        "| TMB-5 | Encapsulate state and storage | 10 | open |",
        "| TMB-6 | Make transport adapter-only | 10 | open |",
        "| TMB-7 | Make iOS Engine access black-boxed | 10 | open |",
        "| TMB-8 | Define boundary-local error contracts | 8 | open |",
        "| TMB-9 | Update docs and README | 6 | open |",
        "| TMB-10 | Final adversarial closeout | 6 | open |",
        "`true_modularity_scorecard_stays_formalized`",
        "`boundary_inventory_covers_tracked_sources`",
        "`agent_loop_uses_model_responder_boundary`",
        "`provider_internals_do_not_escape_model_domain`",
        "`engine_facade_is_the_only_cross_module_engine_api`",
        "`domain_workers_expose_contracts_not_services`",
        "`state_stores_are_owner_private`",
        "`transport_is_adapter_only`",
        "`ios_ui_uses_repositories_not_engine_transport`",
        "`boundary_errors_do_not_leak_impl_errors`",
        "`final_modularity_closeout_is_complete`",
    ] {
        assert!(
            scorecard.contains(required),
            "TMB scorecard missing required text: {required}"
        );
    }

    for required in [
        "# True Modularity Boundary Evidence Manifest",
        "Status: **active**",
        "Current score: **5/100**",
        "| TMB-0 | passed_after_fix |",
        "## TMB-0 Red Proof",
        "The first invariant run is intentionally red.",
        "Rust agent loop imports `domains::model::providers` directly",
        "Provider factory and provider health types cross into server and agent",
    ] {
        assert!(
            manifest.contains(required),
            "TMB evidence manifest missing required text: {required}"
        );
    }

    assert!(
        readme.contains("packages/agent/docs/true-modularity-boundary-scorecard.md")
            && readme.contains("packages/agent/docs/true-modularity-boundary-evidence-manifest.md")
            && readme.contains("packages/agent/tests/true_modularity_boundary_invariants.rs"),
        "README living-doc map must link the active TMB scorecard, evidence manifest, and invariant target"
    );
}

#[test]
fn boundary_inventory_covers_tracked_sources() {
    let inventory = read_repo_file("packages/agent/docs/true-modularity-boundary-inventory.tsv");
    let mut rows = BTreeMap::new();
    for line in inventory.lines().skip(1) {
        let columns: Vec<&str> = line.split('\t').collect();
        assert!(
            columns.len() >= 5,
            "inventory row must have path, language, class, owner, and dependency direction columns: {line}"
        );
        rows.insert(columns[0].to_owned(), columns);
    }

    let tracked_sources = tracked_boundary_sources();
    let missing: Vec<String> = tracked_sources
        .iter()
        .filter(|path| !rows.contains_key(*path))
        .cloned()
        .collect();
    assert!(
        missing.is_empty(),
        "boundary inventory must classify every tracked Rust/Swift production source:\n{}",
        missing.join("\n")
    );

    let allowed_classes: BTreeSet<&str> = [
        "facade",
        "contract",
        "adapter",
        "implementation",
        "composition-root",
        "test-support",
        "generated-wire-dto",
    ]
    .into_iter()
    .collect();

    for (path, columns) in rows {
        assert!(
            allowed_classes.contains(columns[2]),
            "inventory row for {path} has unknown class `{}`",
            columns[2]
        );
        assert!(
            !columns[3].trim().is_empty() && !columns[4].trim().is_empty(),
            "inventory row for {path} must record owner and dependency direction"
        );
    }
}

#[test]
fn agent_loop_uses_model_responder_boundary() {
    assert!(
        repo_path("packages/agent/src/domains/model/responder/mod.rs").exists(),
        "domains::model must expose an internal responder boundary module"
    );

    let leaks = rust_source_lines("packages/agent/src/domains/agent")
        .into_iter()
        .filter(|line| {
            line.contains("domains::model::providers")
                || line.contains("ProviderFactory")
                || line.contains("ProviderHealthTracker")
                || line.contains("dyn Provider")
                || line.contains("ProviderStreamOptions")
        })
        .collect::<Vec<_>>();

    assert!(
        leaks.is_empty(),
        "agent loop must depend on domains::model responder APIs, not provider internals:\n{}",
        leaks.join("\n")
    );
}

#[test]
fn provider_internals_do_not_escape_model_domain() {
    let allowed_prefixes = [
        "packages/agent/src/domains/model/",
        "packages/agent/src/app/bootstrap/",
    ];
    let leaks = rust_source_lines("packages/agent/src")
        .into_iter()
        .filter(|line| !path_has_any_prefix(path_from_line(line), &allowed_prefixes))
        .filter(|line| {
            line.contains("domains::model::providers::")
                || line.contains("pub use providers::")
                || line.contains("ProviderError")
                || line.contains("ProviderFactory")
                || line.contains("ProviderHealthTracker")
        })
        .collect::<Vec<_>>();

    assert!(
        leaks.is_empty(),
        "provider internals may not escape domains::model except documented composition roots:\n{}",
        leaks.join("\n")
    );
}

#[test]
fn engine_facade_is_the_only_cross_module_engine_api() {
    let allowed_prefixes = [
        "packages/agent/src/engine/",
        "packages/agent/src/app/bootstrap/",
        "packages/agent/src/domains/registration/",
    ];
    let banned_segments = [
        "crate::engine::authority::",
        "crate::engine::catalog::",
        "crate::engine::durability::",
        "crate::engine::invocation::",
        "crate::engine::kernel::",
        "crate::engine::primitives::",
        "crate::engine::runtime::",
    ];

    let leaks = rust_source_lines("packages/agent/src")
        .into_iter()
        .filter(|line| !path_has_any_prefix(path_from_line(line), &allowed_prefixes))
        .filter(|line| banned_segments.iter().any(|needle| line.contains(needle)))
        .collect::<Vec<_>>();

    assert!(
        leaks.is_empty(),
        "cross-module engine users must import the approved engine facade, not internals:\n{}",
        leaks.join("\n")
    );
}

#[test]
fn domain_workers_expose_contracts_not_services() {
    let allowed_prefixes = [
        "packages/agent/src/domains/",
        "packages/agent/src/app/bootstrap/",
    ];
    let leaks = rust_source_lines("packages/agent/src")
        .into_iter()
        .filter(|line| !path_has_any_prefix(path_from_line(line), &allowed_prefixes))
        .filter(|line| {
            line.contains("::handlers::")
                || line.contains("::service::")
                || line.contains("::deps::")
                || line.contains("::operations::")
        })
        .collect::<Vec<_>>();

    assert!(
        leaks.is_empty(),
        "runtime/transport/app code must use domain contracts or composition roots, not domain services:\n{}",
        leaks.join("\n")
    );
}

#[test]
fn state_stores_are_owner_private() {
    let allowed_prefixes = [
        "packages/agent/src/domains/session/event_store/",
        "packages/agent/src/engine/durability/",
        "packages/agent/src/engine/primitives/stores.rs",
        "packages/agent/src/domains/settings/profile/storage/",
        "packages/agent/src/domains/auth/credentials/storage/",
        "packages/agent/src/shared/storage/",
    ];
    let leaks = rust_source_lines("packages/agent/src")
        .into_iter()
        .filter(|line| !path_has_any_prefix(path_from_line(line), &allowed_prefixes))
        .filter(|line| {
            line.contains("event_store::sqlite")
                || line.contains("rusqlite::")
                || line.contains("Sqlite")
                || line.contains("repositories::")
                || line.contains("storage::")
        })
        .collect::<Vec<_>>();

    assert!(
        leaks.is_empty(),
        "state and storage backends must stay behind owner repository/service contracts:\n{}",
        leaks.join("\n")
    );
}

#[test]
fn transport_is_adapter_only() {
    let leaks = rust_source_lines("packages/agent/src/transport")
        .into_iter()
        .filter(|line| {
            line.contains("domains::agent::")
                || line.contains("domains::session::event_store::sqlite")
                || line.contains("domains::model::providers")
                || line.contains("engine::durability::")
        })
        .collect::<Vec<_>>();

    assert!(
        leaks.is_empty(),
        "transport code must frame requests and map protocol only:\n{}",
        leaks.join("\n")
    );
}

#[test]
fn ios_ui_uses_repositories_not_engine_transport() {
    let leaks = swift_source_lines("packages/ios-app/Sources")
        .into_iter()
        .filter(|line| {
            let path = path_from_line(line);
            path.starts_with("packages/ios-app/Sources/Session/")
                || path.starts_with("packages/ios-app/Sources/UI/")
        })
        .filter(|line| {
            line.contains("EngineClient")
                || line.contains("WebSocket")
                || line.contains("EngineProtocolTypes")
                || line.contains("Server")
        })
        .collect::<Vec<_>>();

    assert!(
        leaks.is_empty(),
        "iOS session/UI layers must depend on repositories/view models, not concrete engine transport or raw DTOs:\n{}",
        leaks.join("\n")
    );
}

#[test]
fn boundary_errors_do_not_leak_impl_errors() {
    let leaks = rust_source_lines("packages/agent/src")
        .into_iter()
        .filter(|line| {
            line.contains("ProviderError")
                || line.contains("rusqlite::Error")
                || line.contains("tokio_tungstenite")
                || line.contains("serde_json::Error")
        })
        .filter(|line| {
            !path_has_any_prefix(
                path_from_line(line),
                &[
                    "packages/agent/src/domains/model/",
                    "packages/agent/src/domains/session/event_store/",
                    "packages/agent/src/shared/server/error_mapping.rs",
                    "packages/agent/src/transport/",
                ],
            )
        })
        .collect::<Vec<_>>();

    assert!(
        leaks.is_empty(),
        "implementation-detail errors must be mapped at owning boundaries:\n{}",
        leaks.join("\n")
    );
}

#[test]
fn final_modularity_closeout_is_complete() {
    let scorecard = read_repo_file("packages/agent/docs/true-modularity-boundary-scorecard.md");
    let manifest =
        read_repo_file("packages/agent/docs/true-modularity-boundary-evidence-manifest.md");

    for required in [
        "Current score: **100/100**",
        "Status: **completed**",
        "| TMB-10 | Final adversarial closeout | 6 | passed_after_fix |",
        "Full CI closeout",
        "scripts/tron ci fmt check clippy test",
        "scripts/personal-info-guard.sh",
        "git diff --check",
        "git status --short",
    ] {
        assert!(
            scorecard.contains(required) || manifest.contains(required),
            "final TMB closeout missing required evidence marker: {required}"
        );
    }
}

fn path_from_line(line: &str) -> &str {
    line.split_once(':').map_or("", |(path, _)| path)
}

fn path_has_any_prefix(path: &str, prefixes: &[&str]) -> bool {
    prefixes.iter().any(|prefix| path.starts_with(prefix))
}

fn rust_source_lines(root: &str) -> Vec<String> {
    source_lines(root, "rs")
}

fn swift_source_lines(root: &str) -> Vec<String> {
    source_lines(root, "swift")
}

fn source_lines(root: &str, extension: &str) -> Vec<String> {
    let mut lines = Vec::new();
    for path in tracked_files() {
        if !path.starts_with(root)
            || Path::new(&path).extension().and_then(|e| e.to_str()) != Some(extension)
        {
            continue;
        }
        if is_test_support_path(&path) {
            continue;
        }
        let text = read_repo_file(&path);
        for (index, line) in strip_cfg_test_modules(&text).lines().enumerate() {
            let trimmed = line.trim();
            if trimmed.starts_with("//") || trimmed.starts_with("#[cfg(test)]") {
                continue;
            }
            lines.push(format!("{path}:{}:{trimmed}", index + 1));
        }
    }
    lines
}
