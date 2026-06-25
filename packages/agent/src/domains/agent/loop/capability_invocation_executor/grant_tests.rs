use super::*;

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
async fn subagent_status_and_result_runtime_grants_are_read_only() {
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

        assert_subagent_task_runtime_grant_is_read_only(&grant);
    }
}

#[tokio::test]
async fn subagent_launch_and_cancel_runtime_grants_are_scoped_writes() {
    for operation in ["subagent_launch", "subagent_cancel"] {
        let payload = if operation == "subagent_launch" {
            json!({
                "operation": operation,
                "objectiveSummary": "bounded objective",
                "promptSummary": "bounded prompt",
                "modelPolicy": "bounded_placeholder_v1",
                "idempotencyKey": format!("{operation}-grant")
            })
        } else {
            json!({
                "operation": operation,
                "subagentTaskResourceId": "subagent_task:runtime-grant",
                "expectedSubagentTaskVersionId": "version-runtime-grant",
                "idempotencyKey": format!("{operation}-grant")
            })
        };
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_subagent_task_runtime_grant_is_scoped_write(&grant);
    }
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

fn assert_subagent_task_runtime_grant_is_scoped_write(grant: &crate::engine::EngineGrant) {
    assert_eq!(grant.network_policy, "none");
    for scope in [
        "subagents.read",
        "subagents.write",
        "resource.read",
        "resource.write",
    ] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "subagent task write grant should include {scope}"
        );
    }
    for forbidden_scope in [
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
            "subagent task write grant must not include {forbidden_scope}"
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
    for forbidden_capability in [
        "subagents::create_task",
        "subagents::update_task",
        "worker_lifecycle::launch_worker",
        "jobs::start",
        "process::run",
        "mcp::start_server",
        "tool::execute",
        "catalog::register",
    ] {
        assert!(
            !grant
                .allowed_capabilities
                .contains(&forbidden_capability.to_owned()),
            "subagent task write grant must not include capability {forbidden_capability}"
        );
    }
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
