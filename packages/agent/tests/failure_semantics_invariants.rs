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
        "Status: **active**",
        "Current score: **62/100**",
        "| FSC-0 | Campaign harness | 6 | passed_after_fix |",
        "| FSC-2 | Canonical envelope | 12 | passed_after_fix |",
        "| FSC-7 | Provider retry semantics | 8 | passed_after_fix |",
        "| FSC-9 | Observability and replay | 6 | passed_after_fix |",
        "| FSC-10 | Closeout gates | 10 | pending |",
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
        "Status: **active**",
        "## Canonical Vocabulary",
        "## Surface Inventory",
        "`shared::server::failure::FailureEnvelope`",
        "`shared::server::errors::CapabilityError`",
        "`engine::kernel::EngineError`",
        "`domains::model::providers::shared::ProviderError`",
        "`TronEvent::TurnFailed`",
        "`capability.invocation.completed`",
        "`/engine` WebSocket response errors",
        "## Open Loops",
    ] {
        assert!(
            inventory.contains(required),
            "FSC inventory missing required text: {required}"
        );
    }

    for required in [
        "# Failure Semantics Evidence Manifest",
        "Status: **active**",
        "Current score: **62/100**",
        "| FSC-0 | passed_after_fix |",
        "| FSC-2 | passed_after_fix |",
        "| FSC-7 | passed_after_fix |",
        "| FSC-9 | passed_after_fix |",
        "| FSC-10 | pending |",
        "## FSC-0 Findings",
        "## Server Core Checkpoint Findings",
        "## Durable Replay Checkpoint Findings",
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
fn failure_semantics_inventory_tsv_covers_initial_surfaces() {
    let inventory = read_repo_file("packages/agent/docs/failure-semantics-inventory.tsv");
    let mut rows = BTreeSet::new();

    for line in inventory.lines().skip(1) {
        let columns: Vec<&str> = line.split('\t').collect();
        assert!(
            columns.len() == 6,
            "inventory row must have path, language, surface, owner, current_gap, and fsc_rows columns: {line}"
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
        "packages/agent/src/shared/server/error_mapping.rs",
        "packages/agent/src/engine/kernel/errors.rs",
        "packages/agent/src/domains/model/providers/shared/provider.rs",
        "packages/agent/src/domains/model/responder/mod.rs",
        "packages/agent/src/domains/agent/loop/turn_runner/mod.rs",
        "packages/agent/src/domains/agent/loop/capability_invocation_executor/mod.rs",
        "packages/agent/src/transport/engine/socket/mod.rs",
        "packages/ios-app/Sources/Engine/Protocol/Core/EngineProtocolTypes.swift",
        "packages/ios-app/Sources/UI/Capabilities/Shared/ErrorClassification.swift",
    ] {
        assert!(
            rows.contains(required),
            "FSC inventory missing initial surface path: {required}"
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
