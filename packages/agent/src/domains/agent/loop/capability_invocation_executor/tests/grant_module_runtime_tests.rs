use super::*;
use sha2::{Digest, Sha256};

#[tokio::test]
async fn module_runtime_runtime_grants_are_scoped_to_runtime_and_lifecycle_resources() {
    let cases = [
        (
            json!({
                "operation": "module_runtime_request",
                "moduleLifecycleResourceId": "module_lifecycle_state:enabled",
                "runtimeRequestId": "runtime-request-1",
                "runtimeKind": "module_feature",
                "runtimeLabel": "Summarize bounded resource refs",
                "reason": "Run enabled module through supervisor metadata envelope.",
                "idempotencyKey": "module-runtime-request-grant"
            }),
            true,
            Some("module_lifecycle_state:enabled".to_owned()),
            Some(expected_runtime_resource_id(
                "session-grant",
                "module_lifecycle_state:enabled",
                "runtime-request-1",
            )),
        ),
        (
            json!({
                "operation": "module_runtime_list",
                "idempotencyKey": "module-runtime-list-grant"
            }),
            false,
            None,
            None,
        ),
        (
            json!({
                "operation": "module_runtime_inspect",
                "moduleRuntimeResourceId": "module_runtime_state:inspect",
                "idempotencyKey": "module-runtime-inspect-grant"
            }),
            false,
            None,
            Some("module_runtime_state:inspect".to_owned()),
        ),
        (
            json!({
                "operation": "module_runtime_cancel",
                "moduleRuntimeResourceId": "module_runtime_state:cancel",
                "expectedModuleRuntimeVersionId": "rver-runtime-current",
                "reason": "Cancel supervised runtime envelope.",
                "idempotencyKey": "module-runtime-cancel-grant"
            }),
            true,
            None,
            Some("module_runtime_state:cancel".to_owned()),
        ),
    ];

    for (payload, write_allowed, expected_lifecycle_id, expected_runtime_id) in cases {
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_eq!(grant.network_policy, "none");
        for scope in ["module_runtime.read", "resource.read"] {
            assert!(grant.allowed_authority_scopes.contains(&scope.to_owned()));
        }
        for scope in ["module_runtime.write", "resource.write"] {
            assert_eq!(
                grant.allowed_authority_scopes.contains(&scope.to_owned()),
                write_allowed,
                "unexpected scope {scope}"
            );
        }
        for forbidden_scope in [
            "state.read",
            "state.write",
            "module_lifecycle.write",
            "module_install.write",
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
        assert!(
            grant
                .allowed_resource_kinds
                .contains(&"module_runtime_state".to_owned())
        );
        assert!(
            !grant
                .allowed_resource_kinds
                .contains(&"agent_state".to_owned())
        );
        let mut expected_selectors = vec!["kind:module_runtime_state".to_owned()];
        if expected_lifecycle_id.is_some() {
            assert!(
                grant
                    .allowed_resource_kinds
                    .contains(&"module_lifecycle_state".to_owned())
            );
            expected_selectors.push("kind:module_lifecycle_state".to_owned());
        }
        if let Some(resource_id) = expected_lifecycle_id.as_deref() {
            expected_selectors.push(format!("resource:{resource_id}"));
        }
        if let Some(resource_id) = expected_runtime_id.as_deref() {
            expected_selectors.push(format!("resource:{resource_id}"));
        }
        assert_eq!(grant.resource_selectors, expected_selectors);
        assert_eq!(grant.allowed_capabilities, vec!["capability::execute"]);
    }
}

fn expected_runtime_resource_id(
    session_id: &str,
    lifecycle_resource_id: &str,
    runtime_request_id: &str,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(
        format!("session:{session_id}:{lifecycle_resource_id}:{runtime_request_id}").as_bytes(),
    );
    format!("module_runtime_state:{:x}", hasher.finalize())
}
