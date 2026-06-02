use serde_json::{Map, Value, json};

use super::super::{ResolvedCapabilityTarget, capability_result_value};
use super::trigger_metadata::{related_trigger_ids, related_triggers_metadata};
use super::{OrchestratedExecuteInput, OrchestrationResolve};
use crate::domains::capability::registry::AgentCapabilityRecipeDisplay;
use crate::engine::Invocation;
use crate::shared::content::CapabilityResultContent;
use crate::shared::model_capabilities::{CapabilityResult, CapabilityResultBody};
use crate::shared::server::errors::CapabilityError;

pub(super) fn corrected_orchestrated_request(input: &OrchestratedExecuteInput) -> Value {
    let mut object = Map::new();
    if let Some(intent) = &input.intent {
        object.insert("intent".to_owned(), json!(intent));
    }
    if let Some(target) = &input.target_params {
        object.insert("target".to_owned(), target.clone());
    }
    if let Some(operation) = &input.operation
        && operation != "auto"
    {
        object.insert("operation".to_owned(), json!(operation));
    }
    object.insert("arguments".to_owned(), input.arguments.clone());
    if !input.constraints.as_object().map_or(true, Map::is_empty) {
        object.insert("constraints".to_owned(), input.constraints.clone());
    }
    if let Some(idempotency_key) = &input.idempotency_key {
        object.insert("idempotencyKey".to_owned(), json!(idempotency_key));
    }
    if let Some(reason) = &input.reason {
        object.insert("reason".to_owned(), json!(reason));
    }
    Value::Object(object)
}

pub(super) fn orchestration_details(
    orchestration_id: &str,
    status: &str,
    intent: Option<&str>,
    corrected_request: Option<Value>,
    input: &OrchestratedExecuteInput,
    phase_details: Value,
    child_invocations: Vec<String>,
) -> Value {
    let confidence = if input.corrections.is_empty() {
        1.0
    } else {
        0.95
    };
    json!({
        "orchestrationId": orchestration_id,
        "status": status,
        "intent": intent,
        "correctedRequest": corrected_request.unwrap_or_else(|| corrected_orchestrated_request(input)),
        "correctionsApplied": input.corrections.clone(),
        "correctionConfidence": confidence,
        "phaseDetails": phase_details,
        "childInvocationIds": child_invocations,
    })
}

pub(super) fn orchestration_request_error_details(
    orchestration_id: &str,
    status: &str,
    error: &CapabilityError,
) -> Value {
    json!({
        "orchestrationId": orchestration_id,
        "status": status,
        "intent": Value::Null,
        "correctedRequest": Value::Null,
        "correctionsApplied": [],
        "correctionConfidence": 0.0,
        "phaseDetails": {
            "phase": "parse",
            "error": capability_error_details(error),
        },
        "childInvocationIds": [],
    })
}

pub(super) fn correction_record(
    kind: impl Into<String>,
    message: impl Into<String>,
    confidence: f64,
) -> Value {
    json!({
        "kind": kind.into(),
        "message": message.into(),
        "confidence": confidence,
    })
}

pub(super) fn discovery_phase_details(
    resolve: &OrchestrationResolve,
    target: &ResolvedCapabilityTarget,
) -> Value {
    let inspection = target.entry.inspection(target.binding_decision.clone());
    let recipe = serde_json::to_value(&inspection.recipe).unwrap_or(Value::Null);
    let related_triggers = related_triggers_metadata(&target.entry);
    json!({
        "phase": "discover",
        "resolveMode": resolve.mode,
        "candidates": resolve.candidates,
        "rejectedCandidates": resolve.rejected_candidates,
        "searchStatus": resolve.search_status,
        "selectedTarget": {
            "contractId": target.entry.contract_id.as_str(),
            "implementationId": target.entry.implementation_id.as_str(),
            "functionId": target.entry.function.id.as_str(),
            "catalogRevision": target.entry.catalog_revision,
            "schemaDigest": target.entry.schema_digest.as_str(),
            "effectClass": format!("{:?}", target.entry.function.effect_class),
            "riskLevel": format!("{:?}", target.entry.function.risk_level),
        },
        "recipe": recipe,
        "executionRequirements": inspection.execution_requirements,
        "docs": {
            "summary": target.entry.function.description.as_str(),
            "relatedTriggers": related_triggers,
        }
    })
}

pub(super) fn discovery_message(target: &ResolvedCapabilityTarget) -> String {
    let recipe = target.entry.agent_recipe();
    let display = AgentCapabilityRecipeDisplay::new(&recipe);
    let related_trigger_ids = related_trigger_ids(&target.entry);
    let trigger_clause = if related_trigger_ids.is_empty() {
        String::new()
    } else {
        format!(
            " Related triggers visible as metadata: {}. To invoke this capability by function id, not by trigger id, set target to `{}`; do not use trigger ids as execute targets.",
            related_trigger_ids.join(", "),
            target.entry.function.id.as_str()
        )
    };
    format!(
        "Capability discovery for {}. Required arguments: {}. Optional arguments: {}. Effect/risk: {:?}/{:?}.{} No child invocation was created.",
        target.entry.contract_id,
        display.required_arguments,
        display.optional_arguments,
        target.entry.function.effect_class,
        target.entry.function.risk_level,
        trigger_clause
    )
}

pub(super) fn redacted_prepared_request_preview(prepared_payload: &Value) -> Value {
    json!({
        "mode": prepared_payload.get("mode").cloned().unwrap_or(Value::Null),
        "contractId": prepared_payload.get("contractId").cloned(),
        "capabilityId": prepared_payload.get("capabilityId").cloned(),
        "functionId": prepared_payload.get("functionId").cloned(),
        "implementationId": prepared_payload.get("implementationId").cloned(),
        "hasPayload": prepared_payload.get("payload").is_some(),
        "hasInspectionHandle": prepared_payload.get("inspectionHandle").is_some(),
        "hasIdempotencyKey": prepared_payload.get("idempotencyKey").is_some(),
    })
}

pub(super) fn orchestration_child_invocations(value: &Value) -> Vec<String> {
    let Some(details) = value.get("details") else {
        return Vec::new();
    };
    details
        .get("childInvocations")
        .or_else(|| details.get("childInvocationIds"))
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

pub(super) fn enrich_orchestration_with_result(orchestration: &mut Value, result: &Value) {
    let Some(details) = result.get("details") else {
        return;
    };
    let Some(object) = orchestration.as_object_mut() else {
        return;
    };
    if let Some(resource_refs) = execution_resource_refs(details) {
        object.insert("resourceRefs".to_owned(), resource_refs);
    }
    let approval_decision =
        execution_approval_decision(details).unwrap_or_else(default_no_approval_decision);
    object.insert("approvalDecision".to_owned(), approval_decision);
    if let Some((missing_fields, missing_argument_paths)) = execution_missing_input(details) {
        object.insert("missingFields".to_owned(), missing_fields);
        object.insert("missingArgumentPaths".to_owned(), missing_argument_paths);
    }
}

fn execution_resource_refs(details: &Value) -> Option<Value> {
    details
        .get("resourceRefs")
        .filter(|value| value.as_array().is_some())
        .cloned()
        .or_else(|| {
            details
                .get("output")
                .and_then(|output| output.get("resourceRefs"))
                .filter(|value| value.as_array().is_some())
                .cloned()
        })
}

fn execution_approval_decision(details: &Value) -> Option<Value> {
    if let Some(approval_decision) = details
        .get("approvalDecision")
        .filter(|value| value.is_object())
    {
        return Some(approval_decision.clone());
    }
    if let Some(approval_state) = details
        .get("approvalState")
        .filter(|value| value.is_object())
    {
        return Some(approval_state.clone());
    }

    let has_approval_fields = [
        "approvalRequired",
        "approvalCreated",
        "approvalExecuted",
        "approvalReplayed",
    ]
    .iter()
    .any(|key| details.get(*key).is_some());
    has_approval_fields.then(|| {
        let approval_required = details
            .get("approvalRequired")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let approval_created = details
            .get("approvalCreated")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let approval_executed = details
            .get("approvalExecuted")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let approval_replayed = details
            .get("approvalReplayed")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let mut decision = Map::new();
        decision.insert("approvalRequired".to_owned(), json!(approval_required));
        decision.insert("approvalCreated".to_owned(), json!(approval_created));
        decision.insert("approvalExecuted".to_owned(), json!(approval_executed));
        decision.insert("approvalReplayed".to_owned(), json!(approval_replayed));
        decision.insert(
            "status".to_owned(),
            json!(
                if approval_required || approval_created || approval_executed || approval_replayed {
                    "approval_flow"
                } else {
                    "not_required"
                }
            ),
        );
        for key in [
            "approvalId",
            "approvalRequestId",
            "approvalResourceId",
            "idempotencyKey",
            "traceId",
            "functionId",
            "childInvocationId",
            "childInvocationIds",
        ] {
            if let Some(value) = details.get(key) {
                decision.insert(key.to_owned(), value.clone());
            }
        }
        Value::Object(decision)
    })
}

fn execution_missing_input(details: &Value) -> Option<(Value, Value)> {
    let missing_fields = details
        .get("missingFields")
        .filter(|value| value.as_array().is_some())
        .cloned()
        .or_else(|| {
            details
                .get("guidance")
                .and_then(|guidance| guidance.get("missingFields"))
                .filter(|value| value.as_array().is_some())
                .cloned()
        })
        .or_else(|| {
            details
                .get("error")
                .and_then(|error| error.get("details"))
                .and_then(|details| details.get("missingFields"))
                .filter(|value| value.as_array().is_some())
                .cloned()
        });
    let missing_argument_paths = details
        .get("missingArgumentPaths")
        .filter(|value| value.as_array().is_some())
        .cloned()
        .or_else(|| {
            details
                .get("guidance")
                .and_then(|guidance| guidance.get("missingArgumentPaths"))
                .filter(|value| value.as_array().is_some())
                .cloned()
        })
        .or_else(|| {
            details
                .get("error")
                .and_then(|error| error.get("details"))
                .and_then(|details| details.get("missingArgumentPaths"))
                .filter(|value| value.as_array().is_some())
                .cloned()
        });

    match (missing_fields, missing_argument_paths) {
        (Some(fields), Some(paths)) => Some((fields, paths)),
        _ => None,
    }
}

pub(super) fn attach_orchestration_details(
    value: Value,
    orchestration: Value,
) -> Result<Value, CapabilityError> {
    let mut result: CapabilityResult =
        serde_json::from_value(value).map_err(|error| CapabilityError::Internal {
            message: error.to_string(),
        })?;
    let mut details = match result.details.take() {
        Some(Value::Object(object)) => Value::Object(object),
        Some(value) => json!({ "toolDetails": value }),
        None => json!({}),
    };
    if let Value::Object(object) = &mut details {
        if object.get("resourceRefs").is_none() {
            let resource_refs = orchestration
                .get("resourceRefs")
                .filter(|value| value.as_array().is_some())
                .cloned()
                .unwrap_or_else(|| json!([]));
            object.insert("resourceRefs".to_owned(), resource_refs);
        }
        if object.get("childInvocationIds").is_none()
            && let Some(child_invocation_ids) = orchestration.get("childInvocationIds")
        {
            object.insert(
                "childInvocationIds".to_owned(),
                child_invocation_ids.clone(),
            );
        }
        if object.get("approvalDecision").is_none() {
            let approval_decision = orchestration
                .get("approvalDecision")
                .cloned()
                .unwrap_or_else(default_no_approval_decision);
            object.insert("approvalDecision".to_owned(), approval_decision);
        }
        object.insert("orchestration".to_owned(), orchestration.clone());
        for key in [
            "correctedRequest",
            "correctionsApplied",
            "correctionConfidence",
        ] {
            if let Some(value) = orchestration.get(key) {
                object.insert(key.to_owned(), value.clone());
            }
        }
    }
    result.details = Some(details);
    capability_result_value(result)
}

pub(super) fn attach_execute_invocation_metadata(
    value: Value,
    invocation: &Invocation,
) -> Result<Value, CapabilityError> {
    let mut result: CapabilityResult =
        serde_json::from_value(value).map_err(|error| CapabilityError::Internal {
            message: error.to_string(),
        })?;
    let execute_invocation_id = json!(invocation.id.as_str());
    let mut details = match result.details.take() {
        Some(Value::Object(object)) => Value::Object(object),
        Some(value) => json!({ "toolDetails": value }),
        None => json!({}),
    };
    if let Value::Object(object) = &mut details {
        object.insert(
            "executeInvocationId".to_owned(),
            execute_invocation_id.clone(),
        );
        object.insert(
            "primitiveInvocationId".to_owned(),
            execute_invocation_id.clone(),
        );
        if let Some(Value::Object(orchestration)) = object.get_mut("orchestration") {
            orchestration.insert(
                "executeInvocationId".to_owned(),
                execute_invocation_id.clone(),
            );
            orchestration.insert("primitiveInvocationId".to_owned(), execute_invocation_id);
        }
    }
    result.details = Some(details);
    capability_result_value(result)
}

pub(super) fn orchestration_result(
    status: &str,
    message: &str,
    diagnostics: Value,
    is_error: bool,
) -> Result<Value, CapabilityError> {
    let details = terminal_orchestration_result_details(status, diagnostics);
    capability_result_value(CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            message.to_owned(),
        )]),
        details: Some(details),
        is_error: is_error.then_some(true),
        stop_turn: None,
    })
}

pub(super) fn orchestration_status_is_error(status: &str) -> bool {
    !matches!(
        status,
        "capability_discovery"
            | "needs_input"
            | "needs_selection"
            | "needs_capability"
            | "needs_decomposition"
    )
}

fn terminal_orchestration_result_details(status: &str, diagnostics: Value) -> Value {
    let mut details = Map::new();
    details.insert("status".to_owned(), json!(status));
    details.insert("orchestration".to_owned(), diagnostics.clone());
    details.insert("childInvocationCreated".to_owned(), json!(false));
    details.insert("approvalCreated".to_owned(), json!(false));
    details.insert(
        "approvalDecision".to_owned(),
        default_no_approval_decision(),
    );
    details.insert("resourceRefs".to_owned(), json!([]));

    if let Some(phase_details) = diagnostics.get("phaseDetails") {
        for key in [
            "candidates",
            "rejectedCandidates",
            "missingFields",
            "missingArgumentPaths",
            "searchStatus",
            "proposedCapabilityShape",
            "selectedTarget",
            "error",
            "guidance",
            "decomposition",
            "suggestedCalls",
            "recipe",
            "executionRequirements",
            "docs",
        ] {
            if let Some(value) = phase_details.get(key) {
                details.insert(key.to_owned(), value.clone());
            }
        }
        if !details.contains_key("guidance")
            && let Some(guidance) = terminal_repair_guidance(status, phase_details)
        {
            details.insert("guidance".to_owned(), guidance);
        }
    }
    for key in [
        "correctedRequest",
        "correctionsApplied",
        "correctionConfidence",
        "childInvocationIds",
    ] {
        if let Some(value) = diagnostics.get(key) {
            details.insert(key.to_owned(), value.clone());
        }
    }
    Value::Object(details)
}

fn terminal_repair_guidance(status: &str, phase_details: &Value) -> Option<Value> {
    if status == "needs_selection"
        && let Some(candidates) = phase_details.get("candidates").and_then(Value::as_array)
    {
        let candidate_function_ids = candidates
            .iter()
            .filter_map(|candidate| candidate.get("functionId").and_then(Value::as_str))
            .take(6)
            .map(ToOwned::to_owned)
            .collect::<Vec<_>>();
        if !candidate_function_ids.is_empty() {
            return Some(json!({
                "kind": "select_target",
                "message": needs_selection_message(candidates),
                "candidateFunctionIds": candidate_function_ids,
            }));
        }
    }

    let error = phase_details.get("error")?;
    let code = error.get("code").and_then(Value::as_str)?;
    let error_details = error.get("details").cloned().unwrap_or(Value::Null);
    match code {
        "STALE_CAPABILITY_REVISION" => Some(json!({
            "kind": "refresh_capability_revision",
            "message": "Re-run execute after a fresh capability inspection and retry with the current revision guard; do not reuse stale expectedRevision values.",
            "errorCode": code,
            "details": error_details,
        })),
        "STALE_CAPABILITY_SCHEMA" => Some(json!({
            "kind": "refresh_capability_schema",
            "message": "Re-run execute after a fresh capability inspection and retry with the current schema digest; do not reuse stale expectedSchemaDigest values.",
            "errorCode": code,
            "details": error_details,
        })),
        "INSPECTION_HANDLE_INVALID" => Some(json!({
            "kind": "refresh_inspection_handle",
            "message": "Re-run capability inspection or execute discovery to acquire a fresh inspection handle before retrying this mutating or elevated-risk target.",
            "errorCode": code,
            "details": error_details,
        })),
        _ => None,
    }
}

pub(super) fn default_no_approval_decision() -> Value {
    json!({
        "approvalRequired": false,
        "approvalCreated": false,
        "approvalExecuted": false,
        "approvalReplayed": false,
        "status": "not_required",
    })
}

pub(super) fn needs_selection_message(candidates: &[Value]) -> String {
    let candidate_ids = candidates
        .iter()
        .filter_map(|candidate| candidate.get("functionId").and_then(Value::as_str))
        .take(6)
        .collect::<Vec<_>>();
    if candidate_ids.is_empty() {
        return "Multiple visible capabilities match that intent. Re-run execute with target set to the intended capability.".to_owned();
    }
    format!(
        "Multiple visible capabilities match that intent. Re-run execute with target set to one of: {}.",
        candidate_ids.join(", ")
    )
}

pub(super) fn capability_error_details(error: &CapabilityError) -> Value {
    json!({
        "code": error.code(),
        "message": error.to_string(),
        "details": error.details(),
    })
}

pub(super) fn orchestration_failure_status(error: &CapabilityError) -> &'static str {
    match error.code() {
        "CAPABILITY_DENIED" | "INSPECTION_HANDLE_INVALID" | "STALE_CAPABILITY_REVISION" => {
            "prepare_failed"
        }
        _ => "run_failed",
    }
}
