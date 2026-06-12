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
        "mod platform_guards;",
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
        "pub struct ConsumeGrantInvocationBudget",
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

    let grants = read_repo_file("packages/agent/src/engine/authority/grants/mod.rs");
    for required in [
        "consume_invocation_budget",
        "ConsumeGrantInvocationBudget",
        "\"grant.budget_consumed\"",
        "\"budgetField\": \"remainingInvocations\"",
        "set_remaining_invocations(&mut grant.budget, remaining - 1)?",
        "budget_json = ?2",
        "revision = ?3",
        "updated_at = ?4",
        "updated != 1",
    ] {
        assert!(
            grants.contains(required),
            "grant budget consumption boundary missing required text: {required}"
        );
    }

    let registry = read_repo_file("packages/agent/src/engine/catalog/registry/invocation.rs");
    for required in [
        "consume_invocation_budget(&function, &invocation)",
        "complete_invocation_idempotency(",
        "PreparedSyncInvocationDecision::Execute",
    ] {
        assert!(
            registry.contains(required),
            "invocation registry missing budget consume/replay boundary text: {required}"
        );
    }

    let policy_hash = read_repo_file("packages/agent/src/engine/authority/grants/policy_hash.rs");
    for required in [
        "pub(crate) fn grant_policy_hash(grant: &EngineGrant)",
        "\"allowedCapabilities\": sorted_strings(&grant.allowed_capabilities)",
        "\"resourceSelectors\": sorted_strings(&grant.resource_selectors)",
        "\"budget\": grant.budget",
        "\"revision\": grant.revision",
        "write_canonical_json(&policy, &mut canonical)",
        "Sha256::digest(canonical.as_bytes())",
    ] {
        assert!(
            policy_hash.contains(required),
            "grant policy hash boundary missing required text: {required}"
        );
    }
}

#[test]
fn sacb_delegated_engine_invoke_consumes_parent_budget_before_child_prepare() {
    let source = read_repo_file("packages/agent/src/engine/invocation/host/meta_invocation.rs");
    let start = source
        .find("pub(super) fn prepare_delegated_invocation")
        .expect("prepare_delegated_invocation must exist");
    let tail = &source[start..];
    let end = tail
        .find("\n    fn prepare_meta_invocation")
        .expect("prepare_meta_invocation should follow prepare_delegated_invocation");
    let body = &tail[..end];

    let delegated_child = body
        .find("delegated_child_invocation(&invocation)")
        .expect("delegated child must be parsed before budget consumption");
    let parent_budget = body
        .find("self.consume_invocation_budget_sync(&function, &invocation)")
        .expect("parent wrapper budget must be consumed");
    let child_host_dispatch = body
        .find("is_host_dispatched_primitive_function(&child.function_id)")
        .expect("host-dispatched child branch must remain explicit");
    let child_host_invoke = body
        .find("self.invoke_sync_host_dispatched_primitive(child)")
        .expect("host-dispatched child invocation must remain explicit");
    let child_regular_prepare = body
        .find("self.catalog.prepare_sync_invocation(child)")
        .expect("regular child preparation must remain explicit");

    assert!(
        delegated_child < parent_budget,
        "malformed engine::invoke payloads must fail before budget consumption"
    );
    for (label, child_index) in [
        ("host-dispatched child branch", child_host_dispatch),
        ("host-dispatched child invocation", child_host_invoke),
        ("regular child preparation", child_regular_prepare),
    ] {
        assert!(
            parent_budget < child_index,
            "parent engine::invoke budget must be consumed before {label}"
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
        "bootstrap_grant_policy_hash(&worker.authority_grant)",
        "expect(\"loopback worker token must use a known bootstrap authority grant\")",
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
    assert!(
        !protocol.contains("loopback-bootstrap"),
        "worker protocol must not issue placeholder grant hashes"
    );
    assert!(
        !protocol.contains("unwrap_or_default()"),
        "worker protocol must fail loudly instead of defaulting scoped token grant hashes"
    );

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
        "grant_policy_hash(&grant)",
        "token.authority_grant_hash != active_hash",
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
    assert!(
        !lifecycle.contains("authority_grant_hash.trim().is_empty()"),
        "worker lifecycle must compare the token hash to the active grant hash"
    );

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
        "local_external_worker_hello_accepts_matching_grant_revision_and_hash",
        "local_external_worker_hello_rejects_stale_grant_revision",
        "local_external_worker_hello_rejects_tampered_grant_hash",
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
