//! Generated UI agent-control authoring.

use super::*;

pub(super) fn agent_control_projection(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    request: &SurfaceAuthoringRequest,
) -> Result<TargetProjection> {
    if request.layout_profile != AGENT_CONTROL_SESSION_LAYOUT_PROFILE {
        return Err(EngineError::PolicyViolation(format!(
            "agent_control target requires layoutProfile {AGENT_CONTROL_SESSION_LAYOUT_PROFILE}"
        )));
    }
    let session_id = request.target_id.as_str();
    let actor = actor_context(invocation);
    let functions = host.discover_functions(&FunctionQuery {
        actor: Some(actor.clone()),
        include_internal: false,
        ..FunctionQuery::default()
    });
    let workers = host.visible_workers(&actor);
    let session_invocations = host
        .invocations()
        .into_iter()
        .filter(|record| record.session_id.as_deref() == Some(session_id))
        .collect::<Vec<_>>();
    let failed_invocations = session_invocations
        .iter()
        .filter(|record| !record.succeeded)
        .count();
    let recent_source_control = source_control_invocation_rows(host, session_id, request)
        .into_iter()
        .take(5)
        .collect::<Vec<_>>();
    Ok(TargetProjection {
        title: "Agent Control".to_owned(),
        summary: format!(
            "{} capabilities / {} workers / {} recent session invocations",
            functions.len(),
            workers.len(),
            session_invocations.len()
        ),
        revision: host.catalog_revision().0,
        graph: json!({
            "agentControl": {
                "sessionId": session_id,
                "catalogRevision": host.catalog_revision().0,
                "capabilityCount": functions.len(),
                "workerCount": workers.len(),
                "sessionInvocationCount": session_invocations.len(),
                "failedInvocationCount": failed_invocations,
                "recentSourceControl": recent_source_control,
            }
        }),
    })
}

pub(super) fn agent_control_session_layout(projection: &TargetProjection) -> Value {
    let agent = projection
        .graph
        .get("agentControl")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let recent_source_control = agent
        .get("recentSourceControl")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    json!({
        "type": "Section",
        "props": {"title": projection.title},
        "children": [
            {"type": "Metric", "props": {
                "label": "Session",
                "value": agent
                    .get("sessionId")
                    .and_then(Value::as_str)
                    .map(display_identifier)
                    .map(Value::String)
                    .unwrap_or(Value::Null)
            }},
            {"type": "Metric", "props": {
                "label": "Catalog",
                "value": agent.get("catalogRevision").cloned().unwrap_or(Value::Null)
            }},
            {"type": "Metric", "props": {
                "label": "Capabilities",
                "value": agent.get("capabilityCount").cloned().unwrap_or(Value::Null)
            }},
            {"type": "Metric", "props": {
                "label": "Workers",
                "value": agent.get("workerCount").cloned().unwrap_or(Value::Null)
            }},
            {"type": "Metric", "props": {
                "label": "Failed invocations",
                "value": agent.get("failedInvocationCount").cloned().unwrap_or(Value::Null)
            }},
            {"type": "Disclosure", "props": {"title": "Source Control", "open": true}, "children": [
                {"type": "Button", "props": {"label": "Open source-control review", "actionId": "open-source-control"}},
                {"type": "Button", "props": {"label": "Control snapshot", "actionId": "control-snapshot"}},
                {"type": "Text", "props": {
                    "text": if recent_source_control.is_empty() {
                        json!("No recent source-control capability invocations for this session.")
                    } else {
                        json!(format!("{} recent source-control invocations are linked from server truth.", recent_source_control.len()))
                    }
                }}
            ]}
        ]
    })
}

pub(super) fn agent_control_actions(
    invocation: &crate::engine::Invocation,
    request: &SurfaceAuthoringRequest,
    functions: &[FunctionDefinition],
) -> Result<Vec<Value>> {
    let session_id = request.target_id.as_str();
    let mut actions = Vec::new();
    push_optional_action(
        &mut actions,
        invocation,
        functions,
        "open-source-control",
        "Open Source Control",
        SURFACE_FOR_TARGET_FUNCTION,
        json!({"type": "object", "additionalProperties": false, "properties": {}}),
        json!({
            "targetType": SOURCE_CONTROL_TARGET,
            "targetId": session_id,
            "purpose": "Review source-control state and actions",
            "layoutProfile": SOURCE_CONTROL_SESSION_LAYOUT_PROFILE,
            "maxPreviewBytes": 2048
        }),
    )?;
    push_optional_action(
        &mut actions,
        invocation,
        functions,
        "control-snapshot",
        "Control Snapshot",
        "control::snapshot",
        json!({"type": "object", "additionalProperties": false, "properties": {}}),
        json!({"limit": 100, "sessionId": session_id}),
    )?;
    Ok(actions)
}
