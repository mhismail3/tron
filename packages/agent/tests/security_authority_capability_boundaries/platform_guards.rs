use super::support::read_repo_file;

#[test]
fn sacb_secret_storage_and_redaction_boundaries_are_hardened() {
    let auth_storage = read_repo_file("packages/agent/src/domains/auth/credentials/storage/mod.rs");
    for required in [
        "load_or_init_for_write(path)?",
        "save_auth_storage(path, &mut storage)",
        "atomic_write_0600(parent, path, &json)",
        "tempfile_in(parent)",
        "tmp.as_file().sync_all()?",
        "persist(final_path)",
        "Permissions::from_mode(0o600)",
    ] {
        assert!(
            auth_storage.contains(required),
            "auth storage missing secure custody text: {required}"
        );
    }

    let onboarding = read_repo_file("packages/agent/src/app/lifecycle/onboarding/mod.rs");
    for required in [
        "const TOKEN_BYTE_LEN: usize = 32",
        "general_purpose::URL_SAFE_NO_PAD.encode(bytes)",
        "storage.bearer_token = Some(token.clone())",
        "save_auth_storage(path, &mut storage)",
        "load_or_create_refuses_and_preserves_malformed_non_empty_file",
        "write_token_sets_mode_0o600",
    ] {
        assert!(
            onboarding.contains(required),
            "bearer token lifecycle missing secure custody text: {required}"
        );
    }

    let redaction = read_repo_file("packages/agent/src/domains/session/event_store/redaction.rs");
    for required in [
        "redact_sensitive_content",
        "access_?token",
        "refresh_?token",
        "client_?secret",
        "authorization_?code",
        "redacts_json_auth_fields",
        "redacts_debug_description_auth_fields",
        "redacts_unquoted_secret_key_values",
    ] {
        assert!(
            redaction.contains(required),
            "server redactor missing auth-secret coverage: {required}"
        );
    }

    let logs =
        read_repo_file("packages/agent/src/domains/session/event_store/store/event_store/logs.rs");
    for required in [
        "redact_sensitive_content(message)",
        "redact_and_truncate_client_log_message(&entry.message)",
        "ingest_redacts_sensitive_client_log_messages_before_storage",
        "redact_and_truncate_redacts_before_cutting_secret_tail",
    ] {
        assert!(
            logs.contains(required),
            "client log ingestion missing server-side redaction proof: {required}"
        );
    }

    let ios_store =
        read_repo_file("packages/ios-app/Sources/Support/Pairing/PairedServerStore.swift");
    let paired_server_decl = ios_store
        .split("struct PairedServer")
        .nth(1)
        .and_then(|tail| tail.split("/// iOS-local source of truth").next())
        .unwrap_or("");
    for forbidden in ["token", "authorization", "apiKey"] {
        assert!(
            !paired_server_decl.contains(forbidden),
            "PairedServer metadata must not contain secret field `{forbidden}`"
        );
    }

    let ios_token_store =
        read_repo_file("packages/ios-app/Sources/Support/Storage/PairedServerTokenStore.swift");
    assert!(
        ios_token_store.contains("KeychainItem(")
            && ios_token_store
                .contains("static let keychainServicePrefix = \"com.tron.mobile.bearer\"")
            && !ios_token_store.contains("UserDefaults"),
        "paired server bearer tokens must stay in Keychain and out of UserDefaults"
    );

    let keychain = read_repo_file("packages/ios-app/Sources/Support/Storage/KeychainItem.swift");
    for required in [
        "kSecClassGenericPassword",
        "kSecAttrAccessibleAfterFirstUnlock",
        "**Access group:** intentionally unset",
    ] {
        assert!(
            keychain.contains(required),
            "Keychain item missing custody marker: {required}"
        );
    }

    for path in [
        "packages/ios-app/Sources/Support/Diagnostics/DiagnosticsRedactor.swift",
        "packages/mac-app/Sources/Support/Diagnostics/DiagnosticsRedactor.swift",
    ] {
        let source = read_repo_file(path);
        for required in [
            "accessToken",
            "refreshToken",
            "clientSecret",
            "authorizationCode",
            "swiftDescriptionTokenRegex",
            "redactSwiftDescriptionTokenValues",
        ] {
            assert!(
                source.contains(required),
                "{path} missing diagnostics auth redaction marker: {required}"
            );
        }
    }

    let ios_logger =
        read_repo_file("packages/ios-app/Sources/Support/Diagnostics/TronLogger.swift");
    assert!(
        ios_logger.contains("DiagnosticsRedactor().redactMessage(message())"),
        "iOS logger must redact before buffering or OS logging"
    );
    let network_formatter = read_repo_file(
        "packages/ios-app/Sources/Engine/Transport/Retry/NetworkDiagnosticsFormatter.swift",
    );
    assert!(
        network_formatter.contains("authorization=\\(authState)")
            && !network_formatter.contains("Bearer \\("),
        "network diagnostics must log auth presence, not bearer value"
    );

    let ios_source_guard = read_repo_file(
        "packages/ios-app/Tests/Infrastructure/Guards/SourceGuardTests+BuildAndProject.swift",
    );
    assert!(
        ios_source_guard.contains("testSecretStorageAndRedactionBoundaries"),
        "iOS source guards must pin token custody and redaction boundaries"
    );
    let mac_source_guard =
        read_repo_file("packages/mac-app/Tests/Infrastructure/Guards/MacSourceGuardTests.swift");
    assert!(
        mac_source_guard.contains("diagnosticsRedactorKeepsAuthFieldParity"),
        "Mac source guards must pin diagnostics redaction parity"
    );
}

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
