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
