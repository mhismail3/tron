use super::*;

#[tokio::test]
async fn web_research_runtime_grants_are_scoped_to_research_resources() {
    let cases = [
        (
            json!({
                "operation": "web_research_request_record",
                "webResearchRequestId": "grant-request",
                "title": "Grant web research request",
                "questionSummary": "Record bounded research metadata only.",
                "idempotencyKey": "web-research-request-record-grant"
            }),
            true,
            None,
            None,
            None,
        ),
        (
            json!({
                "operation": "web_research_request_list",
                "idempotencyKey": "web-research-request-list-grant"
            }),
            false,
            None,
            None,
            None,
        ),
        (
            json!({
                "operation": "web_research_request_inspect",
                "webResearchRequestResourceId": "web_research_request:runtime-grant",
                "idempotencyKey": "web-research-request-inspect-grant"
            }),
            false,
            Some("web_research_request:runtime-grant"),
            None,
            None,
        ),
        (
            json!({
                "operation": "web_research_review_record",
                "webResearchRequestResourceId": "web_research_request:review-source",
                "reviewSummary": "Review metadata-only web research custody.",
                "idempotencyKey": "web-research-review-record-grant"
            }),
            true,
            Some("web_research_request:review-source"),
            None,
            None,
        ),
        (
            json!({
                "operation": "web_research_review_inspect",
                "webResearchReviewResourceId": "web_research_review:runtime-grant",
                "idempotencyKey": "web-research-review-inspect-grant"
            }),
            false,
            None,
            Some("web_research_review:runtime-grant"),
            None,
        ),
        (
            json!({
                "operation": "web_research_source_record",
                "webResearchRequestResourceId": "web_research_request:source-request",
                "webResearchReviewResourceId": "web_research_review:source-review",
                "artifactKind": "citation_set",
                "title": "Grant citation artifact",
                "summary": "Record bounded citation refs only.",
                "idempotencyKey": "web-research-source-record-grant"
            }),
            true,
            Some("web_research_request:source-request"),
            Some("web_research_review:source-review"),
            None,
        ),
        (
            json!({
                "operation": "web_research_source_inspect",
                "webResearchSourceResourceId": "web_research_source:runtime-grant",
                "idempotencyKey": "web-research-source-inspect-grant"
            }),
            false,
            None,
            None,
            Some("web_research_source:runtime-grant"),
        ),
    ];

    for (payload, write_allowed, expected_request_id, expected_review_id, expected_source_id) in
        cases
    {
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_eq!(grant.network_policy, "none");
        for scope in ["web_research.read", "resource.read"] {
            assert!(
                grant.allowed_authority_scopes.contains(&scope.to_owned()),
                "web research grant should include {scope}"
            );
        }
        for scope in ["web_research.write", "resource.write"] {
            assert_eq!(
                grant.allowed_authority_scopes.contains(&scope.to_owned()),
                write_allowed,
                "unexpected scope {scope}"
            );
        }
        for forbidden_scope in [
            "state.read",
            "state.write",
            "web.read",
            "web.write",
            "module_dependencies.write",
            "module_runtime.write",
            "tool.execute",
        ] {
            assert!(
                !grant
                    .allowed_authority_scopes
                    .contains(&forbidden_scope.to_owned()),
                "web research grant must not include {forbidden_scope}"
            );
        }
        assert_eq!(
            grant.allowed_resource_kinds,
            vec![
                "web_research_request".to_owned(),
                "web_research_review".to_owned(),
                "web_research_source".to_owned(),
            ]
        );
        assert!(
            !grant
                .allowed_resource_kinds
                .contains(&"agent_state".to_owned())
        );
        let mut expected_selectors = vec![
            "kind:web_research_request".to_owned(),
            "kind:web_research_review".to_owned(),
            "kind:web_research_source".to_owned(),
        ];
        if let Some(resource_id) = expected_request_id {
            expected_selectors.push(format!("resource:{resource_id}"));
        }
        if let Some(resource_id) = expected_review_id {
            expected_selectors.push(format!("resource:{resource_id}"));
        }
        if let Some(resource_id) = expected_source_id {
            expected_selectors.push(format!("resource:{resource_id}"));
        }
        assert_eq!(grant.resource_selectors, expected_selectors);
        assert_eq!(grant.allowed_capabilities, vec!["capability::execute"]);
    }
}
