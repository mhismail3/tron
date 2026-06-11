//! Governance chain validation for worker activation.

use serde_json::{Value, json};

use super::worker_activation::{WorkerActivationRequest, fingerprint_json};
use crate::engine::durability::resources::{EngineResourceInspection, EngineResourceScope};
use crate::engine::kernel::types::{FunctionDefinition, VisibilityScope};
use crate::engine::primitives::runtime::{PrimitiveRuntimeHost, actor_context};
use crate::engine::{EngineError, Result};

pub(super) struct ActivationGovernance {
    pub(super) expected_function: FunctionDefinition,
    pub(super) governance_fingerprint: String,
}

pub(super) fn validate_activation_governance(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &crate::engine::Invocation,
    request: &WorkerActivationRequest,
) -> Result<ActivationGovernance> {
    let decision = require_resource(host, &request.decision_resource_id)?;
    let candidate = require_resource(host, &request.candidate_resource_id)?;
    if candidate.resource.kind != "capability_definition" {
        return Err(EngineError::PolicyViolation(format!(
            "worker activation candidate {} must be capability_definition",
            candidate.resource.resource_id
        )));
    }
    if candidate.resource.lifecycle != "reviewed" {
        return Err(EngineError::PolicyViolation(format!(
            "worker activation candidate {} must be reviewed",
            candidate.resource.resource_id
        )));
    }
    let candidate_payload = current_payload(&candidate)?;
    let candidate_function = candidate_payload
        .get("functionId")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "capability_definition {} must declare functionId",
                candidate.resource.resource_id
            ))
        })?;
    if candidate_function != request.function_id.as_str() {
        return Err(EngineError::PolicyViolation(format!(
            "capability_definition {} functionId does not match {}",
            candidate.resource.resource_id, request.function_id
        )));
    }
    let expected_function: FunctionDefinition = serde_json::from_value(
        candidate_payload
            .get("definition")
            .cloned()
            .ok_or_else(|| {
                EngineError::PolicyViolation(format!(
                    "capability_definition {} must include definition",
                    candidate.resource.resource_id
                ))
            })?,
    )
    .map_err(|error| {
        EngineError::PolicyViolation(format!(
            "capability_definition {} definition is invalid: {error}",
            candidate.resource.resource_id
        ))
    })?;
    if expected_function.id != request.function_id {
        return Err(EngineError::PolicyViolation(format!(
            "capability_definition {} definition id does not match {}",
            candidate.resource.resource_id, request.function_id
        )));
    }
    if expected_function.visibility != request.target_visibility {
        return Err(EngineError::PolicyViolation(format!(
            "capability_definition {} visibility must match activation target {}",
            candidate.resource.resource_id,
            request.target_visibility.as_str()
        )));
    }
    ensure_candidate_scope_matches_request(&expected_function, request)?;
    let actor = actor_context(&invocation.causal_context);
    ensure_resource_scope_compatible(
        "decision",
        &decision,
        &expected_function,
        &actor,
        &request.target_visibility,
        request.workspace_id.as_deref(),
    )?;
    ensure_resource_scope_compatible(
        "candidate",
        &candidate,
        &expected_function,
        &actor,
        &request.target_visibility,
        request.workspace_id.as_deref(),
    )?;
    ensure_decision_approves_activation(&decision, request)?;
    let mut evidence = Vec::new();
    for resource_id in &request.evidence_resource_ids {
        let inspection = require_resource(host, resource_id)?;
        ensure_resource_scope_compatible(
            "evidence",
            &inspection,
            &expected_function,
            &actor,
            &request.target_visibility,
            request.workspace_id.as_deref(),
        )?;
        ensure_evidence_verified(&inspection)?;
        evidence.push(inspection);
    }
    ensure_activation_chain(&decision, &evidence, &candidate)?;
    let governance_fingerprint = fingerprint_json(&json!({
        "version": 1,
        "functionId": request.function_id.as_str(),
        "targetVisibility": request.target_visibility.as_str(),
        "workspaceId": request.workspace_id,
        "candidateResourceId": request.candidate_resource_id,
        "decisionResourceId": request.decision_resource_id,
        "evidenceResourceIds": request.evidence_resource_ids,
        "expectedFunctionDefinition": expected_function,
    }))?;
    Ok(ActivationGovernance {
        expected_function,
        governance_fingerprint,
    })
}

fn ensure_candidate_scope_matches_request(
    function: &FunctionDefinition,
    request: &WorkerActivationRequest,
) -> Result<()> {
    match request.target_visibility {
        VisibilityScope::Session => {
            if let Some(session_id) = function.provenance.session_id.as_deref()
                && request.session_id.as_deref() != Some(session_id)
            {
                return Err(EngineError::PolicyViolation(
                    "capability_definition session scope does not match activation session"
                        .to_owned(),
                ));
            }
        }
        VisibilityScope::Workspace => {
            if let Some(workspace_id) = function.provenance.workspace_id.as_deref()
                && request.workspace_id.as_deref() != Some(workspace_id)
            {
                return Err(EngineError::PolicyViolation(
                    "capability_definition workspace scope does not match activation workspace"
                        .to_owned(),
                ));
            }
        }
        _ => unreachable!("activation target visibility is narrowed before scope validation"),
    }
    Ok(())
}

fn ensure_decision_approves_activation(
    decision: &EngineResourceInspection,
    request: &WorkerActivationRequest,
) -> Result<()> {
    if decision.resource.kind != "decision" {
        return Err(EngineError::PolicyViolation(format!(
            "resource {} is kind {}, expected decision",
            decision.resource.resource_id, decision.resource.kind
        )));
    }
    if decision.resource.lifecycle != "final" {
        return Err(EngineError::PolicyViolation(format!(
            "decision resource {} must be final",
            decision.resource.resource_id
        )));
    }
    let payload = current_payload(decision)?;
    if payload.get("status").and_then(Value::as_str) != Some("accepted") {
        return Err(EngineError::PolicyViolation(format!(
            "decision resource {} must be accepted",
            decision.resource.resource_id
        )));
    }
    let approved_function = first_payload_str(
        payload,
        &[
            "/functionId",
            "/approvedFunctionId",
            "/metadata/functionId",
            "/metadata/approvedFunctionId",
        ],
    )
    .ok_or_else(|| {
        EngineError::PolicyViolation(format!(
            "decision resource {} must approve functionId",
            decision.resource.resource_id
        ))
    })?;
    if approved_function != request.function_id.as_str() {
        return Err(EngineError::PolicyViolation(format!(
            "decision resource {} does not approve function {}",
            decision.resource.resource_id, request.function_id
        )));
    }
    let approved_visibility = first_payload_str(
        payload,
        &[
            "/targetVisibility",
            "/approvedTargetVisibility",
            "/metadata/targetVisibility",
            "/metadata/approvedTargetVisibility",
        ],
    )
    .ok_or_else(|| {
        EngineError::PolicyViolation(format!(
            "decision resource {} must approve target visibility",
            decision.resource.resource_id
        ))
    })?;
    if approved_visibility != request.target_visibility.as_str() {
        return Err(EngineError::PolicyViolation(format!(
            "decision resource {} does not approve {} visibility",
            decision.resource.resource_id,
            request.target_visibility.as_str()
        )));
    }
    if let Some(workspace_id) = request.workspace_id.as_deref()
        && let Some(approved_workspace) =
            first_payload_str(payload, &["/workspaceId", "/metadata/workspaceId"])
        && approved_workspace != workspace_id
    {
        return Err(EngineError::PolicyViolation(format!(
            "decision resource {} does not approve workspace {}",
            decision.resource.resource_id, workspace_id
        )));
    }
    Ok(())
}

fn ensure_evidence_verified(evidence: &EngineResourceInspection) -> Result<()> {
    if evidence.resource.kind != "evidence" {
        return Err(EngineError::PolicyViolation(format!(
            "resource {} is kind {}, expected evidence",
            evidence.resource.resource_id, evidence.resource.kind
        )));
    }
    if evidence.resource.lifecycle != "accepted" {
        return Err(EngineError::PolicyViolation(format!(
            "evidence resource {} must be accepted",
            evidence.resource.resource_id
        )));
    }
    let payload = current_payload(evidence)?;
    let verified = payload
        .pointer("/metadata/verified")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        || first_payload_str(
            payload,
            &[
                "/verificationStatus",
                "/metadata/verificationStatus",
                "/metadata/status",
            ],
        )
        .is_some_and(|value| value == "verified");
    if verified {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "evidence resource {} must be verified",
            evidence.resource.resource_id
        )))
    }
}

fn ensure_activation_chain(
    decision: &EngineResourceInspection,
    evidence: &[EngineResourceInspection],
    candidate: &EngineResourceInspection,
) -> Result<()> {
    let decision_supported = evidence.iter().any(|item| {
        resources_linked(
            decision,
            item,
            &["supports", "supported_by", "evidence_for"],
        )
    });
    let decision_links_candidate = resources_linked(
        decision,
        candidate,
        &[
            "promotes",
            "decides",
            "candidate_output",
            "promoted_output",
            "supported_by",
        ],
    ) || payload_array_contains(
        current_payload(decision)?,
        "promotedResources",
        &candidate.resource.resource_id,
    ) || payload_array_contains(
        current_payload(decision)?,
        "candidateResourceIds",
        &candidate.resource.resource_id,
    );
    let evidence_links_candidate = evidence.iter().any(|item| {
        resources_linked(
            item,
            candidate,
            &["supports", "supported_by", "evidence_for"],
        )
    });
    if decision_links_candidate && (decision_supported || evidence_links_candidate) {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "candidate resource {} is not linked to the decision/evidence chain",
            candidate.resource.resource_id
        )))
    }
}

fn ensure_resource_scope_compatible(
    label: &str,
    inspection: &EngineResourceInspection,
    function: &FunctionDefinition,
    actor: &crate::engine::ActorContext,
    target: &VisibilityScope,
    target_workspace_id: Option<&str>,
) -> Result<()> {
    let compatible = match &inspection.resource.scope {
        EngineResourceScope::System => actor.actor_kind.is_admin_like(),
        EngineResourceScope::Workspace(resource_workspace) => {
            actor.actor_kind.is_admin_like()
                || actor.workspace_id.as_deref() == Some(resource_workspace.as_str())
                || matches!(
                    (target, target_workspace_id),
                    (VisibilityScope::Workspace, Some(target_workspace))
                        if target_workspace == resource_workspace
                )
        }
        EngineResourceScope::Session(resource_session) => {
            actor.actor_kind.is_admin_like()
                || (actor.session_id.as_deref() == Some(resource_session.as_str())
                    && function.provenance.session_id.as_deref() == Some(resource_session.as_str()))
        }
    };
    if compatible {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "{label} resource {} scope is incompatible with activation target",
            inspection.resource.resource_id
        )))
    }
}

fn require_resource(
    host: &dyn PrimitiveRuntimeHost,
    resource_id: &str,
) -> Result<EngineResourceInspection> {
    host.inspect_resource(resource_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: resource_id.to_owned(),
        })
}

fn current_payload(inspection: &EngineResourceInspection) -> Result<&Value> {
    let current_version_id = inspection
        .resource
        .current_version_id
        .as_deref()
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "resource {} has no current payload",
                inspection.resource.resource_id
            ))
        })?;
    inspection
        .versions
        .iter()
        .find(|version| version.version_id == current_version_id)
        .map(|version| &version.payload)
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "resource {} current version is missing",
                inspection.resource.resource_id
            ))
        })
}

fn resources_linked(
    left: &EngineResourceInspection,
    right: &EngineResourceInspection,
    relations: &[&str],
) -> bool {
    let left_id = left.resource.resource_id.as_str();
    let right_id = right.resource.resource_id.as_str();
    left.outgoing_links.iter().any(|link| {
        link.target_resource_id == right_id && relations.contains(&link.relation.as_str())
    }) || right.outgoing_links.iter().any(|link| {
        link.target_resource_id == left_id && relations.contains(&link.relation.as_str())
    })
}

fn payload_array_contains(payload: &Value, field: &str, resource_id: &str) -> bool {
    payload
        .get(field)
        .or_else(|| payload.pointer(&format!("/metadata/{field}")))
        .and_then(Value::as_array)
        .is_some_and(|items| items.iter().any(|item| item.as_str() == Some(resource_id)))
}

fn first_payload_str<'a>(payload: &'a Value, pointers: &[&str]) -> Option<&'a str> {
    pointers
        .iter()
        .find_map(|pointer| payload.pointer(pointer).and_then(Value::as_str))
}
