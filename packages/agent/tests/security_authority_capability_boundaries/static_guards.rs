use std::collections::BTreeSet;

use super::support::{INVARIANT_TEST_PATH, parse_inventory, read_repo_file};

#[test]
fn sacb_static_guard_module_is_active() {
    let target = read_repo_file(INVARIANT_TEST_PATH);
    assert!(
        target.contains("mod security_authority_capability_boundaries;"),
        "SACB invariant target must load focused guard modules"
    );

    let module =
        read_repo_file("packages/agent/tests/security_authority_capability_boundaries/mod.rs");
    for required in [
        "mod scorecard_inventory;",
        "mod static_guards;",
        "mod support;",
    ] {
        assert!(
            module.contains(required),
            "SACB module registry missing {required}"
        );
    }
}

#[test]
fn sacb_inventory_covers_required_boundary_classes() {
    let classes = parse_inventory()
        .into_iter()
        .map(|row| row.boundary_class)
        .collect::<BTreeSet<_>>();
    for required in [
        "public_transport",
        "authority_grant",
        "runtime_metadata",
        "execute_primitive",
        "external_worker",
        "secret_storage",
        "pairing_lifecycle",
        "static_gate",
    ] {
        assert!(
            classes.contains(required),
            "SACB inventory missing boundary class {required}"
        );
    }
}

#[test]
fn sacb_public_engine_routes_stay_bearer_gated_and_workers_loopback_only() {
    let server = read_repo_file("packages/agent/src/app/bootstrap/server.rs");
    for required in [
        "\"/engine\"",
        "\"/engine/workers\"",
        "middleware::from_fn_with_state(state.clone(), ws_auth_gate)",
        "verify_bearer_header(&headers, &state.auth_store)?;",
        "ConnectInfo(addr): ConnectInfo<SocketAddr>",
        "ensure_worker_peer_is_loopback(addr)?;",
        "fn ensure_worker_peer_is_loopback(addr: SocketAddr) -> Result<(), StatusCode>",
        "if !addr.ip().is_loopback()",
        "return Err(StatusCode::FORBIDDEN);",
    ] {
        assert!(
            server.contains(required),
            "server route/auth boundary missing required text: {required}"
        );
    }

    let auth = read_repo_file("packages/agent/src/transport/http/auth.rs");
    for required in [
        "header::AUTHORIZATION",
        "strip_prefix(\"Bearer \")",
        "tokens_eq(presented.as_bytes(), canonical.as_bytes())",
        "Err(StatusCode::UNAUTHORIZED)",
    ] {
        assert!(
            auth.contains(required),
            "bearer auth boundary missing required text: {required}"
        );
    }
}

#[test]
fn sacb_public_engine_context_rejects_authority_and_runtime_metadata() {
    let wire = read_repo_file("packages/agent/src/transport/engine/socket/wire.rs");
    for forbidden in ["authority_scopes", "runtime_metadata"] {
        assert!(
            !wire.contains(forbidden),
            "public WireContext must not deserialize {forbidden}"
        );
    }
    assert!(
        wire.contains("#[serde(rename_all = \"camelCase\", deny_unknown_fields)]"),
        "public WireContext must continue denying unknown context fields"
    );

    let transport = read_repo_file("packages/agent/src/transport/engine/mod.rs");
    for forbidden in [
        "pub authority_scopes:",
        "pub runtime_metadata:",
        "input.context.authority_scopes",
        "input.context.runtime_metadata",
        "with_runtime_metadata(key.clone(), value.clone())",
        "remove(\"authorityScopes\")",
        "\"engine-agent\"",
    ] {
        assert!(
            !transport.contains(forbidden),
            "public EngineTransportContext must not accept or copy {forbidden}"
        );
    }
    for required in [
        "Public transports do not accept caller-provided authority scopes or runtime",
        "pub session_id: Option<String>",
        "pub workspace_id: Option<String>",
        "pub trace_id: Option<String>",
        "pub parent_invocation_id: Option<String>",
        "target_authority_scopes_for_engine_invoke(&input.params_payload)",
    ] {
        assert!(
            transport.contains(required),
            "public transport context boundary missing required text: {required}"
        );
    }
}

#[test]
fn sacb_authority_grants_use_canonical_file_roots_and_explicit_bootstrap_roots() {
    let derivation = read_repo_file("packages/agent/src/engine/authority/grants/derivation.rs");
    assert!(
        !derivation.contains("root.starts_with(parent)"),
        "grant derivation must not use raw string-prefix file-root narrowing"
    );
    for required in [
        "canonical_payload_path(root)?",
        "root_allows_path(parent, &canonical_root).unwrap_or(false)",
        "network_rank(&child.network_policy)? > network_rank(&parent.network_policy)?",
        "ensure_budget_narrows(&parent.budget, &child.budget)?",
        "\"remainingInvocations\"",
        "\"remainingTokens\"",
        "\"remainingProcessMs\"",
        "\"maxInvocations\"",
        "\"maxTokens\"",
        "\"maxProcessMs\"",
    ] {
        assert!(
            derivation.contains(required),
            "grant derivation boundary missing required text: {required}"
        );
    }

    let paths = read_repo_file("packages/agent/src/engine/authority/grants/paths.rs");
    for required in [
        "pub(super) fn canonical_payload_path(path: impl AsRef<Path>)",
        "pub(super) fn root_allows_path(root: &str, path: &Path)",
        "Component::ParentDir",
        "path.starts_with(canonical_root)",
        "file path {display} has no existing ancestor",
    ] {
        assert!(
            paths.contains(required),
            "grant path helper missing canonical containment text: {required}"
        );
    }

    let model = read_repo_file("packages/agent/src/engine/authority/grants/model.rs");
    for required in [
        "pub const BOOTSTRAP_GRANT_IDS: &[&str]",
        "allowed_capabilities: vec![\"*\".to_owned()]",
        "allowed_namespaces: vec![\"*\".to_owned()]",
        "allowed_authority_scopes: vec![\"*\".to_owned()]",
        "allowed_resource_kinds: vec![\"*\".to_owned()]",
        "resource_selectors: vec![\"*\".to_owned()]",
        "file_roots: vec![\"*\".to_owned()]",
        "network_policy: \"unrestricted\".to_owned()",
        "max_risk: RiskLevel::Critical",
        "budget: json!({\"class\": \"bootstrap\"})",
        "provenance: json!({\"source\": \"engine.bootstrap\"})",
    ] {
        assert!(
            model.contains(required),
            "bootstrap grant boundary missing required text: {required}"
        );
    }
}

#[test]
fn sacb_capability_execute_is_least_privilege_and_trusted_runtime_only() {
    let executor = [
        read_repo_file(
            "packages/agent/src/domains/agent/loop/capability_invocation_executor/mod.rs",
        ),
        read_repo_file(
            "packages/agent/src/domains/agent/loop/capability_invocation_executor/grant.rs",
        ),
    ]
    .join("\n");
    for required in [
        "derive_capability_runtime_grant",
        "FunctionId::new(\"grant::derive\")",
        "\"parentGrantId\": \"agent-capability-runtime\"",
        "target.function_id.clone()",
        "target_function_id.as_str().to_owned()",
        "\"allowedCapabilities\": allowed_capabilities",
        "\"allowedNamespaces\": [\"__no_namespace_authority__\"]",
        "\"networkPolicy\": \"none\"",
        "normalize_working_directory(working_directory)",
        "with_agent_working_directory_metadata(",
        "RUNTIME_METADATA_WORKING_DIRECTORY",
    ] {
        assert!(
            executor.contains(required),
            "agent capability executor missing least-privilege grant text: {required}"
        );
    }

    let operations = read_repo_file("packages/agent/src/domains/capability/operations/mod.rs");
    for required in [
        "validate_execute_context(invocation, &operation)?",
        "is_bootstrap_authority_grant_id(&invocation.causal_context.authority_grant_id)",
        "capability::execute requires a derived least-privilege authority grant",
        "capability::execute requires a trusted agent or system runtime context",
        "workspace state requires trusted workspace context",
        "capability::execute cannot read or write system-scoped state",
        "requires trusted current session context",
    ] {
        assert!(
            operations.contains(required),
            "capability execute operation guard missing required text: {required}"
        );
    }

    let filesystem =
        read_repo_file("packages/agent/src/domains/capability/operations/filesystem.rs");
    assert!(
        !filesystem.contains("std::env::current_dir"),
        "capability filesystem operations must not fall back to process cwd"
    );
    assert!(
        filesystem.contains("capability::execute requires trusted working directory metadata"),
        "capability filesystem operations must require trusted working-directory metadata"
    );

    let grant_authorization =
        read_repo_file("packages/agent/src/engine/authority/grants/authorization.rs");
    for required in [
        "capability_execute_requires_working_directory(invocation)",
        "RUNTIME_METADATA_WORKING_DIRECTORY",
        "normalize_working_directory(raw)",
        "resolve_invocation_path(invocation, raw)",
    ] {
        assert!(
            grant_authorization.contains(required),
            "grant authorization missing capability execute root guard text: {required}"
        );
    }

    let process = read_repo_file("packages/agent/src/domains/capability/operations/process.rs");
    for required in [
        "inspect_authority_grant(&invocation.causal_context.authority_grant_id)",
        "process_run requires an authority grant with networkPolicy none",
        "/usr/bin/sandbox-exec",
        "(deny network*)",
    ] {
        assert!(
            process.contains(required),
            "process_run missing network-denial guard text: {required}"
        );
    }

    let state = read_repo_file("packages/agent/src/domains/capability/operations/state.rs");
    assert!(
        state.contains("capability::execute cannot read or write system-scoped state"),
        "state operations must reject system scope"
    );
    for (path, required) in [
        (
            "packages/agent/src/domains/capability/operations/trace.rs",
            "requires trusted current session context",
        ),
        (
            "packages/agent/src/domains/capability/operations/logs.rs",
            "requires trusted current session context",
        ),
    ] {
        let source = read_repo_file(path);
        assert!(
            source.contains(required),
            "{path} missing trusted current-session guard text"
        );
    }

    let trace_tests = read_repo_file("packages/agent/tests/primitive_trace_execution.rs");
    for required in [
        "execute_rejects_public_client_context",
        "execute_rejects_bootstrap_authority_grants",
        "execute_rejects_system_scoped_state",
        "execute_process_run_requires_none_network_policy",
    ] {
        assert!(
            trace_tests.contains(required),
            "primitive trace tests missing SACB-6 regression: {required}"
        );
    }
}

#[test]
fn sacb_external_worker_protocol_is_scoped_and_worker_owned() {
    let protocol = read_repo_file("packages/agent/src/engine/runtime/worker_protocol.rs");
    for required in [
        "format!(\"stream:{claim}:*\")",
        "with_session_scope",
        "self.worker_token.session_id = Some(session_id)",
        "with_workspace_scope",
        "self.worker_token.workspace_id = Some(workspace_id)",
    ] {
        assert!(
            protocol.contains(required),
            "worker protocol missing scoped token text: {required}"
        );
    }

    let validation =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/validation.rs");
    for required in [
        "workerToken.resourceSelectors must be scoped; wildcard selectors are not allowed",
        "session-visible workers require workerToken.sessionId binding",
        "namespace_claim_matches_value",
        "stream_topic_allowed_by_token",
        "stream_selector_matches_topic",
    ] {
        assert!(
            validation.contains(required),
            "external worker validation missing scoped-token guard text: {required}"
        );
    }
    assert!(
        !validation.contains("value.contains(claim)"),
        "external worker namespace validation must not use substring matching"
    );

    let lifecycle =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/lifecycle.rs");
    for required in [
        "WorkerAuthPolicy::LoopbackBearer",
        "WorkerKind::External",
        "validate_worker_grant(&hello).await?",
        "inspect_authority_grant(&token.authority_grant_id)",
        "EngineGrantLifecycle::Active",
        "subject_worker_id",
        "allowed_namespaces",
    ] {
        assert!(
            lifecycle.contains(required),
            "external worker lifecycle missing grant/token guard text: {required}"
        );
    }

    let registration =
        read_repo_file("packages/agent/src/engine/runtime/external_workers/registration.rs");
    for required in [
        "validate_worker_trigger",
        "validate_worker_stream_publish",
        "external worker trigger authority grant must match the scoped token",
        "cannot target function",
        "external worker stream visibility must match the worker default visibility",
        "external worker stream sessionId must match the scoped worker session",
        "stream_topic_allowed_by_token(&connection.worker_token, &message.topic)",
    ] {
        assert!(
            registration.contains(required),
            "external worker registration missing ownership guard text: {required}"
        );
    }

    let transport = read_repo_file("packages/agent/src/transport/runtime/external_workers.rs");
    for required in [
        "pending: Arc<Mutex<std::collections::HashMap<String, oneshot::Sender<WorkerInvocationResult>>>>",
        "pending.lock().await.remove(result.invocation_id.as_str())",
        "fail_pending_invocations(&pending, \"external worker websocket disconnected\").await",
        "\"WORKER_DISCONNECTED\"",
        "WORKER_OUTBOUND_BACKPRESSURE_TIMEOUT",
    ] {
        assert!(
            transport.contains(required),
            "external worker transport missing result ownership text: {required}"
        );
    }

    let tests = [
        read_repo_file("packages/agent/src/engine/tests/runtime/external_worker.rs"),
        read_repo_file("packages/agent/src/engine/tests/runtime/external_worker_delivery.rs"),
    ]
    .join("\n");
    for required in [
        "local_external_worker_hello_requires_session_scoped_token_binding",
        "local_external_worker_hello_rejects_wildcard_resource_selectors",
        "local_external_worker_rejects_namespace_substring_claim_escape",
        "local_external_worker_rejects_trigger_target_owned_by_another_worker",
        "local_external_worker_rejects_stream_publish_outside_scoped_session",
        "local_external_worker_rejects_stream_publish_outside_token_selectors",
    ] {
        assert!(
            tests.contains(required),
            "external worker tests missing SACB-7 regression: {required}"
        );
    }
}

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
