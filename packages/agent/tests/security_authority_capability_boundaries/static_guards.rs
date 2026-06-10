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
        "pub(super) fn canonical_payload_path(path: &str)",
        "pub(super) fn root_allows_path(root: &str, path: &Path)",
        "Component::ParentDir",
        "path.starts_with(canonical_root)",
        "file path {path} has no existing ancestor",
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
