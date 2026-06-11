//! Static invariants for the Configuration / Profile / Environment Discipline slice.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

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

fn assert_contains_all(path: &str, needles: &[&str]) {
    let source = read_repo_file(path);
    for needle in needles {
        assert!(
            source.contains(needle),
            "{path} missing required CPE marker: {needle}"
        );
    }
}

#[test]
fn cpe_artifacts_and_gate_wiring_exist() {
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(
            repo_path(path).exists(),
            "required CPE artifact missing: {path}"
        );
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
        assert!(source.contains(TARGET_NAME), "{path} must run CPE");
    }

    let ownership =
        read_repo_file("packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv");
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(
            ownership.contains(path),
            "HRA ownership map must include new CPE file: {path}"
        );
    }
}

#[test]
fn cpe_scorecard_is_closed_at_full_weight() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(scorecard.contains("Status: **closed**"));
    assert!(scorecard.contains("Current score: **100/100**"));
    assert!(scorecard.contains("Passing threshold: **100/100**"));

    let expected = [
        ("CPE-0", "Harness, Baseline, and Scope Control", 5),
        ("CPE-1", "Settings/Profile/Environment Inventory", 10),
        ("CPE-2", "Managed Defaults and Sparse User Overrides", 12),
        (
            "CPE-3",
            "Environment Variable Precedence and Intentionality",
            10,
        ),
        ("CPE-4", "Malformed Config and Safe Failure Semantics", 10),
        ("CPE-5", "iOS Settings Parity and Reset Semantics", 12),
        (
            "CPE-6",
            "README/Profile Examples/Generated Defaults Accuracy",
            8,
        ),
        ("CPE-7", "Runtime Load/Reset/Restart Semantics", 8),
        ("CPE-8", "Generated Default Profile and Drift Guards", 8),
        (
            "CPE-9",
            "Cross-Slice Preservation and Static Gate Integration",
            10,
        ),
        ("CPE-10", "Evidence, Closeout, and Clean State", 7),
    ];
    let mut total = 0u32;
    for (id, name, weight) in expected {
        let row = scorecard
            .lines()
            .find(|line| line.starts_with(&format!("| {id} |")))
            .unwrap_or_else(|| panic!("missing CPE scorecard row {id}"));
        let columns: Vec<_> = row.trim_matches('|').split('|').map(str::trim).collect();
        assert_eq!(columns.get(1), Some(&name), "unexpected CPE row: {row}");
        assert_eq!(
            columns
                .get(2)
                .unwrap_or_else(|| panic!("missing CPE weight: {row}"))
                .parse::<u32>()
                .unwrap_or_else(|error| panic!("invalid CPE weight in {row}: {error}")),
            weight,
            "unexpected CPE row weight: {row}"
        );
        assert_eq!(
            columns.get(3),
            Some(&"passed"),
            "CPE row must be passed at closeout: {row}"
        );
        total += weight;
    }
    assert_eq!(total, 100, "CPE scorecard weights must sum to 100");
}

#[test]
fn cpe_inventory_has_expected_header_and_required_rows() {
    let inventory = read_repo_file(INVENTORY_PATH);
    assert!(inventory.contains("Status: Complete"));
    assert!(inventory.contains(INVENTORY_TSV_PATH));

    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    assert_eq!(
        lines.next(),
        Some(
            "id\tpath\tsurface_kind\towner\tconfiguration_dimension\tcurrent_source_of_truth\tcurrent_default_override_env_behavior\trisk\tproof_target\taction_rationale"
        ),
        "CPE TSV header changed"
    );

    let mut ids = BTreeSet::new();
    let rows: Vec<_> = lines.collect();
    assert!(
        rows.len() >= 36,
        "CPE inventory must keep the audited row set"
    );
    for row in &rows {
        let columns: Vec<_> = row.split('\t').collect();
        assert_eq!(
            columns.len(),
            10,
            "CPE inventory row must have 10 columns: {row}"
        );
        assert!(
            ids.insert(columns[0].to_owned()),
            "duplicate CPE inventory id {}",
            columns[0]
        );
        assert!(
            columns[0].starts_with("CPE-INV-"),
            "inventory id must use CPE prefix: {}",
            columns[0]
        );
        for (field, value) in [
            ("path", columns[1]),
            ("surface_kind", columns[2]),
            ("owner", columns[3]),
            ("configuration_dimension", columns[4]),
            ("current_source_of_truth", columns[5]),
            ("current_default_override_env_behavior", columns[6]),
            ("risk", columns[7]),
            ("proof_target", columns[8]),
            ("action_rationale", columns[9]),
        ] {
            assert!(
                !value.trim().is_empty() && !value.contains("TODO") && !value.contains("TBD"),
                "{} has invalid {field} field: {value}",
                columns[0]
            );
        }
    }

    for required in [
        "CPE-INV-001\tpackages/agent/src/domains/settings/profile/types/mod.rs\trust_settings_root",
        "CPE-INV-006\tpackages/agent/defaults/profiles/default/profile.toml\tmanaged_default_profile",
        "CPE-INV-011\tpackages/agent/src/domains/settings/profile/storage/loader.rs\tsettings_loader",
        "CPE-INV-012\tpackages/agent/src/domains/settings/profile/store.rs\tsparse_writer",
        "CPE-INV-021\tpackages/agent/src/shared/protocol/settings.rs\tpublic_settings_dto",
        "CPE-INV-032\tpackages/ios-app/Sources/Engine/Protocol/Settings/EngineProtocolTypes+Settings.swift\tios_settings_decoder",
        "CPE-INV-036\tpackages/agent/tests/configuration_profile_environment_discipline_invariants.rs\tcpe_static_harness",
    ] {
        assert!(
            tsv.contains(required),
            "CPE inventory missing required row: {required}"
        );
    }
}

#[test]
fn cpe_evidence_manifest_lists_required_closeout_commands() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    assert!(evidence.contains("Status: **closed**"));
    assert!(evidence.contains("Current score: **100/100**"));
    assert!(
        !evidence.contains("not_run") && !evidence.contains("TODO") && !evidence.contains("TBD"),
        "final CPE evidence manifest must not retain placeholders"
    );

    for command in [
        "cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check",
        "cargo check --manifest-path packages/agent/Cargo.toml",
        "cargo test --manifest-path packages/agent/Cargo.toml domains::settings --lib -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test configuration_profile_environment_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test performance_resource_governance_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test provider_model_boundary_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test data_integrity_storage_evolution_migration_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_successor_teardown_cleanup_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture",
        "scripts/tron ci fmt check clippy test",
        "scripts/personal-info-guard.sh",
        "git diff --check",
        "git ls-files -ci --exclude-standard",
        "git status --short",
    ] {
        assert!(
            evidence.contains(command),
            "evidence manifest must record closeout command: {command}"
        );
    }
    assert!(
        evidence.contains("git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj"),
        "evidence must include the iOS XcodeGen drift check"
    );
    assert!(
        evidence.contains("git diff --exit-code -- packages/mac-app/TronMac.xcodeproj"),
        "evidence must include the macOS XcodeGen drift check"
    );
    assert!(
        evidence.contains("No iOS settings/protocol/UI files were touched"),
        "evidence must record iOS targeted-test rationale"
    );
}

#[test]
fn canonical_defaults_sparse_overrides_and_malformed_config_are_guarded() {
    assert_contains_all(
        "packages/agent/src/domains/settings/profile/types/mod.rs",
        &[
            "bundled_default_profile_settings_match_rust_defaults",
            "#[serde(rename_all = \"camelCase\", default, deny_unknown_fields)]",
            "TronSettings::default()",
        ],
    );
    for path in [
        "packages/agent/src/domains/settings/profile/types/api.rs",
        "packages/agent/src/domains/settings/profile/types/context.rs",
        "packages/agent/src/domains/settings/profile/types/server.rs",
        "packages/agent/src/domains/settings/profile/types/ui.rs",
    ] {
        assert_contains_all(
            path,
            &["deny_unknown_fields", "unknown", "serde_json::from_value"],
        );
    }

    let default_profile = read_repo_file("packages/agent/defaults/profiles/default/profile.toml");
    assert!(
        !default_profile.contains("queueDrainMode"),
        "managed default profile must not retain stale ignored session keys"
    );

    assert_contains_all(
        "packages/agent/src/domains/settings/profile/store.rs",
        &[
            "sparse_settings_profile_toml",
            "SettingsStore::operation_lock",
            "read_sparse_value",
            "reset_writes_empty_object",
            "update_rejects_malformed_existing_toml_and_preserves_file",
        ],
    );
    assert_contains_all(
        "packages/agent/src/domains/settings/profile/operations.rs",
        &[
            "read_sparse_settings_snapshot",
            "reload_profile_runtime_or_rollback",
            "restore_sparse_value_for_rollback",
            "PublicSettingsUpdate",
            "into_sparse_settings_value",
        ],
    );
    assert_contains_all(
        "packages/agent/src/domains/settings/profile/storage/loader.rs",
        &[
            "load_invalid_toml_returns_error",
            "load_rejects_removed_policy_settings",
            "load_rejects_unknown_nested_settings_fields",
            "load_rejects_wrong_type_settings",
        ],
    );
}

#[test]
fn environment_overrides_are_intentional_allowlisted_and_fail_closed() {
    let loader = read_repo_file("packages/agent/src/domains/settings/profile/storage/loader.rs");
    for required in [
        "SETTINGS_ENV_ALLOWLIST",
        "TRON_DEFAULT_MODEL",
        "TRON_DEFAULT_PROVIDER",
        "TRON_HEARTBEAT_INTERVAL",
        "ANTHROPIC_CLIENT_ID",
        "apply_env_overrides_from",
        "read_env_u64_from",
        "invalid_env_override_returns_error_without_partial_mutation",
    ] {
        assert!(
            loader.contains(required),
            "settings loader missing env discipline marker: {required}"
        );
    }
    assert!(
        loader.contains("Err(SettingsError::InvalidValue(format!("),
        "malformed settings env overrides must fail closed with SettingsError"
    );
    assert!(
        !loader.contains("invalid u64 env var, ignoring"),
        "malformed settings env overrides must not be silently ignored"
    );
    assert!(
        !loader.contains("parse_bool(") && !loader.contains("parse_u16_range("),
        "settings env parser must not retain unsupported bool/u16 env surfaces"
    );

    assert_contains_all(
        "packages/agent/src/domains/agent/loop/profile_runtime.rs",
        &[
            "apply_env_overrides(&mut settings).map_err",
            "profile settings are invalid after environment overrides",
            "keeping previous valid spec",
        ],
    );
    assert_contains_all(
        "packages/agent/src/shared/foundation/paths/mod.rs",
        &[
            "TRON_DATA_DIR_ENV",
            "TRON_HOME_NAME_ENV",
            "valid_home_relative_name",
        ],
    );
}

#[test]
fn ios_public_settings_parity_and_reset_semantics_stay_exact() {
    let rust = read_repo_file("packages/agent/src/shared/protocol/settings.rs");
    for required in [
        "pub const SETTINGS_CONTRACT_VERSION: u64 = 1;",
        "pub struct PublicSettingsSnapshot",
        "pub struct PublicSettingsUpdate",
        "default_model",
        "default_workspace",
        "tailscale_ip",
        "preserve_recent_count",
        "trigger_token_threshold",
        "verbose_retention_days",
        "retention_enabled",
        "max_database_mb",
    ] {
        assert!(
            rust.contains(required),
            "Rust public settings missing {required}"
        );
    }

    let swift = read_repo_file(
        "packages/ios-app/Sources/Engine/Protocol/Settings/EngineProtocolTypes+Settings.swift",
    );
    for required in [
        "static let currentVersion: UInt64 = 1",
        "let contractVersion: UInt64",
        "let defaultModel: String",
        "let defaultWorkspace: String?",
        "let tailscaleIp: String?",
        "let preserveRecentCount: Int",
        "let triggerTokenThreshold: Double",
        "let observabilityLogLevel: String",
        "let observabilityVerboseRetentionDays: UInt64",
        "let storageRetentionEnabled: Bool",
        "let storageMaxDatabaseMb: UInt64",
        "struct ServerSettingsUpdate: Encodable",
    ] {
        assert!(
            swift.contains(required),
            "Swift settings DTO missing {required}"
        );
    }

    assert_contains_all(
        "packages/ios-app/Sources/Session/Chat/State/SettingsState.swift",
        &[
            "resetToDefaults",
            "settingsRepository.resetToDefaults",
            "applyServerSettings(settings)",
            "rollbackToLastLoadedSettings",
            "lastLoadedSettings",
        ],
    );
    assert_contains_all(
        "packages/ios-app/Tests/Session/Chat/State/SettingsParityTests.swift",
        &[
            "KNOWN_UI_FIELDS",
            "observabilityVerboseRetentionDays",
            "storageMaxDatabaseMb",
            "testEverySettingsStateFieldIsWiredOrWaived",
        ],
    );
    assert_contains_all(
        "packages/ios-app/Tests/Engine/Protocol/EngineProtocolTypesSettingsTests.swift",
        &[
            "missing settings contract version is rejected",
            "stale settings contract version is rejected",
            "ServerSettingsUpdate encodes primitive structure",
        ],
    );
}

#[test]
fn readme_settings_profile_examples_and_env_docs_match_source() {
    let readme = read_repo_file("README.md");
    for required in [
        "Settings are loaded from three layers (highest priority last):",
        "Environment overrides are intentionally allowlisted",
        "\"heartbeatIntervalMs\": 30000",
        "\"defaultProvider\": \"anthropic\"",
        "\"defaultModel\": \"claude-sonnet-4-6\"",
        "\"maxRetries\": 3",
        "\"session\": {}",
        "The WebSocket port is a CLI flag (`--port`, default 9847), not a settings field.",
        "packages/agent/defaults/profiles/default/profile.toml",
        "profiles/user/profile.toml",
    ] {
        assert!(
            readme.contains(required),
            "README settings section missing {required}"
        );
    }
    assert!(
        !readme.contains("\"maxRetries\": 1"),
        "README must not retain stale retry default"
    );
}

#[test]
fn predecessor_gates_remain_wired() {
    let readme = read_repo_file("README.md");
    let quality = read_repo_file("scripts/tron.d/quality.sh");
    let ci = read_repo_file(".github/workflows/ci.yml");
    for target in [
        "security_authority_capability_boundaries_invariants",
        "off_plan_successor_teardown_cleanup_invariants",
        "observability_diagnostics_auditability_invariants",
        "data_integrity_storage_evolution_migration_discipline_invariants",
        "public_protocol_api_contract_discipline_invariants",
        "provider_model_boundary_discipline_invariants",
        "performance_resource_governance_invariants",
        "primitive_trace_execution",
        "integration",
    ] {
        assert!(
            readme.contains(target),
            "README missing predecessor {target}"
        );
        assert!(quality.contains(target), "local quality missing {target}");
        assert!(ci.contains(target), "GitHub static gate missing {target}");
    }
}
