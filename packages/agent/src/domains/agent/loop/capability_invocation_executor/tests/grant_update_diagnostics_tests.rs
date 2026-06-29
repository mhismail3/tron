use super::*;

#[tokio::test]
async fn update_diagnostics_read_runtime_grants_are_read_only_and_selector_bounded() {
    for operation in ["update_diagnostic_list", "update_diagnostic_inspect"] {
        let payload = if operation == "update_diagnostic_inspect" {
            json!({
                "operation": operation,
                "updateDiagnosticResourceId": "update_diagnostic_record:runtime-grant",
                "idempotencyKey": format!("{operation}-grant")
            })
        } else {
            json!({
                "operation": operation,
                "idempotencyKey": format!("{operation}-grant")
            })
        };
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_eq!(grant.network_policy, "none");
        for scope in ["update_diagnostics.read", "resource.read"] {
            assert!(
                grant.allowed_authority_scopes.contains(&scope.to_owned()),
                "update diagnostics read grant should include {scope}"
            );
        }
        for forbidden_scope in [
            "update_diagnostics.write",
            "resource.write",
            "worker.lifecycle.write",
        ] {
            assert!(
                !grant
                    .allowed_authority_scopes
                    .contains(&forbidden_scope.to_owned()),
                "update diagnostics read grant must not include {forbidden_scope}"
            );
        }
        assert_eq!(
            grant.allowed_resource_kinds,
            vec![
                "agent_state".to_owned(),
                "update_diagnostic_record".to_owned()
            ]
        );
        assert!(
            grant
                .resource_selectors
                .contains(&"kind:update_diagnostic_record".to_owned())
        );
        for selector in grant.resource_selectors.iter() {
            assert_ne!(selector, "kind:*");
        }
    }
}

#[tokio::test]
async fn update_diagnostics_write_runtime_grants_are_selector_bounded_and_local_only() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "update_diagnostic_record",
        "diagnosticId": "runtime-grant-record",
        "releaseVersion": "2026.6.25",
        "releaseChannel": "stable",
        "signatureStatus": "verified",
        "idempotencyKey": "update-diagnostic-record-grant"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    for scope in [
        "update_diagnostics.read",
        "update_diagnostics.write",
        "resource.read",
        "resource.write",
    ] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "update diagnostics write grant should include {scope}"
        );
    }
    assert_eq!(grant.network_policy, "none");
    assert!(
        grant
            .allowed_resource_kinds
            .contains(&"update_diagnostic_record".to_owned())
    );
    assert!(
        grant
            .resource_selectors
            .contains(&"kind:update_diagnostic_record".to_owned())
    );
    for forbidden_scope in [
        "web.write",
        "device.write",
        "worker.lifecycle.write",
        "subagents.write",
    ] {
        assert!(
            !grant
                .allowed_authority_scopes
                .contains(&forbidden_scope.to_owned()),
            "update diagnostics write grant must not include {forbidden_scope}"
        );
    }
}
