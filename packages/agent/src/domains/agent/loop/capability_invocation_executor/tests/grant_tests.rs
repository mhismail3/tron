use super::*;
use crate::engine::{CreateResource, EngineResourceScope, SUBAGENT_TASK_KIND};
use sha2::{Digest, Sha256};

fn assert_no_state_inheritance(grant: &crate::engine::EngineGrant) {
    for scope in ["state.read", "state.write"] {
        assert!(
            !grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "grant must not inherit {scope}: {:?}",
            grant.allowed_authority_scopes
        );
    }
    for capability in ["state::get", "state::set", "state::list"] {
        assert!(
            !grant.allowed_capabilities.contains(&capability.to_owned()),
            "grant must not inherit capability {capability}: {:?}",
            grant.allowed_capabilities
        );
    }
    assert!(
        !grant
            .allowed_resource_kinds
            .contains(&"agent_state".to_owned()),
        "grant must not inherit agent_state resource authority: {:?}",
        grant.allowed_resource_kinds
    );
    assert!(
        !grant
            .resource_selectors
            .iter()
            .any(|selector| selector.contains("agent_state")),
        "grant must not inherit agent_state selectors: {:?}",
        grant.resource_selectors
    );
}

#[test]
fn runtime_grant_derivation_has_one_static_authority_owner() {
    let source = include_str!("../grant.rs");

    assert!(source.contains("authority_policy(operation)"));
    assert!(
        source.lines().count() < 900,
        "runtime grant wiring should contain resolution, not another operation catalog"
    );
    for removed_owner in [
        "state_runtime_capability",
        "exact_resource_selector_fields",
        "capability_binding_resource_kinds",
        "capability_route_resource_kinds",
        "delegated_subagent_module_scopes",
        "diagnostic_read_resource_kinds",
    ] {
        assert!(
            !source.contains(removed_owner),
            "duplicate static authority owner {removed_owner} must stay deleted"
        );
    }
    assert!(
        !source.contains("\"agent_state\""),
        "runtime grants must not restore removed agent_state resource authority"
    );
}

#[tokio::test]
async fn state_runtime_grants_are_explicit_state_only() {
    for (operation, expected_capability, expected_scope) in [
        ("state_get", "state::get", "state.read"),
        ("state_set", "state::set", "state.write"),
        ("state_list", "state::list", "state.read"),
    ] {
        let payload = match operation {
            "state_get" => json!({
                "operation": operation,
                "namespace": "runtime-grant",
                "key": "item"
            }),
            "state_set" => json!({
                "operation": operation,
                "namespace": "runtime-grant",
                "key": "item",
                "value": {"ok": true},
                "idempotencyKey": "state-set-runtime-grant"
            }),
            "state_list" => json!({
                "operation": operation,
                "namespace": "runtime-grant"
            }),
            _ => unreachable!(),
        };
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_eq!(grant.network_policy, "none");
        assert_eq!(
            grant.allowed_capabilities,
            vec![
                "capability::execute".to_owned(),
                expected_capability.to_owned()
            ]
        );
        assert!(
            grant
                .allowed_authority_scopes
                .contains(&expected_scope.to_owned()),
            "{operation} grant should include {expected_scope}: {:?}",
            grant.allowed_authority_scopes
        );
        for forbidden_scope in ["state.read", "state.write"] {
            if forbidden_scope == expected_scope {
                continue;
            }
            assert!(
                !grant
                    .allowed_authority_scopes
                    .contains(&forbidden_scope.to_owned()),
                "{operation} grant must not include {forbidden_scope}"
            );
        }
        assert!(
            grant.allowed_resource_kinds.is_empty(),
            "state authority is capability-and-scope based, not resource inheritance"
        );
        assert!(grant.resource_selectors.is_empty());
    }
}

#[tokio::test]
async fn goal_create_runtime_grant_propagates_write_scopes_without_wildcards() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "goal_create",
        "objective": "Record bounded durable goal metadata",
        "idempotencyKey": "goal-create-runtime-grant"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    for scope in ["goals.write", "resource.write"] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "goal_create grant missing {scope}: {:?}",
            grant.allowed_authority_scopes
        );
    }
    assert!(
        grant.allowed_resource_kinds.contains(&"goal".to_owned()),
        "goal_create grant missing goal resource kind"
    );
    assert!(
        grant.resource_selectors.contains(&"kind:goal".to_owned()),
        "goal_create grant missing kind:goal selector"
    );
    assert_eq!(grant.network_policy, "none");
    assert_invocation_scopes(
        &invocation,
        &["capability.execute", "goals.write", "resource.write"],
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
    assert_no_state_inheritance(&grant);
    assert_eq!(
        grant.allowed_capabilities,
        vec!["capability::execute".to_owned()]
    );
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
async fn web_robots_check_runtime_grant_is_exact_network_policy_grant() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "web_robots_check",
        "url": "https://example.com/",
        "idempotencyKey": "web-robots-check-runtime-grant"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    assert_eq!(grant.network_policy, "declared");
    assert_no_state_inheritance(&grant);
    assert_eq!(
        grant.allowed_capabilities,
        vec!["capability::execute".to_owned()]
    );
    for scope in ["web.write", "resource.read", "resource.write"] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "web_robots_check grant should include {scope}"
        );
    }
    assert_eq!(
        grant.allowed_resource_kinds,
        vec!["web_robots_policy".to_owned()]
    );
    assert_eq!(
        grant.resource_selectors,
        vec!["kind:web_robots_policy".to_owned()]
    );
    assert_invocation_scopes(
        &invocation,
        &[
            "capability.execute",
            "web.write",
            "resource.read",
            "resource.write",
        ],
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
    assert_no_state_inheritance(&grant);
    assert_eq!(
        grant.allowed_capabilities,
        vec!["capability::execute".to_owned()]
    );
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
async fn web_fetch_runtime_grant_rejects_partial_robots_proof_before_execution() {
    let (engine_host, surface, captured) = capturing_execute_surface().await;
    let emitter = Arc::new(EventEmitter::new());
    let cancel = CancellationToken::new();
    let mut ctx = capability_exec_ctx(&surface, &emitter, &cancel);
    ctx.engine_host = Some(&engine_host);
    let tempdir = tempfile::tempdir().expect("working directory");
    let call = CapabilityInvocationDraft::new(
        "tc1",
        "execute",
        payload_object(&json!({
            "operation": "web_fetch",
            "url": "https://example.com/source",
            "webRobotsPolicyResourceId": "web_robots_policy:abc123",
            "expectedWebRobotsPolicyVersionId": null,
            "idempotencyKey": "web-fetch-partial-robots-proof"
        })),
    );

    let result = execute_capability_invocation(
        &call,
        "session-grant",
        tempdir.path().to_str().expect("utf8 tempdir"),
        &ctx,
    )
    .await;

    assert_eq!(result.result.is_error, Some(true));
    assert_failure_code(&result.result, "INVALID_PARAMS");
    assert_eq!(
        result.result.details.as_ref().unwrap()["failure"]["category"],
        "invalid_request"
    );
    assert!(
        captured.lock().is_none(),
        "partial robots proof must not reach capability execution"
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
    assert_no_state_inheritance(&grant);
    assert_eq!(
        grant.allowed_capabilities,
        vec!["capability::execute".to_owned()]
    );
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
        "workerPackageKind": "worker_package_proposal"
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
        "workerPackageResourceId": "worker_package_conformance_report:local.echo:1.0.0:run-1"
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
async fn capability_binding_list_runtime_grants_authorize_exact_record_kind_only() {
    for (operation, expected_kind) in [
        (
            "capability_binding_request_list",
            "capability_binding_request",
        ),
        (
            "capability_binding_decision_list",
            "capability_binding_decision",
        ),
        (
            "capability_binding_policy_list",
            "capability_binding_policy",
        ),
    ] {
        let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
            "operation": operation,
            "limit": 10
        }))
        .await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_eq!(grant.allowed_capabilities, vec!["capability::execute"]);
        assert_eq!(grant.network_policy, "none");
        assert_eq!(
            grant
                .allowed_resource_kinds
                .iter()
                .filter(|kind| kind.starts_with("capability_"))
                .cloned()
                .collect::<Vec<_>>(),
            vec![expected_kind.to_owned()],
            "{operation} must derive only its own record kind"
        );
        assert!(
            grant
                .resource_selectors
                .contains(&format!("kind:{expected_kind}")),
            "{operation} grant missing exact kind selector: {:?}",
            grant.resource_selectors
        );
        assert!(
            !grant
                .allowed_resource_kinds
                .contains(&"agent_state".to_owned()),
            "{operation} must not inherit agent_state authority"
        );
        for forbidden_kind in [
            "capability_replacement_candidate",
            "capability_route_binding",
            "capability_route_activation",
            "capability_route_event",
            "capability_shadow_trial_request",
            "capability_shadow_trial_decision",
            "capability_shadow_trial_run",
            "capability_shadow_trial_evidence",
        ] {
            assert!(
                !grant
                    .allowed_resource_kinds
                    .contains(&forbidden_kind.to_owned()),
                "{operation} must not inherit route/shadow kind {forbidden_kind}"
            );
        }
        assert_invocation_scopes(
            &invocation,
            &[
                "capability.execute",
                "capability_binding.read",
                "resource.read",
            ],
        );
    }
}

#[tokio::test]
async fn capability_binding_cockpit_overview_runtime_grant_authorizes_governance_projection_kinds()
{
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "capability_binding_cockpit_overview",
        "targetOperation": "git_status"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    assert_eq!(grant.allowed_capabilities, vec!["capability::execute"]);
    assert_eq!(grant.network_policy, "none");
    assert!(!grant.allowed_resource_kinds.is_empty());
    assert_invocation_scopes(
        &invocation,
        &[
            "capability.execute",
            "capability_binding.read",
            "resource.read",
        ],
    );
    for expected_kind in [
        "capability_binding_request",
        "capability_binding_decision",
        "capability_binding_policy",
        "capability_replacement_candidate",
        "capability_route_binding",
        "capability_route_activation",
        "capability_route_event",
        "capability_route_rollback",
        "capability_shadow_trial_request",
        "capability_shadow_trial_decision",
        "capability_shadow_trial_run",
        "capability_shadow_trial_evidence",
    ] {
        assert!(
            grant
                .allowed_resource_kinds
                .contains(&expected_kind.to_owned()),
            "cockpit overview grant missing kind {expected_kind}: {:?}",
            grant.allowed_resource_kinds
        );
        assert!(
            grant
                .resource_selectors
                .contains(&format!("kind:{expected_kind}")),
            "cockpit overview grant missing selector kind:{expected_kind}: {:?}",
            grant.resource_selectors
        );
    }
    assert!(
        grant
            .resource_selectors
            .contains(&"session:session-grant".to_owned()),
        "cockpit overview grant should remain session-scoped: {:?}",
        grant.resource_selectors
    );
    assert!(
        !grant
            .allowed_resource_kinds
            .contains(&"agent_state".to_owned()),
        "cockpit overview must not inherit agent_state authority"
    );
    assert!(
        !grant
            .allowed_authority_scopes
            .contains(&"capability_binding.write".to_owned()),
        "cockpit overview must stay read-only"
    );
}

#[tokio::test]
async fn capability_shadow_trial_runtime_grants_authorize_exact_trial_kinds() {
    for (operation, write) in [
        ("capability_shadow_trial_request_record", true),
        ("capability_shadow_trial_decision_record", true),
        ("capability_shadow_trial_run_record", true),
        ("capability_shadow_trial_evidence_inspect", false),
    ] {
        let payload = match operation {
            "capability_shadow_trial_request_record" => json!({
                "operation": operation,
                "title": "Runtime grant contract fixture",
                "targetOperation": "git_status",
                "currentBuiltInOwner": "domains::capability::operations::git",
                "ownershipClass": "adapter_replaceable",
                "replacementTarget": "replace",
                "bindingMode": "shadow",
                "candidateAdapter": {},
                "authorityConstraints": {
                    "networkPolicy": "none",
                    "authorityScopes": [],
                    "resourceKinds": [],
                    "resourceSelectors": []
                },
                "contractEvidenceRefs": [],
                "evidenceRefs": [],
                "staleVersionGuard": {},
                "rollbackRef": {"kind": "test", "resourceId": "rollback"},
                "disableRef": {"kind": "test", "resourceId": "disable"},
                "abortRef": {"kind": "test", "resourceId": "abort"},
                "rationale": "Exercise grant derivation after structural validation.",
                "idempotencyKey": format!("{operation}-runtime-grant")
            }),
            "capability_shadow_trial_decision_record" => json!({
                "operation": operation,
                "capabilityShadowTrialRequestResourceId": "capability_shadow_trial_request:test",
                "expectedCapabilityShadowTrialRequestVersionId": "version-request",
                "decision": "approved",
                "reason": "Exercise grant derivation after structural validation.",
                "idempotencyKey": format!("{operation}-runtime-grant")
            }),
            "capability_shadow_trial_run_record" => json!({
                "operation": operation,
                "capabilityShadowTrialDecisionResourceId": "capability_shadow_trial_decision:test",
                "expectedCapabilityShadowTrialDecisionVersionId": "version-decision",
                "builtInProjection": shadow_trial_grant_projection("built-in"),
                "candidateProjection": shadow_trial_grant_projection("candidate"),
                "idempotencyKey": format!("{operation}-runtime-grant")
            }),
            "capability_shadow_trial_evidence_inspect" => json!({
                "operation": operation,
                "capabilityShadowTrialEvidenceResourceId": "capability_shadow_trial_evidence:test"
            }),
            _ => unreachable!("covered shadow operation"),
        };
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_eq!(grant.allowed_capabilities, vec!["capability::execute"]);
        assert_eq!(grant.network_policy, "none");
        for expected_kind in [
            "capability_shadow_trial_request",
            "capability_shadow_trial_decision",
            "capability_shadow_trial_run",
            "capability_shadow_trial_evidence",
        ] {
            assert!(
                grant
                    .allowed_resource_kinds
                    .contains(&expected_kind.to_owned()),
                "{operation} grant missing shadow kind {expected_kind}: {:?}",
                grant.allowed_resource_kinds
            );
            assert!(
                grant
                    .resource_selectors
                    .contains(&format!("kind:{expected_kind}")),
                "{operation} grant missing selector kind:{expected_kind}: {:?}",
                grant.resource_selectors
            );
        }
        for forbidden_kind in [
            "capability_replacement_candidate",
            "capability_route_binding",
            "capability_route_activation",
            "capability_route_event",
            "capability_route_rollback",
            "agent_state",
        ] {
            assert!(
                !grant
                    .allowed_resource_kinds
                    .contains(&forbidden_kind.to_owned()),
                "{operation} shadow grant must not inherit {forbidden_kind}"
            );
        }
        assert_invocation_scopes(
            &invocation,
            if write {
                &[
                    "capability.execute",
                    "capability_binding.read",
                    "capability_binding.write",
                    "resource.read",
                    "resource.write",
                ]
            } else {
                &[
                    "capability.execute",
                    "capability_binding.read",
                    "resource.read",
                ]
            },
        );
        assert_eq!(
            grant
                .allowed_authority_scopes
                .contains(&"capability_binding.write".to_owned()),
            write,
            "{operation} write scope drifted: {:?}",
            grant.allowed_authority_scopes
        );
    }
}

fn shadow_trial_grant_projection(role: &str) -> Value {
    json!({
        "operation": "git_status",
        "status": "clean",
        "headState": "known",
        "indexState": "known",
        "worktreeState": "clean",
        "evidenceRef": {
            "kind": "test",
            "resourceId": format!("evidence-{role}"),
            "role": role
        }
    })
}

#[tokio::test]
async fn procedural_state_runtime_grant_authorizes_only_selected_read_kind() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "procedural_state_inspect",
        "proceduralKind": "hook",
        "proceduralRecordResourceId": "procedural_record:hook:runtime-grant"
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
async fn procedural_module_runtime_grants_are_exact_and_metadata_only() {
    let cases = [
        (
            json!({
                "operation": "procedural_definition_record",
                "proceduralKind": "skill",
                "definitionId": "grant.skill",
                "summary": "Metadata only skill definition",
                "idempotencyKey": "procedural-definition-record-grant"
            }),
            true,
            vec!["procedural_record"],
            vec!["kind:procedural_record", "proceduralKind:skill"],
        ),
        (
            json!({
                "operation": "procedural_activation_request_record",
                "proceduralKind": "hook",
                "proceduralRecordResourceId": "procedural_record:hook:grant",
                "activationRequestId": "grant-hook-request",
                "idempotencyKey": "procedural-activation-request-grant"
            }),
            true,
            vec!["procedural_record", "procedural_activation_request"],
            vec![
                "kind:procedural_record",
                "kind:procedural_activation_request",
                "resource:procedural_record:hook:grant",
                "proceduralKind:hook",
            ],
        ),
        (
            json!({
                "operation": "procedural_activation_decision_record",
                "proceduralKind": "hook",
                "proceduralActivationRequestResourceId": "procedural_activation_request:grant",
                "activationDecisionId": "grant-hook-decision",
                "decision": "deny_activation",
                "reason": "Pending validation",
                "idempotencyKey": "procedural-activation-decision-grant"
            }),
            true,
            vec![
                "procedural_record",
                "procedural_activation_request",
                "procedural_activation_decision",
            ],
            vec![
                "kind:procedural_record",
                "kind:procedural_activation_request",
                "kind:procedural_activation_decision",
                "resource:procedural_activation_request:grant",
                "proceduralKind:hook",
            ],
        ),
    ];

    for (payload, write_allowed, expected_kinds, expected_selectors) in cases {
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_procedural_module_runtime_grant(
            &grant,
            write_allowed,
            &expected_kinds,
            &expected_selectors,
        );
    }
}

#[tokio::test]
async fn memory_query_decision_runtime_grants_are_read_only_and_resource_scoped() {
    for (operation, kinds, id_field, resource_id) in [
        (
            "memory_status",
            vec!["memory_engine", "memory_policy"],
            None,
            None,
        ),
        ("memory_list", vec!["memory_record"], None, None),
        (
            "memory_inspect",
            vec!["memory_record"],
            Some("recordResourceId"),
            Some("memory_record:runtime-grant"),
        ),
        ("memory_query_list", vec!["memory_query"], None, None),
        (
            "memory_query_inspect",
            vec!["memory_query"],
            Some("queryResourceId"),
            Some("memory_query:runtime-grant"),
        ),
        ("memory_decision_list", vec!["memory_decision"], None, None),
        (
            "memory_decision_inspect",
            vec!["memory_decision"],
            Some("decisionResourceId"),
            Some("memory_decision:runtime-grant"),
        ),
    ] {
        let mut payload = json!({"operation": operation});
        if let (Some(field), Some(resource_id)) = (id_field, resource_id) {
            payload[field] = json!(resource_id);
        }
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_memory_evidence_runtime_grant_is_read_only(&grant, &kinds, resource_id);
    }
}

#[tokio::test]
async fn module_registry_list_runtime_grant_is_read_only_and_kind_scoped() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "module_list"
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
        "moduleManifestResourceId": "module_manifest:module_registry"
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
async fn canonical_exact_contracts_reach_runtime_grant_derivation() {
    let payloads = [
        json!({"operation": "catalog_search"}),
        json!({
            "operation": "catalog_conformance",
            "idempotencyKey": "canonical-catalog-conformance"
        }),
        json!({
            "operation": "catalog_inspect",
            "kind": "function",
            "id": "execute::git_status"
        }),
        json!({"operation": "capability_binding_cockpit_overview"}),
        json!({
            "operation": "repository_tree_snapshot",
            "repositoryRef": {"kind": "repository", "id": "repository"},
            "rootRef": {"kind": "workspace", "id": "root"},
            "treeObjectRef": "tree-object",
            "idempotencyKey": "canonical-repository-snapshot"
        }),
        json!({"operation": "repository_tree_list"}),
        json!({
            "operation": "repository_tree_inspect",
            "repositoryTreeResourceId": "repository_tree_snapshot:session:test"
        }),
        json!({
            "operation": "job_start",
            "command": "printf test",
            "idempotencyKey": "canonical-job-start"
        }),
        json!({"operation": "job_status", "jobResourceId": "job_process:test"}),
        json!({"operation": "job_list"}),
        json!({"operation": "job_log", "jobResourceId": "job_process:test"}),
        json!({
            "operation": "job_cancel",
            "jobResourceId": "job_process:test",
            "idempotencyKey": "canonical-job-cancel"
        }),
        json!({
            "operation": "process_run",
            "command": "printf test",
            "idempotencyKey": "canonical-process-run"
        }),
        json!({"operation": "trace_list"}),
        json!({"operation": "trace_get", "traceRecordId": "trace_record:test"}),
    ];

    for payload in payloads {
        let operation = payload["operation"].as_str().expect("operation").to_owned();
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");
        assert!(
            grant
                .allowed_capabilities
                .contains(&"capability::execute".to_owned()),
            "{operation} must reach the canonical execute handler"
        );
        assert!(
            !grant
                .resource_selectors
                .iter()
                .any(|selector| selector == "*"),
            "{operation} must not derive wildcard resource authority"
        );
    }
}

#[tokio::test]
async fn diagnostic_read_runtime_grant_has_no_state_authority() {
    for (payload, expected_kind) in [
        (
            json!({
                "operation": "trace_list",
                "limit": 25
            }),
            "trace_record",
        ),
        (
            json!({
                "operation": "trace_get",
                "traceRecordId": "trace_record:runtime-grant"
            }),
            "trace_record",
        ),
        (
            json!({
                "operation": "log_recent",
                "limit": 25
            }),
            "log_entry",
        ),
        (
            json!({
                "operation": "replay_manifest"
            }),
            "session",
        ),
    ] {
        let operation = payload
            .get("operation")
            .and_then(Value::as_str)
            .expect("operation");
        let operation = operation.to_owned();
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_eq!(grant.network_policy, "none");
        assert_eq!(grant.allowed_capabilities, vec!["capability::execute"]);
        assert_eq!(grant.allowed_authority_scopes, vec!["capability.execute"]);
        assert_eq!(
            grant.allowed_resource_kinds,
            vec![expected_kind.to_owned()],
            "{operation} must derive only its own evidence resource kind"
        );
        assert_eq!(
            grant.resource_selectors,
            vec![format!("kind:{expected_kind}")],
            "{operation} must derive only its own evidence resource selector"
        );
        assert_invocation_scopes(&invocation, &["capability.execute"]);
        assert!(
            !grant
                .allowed_resource_kinds
                .contains(&"agent_state".to_owned()),
            "{operation} must not inherit agent_state authority"
        );
        for forbidden in ["state::get", "state::set", "state::list"] {
            assert!(
                !grant.allowed_capabilities.contains(&forbidden.to_owned()),
                "{operation} grant must not include {forbidden}"
            );
        }
        for forbidden in ["state.read", "state.write"] {
            assert!(
                !grant
                    .allowed_authority_scopes
                    .contains(&forbidden.to_owned()),
                "{operation} grant must not include {forbidden}"
            );
        }
    }
}

#[tokio::test]
async fn subagent_task_list_runtime_grant_authorizes_only_read_projection_kind() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "subagent_task_list",
        "limit": 10
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
        "subagentTaskResourceId": "subagent_task:runtime-grant"
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
            "subagentTaskResourceId": "subagent_task:runtime-grant"
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
        "subagentTaskResourceId": "subagent_task:delegated-runtime-grant"
    });
    let runtime_grant = derive_capability_runtime_grant(
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
        .inspect_authority_grant(&runtime_grant.grant_id)
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

#[test]
fn unsupported_subagent_task_operation_is_rejected_before_grant_derivation() {
    let error = validate_operation_payload(&json!({
        "operation": "subagent_task_create",
        "idempotencyKey": "subagent-task-create-no-grant"
    }))
    .expect_err("unsupported operations must fail before runtime authority derivation");

    assert!(error.to_string().contains("subagent_task_create"));
    assert!(error.to_string().contains("catalog_search"));
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
        vec!["subagent_task".to_owned()]
    );
    let mut expected_selectors = vec!["kind:subagent_task".to_owned()];
    if grant
        .resource_selectors
        .contains(&"resource:subagent_task:runtime-grant".to_owned())
    {
        expected_selectors.push("resource:subagent_task:runtime-grant".to_owned());
    }
    assert_eq!(grant.resource_selectors, expected_selectors);
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
        vec!["capability::execute".to_owned()]
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
    expected_kinds: &[&str],
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
    let mut actual_kinds = grant.allowed_resource_kinds.clone();
    actual_kinds.sort();
    let mut expected_kinds_sorted = expected_kinds
        .iter()
        .map(|kind| (*kind).to_owned())
        .collect::<Vec<_>>();
    expected_kinds_sorted.sort();
    assert_eq!(actual_kinds, expected_kinds_sorted);
    for expected_kind in expected_kinds {
        assert!(
            grant
                .resource_selectors
                .contains(&format!("kind:{expected_kind}")),
            "memory evidence grant should include selector kind:{expected_kind}"
        );
    }
    for forbidden_kind in [
        "agent_state",
        "memory_engine",
        "memory_policy",
        "memory_record",
        "memory_query",
        "memory_decision",
        "memory_prompt_trace",
        "web_source",
        "subagent_task",
        "worker_package",
    ] {
        if expected_kinds.contains(&forbidden_kind) {
            continue;
        }
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
        vec!["capability::execute".to_owned()]
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
        vec!["capability::execute".to_owned()]
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
        vec!["procedural_record".to_owned()]
    );
    for selector in [
        "kind:procedural_record".to_owned(),
        format!("proceduralKind:{expected_procedural_kind}"),
    ] {
        assert!(
            grant.resource_selectors.contains(&selector),
            "procedural read grant should include selector {selector}"
        );
    }
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
        vec!["capability::execute".to_owned()]
    );
}

fn assert_procedural_module_runtime_grant(
    grant: &crate::engine::EngineGrant,
    write_allowed: bool,
    expected_kinds: &[&str],
    expected_selectors: &[&str],
) {
    assert_eq!(grant.network_policy, "none");
    for scope in ["procedural.read", "resource.read"] {
        assert!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            "procedural module grant should include {scope}"
        );
    }
    for scope in ["procedural.write", "resource.write"] {
        assert_eq!(
            grant.allowed_authority_scopes.contains(&scope.to_owned()),
            write_allowed,
            "procedural module write scope {scope} mismatch"
        );
    }
    for forbidden_scope in [
        "state.read",
        "state.write",
        "filesystem.write",
        "git.write",
        "jobs.write",
        "web.write",
        "subagents.write",
        "module_install.write",
    ] {
        assert!(
            !grant
                .allowed_authority_scopes
                .contains(&forbidden_scope.to_owned()),
            "procedural module grant must not include {forbidden_scope}"
        );
    }
    let mut actual_kinds = grant.allowed_resource_kinds.clone();
    actual_kinds.sort();
    let mut expected_kinds_sorted = expected_kinds
        .iter()
        .map(|kind| (*kind).to_owned())
        .collect::<Vec<_>>();
    expected_kinds_sorted.sort();
    assert_eq!(actual_kinds, expected_kinds_sorted);
    for selector in expected_selectors {
        assert!(
            grant.resource_selectors.contains(&(*selector).to_owned()),
            "procedural module grant should include selector {selector}"
        );
    }
    for forbidden_kind in [
        "agent_state",
        "module_manifest",
        "module_proposal",
        "worker_package",
        "web_source",
        "job_process",
        "execution_output",
        "subagent_task",
    ] {
        assert!(
            !grant
                .allowed_resource_kinds
                .contains(&forbidden_kind.to_owned()),
            "procedural module grant must not include kind {forbidden_kind}"
        );
        assert!(
            !grant
                .resource_selectors
                .contains(&format!("kind:{forbidden_kind}")),
            "procedural module grant must not include selector kind:{forbidden_kind}"
        );
    }
    assert_eq!(grant.allowed_capabilities, vec!["capability::execute"]);
}
