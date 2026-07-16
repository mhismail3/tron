use super::*;
use crate::engine::{EngineResourceScope, ListResources};

#[tokio::test]
async fn catalog_read_runtime_grants_have_authority_without_resource_custody() {
    for payload in [
        json!({
            "operation": "catalog_search",
            "text": "git_status"
        }),
        json!({
            "operation": "catalog_inspect",
            "kind": "function",
            "id": "execute::git_status"
        }),
    ] {
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_eq!(grant.network_policy, "none");
        assert_eq!(grant.allowed_capabilities, vec!["capability::execute"]);
        assert_eq!(
            grant.allowed_authority_scopes,
            vec!["capability.execute", "catalog_discovery.read"]
        );
        assert!(
            grant.allowed_resource_kinds.is_empty(),
            "catalog reads do not own resource custody"
        );
        assert!(
            grant.resource_selectors.is_empty(),
            "catalog reads do not need fabricated kind selectors"
        );
        assert_invocation_scopes(
            &invocation,
            &["capability.execute", "catalog_discovery.read"],
        );
        for forbidden in ["state::get", "state::set", "state::list"] {
            assert!(
                !grant.allowed_capabilities.contains(&forbidden.to_owned()),
                "catalog discovery grant must not include {forbidden}"
            );
        }
        for forbidden in ["state.read", "state.write", "resource.read"] {
            assert!(
                !grant
                    .allowed_authority_scopes
                    .contains(&forbidden.to_owned()),
                "catalog discovery grant must not include {forbidden}"
            );
        }
    }
}

#[tokio::test]
async fn catalog_conformance_runtime_grant_authorizes_exact_report_write() {
    let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
        "operation": "catalog_conformance",
        "reason": "Verify the current visible capability catalog",
        "idempotencyKey": "catalog-conformance-runtime-grant"
    }))
    .await;
    let grant = engine_host
        .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
        .await
        .expect("inspect grant")
        .expect("derived grant");

    assert_eq!(grant.network_policy, "none");
    assert_eq!(grant.allowed_capabilities, vec!["capability::execute"]);
    assert_eq!(
        grant.allowed_authority_scopes,
        vec![
            "capability.execute",
            "catalog_discovery.write",
            "resource.write"
        ]
    );
    assert_eq!(
        grant.allowed_resource_kinds,
        vec![crate::engine::CATALOG_DISCOVERY_REPORT_KIND]
    );
    assert_eq!(
        grant.resource_selectors,
        vec![format!(
            "kind:{}",
            crate::engine::CATALOG_DISCOVERY_REPORT_KIND
        )]
    );
    assert_invocation_scopes(
        &invocation,
        &[
            "capability.execute",
            "catalog_discovery.write",
            "resource.write",
        ],
    );
}

#[test]
fn durable_operations_use_caller_key_not_provider_call_for_wrapper_replay() {
    let payload = json!({
        "operation": "catalog_conformance",
        "reason": "Verify catalog",
        "idempotencyKey": "stable-report-key"
    });
    let first = model_capability_invocation_idempotency_key(
        Some("run-a"),
        "session-a",
        1,
        "provider-call-a",
        "execute",
        "/workspace",
        Some("workspace-a"),
        &payload,
    );
    let second = model_capability_invocation_idempotency_key(
        Some("run-b"),
        "session-a",
        9,
        "provider-call-b",
        "execute",
        "/another-workspace-path",
        Some("workspace-a"),
        &payload,
    );
    assert_eq!(
        first, second,
        "provider call identity must not control replay"
    );
    assert!(!first.contains("stable-report-key"));

    let conflicting_payload = json!({
        "operation": "catalog_conformance",
        "reason": "Different semantic request",
        "idempotencyKey": "stable-report-key"
    });
    let conflict = model_capability_invocation_idempotency_key(
        None,
        "session-a",
        2,
        "provider-call-c",
        "execute",
        "/workspace",
        None,
        &conflicting_payload,
    );
    assert_eq!(
        first, conflict,
        "the engine ledger must detect conflicting reuse"
    );

    let different_key_payload = json!({
        "operation": "catalog_conformance",
        "reason": "Verify catalog",
        "idempotencyKey": "different-report-key"
    });
    let different = model_capability_invocation_idempotency_key(
        None,
        "session-a",
        2,
        "provider-call-d",
        "execute",
        "/workspace",
        None,
        &different_key_payload,
    );
    assert_ne!(first, different);

    let goal_payload = json!({
        "operation": "goal_create",
        "objective": "prove generic caller-key replay",
        "idempotencyKey": "stable-goal-key"
    });
    let goal_first = model_capability_invocation_idempotency_key(
        Some("run-a"),
        "session-a",
        1,
        "provider-call-a",
        "execute",
        "/workspace",
        Some("workspace-a"),
        &goal_payload,
    );
    let goal_replay = model_capability_invocation_idempotency_key(
        Some("run-b"),
        "session-a",
        7,
        "provider-call-b",
        "execute",
        "/workspace",
        Some("workspace-a"),
        &goal_payload,
    );
    assert_eq!(goal_first, goal_replay);
    assert_ne!(goal_first, first, "operation identity scopes caller keys");
}

#[test]
fn context_boundaries_reenter_the_domain_for_caller_key_replay() {
    for operation in ["context_control_compact", "context_control_clear"] {
        let payload = json!({
            "operation": operation,
            "idempotencyKey": "same-domain-action"
        });
        let first = model_capability_invocation_idempotency_key(
            Some("run-a"),
            "session-a",
            1,
            "provider-call-a",
            "execute",
            "/workspace",
            Some("workspace-a"),
            &payload,
        );
        let replay = model_capability_invocation_idempotency_key(
            Some("run-b"),
            "session-a",
            2,
            "provider-call-b",
            "execute",
            "/workspace",
            Some("workspace-a"),
            &payload,
        );
        assert_ne!(
            first, replay,
            "the outer ledger must not bypass {operation}'s durable replay owner"
        );
    }
}

#[tokio::test]
async fn catalog_conformance_replays_end_to_end_without_duplicate_evidence() {
    let server = crate::shared::server::test_support::make_test_context();
    let surface = resolve_provider_primitive_surface(&server.engine_host, "catalog-replay", None)
        .await
        .expect("provider capability surface");
    let emitter = Arc::new(EventEmitter::new());
    let cancel = CancellationToken::new();
    let registry = Arc::new(InvocationAbortRegistry::new());
    let mut ctx = capability_exec_ctx(&surface, &emitter, &cancel, &registry);
    ctx.engine_host = Some(&server.engine_host);
    let tempdir = tempfile::tempdir().expect("catalog replay workspace");
    let payload = json!({
        "operation": "catalog_conformance",
        "reason": "Replay-safe catalog verification",
        "idempotencyKey": "catalog-conformance-e2e-replay"
    });
    let before_cursor = server
        .engine_host
        .latest_stream_cursor(crate::domains::catalog_discovery::CATALOG_DISCOVERY_TOPIC)
        .await
        .expect("initial catalog discovery cursor");

    let first = execute_capability_invocation(
        &CapabilityInvocationDraft::new("provider-call-first", "execute", payload_object(&payload)),
        "catalog-replay",
        tempdir.path().to_str().expect("utf8 workspace"),
        &ctx,
    )
    .await;
    assert_eq!(
        first.result.is_error,
        Some(false),
        "first report must succeed"
    );
    let first_details = first.result.details.as_ref().expect("first details");
    assert_eq!(first_details["engineOutcome"]["replayed"], false);
    let first_resource_id = first_details["catalogDiscovery"]["reportResourceId"]
        .as_str()
        .expect("first report resource id");
    assert!(!first_resource_id.contains("catalog-conformance-e2e-replay"));
    assert!(!first_resource_id.contains("provider-call-first"));
    let after_first_cursor = server
        .engine_host
        .latest_stream_cursor(crate::domains::catalog_discovery::CATALOG_DISCOVERY_TOPIC)
        .await
        .expect("catalog cursor after first report");
    assert!(after_first_cursor > before_cursor);

    let second = execute_capability_invocation(
        &CapabilityInvocationDraft::new(
            "provider-call-second",
            "execute",
            payload_object(&payload),
        ),
        "catalog-replay",
        tempdir.path().to_str().expect("utf8 workspace"),
        &ctx,
    )
    .await;
    assert_eq!(second.result.is_error, Some(false), "replay must succeed");
    let second_details = second.result.details.as_ref().expect("replay details");
    assert_eq!(second_details["engineOutcome"]["replayed"], true);
    assert!(
        second_details["engineOutcome"]["replaySourceInvocationRef"]
            .as_str()
            .is_some_and(|value| !value.is_empty())
    );
    assert_eq!(
        second_details["catalogDiscovery"]["reportResourceId"],
        first_resource_id
    );
    assert_eq!(
        server
            .engine_host
            .latest_stream_cursor(crate::domains::catalog_discovery::CATALOG_DISCOVERY_TOPIC)
            .await
            .expect("catalog cursor after replay"),
        after_first_cursor,
        "replay must not publish a second report event"
    );

    let resources = server
        .engine_host
        .list_resources(ListResources {
            kind: Some(crate::engine::CATALOG_DISCOVERY_REPORT_KIND.to_owned()),
            scope: Some(EngineResourceScope::Session("catalog-replay".to_owned())),
            lifecycle: None,
            limit: 10,
        })
        .await
        .expect("list catalog reports");
    assert_eq!(
        resources.len(),
        1,
        "replay must not duplicate report resources"
    );

    let conflict_payload = json!({
        "operation": "catalog_conformance",
        "reason": "Conflicting catalog verification",
        "idempotencyKey": "catalog-conformance-e2e-replay"
    });
    let conflict = execute_capability_invocation(
        &CapabilityInvocationDraft::new(
            "provider-call-conflict",
            "execute",
            payload_object(&conflict_payload),
        ),
        "catalog-replay",
        tempdir.path().to_str().expect("utf8 workspace"),
        &ctx,
    )
    .await;
    assert_eq!(conflict.result.is_error, Some(true));
    let rendered_conflict = serde_json::to_string(&conflict.result).expect("serialize conflict");
    assert!(rendered_conflict.contains("IDEMPOTENCY_CONFLICT"));
    assert!(
        !rendered_conflict.contains("catalog-conformance-e2e-replay"),
        "provider failure must not leak the raw caller key: {rendered_conflict}"
    );
    assert_eq!(
        server
            .engine_host
            .latest_stream_cursor(crate::domains::catalog_discovery::CATALOG_DISCOVERY_TOPIC)
            .await
            .expect("catalog cursor after conflict"),
        after_first_cursor,
        "conflicting reuse must not publish evidence"
    );
}
