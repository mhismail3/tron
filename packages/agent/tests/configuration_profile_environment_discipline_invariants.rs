//! Static invariants for the Configuration / Profile / Environment Discipline slice.

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
}

#[test]
fn cpe_scorecard_is_closed_at_full_weight() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(scorecard.contains("Status: **closed**"));
    assert!(scorecard.contains("Current score: **100/100**"));
    assert!(scorecard.contains("Passing threshold: **100/100**"));

    let expected = [
        ("CPE-0", "Harness, Baseline, Scope Control", 5),
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
        ("CPE-10", "Evidence, Closeout, Clean State", 7),
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
                .unwrap_or_else(|| panic!("missing weight in row: {row}"))
                .parse::<u32>()
                .unwrap_or_else(|error| panic!("invalid CPE weight in {row}: {error}")),
            weight,
            "unexpected CPE weight: {row}"
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
fn cpe_inventory_shape_and_required_surfaces_are_complete() {
    let inventory = read_repo_file(INVENTORY_PATH);
    assert!(inventory.contains("Status: Complete"));
    assert!(inventory.contains(INVENTORY_TSV_PATH));

    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    assert_eq!(
        lines.next(),
        Some(
            "id\tpath\tsurface_kind\towner\tsetting_env_profile_field\tsource_of_truth\tprecedence_default_reset_semantics\tcurrent_proof\trisk\tproof_target\taction_rationale"
        ),
        "CPE TSV header changed"
    );
    let rows: Vec<_> = lines.collect();
    assert_eq!(rows.len(), 22, "CPE inventory row count changed");

    for required in [
        "CPE-INV-001\tpackages/agent/src/domains/settings/profile/types/mod.rs",
        "CPE-INV-006\tpackages/agent/src/domains/settings/profile/storage/loader.rs",
        "CPE-INV-009\tpackages/agent/defaults/profiles/default/profile.toml",
        "CPE-INV-011\tpackages/agent/src/shared/protocol/settings.rs",
        "CPE-INV-012\tpackages/ios-app/Sources/Engine/Protocol/Settings/EngineProtocolTypes+Settings.swift",
        "CPE-INV-016\tREADME.md",
        "CPE-INV-019\tpackages/agent/tests/configuration_profile_environment_discipline_invariants.rs",
    ] {
        assert!(
            tsv.contains(required),
            "CPE inventory missing required row: {required}"
        );
    }

    for row in rows {
        let columns: Vec<_> = row.split('\t').collect();
        assert_eq!(
            columns.len(),
            11,
            "CPE inventory row must have 11 columns: {row}"
        );
        assert!(columns[0].starts_with("CPE-INV-"));
        for value in columns {
            assert!(
                !value.trim().is_empty() && !value.contains("TODO") && !value.contains("TBD"),
                "CPE inventory field must be complete: {row}"
            );
        }
    }
}

#[test]
fn cpe_evidence_manifest_lists_required_closeout_commands() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    assert!(evidence.contains("Status: **closed**"));
    assert!(evidence.contains("Current score: **100/100**"));
    assert!(
        !evidence.contains("pending") && !evidence.contains("TODO") && !evidence.contains("TBD"),
        "final CPE evidence must not retain placeholders"
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
            "CPE evidence manifest must record closeout command: {command}"
        );
    }
    assert!(evidence.contains("git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj"));
    assert!(evidence.contains("git diff --exit-code -- packages/mac-app/TronMac.xcodeproj"));
    assert!(
        evidence.contains("No iOS settings/protocol/UI source files were touched")
            || evidence.contains("platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5"),
        "evidence must record iOS 26.5 simulator result or source-grounded no-touch rationale"
    );
}

#[test]
fn settings_profile_schema_is_strict_and_env_overrides_fail_closed() {
    for path in [
        "packages/agent/src/domains/settings/profile/types/mod.rs",
        "packages/agent/src/domains/settings/profile/types/server.rs",
        "packages/agent/src/domains/settings/profile/types/context.rs",
        "packages/agent/src/domains/settings/profile/types/api.rs",
        "packages/agent/src/domains/settings/profile/types/ui.rs",
    ] {
        let source = read_repo_file(path);
        assert!(
            !source.contains("#[serde(rename_all = \"camelCase\", default)]"),
            "{path} must not keep lenient camelCase default settings structs"
        );
    }

    let loader = read_repo_file("packages/agent/src/domains/settings/profile/storage/loader.rs");
    for required in [
        "CPE environment overrides are a closed, typed allowlist",
        "pub fn apply_env_overrides(settings: &mut TronSettings) -> Result<()>",
        "let mut candidate = settings.clone();",
        "parse_u64_range(name, &val, min, max).map(Some)",
        "malformed_env_override_fails_without_partial_application",
        "valid_env_overrides_apply_transactionally",
    ] {
        assert!(
            loader.contains(required),
            "loader missing CPE marker: {required}"
        );
    }

    let default_profile = read_repo_file("packages/agent/defaults/profiles/default/profile.toml");
    assert!(
        !default_profile.contains("queueDrainMode"),
        "managed default profile must not retain stale session queueDrainMode"
    );
}

#[test]
fn public_settings_parity_is_explicit_between_rust_and_swift() {
    let rust = read_repo_file("packages/agent/src/shared/protocol/settings.rs");
    let swift = read_repo_file(
        "packages/ios-app/Sources/Engine/Protocol/Settings/EngineProtocolTypes+Settings.swift",
    );
    let state = read_repo_file("packages/ios-app/Sources/Session/Chat/State/SettingsState.swift");
    let agent_page =
        read_repo_file("packages/ios-app/Sources/UI/Settings/Pages/AgentSettingsPage.swift");

    for field in [
        "contract_version",
        "default_model",
        "default_workspace",
        "tailscale_ip",
        "preserve_recent_count",
        "trigger_token_threshold",
        "verbose_retention_days",
        "retention_enabled",
        "max_database_mb",
    ] {
        assert!(rust.contains(field), "Rust public DTO missing {field}");
    }

    for marker in [
        "contractVersion",
        "defaultModel",
        "defaultWorkspace",
        "tailscaleIp",
        "preserveRecentCount",
        "triggerTokenThreshold",
        "verboseRetentionDays",
        "retentionEnabled",
        "maxDatabaseMb",
        "ServerSettingsUpdate",
    ] {
        assert!(
            swift.contains(marker),
            "Swift settings DTO missing {marker}"
        );
    }

    for marker in [
        "defaultModel",
        "quickSessionWorkspace",
        "preserveRecentCount",
        "triggerTokenThreshold",
        "observabilityVerboseRetentionDays",
        "storageRetentionEnabled",
        "storageMaxDatabaseMb",
        "resetToDefaults",
    ] {
        assert!(state.contains(marker), "SettingsState missing {marker}");
    }
    assert!(agent_page.contains("updateServerSetting(.defaultWorkspace"));
    assert!(agent_page.contains("updateServerSetting(.defaultModel"));
}

#[test]
fn cpe_hra_ownership_rows_cover_new_artifacts() {
    let current =
        read_repo_file("packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv");
    let historical =
        read_repo_file("packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv");
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(
            current.contains(path),
            "HRA current ownership map missing CPE path: {path}"
        );
        assert!(
            historical.contains(path),
            "HRA file inventory missing CPE path: {path}"
        );
    }
}
