//! Static and source-backed invariants for the Primitive Minimality Closure
//! slice.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

const SCORECARD_PATH: &str = "packages/agent/docs/primitive-minimality-closure-scorecard.md";
const EVIDENCE_PATH: &str = "packages/agent/docs/primitive-minimality-closure-evidence-manifest.md";
const INVENTORY_PATH: &str = "packages/agent/docs/primitive-minimality-closure-inventory.md";
const INVENTORY_TSV_PATH: &str = "packages/agent/docs/primitive-minimality-closure-inventory.tsv";
const TARGET_PATH: &str = "packages/agent/tests/primitive_minimality_closure_invariants.rs";
const TARGET_NAME: &str = "primitive_minimality_closure_invariants";
const BASE_COMMIT: &str = "7b03b51f5476f5764e3813666137897af2f3cd3d";
const CLOSEOUT_COMMIT: &str = "b7443240e2b78397388b5f6b606f4ae3adaddfba";

#[derive(Debug)]
struct ScorecardRow {
    id: String,
    name: String,
    weight: u32,
    status: String,
}

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

fn git_output(args: &[&str]) -> String {
    let output = Command::new("git")
        .args(args)
        .current_dir(repo_root())
        .output()
        .unwrap_or_else(|error| panic!("git {args:?} failed to start: {error}"));
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).expect("git output should be UTF-8")
}

fn git_ls_files() -> BTreeSet<String> {
    git_output(&["ls-files"])
        .lines()
        .map(str::to_owned)
        .collect()
}

fn tracked_or_present(path: &str) -> bool {
    repo_path(path).exists() || git_ls_files().contains(path)
}

fn assert_current_lineage_base() {
    let status = Command::new("git")
        .args(["merge-base", "--is-ancestor", BASE_COMMIT, "HEAD"])
        .current_dir(repo_root())
        .status()
        .expect("git merge-base should run");
    assert!(
        status.success(),
        "HEAD must descend from SSARR baseline {BASE_COMMIT}"
    );
}

fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| PMC-"))
        .map(|line| {
            let columns: Vec<_> = line.trim_matches('|').split('|').map(str::trim).collect();
            assert_eq!(
                columns.len(),
                5,
                "PMC scorecard row must have five columns: {line}"
            );
            ScorecardRow {
                id: columns[0].to_owned(),
                name: columns[1].to_owned(),
                weight: columns[2]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid PMC weight in {line}: {error}")),
                status: columns[3].to_owned(),
            }
        })
        .collect()
}

fn parse_inventory_rows() -> Vec<Vec<String>> {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    assert_eq!(
        lines.next(),
        Some(
            "id\tpath\tsurface_kind\towner\tclosure_action\tessentiality\tproof\tregression_gate\tscorecard_rows"
        ),
        "PMC inventory TSV header changed"
    );
    lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| line.split('\t').map(str::to_owned).collect::<Vec<_>>())
        .collect()
}

fn parse_quality_closeout_targets() -> Vec<String> {
    let quality = read_repo_file("scripts/tron.d/quality.sh");
    let mut targets = Vec::new();
    let mut in_array = false;
    for line in quality.lines() {
        if line.contains("local closeout_test_targets=(") {
            in_array = true;
            continue;
        }
        if in_array {
            let trimmed = line.trim();
            if trimmed == ")" {
                break;
            }
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            targets.push(trimmed.to_owned());
        }
    }
    assert!(
        !targets.is_empty(),
        "local closeout_test_targets array not found"
    );
    targets
}

fn parse_github_static_gate_targets() -> Vec<String> {
    let ci = read_repo_file(".github/workflows/ci.yml");
    let mut targets = Vec::new();
    let mut in_block = false;
    for line in ci.lines() {
        if line.contains("Run Rust-owned closeout target set") {
            in_block = true;
            continue;
        }
        if in_block && line.trim_start().starts_with("- name:") && !targets.is_empty() {
            break;
        }
        if !in_block {
            continue;
        }
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("cargo test --test ") {
            let target = rest
                .split_whitespace()
                .next()
                .expect("cargo test target should have a name");
            targets.push(target.to_owned());
        }
    }
    assert!(
        !targets.is_empty(),
        "GitHub static-gates target block not found"
    );
    targets
}

#[test]
fn pmc_artifacts_lineage_and_readme_wiring_exist() {
    assert_current_lineage_base();

    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(repo_path(path).exists(), "missing PMC artifact: {path}");
    }

    let scorecard = read_repo_file(SCORECARD_PATH);
    for required in [
        "Status: **complete**",
        "Current score: **100/100**",
        "Passing threshold: **100/100**",
        "Total weight: **100**",
        "codex/primitive-minimality-closure-current",
        BASE_COMMIT,
        "Scope quarantine",
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
            "README must mention PMC artifact or target: {required}"
        );
    }
}

#[test]
fn pmc_scorecard_weights_sum_to_100_and_are_closed() {
    let rows = parse_scorecard_rows();
    let expected = BTreeMap::from([
        ("PMC-0", ("Baseline lineage and regression contract", 5_u32)),
        ("PMC-1", ("Dead Anthropic request-helper removal", 12)),
        ("PMC-2", ("Anthropic converter facade collapse", 10)),
        ("PMC-3", ("Google stream-state residue removal", 10)),
        ("PMC-4", ("Shared SSE parse helper collapse", 8)),
        ("PMC-5", ("Runtime suspicious-surface retention audit", 12)),
        (
            "PMC-6",
            ("Proof-layer and predecessor inventory parity", 12),
        ),
        (
            "PMC-7",
            ("README and progressive-doc current-truth sync", 8),
        ),
        ("PMC-8", ("Focused teardown validation", 8)),
        ("PMC-9", ("Broad final closeout and clean handoff", 15)),
    ]);
    assert_eq!(rows.len(), expected.len(), "PMC must contain rows 0..9");
    let mut total = 0_u32;
    for row in &rows {
        let (name, weight) = expected
            .get(row.id.as_str())
            .unwrap_or_else(|| panic!("unexpected PMC row {}", row.id));
        assert_eq!(&row.name, name);
        assert_eq!(row.weight, *weight);
        assert_eq!(row.status, "passed", "{} must be closed", row.id);
        total += row.weight;
    }
    assert_eq!(total, 100, "PMC scorecard weights must sum to 100");
}

#[test]
fn pmc_inventory_is_structured_and_covers_removed_and_retained_surfaces() {
    let rows = parse_inventory_rows();
    assert!(
        rows.len() >= 24,
        "PMC inventory row count regressed: {}",
        rows.len()
    );

    let allowed_actions = BTreeSet::from([
        "removed",
        "collapsed",
        "retained_contract",
        "historical_evidence",
        "static_gate",
        "baseline",
    ]);
    let mut ids = BTreeSet::new();
    let mut actions = BTreeSet::new();
    let mut covered_rows = BTreeSet::new();
    let mut by_path = BTreeMap::new();

    for row in &rows {
        assert_eq!(row.len(), 9, "PMC row must have 9 fields: {row:?}");
        assert!(ids.insert(row[0].clone()), "duplicate PMC id {}", row[0]);
        assert!(row[0].starts_with("PMC-INV-"));
        assert!(
            allowed_actions.contains(row[4].as_str()),
            "{} has unknown closure action {}",
            row[0],
            row[4]
        );
        assert!(
            tracked_or_present(&row[1]) || row[1] == BASE_COMMIT,
            "PMC inventory path must be tracked/present or baseline commit: {}",
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
                    && !lower.contains("recorded later")
                    && !lower.contains("to be recorded")
                    && !lower.contains("will be recorded"),
                "invalid PMC inventory field in row {:?}",
                row
            );
        }
        actions.insert(row[4].clone());
        by_path.insert(row[1].clone(), row.clone());
        for id in row[8].split(',') {
            covered_rows.insert(id.to_owned());
        }
    }

    for action in allowed_actions {
        assert!(actions.contains(action), "missing PMC action {action}");
    }
    for row_id in 0..=9 {
        assert!(
            covered_rows.contains(&format!("PMC-{row_id}")),
            "PMC inventory does not cover PMC-{row_id}"
        );
    }
    for required_path in [
        BASE_COMMIT,
        "packages/agent/src/domains/model/providers/anthropic/types/mod.rs",
        "packages/agent/src/domains/model/providers/anthropic/message_converter/mod.rs",
        "packages/agent/src/domains/model/providers/anthropic/provider/mod.rs",
        "packages/agent/src/domains/model/providers/google/stream_handler.rs",
        "packages/agent/src/domains/model/providers/shared/sse.rs",
        "packages/agent/src/domains/model/providers/shared/stream_pipeline.rs",
        "packages/agent/src/engine/authority/leases.rs",
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
        "scripts/tron.d/quality.sh",
        ".github/workflows/ci.yml",
        "README.md",
    ] {
        assert!(
            by_path.contains_key(required_path),
            "PMC inventory missing required path {required_path}"
        );
    }

    let inventory = read_repo_file(INVENTORY_PATH);
    for required in [
        "Removed Runtime Residue",
        "Retained Contracts",
        "Closeout Policy",
        "`removed`",
        "`collapsed`",
        "`retained_contract`",
        "`historical_evidence`",
        "`static_gate`",
        "`baseline`",
    ] {
        assert!(inventory.contains(required), "inventory missing {required}");
    }
}

#[test]
fn deleted_runtime_residue_remains_absent_and_replacements_remain_owned() {
    let anthropic_types =
        read_repo_file("packages/agent/src/domains/model/providers/anthropic/types/mod.rs");
    for removed in [
        "pub fn text_cached",
        "pub fn text_block",
        "pub fn image_block",
        "pub fn document_block",
        "pub fn thinking_block",
        "pub fn tool_use_block",
        "pub fn tool_result_block",
    ] {
        assert!(
            !anthropic_types.contains(removed),
            "Anthropic types reintroduced deleted helper: {removed}"
        );
    }

    let anthropic_converter = read_repo_file(
        "packages/agent/src/domains/model/providers/anthropic/message_converter/mod.rs",
    );
    for removed in [
        "pub fn convert_context",
        "fn convert_tools(",
        "ModelCapability definitions with cache control",
    ] {
        assert!(
            !anthropic_converter.contains(removed),
            "Anthropic converter reintroduced deleted facade/helper: {removed}"
        );
    }

    let anthropic_provider =
        read_repo_file("packages/agent/src/domains/model/providers/anthropic/provider/mod.rs");
    for required in [
        "fn build_tools(&self, context: &Context) -> Option<Vec<AnthropicTool>>",
        "last.cache_control = Some(CacheControl",
        r#"ttl: Some("1h".into())"#,
    ] {
        assert!(
            anthropic_provider.contains(required),
            "Anthropic provider must retain canonical tool owner: {required}"
        );
    }

    let google_stream =
        read_repo_file("packages/agent/src/domains/model/providers/google/stream_handler.rs");
    for removed in ["completed_tool_ids", "synthesize_done_event"] {
        assert!(
            !google_stream.contains(removed),
            "Google stream handler reintroduced deleted residue: {removed}"
        );
    }
    for required in ["fn handle_finish(", "process_stream_chunk"] {
        assert!(
            google_stream.contains(required),
            "Google stream handler must retain canonical finish/chunk owner: {required}"
        );
    }

    let shared_sse = read_repo_file("packages/agent/src/domains/model/providers/shared/sse.rs");
    assert!(
        !shared_sse.contains("parse_sse_data"),
        "shared SSE parser reintroduced deleted parse wrapper"
    );

    let stream_pipeline =
        read_repo_file("packages/agent/src/domains/model/providers/shared/stream_pipeline.rs");
    for required in [
        "parse_sse_lines(byte_stream, options)",
        "serde_json::from_str(&line)",
        "Failed to parse SSE event",
    ] {
        assert!(
            stream_pipeline.contains(required),
            "stream pipeline must retain direct parse owner: {required}"
        );
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
        "PMC target must be in the closeout set"
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
    let ssarr_index = local_targets
        .iter()
        .position(|target| target == "self_sufficient_agent_runtime_readiness_invariants")
        .expect("SSARR target should be present");
    let pmc_index = local_targets
        .iter()
        .position(|target| target == TARGET_NAME)
        .expect("PMC target should be present");
    let primitive_trace_index = local_targets
        .iter()
        .position(|target| target == "primitive_trace_execution")
        .expect("primitive trace target should be present");
    assert!(
        ssarr_index < pmc_index && pmc_index < primitive_trace_index,
        "PMC must run after SSARR and before primitive trace/integration closeout targets"
    );
}

#[test]
fn evidence_manifest_records_required_commands_without_placeholders() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    for row_id in 0..=9 {
        assert!(
            evidence.contains(&format!("PMC-{row_id}")),
            "PMC evidence manifest must cover PMC-{row_id}"
        );
    }
    for command in [
        "scripts/tron ci fmt check clippy test",
        "scripts/personal-info-guard.sh",
        "cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj",
        "cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check",
        "cargo test --manifest-path packages/agent/Cargo.toml domains::model::providers::anthropic --lib -- --quiet",
        "cargo test --manifest-path packages/agent/Cargo.toml domains::model::providers::google::stream_handler --lib -- --quiet",
        "cargo test --manifest-path packages/agent/Cargo.toml domains::model::providers::shared::sse --lib -- --quiet",
        "cargo check --manifest-path packages/agent/Cargo.toml",
        "cargo test --manifest-path packages/agent/Cargo.toml --test primitive_minimality_closure_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test self_sufficient_agent_runtime_readiness_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test documentation_evidence_scorecard_integrity_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test developer_experience_repo_hygiene_automation_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test concurrency_scheduling_discipline_invariants -- --nocapture",
        "git diff --check",
        "git ls-files -ci --exclude-standard",
        "git status --short",
    ] {
        assert!(
            evidence.contains(command),
            "PMC evidence manifest missing command: {command}"
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
            "PMC evidence must not contain placeholder language: {forbidden}"
        );
    }
    for required in [
        "Failed Attempts And Fixes",
        "Retained Suspicious Surfaces",
        "iOS No-Touch Rationale",
        "Residual Risk",
    ] {
        assert!(evidence.contains(required), "evidence missing {required}");
    }
}

#[test]
fn predecessor_inventories_classify_pmc_artifacts() {
    let required_paths = [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ];
    for predecessor in [
        "packages/agent/docs/primitive-code-cleanup-file-inventory.tsv",
        "packages/agent/docs/true-primitive-cleanup-retention-inventory.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv",
        "packages/agent/docs/release-install-upgrade-rollback-discipline-inventory.tsv",
        "packages/agent/docs/ios-thin-client-generic-runtime-shell-inventory.tsv",
        "packages/agent/docs/configuration-profile-environment-discipline-inventory.tsv",
        "packages/agent/docs/performance-resource-governance-inventory.tsv",
        "packages/agent/docs/provider-model-boundary-discipline-inventory.tsv",
        "packages/agent/docs/public-protocol-api-contract-discipline-inventory.tsv",
        "packages/agent/docs/data-integrity-storage-evolution-migration-discipline-inventory.tsv",
        "packages/agent/docs/observability-diagnostics-auditability-inventory.tsv",
        "packages/agent/docs/security-authority-capability-boundaries-inventory.tsv",
        "packages/agent/docs/concurrency-scheduling-discipline-inventory.tsv",
        "packages/agent/docs/state-ownership-lifecycle-inventory.tsv",
        "packages/agent/docs/off-plan-saa-authorship-teardown-cleanup-inventory.tsv",
        "packages/agent/docs/developer-experience-repo-hygiene-automation-inventory.tsv",
        "packages/agent/docs/documentation-evidence-scorecard-integrity-inventory.tsv",
        "packages/agent/docs/self-sufficient-agent-runtime-readiness-inventory.tsv",
    ] {
        let source = read_repo_file(predecessor);
        for required_path in required_paths {
            assert!(
                source.contains(required_path),
                "{predecessor} missing PMC artifact {required_path}"
            );
        }
    }
}

#[test]
fn closure_does_not_expand_public_or_ios_behavior_surfaces() {
    let changed = git_output(&["diff", "--name-only", BASE_COMMIT, CLOSEOUT_COMMIT]);
    for path in changed.lines() {
        assert!(
            !path.starts_with("packages/ios-app/Sources/"),
            "PMC must not change iOS source behavior: {path}"
        );
        assert!(
            !path.starts_with("packages/agent/src/transport/engine/contracts.rs")
                && !path.starts_with("packages/agent/src/domains/settings/profile/types/")
                && !path.starts_with("packages/agent/src/domains/auth/credentials/")
                && !path.starts_with(
                    "packages/agent/src/domains/session/event_store/sqlite/migrations/"
                ),
            "PMC must not expand public protocol/settings/auth/DB surfaces: {path}"
        );
    }

    for path in ["scripts/tron.d/quality.sh", ".github/workflows/ci.yml"] {
        let source = read_repo_file(path);
        assert!(
            !source.contains("tron deploy")
                && !source.contains("auto-deploy")
                && !source.contains("cmd_auto_deploy"),
            "{path} must not add deploy automation"
        );
    }
}
