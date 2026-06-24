//! Static and synthetic invariants for the Configuration / Profile /
//! Environment Discipline slice.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

use tron::domains::settings::profile::types::TronSettings;

const SCORECARD_PATH: &str =
    "packages/agent/docs/configuration-profile-environment-discipline-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/configuration-profile-environment-discipline-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/configuration-profile-environment-discipline-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/configuration-profile-environment-discipline-inventory.tsv";
const TARGET_PATH: &str =
    "packages/agent/tests/configuration_profile_environment_discipline_invariants.rs";
const TARGET_NAME: &str = "configuration_profile_environment_discipline_invariants";

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

fn git_ls_files(prefix: &str) -> Vec<String> {
    let output = Command::new("git")
        .args(["ls-files", prefix])
        .current_dir(repo_root())
        .output()
        .expect("git ls-files should run");
    assert!(
        output.status.success(),
        "git ls-files failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("git output should be utf8")
        .lines()
        .map(str::to_owned)
        .collect()
}

fn tracked_or_present(path: &str) -> bool {
    repo_path(path).exists() || git_ls_files(path).iter().any(|tracked| tracked == path)
}

fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| CPE-"))
        .map(|line| {
            let columns: Vec<_> = line.trim_matches('|').split('|').map(str::trim).collect();
            assert_eq!(
                columns.len(),
                5,
                "scorecard row must have five columns: {line}"
            );
            ScorecardRow {
                id: columns[0].to_owned(),
                name: columns[1].to_owned(),
                weight: columns[2]
                    .parse()
                    .unwrap_or_else(|error| panic!("invalid scorecard weight in {line}: {error}")),
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
            "id\tpath\tsurface_kind\towner\tcanonical_source\twrite_or_override_rule\tproof\tscorecard_rows"
        ),
        "CPE inventory TSV header changed"
    );
    lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| line.split('\t').map(str::to_owned).collect::<Vec<_>>())
        .collect()
}

#[test]
fn cpe_artifacts_and_static_gate_wiring_exist() {
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(repo_path(path).exists(), "missing CPE artifact: {path}");
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
            "README must mention CPE artifact or target: {required}"
        );
    }

    for path in ["scripts/tron.d/quality.sh", ".github/workflows/ci.yml"] {
        let source = read_repo_file(path);
        assert!(
            source.contains(TARGET_NAME),
            "{path} must run CPE invariant target"
        );
    }
}

#[test]
fn cpe_scorecard_weights_sum_to_100_and_are_closed() {
    let rows = parse_scorecard_rows();
    let expected = BTreeMap::from([
        (
            "CPE-0",
            ("Baseline, lineage, and stale-branch quarantine", 5_u32),
        ),
        ("CPE-1", ("Whole configuration/profile/env inventory", 8)),
        ("CPE-2", ("Canonical settings schema and defaults", 12)),
        (
            "CPE-3",
            ("Sparse user overlay and atomic update discipline", 12),
        ),
        (
            "CPE-4",
            ("Profile inheritance, versioning, seeding, and recovery", 10),
        ),
        (
            "CPE-5",
            ("Environment variable ownership and override discipline", 10),
        ),
        ("CPE-6", ("iOS settings parity", 12)),
        (
            "CPE-7",
            ("Malformed config safe failure and error surfacing", 10),
        ),
        (
            "CPE-8",
            ("Docs, README, predecessor inventories, and CI wiring", 9),
        ),
        (
            "CPE-9",
            ("Targeted static gates and verification harness", 8),
        ),
        ("CPE-10", ("Broad closeout and clean commit", 4)),
    ]);
    assert_eq!(rows.len(), expected.len(), "CPE must contain rows 0..10");
    let mut total = 0_u32;
    for row in &rows {
        let (name, weight) = expected
            .get(row.id.as_str())
            .unwrap_or_else(|| panic!("unexpected CPE row {}", row.id));
        assert_eq!(&row.name, name);
        assert_eq!(row.weight, *weight);
        assert_eq!(row.status, "passed", "{} must be closed", row.id);
        total += row.weight;
    }
    assert_eq!(total, 100, "CPE scorecard weights must sum to 100");

    let scorecard = read_repo_file(SCORECARD_PATH);
    for required in [
        "Status: **complete**",
        "Current score: **100/100**",
        "Passing threshold: **100/100**",
        "codex/configuration-profile-environment-discipline-current",
        "c1d266e224f87fb57f18f85846f2c8931e038ec8",
        "codex/configuration-profile-environment-discipline-recovery",
        "quarry-only",
    ] {
        assert!(scorecard.contains(required), "scorecard missing {required}");
    }
    for forbidden in ["TODO", "TBD", "placeholder"] {
        assert!(
            !scorecard.contains(forbidden),
            "closed CPE scorecard must not contain {forbidden}"
        );
    }
}

#[test]
fn cpe_inventory_is_structured_and_covers_required_surfaces() {
    let rows = parse_inventory_rows();
    assert!(
        rows.len() >= 70,
        "CPE inventory row count regressed: {}",
        rows.len()
    );

    let allowed_surfaces = BTreeSet::from([
        "rust_schema",
        "profile_defaults",
        "sparse_overlay",
        "profile_runtime",
        "env_override",
        "script_env",
        "ios_settings",
        "mac_wrapper",
        "docs_ci",
        "predecessor_inventory",
    ]);
    let mut ids = BTreeSet::new();
    let mut covered_rows = BTreeSet::new();
    let mut surfaces = BTreeSet::new();
    for row in &rows {
        assert_eq!(row.len(), 8, "CPE row must have 8 fields: {row:?}");
        assert!(ids.insert(row[0].clone()), "duplicate CPE id {}", row[0]);
        assert!(row[0].starts_with("CPE-INV-"));
        assert!(
            tracked_or_present(&row[1]),
            "CPE inventory path must be tracked or present: {}",
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
                    && !field.contains("unclassified"),
                "invalid CPE inventory field in row {:?}",
                row
            );
        }
        surfaces.insert(row[2].clone());
        for id in row[7].split(',') {
            covered_rows.insert(id.to_owned());
        }
    }
    for surface in allowed_surfaces {
        assert!(surfaces.contains(surface), "missing surface {surface}");
    }
    for row_id in 0..=10 {
        assert!(
            covered_rows.contains(&format!("CPE-{row_id}")),
            "CPE inventory does not cover CPE-{row_id}"
        );
    }
    for required_path in [
        "packages/agent/src/domains/settings/profile/types/mod.rs",
        "packages/agent/defaults/profiles/default/profile.toml",
        "packages/ios-app/Sources/Engine/Protocol/Settings/EngineProtocolTypes+Settings.swift",
        "packages/mac-app/Sources/Server/Paths/ServerSettingsProfile.swift",
        "scripts/tron.d/dev.sh",
        ".github/workflows/ci.yml",
    ] {
        assert!(
            rows.iter().any(|row| row[1] == required_path),
            "CPE inventory missing required path {required_path}"
        );
    }
}

#[test]
fn managed_default_profile_cannot_drift_from_compiled_settings_defaults() {
    let default_profile = read_repo_file("packages/agent/defaults/profiles/default/profile.toml");
    assert!(
        !default_profile.contains("queueDrainMode"),
        "stale settings.session.queueDrainMode must not return to managed defaults"
    );

    let bundled = tron::shared::foundation::profile::bundled_default_execution_spec();
    assert_eq!(
        serde_json::to_value(bundled.settings()).unwrap(),
        serde_json::to_value(TronSettings::default()).unwrap(),
        "managed default profile [settings] must match compiled Rust defaults"
    );

    let loader_source =
        read_repo_file("packages/agent/src/domains/settings/profile/storage/loader.rs");
    assert!(loader_source.contains("bundled_profile_settings_match_compiled_rust_defaults"));
    assert!(loader_source.contains("load_rejects_unknown_nested_session_settings"));
}

#[test]
fn nested_rust_settings_schemas_reject_unknown_fields() {
    for path in [
        "packages/agent/src/domains/settings/profile/types/api.rs",
        "packages/agent/src/domains/settings/profile/types/context.rs",
        "packages/agent/src/domains/settings/profile/types/mod.rs",
        "packages/agent/src/domains/settings/profile/types/server.rs",
        "packages/agent/src/domains/settings/profile/types/ui.rs",
    ] {
        let source = read_repo_file(path);
        assert!(
            source.contains("deny_unknown_fields"),
            "{path} must reject stale nested profile keys"
        );
    }
    let server = read_repo_file("packages/agent/src/domains/settings/profile/types/server.rs");
    assert!(server.contains("session_unknown_field_rejected"));
    let context = read_repo_file("packages/agent/src/domains/settings/profile/types/context.rs");
    assert!(context.contains("unknown_compactor_field_rejected"));
}

#[test]
fn sparse_overlay_rules_stay_atomic_sparse_and_rollback_safe() {
    let store = read_repo_file("packages/agent/src/domains/settings/profile/store.rs");
    for required in [
        "tempfile::Builder::new()",
        ".persist(&self.path)",
        "sync_parent_dir(parent)",
        "validate_sparse_settings",
        "write_profile_toml_locked(&Value::Object(Map::new()))",
        "restore_sparse_value_for_rollback",
    ] {
        assert!(store.contains(required), "SettingsStore missing {required}");
    }
    let user_profile = read_repo_file("packages/agent/defaults/profiles/user/profile.toml");
    let user_profile_value: toml::Value = user_profile
        .parse()
        .expect("managed user profile seed should be valid TOML");
    assert!(
        user_profile_value.get("settings").is_none(),
        "managed user profile seed must not contain persisted settings defaults"
    );
    assert!(user_profile.contains("inherits = []"));

    let operations = read_repo_file("packages/agent/src/domains/settings/profile/operations.rs");
    for required in [
        "SettingsStore::operation_lock",
        "read_sparse_settings_snapshot",
        "reload_profile_runtime_or_rollback",
        "rollback_sparse_settings",
    ] {
        assert!(
            operations.contains(required),
            "settings operations missing {required}"
        );
    }
}

#[test]
fn environment_override_surface_is_explicit_and_owned() {
    let paths = read_repo_file("packages/agent/src/shared/foundation/paths/mod.rs");
    for required in [
        "TRON_DATA_DIR_ENV",
        "TRON_HOME_NAME_ENV",
        "valid_home_relative_name",
        "must be a single home-relative directory name",
    ] {
        assert!(
            paths.contains(required),
            "paths env owner missing {required}"
        );
    }

    let loader = read_repo_file("packages/agent/src/domains/settings/profile/storage/loader.rs");
    for required in [
        "TRON_DEFAULT_MODEL",
        "TRON_DEFAULT_PROVIDER",
        "TRON_HEARTBEAT_INTERVAL",
        "ANTHROPIC_CLIENT_ID",
        "parse_u64_range",
    ] {
        assert!(
            loader.contains(required),
            "settings env override missing {required}"
        );
    }

    let inventory = read_repo_file(INVENTORY_TSV_PATH);
    for required in [
        "TRON_DATA_DIR",
        "TRON_HOME_NAME",
        "TRON_MAC_INSTALL_MODE",
        "TRON_IOS_DEVICE_NAME",
        "TRON_IOS_SCHEME",
        "TRON_IOS_CONFIGURATION",
    ] {
        assert!(
            inventory.contains(required),
            "CPE env inventory missing {required}"
        );
    }
}

#[test]
fn ios_settings_decode_is_server_authoritative_and_ui_wired() {
    let dto = read_repo_file(
        "packages/ios-app/Sources/Engine/Protocol/Settings/EngineProtocolTypes+Settings.swift",
    );
    assert!(dto.contains("defaultModel = try serverContainer.decode(String.self"));
    assert!(dto.contains("compaction = try contextContainer.decode"));
    assert!(dto.contains("observabilityLogLevel = try observabilityContainer.decode"));
    assert!(dto.contains("storageRetentionEnabled = try storageContainer.decode"));
    for forbidden in [
        "try? serverContainer.decodeIfPresent(String.self, forKey: .defaultModel",
        "?? \"claude-sonnet-4-6\"",
        "?? .defaults",
    ] {
        assert!(
            !dto.contains(forbidden),
            "iOS settings decoder must not mask server state with fallback {forbidden}"
        );
    }

    let tests = read_repo_file(
        "packages/ios-app/Tests/Engine/Protocol/EngineProtocolTypesSettingsTests.swift",
    );
    for required in [
        "serverSettingsDecoderRejectsEmptyPayload",
        "serverSettingsDecoderRejectsMalformedTypes",
        "settingsUpdateEncode",
    ] {
        assert!(
            tests.contains(required),
            "iOS settings tests missing {required}"
        );
    }

    let parity =
        read_repo_file("packages/ios-app/Tests/Session/Chat/State/SettingsParityTests.swift");
    for required in [
        "defaultModel",
        "quickSessionWorkspace",
        "preserveRecentCount",
        "triggerTokenThreshold",
        "observabilityLogLevel",
        "storageMaxDatabaseMb",
    ] {
        assert!(
            parity.contains(required),
            "iOS parity test missing {required}"
        );
    }
}

#[test]
fn mac_wrapper_seeds_only_current_sparse_user_overlay_metadata() {
    let source =
        read_repo_file("packages/mac-app/Sources/Server/Paths/ServerSettingsProfile.swift");
    for required in [
        "version = \"3\"",
        "inherits = []",
        "authProfile = \"default\"",
        "settings.server",
        "tailscaleIp",
    ] {
        assert!(
            source.contains(required),
            "Mac settings profile missing {required}"
        );
    }
    assert!(
        !source.contains("inherits = [\"normal\"]"),
        "Mac sparse overlay seed must not inherit managed defaults"
    );

    let tests =
        read_repo_file("packages/mac-app/Tests/Server/Paths/ServerSettingsReaderTests.swift");
    assert!(tests.contains("creates missing profile with Tailscale IP cache"));
    assert!(tests.contains("inherits = []"));
}

#[test]
fn predecessor_inventory_wiring_is_recorded() {
    let inventory = read_repo_file(INVENTORY_TSV_PATH);
    for predecessor in [
        "performance-resource-governance-inventory.tsv",
        "provider-model-boundary-discipline-inventory.tsv",
        "public-protocol-api-contract-discipline-inventory.tsv",
        "off-plan-saa-authorship-teardown-cleanup-inventory.tsv",
        "data-integrity-storage-evolution-migration-discipline-inventory.tsv",
        "observability-diagnostics-auditability-inventory.tsv",
        "security-authority-capability-boundaries-inventory.tsv",
        "concurrency-scheduling-discipline-inventory.tsv",
        "state-ownership-lifecycle-inventory.tsv",
        "failure-semantics-inventory.tsv",
        "determinism-replayability-inventory.tsv",
        "true-primitive-cleanup-retention-inventory.tsv",
        "hierarchical-rearchitecture-file-inventory.tsv",
        "hierarchical-rearchitecture-current-ownership-map.tsv",
        "primitive-code-cleanup-file-inventory.tsv",
    ] {
        assert!(
            inventory.contains(predecessor),
            "CPE inventory missing predecessor audit path {predecessor}"
        );
    }

    for path in [
        "packages/agent/docs/performance-resource-governance-inventory.tsv",
        "packages/agent/docs/provider-model-boundary-discipline-inventory.tsv",
        "packages/agent/docs/public-protocol-api-contract-discipline-inventory.tsv",
        "packages/agent/docs/off-plan-saa-authorship-teardown-cleanup-inventory.tsv",
        "packages/agent/docs/data-integrity-storage-evolution-migration-discipline-inventory.tsv",
        "packages/agent/docs/observability-diagnostics-auditability-inventory.tsv",
        "packages/agent/docs/security-authority-capability-boundaries-inventory.tsv",
        "packages/agent/docs/concurrency-scheduling-discipline-inventory.tsv",
        "packages/agent/docs/state-ownership-lifecycle-inventory.tsv",
        "packages/agent/docs/failure-semantics-inventory.tsv",
        "packages/agent/docs/determinism-replayability-inventory.tsv",
        "packages/agent/docs/true-primitive-cleanup-retention-inventory.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv",
        "packages/agent/docs/primitive-code-cleanup-file-inventory.tsv",
    ] {
        let predecessor = read_repo_file(path);
        assert!(
            predecessor.contains("Configuration / Profile / Environment Discipline")
                || predecessor.contains("configuration-profile-environment-discipline")
                || predecessor.contains("configuration_profile_environment_discipline"),
            "{path} missing CPE predecessor inventory marker"
        );
    }
}
