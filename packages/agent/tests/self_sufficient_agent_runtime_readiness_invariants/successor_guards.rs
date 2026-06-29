use super::*;
use std::collections::BTreeMap;

fn has_successor_term(source: &str) -> bool {
    let lower = source.to_ascii_lowercase();
    [
        "self-adapting",
        "generated worker",
        "generated-worker",
        "learned rules",
        "learned rule",
        "learned memory",
        "tool synthesis",
        "agent-authored",
        "self-sufficient",
        "worker schedule",
        "worker activation",
        "self_sufficient",
        "self_adapting",
        "tool_synthesis",
        "learned_memory",
    ]
    .iter()
    .any(|term| lower.contains(term))
        || contains_standalone_saa(source)
}

fn contains_standalone_saa(source: &str) -> bool {
    source.match_indices("SAA").any(|(index, _)| {
        let before = source[..index].chars().next_back();
        let after = source[index + "SAA".len()..].chars().next();
        before.is_none_or(|ch| !ch.is_ascii_alphanumeric())
            && after.is_none_or(|ch| !ch.is_ascii_alphanumeric())
    })
}

fn classified_successor_term_path(path: &str, source: &str) -> bool {
    path.starts_with("packages/agent/docs/self-sufficient-agent-runtime-readiness-")
        || path == TARGET_PATH
        || path == "README.md"
        || path == "AGENTS.md"
        || path == "packages/ios-app/docs/architecture.md"
        || path == "packages/agent/src/shared/protocol/messages/mod.rs"
        || path == "packages/agent/src/domains/agent/context/types.rs"
        || path == "packages/agent/src/domains/capability/mod.rs"
        || path.starts_with("packages/agent/docs/off-plan-saa-authorship-teardown-cleanup-")
        || path.starts_with("packages/agent/docs/primitive-engine-teardown-")
        || path.starts_with("packages/agent/docs/ios-thin-client-generic-runtime-shell-")
        || path.starts_with("packages/agent/docs/ios-self-adapting-agent-cockpit-baseline-")
        || path.starts_with("packages/agent/docs/ios-affordance-restoration-map-")
        || path == "packages/agent/docs/ios-affordance-restoration-progress.md"
        || path.starts_with("packages/agent/docs/phase-2-agent-execution-restoration-")
        || path == "packages/agent/docs/restoration-retrospective-audit-status.md"
        || path == "packages/agent/tests/ios_affordance_restoration_map_invariants.rs"
        || path == "packages/agent/tests/ios_self_adapting_agent_cockpit_baseline_invariants.rs"
        || path
            == "packages/agent/docs/primitive-baseline-vs-modular-capability-engine-feature-index.md"
        || path.starts_with("packages/agent/docs/baseline-pre-restoration-closure-")
        || path == "packages/agent/docs/self-updating-worker-runtime-foundation-inventory.tsv"
        || path == "packages/agent/tests/baseline_pre_restoration_closure_invariants.rs"
        || path == "packages/agent/docs/primitive-code-cleanup-scorecard.md"
        || path == "packages/agent/docs/provider-model-boundary-discipline-scorecard.md"
        || path == "packages/agent/docs/public-protocol-api-contract-discipline-scorecard.md"
        || path
            == "packages/agent/docs/data-integrity-storage-evolution-migration-discipline-scorecard.md"
        || path == "packages/agent/docs/release-install-upgrade-rollback-discipline-scorecard.md"
        || path == "packages/agent/tests/primitive_engine_teardown/scorecard_inventory.rs"
        || path == "packages/agent/tests/primitive_code_cleanup/budgets_generated_dependencies.rs"
        || path == "packages/agent/tests/self_updating_worker_runtime_foundation_invariants.rs"
        || source.contains("off-plan-saa-authorship-teardown-cleanup")
        || source.contains("self-sufficient-agent-runtime-readiness")
        || source.contains("self_sufficient_agent_runtime_readiness")
}

#[test]
fn ssarr_artifacts_lineage_branch_and_readme_wiring_exist() {
    assert_current_lineage_base();
    assert_eq!(
        git_output(&["rev-parse", STALE_BRANCH]).trim(),
        STALE_BRANCH_HEAD
    );

    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(repo_path(path).exists(), "missing SSARR artifact: {path}");
    }

    let scorecard = read_repo_file(SCORECARD_PATH);
    for required in [
        "Status: **complete**",
        "Current score: **100/100**",
        "Passing threshold: **100/100**",
        "Total weight: **100**",
        "codex/self-sufficient-agent-runtime-readiness-current",
        BASE_COMMIT,
        STALE_BRANCH,
        STALE_BRANCH_HEAD,
        "quarry-only",
        "readiness audit only",
    ] {
        assert!(scorecard.contains(required), "scorecard missing {required}");
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
            "README must mention SSARR artifact or target: {required}"
        );
    }
}

#[test]
fn ssarr_scorecard_weights_sum_to_100_and_are_closed() {
    let rows = parse_scorecard_rows();
    let expected = BTreeMap::from([
        (
            "SSARR-0",
            ("Baseline, lineage, and scope quarantine", 5_u32),
        ),
        (
            "SSARR-1",
            ("Extension-point inventory and ownership map", 10),
        ),
        (
            "SSARR-2",
            ("Generated-worker readiness without implementation", 10),
        ),
        (
            "SSARR-3",
            (
                "Learned rules/memory readiness without repo-managed memory/skills",
                10,
            ),
        ),
        (
            "SSARR-4",
            ("Tool synthesis and capability boundary readiness", 10),
        ),
        (
            "SSARR-5",
            ("Agent-authored state custody and migration readiness", 10),
        ),
        (
            "SSARR-6",
            (
                "Runtime orchestration, error, and auditability preconditions",
                8,
            ),
        ),
        (
            "SSARR-7",
            ("Public protocol and iOS generic-shell readiness", 8),
        ),
        (
            "SSARR-8",
            (
                "Negative guards against accidental successor feature reintroduction and stale cruft",
                10,
            ),
        ),
        (
            "SSARR-9",
            (
                "Static-gate/local-GitHub/README/evidence parity and handoff",
                9,
            ),
        ),
        ("SSARR-10", ("Broad verification and final closeout", 10)),
    ]);
    assert_eq!(rows.len(), expected.len(), "SSARR must contain rows 0..10");
    let mut total = 0_u32;
    for row in &rows {
        let (name, weight) = expected
            .get(row.id.as_str())
            .unwrap_or_else(|| panic!("unexpected SSARR row {}", row.id));
        assert_eq!(&row.name, name);
        assert_eq!(row.weight, *weight);
        assert_eq!(row.status, "passed", "{} must be closed", row.id);
        total += row.weight;
    }
    assert_eq!(total, 100, "SSARR scorecard weights must sum to 100");
}

#[test]
fn ssarr_inventory_is_structured_and_covers_required_dimensions() {
    let rows = parse_inventory_rows();
    assert!(
        rows.len() >= 40,
        "SSARR inventory row count regressed: {}",
        rows.len()
    );

    let allowed_dimensions = BTreeSet::from([
        "generated_workers",
        "learned_rules_memory",
        "tool_synthesis",
        "agent_authored_state",
        "runtime_orchestration_auditability",
        "public_protocol_ios_shell",
        "static_gates_docs",
        "historical_quarry_classification",
    ]);
    let allowed_states = BTreeSet::from([
        "ready_extension_point",
        "future_prerequisite",
        "historical_evidence",
        "forbidden_successor_feature",
        "static_gate",
    ]);
    let mut ids = BTreeSet::new();
    let mut dimensions = BTreeSet::new();
    let mut states = BTreeSet::new();
    let mut covered_rows = BTreeSet::new();
    let mut by_path = BTreeMap::new();

    for row in &rows {
        assert_eq!(row.len(), 12, "SSARR row must have 12 fields: {row:?}");
        assert!(ids.insert(row[0].clone()), "duplicate SSARR id {}", row[0]);
        assert!(row[0].starts_with("SSARR-INV-"));
        assert!(
            allowed_dimensions.contains(row[4].as_str()),
            "{} has unknown readiness dimension {}",
            row[0],
            row[4]
        );
        assert!(
            allowed_states.contains(row[7].as_str()),
            "{} has unknown implementation state {}",
            row[0],
            row[7]
        );
        assert!(
            tracked_or_present(&row[1])
                || row[1].starts_with("codex/")
                || row[7] == "forbidden_successor_feature",
            "SSARR inventory path must be tracked/present, branch evidence, or forbidden absent path: {}",
            row[1]
        );
        for field in row {
            let lower = field.to_ascii_lowercase();
            assert!(
                !field.trim().is_empty()
                    && !field.contains("TODO")
                    && !field.contains("TBD")
                    && !lower.contains("pending")
                    && !lower.contains("unclassified")
                    && !lower.contains("current_gap")
                    && !lower.contains("recorded later")
                    && !lower.contains("to be recorded")
                    && !lower.contains("will be recorded"),
                "invalid SSARR inventory field in row {:?}",
                row
            );
        }
        dimensions.insert(row[4].clone());
        states.insert(row[7].clone());
        by_path.insert(row[1].clone(), row.clone());
        for id in row[11].split(',') {
            covered_rows.insert(id.to_owned());
        }
    }

    for dimension in allowed_dimensions {
        assert!(
            dimensions.contains(dimension),
            "missing SSARR readiness dimension {dimension}"
        );
    }
    for state in allowed_states {
        assert!(
            states.contains(state),
            "missing SSARR implementation state {state}"
        );
    }
    for row_id in 0..=10 {
        assert!(
            covered_rows.contains(&format!("SSARR-{row_id}")),
            "SSARR inventory does not cover SSARR-{row_id}"
        );
    }
    for required_path in [
        "packages/agent/src/engine/mod.rs",
        "packages/agent/src/engine/runtime/external_workers/mod.rs",
        "packages/agent/src/engine/durability/queue/mod.rs",
        "packages/agent/src/domains/capability/contract.rs",
        "packages/agent/src/domains/capability/operations/state.rs",
        "packages/agent/src/engine/durability/resources/mod.rs",
        "packages/agent/src/transport/engine/contracts.rs",
        "packages/ios-app/Sources/UI/RuntimeSurfaces/GeneratedRuntimeSurfaceView.swift",
        "packages/agent/skills",
        STALE_BRANCH,
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(
            by_path.contains_key(required_path),
            "SSARR inventory missing required path {required_path}"
        );
    }

    let inventory = read_repo_file(INVENTORY_PATH);
    for required in [
        "Generated workers",
        "Learned rules/memory",
        "Tool synthesis",
        "Agent-authored state",
        "No-implementation decision",
        "ready_extension_point",
        "future_prerequisite",
        "historical_evidence",
        "forbidden_successor_feature",
        "static_gate",
    ] {
        assert!(inventory.contains(required), "inventory missing {required}");
    }
}

#[test]
fn static_gate_wiring_matches_local_and_github_closeout_order() {
    let local_targets = parse_quality_closeout_targets();
    let github_targets = parse_github_static_gate_targets();
    assert_eq!(
        local_targets, github_targets,
        "scripts/tron ci test and GitHub rust-static-gates must run the same closeout target set in the same order"
    );
    assert!(
        local_targets.contains(&TARGET_NAME.to_owned()),
        "SSARR target must be in the closeout set"
    );
    let unique: BTreeSet<_> = local_targets.iter().collect();
    assert_eq!(
        unique.len(),
        local_targets.len(),
        "closeout target set must not contain duplicates"
    );
    assert_eq!(
        local_targets.last().map(String::as_str),
        Some("integration"),
        "serial integration target must remain last"
    );
    let desi_index = local_targets
        .iter()
        .position(|target| target == "documentation_evidence_scorecard_integrity_invariants")
        .expect("DESI target should be present");
    let ssarr_index = local_targets
        .iter()
        .position(|target| target == TARGET_NAME)
        .expect("SSARR target should be present");
    let primitive_trace_index = local_targets
        .iter()
        .position(|target| target == "primitive_trace_execution")
        .expect("primitive trace target should be present");
    assert!(
        desi_index < ssarr_index && ssarr_index < primitive_trace_index,
        "SSARR must run after DESI and before primitive trace/integration closeout targets"
    );
}

#[test]
fn evidence_manifest_records_required_commands_without_placeholders() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    for row_id in 0..=10 {
        assert!(
            evidence.contains(&format!("SSARR-{row_id}")),
            "SSARR evidence manifest must cover SSARR-{row_id}"
        );
    }
    for command in [
        "cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check",
        "cargo check --manifest-path packages/agent/Cargo.toml",
        "cargo test --manifest-path packages/agent/Cargo.toml --test self_sufficient_agent_runtime_readiness_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test developer_experience_repo_hygiene_automation_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_saa_authorship_teardown_cleanup_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test ios_thin_client_generic_runtime_shell_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test release_install_upgrade_rollback_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test configuration_profile_environment_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test performance_resource_governance_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test provider_model_boundary_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test data_integrity_storage_evolution_migration_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --nocapture",
        "scripts/tron ci fmt check clippy test",
        "scripts/personal-info-guard.sh",
        "cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj",
        "git diff --check",
        "git ls-files -ci --exclude-standard",
        "git status --short",
    ] {
        assert!(
            evidence.contains(command),
            "SSARR evidence manifest missing command: {command}"
        );
    }
    for forbidden in [
        "TODO",
        "TBD",
        "placeholder",
        "pending",
        "current_gap",
        "recorded later",
        "to be recorded",
        "will be recorded",
        "not run",
    ] {
        assert!(
            !evidence.contains(forbidden),
            "SSARR evidence must not contain placeholder language: {forbidden}"
        );
    }
}

#[test]
fn successor_terms_are_classified_and_do_not_claim_implementation() {
    let mut unclassified = Vec::new();
    for path in active_text_files() {
        let source = read_repo_file(&path);
        if has_successor_term(&source) && !classified_successor_term_path(&path, &source) {
            unclassified.push(path.clone());
        }
        if matches!(
            path.as_str(),
            TARGET_PATH
                | "packages/agent/tests/off_plan_saa_authorship_teardown_cleanup_invariants.rs"
        ) {
            continue;
        }
        for forbidden in forbidden_successor_completion_claims() {
            assert!(
                !source.to_ascii_lowercase().contains(&forbidden),
                "{path} contains stale successor implementation claim: {forbidden}"
            );
        }
    }
    assert!(
        unclassified.is_empty(),
        "successor-term paths must be classified by SSARR: {unclassified:#?}"
    );
}

fn forbidden_successor_completion_claims() -> Vec<String> {
    [
        ("generated worker execution", " is implemented"),
        ("generated-worker systems", " are implemented"),
        ("generated workers", " are complete"),
        ("worker schedule dispatch", " is implemented"),
        ("worker schedule scanning", " is complete"),
        ("worker activation", " is implemented"),
        ("worker activation", " is complete"),
        ("learned memory", " is implemented"),
        ("learned rules", " are implemented"),
        ("tool synthesis runtime", " is implemented"),
        ("self-sufficient agent runtime", " is implemented"),
        ("self-adapting agent", " is implemented"),
        ("public promotion API", " for tool synthesis"),
        ("client-side catalog edit API", " for synthesized tools"),
    ]
    .into_iter()
    .map(|(prefix, suffix)| format!("{prefix}{suffix}"))
    .collect()
}

#[test]
fn forbidden_successor_runtime_surfaces_remain_absent() {
    let tracked = git_ls_files();
    assert!(
        !repo_path("packages/agent/skills").exists()
            && !tracked
                .iter()
                .any(|path| path.starts_with("packages/agent/skills/")),
        "repo-managed first-party skills must remain absent"
    );

    for path in tracked.iter().filter(|path| {
        path.starts_with("packages/agent/src/")
            || path.starts_with("packages/ios-app/Sources/")
            || path.starts_with("packages/mac-app/Sources/")
            || path.starts_with("scripts/")
    }) {
        let Some(source) = read_repo_file_if_utf8(path) else {
            continue;
        };
        for forbidden in [
            "agent_memory",
            "agent_rule",
            "self_adapting_resource_kinds",
            "GeneratedWorkerRuntime",
            "generated_worker_runtime",
            "WorkerSchedule",
            "worker_schedule",
            "WorkerActivation",
            "worker_activation",
            "ToolSynthesis",
            "tool_synthesis",
            "synthesize_tool",
            "GeneratedCapabilityLifecycle",
            "generated_capability_lifecycle",
            "LearnedMemoryStore",
            "learned_memory_store",
            "SelfAdaptingAgentPanel",
            "SelfSufficientAgentPanel",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} reintroduced forbidden successor runtime surface: {forbidden}"
            );
        }
    }

    let capability_contract = read_repo_file("packages/agent/src/domains/capability/contract.rs");
    assert!(
        capability_contract.contains(r#"schema["properties"].get("target").is_none()"#),
        "capability contract must keep a source-backed guard that execute exposes no target field"
    );
    for absent_field_guard in [
        r#"schema["properties"].get("contractId").is_none()"#,
        r#"schema["properties"].get("functionId").is_none()"#,
        r#"schema["properties"].get("constraints").is_none()"#,
    ] {
        assert!(
            capability_contract.contains(absent_field_guard),
            "capability contract must keep source-backed guard {absent_field_guard}"
        );
    }
    for forbidden_field in ["resource_create", "resource_update", "resource_link"] {
        assert!(
            !capability_contract.contains(forbidden_field),
            "model-facing execute schema must not expose successor/tool-synthesis field {forbidden_field}"
        );
    }

    let readme = read_repo_file("README.md");
    assert!(
        readme.contains("Public `promote` is a user-owned `engine::promote` path, not a client-side catalog edit"),
        "README must distinguish public promote from tool synthesis/catalog authoring"
    );
}
