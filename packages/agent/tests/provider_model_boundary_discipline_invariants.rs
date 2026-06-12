//! Static invariants for the Provider / Model Boundary Discipline slice.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;

const SCORECARD_PATH: &str = "packages/agent/docs/provider-model-boundary-discipline-scorecard.md";
const EVIDENCE_PATH: &str =
    "packages/agent/docs/provider-model-boundary-discipline-evidence-manifest.md";
const INVENTORY_PATH: &str = "packages/agent/docs/provider-model-boundary-discipline-inventory.md";
const INVENTORY_TSV_PATH: &str =
    "packages/agent/docs/provider-model-boundary-discipline-inventory.tsv";
const TARGET_PATH: &str = "packages/agent/tests/provider_model_boundary_discipline_invariants.rs";
const TARGET_NAME: &str = "provider_model_boundary_discipline_invariants";

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

fn tracked_or_staged(path: &str) -> bool {
    repo_path(path).exists() || git_ls_files(path).iter().any(|tracked| tracked == path) || {
        let output = Command::new("git")
            .args(["diff", "--cached", "--name-only", "--", path])
            .current_dir(repo_root())
            .output()
            .expect("git diff --cached should run");
        output.status.success()
            && String::from_utf8(output.stdout)
                .expect("git output should be utf8")
                .lines()
                .any(|staged| staged == path)
    }
}

#[test]
fn pmbd_artifacts_and_static_gate_wiring_exist() {
    for path in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        TARGET_PATH,
    ] {
        assert!(
            repo_path(path).exists(),
            "required PMBD artifact missing: {path}"
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
            "README must mention PMBD artifact or target: {required}"
        );
    }

    for path in ["scripts/tron.d/quality.sh", ".github/workflows/ci.yml"] {
        let source = read_repo_file(path);
        assert!(
            source.contains(TARGET_NAME),
            "{path} must run PMBD invariant target"
        );
    }
}

#[test]
fn pmbd_scorecard_weights_sum_to_100_and_are_closed() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(scorecard.contains("Status: **complete**"));
    assert!(scorecard.contains("Current score: **100/100**"));
    assert!(scorecard.contains("Passing threshold: **100/100**"));
    assert!(scorecard.contains("codex/provider-model-boundary-discipline-current"));
    assert!(scorecard.contains("c7deea13d1bcb37b0348406329d503c043933ae6"));
    assert!(scorecard.contains("b11449319"));

    let rows: Vec<_> = scorecard
        .lines()
        .filter(|line| line.starts_with("| PMBD-"))
        .collect();
    assert_eq!(rows.len(), 11, "PMBD scorecard must contain PMBD-0..10");

    let mut total = 0_u32;
    for row in rows {
        let columns: Vec<_> = row.trim_matches('|').split('|').map(str::trim).collect();
        assert_eq!(columns.len(), 5, "invalid PMBD scorecard row: {row}");
        let weight: u32 = columns[2]
            .parse()
            .unwrap_or_else(|error| panic!("invalid PMBD weight in {row}: {error}"));
        assert_eq!(columns[3], "passed", "PMBD row must be passed: {row}");
        total += weight;
    }
    assert_eq!(total, 100, "PMBD scorecard weights must sum to 100");
}

#[test]
fn pmbd_inventory_is_structured_and_covers_required_surfaces() {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut lines = tsv.lines();
    assert_eq!(
        lines.next(),
        Some(
            "id\tpath\tsurface_kind\towner\tboundary_direction\tpublic_status\tprovider_specificity\tauth_secret_risk\tcanonical_contract\tproof_target\taction\trationale"
        ),
        "PMBD TSV header changed"
    );

    let rows: Vec<Vec<&str>> = lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| line.split('\t').collect())
        .collect();
    assert!(
        rows.len() >= 61,
        "PMBD inventory row count regressed: {}",
        rows.len()
    );

    let mut ids = BTreeSet::new();
    for row in &rows {
        assert_eq!(row.len(), 12, "PMBD row must have 12 fields: {row:?}");
        assert!(
            ids.insert(row[0]),
            "duplicate PMBD inventory id: {}",
            row[0]
        );
        assert!(
            row[0].starts_with("PMBD-INV-"),
            "PMBD inventory id must use PMBD-INV prefix: {}",
            row[0]
        );
        assert!(
            tracked_or_staged(row[1]),
            "PMBD inventory path must be tracked, staged, or present: {}",
            row[1]
        );
    }

    let inventory = read_repo_file(INVENTORY_PATH);
    for required in [
        "OpenAI",
        "Anthropic",
        "Google",
        "Kimi",
        "MiniMax",
        "Ollama",
        "ProviderAuditPayload",
        "StreamEvent",
        "FailureEnvelope",
    ] {
        assert!(
            inventory.contains(required) || tsv.contains(required),
            "PMBD inventory missing required provider/model surface: {required}"
        );
    }

    for required in [
        "packages/agent/src/domains/model/providers/shared/provider.rs",
        "packages/agent/src/domains/model/providers/factory/mod.rs",
        "packages/agent/src/domains/model/responder/mod.rs",
        "packages/agent/src/domains/model/protocol/capability_parsing.rs",
        "packages/agent/src/domains/model/protocol/id_remapping.rs",
        "packages/agent/src/domains/model/routing/models/registry.rs",
        "packages/agent/src/domains/model/tokens/normalization.rs",
        "packages/agent/src/domains/auth/credentials/mod.rs",
        "packages/agent/src/shared/protocol/model_audit.rs",
        "packages/agent/src/shared/foundation/redaction.rs",
    ] {
        assert!(tsv.contains(required), "PMBD inventory missing {required}");
    }
}

#[test]
fn provider_native_imports_stay_behind_provider_or_responder_boundaries() {
    let allowed_prefixes = [
        "packages/agent/src/domains/model/providers/",
        "packages/agent/src/domains/model/responder/",
        "packages/agent/src/domains/model/routing/",
        "packages/agent/src/domains/model/mod.rs",
        "packages/agent/src/app/bootstrap/tests/",
    ];

    for path in git_ls_files("packages/agent/src") {
        if !path.ends_with(".rs")
            || path.contains("/tests/")
            || path.ends_with("/tests.rs")
            || allowed_prefixes
                .iter()
                .any(|prefix| path.starts_with(prefix))
        {
            continue;
        }
        let source = read_repo_file(&path);
        for forbidden in [
            "domains::model::providers::",
            "ProviderError",
            "ProviderStreamOptions",
            "StreamRetryConfig",
        ] {
            assert!(
                !source.contains(forbidden),
                "{path} must not depend on provider-native boundary symbol `{forbidden}`"
            );
        }
    }
}

#[test]
fn provider_wire_markers_stay_confined_to_owned_boundaries() {
    let allowed_prefixes = [
        "packages/agent/src/domains/model/providers/",
        "packages/agent/src/domains/model/protocol/",
        "packages/agent/src/domains/model/routing/",
        "packages/agent/src/domains/model/tokens/",
        "packages/agent/src/domains/session/event_store/reconstruction/",
        "packages/agent/src/shared/protocol/events/",
        "packages/agent/src/shared/protocol/messages/",
        "packages/agent/src/shared/protocol/model_audit.rs",
        "packages/agent/src/shared/foundation/errors/parse.rs",
    ];
    let markers = [
        "anthropic-beta",
        "x-api-key",
        "/v1/responses",
        "/v1/messages",
        "function_call",
        "function_call_output",
        "\"tool_use\"",
        "\"tool_result\"",
        "generateContent",
        "streamGenerateContent",
        "chat/completions",
    ];

    for path in git_ls_files("packages/agent/src") {
        if !path.ends_with(".rs")
            || allowed_prefixes
                .iter()
                .any(|prefix| path.starts_with(prefix))
        {
            continue;
        }
        let source = read_repo_file(&path);
        for marker in markers {
            assert!(
                !source.contains(marker),
                "{path} contains provider wire marker `{marker}` outside owned boundary"
            );
        }
    }
}

#[test]
fn provider_audit_retry_and_failure_surfaces_are_redacted_and_bounded() {
    let audit = read_repo_file("packages/agent/src/shared/protocol/model_audit.rs");
    for required in [
        "MODEL_PROVIDER_REQUEST_AUDIT_FORMAT",
        "MAX_PROVIDER_AUDIT_PAYLOAD_BYTES",
        "ProviderAuditPayloadError::TooLarge",
        "redacted_and_bounded",
        "redact_sensitive_json",
    ] {
        assert!(audit.contains(required), "model audit missing {required}");
    }

    let responder = read_repo_file("packages/agent/src/domains/model/responder/mod.rs");
    assert!(
        responder.contains(".redacted_and_bounded()"),
        "model responder must validate provider audit payloads"
    );
    assert!(
        responder.contains("redact_sensitive_content(&message)")
            && responder.contains("redact_sensitive_content(&error.to_string())"),
        "model responder must redact provider-derived error text"
    );

    let retry = read_repo_file("packages/agent/src/domains/model/providers/shared/retry.rs");
    assert!(
        retry.contains("redact_sensitive_content(&err.to_string())"),
        "retry events must redact provider error strings"
    );

    let provider = read_repo_file("packages/agent/src/domains/model/providers/shared/provider.rs");
    assert!(
        provider
            .matches("redact_sensitive_content(message)")
            .count()
            >= 3,
        "provider error mapping must redact provider-native messages"
    );

    let event_store = read_repo_file(
        "packages/agent/src/domains/session/event_store/store/event_store/event_log.rs",
    );
    assert!(
        event_store.contains("redact_json_strings"),
        "event store append must keep recursive payload redaction"
    );
}

#[test]
fn provider_family_stream_and_catalog_tests_remain_present() {
    for (path, required) in [
        (
            "packages/agent/src/domains/model/providers/openai/stream_handler/tests.rs",
            "malformed_arguments_fails_closed",
        ),
        (
            "packages/agent/src/domains/model/providers/google/stream_handler.rs",
            "non_object_function_call_arguments_fail_closed",
        ),
        (
            "packages/agent/src/domains/model/providers/kimi/stream_handler/tests.rs",
            "malformed_capability_invocation_arguments_fail_closed",
        ),
        (
            "packages/agent/src/domains/model/providers/ollama/message_converter/tests.rs",
            "capability_invocation_arguments_serialize_as_object",
        ),
        (
            "packages/agent/src/domains/model/providers/anthropic/message_converter/tests.rs",
            "convert_assistant_capability_invocation_remaps_openai_id",
        ),
        (
            "packages/agent/src/domains/model/routing/models/registry.rs",
            "detect_family_prefix_gpt",
        ),
        (
            "packages/agent/src/domains/model/tokens/normalization.rs",
            "minimax_anthropic_compatible_context_window_adds_cache",
        ),
    ] {
        let source = read_repo_file(path);
        assert!(
            source.contains(required),
            "{path} missing PMBD proof anchor {required}"
        );
    }
}

#[test]
fn predecessor_inventory_rows_record_pmbd_as_current_original_slice() {
    for (path, required) in [
        (
            "packages/agent/docs/off-plan-saa-authorship-teardown-cleanup-inventory.tsv",
            "Provider / Model Boundary Discipline is original hardening after PPACD/OPSAA",
        ),
        (
            "packages/agent/docs/public-protocol-api-contract-discipline-inventory.tsv",
            "PMBD provider/model boundary artifacts extend PPACD public protocol hardening evidence",
        ),
        (
            "packages/agent/docs/primitive-code-cleanup-file-inventory.tsv",
            "Provider / Model Boundary Discipline",
        ),
        (
            "packages/agent/docs/true-primitive-cleanup-retention-inventory.tsv",
            "Provider / Model Boundary Discipline",
        ),
        (
            "packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv",
            "Provider / Model Boundary Discipline",
        ),
        (
            "packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv",
            "Provider / Model Boundary Discipline",
        ),
        (
            "packages/agent/docs/security-authority-capability-boundaries-inventory.tsv",
            "Provider / Model Boundary Discipline",
        ),
    ] {
        let source = read_repo_file(path);
        assert!(
            source.contains(required),
            "{path} missing PMBD predecessor inventory marker"
        );
    }
}
