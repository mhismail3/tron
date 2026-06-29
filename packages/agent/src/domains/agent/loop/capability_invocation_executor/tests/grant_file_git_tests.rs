use super::*;

#[tokio::test]
async fn filesystem_runtime_grants_use_file_git_module_authority_without_state_fallback() {
    let cases = [
        (
            json!({
                "operation": "filesystem_read",
                "path": "notes/today.txt"
            }),
            &["filesystem.read", "resource.read"][..],
            &["materialized_file"][..],
        ),
        (
            json!({
                "operation": "filesystem_write",
                "path": "notes/today.txt",
                "content": "bounded test content",
                "commit": true,
                "idempotencyKey": "filesystem-write-file-git-grant"
            }),
            &[
                "filesystem.read",
                "filesystem.write",
                "resource.read",
                "resource.write",
            ][..],
            &["patch_proposal", "materialized_file"][..],
        ),
    ];

    for (payload, expected_scopes, expected_kinds) in cases {
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_eq!(grant.allowed_capabilities, vec!["capability::execute"]);
        assert_eq!(grant.network_policy, "none");
        assert_no_state_fallback_or_wildcards(&grant);
        for scope in expected_scopes {
            assert!(
                grant.allowed_authority_scopes.contains(&scope.to_string()),
                "missing scope {scope}: {:?}",
                grant.allowed_authority_scopes
            );
        }
        assert_eq!(
            grant.allowed_resource_kinds,
            expected_kinds
                .iter()
                .map(|kind| (*kind).to_owned())
                .collect::<Vec<_>>()
        );
        assert_eq!(
            grant.resource_selectors,
            expected_kinds
                .iter()
                .map(|kind| format!("kind:{kind}"))
                .collect::<Vec<_>>()
        );
        assert_eq!(
            grant.file_roots,
            vec![
                invocation
                    .causal_context
                    .runtime_metadata(RUNTIME_METADATA_WORKING_DIRECTORY)
                    .expect("working directory metadata")
                    .to_owned()
            ]
        );
    }
}

#[tokio::test]
async fn git_runtime_grants_use_git_evidence_kinds_without_state_fallback() {
    let cases = [
        (
            json!({"operation": "git_status"}),
            &["git.read", "resource.read"][..],
            &["git_index_change", "git_commit", "git_branch_start"][..],
        ),
        (
            json!({
                "operation": "git_stage",
                "path": "src/lib.rs",
                "expectedHead": "0123456789012345678901234567890123456789",
                "reason": "Stage one reviewed file.",
                "idempotencyKey": "git-stage-file-git-grant"
            }),
            &["git.read", "git.write", "resource.write"][..],
            &["git_index_change"][..],
        ),
        (
            json!({
                "operation": "git_commit",
                "message": "test: commit staged change",
                "expectedHead": "0123456789012345678901234567890123456789",
                "expectedIndexTree": "1234567890123456789012345678901234567890",
                "reason": "Commit already-staged reviewed change.",
                "idempotencyKey": "git-commit-file-git-grant"
            }),
            &["git.read", "git.write", "resource.write"][..],
            &["git_commit"][..],
        ),
        (
            json!({
                "operation": "git_branch_start",
                "branchName": "codex/test-branch",
                "expectedHead": "0123456789012345678901234567890123456789",
                "reason": "Start one reviewed local branch.",
                "idempotencyKey": "git-branch-start-file-git-grant"
            }),
            &["git.read", "git.write", "resource.write"][..],
            &["git_branch_start"][..],
        ),
    ];

    for (payload, expected_scopes, expected_kinds) in cases {
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_eq!(grant.allowed_capabilities, vec!["capability::execute"]);
        assert_eq!(grant.network_policy, "none");
        assert_no_state_fallback_or_wildcards(&grant);
        for scope in expected_scopes {
            assert!(
                grant.allowed_authority_scopes.contains(&scope.to_string()),
                "missing scope {scope}: {:?}",
                grant.allowed_authority_scopes
            );
        }
        assert_eq!(
            grant.allowed_resource_kinds,
            expected_kinds
                .iter()
                .map(|kind| (*kind).to_owned())
                .collect::<Vec<_>>()
        );
        assert_eq!(
            grant.resource_selectors,
            expected_kinds
                .iter()
                .map(|kind| format!("kind:{kind}"))
                .collect::<Vec<_>>()
        );
        assert_eq!(
            grant.file_roots,
            vec![
                invocation
                    .causal_context
                    .runtime_metadata(RUNTIME_METADATA_WORKING_DIRECTORY)
                    .expect("working directory metadata")
                    .to_owned()
            ]
        );
    }
}

fn assert_no_state_fallback_or_wildcards(grant: &crate::engine::EngineGrant) {
    assert!(
        !grant
            .allowed_authority_scopes
            .contains(&"state.read".to_owned())
    );
    assert!(
        !grant
            .allowed_authority_scopes
            .contains(&"state.write".to_owned())
    );
    assert!(
        !grant
            .allowed_resource_kinds
            .contains(&"agent_state".to_owned())
    );
    for (label, items) in [
        (
            "authority scopes",
            grant.allowed_authority_scopes.as_slice(),
        ),
        ("resource kinds", grant.allowed_resource_kinds.as_slice()),
        ("resource selectors", grant.resource_selectors.as_slice()),
        ("file roots", grant.file_roots.as_slice()),
    ] {
        assert!(
            !items.iter().any(|item| item == "*"),
            "{label} contained wildcard: {items:?}"
        );
    }
}
