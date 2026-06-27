use super::*;

#[tokio::test]
async fn module_dependency_runtime_grants_are_scoped_to_dependency_policy_resources() {
    let cases = [
        (
            json!({
                "operation": "module_dependency_request_record",
                "dependencyRequestId": "grant-dependency-request",
                "title": "Grant dependency request",
                "moduleRef": {"kind": "module_manifest", "resourceId": "module_manifest:owner", "role": "owner"},
                "dependencyName": "portable-pty",
                "dependencyEcosystem": "cargo",
                "rationale": "Record metadata-only owner rationale.",
                "securityNeed": "Review terminal risk.",
                "licenseNeed": "Review license.",
                "runtimeNeed": "Future runtime pack may need terminal metadata.",
                "removalPlan": "Remove when no longer needed.",
                "riskClass": "high",
                "cargoTomlEvidence": {"status": "unchanged", "packageManagerExecuted": false, "fileMutated": false},
                "cargoLockEvidence": {"status": "unchanged", "packageManagerExecuted": false, "fileMutated": false},
                "idempotencyKey": "module-dependency-request-record-grant"
            }),
            true,
            None,
            None,
            None,
        ),
        (
            json!({
                "operation": "module_dependency_request_list",
                "idempotencyKey": "module-dependency-request-list-grant"
            }),
            false,
            None,
            None,
            None,
        ),
        (
            json!({
                "operation": "module_dependency_request_inspect",
                "moduleDependencyRequestResourceId": "module_dependency_request:runtime-grant",
                "idempotencyKey": "module-dependency-request-inspect-grant"
            }),
            false,
            Some("module_dependency_request:runtime-grant"),
            None,
            None,
        ),
        (
            json!({
                "operation": "module_dependency_decision_record",
                "moduleDependencyRequestResourceId": "module_dependency_request:decision-source",
                "decision": "approved",
                "reason": "Approve metadata-only dependency policy candidate.",
                "idempotencyKey": "module-dependency-decision-record-grant"
            }),
            true,
            Some("module_dependency_request:decision-source"),
            None,
            None,
        ),
        (
            json!({
                "operation": "module_dependency_decision_inspect",
                "moduleDependencyDecisionResourceId": "module_dependency_decision:runtime-grant",
                "idempotencyKey": "module-dependency-decision-inspect-grant"
            }),
            false,
            None,
            Some("module_dependency_decision:runtime-grant"),
            None,
        ),
        (
            json!({
                "operation": "module_dependency_policy_activate",
                "moduleDependencyDecisionResourceId": "module_dependency_decision:policy-source",
                "reason": "Activate approved dependency metadata policy.",
                "idempotencyKey": "module-dependency-policy-activate-grant"
            }),
            true,
            None,
            Some("module_dependency_decision:policy-source"),
            None,
        ),
        (
            json!({
                "operation": "module_dependency_policy_inspect",
                "moduleDependencyPolicyResourceId": "module_dependency_policy:runtime-grant",
                "idempotencyKey": "module-dependency-policy-inspect-grant"
            }),
            false,
            None,
            None,
            Some("module_dependency_policy:runtime-grant"),
        ),
    ];

    for (payload, write_allowed, expected_request_id, expected_decision_id, expected_policy_id) in
        cases
    {
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_eq!(grant.network_policy, "none");
        for scope in ["module_dependencies.read", "resource.read"] {
            assert!(
                grant.allowed_authority_scopes.contains(&scope.to_owned()),
                "module dependency grant should include {scope}"
            );
        }
        for scope in ["module_dependencies.write", "resource.write"] {
            assert_eq!(
                grant.allowed_authority_scopes.contains(&scope.to_owned()),
                write_allowed,
                "unexpected scope {scope}"
            );
        }
        for forbidden_scope in [
            "state.read",
            "state.write",
            "module_install.write",
            "module_runtime.write",
            "web.read",
            "web.write",
            "tool.execute",
        ] {
            assert!(
                !grant
                    .allowed_authority_scopes
                    .contains(&forbidden_scope.to_owned()),
                "module dependency grant must not include {forbidden_scope}"
            );
        }
        assert_eq!(
            grant.allowed_resource_kinds,
            vec![
                "module_dependency_request".to_owned(),
                "module_dependency_decision".to_owned(),
                "module_dependency_policy".to_owned(),
            ]
        );
        assert!(
            !grant
                .allowed_resource_kinds
                .contains(&"agent_state".to_owned())
        );
        let mut expected_selectors = vec![
            "kind:module_dependency_request".to_owned(),
            "kind:module_dependency_decision".to_owned(),
            "kind:module_dependency_policy".to_owned(),
        ];
        if let Some(resource_id) = expected_request_id {
            expected_selectors.push(format!("resource:{resource_id}"));
        }
        if let Some(resource_id) = expected_decision_id {
            expected_selectors.push(format!("resource:{resource_id}"));
        }
        if let Some(resource_id) = expected_policy_id {
            expected_selectors.push(format!("resource:{resource_id}"));
        }
        assert_eq!(grant.resource_selectors, expected_selectors);
        assert_eq!(grant.allowed_capabilities, vec!["capability::execute"]);
    }
}
