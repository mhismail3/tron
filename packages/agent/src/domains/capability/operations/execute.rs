//! Single execute orchestrator phases for the model-facing capability primitive.

use serde_json::{Map, Value, json};
use std::collections::BTreeSet;

use super::{
    ResolvedCapabilityTarget, actor_from_invocation, capability_primitive_target_error,
    capability_result_value, index_status_needs_vector_warmup, is_capability_primitive,
    registry_metadata_sync_policy, registry_snapshot_for_functions, registry_store_error,
    requires_fresh_revision_for_payload, resolve_target, run, schedule_vector_warmup,
};
use crate::domains::capability::Deps;
use crate::domains::capability::registry::{
    CapabilityRegistryEntry, CapabilityRegistrySnapshot, CapabilitySearchFilters,
    CapabilitySearchPolicy, CapabilityTarget, parse_target, string_field,
};
use crate::engine::{ActorContext, FunctionHealth, FunctionQuery, Invocation};
use crate::shared::content::CapabilityResultContent;
use crate::shared::model_capabilities::{CapabilityResult, CapabilityResultBody};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;

#[cfg(test)]
use super::target_arguments::intent_file_read_requests;
use super::target_arguments::{
    intent_requests_resource_inventory, normalize_contextual_target_arguments,
    normalize_intent_target_arguments, normalize_target_arguments,
    normalize_target_idempotency_argument, normalized_intent_words,
};
#[cfg(test)]
use super::target_resolution::deterministic_intent_route;
use super::target_resolution::{
    apply_argument_schema_fit_filter, apply_deterministic_intent_route, bounded_snippet,
    clarification_candidates_for_intent, decomposition_phase_details, decomposition_result_message,
    intent_strongly_matches_hit, lacks_sufficient_intent_resolution_evidence,
    orchestration_candidate_summary, orchestration_constraints_allow_hit,
    promote_argument_schema_fit_candidates, validate_orchestration_constraint_shape,
    validate_orchestration_constraints,
};
#[cfg(test)]
use super::validate_target_payload;

const EXECUTE_WRAPPER_KEYS: &[&str] = &[
    "intent",
    "target",
    "arguments",
    "constraints",
    "operation",
    "payload",
    "idempotencyKey",
    "idempotency_key",
    "reason",
    "mode",
    "capabilityId",
    "contractId",
    "implementationId",
    "functionId",
    "language",
    "code",
    "args",
    "allowedContracts",
    "allowedImplementations",
    "timeoutMs",
    "budget",
    "expectedRevision",
    "expectedSchemaDigest",
    "inspectionHandle",
];

pub(crate) async fn execute_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    if is_orchestrated_execute_payload(&invocation.payload) {
        let result = execute_orchestrated_value(invocation, deps).await?;
        return attach_execute_invocation_metadata(result, invocation);
    }
    let mode = string_field(&invocation.payload, "mode").unwrap_or_else(|| "invoke".to_owned());
    match mode.as_str() {
        "invoke" => run::execute_invoke_value(invocation, deps).await,
        "program" => run::execute_program_value(invocation, deps).await,
        other => Err(CapabilityError::InvalidParams {
            message: format!("Unsupported capability execute mode '{other}'"),
        }),
    }
}

#[derive(Debug)]
pub(super) struct OrchestratedExecuteInput {
    pub(super) intent: Option<String>,
    pub(super) target_params: Option<Value>,
    pub(super) arguments: Value,
    pub(super) constraints: Value,
    pub(super) operation: Option<String>,
    pub(super) idempotency_key: Option<String>,
    pub(super) reason: Option<String>,
    pub(super) corrections: Vec<Value>,
}

impl OrchestratedExecuteInput {
    fn discovery_only(&self) -> bool {
        if self.operation.as_deref() == Some("discover") {
            return true;
        }
        if self.operation.as_deref() == Some("run") {
            return false;
        }
        if self
            .arguments
            .as_object()
            .is_some_and(|object| !object.is_empty())
        {
            return false;
        }
        discovery_only_text(self.intent.as_deref())
            || discovery_only_text(self.reason.as_deref())
            || self
                .constraints
                .get("operation")
                .and_then(Value::as_str)
                .is_some_and(|value| value.eq_ignore_ascii_case("discover"))
    }
}

fn is_orchestrated_execute_payload(params: &Value) -> bool {
    params.get("intent").is_some()
        || params.get("target").is_some()
        || params.get("arguments").is_some()
        || params.get("constraints").is_some()
        || (params.get("mode").is_none() && params.get("payload").is_some())
        || (params.get("mode").is_none()
            && params
                .as_object()
                .is_some_and(|object| object.keys().any(|key| !is_execute_wrapper_key(key))))
        || (params.get("mode").is_none() && params.as_object().is_some_and(Map::is_empty))
}

async fn execute_orchestrated_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let orchestration_id = format!("capability-orchestration:{}", uuid::Uuid::now_v7());
    let actor = actor_from_invocation(invocation)?;
    let mut input = match parse_orchestrated_execute_input(&invocation.payload) {
        Ok(input) => input,
        Err(error) => {
            let diagnostics =
                orchestration_request_error_details(&orchestration_id, "request_invalid", &error);
            record_orchestration_audit(deps, invocation, diagnostics.clone()).await?;
            return orchestration_result(
                "request_invalid",
                &format!("execute request is invalid: {error}"),
                diagnostics,
                true,
            );
        }
    };
    normalize_live_resource_inventory_operation(&mut input);
    if let Err(error) = validate_orchestration_constraint_shape(&input.constraints) {
        let diagnostics = orchestration_details(
            &orchestration_id,
            "constraints_rejected",
            input.intent.as_deref(),
            None,
            &input,
            json!({
                "phase": "resolve",
                "error": capability_error_details(&error),
            }),
            Vec::new(),
        );
        record_orchestration_audit(deps, invocation, diagnostics.clone()).await?;
        return orchestration_result(
            "constraints_rejected",
            &format!("execute constraints are invalid: {error}"),
            diagnostics,
            true,
        );
    }
    let resolve = match input.target_params.clone() {
        Some(target_params) => OrchestrationResolve {
            target_params,
            mode: "explicit_target".to_owned(),
            candidates: Vec::new(),
            rejected_candidates: Vec::new(),
            search_status: Value::Null,
        },
        None => {
            let has_argument_shape = input
                .arguments
                .as_object()
                .is_some_and(|object| !object.is_empty());
            let Some(intent) = input.intent.as_deref().or(has_argument_shape.then_some("")) else {
                let diagnostics = orchestration_details(
                    &orchestration_id,
                    "needs_input",
                    input.intent.as_deref(),
                    None,
                    &input,
                    json!({
                        "phase": "resolve",
                        "missingFields": ["intent", "target"]
                    }),
                    Vec::new(),
                );
                record_orchestration_audit(deps, invocation, diagnostics.clone()).await?;
                return orchestration_result(
                    "needs_input",
                    "Tell execute either the natural-language intent or an explicit target capability.",
                    diagnostics,
                    orchestration_status_is_error("needs_input"),
                );
            };
            match resolve_intent_target(intent, &input.arguments, &actor, deps, &input.constraints)
                .await?
            {
                IntentResolveOutcome::Resolved(resolve) => resolve,
                IntentResolveOutcome::NeedsCapability {
                    candidates,
                    search_status,
                } => {
                    let diagnostics = orchestration_details(
                        &orchestration_id,
                        "needs_capability",
                        input.intent.as_deref(),
                        None,
                        &input,
                        json!({
                            "phase": "resolve",
                            "candidates": candidates,
                            "searchStatus": search_status,
                            "proposedCapabilityShape": {
                                "contractId": "<namespace>::<function>",
                                "argumentsSchema": {},
                                "effect": "pure_read|idempotent_write|external_side_effect",
                                "risk": "low|medium|high|critical"
                            }
                        }),
                        Vec::new(),
                    );
                    record_orchestration_audit(deps, invocation, diagnostics.clone()).await?;
                    return orchestration_result(
                        "needs_capability",
                        "No visible healthy capability clearly matches that intent.",
                        diagnostics,
                        orchestration_status_is_error("needs_capability"),
                    );
                }
                IntentResolveOutcome::NeedsSelection {
                    candidates,
                    search_status,
                } => {
                    let message = needs_selection_message(&candidates);
                    let diagnostics = orchestration_details(
                        &orchestration_id,
                        "needs_selection",
                        input.intent.as_deref(),
                        None,
                        &input,
                        json!({
                            "phase": "resolve",
                            "candidates": candidates,
                            "searchStatus": search_status,
                        }),
                        Vec::new(),
                    );
                    record_orchestration_audit(deps, invocation, diagnostics.clone()).await?;
                    return orchestration_result(
                        "needs_selection",
                        &message,
                        diagnostics,
                        orchestration_status_is_error("needs_selection"),
                    );
                }
                IntentResolveOutcome::TriggerMetadataTarget {
                    guidance,
                    search_status,
                } => {
                    let phase_details = trigger_metadata_target_phase_details(
                        "intent_resolution",
                        None,
                        &guidance,
                        search_status,
                    );
                    let diagnostics = orchestration_details(
                        &orchestration_id,
                        "needs_selection",
                        input.intent.as_deref(),
                        None,
                        &input,
                        phase_details,
                        Vec::new(),
                    );
                    record_orchestration_audit(deps, invocation, diagnostics.clone()).await?;
                    return orchestration_result(
                        "needs_selection",
                        &trigger_metadata_target_message(&guidance),
                        diagnostics,
                        orchestration_status_is_error("needs_selection"),
                    );
                }
            }
        }
    };

    input.target_params = Some(resolve.target_params.clone());
    let target = match resolve_target(&resolve.target_params, deps, &actor).await {
        Ok(target) => target,
        Err(error @ CapabilityError::NotFound { .. }) => {
            if let Some(guidance) = trigger_metadata_target_guidance_for_visible_catalog(
                &resolve.target_params,
                &input.arguments,
                deps,
                &actor,
            )
            .await
            {
                let phase_details = trigger_metadata_target_phase_details(
                    &resolve.mode,
                    Some(resolve.target_params.clone()),
                    &guidance,
                    resolve.search_status.clone(),
                );
                let diagnostics = orchestration_details(
                    &orchestration_id,
                    "needs_selection",
                    input.intent.as_deref(),
                    None,
                    &input,
                    phase_details,
                    Vec::new(),
                );
                record_orchestration_audit(deps, invocation, diagnostics.clone()).await?;
                return orchestration_result(
                    "needs_selection",
                    &trigger_metadata_target_message(&guidance),
                    diagnostics,
                    orchestration_status_is_error("needs_selection"),
                );
            }
            let diagnostics = orchestration_details(
                &orchestration_id,
                "needs_capability",
                input.intent.as_deref(),
                None,
                &input,
                json!({
                    "phase": "resolve",
                    "resolveMode": resolve.mode,
                    "selectedTarget": resolve.target_params,
                    "error": capability_error_details(&error),
                    "proposedCapabilityShape": {
                        "contractId": "<namespace>::<function>",
                        "argumentsSchema": {},
                        "effect": "pure_read|idempotent_write|external_side_effect",
                        "risk": "low|medium|high|critical"
                    }
                }),
                Vec::new(),
            );
            record_orchestration_audit(deps, invocation, diagnostics.clone()).await?;
            return orchestration_result(
                "needs_capability",
                "No visible healthy capability matches the requested target.",
                diagnostics,
                orchestration_status_is_error("needs_capability"),
            );
        }
        Err(error) => {
            let diagnostics = orchestration_details(
                &orchestration_id,
                "prepare_failed",
                input.intent.as_deref(),
                None,
                &input,
                json!({
                    "phase": "prepare",
                    "resolveMode": resolve.mode,
                    "selectedTarget": resolve.target_params,
                    "error": capability_error_details(&error),
                }),
                Vec::new(),
            );
            record_orchestration_audit(deps, invocation, diagnostics.clone()).await?;
            return orchestration_result(
                "prepare_failed",
                &format!("execute could not prepare the selected target: {error}"),
                diagnostics,
                true,
            );
        }
    };
    let function = target.entry.function.clone();
    if is_capability_primitive(&function) {
        let error = capability_primitive_target_error(&function);
        let diagnostics = orchestration_details(
            &orchestration_id,
            "request_invalid",
            input.intent.as_deref(),
            None,
            &input,
            json!({
                "phase": "prepare",
                "resolveMode": resolve.mode,
                "selectedTarget": {
                    "contractId": target.entry.contract_id.as_str(),
                    "implementationId": target.entry.implementation_id.as_str(),
                    "functionId": function.id.as_str(),
                    "catalogRevision": target.entry.catalog_revision,
                    "schemaDigest": target.entry.schema_digest.as_str(),
                },
                "error": capability_error_details(&error),
                "guidance": {
                    "kind": "target_real_capability",
                    "message": "Call execute once. Use target for the real capability you want, not capability::execute, and put only that capability's arguments inside arguments.",
                    "examples": [
                        {"target": "filesystem::read_file", "arguments": {"path": "README.md"}},
                        {"target": "process::run", "arguments": {"command": "date", "executionMode": "read_only"}}
                    ]
                }
            }),
            Vec::new(),
        );
        record_orchestration_audit(deps, invocation, diagnostics.clone()).await?;
        return orchestration_result(
            "request_invalid",
            &format!("execute target is invalid: {error}"),
            diagnostics,
            true,
        );
    }
    if let Err(error) = validate_orchestration_constraints(&input.constraints, &target.entry) {
        let diagnostics = orchestration_details(
            &orchestration_id,
            "constraints_rejected",
            input.intent.as_deref(),
            None,
            &input,
            json!({
                "phase": "prepare",
                "resolveMode": resolve.mode,
                "selectedTarget": {
                    "contractId": target.entry.contract_id.as_str(),
                    "implementationId": target.entry.implementation_id.as_str(),
                    "functionId": function.id.as_str(),
                },
                "error": capability_error_details(&error),
            }),
            Vec::new(),
        );
        record_orchestration_audit(deps, invocation, diagnostics.clone()).await?;
        return orchestration_result(
            "constraints_rejected",
            &format!("execute constraints rejected the selected target: {error}"),
            diagnostics,
            true,
        );
    }
    if input.discovery_only() {
        let diagnostics = orchestration_details(
            &orchestration_id,
            "capability_discovery",
            input.intent.as_deref(),
            Some(corrected_orchestrated_request(&input)),
            &input,
            discovery_phase_details(&resolve, &target),
            Vec::new(),
        );
        record_orchestration_audit(deps, invocation, diagnostics.clone()).await?;
        return orchestration_result(
            "capability_discovery",
            &discovery_message(&target),
            diagnostics,
            false,
        );
    }
    if let Some(decomposition) =
        decomposition_phase_details(&resolve, &target, input.intent.as_deref(), &input.arguments)
    {
        let message = decomposition_result_message(&decomposition);
        let diagnostics = orchestration_details(
            &orchestration_id,
            "needs_decomposition",
            input.intent.as_deref(),
            Some(corrected_orchestrated_request(&input)),
            &input,
            decomposition,
            Vec::new(),
        );
        record_orchestration_audit(deps, invocation, diagnostics.clone()).await?;
        return orchestration_result(
            "needs_decomposition",
            &message,
            diagnostics,
            orchestration_status_is_error("needs_decomposition"),
        );
    }
    normalize_target_arguments(&function, &mut input.arguments, &mut input.corrections);
    normalize_intent_target_arguments(
        &function,
        input.intent.as_deref(),
        &mut input.arguments,
        &mut input.corrections,
    );
    normalize_contextual_target_arguments(
        &function,
        invocation,
        &mut input.arguments,
        &mut input.corrections,
    );
    normalize_target_idempotency_argument(
        &function,
        &mut input.arguments,
        input.idempotency_key.as_deref(),
        &mut input.corrections,
    );
    let mut prepared_payload = prepared_execute_payload(&resolve.target_params, &input);
    if requires_fresh_revision_for_payload(&function, &prepared_payload) {
        let freshness = record_orchestration_inspection(invocation, deps, &target).await?;
        prepared_payload["inspectionHandle"] = freshness["inspectionHandle"].clone();
        prepared_payload["expectedRevision"] = freshness["expectedRevision"].clone();
        prepared_payload["expectedSchemaDigest"] = freshness["expectedSchemaDigest"].clone();
        input.corrections.push(correction_record(
            "freshness_prepared",
            "execute acquired a fresh inspection handle for mutating or elevated-risk work",
            1.0,
        ));
    }

    let corrected_request = corrected_orchestrated_request(&input);
    let prepare_diagnostics = json!({
        "phase": "prepare",
        "resolveMode": resolve.mode,
        "candidates": resolve.candidates,
        "rejectedCandidates": resolve.rejected_candidates,
        "searchStatus": resolve.search_status,
        "selectedTarget": {
            "contractId": target.entry.contract_id.as_str(),
            "implementationId": target.entry.implementation_id.as_str(),
            "functionId": function.id.as_str(),
            "catalogRevision": target.entry.catalog_revision,
            "schemaDigest": target.entry.schema_digest.as_str(),
            "effectClass": format!("{:?}", function.effect_class),
            "riskLevel": format!("{:?}", function.risk_level),
        },
        "preparedRequest": redacted_prepared_request_preview(&prepared_payload),
    });

    let mut prepared_invocation = invocation.clone();
    prepared_invocation.payload = prepared_payload;
    let mut result = match run::execute_invoke_value(&prepared_invocation, deps).await {
        Ok(result) => result,
        Err(error) => {
            let failure_status = orchestration_failure_status(&error);
            let failure_phase = if failure_status == "prepare_failed" {
                "prepare"
            } else {
                "run"
            };
            let diagnostics = orchestration_details(
                &orchestration_id,
                failure_status,
                input.intent.as_deref(),
                Some(corrected_request),
                &input,
                json!({
                    "phase": failure_phase,
                    "prepare": prepare_diagnostics,
                    "selectedTarget": {
                        "contractId": target.entry.contract_id.as_str(),
                        "implementationId": target.entry.implementation_id.as_str(),
                        "functionId": function.id.as_str(),
                        "catalogRevision": target.entry.catalog_revision,
                        "schemaDigest": target.entry.schema_digest.as_str(),
                    },
                    "error": capability_error_details(&error),
                }),
                Vec::new(),
            );
            record_orchestration_audit(deps, invocation, diagnostics.clone()).await?;
            let message = if failure_status == "prepare_failed" {
                format!("execute could not prepare the selected target: {error}")
            } else {
                format!("execute failed while running the selected target: {error}")
            };
            return orchestration_result(failure_status, &message, diagnostics, true);
        }
    };
    let result_status = serde_json::from_value::<CapabilityResult>(result.clone())
        .ok()
        .and_then(|capability_result| capability_result.details)
        .and_then(|details| {
            details
                .get("status")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
        })
        .unwrap_or_else(|| "executed".to_owned());
    let mut diagnostics = orchestration_details(
        &orchestration_id,
        &result_status,
        input.intent.as_deref(),
        Some(corrected_request),
        &input,
        prepare_diagnostics,
        orchestration_child_invocations(&result),
    );
    enrich_orchestration_with_result(&mut diagnostics, &result);
    record_orchestration_audit(deps, invocation, diagnostics.clone()).await?;
    result = attach_orchestration_details(result, diagnostics)?;
    Ok(result)
}

#[derive(Debug)]
pub(super) struct OrchestrationResolve {
    pub(super) target_params: Value,
    pub(super) mode: String,
    pub(super) candidates: Vec<Value>,
    pub(super) rejected_candidates: Vec<Value>,
    pub(super) search_status: Value,
}

enum IntentResolveOutcome {
    Resolved(OrchestrationResolve),
    NeedsSelection {
        candidates: Vec<Value>,
        search_status: Value,
    },
    NeedsCapability {
        candidates: Vec<Value>,
        search_status: Value,
    },
    TriggerMetadataTarget {
        guidance: Value,
        search_status: Value,
    },
}

pub(super) fn parse_orchestrated_execute_input(
    params: &Value,
) -> Result<OrchestratedExecuteInput, CapabilityError> {
    let mut corrections = Vec::new();
    let intent = string_field(params, "intent");
    let mut target_params = target_params_from_hint(params.get("target"))?;
    if target_params.is_none() {
        let mut direct_target = Map::new();
        for key in [
            "functionId",
            "implementationId",
            "contractId",
            "capabilityId",
        ] {
            if let Some(value) = params.get(key).cloned() {
                direct_target.insert(key.to_owned(), value);
            }
        }
        if !direct_target.is_empty() {
            let target = Value::Object(direct_target);
            if parse_target(&target).is_none() {
                return Err(CapabilityError::InvalidParams {
                    message: "top-level target fields must include a non-empty functionId, implementationId, capabilityId, or contractId".to_owned(),
                });
            }
            target_params = Some(target);
            corrections.push(correction_record(
                "top_level_target_to_target",
                "moved top-level target fields into target",
                1.0,
            ));
        }
    }
    let mut idempotency_key =
        string_field(params, "idempotencyKey").or_else(|| string_field(params, "idempotency_key"));
    let mut reason = string_field(params, "reason");
    let constraints = params
        .get("constraints")
        .cloned()
        .unwrap_or_else(|| json!({}));
    if !constraints.is_object() {
        return Err(CapabilityError::InvalidParams {
            message: "execute.constraints must be an object when provided".to_owned(),
        });
    }

    let mut arguments = match (params.get("arguments"), params.get("payload")) {
        (Some(arguments), Some(payload)) if arguments != payload => {
            return Err(CapabilityError::InvalidParams {
                message: "execute received both arguments and payload with different values; use arguments only".to_owned(),
            });
        }
        (Some(arguments), _) => object_value(arguments, "execute.arguments")?,
        (None, Some(payload)) => {
            corrections.push(correction_record(
                "payload_to_arguments",
                "moved top-level payload into arguments",
                1.0,
            ));
            object_value(payload, "execute payload alias")?
        }
        (None, None) => json!({}),
    };
    let operation = string_field(params, "operation")
        .map(|value| normalize_execute_operation(&value))
        .transpose()?;

    normalize_nested_wrapper_shape(
        &mut arguments,
        &mut target_params,
        &mut idempotency_key,
        &mut reason,
        &mut corrections,
    )?;
    normalize_execute_self_target(&mut target_params, &mut corrections);
    normalize_flattened_target_arguments(params, &mut arguments, &mut corrections)?;

    Ok(OrchestratedExecuteInput {
        intent,
        target_params,
        arguments,
        constraints,
        operation,
        idempotency_key,
        reason,
        corrections,
    })
}

fn is_execute_wrapper_key(key: &str) -> bool {
    EXECUTE_WRAPPER_KEYS.contains(&key)
}

fn normalize_flattened_target_arguments(
    params: &Value,
    arguments: &mut Value,
    corrections: &mut Vec<Value>,
) -> Result<(), CapabilityError> {
    let Some(params_object) = params.as_object() else {
        return Ok(());
    };
    let Some(arguments_object) = arguments.as_object_mut() else {
        return Err(CapabilityError::InvalidParams {
            message: "execute.arguments must be an object".to_owned(),
        });
    };

    let flattened = params_object
        .iter()
        .filter(|(key, _)| !is_execute_wrapper_key(key))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect::<Vec<_>>();
    if flattened.is_empty() {
        return Ok(());
    }

    let mut moved = Vec::new();
    let mut deduped = Vec::new();
    for (key, value) in flattened {
        if let Some(existing) = arguments_object.get(&key) {
            if existing == &value {
                deduped.push(key);
                continue;
            }
            return Err(CapabilityError::InvalidParams {
                message: format!(
                    "execute received conflicting values for target argument '{key}' at the root and inside arguments; keep target arguments inside arguments"
                ),
            });
        }
        arguments_object.insert(key.clone(), value);
        moved.push(key);
    }
    if !moved.is_empty() {
        corrections.push(correction_record(
            "top_level_arguments_to_arguments",
            format!(
                "moved flattened target argument fields into arguments: {}",
                moved.join(", ")
            ),
            0.95,
        ));
    }
    if !deduped.is_empty() {
        corrections.push(correction_record(
            "duplicate_flattened_arguments_deduped",
            format!(
                "ignored duplicate flattened target argument fields already present in arguments: {}",
                deduped.join(", ")
            ),
            1.0,
        ));
    }
    Ok(())
}

fn object_value(value: &Value, label: &str) -> Result<Value, CapabilityError> {
    if value.is_object() {
        Ok(value.clone())
    } else {
        Err(CapabilityError::InvalidParams {
            message: format!("{label} must be an object"),
        })
    }
}

fn normalize_execute_operation(value: &str) -> Result<String, CapabilityError> {
    let normalized = value.trim().to_ascii_lowercase();
    match normalized.as_str() {
        "" | "auto" => Ok("auto".to_owned()),
        "discover" | "discovery" | "inspect" | "describe" | "dry_run" | "dry-run" => {
            Ok("discover".to_owned())
        }
        "run" | "invoke" | "execute" => Ok("run".to_owned()),
        _ => Err(CapabilityError::InvalidParams {
            message: format!(
                "Unsupported execute.operation '{value}'; use discover, run, or omit it for auto"
            ),
        }),
    }
}

fn normalize_execute_self_target(target_params: &mut Option<Value>, corrections: &mut Vec<Value>) {
    let Some(target) = target_params.as_ref() else {
        return;
    };
    if !is_execute_self_target(target) {
        return;
    }
    *target_params = None;
    corrections.push(correction_record(
        "execute_self_target_removed",
        "removed target=capability::execute so execute can resolve the real capability from intent",
        1.0,
    ));
}

fn normalize_live_resource_inventory_operation(input: &mut OrchestratedExecuteInput) {
    let Some(intent) = input.intent.as_deref() else {
        return;
    };
    if !intent_requests_resource_inventory(intent, &input.arguments)
        || explicit_discovery_only_request(intent)
    {
        return;
    }
    if input
        .target_params
        .as_ref()
        .is_some_and(|target| !target_is_resource_list(target))
    {
        return;
    }
    if input.operation.as_deref() == Some("run") {
        return;
    }
    input.operation = Some("run".to_owned());
    input.corrections.push(correction_record(
        "resource_inventory_discovery_to_read_only_run",
        "treated resource inventory discovery as a pure-read resource::list operation",
        1.0,
    ));
}

fn explicit_discovery_only_request(intent: &str) -> bool {
    let normalized = intent.to_ascii_lowercase();
    [
        "do not execute",
        "don't execute",
        "no child invocation",
        "without executing",
        "dry run",
        "dry-run",
        "required fields",
        "required arguments",
        "schema",
        "schemas",
    ]
    .iter()
    .any(|phrase| normalized.contains(phrase))
}

fn target_is_resource_list(target: &Value) -> bool {
    matches!(
        parse_target(target),
        Some(CapabilityTarget::Function(id))
            | Some(CapabilityTarget::Contract(id))
            | Some(CapabilityTarget::Capability(id))
            if id == "resource::list"
    )
}

fn is_execute_self_target(target: &Value) -> bool {
    match parse_target(target) {
        Some(CapabilityTarget::Function(id))
        | Some(CapabilityTarget::Contract(id))
        | Some(CapabilityTarget::Capability(id)) => id == "capability::execute",
        Some(CapabilityTarget::Implementation(id)) => {
            id == "function:capability::execute"
                || (id.starts_with("first_party.capability.v") && id.ends_with(".execute"))
        }
        None => false,
    }
}

fn discovery_only_text(value: Option<&str>) -> bool {
    let Some(value) = value else {
        return false;
    };
    let normalized = value.to_ascii_lowercase();
    let explicit_discovery_terms = [
        "discovery only",
        "required fields",
        "required arguments",
        "capability id",
        "capability ids",
        "schema",
        "schemas",
        "safe sequence",
        "dry run",
        "dry-run",
        "do not execute",
        "don't execute",
        "no child invocation",
        "without executing",
    ];
    if explicit_discovery_terms
        .iter()
        .any(|term| normalized.contains(term))
    {
        return true;
    }
    let words = normalized_intent_words(value);
    let asks_to_discover = words.contains("discover") || words.contains("discovery");
    let asks_to_use_result = [
        "use",
        "run",
        "invoke",
        "execute",
        "get",
        "read",
        "list",
        "query",
        "report",
        "show",
        "return",
        "fetch",
        "count",
        "current",
        "status",
        "summary",
        "available",
        "recent",
    ]
    .iter()
    .any(|word| words.contains(*word));
    asks_to_discover && !asks_to_use_result
}

fn target_params_from_hint(value: Option<&Value>) -> Result<Option<Value>, CapabilityError> {
    let Some(value) = value else {
        return Ok(None);
    };
    if let Some(target) = value
        .as_str()
        .map(str::trim)
        .filter(|target| !target.is_empty())
    {
        return Ok(Some(json!({ "capabilityId": target })));
    }
    if value.is_object() {
        if parse_target(value).is_none() {
            return Err(CapabilityError::InvalidParams {
                message: "execute.target object must include one of functionId, implementationId, capabilityId, or contractId".to_owned(),
            });
        }
        return Ok(Some(value.clone()));
    }
    Err(CapabilityError::InvalidParams {
        message: "execute.target must be a capability id string or target object".to_owned(),
    })
}

fn normalize_nested_wrapper_shape(
    arguments: &mut Value,
    target_params: &mut Option<Value>,
    idempotency_key: &mut Option<String>,
    reason: &mut Option<String>,
    corrections: &mut Vec<Value>,
) -> Result<(), CapabilityError> {
    let Some(object) = arguments.as_object_mut() else {
        return Err(CapabilityError::InvalidParams {
            message: "execute.arguments must be an object".to_owned(),
        });
    };

    if target_params.is_none() {
        let mut nested_target = Map::new();
        for key in [
            "functionId",
            "implementationId",
            "contractId",
            "capabilityId",
        ] {
            if let Some(value) = object.remove(key) {
                nested_target.insert(key.to_owned(), value);
            }
        }
        if !nested_target.is_empty() {
            let target = Value::Object(nested_target);
            if parse_target(&target).is_none() {
                return Err(CapabilityError::InvalidParams {
                    message: "wrapper target fields inside arguments were not valid strings"
                        .to_owned(),
                });
            }
            *target_params = Some(target);
            corrections.push(correction_record(
                "nested_target_to_target",
                "moved target fields out of arguments into target",
                1.0,
            ));
        }
    }

    if idempotency_key.is_none()
        && let Some(value) = object
            .remove("idempotencyKey")
            .or_else(|| object.remove("idempotency_key"))
        && let Some(value) = value
            .as_str()
            .map(str::trim)
            .filter(|value| !value.is_empty())
    {
        *idempotency_key = Some(value.to_owned());
        corrections.push(correction_record(
            "nested_idempotency_key_to_wrapper",
            "moved idempotencyKey out of arguments",
            1.0,
        ));
    }
    if reason.is_none()
        && let Some(value) = object.remove("reason")
        && let Some(value) = value
            .as_str()
            .map(str::trim)
            .filter(|value| !value.is_empty())
    {
        *reason = Some(value.to_owned());
        corrections.push(correction_record(
            "nested_reason_to_wrapper",
            "moved reason out of arguments",
            1.0,
        ));
    }

    if let Some(payload) = object.remove("payload") {
        if !payload.is_object() {
            return Err(CapabilityError::InvalidParams {
                message: "nested arguments.payload must be an object when supplied".to_owned(),
            });
        }
        if object.is_empty() {
            *arguments = payload;
            corrections.push(correction_record(
                "nested_payload_to_arguments",
                "moved nested payload into arguments",
                1.0,
            ));
        } else {
            object.insert("payload".to_owned(), payload);
        }
    }

    Ok(())
}

async fn resolve_intent_target(
    intent: &str,
    arguments: &Value,
    actor: &ActorContext,
    deps: &Deps,
    constraints: &Value,
) -> Result<IntentResolveOutcome, CapabilityError> {
    let functions = deps
        .engine_host
        .discover(&FunctionQuery {
            actor: Some(actor.clone()),
            health: Some(FunctionHealth::Healthy),
            ..FunctionQuery::default()
        })
        .await;
    let snapshot = registry_snapshot_for_functions(deps, actor, functions).await;
    if let Some(guidance) =
        trigger_metadata_target_guidance_for_intent(intent, arguments, &snapshot)
    {
        return Ok(IntentResolveOutcome::TriggerMetadataTarget {
            guidance,
            search_status: Value::Null,
        });
    }
    let store = deps.registry_store.clone();
    let embedding_provider = deps.embedding_provider.clone();
    let policy = CapabilitySearchPolicy::default();
    let query = intent.to_owned();
    let snapshot_for_search = snapshot.clone();
    let search = run_blocking_task("capability.execute.resolve", move || {
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        let sync_policy = registry_metadata_sync_policy();
        store
            .sync_snapshot(
                &snapshot_for_search,
                embedding_provider.as_ref(),
                &sync_policy,
            )
            .map_err(registry_store_error)?;
        store
            .search(
                &query,
                &CapabilitySearchFilters {
                    include_unavailable: false,
                    ..CapabilitySearchFilters::default()
                },
                &policy,
                8,
                embedding_provider.as_ref(),
            )
            .map_err(registry_store_error)
    })
    .await?;
    if index_status_needs_vector_warmup(&search.status) {
        schedule_vector_warmup(snapshot.clone(), deps);
    }
    let all_executable_hits = search
        .hits
        .iter()
        .filter(|hit| hit.kind == "implementation" && !hit.function_id.trim().is_empty())
        .cloned()
        .collect::<Vec<_>>();
    let mut executable_hits = all_executable_hits
        .into_iter()
        .filter_map(
            |hit| match orchestration_constraints_allow_hit(constraints, &hit) {
                Ok(true) => Some(Ok(hit)),
                Ok(false) => None,
                Err(error) => Some(Err(error)),
            },
        )
        .collect::<Result<Vec<_>, _>>()?;
    apply_deterministic_intent_route(
        intent,
        arguments,
        &snapshot,
        constraints,
        &mut executable_hits,
    )?;
    promote_argument_schema_fit_candidates(
        arguments,
        &snapshot,
        constraints,
        &mut executable_hits,
    )?;
    let argument_rejected_candidates =
        apply_argument_schema_fit_filter(arguments, &snapshot, &mut executable_hits);
    let candidates = executable_hits
        .iter()
        .map(orchestration_candidate_summary)
        .collect::<Vec<_>>();
    let search_status = serde_json::to_value(&search.status).unwrap_or(Value::Null);
    let Some(selected) = executable_hits.first() else {
        if let Some(candidates) =
            clarification_candidates_for_intent(intent, &snapshot, constraints)?
        {
            return Ok(IntentResolveOutcome::NeedsSelection {
                candidates,
                search_status,
            });
        }
        return Ok(IntentResolveOutcome::NeedsCapability {
            candidates,
            search_status,
        });
    };
    if selected.fused_score <= 0.0 {
        if let Some(candidates) =
            clarification_candidates_for_intent(intent, &snapshot, constraints)?
        {
            return Ok(IntentResolveOutcome::NeedsSelection {
                candidates,
                search_status,
            });
        }
        return Ok(IntentResolveOutcome::NeedsCapability {
            candidates,
            search_status,
        });
    }
    let selected_has_strong_name_match = intent_strongly_matches_hit(intent, selected);
    if lacks_sufficient_intent_resolution_evidence(intent, arguments, selected) {
        if let Some(candidates) =
            clarification_candidates_for_intent(intent, &snapshot, constraints)?
        {
            return Ok(IntentResolveOutcome::NeedsSelection {
                candidates,
                search_status,
            });
        }
        return Ok(IntentResolveOutcome::NeedsCapability {
            candidates,
            search_status,
        });
    }
    let ambiguous = executable_hits.iter().skip(1).any(|candidate| {
        candidate.contract_id != selected.contract_id
            && (selected.fused_score - candidate.fused_score).abs() <= 0.05
            && (!selected_has_strong_name_match || intent_strongly_matches_hit(intent, candidate))
    });
    if ambiguous {
        return Ok(IntentResolveOutcome::NeedsSelection {
            candidates,
            search_status,
        });
    }
    let rejected_candidates = argument_rejected_candidates
        .into_iter()
        .chain(
            executable_hits
                .iter()
                .skip(1)
                .map(orchestration_candidate_summary),
        )
        .collect::<Vec<_>>();
    Ok(IntentResolveOutcome::Resolved(OrchestrationResolve {
        target_params: json!({ "functionId": selected.function_id }),
        mode: "intent_resolution".to_owned(),
        candidates,
        rejected_candidates,
        search_status,
    }))
}

pub(super) fn prepared_execute_payload(
    target_params: &Value,
    input: &OrchestratedExecuteInput,
) -> Value {
    let mut object = Map::new();
    object.insert("mode".to_owned(), json!("invoke"));
    if let Some(target) = target_params.as_object() {
        for key in [
            "functionId",
            "implementationId",
            "contractId",
            "capabilityId",
        ] {
            if let Some(value) = target.get(key) {
                object.insert(key.to_owned(), value.clone());
            }
        }
    }
    object.insert("payload".to_owned(), input.arguments.clone());
    if let Some(idempotency_key) = &input.idempotency_key {
        object.insert("idempotencyKey".to_owned(), json!(idempotency_key));
    }
    if let Some(reason) = &input.reason {
        object.insert("reason".to_owned(), json!(reason));
    }
    Value::Object(object)
}

async fn record_orchestration_inspection(
    invocation: &Invocation,
    deps: &Deps,
    target: &ResolvedCapabilityTarget,
) -> Result<Value, CapabilityError> {
    let inspection = target.entry.inspection(target.binding_decision.clone());
    let handle = inspection.inspection_handle.clone();
    let entry = target.entry.clone();
    let decision = target.binding_decision.clone();
    let trace_id = invocation.causal_context.trace_id.as_str().to_owned();
    let expected_revision = target.entry.function.revision.0;
    let expected_schema_digest = target.entry.schema_digest.clone();
    let store = deps.registry_store.clone();
    run_blocking_task("capability.execute.prepare.record_inspection", move || {
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .record_inspection(&handle, &entry, &decision)
            .map_err(registry_store_error)?;
        store
            .record_audit_event(
                "capability.execute.prepare",
                Some(&trace_id),
                json!({
                    "status": "freshness_prepared",
                    "contractId": decision.contract_id,
                    "implementationId": decision.selected_implementation,
                    "functionId": decision.selected_function_id,
                    "catalogRevision": decision.catalog_revision,
                    "schemaDigest": decision.schema_digest,
                    "inspectionHandle": handle.handle,
                }),
            )
            .map_err(registry_store_error)?;
        Ok(())
    })
    .await?;
    Ok(json!({
        "inspectionHandle": inspection.inspection_handle.handle,
        "expectedRevision": expected_revision,
        "expectedSchemaDigest": expected_schema_digest
    }))
}

fn corrected_orchestrated_request(input: &OrchestratedExecuteInput) -> Value {
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

fn orchestration_details(
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

fn orchestration_request_error_details(
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

fn correction_record(
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

fn discovery_phase_details(
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

fn discovery_message(target: &ResolvedCapabilityTarget) -> String {
    let recipe = target.entry.agent_recipe();
    let required = if recipe.required_payload.is_empty() {
        "none".to_owned()
    } else {
        recipe.required_payload.join("; ")
    };
    let optional = if recipe.optional_payload.is_empty() {
        "none".to_owned()
    } else {
        recipe.optional_payload.join("; ")
    };
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
        required,
        optional,
        target.entry.function.effect_class,
        target.entry.function.risk_level,
        trigger_clause
    )
}

fn related_triggers_metadata(entry: &CapabilityRegistryEntry) -> Value {
    entry
        .function
        .metadata
        .get("relatedTriggers")
        .cloned()
        .unwrap_or_else(|| json!([]))
}

fn related_trigger_ids(entry: &CapabilityRegistryEntry) -> Vec<String> {
    entry
        .function
        .metadata
        .get("relatedTriggers")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|trigger| trigger.get("triggerId").and_then(Value::as_str))
        .map(ToOwned::to_owned)
        .collect()
}

async fn trigger_metadata_target_guidance_for_visible_catalog(
    target_params: &Value,
    arguments: &Value,
    deps: &Deps,
    actor: &ActorContext,
) -> Option<Value> {
    let functions = deps
        .engine_host
        .discover(&FunctionQuery {
            actor: Some(actor.clone()),
            health: Some(FunctionHealth::Healthy),
            ..FunctionQuery::default()
        })
        .await;
    let snapshot = registry_snapshot_for_functions(deps, actor, functions).await;
    trigger_metadata_target_guidance_for_target_params(target_params, arguments, &snapshot)
}

fn trigger_metadata_target_guidance_for_target_params(
    target_params: &Value,
    arguments: &Value,
    snapshot: &CapabilityRegistrySnapshot,
) -> Option<Value> {
    let target_id = target_id_from_params(target_params)?;
    trigger_metadata_target_guidance_for_ids([target_id.as_str()], arguments, snapshot)
}

fn trigger_metadata_target_guidance_for_intent(
    intent: &str,
    arguments: &Value,
    snapshot: &CapabilityRegistrySnapshot,
) -> Option<Value> {
    let trigger_ids = snapshot
        .entries
        .iter()
        .flat_map(|entry| {
            entry
                .function
                .metadata
                .get("relatedTriggers")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|trigger| trigger.get("triggerId").and_then(Value::as_str))
        })
        .filter(|trigger_id| intent.contains(*trigger_id))
        .collect::<BTreeSet<_>>();
    trigger_metadata_target_guidance_for_ids(trigger_ids, arguments, snapshot)
}

fn trigger_metadata_target_guidance_for_ids<'a>(
    trigger_ids: impl IntoIterator<Item = &'a str>,
    arguments: &Value,
    snapshot: &CapabilityRegistrySnapshot,
) -> Option<Value> {
    let requested_trigger_ids = trigger_ids
        .into_iter()
        .map(str::trim)
        .filter(|trigger_id| !trigger_id.is_empty())
        .map(ToOwned::to_owned)
        .collect::<BTreeSet<_>>();
    if requested_trigger_ids.is_empty() {
        return None;
    }

    let mut candidates = Vec::new();
    let mut related_triggers = Vec::new();
    let mut suggested_calls = Vec::new();
    let mut seen_functions = BTreeSet::new();
    let mut matched_trigger_ids = BTreeSet::new();
    for entry in &snapshot.entries {
        let Some(triggers) = entry
            .function
            .metadata
            .get("relatedTriggers")
            .and_then(Value::as_array)
        else {
            continue;
        };
        for trigger in triggers {
            let Some(trigger_id) = trigger.get("triggerId").and_then(Value::as_str) else {
                continue;
            };
            if !requested_trigger_ids.contains(trigger_id) {
                continue;
            }
            matched_trigger_ids.insert(trigger_id.to_owned());
            related_triggers.push(trigger.clone());
            if seen_functions.insert(entry.function_id.clone()) {
                candidates.push(trigger_metadata_candidate_summary(entry));
                suggested_calls.push(json!({
                    "target": entry.function_id.as_str(),
                    "arguments": arguments.clone(),
                }));
            }
        }
    }

    if candidates.is_empty() {
        return None;
    }
    let requested = matched_trigger_ids.into_iter().collect::<Vec<_>>();
    Some(json!({
        "kind": "trigger_metadata_target",
        "message": "Trigger ids are metadata, not executable capability targets. Re-run execute with the related function id as target; do not use trigger ids as execute targets.",
        "requestedTriggerIds": requested,
        "relatedTriggers": related_triggers,
        "candidates": candidates,
        "suggestedCalls": suggested_calls,
    }))
}

fn target_id_from_params(target_params: &Value) -> Option<String> {
    match parse_target(target_params)? {
        CapabilityTarget::Function(id)
        | CapabilityTarget::Implementation(id)
        | CapabilityTarget::Contract(id)
        | CapabilityTarget::Capability(id) => Some(id),
    }
}

fn trigger_metadata_candidate_summary(entry: &CapabilityRegistryEntry) -> Value {
    json!({
        "kind": "implementation",
        "contractId": entry.contract_id.as_str(),
        "implementationId": entry.implementation_id.as_str(),
        "functionId": entry.function_id.as_str(),
        "score": 1.0,
        "matchedBy": "related_trigger_metadata",
        "riskLevel": format!("{:?}", entry.function.risk_level),
        "effectClass": format!("{:?}", entry.function.effect_class),
        "snippet": bounded_snippet(&entry.search_text),
    })
}

fn trigger_metadata_target_phase_details(
    resolve_mode: &str,
    selected_target: Option<Value>,
    guidance: &Value,
    search_status: Value,
) -> Value {
    let mut object = Map::new();
    object.insert("phase".to_owned(), json!("resolve"));
    object.insert("resolveMode".to_owned(), json!(resolve_mode));
    if let Some(selected_target) = selected_target {
        object.insert("selectedTarget".to_owned(), selected_target);
    }
    object.insert(
        "candidates".to_owned(),
        guidance
            .get("candidates")
            .cloned()
            .unwrap_or_else(|| json!([])),
    );
    object.insert("searchStatus".to_owned(), search_status);
    object.insert("guidance".to_owned(), guidance.clone());
    object.insert(
        "suggestedCalls".to_owned(),
        guidance
            .get("suggestedCalls")
            .cloned()
            .unwrap_or_else(|| json!([])),
    );
    object.insert(
        "docs".to_owned(),
        json!({
            "relatedTriggers": guidance
                .get("relatedTriggers")
                .cloned()
                .unwrap_or_else(|| json!([])),
        }),
    );
    Value::Object(object)
}

fn trigger_metadata_target_message(guidance: &Value) -> String {
    let trigger_ids = guidance
        .get("requestedTriggerIds")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect::<Vec<_>>();
    let function_ids = guidance
        .get("candidates")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|candidate| candidate.get("functionId").and_then(Value::as_str))
        .collect::<Vec<_>>();
    let trigger_label = if trigger_ids.is_empty() {
        "the requested trigger id".to_owned()
    } else {
        trigger_ids.join(", ")
    };
    match function_ids.as_slice() {
        [function_id] => format!(
            "Trigger ids are metadata, not executable capability targets. Re-run execute with target `{function_id}` and the same arguments; do not use trigger id `{trigger_label}` as the target. No child invocation was created."
        ),
        [] => format!(
            "Trigger ids are metadata, not executable capability targets. Re-run execute with the related function id as target; do not use trigger id `{trigger_label}` as the target. No child invocation was created."
        ),
        _ => format!(
            "Trigger ids are metadata, not executable capability targets. Re-run execute with one related function target: {}. Do not use trigger id `{trigger_label}` as the target. No child invocation was created.",
            function_ids.join(", ")
        ),
    }
}

fn redacted_prepared_request_preview(prepared_payload: &Value) -> Value {
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

fn orchestration_child_invocations(value: &Value) -> Vec<String> {
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

fn enrich_orchestration_with_result(orchestration: &mut Value, result: &Value) {
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
        json!({
            "approvalRequired": approval_required,
            "approvalCreated": approval_created,
            "approvalExecuted": approval_executed,
            "approvalReplayed": approval_replayed,
            "status": if approval_required || approval_created || approval_executed || approval_replayed {
                "approval_flow"
            } else {
                "not_required"
            },
        })
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

fn attach_orchestration_details(
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

fn attach_execute_invocation_metadata(
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

fn orchestration_result(
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

fn orchestration_status_is_error(status: &str) -> bool {
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

fn default_no_approval_decision() -> Value {
    json!({
        "approvalRequired": false,
        "approvalCreated": false,
        "approvalExecuted": false,
        "approvalReplayed": false,
        "status": "not_required",
    })
}

fn needs_selection_message(candidates: &[Value]) -> String {
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

fn capability_error_details(error: &CapabilityError) -> Value {
    json!({
        "code": error.code(),
        "message": error.to_string(),
        "details": error.details(),
    })
}

fn orchestration_failure_status(error: &CapabilityError) -> &'static str {
    match error.code() {
        "CAPABILITY_DENIED" | "INSPECTION_HANDLE_INVALID" | "STALE_CAPABILITY_REVISION" => {
            "prepare_failed"
        }
        _ => "run_failed",
    }
}

async fn record_orchestration_audit(
    deps: &Deps,
    invocation: &Invocation,
    mut diagnostics: Value,
) -> Result<(), CapabilityError> {
    let store = deps.registry_store.clone();
    let trace_id = invocation.causal_context.trace_id.as_str().to_owned();
    if let Value::Object(object) = &mut diagnostics {
        object.insert(
            "executeInvocationId".to_owned(),
            json!(invocation.id.as_str()),
        );
        object.insert(
            "primitiveInvocationId".to_owned(),
            json!(invocation.id.as_str()),
        );
    }
    run_blocking_task("capability.execute.orchestration_audit", move || {
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .record_audit_event("capability.orchestration", Some(&trace_id), diagnostics)
            .map_err(registry_store_error)?;
        Ok(())
    })
    .await
}

#[cfg(test)]
mod tests;
