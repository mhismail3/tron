use super::support::read_repo_file;

#[test]
fn sacb_pairing_lifecycle_boundaries_are_hardened() {
    let ios_parser =
        read_repo_file("packages/ios-app/Sources/Support/Pairing/PairingURLParser.swift");
    for required in [
        "enum PairingHostValidator",
        "case invalidHost(String)",
        "PairingHostValidator.canonicalHost(host)",
        "!trimmed.contains(\"://\")",
        "CharacterSet(charactersIn: \"/\\\\?#@[]\")",
        "isValidIPv6",
        "UInt8($0) != nil",
    ] {
        assert!(
            ios_parser.contains(required),
            "iOS pairing parser missing host lifecycle guard: {required}"
        );
    }

    let ios_validator = read_repo_file(
        "packages/ios-app/Sources/Support/Pairing/Onboarding/PairingStepValidator.swift",
    );
    for required in [
        "case invalidHost(String)",
        "PairingHostValidator.canonicalHost(trimmedHost)",
        "Host must be a Tailscale IP or hostname, not a full URL.",
    ] {
        assert!(
            ios_validator.contains(required),
            "iOS pairing validator missing manual-host guard: {required}"
        );
    }

    let ios_persistor = read_repo_file(
        "packages/ios-app/Sources/Support/Pairing/Onboarding/PairingPersistor.swift",
    );
    for required in [
        "enum RollbackTokenAction",
        "struct RollbackPlan",
        "static func rollbackPlan(",
        "PairingHostValidator.canonicalHost(payload.host)",
        "preconditionFailure(\"PairingPersistor requires a validated pairing host\")",
        "previousToken.map(RollbackTokenAction.restore) ?? .remove",
    ] {
        assert!(
            ios_persistor.contains(required),
            "iOS pairing persistor missing commit/rollback guard: {required}"
        );
    }

    let pairing_step =
        read_repo_file("packages/ios-app/Sources/UI/Onboarding/Steps/PairingStep.swift");
    assert!(
        pairing_step.contains("PairingPersistor.rollbackPlan(")
            && !pairing_step.contains("try? dependencies.pairedServerTokenStore"),
        "PairingStep must use explicit rollback planning without swallowing token-store failures"
    );

    let dependency_container =
        read_repo_file("packages/ios-app/Sources/Support/Composition/DependencyContainer.swift");
    assert!(
        dependency_container.contains("func forgetPairedServer(_ server: PairedServer) throws")
            && dependency_container
                .contains("try pairedServerTokenStore.remove(serverId: server.id)")
            && !dependency_container
                .contains("try? pairedServerTokenStore.remove(serverId: server.id)"),
        "forgetting a paired server must remove the Keychain token first and fail closed"
    );

    let mac_builder =
        read_repo_file("packages/mac-app/Sources/Support/Pairing/PairingURLBuilder.swift");
    for required in [
        "enum PairingHostValidator",
        "PairingHostValidator.canonicalHost(payload.host)",
        "PairingHostValidator.canonicalHost(host)",
        "(1...65_535).contains(payload.port)",
        "(1...65_535).contains(port)",
        "!trimmed.contains(\"://\")",
        "CharacterSet(charactersIn: \"/\\\\?#@[]\")",
    ] {
        assert!(
            mac_builder.contains(required),
            "Mac pairing URL builder missing iOS-parity guard: {required}"
        );
    }

    let ios_source_guard = read_repo_file(
        "packages/ios-app/Tests/Infrastructure/Guards/SourceGuardTests+BuildAndProject.swift",
    );
    assert!(
        ios_source_guard.contains("testPairingLifecycleBoundaries"),
        "iOS source guards must pin pairing lifecycle boundaries"
    );

    let ios_parser_tests =
        read_repo_file("packages/ios-app/Tests/Support/Pairing/PairingURLParserTests.swift");
    for required in [
        "rejectsURLShapedHostValue",
        "rejectsHostFragments",
        "rejectsInvalidIPAndDNSHosts",
        "makeURLRejectsMalformedRequiredFields",
    ] {
        assert!(
            ios_parser_tests.contains(required),
            "iOS parser tests missing pairing regression: {required}"
        );
    }

    let ios_validator_tests =
        read_repo_file("packages/ios-app/Tests/Support/Pairing/PairingValidationTests.swift");
    for required in ["urlShapedHost", "pathOrQueryHost"] {
        assert!(
            ios_validator_tests.contains(required),
            "iOS validator tests missing pairing regression: {required}"
        );
    }

    let ios_persistor_tests =
        read_repo_file("packages/ios-app/Tests/Support/Pairing/PairingPersistorTests.swift");
    for required in [
        "directPayloadValuesCanonicalized",
        "rollbackNewServerRemovesCandidateToken",
        "rollbackExistingServerRestoresPreviousToken",
    ] {
        assert!(
            ios_persistor_tests.contains(required),
            "iOS persistor tests missing pairing regression: {required}"
        );
    }

    let dependency_tests =
        read_repo_file("packages/ios-app/Tests/Support/Composition/DependencyContainerTests.swift");
    assert!(
        dependency_tests.contains("test_forgetPairedServer_removesTokenBeforeMetadataCompletes"),
        "DependencyContainer tests must prove forget removes Keychain token and metadata"
    );

    let mac_builder_tests =
        read_repo_file("packages/mac-app/Tests/Support/Pairing/PairingURLBuilderTests.swift");
    for required in [
        "portBoundaries",
        "parseRejectsOutOfRangePort",
        "ipv6HostAccepted",
        "malformedHostsRejected",
        "parseRejectsURLShapedHost",
    ] {
        assert!(
            mac_builder_tests.contains(required),
            "Mac pairing URL builder tests missing regression: {required}"
        );
    }
}

#[test]
fn sacb_internal_invoke_scope_is_trusted_runtime_only() {
    let policy = read_repo_file("packages/agent/src/engine/kernel/policy.rs");
    for required in [
        "has_trusted_internal_invoke_scope(ctx)",
        "ctx.has_scope(ENGINE_INTERNAL_INVOKE_SCOPE)",
        "ActorKind::System | ActorKind::Worker | ActorKind::Queue | ActorKind::Cron",
        "public clients, users, and agent contexts remain denied",
    ] {
        assert!(
            policy.contains(required),
            "internal invoke policy missing trusted-runtime guard text: {required}"
        );
    }

    let transport = read_repo_file("packages/agent/src/transport/engine/mod.rs");
    assert!(
        !transport.contains("ENGINE_INTERNAL_INVOKE_SCOPE")
            && !transport.contains("\"engine.internal.invoke\""),
        "public engine transport must not mint engine.internal.invoke"
    );

    let prompt = read_repo_file("packages/agent/src/domains/agent/prompt/prompt.rs");
    for required in [
        "trusted_agent_internal_child_context",
        "system:agent-runtime",
        "AuthorityGrantId::new(\"engine-system\")",
        "ENGINE_INTERNAL_INVOKE_SCOPE.to_owned()",
    ] {
        assert!(
            prompt.contains(required),
            "agent hidden prompt delegation must use engine-owned internal context: {required}"
        );
    }
}
