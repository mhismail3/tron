//! Static invariants for the iOS Affordance Restoration Map.
//! This target verifies exhaustive old-tree coverage without restoring any
//! Swift UI feature or backend capability.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

const SCORECARD_PATH: &str = "packages/agent/docs/ios-affordance-restoration-map-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/ios-affordance-restoration-map-evidence-manifest.md";
const INVENTORY_PATH: &str = "packages/agent/docs/ios-affordance-restoration-map-inventory.md";
const INVENTORY_TSV_PATH: &str = "packages/agent/docs/ios-affordance-restoration-map-inventory.tsv";
const PROGRESS_PATH: &str = "packages/agent/docs/ios-affordance-restoration-progress.md";
const TARGET_PATH: &str = "packages/agent/tests/ios_affordance_restoration_map_invariants.rs";
const TARGET_NAME: &str = "ios_affordance_restoration_map_invariants";
const OLD_REFERENCE: &str = "ad5e484722c6f7abbe764126409494026216ad92";
const BASELINE_COMMIT: &str = "a0b80c7d204cf9349a5f647ecbc58a8a37735e15";

#[derive(Debug)]
struct ScorecardRow {
    id: String,
    name: String,
    weight: u32,
    status: String,
}

#[derive(Debug)]
struct InventoryRow {
    id: String,
    old_path_patterns: Vec<String>,
    feature_family: String,
    classification: String,
    current_replacement: String,
    user_value_hypothesis: String,
    modern_interpretation: String,
    data_authority_owner: String,
    functional_without_agent_backend: String,
    future_slice_order: String,
    evidence_source: String,
    validation_requirement: String,
    phase2_bucket_refs: String,
    scorecard_rows: String,
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

fn tracked_text_under(paths: &[&str]) -> String {
    let mut args = vec!["ls-files"];
    args.extend(paths);
    git_output(&args)
        .lines()
        .filter(|path| path.ends_with(".swift"))
        .filter(|path| repo_path(path).exists())
        .map(|path| format!("\n// FILE: {path}\n{}", read_repo_file(path)))
        .collect::<Vec<_>>()
        .join("\n")
}

fn assert_contains_all(path: &str, required: &[&str]) {
    let content = read_repo_file(path);
    for needle in required {
        assert!(
            content.contains(needle),
            "{path} missing required text: {needle}"
        );
    }
}

fn assert_current_lineage_base() {
    let status = Command::new("git")
        .args(["merge-base", "--is-ancestor", BASELINE_COMMIT, "HEAD"])
        .current_dir(repo_root())
        .status()
        .expect("git merge-base should run");
    assert!(
        status.success(),
        "HEAD must descend from IARM baseline {BASELINE_COMMIT}"
    );
}

fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| IARM-"))
        .map(|line| {
            let columns: Vec<_> = line.trim_matches('|').split('|').map(str::trim).collect();
            assert_eq!(
                columns.len(),
                5,
                "IARM scorecard row must have five columns: {line}"
            );
            ScorecardRow {
                id: columns[0].to_owned(),
                name: columns[1].to_owned(),
                weight: columns[2]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid IARM weight in {line}: {error}")),
                status: columns[3].to_owned(),
            }
        })
        .collect()
}

fn parse_inventory_rows() -> Vec<InventoryRow> {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    assert_eq!(
        lines.next(),
        Some(
            "id\told_path_patterns\tfeature_family\tclassification\tcurrent_replacement\tuser_value_hypothesis\tmodern_interpretation\tdata_authority_owner\tfunctional_without_agent_backend\tfuture_slice_order\tevidence_source\tvalidation_requirement\tphase2_bucket_refs\tscorecard_rows"
        ),
        "IARM inventory TSV header changed"
    );
    lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let columns = line.split('\t').map(str::to_owned).collect::<Vec<_>>();
            assert_eq!(
                columns.len(),
                14,
                "inventory row must have 14 columns: {line}"
            );
            InventoryRow {
                id: columns[0].clone(),
                old_path_patterns: columns[1]
                    .split(';')
                    .map(str::trim)
                    .filter(|pattern| !pattern.is_empty())
                    .map(str::to_owned)
                    .collect(),
                feature_family: columns[2].clone(),
                classification: columns[3].clone(),
                current_replacement: columns[4].clone(),
                user_value_hypothesis: columns[5].clone(),
                modern_interpretation: columns[6].clone(),
                data_authority_owner: columns[7].clone(),
                functional_without_agent_backend: columns[8].clone(),
                future_slice_order: columns[9].clone(),
                evidence_source: columns[10].clone(),
                validation_requirement: columns[11].clone(),
                phase2_bucket_refs: columns[12].clone(),
                scorecard_rows: columns[13].clone(),
            }
        })
        .collect()
}

fn old_deleted_or_renamed_ios_paths() -> Vec<String> {
    git_output(&[
        "diff",
        "--name-status",
        &format!("{OLD_REFERENCE}..HEAD"),
        "--",
        "packages/ios-app",
    ])
    .lines()
    .filter_map(|line| {
        let columns = line.split('\t').collect::<Vec<_>>();
        match columns.as_slice() {
            ["D", path] => Some((*path).to_owned()),
            [status, old_path, _new_path] if status.starts_with('R') => {
                Some((*old_path).to_owned())
            }
            _ => None,
        }
    })
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
fn artifacts_lineage_and_docs_wiring_exist() {
    assert_current_lineage_base();
    git_output(&["cat-file", "-e", &format!("{OLD_REFERENCE}^{{commit}}")]);

    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        PROGRESS_PATH,
        TARGET_PATH,
    ] {
        assert!(repo_path(path).exists(), "missing IARM artifact: {path}");
    }

    assert_contains_all(
        SCORECARD_PATH,
        &[
            "Status: **complete**",
            "Current score: **100/100**",
            "Passing threshold: **100/100**",
            "Total weight: **100**",
            "codex/ios-affordance-restoration-map-current",
            OLD_REFERENCE,
            BASELINE_COMMIT,
            "Scope quarantine",
        ],
    );

    let readme = read_repo_file("README.md");
    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
        TARGET_NAME,
        "iOS Affordance Restoration Map",
        "Phase 2 agent-execution restoration plan",
    ] {
        assert!(
            readme.contains(required),
            "README must mention IARM artifact, target, or phase anchor: {required}"
        );
    }

    assert_contains_all(
        "packages/ios-app/docs/architecture.md",
        &[
            "iOS Affordance Restoration Map",
            "functional-only",
            "does not restore deleted product panels",
            "Notification and inbox affordances remain deferred",
            "server-owned APNs/device/capability resource",
            "Phase 2 agent-execution restoration plan",
        ],
    );
}

#[test]
fn scorecard_weights_sum_to_100_and_are_closed() {
    let rows = parse_scorecard_rows();
    let expected = BTreeMap::from([
        ("IARM-0", ("Baseline and scope", 5_u32)),
        ("IARM-1", ("Exhaustive old-tree census", 15)),
        ("IARM-2", ("Current surface match", 10)),
        ("IARM-3", ("Affordance taxonomy", 10)),
        ("IARM-4", ("Phase 1 review queue", 15)),
        ("IARM-5", ("Phase 2 deferral map", 10)),
        ("IARM-6", ("First-principles UX rubric", 10)),
        ("IARM-7", ("Static gate", 10)),
        ("IARM-8", ("Docs and README integration", 7)),
        ("IARM-9", ("Validation and handoff", 8)),
    ]);
    assert_eq!(rows.len(), expected.len(), "IARM must contain rows 0..9");
    let mut total = 0_u32;
    for row in &rows {
        let (name, weight) = expected
            .get(row.id.as_str())
            .unwrap_or_else(|| panic!("unexpected IARM row {}", row.id));
        assert_eq!(&row.name, name);
        assert_eq!(row.weight, *weight);
        assert_eq!(row.status, "passed", "{} must be closed", row.id);
        total += row.weight;
    }
    assert_eq!(total, 100, "IARM weights must sum to 100");
}

#[test]
fn inventory_uses_controlled_vocabulary_and_review_queue() {
    let rows = parse_inventory_rows();
    assert!(
        rows.len() >= 30,
        "IARM inventory should group every major old iOS affordance family"
    );

    let ids = rows
        .iter()
        .map(|row| row.id.as_str())
        .collect::<BTreeSet<_>>();
    for required in [
        "IARM-SURFACE-011",
        "IARM-SURFACE-013",
        "IARM-SURFACE-016",
        "IARM-SURFACE-017",
        "IARM-SURFACE-019",
        "IARM-SURFACE-020",
        "IARM-SURFACE-021",
        "IARM-SURFACE-035",
    ] {
        assert!(ids.contains(required), "IARM inventory missing {required}");
    }

    let allowed_classifications = BTreeSet::from([
        "phase1_local_native",
        "phase1_server_fact",
        "phase1_review_only",
        "phase2_agent_execution",
        "superseded_current_shell",
        "reject_candidate",
    ]);
    let allowed_functional = BTreeSet::from(["yes", "no", "review"]);
    let allowed_orders = BTreeSet::from([
        "phase1_slice_1",
        "phase1_slice_2",
        "phase1_slice_3",
        "phase1_slice_4",
        "phase1_slice_5",
        "phase1_slice_6",
        "phase2_full_plan",
        "not_scheduled",
    ]);

    let mut classifications = BTreeSet::new();
    let mut orders = BTreeSet::new();
    for row in rows {
        assert!(
            row.id.starts_with("IARM-SURFACE-"),
            "inventory row id should be an IARM surface row: {}",
            row.id
        );
        assert!(
            allowed_classifications.contains(row.classification.as_str()),
            "unexpected classification in {:?}",
            row
        );
        assert!(
            allowed_functional.contains(row.functional_without_agent_backend.as_str()),
            "unexpected functional value in {:?}",
            row
        );
        assert!(
            allowed_orders.contains(row.future_slice_order.as_str()),
            "unexpected future slice order in {:?}",
            row
        );
        for cell in [
            row.feature_family,
            row.current_replacement,
            row.user_value_hypothesis,
            row.modern_interpretation,
            row.data_authority_owner,
            row.evidence_source,
            row.validation_requirement,
            row.phase2_bucket_refs,
            row.scorecard_rows,
        ] {
            assert!(!cell.trim().is_empty(), "inventory cells must be non-empty");
            assert!(
                !cell.contains("TODO") && !cell.contains("pending"),
                "inventory rows must not preserve open work markers: {cell}"
            );
        }
        classifications.insert(row.classification);
        orders.insert(row.future_slice_order);
    }

    for required in [
        "phase1_local_native",
        "phase1_server_fact",
        "phase1_review_only",
        "phase2_agent_execution",
        "superseded_current_shell",
    ] {
        assert!(
            classifications.contains(required),
            "inventory should use classification {required}"
        );
    }
    for required in [
        "phase1_slice_1",
        "phase1_slice_2",
        "phase1_slice_3",
        "phase1_slice_4",
        "phase1_slice_5",
        "phase1_slice_6",
        "phase2_full_plan",
    ] {
        assert!(
            orders.contains(required),
            "inventory should include {required}"
        );
    }
}

#[test]
fn inventory_patterns_cover_every_deleted_or_renamed_old_ios_path() {
    let old_paths = old_deleted_or_renamed_ios_paths();
    assert_eq!(
        old_paths.len(),
        848,
        "old iOS deleted/renamed path count changed; refresh the IARM inventory"
    );

    let rows = parse_inventory_rows();
    let mut patterns = Vec::new();
    for row in &rows {
        assert!(
            !row.old_path_patterns.is_empty(),
            "inventory row must include at least one old path pattern: {}",
            row.id
        );
        for pattern in &row.old_path_patterns {
            assert!(
                pattern.starts_with("packages/ios-app/"),
                "old path pattern must be repo-relative iOS path: {pattern}"
            );
            let matched = old_paths
                .iter()
                .any(|path| path == pattern || path.starts_with(pattern));
            assert!(matched, "old path pattern matches no old path: {pattern}");
            patterns.push(pattern.clone());
        }
    }

    let uncovered = old_paths
        .iter()
        .filter(|path| {
            !patterns
                .iter()
                .any(|pattern| *path == pattern || path.starts_with(pattern))
        })
        .cloned()
        .collect::<Vec<_>>();
    assert!(
        uncovered.is_empty(),
        "IARM inventory left old iOS paths uncovered: {uncovered:#?}"
    );
}

#[test]
fn phase_two_anchor_covers_deferred_agent_execution_buckets() {
    assert_contains_all(
        INVENTORY_PATH,
        &[
            "Phase 2 Anchor",
            "capability discovery",
            "filesystem",
            "jobs/processes",
            "worker self-extension",
            "subagents",
            "goals/queues/questions",
            "approvals",
            "web",
            "git/worktrees",
            "skills/rules/hooks/memory",
            "MCP",
            "scheduling",
            "program execution",
            "database/events",
            "settings",
            "dependency restoration",
        ],
    );

    let inventory = read_repo_file(INVENTORY_TSV_PATH);
    for bucket in [
        "BPRC-FEATURE-01",
        "BPRC-FEATURE-02",
        "BPRC-FEATURE-03",
        "BPRC-FEATURE-04",
        "BPRC-FEATURE-05",
        "BPRC-FEATURE-06",
        "BPRC-FEATURE-07",
        "BPRC-FEATURE-08",
        "BPRC-FEATURE-09",
        "BPRC-FEATURE-10",
        "BPRC-FEATURE-11",
        "BPRC-FEATURE-12",
        "BPRC-FEATURE-13",
        "BPRC-FEATURE-14",
        "BPRC-FEATURE-15",
        "BPRC-FEATURE-16",
        "BPRC-FEATURE-17",
        "BPRC-FEATURE-18",
        "BPRC-FEATURE-19",
        "BPRC-FEATURE-20",
        "BPRC-FEATURE-21",
        "BPRC-FEATURE-22",
        "BPRC-FEATURE-23",
        "BPRC-FEATURE-24",
    ] {
        assert!(
            inventory.contains(bucket),
            "IARM inventory must link deferred bucket {bucket}"
        );
    }
}

#[test]
fn slice_six_notification_inbox_decision_is_deferred_until_apns_restoration() {
    assert_contains_all(
        PROGRESS_PATH,
        &[
            "Phase 1 Slice 6: Notification/Inbox Concept Review",
            "Do not implement a Phase 1 notification/inbox affordance.",
            "central engine/resource mechanism",
            "This is not a permanent rejection of APNs.",
            "Current production source has no notification bell",
            "Direct inspection of the local Tron SQLite database",
            "Rejected for Phase 1: fake unread counts",
            "Deferred to Phase 2/restoration: APNs",
            "No Swift UI, public `/engine` methods, database tables",
            "Simulator validation:",
            "Not required. Slice 6 made no Swift or UI changes",
            "## Phase 1 Closeout",
            "No remaining Phase 1 slice is queued.",
        ],
    );

    let progress = read_repo_file(PROGRESS_PATH);
    assert!(
        !progress.contains("The next recommended restoration slice is `phase1_slice_6`"),
        "Slice 6 is no longer the next recommended slice after the defer decision"
    );
}

#[test]
fn phase_one_closeout_removes_retired_local_scaffolding_from_sources() {
    assert_contains_all(
        PROGRESS_PATH,
        &[
            "## Phase 1 Closeout",
            "Phase 1 local-native/user-facing affordance restoration is closed",
            "No remaining Phase 1 slice is queued",
            "session-list/cockpit placement cleanup",
            "moved Runtime Cockpit access into Servers -> Diagnostics",
            "No old notification bell",
            "No chat-mounted passive worker-runtime banner",
            "No temporary chat timeline loading spinner/text row",
            "No custom fallback session list row press implementation remains",
            "The next planned body of work is the full Phase 2 agent-execution restoration",
            "central engine/resource mechanism",
        ],
    );

    let source_text = tracked_text_under(&["packages/ios-app/Sources"]);
    for retired in [
        "ChatTimelineAuxiliaryState",
        "ChatTimelineLoadingView",
        "Loading messages",
        "AgentStatusCapsuleView",
        "showAgentCockpit",
        "agentCockpit.refresh",
        "NotificationBell",
        "NotificationInbox",
        "NotificationStore",
        "NotificationClient",
        "PushNotificationService",
        "APNsEnvironment",
        "NotificationDelivery",
        concat!("Session", "Dashboard", "RowButtonStyle"),
        "SessionListRowButtonStyle",
        "rowContainerSurface",
        "rowPressedScale",
        "rowPressedBrightness",
        "outerHorizontalPadding",
    ] {
        assert!(
            !source_text.contains(retired),
            "retired Phase 1 scaffolding still appears in iOS source: {retired}"
        );
    }

    let chat_source_text = tracked_text_under(&["packages/ios-app/Sources/UI/Chat"]);
    assert!(
        !chat_source_text.contains("AgentCockpitViewModel()"),
        "chat source must not instantiate the diagnostics-owned Agent cockpit"
    );
}

#[test]
fn static_gate_is_wired_in_local_and_github_closeout_targets() {
    let local_targets = parse_quality_closeout_targets();
    let github_targets = parse_github_static_gate_targets();
    assert_eq!(
        local_targets, github_targets,
        "local and GitHub closeout target order must match"
    );
    let iarm_index = local_targets
        .iter()
        .position(|target| target == TARGET_NAME)
        .expect("IARM target must be wired into closeout targets");
    let iosac_index = local_targets
        .iter()
        .position(|target| target == "ios_self_adapting_agent_cockpit_baseline_invariants")
        .expect("IOSAC target must stay wired");
    let primitive_trace_index = local_targets
        .iter()
        .position(|target| target == "primitive_trace_execution")
        .expect("primitive trace target must stay wired");
    assert!(
        iosac_index < iarm_index && iarm_index < primitive_trace_index,
        "IARM should run after IOSAC and before primitive trace"
    );
}
