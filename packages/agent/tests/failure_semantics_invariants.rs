//! Static gates for the Failure Semantics Campaign.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::process::Command;

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

fn tracked_files() -> Vec<String> {
    let output = Command::new("git")
        .arg("ls-files")
        .current_dir(repo_root())
        .output()
        .expect("git ls-files should run in repository tests");
    assert!(
        output.status.success(),
        "git ls-files failed with status {:?}",
        output.status.code()
    );
    String::from_utf8(output.stdout)
        .expect("git ls-files output should be UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

#[test]
fn failure_semantics_campaign_harness_exists() {
    let scorecard = read_repo_file("packages/agent/docs/failure-semantics-scorecard.md");
    let inventory = read_repo_file("packages/agent/docs/failure-semantics-inventory.md");
    let manifest = read_repo_file("packages/agent/docs/failure-semantics-evidence-manifest.md");
    let readme = read_repo_file("README.md");

    for required in [
        "# Failure Semantics Campaign Scorecard",
        "Status: **closed/verified**",
        "Current score: **100/100**",
        "| FSC-0 | Campaign harness | 6 | passed_after_fix |",
        "| FSC-1 | Failure inventory | 8 | passed_after_fix |",
        "| FSC-2 | Canonical envelope | 12 | passed_after_fix |",
        "| FSC-3 | Error mapping matrix | 12 | passed_after_fix |",
        "| FSC-7 | Provider retry semantics | 8 | passed_after_fix |",
        "| FSC-8 | iOS parity | 8 | passed_after_fix |",
        "| FSC-9 | Observability and replay | 6 | passed_after_fix |",
        "| FSC-10 | Closeout gates | 10 | passed_after_fix |",
        "`packages/agent/docs/failure-semantics-inventory.tsv`",
        "`packages/agent/tests/failure_semantics_invariants.rs`",
    ] {
        assert!(
            scorecard.contains(required),
            "FSC scorecard missing required text: {required}"
        );
    }

    for required in [
        "# Failure Semantics Inventory",
        "Status: **closed/verified**",
        "## Canonical Vocabulary",
        "## Surface Inventory",
        "`shared::server::failure::FailureEnvelope`",
        "`shared::server::errors::CapabilityError`",
        "`engine::kernel::EngineError`",
        "`domains::model::providers::shared::ProviderError`",
        "`TronEvent::TurnFailed`",
        "`capability.invocation.completed`",
        "`/engine` WebSocket response errors",
        "## Closeout Notes",
    ] {
        assert!(
            inventory.contains(required),
            "FSC inventory missing required text: {required}"
        );
    }

    for required in [
        "# Failure Semantics Evidence Manifest",
        "Status: **closed/verified**",
        "Current score: **100/100**",
        "| FSC-0 | passed_after_fix |",
        "| FSC-1 | passed_after_fix |",
        "| FSC-2 | passed_after_fix |",
        "| FSC-3 | passed_after_fix |",
        "| FSC-7 | passed_after_fix |",
        "| FSC-8 | passed_after_fix |",
        "| FSC-9 | passed_after_fix |",
        "| FSC-10 | passed_after_fix |",
        "## FSC-0 Findings",
        "## Server Core Checkpoint Findings",
        "## Error Mapping Closeout Findings",
        "## Inventory Closeout Findings",
        "## Durable Replay Checkpoint Findings",
        "## iOS Parity Checkpoint Findings",
        "## Closeout Gate Findings",
        "## Verification Log",
    ] {
        assert!(
            manifest.contains(required),
            "FSC evidence manifest missing required text: {required}"
        );
    }

    for required in [
        "packages/agent/docs/failure-semantics-scorecard.md",
        "packages/agent/docs/failure-semantics-evidence-manifest.md",
        "packages/agent/docs/failure-semantics-inventory.md",
        "packages/agent/docs/failure-semantics-inventory.tsv",
        "packages/agent/tests/failure_semantics_invariants.rs",
    ] {
        assert!(
            readme.contains(required),
            "README living-doc map must link {required}"
        );
    }
}

#[test]
fn failure_semantics_closeout_artifacts_have_no_stale_status() {
    let scorecard = read_repo_file("packages/agent/docs/failure-semantics-scorecard.md");
    let inventory = read_repo_file("packages/agent/docs/failure-semantics-inventory.md");
    let manifest = read_repo_file("packages/agent/docs/failure-semantics-evidence-manifest.md");
    let tsv = read_repo_file("packages/agent/docs/failure-semantics-inventory.tsv");

    assert!(scorecard.contains("Current score: **100/100**"));
    assert!(manifest.contains("Current score: **100/100**"));
    assert!(scorecard.contains("Status: **closed/verified**"));
    assert!(inventory.contains("Status: **closed/verified**"));
    assert!(manifest.contains("Status: **closed/verified**"));
    assert!(scorecard.contains("| FSC-10 | Closeout gates | 10 | passed_after_fix |"));
    assert!(manifest.contains("| FSC-10 | passed_after_fix |"));
    assert!(inventory.contains("## Closeout Notes"));
    assert!(tsv.starts_with("path\tlanguage\tsurface\towner\tcurrent_state\tfsc_rows\n"));

    for (name, content) in [
        ("scorecard", scorecard.as_str()),
        ("inventory", inventory.as_str()),
        ("manifest", manifest.as_str()),
        ("inventory_tsv", tsv.as_str()),
    ] {
        for forbidden in [
            "Current score: **90/100**",
            "Status: **active**",
            "open-loop ledger",
            "| `packages/agent/docs/failure-semantics-scorecard.md` | active |",
            "| `packages/agent/docs/failure-semantics-inventory.md` | active |",
            "| `packages/agent/docs/failure-semantics-inventory.tsv` | active |",
            "| `packages/agent/docs/failure-semantics-evidence-manifest.md` | active |",
            "remaining\n  `TronEvent::TurnFailed`",
            "remaining `TronEvent::Error`",
            "| FSC-10 | pending |",
            "Not started.",
            "Implementation rows remain",
            "final stale-doc enforcement moves",
            "Add final static",
            "Durable payload enrichment remains",
            "Durable replay/export enrichment remains",
            "## Open Loops",
            "current_gap",
        ] {
            assert!(
                !content.contains(forbidden),
                "{name} contains stale failure-semantics closeout marker: {forbidden}"
            );
        }
    }
}

#[test]
fn failure_semantics_inventory_tsv_covers_initial_surfaces() {
    let inventory = read_repo_file("packages/agent/docs/failure-semantics-inventory.tsv");
    let mut rows = BTreeSet::new();

    for line in inventory.lines().skip(1) {
        let columns: Vec<&str> = line.split('\t').collect();
        assert!(
            columns.len() == 6,
            "inventory row must have path, language, surface, owner, current_state, and fsc_rows columns: {line}"
        );
        assert!(
            repo_path(columns[0]).exists(),
            "inventory path must exist: {}",
            columns[0]
        );
        assert!(
            !columns[2].trim().is_empty()
                && !columns[3].trim().is_empty()
                && !columns[4].trim().is_empty()
                && !columns[5].trim().is_empty(),
            "inventory row must classify surface, owner, gap, and rows: {line}"
        );
        let inserted = rows.insert(columns[0].to_owned());
        assert!(inserted, "duplicate inventory path: {}", columns[0]);
    }

    for required in [
        "packages/agent/src/shared/server/errors.rs",
        "packages/agent/src/shared/server/failure.rs",
        "packages/agent/src/shared/server/error_mapping/mod.rs",
        "packages/agent/src/engine/kernel/errors.rs",
        "packages/agent/src/domains/model/providers/shared/provider.rs",
        "packages/agent/src/domains/model/responder/mod.rs",
        "packages/agent/src/domains/agent/loop/turn_runner/mod.rs",
        "packages/agent/src/domains/agent/loop/capability_invocation_executor/mod.rs",
        "packages/agent/src/transport/engine/socket/mod.rs",
        "packages/ios-app/Sources/Engine/Protocol/Core/FailurePayload.swift",
        "packages/ios-app/Sources/Engine/Protocol/Core/EngineProtocolTypes.swift",
        "packages/ios-app/Sources/UI/Capabilities/Shared/ErrorClassification.swift",
    ] {
        assert!(
            rows.contains(required),
            "FSC inventory missing initial surface path: {required}"
        );
    }

    for forbidden in [
        "without_envelope",
        "no_failure_envelope_field",
        "string_only",
        "auth_session_event_tests_pending",
        "fallback",
        "legacy",
    ] {
        assert!(
            !inventory.contains(forbidden),
            "inventory TSV contains stale failure-semantics gap marker: {forbidden}"
        );
    }
}

#[test]
fn failure_semantics_server_core_uses_canonical_envelope() {
    let failure = read_repo_file("packages/agent/src/shared/server/failure.rs");
    for required in [
        "pub struct FailureEnvelope",
        "pub enum FailureCategory",
        "pub enum FailureOrigin",
        "pub fn details_with_failure",
        "PROVIDER_RATE_LIMITED",
        "CAPABILITY_PRIMITIVE_NOT_FOUND",
    ] {
        assert!(
            failure.contains(required),
            "canonical failure contract missing {required}"
        );
    }

    let model_capabilities =
        read_repo_file("packages/agent/src/shared/protocol/model_capabilities.rs");
    assert!(
        model_capabilities.contains("pub fn failure_result"),
        "capability results must expose the canonical failure-result helper"
    );
    assert!(
        !model_capabilities.contains("error_result"),
        "text-only capability error_result helper must not return"
    );

    let event_factory = read_repo_file("packages/agent/src/shared/protocol/events/factory.rs");
    assert!(
        event_factory.matches("details_with_failure").count() >= 2,
        "turn-failed and error event builders must embed the canonical envelope"
    );

    for path in [
        "packages/agent/src/domains/agent/loop/turn_runner/mod.rs",
        "packages/agent/src/domains/agent/runtime/service/agent_build.rs",
        "packages/agent/src/domains/agent/runtime/service/completion.rs",
    ] {
        let source = read_repo_file(path);
        assert!(
            !source.contains("TronEvent::TurnFailed"),
            "runtime production path must use turn_failed_event builder: {path}"
        );
        assert!(
            !source.contains("TronEvent::Error"),
            "runtime production path must use error_event builder: {path}"
        );
    }

    let socket = read_repo_file("packages/agent/src/transport/engine/socket/mod.rs");
    assert!(
        socket.contains(".to_failure(FailureOrigin::Transport)"),
        "engine socket errors must serialize canonical failure envelopes"
    );
    assert!(
        socket.contains(".with_trace_id(trace_id.clone())")
            && socket.contains("\"error\": failure.to_value()")
            && socket.contains("\"traceId\": trace_id"),
        "engine socket error frames must expose the canonical envelope and trace id"
    );

    let responder = read_repo_file("packages/agent/src/domains/model/responder/mod.rs");
    assert!(
        responder.contains("fn from_provider_stream_event_error")
            && responder.contains("PROVIDER_SSE_PARSE_ERROR")
            && !responder.contains("impl From<ProviderError> for ModelResponseError")
            && !responder.contains("modelResponderFallback"),
        "model responder must preserve provider/model failure context without unknown fallback conversion"
    );

    let stream_state = read_repo_file("packages/agent/src/domains/agent/loop/stream_state.rs");
    assert!(
        !stream_state.contains("RuntimeError::Internal(error)")
            && stream_state
                .contains("provider stream error event escaped model responder boundary"),
        "stream state must not propagate provider stream error text as string-only internal failure"
    );

    let replay = read_repo_file("packages/agent/src/domains/session/replay/mod.rs");
    assert!(
        replay.contains("engine_error_replay_details")
            && !replay.contains("engine_error_legacy_details"),
        "replay failure diagnostics must not be named as legacy compatibility details"
    );
}

#[test]
fn failure_semantics_closeout_rejects_unapproved_runtime_failure_construction() {
    let allowed_turn_failed: BTreeSet<&str> = BTreeSet::from([
        "packages/agent/src/shared/protocol/events/factory.rs",
        "packages/agent/src/transport/runtime/streams/turn.rs",
    ]);
    let allowed_error: BTreeSet<&str> = BTreeSet::from([
        "packages/agent/src/shared/protocol/events/factory.rs",
        "packages/agent/src/transport/runtime/streams/session/agent.rs",
    ]);

    for path in tracked_files().into_iter().filter(|path| {
        path.starts_with("packages/agent/src/")
            && path.ends_with(".rs")
            && !path.contains("/tests/")
    }) {
        let source = read_repo_file(&path);
        assert!(
            !source.contains("error_result"),
            "production Rust source must not reintroduce text-only capability errors: {path}"
        );
        if source.contains("TronEvent::TurnFailed") {
            assert!(
                allowed_turn_failed.contains(path.as_str()),
                "unapproved direct TronEvent::TurnFailed construction: {path}"
            );
        }
        if source.contains("TronEvent::Error") {
            assert!(
                allowed_error.contains(path.as_str()),
                "unapproved direct TronEvent::Error construction: {path}"
            );
        }
    }
}

#[test]
fn failure_semantics_error_mapping_matrix_covers_auth_session_event_store() {
    let errors = read_repo_file("packages/agent/src/shared/server/errors.rs");
    for required in [
        "pub const SESSION_NOT_FOUND",
        "pub const EVENT_NOT_FOUND",
        "pub const WORKSPACE_NOT_FOUND",
        "pub const BLOB_NOT_FOUND",
        "pub const EVENT_STORE_BUSY",
        "pub const EVENT_STORE_FAILURE",
        "pub const AUTH_NOT_CONFIGURED",
        "pub const AUTH_TOKEN_EXPIRED",
        "pub const AUTH_OAUTH_ERROR",
        "pub const AUTH_STORAGE_ERROR",
        "pub const AUTH_TRANSPORT_ERROR",
        "EVENT_STORE_BUSY => FailureCategory::Unavailable",
        "AUTH_TRANSPORT_ERROR => FailureCategory::Network",
        "EVENT_STORE_FAILURE => FailureCategory::Persistence",
    ] {
        assert!(
            errors.contains(required),
            "server error contract missing mapped code/category coverage: {required}"
        );
    }

    let mapping = read_repo_file("packages/agent/src/shared/server/error_mapping/mod.rs");
    let mapping_tests = read_repo_file("packages/agent/src/shared/server/error_mapping/tests.rs");
    let mapping_with_tests = format!("{mapping}\n{mapping_tests}");
    let engine_errors = read_repo_file("packages/agent/src/engine/kernel/errors.rs");
    for variant in [
        "InvalidId",
        "InvalidFunctionId",
        "NotFound",
        "OwnerMismatch",
        "NamespaceDenied",
        "UnsupportedDeliveryMode",
        "DeliveryModeNotAllowed",
        "IdempotencyConflict",
        "LedgerFailure",
        "StoredInvocationError",
        "InvalidSchema",
        "SchemaViolation",
        "InvalidVisibilityPromotion",
        "PolicyViolation",
        "NotRoutable",
        "DomainFailure",
        "WorkerTransportFailure",
        "HandlerFailed",
    ] {
        assert!(
            engine_errors.contains(variant) && mapping.contains(&format!("EngineError::{variant}")),
            "EngineError variant must be represented in engine_error_to_failure: {variant}"
        );
    }

    for required in [
        "E::SessionNotFound(id) => CapabilityError::from_failure",
        "E::EventNotFound(id) => CapabilityError::from_failure",
        "E::WorkspaceNotFound(id) => CapabilityError::from_failure",
        "E::BlobNotFound(id) => CapabilityError::from_failure",
        "E::Busy",
        "codes::EVENT_STORE_BUSY",
        "event_store_internal_failure",
        "codes::EVENT_STORE_FAILURE",
        "A::NotConfigured(provider) => CapabilityError::from_failure",
        "A::TokenExpired(message) => CapabilityError::from_failure",
        "A::OAuth { status, message }",
        "codes::AUTH_OAUTH_ERROR",
        "A::MalformedProviderAuth { provider, details }",
        "A::MalformedAuthFile { details, .. }",
        "codes::AUTH_STORAGE_ERROR",
        "A::Http(error)",
        "codes::AUTH_TRANSPORT_ERROR",
    ] {
        assert!(
            mapping.contains(required),
            "error mapping matrix missing canonical branch: {required}"
        );
    }
    assert!(
        !mapping.contains("Malformed auth file at '{path}'"),
        "auth-file mapping must not leak local paths in public failure messages"
    );

    for required_test in [
        "every_engine_error_variant_has_stable_failure_mapping",
        "event_store_busy_is_retryable_unavailable",
        "event_store_internal_errors_preserve_persistence_failure",
        "auth_oauth_transient_status_is_retryable",
        "auth_malformed_auth_file_is_sanitized_storage_error",
    ] {
        assert!(
            mapping_with_tests.contains(required_test),
            "error mapping tests missing coverage marker: {required_test}"
        );
    }
}

#[test]
fn failure_semantics_ios_uses_canonical_failure_payload() {
    let failure_payload =
        read_repo_file("packages/ios-app/Sources/Engine/Protocol/Core/FailurePayload.swift");
    for required in [
        "struct CanonicalFailurePayload",
        "let retryable: Bool",
        "let recoverable: Bool",
        "static func fromDetails",
        "details?.anyCodableDict(\"failure\")",
    ] {
        assert!(
            failure_payload.contains(required),
            "iOS canonical failure payload missing {required}"
        );
    }

    let protocol_types =
        read_repo_file("packages/ios-app/Sources/Engine/Protocol/Core/EngineProtocolTypes.swift");
    assert!(
        protocol_types.contains("init(failure: CanonicalFailurePayload)")
            && protocol_types.contains("let category: String")
            && protocol_types.contains("let origin: String"),
        "iOS engine protocol errors must decode the canonical envelope"
    );
    for required_code in [
        "case eventStoreBusy = \"EVENT_STORE_BUSY\"",
        "case eventStoreFailure = \"EVENT_STORE_FAILURE\"",
        "case authStorageError = \"AUTH_STORAGE_ERROR\"",
        "case authTransportError = \"AUTH_TRANSPORT_ERROR\"",
    ] {
        assert!(
            protocol_types.contains(required_code),
            "iOS engine error-code enum missing server mapping code: {required_code}"
        );
    }

    let requests = read_repo_file(
        "packages/ios-app/Sources/Engine/Transport/WebSocket/EngineConnection+Requests.swift",
    );
    assert!(
        requests.contains("guard let failure = error.failure")
            && !requests.contains("\"ENGINE_ERROR\""),
        "child engine errors must require details.failure instead of local fallback codes"
    );

    let error_plugin = read_repo_file(
        "packages/ios-app/Sources/Engine/Events/Plugins/Lifecycle/ErrorPlugin.swift",
    );
    assert!(
        error_plugin.contains("static let eventType = \"error\"")
            && error_plugin
                .contains("guard let failure = CanonicalFailurePayload.fromDetails(data.details)")
            && !error_plugin.contains("failure?.code ?? data.code")
            && !error_plugin.contains("failure?.message ??")
            && !error_plugin.contains("\"UNKNOWN\"")
            && !error_plugin.contains("\"Unknown error\""),
        "live iOS error plugin must consume canonical failure data without placeholder defaults"
    );

    let turn_failed = read_repo_file(
        "packages/ios-app/Sources/Engine/Events/Plugins/Lifecycle/TurnFailedPlugin.swift",
    );
    assert!(
        turn_failed.contains("guard let turn = data.turn")
            && turn_failed
                .contains("let failure = CanonicalFailurePayload.fromDetails(data.details)")
            && !turn_failed.contains("failure?.message ??")
            && !turn_failed.contains("?? 0")
            && !turn_failed.contains("?? false"),
        "live iOS turn failure plugin must not invent turn or recoverability defaults"
    );

    let error_classification =
        read_repo_file("packages/ios-app/Sources/UI/Capabilities/Shared/ErrorClassification.swift");
    assert!(
        error_classification.contains("server-provided")
            && !error_classification.contains("enum ")
            && !error_classification.contains("switch "),
        "iOS capability error display must not define a separate failure taxonomy"
    );
}

#[test]
fn failure_semantics_durable_replay_preserves_failure_envelopes() {
    let turn_payload =
        read_repo_file("packages/agent/src/domains/session/event_store/types/payloads/turn.rs");
    for required in [
        "pub retryable: Option<bool>",
        "pub origin: Option<String>",
        "pub details: Option<Value>",
    ] {
        assert!(
            turn_payload.contains(required),
            "durable turn.failed payload missing {required}"
        );
    }

    let error_payload =
        read_repo_file("packages/agent/src/domains/session/event_store/types/payloads/error.rs");
    for required in [
        "pub details: Option<Value>",
        "pub retry_after_ms: Option<u64>",
    ] {
        assert!(
            error_payload.contains(required),
            "durable error payloads missing {required}"
        );
    }

    let completion =
        read_repo_file("packages/agent/src/domains/agent/runtime/service/completion.rs");
    assert!(
        completion.contains("failure.details_with_failure()"),
        "interrupted durable turn.failed writer must persist details.failure"
    );

    let replay = read_repo_file("packages/agent/src/domains/session/replay/mod.rs");
    assert!(
        replay.contains("engine_error_to_failure(error)")
            && replay.contains(".details_with_failure()"),
        "replay engine invocation errors must export canonical failure envelopes"
    );
}

#[test]
fn failure_semantics_campaign_artifacts_are_tracked() {
    let tracked: BTreeSet<String> = tracked_files().into_iter().collect();
    for required in [
        "packages/agent/docs/failure-semantics-scorecard.md",
        "packages/agent/docs/failure-semantics-inventory.md",
        "packages/agent/docs/failure-semantics-evidence-manifest.md",
        "packages/agent/docs/failure-semantics-inventory.tsv",
        "packages/agent/tests/failure_semantics_invariants.rs",
    ] {
        assert!(
            tracked.contains(required) || repo_path(required).exists(),
            "FSC artifact should exist and be staged before commit: {required}"
        );
    }
}
