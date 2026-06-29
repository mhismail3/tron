use super::*;
use sha2::{Digest, Sha256};

#[tokio::test]
async fn module_lifecycle_runtime_grants_are_scoped_to_lifecycle_resources() {
    let cases = [
        (
            json!({
                "operation": "module_lifecycle_request",
                "moduleInstallDecisionResourceId": "module_install_decision:candidate",
                "lifecycleAction": "disable",
                "reason": "Metadata-only disable request.",
                "idempotencyKey": "module-lifecycle-request-grant"
            }),
            true,
            Some("module_install_decision:candidate"),
            Some(expected_lifecycle_resource_id(
                "session-grant",
                "module_install_decision:candidate",
            )),
        ),
        (
            json!({
                "operation": "module_lifecycle_decision",
                "moduleLifecycleResourceId": "module_lifecycle_state:runtime-grant",
                "expectedModuleLifecycleVersionId": "version:lifecycle-current",
                "approvalRequestResourceId": "approval_request:runtime",
                "approvalDecisionResourceId": "approval_decision:runtime",
                "decision": "approved",
                "reason": "Metadata-only lifecycle decision approved.",
                "idempotencyKey": "module-lifecycle-decision-grant"
            }),
            true,
            None,
            Some("module_lifecycle_state:runtime-grant".to_owned()),
        ),
        (
            json!({
                "operation": "module_lifecycle_list",
                "idempotencyKey": "module-lifecycle-list-grant"
            }),
            false,
            None,
            None,
        ),
        (
            json!({
                "operation": "module_lifecycle_inspect",
                "moduleLifecycleResourceId": "module_lifecycle_state:inspect",
                "idempotencyKey": "module-lifecycle-inspect-grant"
            }),
            false,
            None,
            Some("module_lifecycle_state:inspect".to_owned()),
        ),
    ];

    for (payload, write_allowed, expected_install_decision_id, expected_lifecycle_id) in cases {
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_eq!(grant.network_policy, "none");
        for scope in ["module_lifecycle.read", "resource.read"] {
            assert!(grant.allowed_authority_scopes.contains(&scope.to_owned()));
        }
        for scope in ["module_lifecycle.write", "resource.write"] {
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
            "module_validation.write",
            "worker.lifecycle.write",
            "web.read",
            "web.write",
        ] {
            assert!(
                !grant
                    .allowed_authority_scopes
                    .contains(&forbidden_scope.to_owned())
            );
        }
        assert_eq!(
            grant.allowed_resource_kinds,
            vec!["module_lifecycle_state".to_owned()]
        );
        let mut expected_selectors = vec!["kind:module_lifecycle_state".to_owned()];
        if let Some(resource_id) = expected_install_decision_id {
            expected_selectors.push(format!("resource:{resource_id}"));
        }
        if let Some(resource_id) = expected_lifecycle_id.as_deref() {
            expected_selectors.push(format!("resource:{resource_id}"));
        }
        assert_eq!(grant.resource_selectors, expected_selectors);
        assert!(
            !grant
                .allowed_resource_kinds
                .contains(&"agent_state".to_owned())
        );
        assert!(
            !grant
                .resource_selectors
                .contains(&"kind:agent_state".to_owned())
        );
        assert_eq!(grant.allowed_capabilities, vec!["capability::execute"]);
    }
}

fn expected_lifecycle_resource_id(session_id: &str, install_decision_resource_id: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(format!("session:{session_id}:{install_decision_resource_id}").as_bytes());
    format!("module_lifecycle_state:{:x}", hasher.finalize())
}
