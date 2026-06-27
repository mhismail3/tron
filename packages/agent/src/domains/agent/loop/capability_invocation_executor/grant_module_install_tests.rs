use super::*;

#[tokio::test]
async fn module_install_runtime_grants_are_scoped_to_install_gate_resources() {
    let cases = [
        (
            json!({
                "operation": "module_install_request_record",
                "installRequestId": "grant-install-request",
                "title": "Grant install request",
                "summary": "Runtime grant should be scoped to module install gate resources.",
                "moduleValidationReportResourceId": "module_validation_report:passed",
                "idempotencyKey": "module-install-request-record-grant"
            }),
            true,
            Some("module_validation_report:passed"),
            None,
            None,
        ),
        (
            json!({
                "operation": "module_install_request_list",
                "idempotencyKey": "module-install-request-list-grant"
            }),
            false,
            None,
            None,
            None,
        ),
        (
            json!({
                "operation": "module_install_request_inspect",
                "moduleInstallRequestResourceId": "module_install_request:runtime-grant",
                "idempotencyKey": "module-install-request-inspect-grant"
            }),
            false,
            None,
            Some("module_install_request:runtime-grant"),
            None,
        ),
        (
            json!({
                "operation": "module_install_decision_record",
                "moduleInstallRequestResourceId": "module_install_request:decision-source",
                "approvalRequestResourceId": "approval_request:runtime",
                "approvalDecisionResourceId": "approval_decision:runtime",
                "decision": "approved",
                "reason": "Metadata-only install candidate review approved.",
                "idempotencyKey": "module-install-decision-record-grant"
            }),
            true,
            None,
            Some("module_install_request:decision-source"),
            None,
        ),
        (
            json!({
                "operation": "module_install_decision_list",
                "idempotencyKey": "module-install-decision-list-grant"
            }),
            false,
            None,
            None,
            None,
        ),
        (
            json!({
                "operation": "module_install_decision_inspect",
                "moduleInstallDecisionResourceId": "module_install_decision:runtime-grant",
                "idempotencyKey": "module-install-decision-inspect-grant"
            }),
            false,
            None,
            None,
            Some("module_install_decision:runtime-grant"),
        ),
    ];

    for (
        payload,
        write_allowed,
        expected_validation_report_id,
        expected_request_id,
        expected_decision_id,
    ) in cases
    {
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_module_install_runtime_grant(
            &grant,
            write_allowed,
            expected_validation_report_id,
            expected_request_id,
            expected_decision_id,
        );
    }
}

fn assert_module_install_runtime_grant(
    grant: &crate::engine::EngineGrant,
    write_allowed: bool,
    expected_validation_report_id: Option<&str>,
    expected_request_id: Option<&str>,
    expected_decision_id: Option<&str>,
) {
    assert_eq!(grant.network_policy, "none");
    for scope in ["module_install.read", "resource.read"] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "module install grant should include {scope}"
        );
    }
    if write_allowed {
        for scope in ["module_install.write", "resource.write"] {
            assert!(
                grant.allowed_authority_scopes.contains(&scope.to_owned()),
                "module install write grant should include {scope}"
            );
        }
    } else {
        for scope in ["module_install.write", "resource.write"] {
            assert!(
                !grant.allowed_authority_scopes.contains(&scope.to_owned()),
                "module install read grant must not include {scope}"
            );
        }
    }
    for forbidden_scope in [
        "state.read",
        "state.write",
        "module_authoring.write",
        "module_registry.write",
        "module_validation.write",
        "worker.lifecycle.write",
        "procedural.write",
        "subagents.write",
        "web.read",
        "web.write",
        "tool.execute",
    ] {
        assert!(
            !grant
                .allowed_authority_scopes
                .contains(&forbidden_scope.to_owned()),
            "module install grant must not include {forbidden_scope}"
        );
    }
    assert_eq!(
        grant.allowed_resource_kinds,
        vec![
            "module_install_request".to_owned(),
            "module_install_decision".to_owned()
        ],
        "module install runtime grant must be install-gate-only"
    );
    let mut expected_selectors = vec![
        "kind:module_install_request".to_owned(),
        "kind:module_install_decision".to_owned(),
    ];
    if let Some(resource_id) = expected_validation_report_id {
        expected_selectors.push(format!("resource:{resource_id}"));
    }
    if let Some(resource_id) = expected_request_id {
        expected_selectors.push(format!("resource:{resource_id}"));
    }
    if let Some(resource_id) = expected_decision_id {
        expected_selectors.push(format!("resource:{resource_id}"));
    }
    assert_eq!(grant.resource_selectors, expected_selectors);
    for forbidden_kind in [
        "module_manifest",
        "module_proposal",
        "module_validation_report",
        "agent_state",
        "worker_package",
        "web_source",
        "subagent_task",
        "procedural_record",
    ] {
        assert!(
            !grant
                .allowed_resource_kinds
                .contains(&forbidden_kind.to_owned()),
            "module install grant must not include kind {forbidden_kind}"
        );
        assert!(
            !grant
                .resource_selectors
                .contains(&format!("kind:{forbidden_kind}")),
            "module install grant must not include selector kind:{forbidden_kind}"
        );
    }
    assert_eq!(grant.allowed_capabilities, vec!["capability::execute"]);
}
