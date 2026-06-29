use super::*;

#[tokio::test]
async fn repository_tree_read_runtime_grants_are_read_only_and_selector_bounded() {
    for operation in ["repository_tree_list", "repository_tree_inspect"] {
        let payload = if operation == "repository_tree_inspect" {
            json!({
                "operation": operation,
                "repositoryTreeResourceId": "repository_tree_snapshot:runtime-grant",
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
        for scope in ["repository_tree.read", "resource.read"] {
            assert!(
                grant.allowed_authority_scopes.contains(&scope.to_owned()),
                "repository tree read grant should include {scope}"
            );
        }
        for forbidden_scope in [
            "repository_tree.write",
            "resource.write",
            "notifications.write",
        ] {
            assert!(
                !grant
                    .allowed_authority_scopes
                    .contains(&forbidden_scope.to_owned()),
                "repository tree read grant must not include {forbidden_scope}"
            );
        }
        assert_eq!(
            grant.allowed_resource_kinds,
            vec![
                "agent_state".to_owned(),
                "repository_tree_snapshot".to_owned()
            ]
        );
        assert!(
            grant
                .resource_selectors
                .contains(&"kind:repository_tree_snapshot".to_owned())
        );
        for selector in grant.resource_selectors.iter() {
            assert_ne!(selector, "kind:*");
        }
    }
}

#[tokio::test]
async fn repository_tree_write_runtime_grants_are_selector_bounded_and_local_only() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "repository_tree_snapshot",
        "snapshotId": "runtime-grant-record",
        "repositoryRef": {"kind": "repository", "id": "repo:runtime"},
        "rootRef": {"kind": "workspace", "id": "workspace:runtime"},
        "treeObjectRef": "tree:runtime",
        "pathEntries": [{"path": "src/lib.rs", "kind": "file", "contentHash": "sha256:abc"}],
        "idempotencyKey": "repository-tree-record-grant"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    for scope in [
        "repository_tree.read",
        "repository_tree.write",
        "resource.read",
        "resource.write",
    ] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "repository tree write grant should include {scope}"
        );
    }
    assert_eq!(grant.network_policy, "none");
    assert!(
        grant
            .allowed_resource_kinds
            .contains(&"repository_tree_snapshot".to_owned())
    );
    assert!(
        grant
            .resource_selectors
            .contains(&"kind:repository_tree_snapshot".to_owned())
    );
    for forbidden_scope in [
        "web.write",
        "device.write",
        "tool.execute",
        "subagents.write",
    ] {
        assert!(
            !grant
                .allowed_authority_scopes
                .contains(&forbidden_scope.to_owned()),
            "repository tree write grant must not include {forbidden_scope}"
        );
    }
}
