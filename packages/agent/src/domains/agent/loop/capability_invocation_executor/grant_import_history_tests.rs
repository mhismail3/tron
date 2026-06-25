use super::*;

#[tokio::test]
async fn import_history_read_runtime_grants_are_read_only_and_selector_bounded() {
    for operation in ["import_history_list", "import_history_inspect"] {
        let payload = if operation == "import_history_inspect" {
            json!({
                "operation": operation,
                "importHistoryResourceId": "import_history_record:runtime-grant",
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
        for scope in ["import_history.read", "resource.read"] {
            assert!(
                grant.allowed_authority_scopes.contains(&scope.to_owned()),
                "import history read grant should include {scope}"
            );
        }
        for forbidden_scope in [
            "import_history.write",
            "resource.write",
            "notifications.write",
        ] {
            assert!(
                !grant
                    .allowed_authority_scopes
                    .contains(&forbidden_scope.to_owned()),
                "import history read grant must not include {forbidden_scope}"
            );
        }
        assert_eq!(
            grant.allowed_resource_kinds,
            vec!["agent_state".to_owned(), "import_history_record".to_owned()]
        );
        assert!(
            grant
                .resource_selectors
                .contains(&"kind:import_history_record".to_owned())
        );
        for selector in grant.resource_selectors.iter() {
            assert_ne!(selector, "kind:*");
        }
    }
}

#[tokio::test]
async fn import_history_write_runtime_grants_are_selector_bounded_and_local_only() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "import_history_record",
        "recordId": "runtime-grant-record",
        "subjectKind": "session",
        "subjectId": "s1",
        "parentRefs": [{"kind": "session", "id": "s1"}],
        "childRefs": [{"kind": "resource", "id": "media_artifact:abc"}],
        "idempotencyKey": "import-history-record-grant"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    for scope in [
        "import_history.read",
        "import_history.write",
        "resource.read",
        "resource.write",
    ] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "import history write grant should include {scope}"
        );
    }
    assert_eq!(grant.network_policy, "none");
    assert!(
        grant
            .allowed_resource_kinds
            .contains(&"import_history_record".to_owned())
    );
    assert!(
        grant
            .resource_selectors
            .contains(&"kind:import_history_record".to_owned())
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
            "import history write grant must not include {forbidden_scope}"
        );
    }
}
