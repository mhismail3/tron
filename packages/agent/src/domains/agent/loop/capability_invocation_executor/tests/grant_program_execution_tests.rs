use super::*;

#[tokio::test]
async fn program_execution_read_runtime_grants_are_read_only_and_selector_bounded() {
    for operation in ["program_execution_list", "program_execution_inspect"] {
        let payload = if operation == "program_execution_inspect" {
            json!({
                "operation": operation,
                "programExecutionResourceId": "program_execution_record:runtime-grant",
            })
        } else {
            json!({"operation": operation})
        };
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        for scope in ["program_execution.read", "resource.read"] {
            assert!(
                grant.allowed_authority_scopes.contains(&scope.to_owned()),
                "missing {scope} for {operation}: {:?}",
                grant.allowed_authority_scopes
            );
        }
        assert!(
            !grant
                .allowed_authority_scopes
                .contains(&"program_execution.write".to_owned()),
            "read operation must not receive write scope"
        );
        assert_eq!(
            grant.allowed_resource_kinds,
            vec![
                "agent_state".to_owned(),
                "program_execution_record".to_owned()
            ]
        );
        assert!(
            grant
                .resource_selectors
                .contains(&"kind:program_execution_record".to_owned())
        );
        if operation == "program_execution_inspect" {
            assert!(
                grant
                    .resource_selectors
                    .contains(&"resource:program_execution_record:runtime-grant".to_owned())
            );
        }
        assert_eq!(grant.network_policy, "none");
    }
}

#[tokio::test]
async fn program_execution_write_runtime_grants_are_selector_bounded_and_local_only() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "program_execution_record",
        "runtimeId": "metadata.runtime",
        "languageId": "metadata.language",
        "programFingerprint": "sha256:program",
        "idempotencyKey": "program-execution-record-grant",
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    for scope in [
        "program_execution.read",
        "program_execution.write",
        "resource.read",
        "resource.write",
    ] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "missing {scope}: {:?}",
            grant.allowed_authority_scopes
        );
    }
    assert!(
        grant
            .allowed_resource_kinds
            .contains(&"program_execution_record".to_owned())
    );
    assert!(
        grant
            .resource_selectors
            .contains(&"kind:program_execution_record".to_owned())
    );
    assert_eq!(grant.network_policy, "none");
}
