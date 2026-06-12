//! Static gates for Self-Sufficient Agent Runtime Readiness.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;

const SCORECARD_PATH: &str =
    "packages/agent/docs/self-sufficient-agent-runtime-readiness-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/self-sufficient-agent-runtime-readiness-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/self-sufficient-agent-runtime-readiness-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/self-sufficient-agent-runtime-readiness-inventory.tsv";
const TARGET_PATH: &str =
    "packages/agent/tests/self_sufficient_agent_runtime_readiness_invariants.rs";
const TARGET_NAME: &str = "self_sufficient_agent_runtime_readiness_invariants";

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
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
        .expect("git output should be utf8")
        .lines()
        .map(str::to_owned)
        .collect()
}

fn parse_scorecard_row(row: &str) -> Vec<&str> {
    row.trim_matches('|').split('|').map(str::trim).collect()
}

fn closeout_targets_from_quality(source: &str) -> BTreeSet<String> {
    let mut in_array = false;
    let mut targets = BTreeSet::new();
    for line in source.lines() {
        let trimmed = line.trim();
        if trimmed == "local closeout_test_targets=(" {
            in_array = true;
            continue;
        }
        if in_array && trimmed == ")" {
            break;
        }
        if in_array && !trimmed.is_empty() {
            targets.insert(trimmed.to_owned());
        }
    }
    targets
}

fn closeout_targets_from_ci(source: &str) -> BTreeSet<String> {
    source
        .lines()
        .filter_map(|line| {
            let trimmed = line.trim();
            let rest = trimmed.strip_prefix("cargo test --test ")?;
            Some(
                rest.split_whitespace()
                    .next()
                    .expect("cargo test line should name target")
                    .to_owned(),
            )
        })
        .collect()
}

#[test]
fn sarr_artifacts_readme_and_gate_wiring_exist() {
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(repo_path(path).exists(), "missing SARR artifact: {path}");
    }

    let readme = read_repo_file("README.md");
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
            "README must mention SARR artifact or target: {required}"
        );
    }

    for path in ["scripts/tron.d/quality.sh", ".github/workflows/ci.yml"] {
        let source = read_repo_file(path);
        assert!(source.contains(TARGET_NAME), "{path} must run SARR");
    }
}

#[test]
fn sarr_scorecard_rows_have_exact_weights_and_closed_state_hygiene() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(scorecard.contains("Passing threshold: **100/100**"));
    assert!(scorecard.contains("Base commit: `f931c3126a2ee62940f42512278715c9c65c2079`"));
    assert!(scorecard.contains("Branch: `codex/self-sufficient-agent-runtime-readiness`"));
    assert!(
        scorecard.contains("This slice does not add worker autostart")
            && scorecard.contains("repo-managed first-party skills")
            && scorecard.contains("deploy automation"),
        "SARR scorecard must state non-implementation scope"
    );

    let expected = [
        ("SARR-0", "Harness, Base, and Scope Control", 5),
        ("SARR-1", "Readiness Inventory Completeness", 10),
        ("SARR-2", "Extension Point Clarity Without Activation", 10),
        ("SARR-3", "Agent-Authored State Readiness Boundaries", 10),
        (
            "SARR-4",
            "Authority, Promotion, and Human-Control Gate Readiness",
            12,
        ),
        (
            "SARR-5",
            "Durability, Replay, and Audit Trail Readiness",
            10,
        ),
        ("SARR-6", "Public Protocol and Client Shell Readiness", 8),
        (
            "SARR-7",
            "Resource, Configuration, and Operational Guardrail Readiness",
            8,
        ),
        (
            "SARR-8",
            "Cross-Slice Consistency and Living-Doc Truthfulness",
            8,
        ),
        ("SARR-9", "Negative/Adversarial Readiness Gates", 10),
        ("SARR-10", "Verification, Clean State, and Commit", 9),
    ];

    let mut total = 0u32;
    let mut pending = 0usize;
    for (id, name, weight) in expected {
        let row = scorecard
            .lines()
            .find(|line| line.starts_with(&format!("| {id} |")))
            .unwrap_or_else(|| panic!("missing SARR row {id}"));
        let columns = parse_scorecard_row(row);
        assert_eq!(columns.get(1), Some(&name), "unexpected row name: {row}");
        assert_eq!(
            columns
                .get(2)
                .expect("row has weight")
                .parse::<u32>()
                .unwrap_or_else(|error| panic!("invalid row weight in {row}: {error}")),
            weight,
            "unexpected row weight: {row}"
        );
        let status = columns.get(3).expect("row has status");
        assert!(
            !status.is_empty() && *status != "TODO" && *status != "TBD",
            "SARR row status must be explicit: {row}"
        );
        if status.contains("pending") {
            pending += 1;
        }
        total += weight;
    }
    assert_eq!(total, 100, "SARR scorecard weights must sum to 100");

    if scorecard.contains("Status: **closed**") {
        assert!(scorecard.contains("Current score: **100/100**"));
        assert_eq!(
            pending, 0,
            "closed SARR scorecard cannot retain pending rows"
        );
        for forbidden in [
            "pending_validation",
            "not_run_yet",
            "TODO",
            "TBD",
            "will pass",
            "will update",
            "requires final",
        ] {
            assert!(
                !scorecard.contains(forbidden),
                "closed SARR scorecard contains stale marker {forbidden}"
            );
        }
    } else {
        assert!(
            !scorecard.contains("Current score: **100/100**"),
            "active SARR scorecard must not claim 100/100"
        );
        assert!(
            pending > 0,
            "active SARR scorecard should show pending rows"
        );
    }
}

#[test]
fn sarr_inventory_is_structured_and_complete_for_readiness_surfaces() {
    let inventory = read_repo_file(INVENTORY_PATH);
    assert!(inventory.contains("Status: **inventory_built_pre_edit**"));
    assert!(inventory.contains("This inventory was built before SARR source edits"));
    assert!(inventory.contains(INVENTORY_TSV_PATH));

    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    assert_eq!(
        lines.next(),
        Some(
            "id\tpath_or_surface\tsurface_kind\towner\tcurrent_contract\treadiness_role\tfuture_extension_risk\tallowed_now\tproof_target"
        ),
        "SARR inventory header changed"
    );
    let rows = lines.collect::<Vec<_>>();
    assert!(rows.len() >= 60, "SARR inventory row count regressed");

    let mut ids = BTreeSet::new();
    let mut kinds = BTreeSet::new();
    for row in rows {
        let columns = row.split('\t').collect::<Vec<_>>();
        assert_eq!(
            columns.len(),
            9,
            "SARR inventory row must have 9 columns: {row}"
        );
        assert!(
            ids.insert(columns[0].to_owned()),
            "duplicate row id {}",
            columns[0]
        );
        assert!(
            columns[0].starts_with("SARR-INV-"),
            "bad row id {}",
            columns[0]
        );
        kinds.insert(columns[2].to_owned());
        for value in columns {
            assert!(
                !value.trim().is_empty() && !value.contains("TODO") && !value.contains("TBD"),
                "SARR inventory field must be complete: {row}"
            );
        }
    }

    for required_kind in [
        "sarr_artifact",
        "execute_primitive",
        "engine_substrate",
        "authored_state",
        "authority_promotion",
        "public_protocol",
        "client_shell",
        "predecessor_evidence",
        "static_gate",
        "absent_guardrail",
    ] {
        assert!(
            kinds.contains(required_kind),
            "SARR inventory missing surface kind {required_kind}"
        );
    }

    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
        "packages/agent/src/domains/capability/contract.rs",
        "packages/agent/src/domains/capability/operations/resource.rs",
        "packages/agent/src/domains/agent/loop/capability_invocation_executor/grant.rs",
        "packages/agent/src/engine/mod.rs",
        "packages/agent/src/engine/durability/ledger/mod.rs",
        "packages/agent/src/engine/durability/queue/mod.rs",
        "packages/agent/src/engine/durability/streams/mod.rs",
        "packages/agent/src/engine/durability/replay.rs",
        "packages/agent/src/engine/durability/resources/definitions.rs",
        "packages/agent/src/engine/runtime/external_workers/validation.rs",
        "packages/agent/src/transport/engine/socket/wire.rs",
        "packages/agent/src/transport/engine/contracts.rs",
        "packages/ios-app/Sources/Engine/Protocol/GeneratedUI/EngineProtocolTypes+GeneratedUI.swift",
        "packages/ios-app/Sources/UI/RuntimeSurfaces/GeneratedRuntimeSurfaceView.swift",
        "packages/agent/docs/self-adapting-agent-authorship-scorecard.md",
        "packages/agent/docs/off-plan-successor-teardown-cleanup-scorecard.md",
        "packages/agent/docs/performance-resource-governance-scorecard.md",
        "packages/agent/docs/configuration-profile-environment-discipline-scorecard.md",
        "packages/agent/docs/release-install-upgrade-rollback-discipline-scorecard.md",
        "packages/agent/docs/ios-thin-client-generic-runtime-shell-scorecard.md",
        "packages/agent/docs/security-authority-capability-boundaries-inventory.tsv",
        "deleted:packages/agent/src/engine/primitives/worker_activation.rs",
        "absent:packages/agent/skills",
    ] {
        assert!(tsv.contains(required), "SARR inventory missing {required}");
    }
}

#[test]
fn sarr_evidence_manifest_lists_rows_and_required_commands() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    assert!(
        evidence.contains("Status: **active_validation_pending**")
            || evidence.contains("Status: **closed**"),
        "SARR evidence must record status"
    );

    for row in [
        "SARR-0", "SARR-1", "SARR-2", "SARR-3", "SARR-4", "SARR-5", "SARR-6", "SARR-7", "SARR-8",
        "SARR-9", "SARR-10",
    ] {
        assert!(
            evidence.contains(&format!("| {row} |")),
            "SARR evidence missing row evidence for {row}"
        );
    }

    for command in [
        "cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check",
        "cargo check --manifest-path packages/agent/Cargo.toml",
        "cargo test --manifest-path packages/agent/Cargo.toml --test self_sufficient_agent_runtime_readiness_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test developer_experience_repo_hygiene_automation_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_authorship_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_successor_teardown_cleanup_invariants -- --nocapture",
        "scripts/tron ci fmt check clippy test",
        "scripts/personal-info-guard.sh",
        "cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj",
        "git diff --check",
        "git ls-files -ci --exclude-standard",
        "git status --short",
    ] {
        assert!(
            evidence.contains(command),
            "SARR evidence missing required command: {command}"
        );
    }

    if evidence.contains("Status: **closed**") {
        assert!(evidence.contains("Current score: **100/100**"));
        for forbidden in ["pending_validation", "not_run_yet", "TODO", "TBD"] {
            assert!(
                !evidence.contains(forbidden),
                "closed SARR evidence contains stale marker {forbidden}"
            );
        }
    }
}

#[test]
fn local_and_github_closeout_target_lists_remain_in_parity() {
    let quality = read_repo_file("scripts/tron.d/quality.sh");
    let ci = read_repo_file(".github/workflows/ci.yml");
    let local_targets = closeout_targets_from_quality(&quality);
    let github_targets = closeout_targets_from_ci(&ci);

    assert!(
        local_targets.contains(TARGET_NAME),
        "local closeout list missing SARR"
    );
    assert!(
        github_targets.contains(TARGET_NAME),
        "GitHub static gates missing SARR"
    );
    assert_eq!(
        local_targets, github_targets,
        "local and GitHub closeout target lists must match exactly"
    );
}

#[test]
fn predecessor_inventories_cover_sarr_artifacts() {
    let required_paths = [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ];

    for path in [
        "packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv",
        "packages/agent/docs/primitive-code-cleanup-file-inventory.tsv",
        "packages/agent/docs/true-primitive-cleanup-retention-inventory.tsv",
        "packages/agent/docs/security-authority-capability-boundaries-inventory.tsv",
        "packages/agent/docs/documentation-evidence-scorecard-integrity-inventory.tsv",
    ] {
        let source = read_repo_file(path);
        for required in required_paths {
            assert!(
                source.contains(required),
                "{path} must contain predecessor inventory row for {required}"
            );
        }
    }
}

#[test]
fn active_source_rejects_off_plan_activation_and_hidden_public_leakage() {
    let tracked = git_ls_files();
    for removed in [
        "packages/agent/src/engine/primitives/worker_activation.rs",
        "packages/agent/src/engine/primitives/worker_activation_governance.rs",
        "packages/agent/src/engine/runtime/worker_schedule/mod.rs",
        "packages/agent/src/engine/runtime/worker_orchestration/mod.rs",
        "packages/agent/skills",
    ] {
        assert!(
            !repo_path(removed).exists(),
            "removed or forbidden SARR surface exists: {removed}"
        );
        assert!(
            !tracked.iter().any(|path| path.starts_with(removed)),
            "removed or forbidden SARR surface is tracked: {removed}"
        );
    }

    let mut offenders = Vec::new();
    for path in tracked {
        if !(path.starts_with("packages/agent/src/")
            || path.starts_with("packages/ios-app/Sources/")
            || path.starts_with("packages/mac-app/Sources/"))
        {
            continue;
        }
        if !(path.ends_with(".rs") || path.ends_with(".swift")) {
            continue;
        }
        let source = read_repo_file(&path);
        for forbidden in [
            "worker::issue_activation",
            "worker::launch_activation",
            "worker::launch_from_trigger",
            "stdin_activation_bundle_v1",
            "worker_schedule_plan",
            "worker_schedule_tick",
            "self_adapting_background_loop",
            "autonomous_background_mutation",
            "auto_deploy",
            "packages/agent/skills",
        ] {
            if source.contains(forbidden) {
                offenders.push(format!("{path}: {forbidden}"));
            }
        }
    }
    assert!(
        offenders.is_empty(),
        "active source contains off-plan activation or automation markers:\n{}",
        offenders.join("\n")
    );

    let wire = read_repo_file("packages/agent/src/transport/engine/socket/wire.rs");
    for forbidden in ["authority_scopes", "runtime_metadata"] {
        assert!(
            !wire.contains(forbidden),
            "public wire context must not expose {forbidden}"
        );
    }
    assert!(
        wire.contains("#[serde(rename_all = \"camelCase\", deny_unknown_fields)]"),
        "public wire context must deny unknown fields"
    );
}

#[test]
fn sarr_docs_keep_path_hygiene_and_do_not_promise_runtime_features() {
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
    ] {
        let source = read_repo_file(path);
        for forbidden in ["/Users/", ".codex/worktrees", "chat history as proof"] {
            assert!(
                !source.contains(forbidden),
                "{path} contains non-durable path/provenance marker {forbidden}"
            );
        }
    }

    let active_sarr_docs = [
        (SCORECARD_PATH, read_repo_file(SCORECARD_PATH)),
        (INVENTORY_PATH, read_repo_file(INVENTORY_PATH)),
        (INVENTORY_TSV_PATH, read_repo_file(INVENTORY_TSV_PATH)),
    ];
    for (path, source) in active_sarr_docs {
        for forbidden in [
            "SARR implements",
            "SARR adds worker autostart",
            "SARR launches generated workers",
            "public generated-worker API",
            "automatic learned-rule promotion",
            "production deploy automation",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} promises forbidden runtime feature: {forbidden}"
            );
        }
    }
}
