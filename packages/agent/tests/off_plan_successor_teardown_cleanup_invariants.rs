//! Static invariants for the off-plan successor teardown cleanup scorecard.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::process::Command;

const SCORECARD_PATH: &str = "packages/agent/docs/off-plan-successor-teardown-cleanup-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/off-plan-successor-teardown-cleanup-evidence-manifest.md";
const INVENTORY_PATH: &str = "packages/agent/docs/off-plan-successor-teardown-cleanup-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/off-plan-successor-teardown-cleanup-inventory.tsv";
const TARGET_PATH: &str = "packages/agent/tests/off_plan_successor_teardown_cleanup_invariants.rs";
const TARGET_NAME: &str = "off_plan_successor_teardown_cleanup_invariants";

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
        .expect("agent crate should live under packages/agent")
        .to_path_buf()
}

fn repo_path(path: &str) -> PathBuf {
    repo_root().join(path)
}

fn read_repo_file(path: &str) -> String {
    let full_path = repo_path(path);
    std::fs::read_to_string(&full_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", full_path.display()))
}

fn git_ls_files() -> BTreeSet<String> {
    let output = Command::new("git")
        .arg("ls-files")
        .current_dir(repo_root())
        .output()
        .expect("git ls-files should run");
    assert!(output.status.success(), "git ls-files failed");
    String::from_utf8(output.stdout)
        .expect("git output should be UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

#[test]
fn opstc_scorecard_inventory_and_readme_are_linked() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let readme = read_repo_file("README.md");

    for required in [
        "Status: **complete**",
        "Current score: **100/100**",
        "Passing threshold: **100/100**",
        "Audited off-plan range: `e781a6aef..2da96a848`",
        "Attachment parsed:",
        "Remaining original-list slices after this cleanup remain:",
        "| OPSTC-0 | Harness | 5 | passed_after_fix |",
        "| OPSTC-9 | Closeout | 7 | passed_after_fix |",
        "The removed worker activation/orchestration/schedule commits are not converted",
    ] {
        assert!(
            scorecard.contains(required),
            "OPSTC scorecard missing required text: {required}"
        );
    }

    for required in [
        "Status: **complete**",
        "Current score: **100/100**",
        "| OPSTC-0 | passed_after_fix |",
        "| OPSTC-9 | passed_after_fix |",
        "git log --oneline e781a6aef..2da96a848",
        "git diff --name-status e781a6aef..2da96a848",
        "Residual Risk",
    ] {
        assert!(
            evidence.contains(required),
            "OPSTC evidence missing required text: {required}"
        );
    }

    for required in [
        "The TSV contains 160 rows",
        "`remove_successor_worker_surface`",
        "`retain_bounded_external_worker_substrate`",
        "Removed surfaces include the worker activation primitive",
    ] {
        assert!(
            inventory.contains(required),
            "OPSTC inventory missing required text: {required}"
        );
    }

    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
        TARGET_NAME,
    ] {
        assert!(
            readme.contains(required),
            "README must link OPSTC artifact or target: {required}"
        );
    }
}

#[test]
fn opstc_inventory_covers_every_off_plan_range_file() {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut rows = tsv.lines();
    assert_eq!(
        rows.next(),
        Some("id\tpath\trange_status\tclassification\taction\trationale\tevidence"),
        "OPSTC TSV header changed"
    );
    let rows = rows.collect::<Vec<_>>();
    assert_eq!(rows.len(), 160, "OPSTC inventory row count changed");

    let off_plan = rows
        .iter()
        .filter(|line| line.contains("\tM\t") || line.contains("\tA\t"))
        .count();
    assert_eq!(off_plan, 155, "every off-plan range file must have one row");

    for required in [
        "OPSTC-INV-001\t.github/workflows/ci.yml\tM\tgate_cleanup",
        "OPSTC-INV-089\tpackages/agent/src/engine/primitives/worker_activation.rs\tA\tremove_successor_worker_surface\tremoved",
        "OPSTC-INV-097\tpackages/agent/src/engine/runtime/worker_activation_bundle_vault.rs\tA\tremove_successor_worker_surface\tremoved",
        "OPSTC-INV-105\tpackages/agent/src/engine/runtime/worker_schedule/mod.rs\tA\tremove_successor_worker_surface\tremoved",
        "OPSTC-INV-148\tpackages/agent/tests/self_adapting_agent_successor_teardown_cleanup_invariants.rs\tA\treplace_cleanup_harness\tremoved_replaced_by_opstc",
        "OPSTC-INV-160\tpackages/agent/tests/data_integrity_storage_evolution_migration_discipline_invariants.rs\tpost_range\tpredecessor_bookkeeping",
    ] {
        assert!(
            tsv.contains(required),
            "OPSTC inventory missing required row: {required}"
        );
    }
}

#[test]
fn opstc_removed_successor_files_and_old_gates_stay_absent() {
    let tracked = git_ls_files();
    for deleted in [
        "packages/agent/src/engine/primitives/worker_activation.rs",
        "packages/agent/src/engine/primitives/worker_activation_governance.rs",
        "packages/agent/src/engine/invocation/host/promotion_governance.rs",
        "packages/agent/src/engine/runtime/worker_activation_bundle_vault.rs",
        "packages/agent/src/engine/runtime/worker_orchestration/mod.rs",
        "packages/agent/src/engine/runtime/worker_schedule/mod.rs",
        "packages/agent/src/engine/durability/resources/worker_schedule_definitions.rs",
        "packages/agent/tests/self_adapting_agent_worker_activation_invariants.rs",
        "packages/agent/tests/self_adapting_agent_worker_orchestration_invariants.rs",
        "packages/agent/tests/self_adapting_agent_worker_schedule_dispatch_invariants.rs",
        "packages/agent/tests/self_adapting_agent_successor_teardown_cleanup_invariants.rs",
    ] {
        assert!(
            !repo_path(deleted).exists(),
            "deleted successor file still exists: {deleted}"
        );
        assert!(
            !tracked.contains(deleted),
            "deleted successor file is still tracked: {deleted}"
        );
    }

    for path in ["scripts/tron.d/quality.sh", ".github/workflows/ci.yml"] {
        let source = read_repo_file(path);
        assert!(source.contains(TARGET_NAME), "{path} must run OPSTC");
        for forbidden in [
            "self_adapting_agent_promotion_governance_invariants",
            "self_adapting_agent_worker_activation_invariants",
            "self_adapting_agent_worker_orchestration_invariants",
            "self_adapting_agent_worker_bundle_handoff_invariants",
            "self_adapting_agent_worker_trigger_launch_invariants",
            "self_adapting_agent_worker_schedule_dispatch_invariants",
            "self_adapting_agent_worker_schedule_capacity_invariants",
            "self_adapting_agent_successor_teardown_cleanup_invariants",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} still runs removed successor target {forbidden}"
            );
        }
    }
}

#[test]
fn opstc_source_tree_has_no_successor_activation_launch_or_schedule_surface() {
    let source_files = git_ls_files()
        .into_iter()
        .filter(|path| path.starts_with("packages/agent/src/"))
        .filter(|path| repo_path(path).is_file())
        .collect::<Vec<_>>();

    for path in source_files {
        let source = read_repo_file(&path);
        for forbidden in [
            "worker::issue_activation",
            "worker::launch_activation",
            "worker::launch_from_trigger",
            "stdin_activation_bundle_v1",
            "worker_schedule_plan",
            "worker_schedule_tick",
            "worker_schedule_scan_state",
            "worker_activation_bundle",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} still contains removed successor marker {forbidden}"
            );
        }
    }

    let engine_mod = read_repo_file("packages/agent/src/engine/mod.rs");
    for forbidden in [
        "EngineWorkerScheduleRuntime",
        "WORKER_SCHEDULE_",
        "worker_schedule::",
    ] {
        assert!(
            !engine_mod.contains(forbidden),
            "engine facade still exports removed schedule surface: {forbidden}"
        );
    }

    let runtime_mod = read_repo_file("packages/agent/src/engine/runtime/mod.rs");
    for forbidden in [
        "worker_activation_bundle_vault",
        "worker_orchestration",
        "worker_schedule",
    ] {
        assert!(
            !runtime_mod.contains(forbidden),
            "runtime module still declares removed successor module: {forbidden}"
        );
    }

    let primitives_mod = read_repo_file("packages/agent/src/engine/primitives/mod.rs");
    for forbidden in ["worker_activation", "worker_activation_governance"] {
        assert!(
            !primitives_mod.contains(forbidden),
            "primitive module still declares removed activation module: {forbidden}"
        );
    }
}

#[test]
fn opstc_retained_substrate_is_bounded_and_not_a_successor_feature() {
    let worker = read_repo_file("packages/agent/src/engine/primitives/worker.rs");
    for required in [
        "pub(crate) const LIST_FUNCTION: &str = \"worker::list\";",
        "pub(crate) const GET_FUNCTION: &str = \"worker::get\";",
        "pub(crate) const DISCONNECT_FUNCTION: &str = \"worker::disconnect\";",
        "pub(crate) const HEALTH_FUNCTION: &str = \"worker::health\";",
    ] {
        assert!(
            worker.contains(required),
            "worker primitive must retain bounded primitive function: {required}"
        );
    }
    for forbidden in [
        "ISSUE_ACTIVATION",
        "LAUNCH_ACTIVATION",
        "LAUNCH_FROM_TRIGGER",
    ] {
        assert!(
            !worker.contains(forbidden),
            "worker primitive retained successor function marker {forbidden}"
        );
    }

    let external_workers =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/mod.rs");
    for required in [
        "This is deliberately loopback-only and protocol-bound",
        "Accepted hellos must present an external worker, loopback",
        "mod lifecycle;",
        "mod proxy;",
        "mod registration;",
        "mod validation;",
    ] {
        assert!(
            external_workers.contains(required),
            "generic external-worker substrate missing retained bound: {required}"
        );
    }
    assert!(
        !external_workers.contains("EngineWorkerOrchestrationRuntime"),
        "external-worker runtime must not depend on removed orchestration runtime"
    );
}
