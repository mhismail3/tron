use super::*;
use crate::engine::{CreateResource, EngineResourceScope, SUBAGENT_TASK_KIND};
use sha2::{Digest, Sha256};

#[tokio::test]
async fn web_fetch_runtime_grant_stays_source_only_without_robots_evidence() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "web_fetch",
        "url": "https://example.com/source",
        "idempotencyKey": "web-fetch-grant-source-only"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    assert_eq!(grant.network_policy, "declared");
    assert!(
        grant
            .allowed_authority_scopes
            .contains(&"web.write".to_owned())
    );
    assert!(
        grant
            .allowed_authority_scopes
            .contains(&"resource.write".to_owned())
    );
    assert!(
        !grant
            .allowed_authority_scopes
            .contains(&"resource.read".to_owned()),
        "plain web_fetch must not gain robots-policy read authority"
    );
    assert!(
        grant
            .allowed_resource_kinds
            .contains(&"web_source".to_owned())
    );
    assert!(
        !grant
            .allowed_resource_kinds
            .contains(&"web_robots_policy".to_owned()),
        "plain web_fetch must not gain robots-policy resource authority"
    );
    assert!(
        grant
            .resource_selectors
            .contains(&"kind:web_source".to_owned())
    );
    assert!(
        !grant
            .resource_selectors
            .contains(&"kind:web_robots_policy".to_owned())
    );
}

#[tokio::test]
async fn web_fetch_runtime_grant_stays_source_only_with_null_robots_fields() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "web_fetch",
        "url": "https://example.com/source",
        "webRobotsPolicyResourceId": null,
        "expectedWebRobotsPolicyVersionId": null,
        "idempotencyKey": "web-fetch-grant-null-robots"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    assert_eq!(grant.network_policy, "declared");
    assert!(
        grant
            .allowed_authority_scopes
            .contains(&"web.write".to_owned())
    );
    assert!(
        grant
            .allowed_authority_scopes
            .contains(&"resource.write".to_owned())
    );
    assert!(
        !grant
            .allowed_authority_scopes
            .contains(&"web.read".to_owned()),
        "null robots fields must not gain web.read authority"
    );
    assert!(
        !grant
            .allowed_authority_scopes
            .contains(&"resource.read".to_owned()),
        "null robots fields must not gain resource.read authority"
    );
    assert!(
        grant
            .allowed_resource_kinds
            .contains(&"web_source".to_owned())
    );
    assert!(
        !grant
            .allowed_resource_kinds
            .contains(&"web_robots_policy".to_owned()),
        "null robots fields must not gain robots-policy resource authority"
    );
    assert!(
        !grant
            .resource_selectors
            .contains(&"kind:web_robots_policy".to_owned())
    );
}

#[tokio::test]
async fn web_fetch_runtime_grant_includes_robots_policy_authority_when_linked() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "web_fetch",
        "url": "https://example.com/source",
        "webRobotsPolicyResourceId": "web_robots_policy:abc123",
        "expectedWebRobotsPolicyVersionId": "rver_abc123",
        "idempotencyKey": "web-fetch-grant-robots-linked"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    assert_eq!(grant.network_policy, "declared");
    for scope in ["web.read", "web.write", "resource.read", "resource.write"] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "linked web_fetch grant should include {scope}"
        );
    }
    for kind in ["web_source", "web_robots_policy"] {
        assert!(
            grant.allowed_resource_kinds.contains(&kind.to_owned()),
            "linked web_fetch grant should include kind {kind}"
        );
        assert!(
            grant.resource_selectors.contains(&format!("kind:{kind}")),
            "linked web_fetch grant should include selector kind:{kind}"
        );
    }
}

#[tokio::test]
async fn worker_package_list_runtime_grant_authorizes_only_selected_read_kind() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "worker_package_list",
        "workerPackageKind": "worker_package_proposal",
        "idempotencyKey": "worker-package-list-grant-proposal"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    assert_worker_package_runtime_grant_is_read_only_for_kind(&grant, "worker_package_proposal");
    assert_eq!(
        grant
            .allowed_resource_kinds
            .iter()
            .filter(|kind| kind.starts_with("worker_"))
            .collect::<Vec<_>>(),
        vec![&"worker_package_proposal".to_owned()]
    );
}

#[tokio::test]
async fn worker_package_inspect_runtime_grant_authorizes_only_resource_id_kind() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "worker_package_inspect",
        "workerPackageResourceId": "worker_package_conformance_report:local.echo:1.0.0:run-1",
        "idempotencyKey": "worker-package-inspect-grant-conformance"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    assert_worker_package_runtime_grant_is_read_only_for_kind(
        &grant,
        "worker_package_conformance_report",
    );
    assert_eq!(
        grant
            .allowed_resource_kinds
            .iter()
            .filter(|kind| kind.starts_with("worker_"))
            .collect::<Vec<_>>(),
        vec![&"worker_package_conformance_report".to_owned()]
    );
}

#[tokio::test]
async fn procedural_state_runtime_grant_authorizes_only_selected_read_kind() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "procedural_state_inspect",
        "proceduralKind": "hook",
        "proceduralRecordResourceId": "procedural_record:hook:runtime-grant",
        "idempotencyKey": "procedural-state-inspect-grant"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    assert_procedural_runtime_grant_is_read_only_for_kind(&grant, "hook");
}

#[tokio::test]
async fn memory_query_decision_runtime_grants_are_read_only_and_resource_scoped() {
    for (operation, kind, id_field, resource_id) in [
        ("memory_query_list", "memory_query", None, None),
        (
            "memory_query_inspect",
            "memory_query",
            Some("queryResourceId"),
            Some("memory_query:runtime-grant"),
        ),
        ("memory_decision_list", "memory_decision", None, None),
        (
            "memory_decision_inspect",
            "memory_decision",
            Some("decisionResourceId"),
            Some("memory_decision:runtime-grant"),
        ),
    ] {
        let mut payload = json!({
            "operation": operation,
            "idempotencyKey": format!("{operation}-grant")
        });
        if let (Some(field), Some(resource_id)) = (id_field, resource_id) {
            payload[field] = json!(resource_id);
        }
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_memory_evidence_runtime_grant_is_read_only(&grant, kind, resource_id);
    }
}

#[tokio::test]
async fn module_registry_list_runtime_grant_is_read_only_and_kind_scoped() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "module_list",
        "idempotencyKey": "module-list-grant"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    assert_module_registry_runtime_grant_is_read_only(&grant, None);
}

#[tokio::test]
async fn module_registry_inspect_runtime_grant_is_read_only_and_resource_scoped() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "module_inspect",
        "moduleManifestResourceId": "module_manifest:module_registry",
        "idempotencyKey": "module-inspect-grant"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    assert_module_registry_runtime_grant_is_read_only(
        &grant,
        Some("module_manifest:module_registry"),
    );
}

#[tokio::test]
async fn subagent_task_list_runtime_grant_authorizes_only_read_projection_kind() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "subagent_task_list",
        "limit": 10,
        "idempotencyKey": "subagent-task-list-grant"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    assert_subagent_task_runtime_grant_is_read_only(&grant);
}

#[tokio::test]
async fn subagent_task_inspect_runtime_grant_authorizes_only_read_projection_kind() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "subagent_task_inspect",
        "subagentTaskResourceId": "subagent_task:runtime-grant",
        "idempotencyKey": "subagent-task-inspect-grant"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    assert_subagent_task_runtime_grant_is_read_only(&grant);
}

#[tokio::test]
async fn subagent_status_and_result_runtime_grants_authorize_delegated_module_reads() {
    for operation in ["subagent_status", "subagent_result"] {
        let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
            "operation": operation,
            "subagentTaskResourceId": "subagent_task:runtime-grant",
            "idempotencyKey": format!("{operation}-grant")
        }))
        .await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_delegated_subagent_runtime_grant(
            &grant,
            DelegatedSubagentAccess::Read,
            &["resource:subagent_task:runtime-grant"],
        );
    }
}

#[tokio::test]
async fn subagent_launch_runtime_grant_authorizes_exact_delegated_module_start() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "subagent_launch",
        "taskId": "runtime-grant-task",
        "objectiveSummary": "bounded objective",
        "promptSummary": "bounded prompt",
        "modelPolicy": "accepted_jobs_program_execution_v1",
        "workerKind": "module_program_execution",
        "modulePackId": "jobs_program_execution",
        "moduleLifecycleResourceId": "module_lifecycle_state:subagent-runtime-grant",
        "runtimeRequestId": "subagent-runtime-request",
        "command": "printf delegated",
        "runtimeId": "runtime.shell",
        "languageId": "language.shell",
        "programFingerprint": "sha256:delegated",
        "networkPolicy": "none",
        "idempotencyKey": "subagent-launch-grant"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");
    let expected_subagent_task = expected_subagent_task_resource_id(
        "session-grant",
        "runtime-grant-task",
        invocation
            .causal_context
            .idempotency_key
            .as_deref()
            .expect("model invocation idempotency key"),
    );

    assert_delegated_subagent_runtime_grant(
        &grant,
        DelegatedSubagentAccess::Start,
        &[
            &format!("resource:{expected_subagent_task}"),
            "resource:module_lifecycle_state:subagent-runtime-grant",
            &format!(
                "resource:{}",
                expected_runtime_resource_id(
                    "session-grant",
                    "module_lifecycle_state:subagent-runtime-grant",
                    "subagent-runtime-request"
                )
            ),
        ],
    );
}

#[tokio::test]
async fn subagent_cancel_runtime_grant_authorizes_delegated_module_cancel() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "subagent_cancel",
        "subagentTaskResourceId": "subagent_task:runtime-grant",
        "expectedSubagentTaskVersionId": "version-runtime-grant",
        "idempotencyKey": "subagent-cancel-grant"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    assert_delegated_subagent_runtime_grant(
        &grant,
        DelegatedSubagentAccess::Cancel,
        &["resource:subagent_task:runtime-grant"],
    );
}

#[tokio::test]
async fn subagent_followup_grant_reads_existing_task_for_exact_delegated_refs() {
    let engine_host = EngineHostHandle::new_in_memory().expect("engine host");
    seed_delegated_subagent_task(&engine_host).await;
    let payload = json!({
        "operation": "subagent_status",
        "subagentTaskResourceId": "subagent_task:delegated-runtime-grant",
        "idempotencyKey": "subagent-status-delegated-grant"
    });
    let grant_id = derive_capability_runtime_grant(
        &engine_host,
        &ActorId::new("agent:session-grant").expect("actor id"),
        &FunctionId::new("capability::execute").expect("function id"),
        &["capability.execute".to_owned()],
        "session-grant",
        None,
        "/tmp",
        &TraceId::new("trace-subagent-delegated-grant").expect("trace id"),
        "provider-call-subagent-delegated-grant",
        "execute",
        1,
        Some("run-1"),
        &payload,
    )
    .await
    .expect("derive delegated subagent grant");
    let grant = engine_host
        .inspect_authority_grant(&grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    assert_delegated_subagent_runtime_grant(
        &grant,
        DelegatedSubagentAccess::Read,
        &[
            "resource:subagent_task:delegated-runtime-grant",
            "resource:module_runtime_state:delegated-runtime",
            "resource:job_process:delegated-job",
            "resource:program_execution_record:delegated-program",
        ],
    );
}

#[tokio::test]
async fn unsupported_subagent_task_operation_does_not_gain_lifecycle_authority() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "subagent_task_create",
        "idempotencyKey": "subagent-task-create-no-grant"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    for forbidden_scope in [
        "subagents.read",
        "subagents.write",
        "resource.read",
        "resource.write",
    ] {
        assert!(
            !grant
                .allowed_authority_scopes
                .contains(&forbidden_scope.to_owned()),
            "unsupported subagent operation must not include {forbidden_scope}"
        );
    }
    assert!(
        !grant
            .allowed_resource_kinds
            .contains(&"subagent_task".to_owned())
    );
    assert!(
        !grant
            .resource_selectors
            .contains(&"kind:subagent_task".to_owned())
    );
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum DelegatedSubagentAccess {
    Read,
    Start,
    Cancel,
}

fn assert_delegated_subagent_runtime_grant(
    grant: &crate::engine::EngineGrant,
    access: DelegatedSubagentAccess,
    expected_exact_selectors: &[&str],
) {
    assert_eq!(grant.allowed_capabilities, vec!["capability::execute"]);
    assert_eq!(grant.network_policy, "none");
    assert!(
        !grant
            .allowed_resource_kinds
            .contains(&"agent_state".to_owned()),
        "delegated subagent grants must not inherit agent_state"
    );
    for scope in [
        "subagents.read",
        "module_runtime.read",
        "program_execution.read",
        "jobs.read",
        "resource.read",
    ] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "delegated subagent grant missing {scope}: {:?}",
            grant.allowed_authority_scopes
        );
    }
    let write_expected = matches!(
        access,
        DelegatedSubagentAccess::Start | DelegatedSubagentAccess::Cancel
    );
    for scope in [
        "subagents.write",
        "module_runtime.write",
        "jobs.write",
        "resource.write",
    ] {
        assert_eq!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            write_expected,
            "delegated subagent grant unexpected write scope {scope}"
        );
    }
    assert_eq!(
        grant
            .allowed_authority_scopes
            .contains(&"program_execution.write".to_owned()),
        access == DelegatedSubagentAccess::Start,
        "only launch may record program execution metadata"
    );
    for kind in [
        "subagent_task",
        "module_runtime_state",
        "program_execution_record",
        "job_process",
        "execution_output",
    ] {
        assert!(
            grant.allowed_resource_kinds.contains(&kind.to_owned()),
            "delegated subagent grant missing kind {kind}: {:?}",
            grant.allowed_resource_kinds
        );
        assert!(
            grant.resource_selectors.contains(&format!("kind:{kind}")),
            "delegated subagent grant missing selector kind:{kind}: {:?}",
            grant.resource_selectors
        );
    }
    assert_eq!(
        grant
            .allowed_resource_kinds
            .contains(&"module_lifecycle_state".to_owned()),
        access == DelegatedSubagentAccess::Start,
        "only launch needs lifecycle-state authority"
    );
    for selector in expected_exact_selectors {
        assert!(
            grant.resource_selectors.contains(&(*selector).to_owned()),
            "delegated subagent grant missing exact selector {selector}: {:?}",
            grant.resource_selectors
        );
    }
    for selector in &grant.resource_selectors {
        assert!(
            !matches!(
                selector.trim(),
                "*" | "kind:*" | "resource:*" | "kind:" | "resource:"
            ) && !selector.trim().ends_with(":*"),
            "delegated subagent grant must reject broad selector {selector}"
        );
    }
}

async fn seed_delegated_subagent_task(engine_host: &EngineHostHandle) {
    engine_host
        .create_resource(CreateResource {
            resource_id: Some("subagent_task:delegated-runtime-grant".to_owned()),
            kind: SUBAGENT_TASK_KIND.to_owned(),
            schema_id: None,
            scope: EngineResourceScope::Session("session-grant".to_owned()),
            owner_worker_id: WorkerId::new("subagents").expect("worker id"),
            owner_actor_id: ActorId::new("agent:session-grant").expect("actor id"),
            lifecycle: Some("running".to_owned()),
            policy: json!({"owner": "subagents", "networkPolicy": "none"}),
            initial_payload: Some(json!({
                "schemaVersion": "tron.subagent_task.v1",
                "state": "running",
                "taskId": "delegated-runtime-grant",
                "parent": {
                    "sessionId": "session-grant",
                    "workspaceId": "workspace-grant",
                    "traceId": "trace-seed-subagent-delegated-grant",
                    "actorId": "agent:session-grant",
                    "actorKind": "agent"
                },
                "scope": {"kind": "session", "value": "session-grant"},
                "objectiveSummary": "Inspect delegated module refs.",
                "promptSummary": "Return bounded status refs only.",
                "createdAt": "2026-01-01T00:00:00Z",
                "updatedAt": "2026-01-01T00:00:00Z",
                "refs": {"trace": [], "replay": [], "evidence": [], "outputs": [], "handoff": []},
                "activation": {"workerStarted": true, "modulePackActivated": true},
                "network": {"requiredPolicy": "none", "networkAccessPerformed": false},
                "revision": 1,
                "delegation": {
                    "moduleRuntimeResourceId": "module_runtime_state:delegated-runtime",
                    "jobResourceId": "job_process:delegated-job",
                    "programExecutionResourceId": "program_execution_record:delegated-program"
                }
            })),
            locations: Vec::new(),
            trace_id: TraceId::new("trace-seed-subagent-delegated-grant").expect("trace id"),
            invocation_id: None,
        })
        .await
        .expect("seed delegated subagent task");
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

fn expected_subagent_task_resource_id(
    session_id: &str,
    task_id: &str,
    idempotency_key: &str,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"session");
    hasher.update(b":");
    hasher.update(session_id.as_bytes());
    hasher.update(b":");
    hasher.update(task_id.as_bytes());
    hasher.update(b":");
    hasher.update(idempotency_key.as_bytes());
    format!("subagent_task:{:x}", hasher.finalize())
}

fn assert_subagent_task_runtime_grant_is_read_only(grant: &crate::engine::EngineGrant) {
    assert_eq!(grant.network_policy, "none");
    for scope in ["subagents.read", "resource.read"] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "subagent task read grant should include {scope}"
        );
    }
    for forbidden_scope in [
        "subagents.write",
        "resource.write",
        "worker.lifecycle.read",
        "worker.lifecycle.write",
        "web.read",
        "web.write",
        "catalog.write",
        "mcp.write",
        "tool.execute",
    ] {
        assert!(
            !grant
                .allowed_authority_scopes
                .contains(&forbidden_scope.to_owned()),
            "subagent task read grant must not include {forbidden_scope}"
        );
    }
    assert_eq!(
        grant.allowed_resource_kinds,
        vec!["agent_state".to_owned(), "subagent_task".to_owned()]
    );
    assert_eq!(
        grant.resource_selectors,
        vec![
            "kind:agent_state".to_owned(),
            "kind:subagent_task".to_owned()
        ]
    );
    for forbidden_kind in [
        "worker_package",
        "worker_launch_attempt",
        "web_source",
        "web_robots_policy",
        "tool_source_proposal",
        "tool_source_conformance_report",
    ] {
        assert!(
            !grant
                .allowed_resource_kinds
                .contains(&forbidden_kind.to_owned()),
            "subagent task read grant must not include kind {forbidden_kind}"
        );
        assert!(
            !grant
                .resource_selectors
                .contains(&format!("kind:{forbidden_kind}")),
            "subagent task read grant must not include selector kind:{forbidden_kind}"
        );
    }
    for forbidden_capability in [
        "subagents::create_task",
        "subagents::update_task",
        "worker_lifecycle::launch_worker",
        "job::start",
        "process::run",
        "mcp::start_server",
        "mcp::restart_server",
        "tool::execute",
        "catalog::register",
    ] {
        assert!(
            !grant
                .allowed_capabilities
                .contains(&forbidden_capability.to_owned()),
            "subagent task read grant must not include capability {forbidden_capability}"
        );
    }
    assert_eq!(
        grant.allowed_capabilities,
        vec![
            "capability::execute".to_owned(),
            "state::get".to_owned(),
            "state::list".to_owned(),
            "state::set".to_owned(),
        ]
    );
}

fn assert_module_registry_runtime_grant_is_read_only(
    grant: &crate::engine::EngineGrant,
    expected_resource_id: Option<&str>,
) {
    assert_eq!(grant.network_policy, "none");
    for scope in ["module_registry.read", "resource.read"] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "module registry read grant should include {scope}"
        );
    }
    for forbidden_scope in [
        "state.read",
        "state.write",
        "module_registry.write",
        "resource.write",
        "worker.lifecycle.read",
        "worker.lifecycle.write",
        "procedural.write",
        "subagents.write",
        "web.read",
        "web.write",
        "catalog.write",
        "mcp.write",
        "tool.execute",
    ] {
        assert!(
            !grant
                .allowed_authority_scopes
                .contains(&forbidden_scope.to_owned()),
            "module registry read grant must not include {forbidden_scope}"
        );
    }
    assert_eq!(
        grant.allowed_resource_kinds,
        vec!["module_manifest".to_owned()],
        "module registry runtime grant must be module-manifest-only"
    );
    let expected_selectors = if let Some(resource_id) = expected_resource_id {
        vec![
            "kind:module_manifest".to_owned(),
            format!("resource:{resource_id}"),
        ]
    } else {
        vec!["kind:module_manifest".to_owned()]
    };
    assert_eq!(
        grant.resource_selectors, expected_selectors,
        "module registry runtime grant must use only explicit module_manifest selectors"
    );
    for forbidden_kind in [
        "worker_package",
        "worker_launch_attempt",
        "web_source",
        "web_robots_policy",
        "tool_source_proposal",
        "subagent_task",
        "procedural_record",
        "agent_state",
    ] {
        assert!(
            !grant
                .allowed_resource_kinds
                .contains(&forbidden_kind.to_owned()),
            "module registry read grant must not include kind {forbidden_kind}"
        );
        assert!(
            !grant
                .resource_selectors
                .contains(&format!("kind:{forbidden_kind}")),
            "module registry read grant must not include selector kind:{forbidden_kind}"
        );
    }
    for forbidden_capability in [
        "state::get",
        "state::list",
        "state::set",
        "worker_lifecycle::install_package",
        "worker_lifecycle::launch_worker",
        "procedural::activate",
        "procedural::execute",
        "jobs::start",
        "process::run",
        "mcp::start_server",
        "mcp::restart_server",
        "tool::execute",
        "catalog::register",
    ] {
        assert!(
            !grant
                .allowed_capabilities
                .contains(&forbidden_capability.to_owned()),
            "module registry read grant must not include capability {forbidden_capability}"
        );
    }
    assert_eq!(grant.allowed_capabilities, vec!["capability::execute"]);
}

fn assert_memory_evidence_runtime_grant_is_read_only(
    grant: &crate::engine::EngineGrant,
    expected_kind: &str,
    expected_resource_id: Option<&str>,
) {
    assert_eq!(grant.network_policy, "none");
    for scope in ["memory.read", "resource.read"] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "memory evidence read grant should include {scope}"
        );
    }
    for forbidden_scope in [
        "memory.write",
        "resource.write",
        "web.read",
        "web.write",
        "subagents.write",
        "worker.lifecycle.write",
        "catalog.write",
        "tool.execute",
    ] {
        assert!(
            !grant
                .allowed_authority_scopes
                .contains(&forbidden_scope.to_owned()),
            "memory evidence read grant must not include {forbidden_scope}"
        );
    }
    assert_eq!(
        grant.allowed_resource_kinds,
        vec!["agent_state".to_owned(), expected_kind.to_owned()]
    );
    assert!(
        grant
            .resource_selectors
            .contains(&format!("kind:{expected_kind}")),
        "memory evidence grant should include selector kind:{expected_kind}"
    );
    for forbidden_kind in [
        "memory_record",
        "memory_prompt_trace",
        "web_source",
        "subagent_task",
        "worker_package",
    ] {
        assert!(
            !grant
                .allowed_resource_kinds
                .contains(&forbidden_kind.to_owned()),
            "memory evidence read grant must not include kind {forbidden_kind}"
        );
        assert!(
            !grant
                .resource_selectors
                .contains(&format!("kind:{forbidden_kind}")),
            "memory evidence read grant must not include selector kind:{forbidden_kind}"
        );
    }
    if let Some(resource_id) = expected_resource_id {
        assert!(
            grant
                .resource_selectors
                .contains(&format!("resource:{resource_id}")),
            "memory inspect grant should include selector resource:{resource_id}"
        );
    }
    assert_eq!(
        grant.allowed_capabilities,
        vec![
            "capability::execute".to_owned(),
            "state::get".to_owned(),
            "state::list".to_owned(),
            "state::set".to_owned(),
        ]
    );
}

fn assert_worker_package_runtime_grant_is_read_only_for_kind(
    grant: &crate::engine::EngineGrant,
    expected_kind: &str,
) {
    assert_eq!(grant.network_policy, "none");
    for scope in ["worker.lifecycle.read", "resource.read"] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "worker package read grant should include {scope}"
        );
    }
    for forbidden_scope in [
        "worker.lifecycle.propose",
        "worker.lifecycle.write",
        "resource.write",
        "catalog.write",
        "mcp.write",
        "tool.execute",
    ] {
        assert!(
            !grant
                .allowed_authority_scopes
                .contains(&forbidden_scope.to_owned()),
            "worker package read grant must not include {forbidden_scope}"
        );
    }
    assert!(
        grant
            .allowed_resource_kinds
            .contains(&expected_kind.to_owned()),
        "worker package read grant should include kind {expected_kind}"
    );
    assert!(
        grant
            .resource_selectors
            .contains(&format!("kind:{expected_kind}")),
        "worker package read grant should include selector kind:{expected_kind}"
    );
    for forbidden_kind in [
        "mcp_server",
        "tool_source",
        "tool_catalog",
        "worker_package_catalog",
    ] {
        assert!(
            !grant
                .allowed_resource_kinds
                .contains(&forbidden_kind.to_owned()),
            "worker package read grant must not include kind {forbidden_kind}"
        );
        assert!(
            !grant
                .resource_selectors
                .contains(&format!("kind:{forbidden_kind}")),
            "worker package read grant must not include selector kind:{forbidden_kind}"
        );
    }
    for forbidden_capability in [
        "worker_lifecycle::propose_package_change",
        "worker_lifecycle::install_package",
        "worker_lifecycle::enable_package",
        "worker_lifecycle::disable_package",
        "worker_lifecycle::launch_worker",
        "worker_lifecycle::stop_worker",
        "worker_lifecycle::retire_package",
        "mcp::start_server",
        "mcp::restart_server",
        "tool::execute",
        "catalog::register",
    ] {
        assert!(
            !grant
                .allowed_capabilities
                .contains(&forbidden_capability.to_owned()),
            "worker package read grant must not include capability {forbidden_capability}"
        );
    }
    assert_eq!(
        grant.allowed_capabilities,
        vec![
            "capability::execute".to_owned(),
            "state::get".to_owned(),
            "state::list".to_owned(),
            "state::set".to_owned(),
        ]
    );
}

fn assert_procedural_runtime_grant_is_read_only_for_kind(
    grant: &crate::engine::EngineGrant,
    expected_procedural_kind: &str,
) {
    assert_eq!(grant.network_policy, "none");
    for scope in ["procedural.read", "resource.read"] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "procedural read grant should include {scope}"
        );
    }
    for forbidden_scope in [
        "procedural.write",
        "resource.write",
        "worker.lifecycle.read",
        "worker.lifecycle.write",
        "subagents.write",
        "web.read",
        "web.write",
        "catalog.write",
        "mcp.write",
        "tool.execute",
    ] {
        assert!(
            !grant
                .allowed_authority_scopes
                .contains(&forbidden_scope.to_owned()),
            "procedural read grant must not include {forbidden_scope}"
        );
    }
    assert_eq!(
        grant.allowed_resource_kinds,
        vec!["agent_state".to_owned(), "procedural_record".to_owned()]
    );
    assert_eq!(
        grant.resource_selectors,
        vec![
            "kind:agent_state".to_owned(),
            "kind:procedural_record".to_owned(),
            format!("proceduralKind:{expected_procedural_kind}")
        ]
    );
    for forbidden_kind in [
        "worker_package",
        "worker_launch_attempt",
        "web_source",
        "web_robots_policy",
        "tool_source_proposal",
        "subagent_task",
    ] {
        assert!(
            !grant
                .allowed_resource_kinds
                .contains(&forbidden_kind.to_owned()),
            "procedural read grant must not include kind {forbidden_kind}"
        );
    }
    for forbidden_capability in [
        "procedural::activate",
        "procedural::trigger",
        "procedural::execute",
        "worker_lifecycle::install_package",
        "worker_lifecycle::launch_worker",
        "mcp::start_server",
        "tool::execute",
        "catalog::register",
    ] {
        assert!(
            !grant
                .allowed_capabilities
                .contains(&forbidden_capability.to_owned()),
            "procedural read grant must not include capability {forbidden_capability}"
        );
    }
    assert_eq!(
        grant.allowed_capabilities,
        vec![
            "capability::execute".to_owned(),
            "state::get".to_owned(),
            "state::list".to_owned(),
            "state::set".to_owned(),
        ]
    );
}
