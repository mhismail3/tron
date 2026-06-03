use super::*;

const SUBAGENT_RESULT_RESOURCE_ID: &str = "agent_result:subagent:subagent-lineage-child";

fn subagent_resource_context(key: &str) -> CausalContext {
    mutating_causal(key)
        .with_session_id("parent-session")
        .with_scope("resource.write")
}

fn subagent_read_context() -> CausalContext {
    causal()
        .with_session_id("parent-session")
        .with_scope("agent.read")
}

fn subagent_ui_context(key: &str) -> CausalContext {
    mutating_causal(key)
        .with_session_id("parent-session")
        .with_scope("ui.write")
        .with_scope("resource.read")
        .with_scope("agent.read")
        .with_scope("agent.write")
}

async fn create_subagent_result_resource_with(
    handle: &EngineHostHandle,
    key: &str,
    resource_id: &str,
    session_id: &str,
    metadata: Value,
) {
    let created = handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "kind": "agent_result",
                "resourceId": resource_id,
                "scope": "session",
                "sessionId": session_id,
                "lifecycle": "final",
                "payload": {
                    "message": "Subagent completed with a bounded answer.",
                    "promotedRefs": [],
                    "decisionRefs": [],
                    "subgoalRefs": [],
                    "stopReason": "completed",
                    "tokenUsage": {"input": 11, "output": 7},
                    "metadata": metadata
                }
            }),
            subagent_resource_context(key),
        ))
        .await;
    assert_eq!(created.error, None);
}

async fn create_subagent_result_resource(handle: &EngineHostHandle) {
    create_subagent_result_resource_with(
        handle,
        "subagent-lineage-result-resource",
        SUBAGENT_RESULT_RESOURCE_ID,
        "parent-session",
        json!({
            "parentSessionId": "parent-session",
            "subagentSessionId": "subagent-lineage-child",
            "task": "Check the generated surface boundary",
            "taskProfile": {
                "id": "review",
                "label": "Review"
            },
            "modelRouting": {
                "preset": "localWhenPossible",
                "presetLabel": "Local when possible",
                "selectionStatus": "selected",
                "selectedModel": "claude-sonnet-4-6",
                "selectedModelLabel": "Claude Sonnet 4.6",
                "modelClass": "hosted",
                "hostedRouteUsed": true,
                "hostedRouteLabel": "Hosted route",
                "hostedRouteReason": "Local model is unavailable for this flow.",
                "localOptIn": true
            },
            "success": true,
            "turnsExecuted": 2,
            "durationMs": 321,
            "spawnType": "capability_agent"
        }),
    )
    .await;
}

#[tokio::test]
async fn subagent_result_and_status_read_resource_truth_without_live_manager() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    create_subagent_result_resource(&handle).await;

    let result = handle
        .invoke(host_invocation(
            "agent::subagent_result",
            json!({
                "sessionId": "parent-session",
                "subagentSessionId": "subagent-lineage-child"
            }),
            subagent_read_context(),
        ))
        .await;
    assert_eq!(result.error, None);
    let result_value = result.value.as_ref().unwrap();
    assert_eq!(result_value["subagentSessionId"], "subagent-lineage-child");
    assert_eq!(
        result_value["result"]["output"],
        "Subagent completed with a bounded answer."
    );
    assert_eq!(result_value["result"]["status"], "completed");
    assert_eq!(
        result_value["resourceRefs"][0]["resourceId"],
        SUBAGENT_RESULT_RESOURCE_ID
    );

    let status = handle
        .invoke(host_invocation(
            "agent::subagent_status",
            json!({
                "sessionId": "parent-session",
                "subagentSessionId": "subagent-lineage-child"
            }),
            subagent_read_context(),
        ))
        .await;
    assert_eq!(status.error, None);
    let status_value = status.value.as_ref().unwrap();
    assert_eq!(status_value["status"], "completed");
    assert_eq!(
        status_value["resourceRefs"][0]["resourceId"],
        SUBAGENT_RESULT_RESOURCE_ID
    );
}

#[tokio::test]
async fn generated_subagent_lineage_surface_uses_resource_truth_and_stored_actions() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();
    create_subagent_result_resource(&handle).await;

    let unrelated = handle
        .invoke(host_invocation(
            "resource::create",
            json!({
                "kind": "agent_result",
                "resourceId": "agent_result:ordinary-run",
                "scope": "session",
                "sessionId": "parent-session",
                "lifecycle": "final",
                "payload": {
                    "message": "ordinary prompt result",
                    "promotedRefs": [],
                    "decisionRefs": [],
                    "subgoalRefs": [],
                    "stopReason": "completed",
                    "tokenUsage": {},
                    "metadata": {"runId": "prompt-run"}
                }
            }),
            subagent_resource_context("subagent-lineage-unrelated-result"),
        ))
        .await;
    assert_eq!(unrelated.error, None);

    let surface = handle
        .invoke(host_invocation(
            "ui::surface_for_target",
            json!({
                "targetType": "resource_collection",
                "targetId": "agent_result:subagent",
                "purpose": "Inspect subagent lineage",
                "layoutProfile": "subagent.lineage.v1",
                "maxPreviewBytes": 512,
                "expiresAt": "2100-01-01T00:00:00Z"
            }),
            subagent_ui_context("subagent-lineage-surface"),
        ))
        .await;
    assert_eq!(surface.error, None);
    let authored = &surface.value.as_ref().unwrap()["surface"];
    assert_eq!(
        authored["authoring"]["layoutProfile"],
        "subagent.lineage.v1"
    );
    assert!(
        authored["layout"]
            .to_string()
            .contains("Check the generated surface boundary"),
        "surface should render subagent task from resource truth"
    );
    let layout = authored["layout"].to_string();
    for required in [
        "Review",
        "Local when possible",
        "Claude Sonnet 4.6",
        "Hosted route",
        "Local model is unavailable for this flow.",
    ] {
        assert!(
            layout.contains(required),
            "surface should render subagent product routing field `{required}` from resource truth"
        );
    }
    assert!(
        !authored["layout"]
            .to_string()
            .contains("ordinary prompt result"),
        "subagent lineage surface must not include ordinary agent_result resources"
    );

    let actions = authored["actions"].as_array().unwrap();
    for target in ["agent::subagent_status", "agent::subagent_result"] {
        assert!(
            actions.iter().any(|action| {
                action["targetFunctionId"] == target
                    && action["payloadTemplate"]["subagentSessionId"] == "subagent-lineage-child"
                    && action["idempotencyKeyTemplate"] == "${submission.idempotencyKey}"
                    && action["targetRevision"].is_u64()
            }),
            "missing stored subagent lineage action for {target}"
        );
    }
    assert!(
        actions
            .iter()
            .all(|action| action["targetFunctionId"] != "agent::cancel_subagent"),
        "completed subagent lineage rows must not expose a cancel action"
    );
    assert!(
        actions
            .iter()
            .all(|action| action.get("payloadTemplate").is_some()),
        "subagent generated actions must be server-authored stored templates"
    );

    let unsupported = handle
        .invoke(host_invocation(
            "ui::surface_for_target",
            json!({
                "targetType": "resource_collection",
                "targetId": "agent_result:subagent",
                "purpose": "Inspect subagent lineage",
                "layoutProfile": "subagent.unsupported.v1",
                "maxPreviewBytes": 512,
                "expiresAt": "2100-01-01T00:00:00Z"
            }),
            subagent_ui_context("subagent-lineage-unsupported-profile"),
        ))
        .await;
    assert!(
        unsupported
            .error
            .as_ref()
            .is_some_and(|error| format!("{error:?}").contains("subagent.lineage.v1")),
        "unsupported subagent collection profiles must fail closed"
    );
}

#[tokio::test]
async fn malformed_or_cross_session_subagent_resources_are_not_lineage_truth() {
    let ctx = crate::shared::server::test_support::make_test_context();
    let handle = ctx.engine_host.clone();

    create_subagent_result_resource_with(
        &handle,
        "subagent-lineage-missing-parent",
        "agent_result:subagent:missing-parent",
        "parent-session",
        json!({
            "subagentSessionId": "missing-parent",
            "task": "Malformed missing parent",
            "success": true
        }),
    )
    .await;
    create_subagent_result_resource_with(
        &handle,
        "subagent-lineage-cross-session",
        "agent_result:subagent:cross-session",
        "other-session",
        json!({
            "parentSessionId": "other-session",
            "subagentSessionId": "cross-session",
            "task": "Cross-session result",
            "success": true
        }),
    )
    .await;
    create_subagent_result_resource_with(
        &handle,
        "subagent-lineage-mismatched-id",
        "agent_result:subagent:mismatched-id",
        "parent-session",
        json!({
            "parentSessionId": "parent-session",
            "subagentSessionId": "different-id",
            "task": "Mismatched result id",
            "success": true
        }),
    )
    .await;

    for subagent_session_id in ["missing-parent", "cross-session", "mismatched-id"] {
        let result = handle
            .invoke(host_invocation(
                "agent::subagent_result",
                json!({
                    "sessionId": "parent-session",
                    "subagentSessionId": subagent_session_id
                }),
                subagent_read_context(),
            ))
            .await;
        assert!(
            result
                .error
                .as_ref()
                .is_some_and(|error| format!("{error:?}").contains("SUBAGENT_RESULT_NOT_READY")),
            "malformed or cross-session subagent resource {subagent_session_id} must not be accepted as result truth"
        );
    }

    let surface = handle
        .invoke(host_invocation(
            "ui::surface_for_target",
            json!({
                "targetType": "resource_collection",
                "targetId": "agent_result:subagent",
                "purpose": "Inspect subagent lineage",
                "layoutProfile": "subagent.lineage.v1",
                "maxPreviewBytes": 512,
                "expiresAt": "2100-01-01T00:00:00Z"
            }),
            subagent_ui_context("subagent-lineage-malformed-surface"),
        ))
        .await;
    assert_eq!(surface.error, None);
    let layout = surface.value.as_ref().unwrap()["surface"]["layout"].to_string();
    let actions = surface.value.as_ref().unwrap()["surface"]["actions"]
        .as_array()
        .unwrap();
    for forbidden in [
        "Malformed missing parent",
        "Cross-session result",
        "Mismatched result id",
    ] {
        assert!(
            !layout.contains(forbidden),
            "generated subagent lineage must omit malformed/cross-session row `{forbidden}`"
        );
    }
    for forbidden_subagent_id in ["missing-parent", "cross-session", "mismatched-id"] {
        assert!(
            actions
                .iter()
                .all(|action| action["payloadTemplate"]["subagentSessionId"]
                    != forbidden_subagent_id),
            "generated subagent lineage must not emit stored actions for malformed/cross-session resource `{forbidden_subagent_id}`"
        );
    }
}
