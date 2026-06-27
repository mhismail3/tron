use super::*;

#[tokio::test]
async fn module_validation_runtime_grants_are_scoped_to_validation_reports() {
    let cases = [
        (
            json!({
                "operation": "module_validation_record",
                "reportId": "grant-validation",
                "title": "Grant validation",
                "summary": "Runtime grant should be scoped to module validation reports.",
                "moduleRefs": [{"kind": "module_manifest", "resourceId": "module_manifest:module_registry"}],
                "docEvidence": [{"kind": "prompt_artifact", "resourceId": "prompt_artifact:docs"}],
                "testEvidence": [{"kind": "prompt_artifact", "resourceId": "prompt_artifact:tests"}],
                "idempotencyKey": "module-validation-record-grant"
            }),
            true,
            None,
        ),
        (
            json!({
                "operation": "module_validation_list",
                "idempotencyKey": "module-validation-list-grant"
            }),
            false,
            None,
        ),
        (
            json!({
                "operation": "module_validation_inspect",
                "moduleValidationReportResourceId": "module_validation_report:runtime-grant",
                "idempotencyKey": "module-validation-inspect-grant"
            }),
            false,
            Some("module_validation_report:runtime-grant"),
        ),
    ];

    for (payload, write_allowed, expected_resource_id) in cases {
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_module_validation_runtime_grant(&grant, write_allowed, expected_resource_id);
    }
}

fn assert_module_validation_runtime_grant(
    grant: &crate::engine::EngineGrant,
    write_allowed: bool,
    expected_resource_id: Option<&str>,
) {
    assert_eq!(grant.network_policy, "none");
    for scope in ["module_validation.read", "resource.read"] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "module validation grant should include {scope}"
        );
    }
    if write_allowed {
        for scope in ["module_validation.write", "resource.write"] {
            assert!(
                grant.allowed_authority_scopes.contains(&scope.to_owned()),
                "module validation write grant should include {scope}"
            );
        }
    } else {
        for scope in ["module_validation.write", "resource.write"] {
            assert!(
                !grant.allowed_authority_scopes.contains(&scope.to_owned()),
                "module validation read grant must not include {scope}"
            );
        }
    }
    for forbidden_scope in [
        "state.read",
        "state.write",
        "module_authoring.write",
        "module_registry.write",
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
            "module validation grant must not include {forbidden_scope}"
        );
    }
    assert_eq!(
        grant.allowed_resource_kinds,
        vec!["module_validation_report".to_owned()],
        "module validation runtime grant must be report-only"
    );
    let expected_selectors = if let Some(resource_id) = expected_resource_id {
        vec![
            "kind:module_validation_report".to_owned(),
            format!("resource:{resource_id}"),
        ]
    } else {
        vec!["kind:module_validation_report".to_owned()]
    };
    assert_eq!(grant.resource_selectors, expected_selectors);
    for forbidden_kind in [
        "module_manifest",
        "module_proposal",
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
            "module validation grant must not include kind {forbidden_kind}"
        );
        assert!(
            !grant
                .resource_selectors
                .contains(&format!("kind:{forbidden_kind}")),
            "module validation grant must not include selector kind:{forbidden_kind}"
        );
    }
    assert_eq!(grant.allowed_capabilities, vec!["capability::execute"]);
}
