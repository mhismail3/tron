//! Static invariants for the iOS Self-Adapting Agent Cockpit Baseline.
//! This target verifies successor-readiness cockpit wording only; it does not
//! add the retired SAA authorship architecture.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

const SCORECARD_PATH: &str =
    "packages/agent/docs/ios-self-adapting-agent-cockpit-baseline-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/ios-self-adapting-agent-cockpit-baseline-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/ios-self-adapting-agent-cockpit-baseline-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/ios-self-adapting-agent-cockpit-baseline-inventory.tsv";
const TARGET_PATH: &str =
    "packages/agent/tests/ios_self_adapting_agent_cockpit_baseline_invariants.rs";
const TARGET_NAME: &str = "ios_self_adapting_agent_cockpit_baseline_invariants";
const BASELINE_COMMIT: &str = "6aa395fddf8ad8cca8f485c6a96fa0e78862e653";

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
        "HEAD must descend from IOSAC baseline {BASELINE_COMMIT}"
    );
}

fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| IOSAC-"))
        .map(|line| {
            let columns: Vec<_> = line.trim_matches('|').split('|').map(str::trim).collect();
            assert_eq!(
                columns.len(),
                5,
                "IOSAC scorecard row must have five columns: {line}"
            );
            ScorecardRow {
                id: columns[0].to_owned(),
                name: columns[1].to_owned(),
                weight: columns[2]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid IOSAC weight in {line}: {error}")),
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
            "id\trecord_type\tpath_or_surface\towner\tclassification\tcurrent_state\tproof\tregression_gate\tscorecard_rows"
        ),
        "IOSAC inventory TSV header changed"
    );
    lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| line.split('\t').map(str::to_owned).collect::<Vec<_>>())
        .collect()
}

#[test]
fn scorecard_artifacts_and_lineage_are_current() {
    assert_current_lineage_base();
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(repo_path(path).exists(), "missing IOSAC artifact: {path}");
    }

    assert_contains_all(
        SCORECARD_PATH,
        &[
            "Status: **complete**",
            "Current score: **100/100**",
            "Passing threshold: **100/100**",
            "Total weight: **100**",
            "codex/ios-agent-cockpit-baseline-current",
            BASELINE_COMMIT,
            "Scope quarantine",
            "ui_surface",
            "GeneratedRuntimeSurfaceView",
        ],
    );
}

#[test]
fn scorecard_weights_sum_to_100_and_are_closed() {
    let rows = parse_scorecard_rows();
    let expected = BTreeMap::from([
        ("IOSAC-0", ("Baseline and scope", 5_u32)),
        ("IOSAC-1", ("Lifecycle protocol bridge", 10)),
        ("IOSAC-2", ("Cockpit projection model", 10)),
        ("IOSAC-3", ("Lifecycle actions and confirmations", 10)),
        ("IOSAC-4", ("Dynamic runtime surfaces", 10)),
        ("IOSAC-5", ("Chat shell integration", 10)),
        ("IOSAC-6", ("Neutral glass visual baseline", 8)),
        ("IOSAC-7", ("Focused Swift tests", 12)),
        ("IOSAC-8", ("Static gates", 10)),
        ("IOSAC-9", ("Docs and inventory", 8)),
        ("IOSAC-10", ("Closeout validation", 7)),
    ]);
    assert_eq!(rows.len(), expected.len(), "IOSAC must contain rows 0..10");
    let mut total = 0_u32;
    for row in &rows {
        let (name, weight) = expected
            .get(row.id.as_str())
            .unwrap_or_else(|| panic!("unexpected IOSAC row {}", row.id));
        assert_eq!(&row.name, name);
        assert_eq!(row.weight, *weight);
        assert_eq!(row.status, "passed", "{} must be closed", row.id);
        total += row.weight;
    }
    assert_eq!(total, 100, "IOSAC weights must sum to 100");
}

#[test]
fn inventory_is_structured_and_covers_cockpit_surfaces() {
    let rows = parse_inventory_rows();
    assert!(
        rows.len() >= 20,
        "IOSAC inventory should cover artifacts, source, tests, and gates"
    );
    let ids = rows
        .iter()
        .map(|row| row[0].as_str())
        .collect::<BTreeSet<_>>();
    for required in [
        "IOSAC-ARTIFACT-01",
        "IOSAC-ARTIFACT-02",
        "IOSAC-ARTIFACT-03",
        "IOSAC-ARTIFACT-04",
        "IOSAC-SOURCE-01",
        "IOSAC-SOURCE-02",
        "IOSAC-SOURCE-05",
        "IOSAC-SOURCE-06",
        "IOSAC-SOURCE-07",
        "IOSAC-SOURCE-08",
        "IOSAC-SOURCE-10",
        "IOSAC-SOURCE-11",
        "IOSAC-SERVER-01",
        "IOSAC-TEST-01",
        "IOSAC-TEST-02",
        "IOSAC-TEST-03",
        "IOSAC-TEST-04",
        "IOSAC-TEST-05",
        "IOSAC-GATE-01",
        "IOSAC-GATE-02",
    ] {
        assert!(ids.contains(required), "IOSAC inventory missing {required}");
    }

    for row in rows {
        assert_eq!(row.len(), 9, "inventory row must have 9 columns: {row:?}");
        for cell in &row {
            assert!(!cell.trim().is_empty(), "inventory cells must not be empty");
            assert!(
                !cell.contains("TODO") && !cell.contains("pending"),
                "inventory row must not preserve open work markers: {row:?}"
            );
        }
        let path = &row[2];
        if path.starts_with("packages/") || path == TARGET_PATH {
            assert!(
                repo_path(path).exists(),
                "inventory path must exist in working tree: {path}"
            );
        }
    }

    assert_contains_all(
        INVENTORY_PATH,
        &[
            "WorkerLifecycleClient",
            "WorkerLifecycleRepository",
            "AgentCockpitProjection",
            "AgentCockpitViewModel",
            "AgentCockpitSheet",
            "TronColors",
            "No new Rust primitive",
            "Existing `resource::list` and `resource::inspect` primitives are system-visible",
        ],
    );
}

#[test]
fn generic_resource_reads_are_client_visible_without_promoting_writes() {
    assert_contains_all(
        "packages/agent/src/engine/primitives/resource/mod.rs",
        &[
            "fn resource_read_function(",
            "function.visibility = VisibilityScope::System;",
            "resource_read_function(",
            "INSPECT_FUNCTION",
            "LIST_FUNCTION",
            "REGISTER_TYPE_FUNCTION",
            "register_type.visibility = VisibilityScope::Admin;",
            "CREATE_FUNCTION",
            "UPDATE_FUNCTION",
            "LINK_FUNCTION",
        ],
    );
    assert_contains_all(
        "packages/agent/src/engine/tests/invocation/meta_primitives.rs",
        &[
            "resource_read_primitives_are_visible_to_engine_client_without_write_access",
            "\"functionId\": \"resource::list\"",
            "\"functionId\": \"resource::create\"",
            "message.contains(\"not visible\")",
        ],
    );
}

#[test]
fn worker_lifecycle_client_uses_existing_engine_functions_only() {
    assert_contains_all(
        "packages/ios-app/Sources/Engine/Transport/Clients/WorkerLifecycleClient.swift",
        &[
            "catalog::watch_snapshot",
            "resource::list",
            "resource::inspect",
            "worker_lifecycle::propose_package_change",
            "worker_lifecycle::install_package",
            "worker_lifecycle::enable_package",
            "worker_lifecycle::disable_package",
            "worker_lifecycle::launch_worker",
            "worker_lifecycle::stop_worker",
            "worker_lifecycle::retire_package",
            "EngineInvocationContext(sessionId: sessionId, workspaceId: workspaceId)",
        ],
    );

    let client = read_repo_file(
        "packages/ios-app/Sources/Engine/Transport/Clients/WorkerLifecycleClient.swift",
    );
    assert!(
        !client.contains("/engine/"),
        "cockpit client must not add public transport routes"
    );
}

#[test]
fn cockpit_decodes_live_catalog_resources_and_runtime_surfaces() {
    assert_contains_all(
        "packages/ios-app/Sources/Engine/Protocol/WorkerLifecycle/EngineProtocolTypes+WorkerLifecycle.swift",
        &[
            "struct WorkerCatalogDefinitionDTO",
            "struct FunctionCatalogDefinitionDTO",
            "struct TriggerCatalogDefinitionDTO",
            "case uiSurface = \"ui_surface\"",
            "struct EngineResourceInspectionDTO",
            "func workerDefinitions()",
            "func functionDefinitions()",
            "func triggerDefinitions()",
        ],
    );

    assert_contains_all(
        "packages/ios-app/Sources/Session/WorkerLifecycle/AgentCockpitState.swift",
        &[
            "struct AgentCockpitRuntimeSurface",
            "var runtimeSurfaces: [AgentCockpitRuntimeSurface]",
            "static func project(",
            "static func actions(for package: AgentCockpitPackageRow)",
            "static func confirmation(for action: AgentCockpitAction)",
            "guard kind != .uiSurface else { return nil }",
        ],
    );

    assert_contains_all(
        "packages/ios-app/Sources/Session/WorkerLifecycle/AgentCockpitViewModel.swift",
        &[
            "let runtimeSurfaceResources = try await repository.listResources(kind: .uiSurface, lifecycle: \"active\", limit: 25)",
            "inspectRuntimeSurfaces(",
            "decodeSurface(from:",
            "UiSurfaceRefDTO(",
            "WorkerLifecycleResultDTO",
        ],
    );
}

#[test]
fn cockpit_ui_is_generic_and_not_placeholder_backed() {
    assert_contains_all(
        "packages/ios-app/Sources/UI/AgentCockpit/AgentCockpitViews.swift",
        &[
            "struct AgentStatusCapsuleView",
            "struct AgentCockpitSheet",
            "GeneratedRuntimeSurfaceView(",
            "resourceRef: runtimeSurface.resourceRef",
            "observedVersionId: runtimeSurface.resourceRef.versionId",
            "confirmationDialog(",
        ],
    );

    let cockpit =
        read_repo_file("packages/ios-app/Sources/UI/AgentCockpit/AgentCockpitViews.swift");
    for forbidden in [
        "sampleGeneratedSurface",
        "agent-cockpit-runtime-surface-placeholder",
        "repository-specific",
        "assistant-management",
    ] {
        assert!(
            !cockpit.contains(forbidden),
            "cockpit UI must not retain forbidden placeholder/fixed-panel text: {forbidden}"
        );
    }

    assert_contains_all(
        "packages/ios-app/Sources/UI/Chat/Shell/ChatView.swift",
        &[
            "agentCockpit = AgentCockpitViewModel()",
            "AgentStatusCapsuleView(",
            "sheetCoordinator.showAgentCockpit()",
        ],
    );
    assert_contains_all(
        "packages/ios-app/Sources/UI/Chat/Shell/ChatSheetContent.swift",
        &["AgentCockpitSheet("],
    );
    assert_contains_all(
        "packages/ios-app/Sources/UI/Chat/Shell/ChatSheetModifier.swift",
        &[
            "let observedActiveSheet = sheetCoordinator.activeSheet",
            ".sheet(item: sheetBinding(observedActiveSheet)",
        ],
    );
}

#[test]
fn neutral_glass_theme_baseline_is_locked_by_source_and_tests() {
    assert_contains_all(
        "packages/ios-app/Sources/UI/Theme/TronColors.swift",
        &[
            "static let tronEmerald = Color(lightHex: \"#2563EB\", darkHex: \"#60A5FA\")",
            "static let tronBackground = Color(lightHex: \"#F7F8FA\", darkHex: \"#090A0C\")",
            "static let tronSurface = Color(lightHex: \"#FFFFFF\", darkHex: \"#16181D\")",
            "static let tronSurfaceElevated = Color(lightHex: \"#EEF2F6\", darkHex: \"#252A32\")",
            "static let tronSuccess = Color(lightHex: \"#15803D\", darkHex: \"#22C55E\")",
            "static let tronWarning = Color(lightHex: \"#D97706\", darkHex: \"#F59E0B\")",
            "static let tronError = Color(lightHex: \"#DC2626\", darkHex: \"#EF4444\")",
        ],
    );
    assert_contains_all(
        "packages/ios-app/Tests/UI/Theme/TronColorsTests.swift",
        &[
            "lightModeBackgroundsAreNeutralGlass",
            "darkModeColorsUseNeutralGlassBaseline",
            "#F7F8FA",
            "#60A5FA",
        ],
    );
}

#[test]
fn focused_swift_tests_cover_cockpit_protocol_state_surfaces_and_theme() {
    assert_contains_all(
        "packages/ios-app/Tests/Engine/Protocol/WorkerLifecycleDTOTests.swift",
        &[
            "Catalog snapshot decodes current engine worker/function/trigger shapes",
            "Resource inspection decodes package manifest payload",
        ],
    );
    assert_contains_all(
        "packages/ios-app/Tests/Engine/Transport/Clients/WorkerLifecycleClientTests.swift",
        &[
            "Runtime surface resources use generic resource primitives",
            "Package ref lifecycle writes use worker lifecycle functions",
            "Manifest lifecycle writes keep manifest dynamic",
        ],
    );
    assert_contains_all(
        "packages/ios-app/Tests/Session/WorkerLifecycle/AgentCockpitStateTests.swift",
        &[
            "Projection derives workers functions packages activity and approval status",
            "Package actions require confirmation and disable unsafe lifecycle states",
        ],
    );
    assert_contains_all(
        "packages/ios-app/Tests/Session/WorkerLifecycle/AgentCockpitViewModelTests.swift",
        &[
            "Refresh loads catalog and lifecycle resources",
            "ui_surface:surface-1",
            "Runtime",
        ],
    );
    assert_contains_all(
        "packages/ios-app/Tests/UI/RuntimeSurfaces/GeneratedUIRendererTests.swift",
        &[
            "agent-created runtime surface renders and submits stored coordinates",
            "runtime schema supports every retained component",
        ],
    );
}

#[test]
fn docs_and_closeout_targets_reference_current_cockpit_behavior() {
    assert_contains_all(
        "README.md",
        &[
            "ios-self-adapting-agent-cockpit-baseline-scorecard.md",
            "Agent cockpit",
            "worker lifecycle catalog",
            "ui_surface",
            TARGET_NAME,
        ],
    );
    assert_contains_all(
        "packages/ios-app/docs/architecture.md",
        &[
            "Agent cockpit",
            "WorkerLifecycleRepository",
            "AgentCockpitProjection",
            "ui_surface",
            "neutral glass",
        ],
    );
    assert_contains_all("scripts/tron.d/quality.sh", &[TARGET_NAME]);
    assert_contains_all(
        ".github/workflows/ci.yml",
        &[&format!("cargo test --test {TARGET_NAME} -- --quiet")],
    );
}

#[test]
fn evidence_manifest_records_validation_and_simulator_baseline() {
    assert_contains_all(
        EVIDENCE_PATH,
        &[
            "WorkerLifecycleDTOTests",
            "WorkerLifecycleClientTests",
            "AgentCockpitStateTests",
            "AgentCockpitViewModelTests",
            "TronColorsTests",
            "GeneratedUIRendererTests",
            "scripts/tron ci fmt check clippy test",
            "scripts/personal-info-guard.sh",
            "xcodebuild test -scheme Tron",
            "Simulator validation is required",
            "Surfaces tab renders them through",
        ],
    );
}
