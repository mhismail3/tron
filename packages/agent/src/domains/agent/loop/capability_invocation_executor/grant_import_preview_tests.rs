use super::*;

#[tokio::test]
async fn import_preview_read_runtime_grants_are_read_only_and_selector_bounded() {
    for operation in ["import_preview_list", "import_preview_inspect"] {
        let payload = if operation == "import_preview_inspect" {
            json!({
                "operation": operation,
                "importPreviewResourceId": "import_preview:runtime-grant",
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
        for scope in ["import_preview.read", "resource.read"] {
            assert!(
                grant.allowed_authority_scopes.contains(&scope.to_owned()),
                "import preview read grant should include {scope}"
            );
        }
        for forbidden_scope in [
            "import_preview.write",
            "resource.write",
            "notifications.write",
        ] {
            assert!(
                !grant
                    .allowed_authority_scopes
                    .contains(&forbidden_scope.to_owned()),
                "import preview read grant must not include {forbidden_scope}"
            );
        }
        assert_eq!(
            grant.allowed_resource_kinds,
            vec!["agent_state".to_owned(), "import_preview".to_owned()]
        );
        assert!(
            grant
                .resource_selectors
                .contains(&"kind:import_preview".to_owned())
        );
        for selector in grant.resource_selectors.iter() {
            assert_ne!(selector, "kind:*");
        }
    }
}

#[tokio::test]
async fn import_preview_write_runtime_grants_are_selector_bounded_and_local_only() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "import_preview_record",
        "previewId": "runtime-grant-record",
        "importHistoryRef": {"kind": "import_history_record", "resourceId": "import_history_record:runtime", "role": "lineage"},
        "repositoryTreeRef": {"kind": "repository_tree_snapshot", "resourceId": "repository_tree_snapshot:runtime", "role": "tree"},
        "repositoryRef": {"kind": "repository", "id": "repo:runtime"},
        "rootRef": {"kind": "workspace", "id": "workspace:runtime"},
        "previewFingerprint": "sha256:preview-runtime",
        "pathEntries": [{"path": "src/lib.rs", "kind": "file", "contentHash": "sha256:abc", "changeKind": "modified"}],
        "idempotencyKey": "import-preview-record-grant"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    for scope in [
        "import_preview.read",
        "import_preview.write",
        "resource.read",
        "resource.write",
    ] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "import preview write grant should include {scope}"
        );
    }
    assert_eq!(grant.network_policy, "none");
    assert!(
        grant
            .allowed_resource_kinds
            .contains(&"import_preview".to_owned())
    );
    assert!(
        grant
            .resource_selectors
            .contains(&"kind:import_preview".to_owned())
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
            "import preview write grant must not include {forbidden_scope}"
        );
    }
}
