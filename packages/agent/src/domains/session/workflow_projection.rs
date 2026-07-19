//! Minimal Level 2 workflow projection for session reconstruction.
//!
//! This module does not own workflow state. Context Control resources, session
//! lineage rows, and Delegation resources remain canonical in their domains.
//! The projection is a bounded reconnect view for first-party clients.

use serde_json::{Value, json};

use crate::domains::session::Deps;
use crate::engine::{EngineResourceInspection, EngineResourceScope, ListResources};
use crate::shared::server::errors::CapabilityError;

const DELEGATION_KIND: &str = "delegation";
const MAX_ACTIVE_DELEGATIONS: usize = 3;
const MAX_RECENT_DELEGATIONS: usize = 10;

pub(super) async fn session_workflow_snapshot(
    deps: &Deps,
    session_id: &str,
) -> Result<Value, CapabilityError> {
    let scope = EngineResourceScope::Session(session_id.to_owned());
    let context_revision = context_revision(deps, &scope).await?;
    let delegation_deps = crate::domains::delegation::Deps::from_components(
        deps.engine_host.clone(),
        deps.event_store.clone(),
        deps.orchestrator.clone(),
        deps.session_manager.clone(),
    );
    crate::domains::delegation::service::repair_scope(&delegation_deps, &scope).await?;
    let (active_delegations, recent_delegations, truncated) =
        delegation_summaries(deps, &scope).await?;
    let branch_lineage = branch_lineage(deps, session_id).await?;

    Ok(json!({
        "schemaVersion": "tron.session_workflows.v1",
        "contextRevision": context_revision,
        "branchLineage": branch_lineage,
        "activeDelegations": active_delegations,
        "recentDelegations": recent_delegations,
        "truncated": truncated
    }))
}

async fn context_revision(
    deps: &Deps,
    scope: &EngineResourceScope,
) -> Result<Value, CapabilityError> {
    let action = latest_inspection(
        deps,
        crate::domains::context_control::CONTEXT_CONTROL_ACTION_KIND,
        scope,
    )
    .await?;
    Ok(project_context_revision(action.as_ref()))
}

async fn delegation_summaries(
    deps: &Deps,
    scope: &EngineResourceScope,
) -> Result<(Vec<Value>, Vec<Value>, bool), CapabilityError> {
    // Active work is queried independently so a long terminal history can
    // never hide a still-running child from the reconnect projection.
    let mut active_resources = Vec::new();
    for lifecycle in ["preparing", "running"] {
        active_resources.extend(
            deps.engine_host
                .list_resources(ListResources {
                    kind: Some(DELEGATION_KIND.to_owned()),
                    scope: Some(scope.clone()),
                    lifecycle: Some(lifecycle.to_owned()),
                    limit: MAX_ACTIVE_DELEGATIONS + 1,
                })
                .await
                .map_err(engine_error)?,
        );
    }
    active_resources.truncate(MAX_ACTIVE_DELEGATIONS);

    let mut recent_resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(DELEGATION_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: None,
            limit: MAX_RECENT_DELEGATIONS + MAX_ACTIVE_DELEGATIONS + 1,
        })
        .await
        .map_err(engine_error)?;
    recent_resources.retain(|resource| !delegation_is_active_state(&resource.lifecycle));
    let truncated = recent_resources.len() > MAX_RECENT_DELEGATIONS;
    recent_resources.truncate(MAX_RECENT_DELEGATIONS);

    let active = inspect_delegations(deps, active_resources).await?;
    let recent = inspect_delegations(deps, recent_resources).await?;
    Ok((active, recent, truncated))
}

async fn inspect_delegations(
    deps: &Deps,
    resources: Vec<crate::engine::EngineResource>,
) -> Result<Vec<Value>, CapabilityError> {
    let mut summaries = Vec::with_capacity(resources.len());
    for resource in resources {
        if let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        {
            if let Some(version) = current_version(&inspection) {
                summaries.push(project_delegation(
                    inspection.resource.lifecycle.as_str(),
                    &version.payload,
                ));
            }
        }
    }
    Ok(summaries)
}

async fn latest_inspection(
    deps: &Deps,
    kind: &str,
    scope: &EngineResourceScope,
) -> Result<Option<EngineResourceInspection>, CapabilityError> {
    let resource = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(kind.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: None,
            limit: 1,
        })
        .await
        .map_err(engine_error)?
        .into_iter()
        .next();
    let Some(resource) = resource else {
        return Ok(None);
    };
    deps.engine_host
        .inspect_resource(&resource.resource_id)
        .await
        .map_err(engine_error)
}

async fn branch_lineage(deps: &Deps, session_id: &str) -> Result<Value, CapabilityError> {
    let store = deps.event_store.clone();
    let session_id = session_id.to_owned();
    crate::shared::server::context::run_blocking_task("session.workflow_lineage", move || {
        let session = store
            .get_session(&session_id)
            .map_err(|error| CapabilityError::Internal {
                message: format!("Failed to load branch lineage: {error}"),
            })?
            .ok_or_else(|| CapabilityError::NotFound {
                code: crate::shared::server::errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;
        Ok(json!({
            "isBranch": session.parent_session_id.is_some()
        }))
    })
    .await
}

fn project_context_revision(action: Option<&EngineResourceInspection>) -> Value {
    if action.is_none() {
        return Value::Null;
    }
    let action_version = action.and_then(current_version);
    let action_payload = action_version.map(|version| &version.payload);

    json!({
        "state": action.map(|inspection| inspection.resource.lifecycle.as_str()).unwrap_or("active"),
        "kind": action_payload.and_then(|payload| payload.pointer("/action/kind")).and_then(Value::as_str),
        "reason": action_payload
            .and_then(|payload| payload.pointer("/result/reason"))
            .or_else(|| action_payload.and_then(|payload| payload.pointer("/action/reason")))
            .and_then(Value::as_str)
    })
}

fn current_version(
    inspection: &EngineResourceInspection,
) -> Option<&crate::engine::EngineResourceVersion> {
    let current = inspection.resource.current_version_id.as_deref()?;
    inspection
        .versions
        .iter()
        .find(|version| version.version_id == current)
}

fn project_delegation(state: &str, payload: &Value) -> Value {
    json!({
        "state": state,
        "objectiveSummary": payload.get("objectiveSummary").cloned().unwrap_or(Value::Null),
        // Acceptance is the information boundary. A ready-but-unaccepted
        // child result is intentionally not copied into this UI read model.
        "resultSummary": if state == "accepted" {
            payload.get("resultSummary").cloned().unwrap_or(Value::Null)
        } else {
            Value::Null
        }
    })
}

fn delegation_is_active_state(state: &str) -> bool {
    matches!(state, "preparing" | "running")
}

fn engine_error(error: crate::engine::EngineError) -> CapabilityError {
    CapabilityError::Internal {
        message: format!("Workflow projection failed: {error}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::durability::resources::EngineResourceVersionState;
    use crate::engine::{
        ActorId, EngineResource, EngineResourceInspection, EngineResourceVersion, TraceId, WorkerId,
    };
    use chrono::Utc;

    fn inspection(kind: &str, lifecycle: &str, payload: Value) -> EngineResourceInspection {
        let resource_id = format!("{kind}:one");
        let version_id = format!("{kind}:version:one");
        EngineResourceInspection {
            resource: EngineResource {
                resource_id: resource_id.clone(),
                kind: kind.to_owned(),
                schema_id: format!("tron.resource.{kind}.v1"),
                scope: EngineResourceScope::Session("session-one".to_owned()),
                owner_worker_id: WorkerId::new("test").unwrap(),
                owner_actor_id: ActorId::new("system:test").unwrap(),
                lifecycle: lifecycle.to_owned(),
                policy: json!({}),
                current_version_id: Some(version_id.clone()),
                trace_id: TraceId::generate(),
                created_by_invocation_id: None,
                created_at: Utc::now(),
                updated_at: Utc::now(),
            },
            versions: vec![EngineResourceVersion {
                version_id,
                resource_id,
                parent_version_id: None,
                content_hash: "hash".to_owned(),
                state: EngineResourceVersionState::Available,
                payload,
                locations: vec![],
                created_by_invocation_id: None,
                trace_id: TraceId::generate(),
                created_at: Utc::now(),
            }],
            outgoing_links: vec![],
            incoming_links: vec![],
            events: vec![],
        }
    }

    #[test]
    fn context_revision_is_a_projection_over_source_owned_resources() {
        let action = inspection(
            crate::domains::context_control::CONTEXT_CONTROL_ACTION_KIND,
            "succeeded",
            json!({
                "action": {"kind": "compact", "reason": "long session", "sessionId": "session-one"},
                "createdAt": "2026-07-18T00:00:00Z",
                "updatedAt": "2026-07-18T00:00:01Z"
            }),
        );
        let projection = project_context_revision(Some(&action));
        assert_eq!(projection["kind"], "compact");
        assert_eq!(projection["state"], "succeeded");
        assert!(projection.get("workflowRef").is_none());
        assert!(projection.get("preflight").is_none());
    }

    #[test]
    fn delegation_projection_excludes_raw_handoff_and_authority_payloads() {
        let delegation = inspection(
            DELEGATION_KIND,
            "running",
            json!({
                "parentSessionId": "session-one",
                "childSessionId": "session-child",
                "objectiveSummary": "Review the persistence boundary",
                "prompt": "raw prompt must not project",
                "authority": {"grant": "secret"},
                "resultSummary": null,
                "resultRefs": [],
                "createdAt": "2026-07-18T00:00:00Z",
                "updatedAt": "2026-07-18T00:00:01Z"
            }),
        );

        let version = current_version(&delegation).unwrap();
        let projection = project_delegation(&delegation.resource.lifecycle, &version.payload);
        let rendered = serde_json::to_string(&projection).unwrap();
        assert_eq!(
            projection["objectiveSummary"],
            "Review the persistence boundary"
        );
        assert!(projection.get("childSessionId").is_none());
        assert!(projection["resultSummary"].is_null());
        assert!(!rendered.contains("raw prompt"));
        assert!(!rendered.contains("secret"));
    }
}
