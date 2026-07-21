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
            "server route/auth boundary missing: {required}"
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
            "bearer auth boundary missing: {required}"
        );
    }
}

#[test]
fn sacb_public_transport_cannot_inject_trusted_runtime_metadata() {
    let wire = read_repo_file("packages/agent/src/transport/engine/socket/wire.rs");
    assert!(wire.contains("#[serde(rename_all = \"camelCase\", deny_unknown_fields)]"));
    for forbidden in ["authority_scopes", "runtime_metadata", "trustedLocal"] {
        assert!(
            !wire.contains(forbidden),
            "public wire context accepts `{forbidden}`"
        );
    }

    let transport = read_repo_file("packages/agent/src/transport/engine/mod.rs");
    for forbidden in [
        "pub authority_scopes:",
        "pub runtime_metadata:",
        "with_runtime_metadata(",
        "RUNTIME_METADATA_TRUSTED_LOCAL",
        "engine.internal.invoke",
    ] {
        assert!(
            !transport.contains(forbidden),
            "public transport mints `{forbidden}`"
        );
    }
    for required in [
        "Public transports do not accept caller-provided runtime metadata",
        "pub session_id: Option<String>",
        "pub workspace_id: Option<String>",
        "pub trace_id: Option<String>",
        "pub parent_invocation_id: Option<String>",
    ] {
        assert!(
            transport.contains(required),
            "transport context missing: {required}"
        );
    }
}

#[test]
fn sacb_trusted_local_context_is_observation_not_grant_ceremony() {
    let model = read_repo_file("packages/agent/src/engine/invocation/model.rs");
    for required in [
        "pub const RUNTIME_METADATA_TRUSTED_LOCAL",
        "pub fn trusted_local(",
        "pub fn is_trusted_local(&self)",
        "pub actor_id: ActorId",
        "pub actor_kind: ActorKind",
        "pub trace_id: TraceId",
    ] {
        assert!(
            model.contains(required),
            "causal observation missing: {required}"
        );
    }
    for forbidden in [
        "AuthorityGrantId",
        "authority_grant_id",
        "require_authority_grant_id",
    ] {
        assert!(
            !model.contains(forbidden),
            "causal model retains grant ceremony: {forbidden}"
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
            "model tool executor missing: {required}"
        );
    }
    for forbidden in [
        "grant::derive",
        "derive_capability_runtime_grant",
        "AuthorityGrantId",
    ] {
        assert!(
            !executor.contains(forbidden),
            "model tool executor mints grants: {forbidden}"
        );
    }
}

#[test]
fn sacb_worker_runtime_uses_reliability_controls_not_permissions() {
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
            "worker reliability boundary missing: {required}"
        );
    }
    for forbidden in ["AuthorityGrantId", "grant::derive", "resource_lease"] {
        assert!(
            !workers.contains(forbidden),
            "worker runtime retains permission ceremony: {forbidden}"
        );
    }
}

#[test]
fn sacb_removed_authority_resource_and_wrapper_planes_stay_deleted() {
    for removed in [
        "packages/agent/src/engine/authority",
        "packages/agent/src/engine/durability/resources",
        "packages/agent/src/engine/primitives/resource",
        "packages/agent/src/engine/primitives/grant.rs",
        "packages/agent/src/domains/context_control",
        "packages/agent/src/domains/device",
        "packages/agent/src/domains/memory",
        "packages/agent/src/platform",
        "packages/agent/src/engine/runtime/worker_protocol.rs",
        "packages/agent/src/engine/runtime/external_workers/mod.rs",
        "packages/agent/src/transport/runtime/external_workers.rs",
        "packages/agent/src/transport/runtime/worker_heartbeat.rs",
    ] {
        assert!(
            !repo_path(removed).exists(),
            "retired plane returned: {removed}"
        );
    }

    let registration = read_repo_file("packages/agent/src/domains/registration/mod.rs");
    assert!(!registration.contains("FunctionId::new(\"capability::execute\")"));
    let server = read_repo_file("packages/agent/src/app/bootstrap/server.rs");
    assert!(!server.contains("\"/engine/workers\""));
}
