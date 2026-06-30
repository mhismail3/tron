use super::*;

#[tokio::test]
async fn prompt_artifacts_read_runtime_grants_are_read_only_and_selector_bounded() {
    for operation in ["prompt_artifact_list", "prompt_artifact_inspect"] {
        let payload = if operation == "prompt_artifact_inspect" {
            json!({
                "operation": operation,
                "promptArtifactResourceId": "prompt_artifact:runtime-grant",
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

        for scope in ["prompt_artifacts.read", "resource.read"] {
            assert!(
                grant.allowed_authority_scopes.contains(&scope.to_owned()),
                "missing {scope} for {operation}: {:?}",
                grant.allowed_authority_scopes
            );
        }
        assert!(
            !grant
                .allowed_authority_scopes
                .contains(&"prompt_artifacts.write".to_owned()),
            "read operation must not receive write scope"
        );
        assert_eq!(
            grant.allowed_resource_kinds,
            vec!["agent_state".to_owned(), "prompt_artifact".to_owned()]
        );
        assert!(
            grant
                .resource_selectors
                .contains(&"kind:prompt_artifact".to_owned())
        );
        if operation == "prompt_artifact_inspect" {
            assert!(
                grant
                    .resource_selectors
                    .contains(&"resource:prompt_artifact:runtime-grant".to_owned())
            );
        }
        assert_eq!(grant.network_policy, "none");
    }
}

#[tokio::test]
async fn prompt_artifacts_write_runtime_grants_are_selector_bounded_and_local_only() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "prompt_artifact_record",
        "artifactKind": "snippet",
        "title": "Prompt artifact metadata",
        "contentFingerprint": "sha256:prompt-artifact",
        "idempotencyKey": "prompt-artifact-record-grant",
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    for scope in [
        "prompt_artifacts.read",
        "prompt_artifacts.write",
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
            .contains(&"prompt_artifact".to_owned())
    );
    assert!(
        grant
            .resource_selectors
            .contains(&"kind:prompt_artifact".to_owned())
    );
    assert_eq!(grant.network_policy, "none");
    assert_invocation_scopes(
        &invocation,
        &[
            "capability.execute",
            "prompt_artifacts.read",
            "prompt_artifacts.write",
            "resource.read",
            "resource.write",
        ],
    );
    assert!(
        !grant
            .allowed_authority_scopes
            .iter()
            .any(|scope| scope == "*"),
        "runtime grant must not use wildcard authority scopes"
    );
    assert!(
        !grant
            .resource_selectors
            .iter()
            .any(|selector| selector == "*"),
        "runtime grant must not use wildcard resource selectors"
    );
}
