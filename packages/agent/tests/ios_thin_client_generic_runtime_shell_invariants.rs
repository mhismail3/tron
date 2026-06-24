//! Static and source-backed invariants for the iOS Thin Client / Generic
//! Runtime Shell slice.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

const SCORECARD_PATH: &str =
    "packages/agent/docs/ios-thin-client-generic-runtime-shell-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/ios-thin-client-generic-runtime-shell-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/ios-thin-client-generic-runtime-shell-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/ios-thin-client-generic-runtime-shell-inventory.tsv";
const TARGET_PATH: &str =
    "packages/agent/tests/ios_thin_client_generic_runtime_shell_invariants.rs";
const TARGET_NAME: &str = "ios_thin_client_generic_runtime_shell_invariants";

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

fn git_ls_files() -> Vec<String> {
    let output = Command::new("git")
        .arg("ls-files")
        .current_dir(repo_root())
        .output()
        .expect("git ls-files should run");
    assert!(
        output.status.success(),
        "git ls-files failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("git output should be UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

fn tracked_or_present(path: &str) -> bool {
    repo_path(path).exists() || git_ls_files().iter().any(|tracked| tracked == path)
}

fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| IOSTC-"))
        .map(|line| {
            let columns: Vec<_> = line.trim_matches('|').split('|').map(str::trim).collect();
            assert_eq!(
                columns.len(),
                5,
                "IOSTC scorecard row must have five columns: {line}"
            );
            ScorecardRow {
                id: columns[0].to_owned(),
                name: columns[1].to_owned(),
                weight: columns[2]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid IOSTC weight in {line}: {error}")),
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
            "id\tpath\tsurface_kind\towner\tthin_client_boundary\tproof\tios_tests\tscorecard_rows"
        ),
        "IOSTC inventory TSV header changed"
    );
    lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| line.split('\t').map(str::to_owned).collect::<Vec<_>>())
        .collect()
}

fn ios_swift_files() -> Vec<String> {
    git_ls_files()
        .into_iter()
        .filter(|path| {
            path.ends_with(".swift")
                && (path.starts_with("packages/ios-app/Sources/")
                    || path.starts_with("packages/ios-app/Tests/"))
        })
        .collect()
}

fn is_ios_source_guard(path: &str) -> bool {
    path.contains("packages/ios-app/Tests/Infrastructure/Guards/SourceGuardTests")
}

fn assert_absent_from_ios_sources(tokens: &[(&str, &str)]) {
    for path in ios_swift_files() {
        if is_ios_source_guard(&path) {
            continue;
        }
        let source = read_repo_file(&path);
        for (token, reason) in tokens {
            assert!(
                !source.contains(token),
                "{path} contains deleted or forbidden {reason}: {token}"
            );
        }
    }
}

#[test]
fn iostc_artifacts_and_static_gate_wiring_exist() {
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(repo_path(path).exists(), "missing IOSTC artifact: {path}");
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
            "README must mention IOSTC artifact or target: {required}"
        );
    }

    for path in ["scripts/tron.d/quality.sh", ".github/workflows/ci.yml"] {
        let source = read_repo_file(path);
        assert!(
            source.contains(TARGET_NAME),
            "{path} must run the IOSTC invariant target"
        );
    }
}

#[test]
fn iostc_scorecard_weights_sum_to_100_and_are_closed() {
    let rows = parse_scorecard_rows();
    let expected = BTreeMap::from([
        (
            "IOSTC-0",
            ("Baseline, lineage, and stale-branch quarantine", 5_u32),
        ),
        (
            "IOSTC-1",
            ("Whole iOS client inventory and ownership map", 8),
        ),
        (
            "IOSTC-2",
            (
                "Thin-client boundary and deleted product-surface guards",
                12,
            ),
        ),
        (
            "IOSTC-3",
            ("Pairing, auth custody, and connection robustness", 10),
        ),
        (
            "IOSTC-4",
            ("Settings parity and sparse update contract", 10),
        ),
        (
            "IOSTC-5",
            ("Generic chat, timeline, and primitive/result rendering", 12),
        ),
        (
            "IOSTC-6",
            ("Server error, restart, offline, and recovery semantics", 10),
        ),
        (
            "IOSTC-7",
            ("Diagnostics, logs, redaction, and local persistence", 8),
        ),
        (
            "IOSTC-8",
            ("Simulator and generated project drift discipline", 8),
        ),
        (
            "IOSTC-9",
            ("Docs, README, predecessor inventories, and CI wiring", 9),
        ),
        ("IOSTC-10", ("Targeted static gates and broad closeout", 8)),
    ]);
    assert_eq!(rows.len(), expected.len(), "IOSTC must contain rows 0..10");
    let mut total = 0_u32;
    for row in &rows {
        let (name, weight) = expected
            .get(row.id.as_str())
            .unwrap_or_else(|| panic!("unexpected IOSTC row {}", row.id));
        assert_eq!(&row.name, name);
        assert_eq!(row.weight, *weight);
        assert_eq!(row.status, "passed", "{} must be closed", row.id);
        total += row.weight;
    }
    assert_eq!(total, 100, "IOSTC scorecard weights must sum to 100");

    let scorecard = read_repo_file(SCORECARD_PATH);
    for required in [
        "Status: **complete**",
        "Current score: **100/100**",
        "Passing threshold: **100/100**",
        "codex/ios-thin-client-generic-runtime-shell-current",
        "084efb4d807eb39c8f3a36508c12541a477c58ce",
        "codex/ios-thin-client-generic-runtime-shell",
        "3cec727e19505aa4c58a18bcc4e54560c6829cce",
        "quarry-only",
    ] {
        assert!(scorecard.contains(required), "scorecard missing {required}");
    }
    for forbidden in ["TODO", "TBD", "placeholder", "pending"] {
        assert!(
            !scorecard.contains(forbidden),
            "closed IOSTC scorecard must not contain {forbidden}"
        );
    }
}

#[test]
fn iostc_inventory_is_structured_and_covers_required_surfaces() {
    let rows = parse_inventory_rows();
    assert!(
        rows.len() >= 80,
        "IOSTC inventory row count regressed: {}",
        rows.len()
    );

    let allowed_surfaces = BTreeSet::from([
        "campaign_harness",
        "ios_protocol",
        "ios_events",
        "ios_persistence",
        "ios_chat_session",
        "ios_timeline_runtime",
        "ios_settings",
        "ios_pairing_auth",
        "ios_diagnostics",
        "generated_project",
        "docs_ci",
        "ios_tests",
        "predecessor_inventory",
    ]);
    let mut ids = BTreeSet::new();
    let mut surfaces = BTreeSet::new();
    let mut covered_rows = BTreeSet::new();
    let mut by_path = BTreeMap::new();
    for row in &rows {
        assert_eq!(row.len(), 8, "IOSTC row must have 8 fields: {row:?}");
        assert!(ids.insert(row[0].clone()), "duplicate IOSTC id {}", row[0]);
        assert!(row[0].starts_with("IOSTC-INV-"));
        assert!(
            tracked_or_present(&row[1]),
            "IOSTC inventory path must be tracked or present: {}",
            row[1]
        );
        assert!(
            allowed_surfaces.contains(row[2].as_str()),
            "{} has unknown surface {}",
            row[0],
            row[2]
        );
        for field in row {
            assert!(
                !field.trim().is_empty()
                    && !field.contains("TODO")
                    && !field.contains("TBD")
                    && !field.contains("pending")
                    && !field.contains("unclassified"),
                "invalid IOSTC inventory field in row {:?}",
                row
            );
        }
        surfaces.insert(row[2].clone());
        by_path.insert(row[1].clone(), row.clone());
        for row_id in row[7].split(',') {
            covered_rows.insert(row_id.to_owned());
        }
    }
    for surface in allowed_surfaces {
        assert!(
            surfaces.contains(surface),
            "missing IOSTC surface {surface}"
        );
    }
    for row_id in 0..=10 {
        assert!(
            covered_rows.contains(&format!("IOSTC-{row_id}")),
            "IOSTC inventory does not cover IOSTC-{row_id}"
        );
    }
    for required_path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
        "packages/ios-app/Sources/Engine/Protocol/Settings/EngineProtocolTypes+Settings.swift",
        "packages/ios-app/Sources/Session/Chat/State/SettingsState.swift",
        "packages/ios-app/Sources/Support/Pairing/PairingURLParser.swift",
        "packages/ios-app/Sources/UI/RuntimeSurfaces/GeneratedRuntimeSurfaceView.swift",
        "packages/ios-app/Tests/Infrastructure/Guards/SourceGuardTests+ProductSurfaces.swift",
        "packages/ios-app/Tests/Session/Chat/State/SettingsParityTests.swift",
        "packages/ios-app/Tests/Support/Diagnostics/DiagnosticsRedactorTests.swift",
        "packages/ios-app/project.yml",
        "packages/ios-app/TronMobile.xcodeproj/project.pbxproj",
        "scripts/tron.d/quality.sh",
        ".github/workflows/ci.yml",
        "README.md",
    ] {
        assert!(
            by_path.contains_key(required_path),
            "IOSTC inventory missing required path {required_path}"
        );
    }
}

#[test]
fn ios_deleted_product_surfaces_stay_absent_from_source() {
    let forbidden = [
        concat!("Agent", "Control"),
        concat!("Prompt", "Library"),
        concat!("Voice", "Notes"),
        concat!("Voice", "Note"),
        concat!("Source", "Control"),
        concat!("Audit", "Details"),
        concat!("Plugin", "Sources"),
        concat!("Session", "Tree"),
        concat!("Audio", "Transcription"),
        concat!("Memory", "Retain"),
        concat!("Rules", "Settings", "Page"),
        concat!("Repository", "Panel"),
        concat!("Assistant", "Management"),
        concat!("Media", "Workflow"),
    ];
    let pairs: Vec<_> = forbidden
        .iter()
        .map(|token| (*token, "fixed product surface"))
        .collect();
    assert_absent_from_ios_sources(&pairs);
}

#[test]
fn ios_source_does_not_own_server_provider_deploy_or_successor_behavior() {
    let tokens = [
        (concat!("OpenAI", "Provider"), "provider implementation"),
        (concat!("Anthropic", "Provider"), "provider implementation"),
        (concat!("Google", "Provider"), "provider implementation"),
        (concat!("Kimi", "Provider"), "provider implementation"),
        (concat!("MiniMax", "Provider"), "provider implementation"),
        (concat!("Ollama", "Provider"), "provider implementation"),
        ("SMAppService", "Mac service-management ownership"),
        ("LaunchAgent", "launchd ownership"),
        ("launchctl", "launchd ownership"),
        ("manual-deploy", "deploy workflow"),
        ("tron deploy", "production deploy workflow"),
        (concat!("Managed", "Skill"), "repo-managed skill surface"),
        (
            concat!("packages/agent/skills"),
            "repo-managed skill copy path",
        ),
        (concat!("Self", "Adapting", "Agent"), "successor feature UI"),
        (concat!("self-", "adapting agent"), "successor feature UI"),
        (concat!("Generated", "Worker"), "successor feature UI"),
        (
            concat!("Resource", "Mutation", "Policy"),
            "server resource policy",
        ),
    ];
    assert_absent_from_ios_sources(&tokens);
}

#[test]
fn settings_parity_sparse_update_and_decode_exception_are_source_guarded() {
    let settings_dto = read_repo_file(
        "packages/ios-app/Sources/Engine/Protocol/Settings/EngineProtocolTypes+Settings.swift",
    );
    let settings_state =
        read_repo_file("packages/ios-app/Sources/Session/Chat/State/SettingsState.swift");
    let repository = read_repo_file(
        "packages/ios-app/Sources/Engine/Transport/Clients/Repositories/Defaults/DefaultEngineAccessRepositories.swift",
    );
    let repository_protocol = read_repo_file(
        "packages/ios-app/Sources/Engine/Transport/Clients/Repositories/Defaults/Protocols/EngineAccessRepositories.swift",
    );
    let parity_test =
        read_repo_file("packages/ios-app/Tests/Session/Chat/State/SettingsParityTests.swift");
    let settings_tests = read_repo_file(
        "packages/ios-app/Tests/Engine/Protocol/EngineProtocolTypesSettingsTests.swift",
    );

    let editable_settings = [
        (
            "defaultModel",
            "defaultModel",
            "defaultModel",
            "defaultModel",
            "AgentSettingsPage.swift",
        ),
        (
            "defaultWorkspace",
            "defaultWorkspace",
            "quickSessionWorkspace",
            "defaultWorkspace",
            "AgentSettingsPage.swift",
        ),
        (
            "preserveRecentCount",
            "preserveRecentCount",
            "preserveRecentCount",
            "compactionPreserveRecentCount",
            "ContextSettingsPage.swift",
        ),
        (
            "triggerTokenThreshold",
            "triggerTokenThreshold",
            "triggerTokenThreshold",
            "compactionTriggerTokenThreshold",
            "ContextSettingsPage.swift",
        ),
        (
            "logLevel",
            "observabilityLogLevel",
            "observabilityLogLevel",
            "observabilityLogLevel",
            "ConnectionSettingsPage.swift",
        ),
        (
            "verboseRetentionDays",
            "observabilityVerboseRetentionDays",
            "observabilityVerboseRetentionDays",
            "observabilityVerboseRetentionDays",
            "ConnectionSettingsPage.swift",
        ),
        (
            "retentionEnabled",
            "storageRetentionEnabled",
            "storageRetentionEnabled",
            "storageRetentionEnabled",
            "ConnectionSettingsPage.swift",
        ),
        (
            "maxDatabaseMb",
            "storageMaxDatabaseMb",
            "storageMaxDatabaseMb",
            "storageMaxDatabaseMb",
            "ConnectionSettingsPage.swift",
        ),
    ];

    for (wire_key, dto_field, state_field, mutation_name, page) in editable_settings {
        assert!(
            settings_dto.contains(wire_key) && settings_dto.contains(dto_field),
            "ServerSettings DTO missing {wire_key}/{dto_field}"
        );
        assert!(
            settings_state.contains(state_field),
            "SettingsState missing {state_field}"
        );
        assert!(
            repository_protocol.contains(&format!("case {mutation_name}"))
                || repository_protocol.contains(&format!("case {mutation_name}(")),
            "SettingsMutation missing {mutation_name}"
        );
        assert!(
            repository.contains(mutation_name),
            "DefaultSettingsRepository missing sparse update mapping for {mutation_name}"
        );
        let page_source = read_repo_file(&format!(
            "packages/ios-app/Sources/UI/Settings/Pages/{page}"
        ));
        assert!(
            page_source.contains(state_field) || page_source.contains(mutation_name),
            "{page} missing setting control for {state_field}/{mutation_name}"
        );
        assert!(
            parity_test.contains(state_field),
            "SettingsParityTests missing field {state_field}"
        );
    }

    for required in [
        "ServerSettings decoder rejects malformed server field type",
        "ServerSettingsUpdate encodes primitive structure",
        r#"#expect(json["session"] == nil)"#,
        "missingRetiredPolicyBlocksAccepted",
    ] {
        assert!(
            settings_tests.contains(required),
            "settings DTO tests missing {required}"
        );
    }

    assert!(
        settings_dto.contains("tailscaleIp"),
        "iOS must continue to decode the Mac-owned tailscaleIp field when present"
    );
    assert!(
        !repository_protocol.contains("case tailscaleIp") && !repository.contains("tailscaleIp("),
        "tailscaleIp is Mac-wrapper-owned pairing metadata and must not become an iOS SettingsMutation"
    );
    let cpe_inventory = read_repo_file(
        "packages/agent/docs/configuration-profile-environment-discipline-inventory.tsv",
    );
    assert!(
        cpe_inventory.contains("Wrapper owns only settings.server.tailscaleIp"),
        "CPE inventory must record the tailscaleIp ownership exception"
    );
}

#[test]
fn generated_runtime_renderer_stays_generic() {
    let renderer = read_repo_file(
        "packages/ios-app/Sources/UI/RuntimeSurfaces/GeneratedRuntimeSurfaceView.swift",
    );
    let support = read_repo_file(
        "packages/ios-app/Sources/UI/RuntimeSurfaces/GeneratedRuntimeSurfaceView+Support.swift",
    );
    let tests =
        read_repo_file("packages/ios-app/Tests/UI/RuntimeSurfaces/GeneratedUIRendererTests.swift");

    for required in [
        "GeneratedRuntimeSurfaceView",
        "GeneratedUIRenderer",
        "schemaVersion",
        "supportedComponents",
        "UiActionSubmissionDTO",
        "surfaceResourceId",
        "surfaceVersionId",
        "actionId",
    ] {
        assert!(
            renderer.contains(required) || support.contains(required) || tests.contains(required),
            "generated runtime surface missing generic marker {required}"
        );
    }
    for forbidden in [
        "ReadCapabilityDetail",
        "BashCapabilityDetail",
        "WriteCapabilityDetail",
        "EditCapabilityDetail",
        "WebSearchCapability",
        "WebFetchCapability",
        concat!("Source", "Control"),
        concat!("Prompt", "Library"),
    ] {
        assert!(
            !renderer.contains(forbidden) && !support.contains(forbidden),
            "generated runtime renderer must not hardcode product panel {forbidden}"
        );
    }
}

#[test]
fn pairing_diagnostics_persistence_and_recovery_tests_remain_present() {
    let project = read_repo_file("packages/ios-app/TronMobile.xcodeproj/project.pbxproj");
    let evidence = read_repo_file(EVIDENCE_PATH);
    for test_name in [
        "PairingValidationTests.swift",
        "PairingURLParserTests.swift",
        "PairingPersistorTests.swift",
        "PairedServerTokenStoreTests.swift",
        "ConnectionErrorClassifierTests.swift",
        "EngineConnectionReconnectTests.swift",
        "StreamingRecoveryTests.swift",
        "SendBlockReasonTests.swift",
        "DiagnosticsRedactorTests.swift",
        "DiagnosticsBundleBuilderTests.swift",
        "ClientLogIngestionServiceTests.swift",
        "DatabaseSchemaTests.swift",
        "GeneratedUIRendererTests.swift",
        "CapabilityInvocationDisplayModelTests.swift",
        "EventTypeRegistryTests.swift",
        "ErrorEventProjectionTests.swift",
        "SettingsParityTests.swift",
    ] {
        assert!(
            project.contains(test_name),
            "generated project missing focused test file {test_name}"
        );
        assert!(
            evidence.contains(test_name.trim_end_matches(".swift")),
            "IOSTC evidence must reference focused test {test_name}"
        );
    }
}

#[test]
fn generated_project_and_simulator_evidence_are_recorded() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    for required in [
        "xcodegen generate",
        "git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj",
        "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5",
        "-only-testing:TronMobileTests/ServerSettingsTests",
        "-only-testing:TronMobileTests/SettingsParityTests",
        "-only-testing:TronMobileTests/PairingValidationTests",
        "-only-testing:TronMobileTests/PairingURLParserTests",
        "-only-testing:TronMobileTests/EventTypeRegistryTests",
        "-only-testing:TronMobileTests/ErrorEventProjectionTests",
        "-only-testing:TronMobileTests/CapabilityInvocationDisplayModelTests",
        "-only-testing:TronMobileTests/GeneratedUIRendererTests",
    ] {
        assert!(
            evidence.contains(required),
            "IOSTC evidence missing generated-project/simulator marker {required}"
        );
    }
    for forbidden in ["TODO", "TBD", "placeholder", "pending"] {
        assert!(
            !evidence.contains(forbidden),
            "closed IOSTC evidence must not contain {forbidden}"
        );
    }
}

#[test]
fn predecessor_inventory_wiring_is_recorded() {
    let inventory = read_repo_file(INVENTORY_TSV_PATH);
    let predecessors = [
        "hierarchical-rearchitecture-file-inventory.tsv",
        "hierarchical-rearchitecture-current-ownership-map.tsv",
        "primitive-code-cleanup-file-inventory.tsv",
        "true-primitive-cleanup-retention-inventory.tsv",
        "public-protocol-api-contract-discipline-inventory.tsv",
        "configuration-profile-environment-discipline-inventory.tsv",
        "release-install-upgrade-rollback-discipline-inventory.tsv",
        "observability-diagnostics-auditability-inventory.tsv",
        "data-integrity-storage-evolution-migration-discipline-inventory.tsv",
        "security-authority-capability-boundaries-inventory.tsv",
        "concurrency-scheduling-discipline-inventory.tsv",
        "state-ownership-lifecycle-inventory.tsv",
    ];
    for predecessor in predecessors {
        assert!(
            inventory.contains(predecessor),
            "IOSTC inventory missing predecessor audit path {predecessor}"
        );
    }

    for path in [
        "packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv",
        "packages/agent/docs/primitive-code-cleanup-file-inventory.tsv",
        "packages/agent/docs/true-primitive-cleanup-retention-inventory.tsv",
        "packages/agent/docs/public-protocol-api-contract-discipline-inventory.tsv",
        "packages/agent/docs/configuration-profile-environment-discipline-inventory.tsv",
        "packages/agent/docs/release-install-upgrade-rollback-discipline-inventory.tsv",
        "packages/agent/docs/observability-diagnostics-auditability-inventory.tsv",
        "packages/agent/docs/data-integrity-storage-evolution-migration-discipline-inventory.tsv",
        "packages/agent/docs/security-authority-capability-boundaries-inventory.tsv",
        "packages/agent/docs/concurrency-scheduling-discipline-inventory.tsv",
        "packages/agent/docs/state-ownership-lifecycle-inventory.tsv",
    ] {
        let predecessor = read_repo_file(path);
        assert!(
            predecessor.contains("iOS Thin Client / Generic Runtime Shell")
                || predecessor.contains("ios-thin-client-generic-runtime-shell")
                || predecessor.contains(TARGET_NAME),
            "{path} missing IOSTC predecessor inventory marker"
        );
    }
}
