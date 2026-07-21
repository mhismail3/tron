use super::support::{read_repo_file, repo_path};

#[test]
fn sacb_public_engine_route_stays_bearer_gated_and_worker_webhooks_loopback_only() {
    let server = read_repo_file("packages/agent/src/app/bootstrap/server.rs");
    for required in [
        "\"/engine\"",
        "\"/engine/webhooks/workers/{worker_id}/{trigger_id}\"",
        "middleware::from_fn_with_state(state.clone(), ws_auth_gate)",
        "verify_bearer_header(&headers, &state.auth_store)?;",
        "ConnectInfo(peer): ConnectInfo<SocketAddr>",
        "if !peer.ip().is_loopback()",
        "worker webhooks accept loopback requests only",
        "x-tron-worker-token",
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
fn sacb_trusted_local_invocations_never_manufacture_grant_ids() {
    let model = read_repo_file("packages/agent/src/engine/invocation/model.rs");
    for required in [
        "pub authority_grant_id: Option<AuthorityGrantId>",
        "Self::new_with_authority(actor_id, actor_kind, None, trace_id)",
        "require_authority_grant_id",
        "Trusted-local invocations persist `None`/SQL `NULL`",
    ] {
        assert!(
            model.contains(required),
            "trusted-local causal model missing explicit no-grant contract: {required}"
        );
    }
    assert!(
        !model.contains("trusted-local-observation"),
        "trusted-local causal context must not preserve a placeholder grant id"
    );

    let discovery = read_repo_file("packages/agent/src/engine/catalog/discovery.rs");
    assert!(
        !discovery.contains("authority_grant_id") && !discovery.contains("AuthorityGrantId"),
        "catalog discovery actor context must not carry unused grant ceremony"
    );

    let surface = read_repo_file("packages/agent/src/domains/agent/loop/primitive_surface.rs");
    let production_surface = surface.split("#[cfg(test)]").next().unwrap_or(&surface);
    assert!(
        !production_surface.contains("trusted-local-observation")
            && !production_surface.contains("AuthorityGrantId"),
        "provider tool discovery must use actor provenance directly"
    );
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
fn sacb_trusted_local_workers_bypass_call_grants_while_remote_auth_stays_explicit() {
    let invocation = read_repo_file("packages/agent/src/engine/catalog/registry/invocation.rs");
    for required in [
        "if invocation.causal_context.is_trusted_local()",
        "return Ok(())",
        ".authorize_invocation(function, invocation)",
        ".consume_invocation_budget(ConsumeGrantInvocationBudget",
    ] {
        assert!(
            invocation.contains(required),
            "invocation boundary missing trusted-local/remote split: {required}"
        );
    }

    let authorization =
        read_repo_file("packages/agent/src/engine/authority/grants/authorization.rs");
    for forbidden in [
        "capability::execute",
        "operation claim",
        "ensure_capability_grant_is_explicit",
        "capability_working_directory",
    ] {
        assert!(
            !authorization.contains(forbidden),
            "remote authorization must remain generic, found obsolete special case: {forbidden}"
        );
    }
    for required in [
        "authorize_with_grant",
        "ensure_resource_authority",
        "ensure_file_roots",
    ] {
        assert!(
            authorization.contains(required),
            "authenticated non-local calls still require generic grant enforcement: {required}"
        );
    }

    let executor = read_repo_file(
        "packages/agent/src/domains/agent/loop/capability_invocation_executor/mod.rs",
    );
    for required in [
        "CausalContext::trusted_local(actor_id, ActorKind::Agent",
        "direct_tool_idempotency_key",
        "RUNTIME_METADATA_PROVIDER_INVOCATION_ID",
    ] {
        assert!(
            executor.contains(required),
            "local model-tool executor missing trusted-local evidence: {required}"
        );
    }
    for forbidden in ["grant::derive", "derive_capability_runtime_grant"] {
        assert!(
            !executor.contains(forbidden),
            "local model-tool executor must not mint per-call grants: {forbidden}"
        );
    }

    let workers = read_repo_file("packages/agent/src/domains/worker_kernel/runtime.rs");
    for required in [
        "CausalContext::trusted_local(",
        "ActorKind::Worker",
        ".mark_failed(&queued.worker_id, \"execution\", &redacted)",
        "self.store.mark_failed(worker_id, phase, &reason)",
        "self.unregister_dynamic_tool(&queued.worker_id).await",
    ] {
        assert!(
            workers.contains(required),
            "worker runtime missing trusted-local/reliability boundary: {required}"
        );
    }

    let registration = read_repo_file("packages/agent/src/domains/registration/mod.rs");
    assert!(
        !registration.contains("FunctionId::new(\"capability::execute\")"),
        "removed capability wrapper must not be registered"
    );
}

#[test]
fn sacb_superseded_external_worker_plane_stays_deleted() {
    for removed in [
        "packages/agent/src/engine/runtime/worker_protocol.rs",
        "packages/agent/src/engine/runtime/external_workers/mod.rs",
        "packages/agent/src/transport/runtime/external_workers.rs",
        "packages/agent/src/transport/runtime/worker_heartbeat.rs",
    ] {
        assert!(
            !repo_path(removed).exists(),
            "superseded external-worker plane must stay deleted: {removed}"
        );
    }

    let server = read_repo_file("packages/agent/src/app/bootstrap/server.rs");
    assert!(
        !server.contains("\"/engine/workers\""),
        "the removed worker websocket namespace must not return"
    );
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
