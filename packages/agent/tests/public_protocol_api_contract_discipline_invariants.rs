//! Static invariants for the public protocol / API contract discipline slice.

use std::path::PathBuf;

const SCORECARD_PATH: &str =
    "packages/agent/docs/public-protocol-api-contract-discipline-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/public-protocol-api-contract-discipline-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/public-protocol-api-contract-discipline-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/public-protocol-api-contract-discipline-inventory.tsv";
const TARGET_PATH: &str =
    "packages/agent/tests/public_protocol_api_contract_discipline_invariants.rs";
const TARGET_NAME: &str = "public_protocol_api_contract_discipline_invariants";

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

#[test]
fn ppacd_artifacts_and_gate_wiring_exist() {
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(
            repo_path(path).exists(),
            "required PPACD artifact missing: {path}"
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
            "README must mention PPACD artifact or target: {required}"
        );
    }

    for path in ["scripts/tron.d/quality.sh", ".github/workflows/ci.yml"] {
        let source = read_repo_file(path);
        assert!(source.contains(TARGET_NAME), "{path} must run PPACD");
    }
}

#[test]
fn ppacd_inventory_has_expected_header_and_marker_rows() {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut rows = tsv.lines();
    assert_eq!(
        rows.next(),
        Some(
            "id\tpath\tsurface_kind\tdirection\tpublic_status\tstability_decision\tserver_owner\tclient_mirror\terror_redaction\tproof_target\taction\trationale"
        ),
        "PPACD TSV header changed"
    );

    for required in [
        "PPACD-INV-005\tpackages/agent/src/shared/protocol/settings.rs\tsettings_dto",
        "PPACD-INV-006\tpackages/agent/src/domains/settings/handlers.rs\tsettings_snapshot_projection",
        "PPACD-INV-010\tpackages/ios-app/Sources/Engine/Protocol/Settings/EngineProtocolTypes+Settings.swift\tios_settings_decoder",
    ] {
        assert!(
            tsv.contains(required),
            "PPACD inventory missing required row: {required}"
        );
    }
}

#[test]
fn ppacd_settings_boundary_uses_public_versioned_dto() {
    let shared_settings = read_repo_file("packages/agent/src/shared/protocol/settings.rs");
    for required in [
        "pub const SETTINGS_CONTRACT_VERSION: u64 = 1;",
        "pub struct PublicSettingsSnapshot",
        "pub struct PublicSettingsUpdate",
        "into_sparse_settings_value",
    ] {
        assert!(
            shared_settings.contains(required),
            "shared public settings DTO missing required text: {required}"
        );
    }

    let handlers = read_repo_file("packages/agent/src/domains/settings/handlers.rs");
    assert!(
        handlers.contains("PublicSettingsSnapshot::from_internal"),
        "settings::get must project through the public DTO"
    );
    assert!(
        !handlers.contains("serde_json::to_value(&deps.profile_runtime.current().settings)"),
        "settings::get must not serialize internal TronSettings directly"
    );

    let operations = read_repo_file("packages/agent/src/domains/settings/profile/operations.rs");
    for required in [
        "PublicSettingsUpdate",
        "into_sparse_settings_value",
        "PublicSettingsSnapshot::from_internal",
    ] {
        assert!(
            operations.contains(required),
            "settings operations missing public DTO boundary text: {required}"
        );
    }

    let contract = read_repo_file("packages/agent/src/domains/settings/contract.rs");
    for required in [
        "public_settings_snapshot_schema()",
        "public_settings_update_schema()",
    ] {
        assert!(
            contract.contains(required),
            "settings contract missing narrow public schema text: {required}"
        );
    }
}

#[test]
fn ppacd_ios_settings_mirror_requires_public_contract_version() {
    let swift = read_repo_file(
        "packages/ios-app/Sources/Engine/Protocol/Settings/EngineProtocolTypes+Settings.swift",
    );
    for required in [
        "enum ServerSettingsContract",
        "static let currentVersion: UInt64 = 1",
        "let contractVersion: UInt64",
        "contractVersion = try container.decode(UInt64.self, forKey: .contractVersion)",
        "guard contractVersion == ServerSettingsContract.currentVersion",
        "var contractVersion: UInt64 = ServerSettingsContract.currentVersion",
    ] {
        assert!(
            swift.contains(required),
            "iOS settings mirror missing version contract text: {required}"
        );
    }
    assert!(
        !swift.contains("var session:"),
        "iOS public settings update must not reintroduce retired session settings"
    );

    let tests = read_repo_file(
        "packages/ios-app/Tests/Engine/Protocol/EngineProtocolTypesSettingsTests.swift",
    );
    for required in [
        "missing settings contract version is rejected",
        "stale settings contract version is rejected",
        "json[\"contractVersion\"] as? Int",
        "invocationContextOmitsAuthorityAndRuntimeInternals",
    ] {
        assert!(
            tests.contains(required),
            "iOS settings protocol tests missing required coverage: {required}"
        );
    }
}

#[test]
fn ppacd_public_engine_context_and_child_envelope_stay_narrow() {
    let wire = read_repo_file("packages/agent/src/transport/engine/socket/wire.rs");
    for required in [
        "pub(super) struct WireContext",
        "#[serde(rename_all = \"camelCase\", deny_unknown_fields)]",
        "pub(super) session_id: Option<String>",
        "pub(super) workspace_id: Option<String>",
        "pub(super) trace_id: Option<String>",
        "pub(super) parent_invocation_id: Option<String>",
    ] {
        assert!(
            wire.contains(required),
            "public WireContext missing required narrow field text: {required}"
        );
    }
    for forbidden in ["authority_scopes", "runtime_metadata"] {
        assert!(
            !wire.contains(forbidden),
            "public WireContext must not deserialize {forbidden}"
        );
    }

    let swift_core =
        read_repo_file("packages/ios-app/Sources/Engine/Protocol/Core/EngineProtocolTypes.swift");
    let context_section = swift_core
        .split("struct EngineInvocationContext")
        .nth(1)
        .and_then(|tail| tail.split("struct EngineInvocationOptions").next())
        .expect("EngineInvocationContext section should exist");
    for forbidden in ["authorityScopes", "runtimeMetadata"] {
        assert!(
            !context_section.contains(forbidden),
            "iOS public invocation context must not encode {forbidden}"
        );
    }

    let meta = read_repo_file("packages/agent/src/engine/invocation/host/meta.rs");
    let result_section = meta
        .split("pub(super) fn invocation_result_value")
        .nth(1)
        .and_then(|tail| tail.split("pub(super) fn delegated_invoke_value").next())
        .expect("invocation_result_value section should exist");
    for forbidden in [
        "\"workerId\"",
        "\"functionRevision\"",
        "\"catalogRevision\"",
    ] {
        assert!(
            !result_section.contains(forbidden),
            "delegated public child envelope must not expose {forbidden}"
        );
    }
    for required in [
        "\"invocationId\"",
        "\"functionId\"",
        "\"traceId\"",
        "\"value\"",
        "\"error\"",
    ] {
        assert!(
            result_section.contains(required),
            "delegated public child envelope missing stable field {required}"
        );
    }

    let child_section = swift_core
        .split("struct EngineChildInvocation")
        .nth(1)
        .and_then(|tail| tail.split("struct EngineChildError").next())
        .expect("EngineChildInvocation section should exist");
    for forbidden in ["workerId", "functionRevision", "catalogRevision"] {
        assert!(
            !child_section.contains(forbidden),
            "iOS public child decoder must not retain {forbidden}"
        );
    }
}
