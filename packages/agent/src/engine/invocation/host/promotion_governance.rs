//! Governance checks for catalog visibility promotion.
//!
//! `engine::promote` is the only host path that widens a session function into
//! workspace or system visibility. Promotion therefore validates the durable
//! decision/evidence/candidate resource chain immediately before mutating the
//! catalog.

use std::collections::BTreeSet;

use super::*;
use crate::engine::durability::resources::{
    EngineResourceInspection, EngineResourceScope, EngineResourceVersion,
};

const DECISION_STATUS_ACCEPTED: &str = "accepted";
const DECISION_LIFECYCLE_FINAL: &str = "final";
const EVIDENCE_LIFECYCLE_ACCEPTED: &str = "accepted";
const VERIFIED_STATUS: &str = "verified";

const CANDIDATE_KINDS: &[&str] = &[
    "artifact",
    "capability_definition",
    "materialized_file",
    "patch_proposal",
    "ui_surface",
    "agent_rule",
];
const DECISION_CANDIDATE_RELATIONS: &[&str] = &[
    "promotes",
    "decides",
    "candidate_output",
    "promoted_output",
    "supported_by",
];
const EVIDENCE_RELATIONS: &[&str] = &["supports", "supported_by", "evidence_for"];

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct PromotionGovernanceRefs {
    pub(super) decision_resource_id: String,
    pub(super) evidence_resource_ids: Vec<String>,
    pub(super) candidate_resource_ids: Vec<String>,
    pub(super) promotion_reason: String,
}

impl PromotionGovernanceRefs {
    pub(super) fn from_payload(payload: &Value) -> Result<Self> {
        let decision_resource_id = non_empty_string(payload, "decisionResourceId")?;
        let evidence_resource_ids = non_empty_string_array(payload, "evidenceResourceIds")?;
        let candidate_resource_ids = non_empty_string_array(payload, "candidateResourceIds")?;
        let promotion_reason = non_empty_string(payload, "promotionReason")?;
        ensure_unique_refs("evidenceResourceIds", &evidence_resource_ids)?;
        ensure_unique_refs("candidateResourceIds", &candidate_resource_ids)?;
        Ok(Self {
            decision_resource_id,
            evidence_resource_ids,
            candidate_resource_ids,
            promotion_reason,
        })
    }

    pub(super) fn response_value(&self) -> Value {
        json!({
            "decisionResourceId": self.decision_resource_id,
            "evidenceResourceIds": self.evidence_resource_ids,
            "candidateResourceIds": self.candidate_resource_ids,
        })
    }

    pub(super) fn redacted_catalog_metadata(&self, target: &VisibilityScope) -> Value {
        json!({
            "targetVisibility": target.as_str(),
            "decisionResourceId": self.decision_resource_id,
            "evidenceResourceIds": self.evidence_resource_ids,
            "candidateResourceIds": self.candidate_resource_ids,
            "promotionReason": self.promotion_reason,
        })
    }
}

impl EngineHost {
    pub(super) fn validate_promotion_governance(
        &self,
        invocation: &Invocation,
        function: &FunctionDefinition,
        target: &VisibilityScope,
        workspace_id: Option<&str>,
        refs: &PromotionGovernanceRefs,
    ) -> Result<()> {
        ensure_payload_idempotency_matches_context(invocation)?;
        let actor = actor_context(&invocation.causal_context);
        ensure_target_authority(&actor, target, workspace_id)?;

        let resources =
            self.primitives.resources.lock().map_err(|_| {
                EngineError::HandlerFailed("resource store lock poisoned".to_owned())
            })?;
        let decision = require_resource(&resources, &refs.decision_resource_id)?;
        ensure_resource_scope_compatible(
            "decision",
            &decision,
            function,
            &actor,
            target,
            workspace_id,
        )?;
        ensure_decision_approves(&decision, function, target, workspace_id)?;

        let mut evidence = Vec::new();
        for resource_id in &refs.evidence_resource_ids {
            let inspection = require_resource(&resources, resource_id)?;
            ensure_resource_scope_compatible(
                "evidence",
                &inspection,
                function,
                &actor,
                target,
                workspace_id,
            )?;
            ensure_evidence_verified(&inspection)?;
            evidence.push(inspection);
        }

        let mut candidates = Vec::new();
        for resource_id in &refs.candidate_resource_ids {
            let inspection = require_resource(&resources, resource_id)?;
            ensure_resource_scope_compatible(
                "candidate",
                &inspection,
                function,
                &actor,
                target,
                workspace_id,
            )?;
            ensure_candidate_kind(&inspection)?;
            candidates.push(inspection);
        }
        ensure_candidates_are_chained(&decision, &evidence, &candidates)?;
        Ok(())
    }
}

fn ensure_payload_idempotency_matches_context(invocation: &Invocation) -> Result<()> {
    let payload_key = required_str(&invocation.payload, "idempotencyKey")?;
    if payload_key.trim().is_empty() {
        return Err(EngineError::PolicyViolation(
            "engine::promote requires non-empty idempotencyKey".to_owned(),
        ));
    }
    match invocation.causal_context.idempotency_key.as_deref() {
        Some(context_key) if context_key == payload_key => Ok(()),
        _ => Err(EngineError::PolicyViolation(
            "engine::promote idempotencyKey must match causal context".to_owned(),
        )),
    }
}

fn ensure_target_authority(
    actor: &ActorContext,
    target: &VisibilityScope,
    workspace_id: Option<&str>,
) -> Result<()> {
    match target {
        VisibilityScope::Workspace => {
            let workspace_id = workspace_id
                .filter(|value| !value.trim().is_empty())
                .ok_or_else(|| EngineError::InvalidVisibilityPromotion {
                    function_id: "engine::promote".to_owned(),
                    target: target.as_str().to_owned(),
                    reason: "workspace promotion requires a workspace id".to_owned(),
                })?;
            if !actor.has_scope("engine.promote.workspace") {
                return Err(EngineError::PolicyViolation(
                    "workspace promotion requires engine.promote.workspace authority".to_owned(),
                ));
            }
            if !actor.actor_kind.is_admin_like()
                && actor.workspace_id.as_deref() != Some(workspace_id)
            {
                return Err(EngineError::PolicyViolation(
                    "workspace promotion requires matching workspace authority".to_owned(),
                ));
            }
            Ok(())
        }
        VisibilityScope::System => {
            if !actor.has_scope("engine.promote.system") {
                return Err(EngineError::PolicyViolation(
                    "system promotion requires engine.promote.system authority".to_owned(),
                ));
            }
            if !actor.actor_kind.is_admin_like() {
                return Err(EngineError::PolicyViolation(
                    "system promotion requires admin authority".to_owned(),
                ));
            }
            Ok(())
        }
        _ => Err(EngineError::InvalidVisibilityPromotion {
            function_id: "engine::promote".to_owned(),
            target: target.as_str().to_owned(),
            reason: "engine::promote only supports workspace or system targets".to_owned(),
        }),
    }
}

fn ensure_resource_scope_compatible(
    label: &str,
    inspection: &EngineResourceInspection,
    function: &FunctionDefinition,
    actor: &ActorContext,
    target: &VisibilityScope,
    target_workspace_id: Option<&str>,
) -> Result<()> {
    let compatible = match &inspection.resource.scope {
        EngineResourceScope::System => true,
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
        return Ok(());
    }
    Err(EngineError::PolicyViolation(format!(
        "{label} resource {} scope is incompatible with promotion target",
        inspection.resource.resource_id
    )))
}

fn ensure_decision_approves(
    decision: &EngineResourceInspection,
    function: &FunctionDefinition,
    target: &VisibilityScope,
    workspace_id: Option<&str>,
) -> Result<()> {
    ensure_resource_kind(decision, "decision")?;
    if decision.resource.lifecycle != DECISION_LIFECYCLE_FINAL {
        return Err(EngineError::PolicyViolation(format!(
            "decision resource {} must be final",
            decision.resource.resource_id
        )));
    }
    let payload = current_payload(decision)?;
    let status = payload.get("status").and_then(Value::as_str);
    if status != Some(DECISION_STATUS_ACCEPTED) {
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
            "decision resource {} must approve a functionId",
            decision.resource.resource_id
        ))
    })?;
    if approved_function != function.id.as_str() {
        return Err(EngineError::PolicyViolation(format!(
            "decision resource {} does not approve function {}",
            decision.resource.resource_id, function.id
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
    if approved_visibility != target.as_str() {
        return Err(EngineError::PolicyViolation(format!(
            "decision resource {} does not approve {} visibility",
            decision.resource.resource_id,
            target.as_str()
        )));
    }
    if let Some(workspace_id) = workspace_id
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
    ensure_resource_kind(evidence, "evidence")?;
    if evidence.resource.lifecycle != EVIDENCE_LIFECYCLE_ACCEPTED {
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
        .is_some_and(|value| value == VERIFIED_STATUS);
    if verified {
        return Ok(());
    }
    Err(EngineError::PolicyViolation(format!(
        "evidence resource {} must be verified",
        evidence.resource.resource_id
    )))
}

fn ensure_candidate_kind(candidate: &EngineResourceInspection) -> Result<()> {
    if CANDIDATE_KINDS.contains(&candidate.resource.kind.as_str()) {
        return Ok(());
    }
    Err(EngineError::PolicyViolation(format!(
        "candidate resource {} kind {} cannot be promoted through engine::promote",
        candidate.resource.resource_id, candidate.resource.kind
    )))
}

fn ensure_candidates_are_chained(
    decision: &EngineResourceInspection,
    evidence: &[EngineResourceInspection],
    candidates: &[EngineResourceInspection],
) -> Result<()> {
    let decision_supported = evidence
        .iter()
        .any(|item| resources_linked(decision, item, EVIDENCE_RELATIONS));
    for candidate in candidates {
        let decision_links_candidate =
            resources_linked(decision, candidate, DECISION_CANDIDATE_RELATIONS)
                || payload_array_contains(
                    current_payload(decision)?,
                    "promotedResources",
                    &candidate.resource.resource_id,
                )
                || payload_array_contains(
                    current_payload(decision)?,
                    "candidateResourceIds",
                    &candidate.resource.resource_id,
                );
        let evidence_links_candidate = evidence
            .iter()
            .any(|item| resources_linked(item, candidate, EVIDENCE_RELATIONS));
        if decision_links_candidate && (decision_supported || evidence_links_candidate) {
            continue;
        }
        return Err(EngineError::PolicyViolation(format!(
            "candidate resource {} is not linked to the decision/evidence chain",
            candidate.resource.resource_id
        )));
    }
    Ok(())
}

fn require_resource(
    store: &crate::engine::primitives::ResourceStoreBackend,
    resource_id: &str,
) -> Result<EngineResourceInspection> {
    store
        .inspect(resource_id)?
        .ok_or_else(|| EngineError::NotFound {
            kind: "resource",
            id: resource_id.to_owned(),
        })
}

fn ensure_resource_kind(inspection: &EngineResourceInspection, expected: &str) -> Result<()> {
    if inspection.resource.kind == expected {
        return Ok(());
    }
    Err(EngineError::PolicyViolation(format!(
        "resource {} is kind {}, expected {expected}",
        inspection.resource.resource_id, inspection.resource.kind
    )))
}

fn current_payload(inspection: &EngineResourceInspection) -> Result<&Value> {
    let Some(current_version_id) = &inspection.resource.current_version_id else {
        return Err(EngineError::PolicyViolation(format!(
            "resource {} has no current payload",
            inspection.resource.resource_id
        )));
    };
    current_version(inspection, current_version_id)
        .map(|version| &version.payload)
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "resource {} current version is missing",
                inspection.resource.resource_id
            ))
        })
}

fn current_version<'a>(
    inspection: &'a EngineResourceInspection,
    current_version_id: &str,
) -> Option<&'a EngineResourceVersion> {
    inspection
        .versions
        .iter()
        .find(|version| version.version_id == current_version_id)
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

fn non_empty_string(payload: &Value, field: &str) -> Result<String> {
    let value = required_str(payload, field)?;
    if value.trim().is_empty() {
        return Err(EngineError::PolicyViolation(format!(
            "{field} must be non-empty"
        )));
    }
    Ok(value.to_owned())
}

fn non_empty_string_array(payload: &Value, field: &str) -> Result<Vec<String>> {
    let items = payload
        .get(field)
        .and_then(Value::as_array)
        .ok_or_else(|| EngineError::PolicyViolation(format!("{field} must be an array")))?;
    if items.is_empty() {
        return Err(EngineError::PolicyViolation(format!(
            "{field} must contain at least one resource id"
        )));
    }
    items
        .iter()
        .map(|item| {
            let Some(value) = item.as_str() else {
                return Err(EngineError::PolicyViolation(format!(
                    "{field} entries must be strings"
                )));
            };
            if value.trim().is_empty() {
                return Err(EngineError::PolicyViolation(format!(
                    "{field} entries must be non-empty"
                )));
            }
            Ok(value.to_owned())
        })
        .collect()
}

fn ensure_unique_refs(field: &str, refs: &[String]) -> Result<()> {
    let mut seen = BTreeSet::new();
    for resource_id in refs {
        if !seen.insert(resource_id) {
            return Err(EngineError::PolicyViolation(format!(
                "{field} contains duplicate resource id {resource_id}"
            )));
        }
    }
    Ok(())
}
