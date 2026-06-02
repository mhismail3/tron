//! Child capability execution, approval pause/resume, and run-result projection.

use serde_json::{Value, json};

use super::{
    ResolvedCapabilityTarget, actor_from_invocation, capability_primitive_target_error,
    capability_result_value, child_idempotency_key, child_idempotency_required,
    enforce_execution_policy, execution_requires_approval, is_capability_primitive,
    merge_optional_details, missing_inspection_requirements_error, registry_store_error,
    requires_fresh_revision_for_payload, resolve_target, validate_inspection_handle,
    validate_target_payload, validate_target_policy_before_approval,
};
use crate::domains::capability::Deps;
use crate::domains::capability::registry::{string_field, u64_field};
use crate::domains::capability::types::CapabilityExecutionRecord;
use crate::engine::{
    ApprovalStatus, CausalContext, DeliveryMode, EngineApprovalRecord, EngineApprovalRequest,
    FunctionDefinition, FunctionRevision, Invocation, InvocationRecord,
};
use crate::shared::content::CapabilityResultContent;
use crate::shared::model_capabilities::{CapabilityResult, CapabilityResultBody};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::error_mapping::engine_error_to_capability_error;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn execute_invoke_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let actor = actor_from_invocation(invocation)?;
    let target = resolve_target(&invocation.payload, deps, &actor).await?;
    let function = target.entry.function.clone();
    if is_capability_primitive(&function) {
        return Err(capability_primitive_target_error(&function));
    }
    enforce_execution_policy(invocation, &target.binding_decision, &function)?;

    let expected_revision = u64_field(&invocation.payload, "expectedRevision");
    let expected_schema_digest = string_field(&invocation.payload, "expectedSchemaDigest")
        .or_else(|| string_field(&invocation.payload, "expected_schema_digest"));
    let inspection_handle = string_field(&invocation.payload, "inspectionHandle")
        .or_else(|| string_field(&invocation.payload, "inspection_handle"));
    if requires_fresh_revision_for_payload(&function, &invocation.payload) {
        if expected_revision.is_none()
            || expected_schema_digest.is_none()
            || inspection_handle.is_none()
        {
            return Err(missing_inspection_requirements_error(
                &function,
                &target.entry,
                expected_revision,
                expected_schema_digest.as_deref(),
                inspection_handle.as_deref(),
            ));
        }
        let valid_inspection = validate_inspection_handle(
            deps,
            inspection_handle.as_deref().unwrap_or_default(),
            target.entry.clone(),
        )
        .await?;
        if !valid_inspection {
            return Err(CapabilityError::Custom {
                code: "INSPECTION_HANDLE_INVALID".to_owned(),
                message: format!(
                    "{} requires a fresh inspection handle for the selected implementation",
                    function.id.as_str()
                ),
                details: Some(json!({
                    "functionId": function.id.as_str(),
                    "currentRevision": function.revision.0,
                    "currentSchemaDigest": target.entry.schema_digest,
                })),
            });
        }
    }

    if let Some(expected) = expected_revision
        && expected != function.revision.0
    {
        return Err(CapabilityError::Custom {
            code: "STALE_CAPABILITY_REVISION".to_owned(),
            message: format!(
                "{} is at revision {}, not requested revision {expected}",
                function.id.as_str(),
                function.revision.0
            ),
            details: Some(json!({
                "functionId": function.id.as_str(),
                "expectedRevision": expected,
                "currentRevision": function.revision.0,
            })),
        });
    }
    if let Some(expected) = expected_schema_digest
        && expected != target.entry.schema_digest
    {
        return Err(CapabilityError::Custom {
            code: "STALE_CAPABILITY_SCHEMA".to_owned(),
            message: format!(
                "{} has schema digest {}, not requested digest {expected}",
                function.id.as_str(),
                target.entry.schema_digest
            ),
            details: Some(json!({
                "functionId": function.id.as_str(),
                "expectedSchemaDigest": expected,
                "currentSchemaDigest": target.entry.schema_digest,
            })),
        });
    }

    let payload = invocation
        .payload
        .get("payload")
        .cloned()
        .unwrap_or_else(|| json!({}));
    if let Err(error) = validate_target_payload(&target.entry, &payload) {
        let status = payload_preflight_status(&error);
        return preflight_rejection_result(&function, &target, error, status);
    }
    if let Err(error) = validate_target_policy_before_approval(&function, &payload) {
        let status = policy_preflight_status(&error);
        return preflight_rejection_result(&function, &target, error, status);
    }
    let idempotency_key = match child_idempotency_key(
        invocation,
        &function,
        &payload,
        child_idempotency_required(&function, &payload),
    ) {
        Ok(key) => key,
        Err(error) => {
            return preflight_rejection_result(&function, &target, error, "idempotency_required");
        }
    };
    let causal_context = child_execute_causal_context(invocation, &function, idempotency_key);

    let mut child = Invocation::new_sync(function.id.clone(), payload.clone(), causal_context);
    if let Some(expected) = expected_revision {
        child = child.expecting_revision(FunctionRevision(expected));
    }
    if execution_requires_approval(&function, &payload) {
        let approval = deps
            .engine_host
            .request_approval(EngineApprovalRequest {
                function_id: function.id.clone(),
                payload: child.payload.clone(),
                causal_context: child.causal_context.clone(),
                delivery_mode: DeliveryMode::Sync,
                target_metadata: None,
            })
            .await
            .map_err(engine_error_to_capability_error)?;
        return await_approval_result(invocation, deps, &function, &target, approval).await;
    }
    let result = deps.engine_host.invoke(child).await;
    if let Some(error) = result.error.clone() {
        return child_run_failure_result(deps, &function, &target, result, error).await;
    }
    let output = result.value.clone().unwrap_or(Value::Null);
    let catalog_revision = result.catalog_revision.0;
    let record = CapabilityExecutionRecord {
        status: "ok".to_owned(),
        trace_id: result.trace_id.as_str().to_owned(),
        root_invocation_id: invocation.id.as_str().to_owned(),
        child_invocations: vec![result.invocation_id.as_str().to_owned()],
        selected_implementation: target.binding_decision.selected_implementation.clone(),
        function_id: result.function_id.as_str().to_owned(),
        catalog_revision,
        function_revision: result.function_revision.0,
        output: output.clone(),
        approval_state: None,
        plugin_versions: vec![target.entry.plugin_id.clone()],
        presentation_hints: target
            .entry
            .function
            .metadata
            .get("presentationHints")
            .cloned(),
        binding_decision: target.binding_decision,
        schema_digest: target.entry.schema_digest,
    };
    let mut details = serde_json::to_value(&record).map_err(|error| CapabilityError::Internal {
        message: error.to_string(),
    })?;
    if let Some(replayed_from) = result.replayed_from {
        details["replayedFrom"] = json!(replayed_from.as_str());
    }
    {
        let store = deps.registry_store.clone();
        let trace_id = record.trace_id.clone();
        let audit_payload = json!({
            "status": record.status,
            "contractId": record.binding_decision.contract_id,
            "implementationId": record.selected_implementation,
            "functionId": record.function_id,
            "catalogRevision": record.catalog_revision,
            "functionRevision": record.function_revision,
            "schemaDigest": record.schema_digest,
            "childInvocations": record.child_invocations,
        });
        run_blocking_task("capability.execute.audit", move || {
            let mut store = store.lock().map_err(|_| CapabilityError::Internal {
                message: "capability registry store mutex poisoned".to_owned(),
            })?;
            store
                .record_audit_event("capability.execute", Some(&trace_id), audit_payload)
                .map_err(registry_store_error)?;
            Ok(())
        })
        .await?;
    }

    if let Ok(mut nested) = serde_json::from_value::<CapabilityResult>(output.clone()) {
        nested.details = Some(merge_optional_details(nested.details, details));
        return capability_result_value(nested);
    }

    let text = serde_json::to_string_pretty(&output).unwrap_or_else(|_| output.to_string());
    capability_result_value(CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(text)]),
        details: Some(details),
        is_error: None,
        stop_turn: None,
    })
}

async fn child_run_failure_result(
    deps: &Deps,
    function: &FunctionDefinition,
    target: &ResolvedCapabilityTarget,
    result: crate::engine::InvocationResult,
    error: crate::engine::EngineError,
) -> Result<Value, CapabilityError> {
    let mapped = engine_error_to_capability_error(error);
    let code = mapped.code().to_owned();
    let details_value = mapped.details();
    let message = mapped.to_string();
    let child_invocations = vec![result.invocation_id.as_str().to_owned()];
    let audit_payload = json!({
        "status": "run_failed",
        "contractId": target.binding_decision.contract_id.clone(),
        "implementationId": target.binding_decision.selected_implementation.clone(),
        "functionId": result.function_id.as_str(),
        "catalogRevision": result.catalog_revision.0,
        "functionRevision": result.function_revision.0,
        "schemaDigest": target.entry.schema_digest.clone(),
        "childInvocations": child_invocations,
        "error": {
            "code": code,
            "message": message,
            "details": details_value
        }
    });
    {
        let store = deps.registry_store.clone();
        let trace_id = result.trace_id.as_str().to_owned();
        let audit_payload = audit_payload.clone();
        run_blocking_task("capability.execute.audit_failure", move || {
            let mut store = store.lock().map_err(|_| CapabilityError::Internal {
                message: "capability registry store mutex poisoned".to_owned(),
            })?;
            store
                .record_audit_event("capability.execute", Some(&trace_id), audit_payload)
                .map_err(registry_store_error)?;
            Ok(())
        })
        .await?;
    }

    capability_result_value(CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(format!(
            "{} failed during child execution: {message}",
            function.id.as_str()
        ))]),
        details: Some(json!({
            "status": "run_failed",
            "error": {
                "code": code,
                "message": message,
                "details": details_value
            },
            "contractId": target.entry.contract_id.clone(),
            "implementationId": target.entry.implementation_id.clone(),
            "functionId": function.id.as_str(),
            "catalogRevision": result.catalog_revision.0,
            "functionRevision": result.function_revision.0,
            "schemaDigest": target.entry.schema_digest.clone(),
            "selectedImplementation": target.binding_decision.selected_implementation.clone(),
            "bindingDecision": target.binding_decision.clone(),
            "childInvocationCreated": true,
            "childInvocationId": result.invocation_id.as_str(),
            "childInvocationIds": child_invocations,
            "approvalCreated": false,
            "resourceRefs": []
        })),
        is_error: Some(true),
        stop_turn: None,
    })
}

pub(super) fn preflight_rejection_result(
    function: &FunctionDefinition,
    target: &ResolvedCapabilityTarget,
    error: CapabilityError,
    status: &str,
) -> Result<Value, CapabilityError> {
    let code = error.code().to_owned();
    let details = error.details();
    let message = error.to_string();
    let guidance = preflight_guidance(status, details.as_ref());
    let missing_fields = guidance
        .get("missingFields")
        .cloned()
        .unwrap_or_else(|| json!([]));
    let missing_argument_paths = guidance
        .get("missingArgumentPaths")
        .cloned()
        .unwrap_or_else(|| json!([]));
    let invalid_fields = guidance
        .get("invalidFields")
        .cloned()
        .unwrap_or_else(|| json!([]));
    let invalid_argument_paths = guidance
        .get("invalidArgumentPaths")
        .cloned()
        .unwrap_or_else(|| json!([]));
    capability_result_value(CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            preflight_message(function, status, &message),
        )]),
        details: Some(json!({
            "status": status,
            "error": {
                "code": code,
                "message": message,
                "details": details
            },
            "guidance": guidance,
            "contractId": target.entry.contract_id,
            "implementationId": target.entry.implementation_id,
            "functionId": function.id.as_str(),
            "catalogRevision": target.entry.catalog_revision,
            "functionRevision": function.revision.0,
            "schemaDigest": target.entry.schema_digest,
            "selectedImplementation": target.binding_decision.selected_implementation,
            "bindingDecision": target.binding_decision,
            "childInvocationCreated": false,
            "childInvocationIds": [],
            "approvalCreated": false,
            "resourceRefs": [],
            "missingFields": missing_fields,
            "missingArgumentPaths": missing_argument_paths,
            "invalidFields": invalid_fields,
            "invalidArgumentPaths": invalid_argument_paths
        })),
        is_error: (status != "needs_input").then_some(true),
        stop_turn: None,
    })
}

pub(super) fn payload_preflight_status(error: &CapabilityError) -> &'static str {
    if is_needs_input_error(error) {
        "needs_input"
    } else {
        "target_payload_invalid"
    }
}

pub(super) fn policy_preflight_status(error: &CapabilityError) -> &'static str {
    if is_needs_input_error(error) {
        "needs_input"
    } else {
        "target_policy_rejected"
    }
}

fn is_needs_input_error(error: &CapabilityError) -> bool {
    error.details().is_some_and(|details| {
        details
            .get("validationKind")
            .and_then(Value::as_str)
            .is_some_and(|kind| matches!(kind, "missing_required_argument" | "repairable_argument"))
    })
}

pub(super) fn is_missing_required_argument_error(error: &CapabilityError) -> bool {
    error.details().is_some_and(|details| {
        details
            .get("validationKind")
            .and_then(Value::as_str)
            .is_some_and(|kind| kind == "missing_required_argument")
    })
}

fn preflight_message(function: &FunctionDefinition, status: &str, message: &str) -> String {
    if status == "needs_input" {
        format!(
            "{} needs input before child execution: {message}",
            function.id.as_str()
        )
    } else {
        format!(
            "{} rejected before child execution: {message}",
            function.id.as_str()
        )
    }
}

fn preflight_guidance(status: &str, details: Option<&Value>) -> Value {
    if status == "idempotency_required" {
        return json!({
            "kind": "provide_idempotency_key",
            "message": "Re-run execute with a stable top-level idempotencyKey for this intended mutation.",
            "missingFields": ["idempotencyKey"],
            "missingArgumentPaths": ["idempotencyKey"],
            "invalidFields": [],
            "invalidArgumentPaths": [],
        });
    }
    if status != "needs_input" {
        return Value::Null;
    }
    let missing_fields = details
        .and_then(|details| details.get("missingFields"))
        .cloned()
        .unwrap_or_else(|| json!([]));
    let argument_paths = details
        .and_then(|details| details.get("missingArgumentPaths"))
        .cloned()
        .unwrap_or_else(|| json!([]));
    let invalid_fields = details
        .and_then(|details| details.get("invalidFields"))
        .cloned()
        .unwrap_or_else(|| json!([]));
    let invalid_argument_paths = details
        .and_then(|details| details.get("invalidArgumentPaths"))
        .cloned()
        .unwrap_or_else(|| json!([]));
    let has_invalid_arguments = invalid_fields
        .as_array()
        .is_some_and(|fields| !fields.is_empty())
        || invalid_argument_paths
            .as_array()
            .is_some_and(|paths| !paths.is_empty());
    json!({
        "kind": if has_invalid_arguments { "correct_arguments" } else { "provide_missing_arguments" },
        "message": "Re-run execute with the same selected target and provide or correct the named fields inside execute.arguments.",
        "missingFields": missing_fields,
        "missingArgumentPaths": argument_paths,
        "invalidFields": invalid_fields,
        "invalidArgumentPaths": invalid_argument_paths,
    })
}

pub(super) fn child_execute_causal_context(
    invocation: &Invocation,
    function: &FunctionDefinition,
    idempotency_key: Option<String>,
) -> CausalContext {
    let mut causal_context = CausalContext::new(
        invocation.causal_context.actor_id.clone(),
        invocation.causal_context.actor_kind.clone(),
        invocation.causal_context.authority_grant_id.clone(),
        invocation.causal_context.trace_id.clone(),
    )
    .with_parent_invocation(invocation.id.clone());
    if let Some(session_id) = &invocation.causal_context.session_id {
        causal_context = causal_context.with_session_id(session_id.clone());
    }
    if let Some(workspace_id) = &invocation.causal_context.workspace_id {
        causal_context = causal_context.with_workspace_id(workspace_id.clone());
    }
    for (key, value) in &invocation.causal_context.runtime_metadata {
        causal_context = causal_context.with_runtime_metadata(key.clone(), value.clone());
    }
    for scope in invocation
        .causal_context
        .authority_scopes
        .iter()
        .chain(function.required_authority.scopes.iter())
    {
        if !causal_context.has_scope(scope) {
            causal_context = causal_context.with_scope(scope.clone());
        }
    }
    if let Some(key) = idempotency_key {
        causal_context = causal_context.with_idempotency_key(key);
    }
    causal_context
}

async fn await_approval_result(
    invocation: &Invocation,
    deps: &Deps,
    function: &FunctionDefinition,
    target: &ResolvedCapabilityTarget,
    approval: EngineApprovalRecord,
) -> Result<Value, CapabilityError> {
    let approval_id = approval.approval_id.clone();
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(30 * 60);
    let mut latest = approval;

    loop {
        match latest.status {
            ApprovalStatus::Executed => {
                let output = latest.result.clone().unwrap_or(Value::Null);
                let child_invocations =
                    approval_child_invocation_ids(deps, &latest, function).await;
                return approved_execution_result(
                    invocation,
                    function,
                    target,
                    &latest,
                    output,
                    child_invocations,
                );
            }
            ApprovalStatus::Failed => {
                let message = latest
                    .error
                    .as_ref()
                    .map(|error| error.message.clone())
                    .unwrap_or_else(|| {
                        format!("Approved invocation of {} failed.", function.id.as_str())
                    });
                return capability_result_value(CapabilityResult {
                    content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
                        message,
                    )]),
                    details: Some(approval_details(function, target, &latest, "failed")),
                    is_error: Some(true),
                    stop_turn: None,
                });
            }
            ApprovalStatus::Denied => {
                return capability_result_value(CapabilityResult {
                    content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
                        format!("Approval denied for {}.", function.id.as_str()),
                    )]),
                    details: Some(approval_details(function, target, &latest, "denied")),
                    is_error: Some(true),
                    stop_turn: Some(true),
                });
            }
            ApprovalStatus::Pending | ApprovalStatus::Approved => {
                if tokio::time::Instant::now() >= deadline {
                    return capability_result_value(CapabilityResult {
                        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
                            format!(
                                "Timed out waiting for approval before executing {}.",
                                function.id.as_str()
                            ),
                        )]),
                        details: Some(approval_details(function, target, &latest, "timeout")),
                        is_error: Some(true),
                        stop_turn: Some(true),
                    });
                }
                tokio::time::sleep(std::time::Duration::from_millis(250)).await;
                latest = deps
                    .engine_host
                    .get_approval(&approval_id)
                    .await
                    .map_err(engine_error_to_capability_error)?
                    .ok_or_else(|| CapabilityError::Custom {
                        code: "APPROVAL_NOT_FOUND".to_owned(),
                        message: format!("approval {approval_id} disappeared before resolution"),
                        details: Some(json!({ "approvalId": approval_id })),
                    })?;
            }
        }
    }
}

pub(super) fn approved_execution_result(
    invocation: &Invocation,
    function: &FunctionDefinition,
    target: &ResolvedCapabilityTarget,
    approval: &EngineApprovalRecord,
    output: Value,
    child_invocations: Vec<String>,
) -> Result<Value, CapabilityError> {
    let replayed_approval = approval_was_replayed_for_invocation(invocation, approval);
    let child_invocation_id = child_invocations.first().cloned();
    let approval_state = json!({
        "approvalId": approval.approval_id,
        "approvalRequired": !replayed_approval,
        "approvalCreated": !replayed_approval,
        "approvalExecuted": !replayed_approval && approval.status == ApprovalStatus::Executed,
        "approvalReplayed": replayed_approval,
        "status": approval.status,
        "functionId": function.id.as_str(),
        "traceId": approval.trace_id.as_str(),
        "idempotencyKey": approval.idempotency_key,
        "childInvocationId": child_invocation_id,
        "childInvocationIds": child_invocations.clone()
    });
    let record = CapabilityExecutionRecord {
        status: "ok".to_owned(),
        trace_id: approval.trace_id.as_str().to_owned(),
        root_invocation_id: invocation.id.as_str().to_owned(),
        child_invocations: child_invocations.clone(),
        selected_implementation: target.binding_decision.selected_implementation.clone(),
        function_id: function.id.as_str().to_owned(),
        catalog_revision: target.entry.catalog_revision,
        function_revision: function.revision.0,
        output: output.clone(),
        approval_state: (!replayed_approval).then_some(approval_state.clone()),
        plugin_versions: vec![target.entry.plugin_id.clone()],
        presentation_hints: target
            .entry
            .function
            .metadata
            .get("presentationHints")
            .cloned(),
        binding_decision: target.binding_decision.clone(),
        schema_digest: target.entry.schema_digest.clone(),
    };
    let mut details = serde_json::to_value(&record).map_err(|error| CapabilityError::Internal {
        message: error.to_string(),
    })?;
    details["approvalRequired"] = json!(!replayed_approval);
    details["approvalCreated"] = json!(!replayed_approval);
    details["approvalExecuted"] =
        json!(!replayed_approval && approval.status == ApprovalStatus::Executed);
    details["approvalReplayed"] = json!(replayed_approval);
    details["idempotencyKey"] = json!(approval.idempotency_key);
    details["childInvocationCreated"] =
        json!(!replayed_approval && !record.child_invocations.is_empty());
    if replayed_approval {
        details["approvalReplay"] = approval_state;
        details["replayedFromTraceId"] = json!(approval.trace_id.as_str());
    }
    if let Ok(mut nested) = serde_json::from_value::<CapabilityResult>(output.clone()) {
        nested.details = Some(merge_optional_details(nested.details, details));
        return capability_result_value(nested);
    }
    let text = serde_json::to_string_pretty(&output).unwrap_or_else(|_| output.to_string());
    capability_result_value(CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(text)]),
        details: Some(details),
        is_error: None,
        stop_turn: None,
    })
}

pub(super) fn approval_was_replayed_for_invocation(
    invocation: &Invocation,
    approval: &EngineApprovalRecord,
) -> bool {
    approval.trace_id != invocation.causal_context.trace_id
        || approval.parent_invocation_id.as_ref() != Some(&invocation.id)
}

fn approval_details(
    function: &FunctionDefinition,
    target: &ResolvedCapabilityTarget,
    approval: &EngineApprovalRecord,
    status: &str,
) -> Value {
    json!({
        "status": status,
        "approvalState": {
            "approvalId": approval.approval_id,
            "status": approval.status,
            "functionId": function.id.as_str(),
            "traceId": approval.trace_id.as_str(),
            "idempotencyKey": approval.idempotency_key
        },
        "selectedImplementation": target.binding_decision.selected_implementation,
        "bindingDecision": target.binding_decision
    })
}

async fn approval_child_invocation_ids(
    deps: &Deps,
    approval: &EngineApprovalRecord,
    function: &FunctionDefinition,
) -> Vec<String> {
    approval_child_invocation_ids_from_records(
        &deps.engine_host.invocation_records().await,
        approval,
        function,
    )
}

pub(super) fn approval_child_invocation_ids_from_records(
    records: &[InvocationRecord],
    approval: &EngineApprovalRecord,
    function: &FunctionDefinition,
) -> Vec<String> {
    let Some(parent_invocation_id) = approval.parent_invocation_id.as_ref() else {
        return Vec::new();
    };
    records
        .iter()
        .filter(|record| {
            record.parent_invocation_id.as_ref() == Some(parent_invocation_id)
                && record.trace_id == approval.trace_id
                && record.function_id == function.id
                && record.idempotency_key == approval.idempotency_key
        })
        .map(|record| record.invocation_id.as_str().to_owned())
        .collect()
}

pub(super) async fn execute_program_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let actor = actor_from_invocation(invocation)?;
    let program_target = json!({
        "functionId": crate::domains::program::contract::RUN_JAVASCRIPT_FUNCTION_ID
    });
    let target = resolve_target(&program_target, deps, &actor).await?;
    let function = target.entry.function.clone();
    enforce_execution_policy(invocation, &target.binding_decision, &function)?;
    let expected_revision = u64_field(&invocation.payload, "expectedRevision");
    let expected_schema_digest = string_field(&invocation.payload, "expectedSchemaDigest")
        .or_else(|| string_field(&invocation.payload, "expected_schema_digest"));
    let inspection_handle = string_field(&invocation.payload, "inspectionHandle")
        .or_else(|| string_field(&invocation.payload, "inspection_handle"));
    if expected_revision.is_none()
        || expected_schema_digest.is_none()
        || inspection_handle.is_none()
    {
        return Err(missing_inspection_requirements_error(
            &function,
            &target.entry,
            expected_revision,
            expected_schema_digest.as_deref(),
            inspection_handle.as_deref(),
        ));
    }
    let valid_inspection = validate_inspection_handle(
        deps,
        inspection_handle.as_deref().unwrap_or_default(),
        target.entry.clone(),
    )
    .await?;
    if !valid_inspection {
        return Err(CapabilityError::Custom {
            code: "INSPECTION_HANDLE_INVALID".to_owned(),
            message: format!(
                "{} requires a fresh inspection handle for the selected implementation",
                function.id.as_str()
            ),
            details: Some(json!({
                "functionId": function.id.as_str(),
                "currentRevision": function.revision.0,
                "currentSchemaDigest": target.entry.schema_digest,
            })),
        });
    }
    if let Some(expected) = expected_revision
        && expected != function.revision.0
    {
        return Err(CapabilityError::Custom {
            code: "STALE_CAPABILITY_REVISION".to_owned(),
            message: format!(
                "{} is at revision {}, not requested revision {expected}",
                function.id.as_str(),
                function.revision.0
            ),
            details: Some(json!({
                "functionId": function.id.as_str(),
                "expectedRevision": expected,
                "currentRevision": function.revision.0,
            })),
        });
    }
    if let Some(expected) = expected_schema_digest.as_deref()
        && expected != target.entry.schema_digest
    {
        return Err(CapabilityError::Custom {
            code: "STALE_CAPABILITY_SCHEMA".to_owned(),
            message: format!(
                "{} has schema digest {}, not requested digest {expected}",
                function.id.as_str(),
                target.entry.schema_digest
            ),
            details: Some(json!({
                "functionId": function.id.as_str(),
                "expectedSchemaDigest": expected,
                "currentSchemaDigest": target.entry.schema_digest,
            })),
        });
    }
    let language = string_field(&invocation.payload, "language").ok_or_else(|| {
        CapabilityError::InvalidParams {
            message: "execute mode 'program' requires language='javascript'".to_owned(),
        }
    })?;
    if language != "javascript" {
        return Err(CapabilityError::InvalidParams {
            message: "execute mode 'program' currently supports JavaScript only".to_owned(),
        });
    }
    let code = string_field(&invocation.payload, "code").ok_or_else(|| {
        CapabilityError::InvalidParams {
            message: "execute mode 'program' requires code".to_owned(),
        }
    })?;
    if code.trim().is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "execute mode 'program' requires non-empty code".to_owned(),
        });
    }
    if invocation.causal_context.idempotency_key.is_none()
        && string_field(&invocation.payload, "idempotencyKey")
            .or_else(|| string_field(&invocation.payload, "idempotency_key"))
            .is_none()
    {
        return Err(CapabilityError::InvalidParams {
            message: "execute mode 'program' requires idempotencyKey or a model invocation idempotency context".to_owned(),
        });
    }
    let mut program_payload = json!({
        "language": language,
        "code": code,
        "args": invocation.payload.get("args").cloned().unwrap_or_else(|| json!({})),
        "allowedContracts": invocation.payload.get("allowedContracts").cloned().unwrap_or_else(|| json!([])),
        "allowedImplementations": invocation.payload.get("allowedImplementations").cloned().unwrap_or_else(|| json!([])),
        "budget": invocation.payload.get("budget").cloned().unwrap_or(Value::Null),
        "reason": string_field(&invocation.payload, "reason"),
    });
    if let Some(timeout_ms) = u64_field(&invocation.payload, "timeoutMs") {
        program_payload["timeoutMs"] = json!(timeout_ms);
    }
    if let Some(key) = string_field(&invocation.payload, "idempotencyKey")
        .or_else(|| string_field(&invocation.payload, "idempotency_key"))
    {
        program_payload["idempotencyKey"] = json!(key);
    }
    let mut causal_context = invocation
        .causal_context
        .clone()
        .with_parent_invocation(invocation.id.clone())
        .with_scope("program.execute");
    causal_context.runtime_metadata.insert(
        "rootInvocationId".to_owned(),
        invocation.id.as_str().to_owned(),
    );
    causal_context.runtime_metadata.insert(
        "bindingDecisionId".to_owned(),
        target.binding_decision.decision_id.clone(),
    );
    if let Some(key) = string_field(&invocation.payload, "idempotencyKey")
        .or_else(|| string_field(&invocation.payload, "idempotency_key"))
    {
        causal_context = causal_context.with_idempotency_key(key);
    }
    let mut child = Invocation::new_sync(function.id.clone(), program_payload, causal_context);
    if let Some(expected) = expected_revision {
        child = child.expecting_revision(FunctionRevision(expected));
    }
    let result = deps.engine_host.invoke(child).await;
    if let Some(error) = result.error {
        return Err(engine_error_to_capability_error(error));
    }
    let mut details = result.value.unwrap_or(Value::Null);
    if let Some(object) = details.as_object_mut() {
        object.insert(
            "parentInvocationId".to_owned(),
            json!(invocation.id.as_str()),
        );
        object.insert("rootInvocationId".to_owned(), json!(invocation.id.as_str()));
        object.insert(
            "bindingDecisionId".to_owned(),
            json!(target.binding_decision.decision_id.clone()),
        );
    }
    let program_status = details
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("ok")
        .to_owned();
    {
        let store = deps.registry_store.clone();
        let trace_id = result.trace_id.as_str().to_owned();
        let audit_payload = json!({
            "status": program_status.clone(),
            "mode": "program",
            "contractId": target.binding_decision.contract_id.clone(),
            "implementationId": target.binding_decision.selected_implementation.clone(),
            "functionId": function.id.as_str(),
            "bindingDecision": target.binding_decision.clone(),
            "programRunId": details.get("programRunId").cloned().unwrap_or(Value::Null),
            "parentInvocationId": details.get("parentInvocationId").cloned().unwrap_or(Value::Null),
            "rootInvocationId": details.get("rootInvocationId").cloned().unwrap_or(Value::Null),
            "bindingDecisionId": details.get("bindingDecisionId").cloned().unwrap_or(Value::Null),
            "codeHash": details.get("codeHash").cloned().unwrap_or(Value::Null),
            "argsHash": details.get("argsHash").cloned().unwrap_or(Value::Null),
            "childInvocations": details.get("childInvocations").cloned().unwrap_or_else(|| json!([])),
        });
        run_blocking_task("capability.execute.program.audit", move || {
            let mut store = store.lock().map_err(|_| CapabilityError::Internal {
                message: "capability registry store mutex poisoned".to_owned(),
            })?;
            store
                .record_audit_event("capability.execute.program", Some(&trace_id), audit_payload)
                .map_err(registry_store_error)
        })
        .await?;
    }
    let is_error = program_status != "ok";
    capability_result_value(CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(format!(
            "Program run {} {}.",
            details
                .get("programRunId")
                .and_then(Value::as_str)
                .unwrap_or("<unknown>"),
            program_status
        ))]),
        details: Some(details),
        is_error: is_error.then_some(true),
        stop_turn: is_error.then_some(true),
    })
}
