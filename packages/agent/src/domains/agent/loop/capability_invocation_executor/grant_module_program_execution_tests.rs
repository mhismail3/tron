use super::*;
use sha2::{Digest, Sha256};

#[tokio::test]
async fn module_program_execution_start_grant_is_ref_only_and_module_scoped() {
    let payload = json!({
        "operation": "module_program_execution_start",
        "moduleLifecycleResourceId": "module_lifecycle_state:enabled",
        "runtimeRequestId": "jobs-runtime-1",
        "command": "printf provider-safe",
        "runtimeId": "runtime.shell",
        "languageId": "language.shell",
        "programFingerprint": "sha256:module-program",
        "networkPolicy": "none",
        "reason": "Run one delegated module job.",
        "idempotencyKey": "module-program-start-grant"
    });
    let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    assert_eq!(grant.allowed_capabilities, vec!["capability::execute"]);
    assert_eq!(grant.network_policy, "none");
    assert!(
        !grant
            .allowed_resource_kinds
            .contains(&"agent_state".to_owned())
    );
    for scope in [
        "module_runtime.read",
        "module_runtime.write",
        "program_execution.read",
        "program_execution.write",
        "jobs.read",
        "jobs.write",
        "resource.read",
        "resource.write",
    ] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "missing scope {scope}: {:?}",
            grant.allowed_authority_scopes
        );
    }
    for kind in [
        "module_runtime_state",
        "module_lifecycle_state",
        "program_execution_record",
        "job_process",
        "execution_output",
    ] {
        assert!(
            grant.allowed_resource_kinds.contains(&kind.to_owned()),
            "missing kind {kind}: {:?}",
            grant.allowed_resource_kinds
        );
        assert!(
            grant.resource_selectors.contains(&format!("kind:{kind}")),
            "missing kind selector {kind}: {:?}",
            grant.resource_selectors
        );
    }
    assert!(
        grant
            .resource_selectors
            .contains(&"resource:module_lifecycle_state:enabled".to_owned())
    );
    assert!(grant.resource_selectors.contains(&format!(
        "resource:{}",
        expected_runtime_resource_id(
            "session-grant",
            "module_lifecycle_state:enabled",
            "jobs-runtime-1"
        )
    )));
}

#[tokio::test]
async fn module_program_execution_followup_grants_require_exact_runtime_and_job_refs() {
    let cases = [
        (
            json!({
                "operation": "module_program_execution_status",
                "moduleRuntimeResourceId": "module_runtime_state:running",
                "jobResourceId": "job_process:running"
            }),
            false,
            false,
        ),
        (
            json!({
                "operation": "module_program_execution_cancel",
                "moduleRuntimeResourceId": "module_runtime_state:running",
                "expectedModuleRuntimeVersionId": "module-runtime-version-1",
                "jobResourceId": "job_process:running",
                "reason": "Cancel delegated module job.",
                "idempotencyKey": "module-program-cancel-grant"
            }),
            true,
            false,
        ),
        (
            json!({
                "operation": "module_program_execution_cleanup",
                "moduleRuntimeResourceId": "module_runtime_state:running",
                "expectedModuleRuntimeVersionId": "module-runtime-version-2",
                "jobResourceId": "job_process:running",
                "expectedJobVersionId": "job-version-1",
                "reason": "Archive delegated module job.",
                "idempotencyKey": "module-program-cleanup-grant"
            }),
            true,
            false,
        ),
    ];

    for (payload, write_allowed, program_write_allowed) in cases {
        let operation = payload
            .get("operation")
            .and_then(Value::as_str)
            .expect("operation")
            .to_owned();
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_eq!(grant.allowed_capabilities, vec!["capability::execute"]);
        assert_eq!(grant.network_policy, "none");
        assert!(
            !grant
                .allowed_resource_kinds
                .contains(&"agent_state".to_owned())
        );
        for scope in [
            "module_runtime.read",
            "program_execution.read",
            "jobs.read",
            "resource.read",
        ] {
            assert!(
                grant.allowed_authority_scopes.contains(&scope.to_owned()),
                "{operation} missing read scope {scope}: {:?}",
                grant.allowed_authority_scopes
            );
        }
        for scope in ["module_runtime.write", "jobs.write", "resource.write"] {
            assert_eq!(
                grant.allowed_authority_scopes.contains(&scope.to_owned()),
                write_allowed,
                "{operation} unexpected write scope {scope}"
            );
        }
        assert_eq!(
            grant
                .allowed_authority_scopes
                .contains(&"program_execution.write".to_owned()),
            program_write_allowed,
            "{operation} unexpected program_execution.write scope"
        );
        for kind in [
            "module_runtime_state",
            "program_execution_record",
            "job_process",
            "execution_output",
        ] {
            assert!(
                grant.allowed_resource_kinds.contains(&kind.to_owned()),
                "{operation} missing kind {kind}: {:?}",
                grant.allowed_resource_kinds
            );
            assert!(
                grant.resource_selectors.contains(&format!("kind:{kind}")),
                "{operation} missing kind selector {kind}: {:?}",
                grant.resource_selectors
            );
        }
        assert!(
            grant
                .resource_selectors
                .contains(&"resource:module_runtime_state:running".to_owned()),
            "{operation} missing exact module runtime selector: {:?}",
            grant.resource_selectors
        );
        assert!(
            grant
                .resource_selectors
                .contains(&"resource:job_process:running".to_owned()),
            "{operation} missing exact delegated job selector: {:?}",
            grant.resource_selectors
        );
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
