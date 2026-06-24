//! Static gates for the Public Protocol API Contract Discipline slice.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::process::Command;

const SCORECARD_PATH: &str =
    "packages/agent/docs/public-protocol-api-contract-discipline-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/public-protocol-api-contract-discipline-evidence-manifest.md";
const INVENTORY_PATH: &str =
    "packages/agent/docs/public-protocol-api-contract-discipline-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/public-protocol-api-contract-discipline-inventory.tsv";
const INVARIANT_PATH: &str =
    "packages/agent/tests/public_protocol_api_contract_discipline_invariants.rs";
const TARGET_NAME: &str = "public_protocol_api_contract_discipline_invariants";

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

fn git_ls_files() -> Vec<String> {
    let output = Command::new("git")
        .arg("ls-files")
        .current_dir(repo_root())
        .output()
        .expect("git ls-files should run");
    assert!(output.status.success(), "git ls-files failed");
    String::from_utf8(output.stdout)
        .expect("git output should be UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

fn parse_scorecard_rows() -> Vec<ScorecardRow> {
    read_repo_file(SCORECARD_PATH)
        .lines()
        .filter(|line| line.starts_with("| PPACD-"))
        .map(|line| {
            let columns: Vec<_> = line.trim_matches('|').split('|').map(str::trim).collect();
            assert_eq!(
                columns.len(),
                5,
                "scorecard row must have 5 columns: {line}"
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
            "id\tpath\tlanguage\tsurface\towner\twire_direction\tversioning\tstrictness\tauthority_or_idempotency\tverification\tppacd_rows"
        ),
        "PPACD inventory TSV header changed"
    );
    lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| line.split('\t').map(str::to_owned).collect::<Vec<_>>())
        .collect()
}

#[test]
fn ppacd_scorecard_rows_are_weighted_and_closed() {
    let rows = parse_scorecard_rows();
    let expected = BTreeMap::from([
        ("PPACD-0", ("Harness, Base, and Scope Control", 5_u32)),
        (
            "PPACD-1",
            ("Protocol Surface Inventory and Ownership Map", 8),
        ),
        (
            "PPACD-2",
            ("`/engine` Message Grammar and Version Negotiation", 10),
        ),
        (
            "PPACD-3",
            ("Public Method Catalog and Canonical Capability Routing", 10),
        ),
        (
            "PPACD-4",
            (
                "Public Context, Authority, Runtime Metadata, and Idempotency Boundary",
                12,
            ),
        ),
        (
            "PPACD-5",
            ("Response, Error, and Canonical Failure Envelope Parity", 10),
        ),
        (
            "PPACD-6",
            (
                "Event Payload, Stream Frame, Cursor, and Subscription Contract Parity",
                10,
            ),
        ),
        (
            "PPACD-7",
            ("Settings/Auth/Model/Session DTO Server-iOS Parity", 10),
        ),
        (
            "PPACD-8",
            ("iOS Transport Client Narrowness and Decoder Strictness", 8),
        ),
        (
            "PPACD-9",
            (
                "Negative Guards Against Internal Leakage and Compatibility Drift",
                8,
            ),
        ),
        (
            "PPACD-10",
            ("Evidence, Broad Verification, and Clean Commit", 9),
        ),
    ]);
    assert_eq!(rows.len(), expected.len(), "PPACD must contain rows 0..10");
    let mut total = 0;
    for row in &rows {
        let (name, weight) = expected
            .get(row.id.as_str())
            .unwrap_or_else(|| panic!("unexpected PPACD row {}", row.id));
        assert_eq!(&row.name, name);
        assert_eq!(row.weight, *weight);
        assert_eq!(row.status, "passed_after_fix", "{} must be closed", row.id);
        total += row.weight;
    }
    assert_eq!(total, 100, "PPACD scorecard weights must sum to 100");
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(scorecard.contains("Status: **complete**"));
    assert!(scorecard.contains("Current score: **100/100**"));
    for forbidden in ["TODO", "TBD", "placeholder", "pending"] {
        assert!(
            !scorecard.contains(forbidden),
            "closed PPACD scorecard must not contain {forbidden}"
        );
    }
}

#[test]
fn ppacd_inventory_is_structured_and_covers_required_surfaces() {
    let tracked: BTreeSet<_> = git_ls_files().into_iter().collect();
    let rows = parse_inventory_rows();
    assert!(rows.len() >= 40, "PPACD inventory row count regressed");
    let allowed_surfaces = BTreeSet::from([
        "campaign_harness",
        "engine_transport",
        "engine_meta_response",
        "server_protocol",
        "settings_auth_model_session",
        "ios_protocol",
        "ios_transport",
        "ios_docs",
        "predecessor_inventory",
    ]);
    let mut ids = BTreeSet::new();
    let mut by_path = BTreeMap::new();
    let mut covered_rows = BTreeSet::new();
    for row in rows {
        assert_eq!(
            row.len(),
            11,
            "PPACD inventory row must have 11 fields: {row:?}"
        );
        assert!(
            ids.insert(row[0].clone()),
            "duplicate PPACD inventory id {}",
            row[0]
        );
        assert!(row[0].starts_with("PPACD-INV-"));
        assert!(
            allowed_surfaces.contains(row[3].as_str()),
            "{} has unknown surface {}",
            row[0],
            row[3]
        );
        assert!(
            tracked.contains(&row[1]) || repo_path(&row[1]).exists(),
            "inventory path must be tracked or staged for tracking: {}",
            row[1]
        );
        for value in &row {
            assert!(
                !value.trim().is_empty()
                    && !value.contains("TODO")
                    && !value.contains("TBD")
                    && !value.contains("unclassified"),
                "invalid PPACD inventory field in row {:?}",
                row
            );
        }
        by_path.insert(row[1].clone(), row.clone());
        for id in row[10].split(',') {
            covered_rows.insert(id.to_owned());
        }
    }
    for row_id in 0..=10 {
        assert!(
            covered_rows.contains(&format!("PPACD-{row_id}")),
            "PPACD inventory does not cover PPACD-{row_id}"
        );
    }
    for required_path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_PATH,
        "packages/agent/src/transport/engine/contracts.rs",
        "packages/agent/src/transport/engine/socket/wire.rs",
        "packages/agent/src/engine/invocation/host/meta.rs",
        "packages/ios-app/Sources/Engine/Protocol/Core/EngineProtocolTypes.swift",
        "packages/ios-app/Sources/Engine/Transport/WebSocket/EngineConnectionProtocolFrames.swift",
        "packages/ios-app/Tests/Engine/Protocol/EngineProtocolTypesTests.swift",
    ] {
        assert!(
            by_path.contains_key(required_path),
            "PPACD inventory missing required path {required_path}"
        );
    }
}

#[test]
fn ppacd_wiring_is_present_in_readme_local_ci_and_github_ci() {
    let readme = read_repo_file("README.md");
    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_PATH,
        TARGET_NAME,
        "Public Protocol API Contract Discipline",
    ] {
        assert!(
            readme.contains(required),
            "README missing PPACD wiring text: {required}"
        );
    }

    let quality = read_repo_file("scripts/tron.d/quality.sh");
    assert!(
        quality.contains(TARGET_NAME),
        "local tron ci test target list missing {TARGET_NAME}"
    );

    let ci = read_repo_file(".github/workflows/ci.yml");
    assert!(
        ci.contains(&format!("cargo test --test {TARGET_NAME} -- --quiet")),
        "GitHub static-gates job missing {TARGET_NAME}"
    );
}

#[test]
fn public_engine_contracts_are_narrow_and_versioned() {
    let contracts = read_repo_file("packages/agent/src/transport/engine/contracts.rs");
    assert!(
        contracts.contains(
            "const PUBLIC_ENGINE_TRANSPORT_METHODS: &[&str] =\n    &[\"discover\", \"inspect\", \"watch\", \"invoke\", \"promote\"];"
        ),
        "public engine transport method set changed without PPACD review"
    );
    for forbidden in [
        "\"session.create\"",
        "\"session.list\"",
        "\"capability.execute\"",
        "\"worker::",
        "\"runtime::",
        "\"status\":{\"type\":\"string\"}",
    ] {
        assert!(
            !contracts.contains(forbidden),
            "public engine contracts expose stale or internal method/schema text: {forbidden}"
        );
    }
    for required in [
        "\"context\":{\"additionalProperties\":false",
        "\"parentInvocationId\":{\"type\":\"string\"}",
        "\"payload\":{\"additionalProperties\":true,\"type\":\"object\"}",
        ".response_schema(json!({\"additionalProperties\":false",
        "\"child\":{\"additionalProperties\":false",
        "\"required\":[\"child\"]",
    ] {
        assert!(
            contracts.contains(required),
            "public engine invoke schema missing strict token: {required}"
        );
    }
}

#[test]
fn public_context_and_child_response_do_not_expose_internal_runtime_metadata() {
    let wire = read_repo_file("packages/agent/src/transport/engine/socket/wire.rs");
    assert!(
        wire.contains("#[serde(rename_all = \"camelCase\", deny_unknown_fields)]"),
        "WireContext must deny unknown public context fields"
    );
    for forbidden in ["pub authority_scopes", "pub runtime_metadata"] {
        assert!(
            !wire.contains(forbidden),
            "public WireContext must not expose {forbidden}"
        );
    }

    let swift_types =
        read_repo_file("packages/ios-app/Sources/Engine/Protocol/Core/EngineProtocolTypes.swift");
    for forbidden in [
        "var authorityScopes:",
        "var runtimeMetadata:",
        "authorityScopes:",
        "runtimeMetadata:",
        "let workerId: String?",
        "let functionRevision: UInt64?",
        "let catalogRevision: UInt64?",
    ] {
        assert!(
            !swift_types.contains(forbidden),
            "iOS public protocol types must not expose {forbidden}"
        );
    }
    for required in [
        "var sessionId: String?",
        "var workspaceId: String?",
        "var traceId: String?",
        "var parentInvocationId: String?",
        "let replayedFrom: String?",
    ] {
        assert!(
            swift_types.contains(required),
            "iOS public protocol type missing public field: {required}"
        );
    }

    let meta = read_repo_file("packages/agent/src/engine/invocation/host/meta.rs");
    for forbidden in [
        "\"workerId\": result.worker_id.as_str()",
        "\"functionRevision\": result.function_revision.0",
        "\"catalogRevision\": result.catalog_revision.0",
    ] {
        assert!(
            !meta.contains(forbidden),
            "delegated child public response must not serialize {forbidden}"
        );
    }
    for required in [
        "\"invocationId\": result.invocation_id.as_str()",
        "\"functionId\": result.function_id.as_str()",
        "\"traceId\": result.trace_id.as_str()",
        "\"value\": result.value.as_ref()",
        "\"error\": result.error.as_ref().map(error_value)",
        "\"replayedFrom\": result.replayed_from.as_ref().map(InvocationId::as_str)",
    ] {
        assert!(
            meta.contains(required),
            "delegated child public response missing public token: {required}"
        );
    }
}

#[test]
fn ppacd_evidence_manifest_records_required_command_results() {
    let evidence = read_repo_file(EVIDENCE_PATH);
    assert!(evidence.contains("Status: **complete**"));
    assert!(evidence.contains("Current score: **100/100**"));
    for command in [
        "cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check",
        "cargo check --manifest-path packages/agent/Cargo.toml",
        "cargo test --manifest-path packages/agent/Cargo.toml transport::engine --lib -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml shared::protocol --lib -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml shared::server::error_mapping --lib -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml domains::session::event_store::types --lib -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test public_protocol_api_contract_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test data_integrity_storage_evolution_migration_discipline_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test observability_diagnostics_auditability_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test failure_semantics_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test determinism_replayability_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test hierarchical_rearchitecture_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test primitive_code_cleanup_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test true_primitive_cleanup_invariants -- --nocapture",
        "cargo test --manifest-path packages/agent/Cargo.toml --test off_plan_saa_authorship_teardown_cleanup_invariants -- --nocapture",
        "cd packages/ios-app && xcodegen generate",
        "only-testing:TronMobileTests/EngineProtocolBaseTypesTests",
        "only-testing:TronMobileTests/ProtocolConstantsTests",
        "only-testing:TronMobileTests/EngineClientErrorTests",
        "only-testing:TronMobileTests/ConnectionStateTests",
        "only-testing:TronMobileTests/EngineStreamScopeTests",
        "only-testing:TronMobileTests/ModelInfoTests",
        "cd packages/ios-app && git diff --exit-code -- TronMobile.xcodeproj",
        "scripts/tron ci fmt check clippy test",
        "scripts/personal-info-guard.sh",
        "git diff --check",
        "git ls-files -ci --exclude-standard",
        "git status --short",
    ] {
        assert!(
            evidence.contains(command),
            "PPACD evidence manifest missing command: {command}"
        );
    }
    for row in 0..=10 {
        assert!(
            evidence.contains(&format!("| PPACD-{row} | passed_after_fix |")),
            "PPACD evidence missing closed row PPACD-{row}"
        );
    }
}

#[test]
fn predecessor_inventories_classify_ppacd_artifacts() {
    let required_paths = [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_PATH,
    ];
    for predecessor in [
        "packages/agent/docs/primitive-code-cleanup-file-inventory.tsv",
        "packages/agent/docs/true-primitive-cleanup-retention-inventory.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv",
        "packages/agent/docs/security-authority-capability-boundaries-inventory.tsv",
        "packages/agent/docs/off-plan-saa-authorship-teardown-cleanup-inventory.tsv",
    ] {
        let source = read_repo_file(predecessor);
        for required_path in required_paths {
            assert!(
                source.contains(required_path),
                "{predecessor} missing PPACD artifact {required_path}"
            );
        }
    }
}
