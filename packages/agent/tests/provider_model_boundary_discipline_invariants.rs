//! Static invariants for the provider / model boundary discipline slice.

use std::path::{Path, PathBuf};

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

fn tracked_files_under(prefix: &str) -> Vec<String> {
    let output = std::process::Command::new("git")
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

#[test]
fn pmbd_artifacts_and_gate_wiring_exist() {
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
        assert!(source.contains(TARGET_NAME), "{path} must run PMBD");
    }
}

#[test]
fn pmbd_scorecard_is_closed_at_full_weight() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    assert!(scorecard.contains("Status: **closed**"));
    assert!(scorecard.contains("Current score: **100/100**"));
    assert!(scorecard.contains("Passing threshold: **100/100**"));

    let mut total = 0u32;
    for line in scorecard.lines() {
        if !line.starts_with("| PMBD-") {
            continue;
        }
        let columns: Vec<_> = line.split('|').map(str::trim).collect();
        let weight: u32 = columns
            .get(3)
            .unwrap_or_else(|| panic!("scorecard row missing weight: {line}"))
            .parse()
            .unwrap_or_else(|error| panic!("invalid PMBD weight in {line}: {error}"));
        assert!(
            columns.get(4).is_some_and(|status| *status == "passed"),
            "PMBD row must be passed at closeout: {line}"
        );
        total += weight;
    }
    assert_eq!(total, 100, "PMBD scorecard weights must sum to 100");
}

#[test]
fn pmbd_inventory_has_expected_header_and_boundary_rows() {
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let mut rows = tsv.lines();
    assert_eq!(
        rows.next(),
        Some(
            "id\tpath\tsurface_kind\towner\tboundary_direction\tpublic_status\tprovider_specificity\tauth_secret_risk\tcanonical_contract\tproof_target\taction\trationale"
        ),
        "PMBD TSV header changed"
    );

    for required in [
        "PMBD-INV-001\tpackages/agent/src/domains/model/mod.rs\tmodel_domain_root",
        "PMBD-INV-008\tpackages/agent/src/domains/model/responder/mod.rs\tmodel_responder_boundary",
        "PMBD-INV-016\tpackages/agent/src/shared/protocol/model_audit.rs\tprovider_audit_dto",
        "PMBD-INV-021\tpackages/agent/src/domains/model/providers/shared/provider.rs\tprovider_trait_error_options",
        "PMBD-INV-050\tpackages/agent/src/domains/model/providers/openai\topenai_provider_family",
        "PMBD-INV-065\tpackages/agent/src/domains/model/providers/anthropic\tanthropic_provider_family",
        "PMBD-INV-080\tpackages/agent/src/domains/model/providers/google\tgoogle_provider_family",
        "PMBD-INV-090\tpackages/agent/src/domains/model/providers/kimi\tkimi_provider_family",
        "PMBD-INV-100\tpackages/agent/src/domains/model/providers/minimax\tminimax_provider_family",
        "PMBD-INV-110\tpackages/agent/src/domains/model/providers/ollama\tollama_provider_family",
    ] {
        assert!(
            tsv.contains(required),
            "PMBD inventory missing required row: {required}"
        );
    }
}

#[test]
fn provider_native_imports_stay_behind_responder_or_provider_roots() {
    let allowed = [
        "packages/agent/src/domains/model/providers/",
        "packages/agent/src/domains/model/responder/mod.rs",
        "packages/agent/src/domains/model/routing/",
        "packages/agent/src/domains/model/mod.rs",
    ];
    for path in tracked_files_under("packages/agent/src") {
        if !path.ends_with(".rs")
            || path.contains("/tests/")
            || path.ends_with("/tests.rs")
            || allowed.iter().any(|prefix| path.starts_with(prefix))
        {
            continue;
        }
        let source = read_repo_file(&path);
        assert!(
            !source.contains("domains::model::providers::"),
            "{path} must not import provider-native modules outside the responder/provider composition boundary"
        );
        assert!(
            !source.contains("ProviderError"),
            "{path} must not depend on provider-native ProviderError"
        );
        assert!(
            !source.contains("ProviderStreamOptions"),
            "{path} must not depend on provider-native stream options"
        );
    }
}

#[test]
fn provider_wire_names_stay_confined_to_owned_boundaries() {
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
    for path in tracked_files_under("packages/agent/src") {
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
                "{path} contains provider wire marker `{marker}` outside an owned boundary"
            );
        }
    }
}

#[test]
fn provider_error_retry_and_audit_surfaces_are_redacted_and_bounded() {
    let audit = read_repo_file("packages/agent/src/shared/protocol/model_audit.rs");
    for required in [
        "MAX_PROVIDER_AUDIT_PAYLOAD_BYTES",
        "redacted_and_bounded",
        "redact_sensitive_json",
        "ProviderAuditPayloadError::TooLarge",
    ] {
        assert!(audit.contains(required), "model audit missing {required}");
    }

    let responder = read_repo_file("packages/agent/src/domains/model/responder/mod.rs");
    assert!(
        responder.contains(".redacted_and_bounded()"),
        "model responder must validate provider audit payloads before persistence"
    );
    assert!(
        responder.contains("redact_sensitive_content(&error.to_string())"),
        "model responder provider-error logs must be redacted"
    );

    let retry = read_repo_file("packages/agent/src/domains/model/providers/shared/retry.rs");
    assert!(
        retry.contains("redact_sensitive_content(&err.to_string())"),
        "retry events must redact provider error text"
    );

    let provider = read_repo_file("packages/agent/src/domains/model/providers/shared/provider.rs");
    assert!(
        provider
            .matches("redact_sensitive_content(message)")
            .count()
            >= 3,
        "provider error to_failure must redact provider-native messages"
    );
}

#[test]
fn provider_factory_remains_the_auth_custody_composition_root() {
    let factory = read_repo_file("packages/agent/src/domains/model/providers/factory/mod.rs");
    for required in [
        "auth_path: PathBuf",
        "load_server_auth_with_client",
        "create_for_model_with_credential",
        "detect_provider_from_model(model)",
        "strip_provider_prefix(model)",
        "OpenAIAuthPath::ChatGptCodex",
        "OpenAIAuthPath::PlatformApiKey",
        "ProviderError::UnsupportedModel",
    ] {
        assert!(
            factory.contains(required),
            "provider factory missing custody/routing boundary text: {required}"
        );
    }
}
