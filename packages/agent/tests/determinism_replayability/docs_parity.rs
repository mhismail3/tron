use super::support::*;

#[test]
fn drc_docs_and_protocol_parity_are_current() {
    let readme = read_repo_file("README.md");
    let ios_events = read_repo_file("packages/ios-app/docs/events.md");
    let ios_architecture = read_repo_file("packages/ios-app/docs/architecture.md");
    let protocol_mod = read_repo_file("packages/agent/src/shared/protocol/mod.rs");
    let model_audit = read_repo_file("packages/agent/src/shared/protocol/model_audit.rs");
    let session_mod = read_repo_file("packages/agent/src/domains/session/mod.rs");

    for required in [
        "engineIdempotencyEntries",
        "`resultHash` or `payloadHash`",
        "payload-fingerprint request hashes",
        "The replay manifest is a capability result, not a persisted event type",
        "cross-record replay references, offline roundtrip proof, docs parity",
    ] {
        assert!(
            readme.contains(required),
            "README replay parity docs missing required text: {required}"
        );
    }

    for required in [
        "DRC-9 replay manifest/event parity",
        "`model.provider_request` is a persisted metadata-only session event",
        "`replay_manifest` is not an event at all",
        "no iOS persisted event case or live plugin is required",
    ] {
        assert!(
            ios_events.contains(required),
            "iOS event docs missing required text: {required}"
        );
    }

    for required in [
        "DRC-9 replay manifest/event parity",
        "Replay exports remain server-owned",
        "not live or persisted iOS events",
        "metadata-only `model.provider_request` audit event",
    ] {
        assert!(
            ios_architecture.contains(required),
            "iOS architecture docs missing required text: {required}"
        );
    }

    assert!(
        protocol_mod.contains("Provider request audit DTOs consumed by replay manifests"),
        "protocol module docs must identify replay manifest audit ownership"
    );
    assert!(
        model_audit.contains("provider-audit section source for canonical replay manifests"),
        "model audit DTO docs must explain replay manifest provenance"
    );
    assert!(
        session_mod.contains("idempotency refs, and offline roundtrip harness"),
        "session progressive docs must mention replay idempotency refs and harness"
    );
}
