//! Single execute orchestrator phases for the model-facing capability primitive.

use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use super::{
    ResolvedCapabilityTarget, actor_from_invocation, capability_primitive_target_error,
    capability_result_value, effect_class_from_str, effect_field, index_status_needs_vector_warmup,
    is_capability_primitive, registry_metadata_sync_policy, registry_snapshot_for_functions,
    registry_store_error, requires_fresh_revision_for_payload, resolve_target, risk_field,
    risk_level_from_str, run, schedule_vector_warmup, validate_target_payload,
};
use crate::domains::capability::Deps;
use crate::domains::capability::registry::{
    CapabilityRegistryEntry, CapabilityRegistrySnapshot, CapabilitySearchFilters,
    CapabilitySearchPolicy, CapabilityTarget, parse_target, requires_fresh_revision, string_field,
};
use crate::domains::capability::types::CapabilityIndexHit;
use crate::engine::resources::{
    ACTIVATION_RECORD_KIND, MODULE_CONFIG_KIND, UI_SURFACE_KIND, WORKER_PACKAGE_KIND,
};
use crate::engine::{ActorContext, FunctionDefinition, FunctionHealth, FunctionQuery, Invocation};
use crate::shared::content::CapabilityResultContent;
use crate::shared::model_capabilities::{CapabilityResult, CapabilityResultBody};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;

const MIN_UNANCHORED_INTENT_SCORE: f32 = 0.1;
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
const ARTIFACT_RESOURCE_KIND: &str = "artifact";
const MATERIALIZED_FILE_RESOURCE_KIND: &str = "materialized_file";

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
            }
        }
    };

    input.target_params = Some(resolve.target_params.clone());
    let target = match resolve_target(&resolve.target_params, deps, &actor).await {
        Ok(target) => target,
        Err(error @ CapabilityError::NotFound { .. }) => {
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
struct OrchestrationResolve {
    target_params: Value,
    mode: String,
    candidates: Vec<Value>,
    rejected_candidates: Vec<Value>,
    search_status: Value,
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

    for key in [
        "mode",
        "inspectionHandle",
        "inspection_handle",
        "expectedRevision",
        "expectedSchemaDigest",
        "expected_schema_digest",
    ] {
        if object.remove(key).is_some() {
            corrections.push(correction_record(
                "nested_wrapper_field_removed",
                format!("removed wrapper field {key} from arguments"),
                1.0,
            ));
        }
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

pub(super) fn normalize_target_arguments(
    function: &FunctionDefinition,
    arguments: &mut Value,
    corrections: &mut Vec<Value>,
) {
    normalize_target_specific_arguments(function, arguments, corrections);
    normalize_schema_property_name_aliases(function, arguments, corrections);
}

pub(super) fn normalize_intent_target_arguments(
    function: &FunctionDefinition,
    intent: Option<&str>,
    arguments: &mut Value,
    corrections: &mut Vec<Value>,
) {
    let Some(intent) = intent else {
        return;
    };
    let Some(object) = arguments.as_object_mut() else {
        return;
    };

    match function.id.as_str() {
        "filesystem::read_file" => {
            if !object.contains_key("path") {
                let requests = intent_file_read_requests(intent);
                if requests.len() == 1 {
                    let request = &requests[0];
                    object.insert("path".to_owned(), json!(request.path));
                    apply_intent_line_bounds(
                        object,
                        request.start_line,
                        request.end_line,
                        corrections,
                    );
                    corrections.push(correction_record(
                        "intent_file_path_to_target_argument",
                        "bound safe relative file path from execute intent into filesystem::read_file arguments",
                        0.92,
                    ));
                }
            }

            if object.contains_key("path")
                && let Some((start_line, end_line)) = intent_line_bounds(intent)
            {
                apply_intent_line_bounds(object, Some(start_line), Some(end_line), corrections);
            }
        }
        "resource::list" => {
            if !object.contains_key("kind") {
                let requests = intent_resource_kind_requests(intent);
                if requests.len() == 1 {
                    object.insert("kind".to_owned(), json!(requests[0].kind));
                    corrections.push(correction_record(
                        "intent_resource_kind_to_target_argument",
                        format!(
                            "bound resource kind {} from execute intent into resource::list arguments",
                            requests[0].kind
                        ),
                        0.95,
                    ));
                }
            }
        }
        _ => {}
    }
}

pub(super) fn normalize_contextual_target_arguments(
    function: &FunctionDefinition,
    invocation: &Invocation,
    arguments: &mut Value,
    corrections: &mut Vec<Value>,
) {
    let Some(schema) = function.request_schema.as_ref() else {
        return;
    };
    let Some(object) = arguments.as_object_mut() else {
        return;
    };

    let required = schema_required_property_names(schema);
    let properties = schema_property_names(schema);
    if required.contains("sessionId") && !object.contains_key("sessionId") {
        if let Some(session_id) = invocation
            .causal_context
            .session_id
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            object.insert("sessionId".to_owned(), json!(session_id));
            corrections.push(correction_record(
                "runtime_session_id_to_target_argument",
                format!(
                    "bound trusted current sessionId into {} arguments",
                    function.id.as_str()
                ),
                1.0,
            ));
        }
    }

    if function.id.as_str() == "worktree::is_git_repo"
        && required.contains("path")
        && !object.contains_key("path")
    {
        if let Some(working_directory) = invocation
            .causal_context
            .runtime_metadata(crate::engine::invocation::RUNTIME_METADATA_WORKING_DIRECTORY)
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            object.insert("path".to_owned(), json!(working_directory));
            corrections.push(correction_record(
                "runtime_working_directory_to_target_path",
                "bound trusted current session working directory into worktree::is_git_repo path",
                1.0,
            ));
        }
    }

    if required.contains("sessionId")
        && !properties.contains("path")
        && object
            .get("path")
            .and_then(Value::as_str)
            .is_some_and(|path| path_is_current_session_worktree_hint(invocation, path))
    {
        object.remove("path");
        corrections.push(correction_record(
            "current_worktree_path_hint_removed",
            format!(
                "removed path because {} is scoped by trusted current sessionId",
                function.id.as_str()
            ),
            1.0,
        ));
    }
}

pub(super) fn normalize_target_specific_arguments(
    function: &FunctionDefinition,
    arguments: &mut Value,
    corrections: &mut Vec<Value>,
) {
    match function.id.as_str() {
        "process::run" => normalize_process_run_arguments(arguments, corrections),
        "filesystem::list_dir" => normalize_filesystem_list_dir_arguments(arguments, corrections),
        "web::search" => normalize_web_search_arguments(arguments, corrections),
        "filesystem::apply_patch" => {
            normalize_filesystem_apply_patch_arguments(arguments, corrections)
        }
        _ => {}
    }
}

fn normalize_schema_property_name_aliases(
    function: &FunctionDefinition,
    arguments: &mut Value,
    corrections: &mut Vec<Value>,
) {
    let Some(schema) = function.request_schema.as_ref() else {
        return;
    };
    let mut renames = Vec::new();
    normalize_schema_property_names_for_value(schema, arguments, &mut renames);
    if renames.is_empty() {
        return;
    }
    corrections.push(correction_record(
        "schema_property_name_alias",
        format!(
            "normalized target argument key casing to {} schema property names: {}",
            function.id.as_str(),
            renames.join(", ")
        ),
        1.0,
    ));
}

fn normalize_schema_property_names_for_value(
    schema: &Value,
    value: &mut Value,
    renames: &mut Vec<String>,
) {
    if let (Some(properties), Some(object)) = (
        schema.get("properties").and_then(Value::as_object),
        value.as_object_mut(),
    ) {
        normalize_object_property_names(properties, object, renames);
        for (property, property_schema) in properties {
            if let Some(child) = object.get_mut(property) {
                normalize_schema_property_names_for_value(property_schema, child, renames);
            }
        }
    }

    if let (Some(items_schema), Some(array)) = (schema.get("items"), value.as_array_mut()) {
        for item in array {
            normalize_schema_property_names_for_value(items_schema, item, renames);
        }
    }
}

fn normalize_object_property_names(
    properties: &Map<String, Value>,
    object: &mut Map<String, Value>,
    renames: &mut Vec<String>,
) {
    let mut normalized_to_canonical: BTreeMap<String, Option<String>> = BTreeMap::new();
    for property in properties.keys() {
        let normalized = normalize_schema_property_key(property);
        normalized_to_canonical
            .entry(normalized)
            .and_modify(|existing| *existing = None)
            .or_insert_with(|| Some(property.clone()));
    }

    let keys = object.keys().cloned().collect::<Vec<_>>();
    for key in keys {
        if properties.contains_key(&key) {
            continue;
        }
        let normalized = normalize_schema_property_key(&key);
        let Some(Some(canonical)) = normalized_to_canonical.get(&normalized) else {
            continue;
        };
        if object.contains_key(canonical) {
            continue;
        }
        if let Some(value) = object.remove(&key) {
            object.insert(canonical.clone(), value);
            renames.push(format!("{key}->{canonical}"));
        }
    }
}

fn normalize_schema_property_key(key: &str) -> String {
    key.chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .flat_map(|ch| ch.to_lowercase())
        .collect()
}

fn path_is_current_session_worktree_hint(invocation: &Invocation, path: &str) -> bool {
    let candidate = path.trim();
    if candidate == "." {
        return true;
    }
    let Some(working_directory) = invocation
        .causal_context
        .runtime_metadata(crate::engine::invocation::RUNTIME_METADATA_WORKING_DIRECTORY)
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return false;
    };
    let candidate = lexical_clean_path(Path::new(candidate));
    let working_directory = lexical_clean_path(Path::new(working_directory));
    candidate == working_directory
}

fn lexical_clean_path(path: &Path) -> PathBuf {
    let mut cleaned = PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                cleaned.pop();
            }
            other => cleaned.push(other.as_os_str()),
        }
    }
    cleaned
}

pub(super) fn normalize_target_idempotency_argument(
    function: &FunctionDefinition,
    arguments: &mut Value,
    wrapper_idempotency_key: Option<&str>,
    corrections: &mut Vec<Value>,
) {
    let Some(idempotency_key) = wrapper_idempotency_key
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return;
    };
    let Some(object) = arguments.as_object_mut() else {
        return;
    };
    if object.contains_key("idempotencyKey") || object.contains_key("idempotency_key") {
        return;
    }
    let Some(schema) = function.request_schema.as_ref() else {
        return;
    };
    if !schema_property_names(schema).contains("idempotencyKey") {
        return;
    }

    object.insert("idempotencyKey".to_owned(), json!(idempotency_key));
    corrections.push(correction_record(
        "wrapper_idempotency_key_to_target_argument",
        format!(
            "copied execute.idempotencyKey into {} arguments because the selected target schema requires idempotencyKey",
            function.id.as_str()
        ),
        1.0,
    ));
}

fn normalize_filesystem_list_dir_arguments(arguments: &mut Value, corrections: &mut Vec<Value>) {
    let Some(object) = arguments.as_object_mut() else {
        return;
    };
    if object.contains_key("maxEntries") {
        if !object.contains_key("maxResults")
            && let Some(value) = object.remove("maxEntries")
        {
            object.insert("maxResults".to_owned(), value);
        } else {
            object.remove("maxEntries");
        }
        corrections.push(correction_record(
            "filesystem_list_dir_max_entries_alias",
            "normalized maxEntries to maxResults; filesystem::list_dir uses maxResults to bound directory entries",
            1.0,
        ));
    }
}

fn normalize_web_search_arguments(arguments: &mut Value, corrections: &mut Vec<Value>) {
    let Some(object) = arguments.as_object_mut() else {
        return;
    };
    let alias = ["maxResults", "limit", "numResults"]
        .into_iter()
        .find(|alias| object.contains_key(*alias));
    let Some(alias) = alias else {
        return;
    };
    if !object.contains_key("count")
        && let Some(value) = object.remove(alias)
    {
        object.insert("count".to_owned(), value);
    } else {
        object.remove(alias);
    }
    for other_alias in ["maxResults", "limit", "numResults"] {
        if other_alias != alias {
            object.remove(other_alias);
        }
    }
    corrections.push(correction_record(
        "web_search_count_alias",
        "normalized web search result-limit alias to count; web::search uses count to bound ranked results",
        1.0,
    ));
}

fn normalize_process_run_arguments(arguments: &mut Value, corrections: &mut Vec<Value>) {
    normalize_process_expected_output_aliases(arguments, corrections);
    let Some(outputs) = arguments
        .get_mut("expectedOutputs")
        .and_then(Value::as_array_mut)
    else {
        return;
    };
    let mut removed = false;
    for output in outputs.iter_mut() {
        if let Some(path) = output
            .as_str()
            .map(str::trim)
            .filter(|path| !path.is_empty())
        {
            *output = json!({ "path": path });
            removed = true;
            continue;
        }
        if let Some(object) = output.as_object_mut() {
            removed |= object.remove("kind").is_some();
            removed |= object.remove("role").is_some();
            removed |= object.remove("type").is_some();
        }
    }
    if removed {
        corrections.push(correction_record(
            "process_expected_outputs_shape",
            "normalized expectedOutputs entries; process::run expects objects with path and optional targetPath only",
            1.0,
        ));
    }
}

fn normalize_filesystem_apply_patch_arguments(arguments: &mut Value, corrections: &mut Vec<Value>) {
    let Some(object) = arguments.as_object_mut() else {
        return;
    };
    if !object.contains_key("oldString")
        && object
            .get("newString")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.is_empty())
    {
        object.insert("oldString".to_owned(), Value::String(String::new()));
        corrections.push(correction_record(
            "filesystem_apply_patch_append_shape",
            "set oldString to an empty string so filesystem::apply_patch appends newString exactly",
            1.0,
        ));
    }
}

fn normalize_process_expected_output_aliases(arguments: &mut Value, corrections: &mut Vec<Value>) {
    let Some(object) = arguments.as_object_mut() else {
        return;
    };
    if object.get("expectedOutputs").is_some() {
        return;
    }
    let Some(alias) = object
        .remove("expectedOutputPaths")
        .or_else(|| object.remove("expectedOutputPath"))
        .or_else(|| object.remove("outputPaths"))
        .or_else(|| object.remove("outputPath"))
    else {
        return;
    };
    let outputs = match alias {
        Value::String(path) => vec![json!({ "path": path })],
        Value::Array(values) => values
            .into_iter()
            .filter_map(|value| match value {
                Value::String(path) => Some(json!({ "path": path })),
                Value::Object(mut object) => {
                    if !object.contains_key("path")
                        && let Some(path) = object.remove("targetPath")
                    {
                        object.insert("path".to_owned(), path);
                    }
                    Some(Value::Object(object))
                }
                _ => None,
            })
            .collect::<Vec<_>>(),
        Value::Object(object) => vec![Value::Object(object)],
        _ => Vec::new(),
    };
    if outputs.is_empty() {
        return;
    }
    object.insert("expectedOutputs".to_owned(), Value::Array(outputs));
    corrections.push(correction_record(
        "process_expected_outputs_alias",
        "converted expected output path alias into expectedOutputs",
        1.0,
    ));
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

pub(super) fn intent_strongly_matches_hit(intent: &str, hit: &CapabilityIndexHit) -> bool {
    let normalized_intent = normalized_intent_words(intent);
    let Some((namespace, function_name)) = hit.contract_id.split_once("::") else {
        return false;
    };
    let mut tokens = normalized_identifier_words(function_name);
    if tokens.is_empty() {
        return false;
    }
    let namespace_tokens = normalized_identifier_words(namespace);
    if namespace_tokens
        .iter()
        .any(|token| normalized_intent.contains(token))
    {
        tokens.extend(namespace_tokens);
    }
    tokens
        .iter()
        .filter(|token| token.len() > 1)
        .all(|token| normalized_intent.contains(token))
}

fn validate_orchestration_constraint_keys(constraints: &Value) -> Result<(), CapabilityError> {
    let Some(object) = constraints.as_object() else {
        return Err(CapabilityError::InvalidParams {
            message: "execute.constraints must be an object".to_owned(),
        });
    };
    for key in object.keys() {
        if !matches!(
            key.as_str(),
            "riskMax" | "effect" | "allowedContracts" | "allowedNamespaces"
        ) {
            return Err(CapabilityError::InvalidParams {
                message: format!(
                    "Unsupported execute.constraints field '{key}'. Supported fields: riskMax, effect, allowedContracts, allowedNamespaces"
                ),
            });
        }
    }
    Ok(())
}

pub(super) fn validate_orchestration_constraint_shape(
    constraints: &Value,
) -> Result<(), CapabilityError> {
    validate_orchestration_constraint_keys(constraints)?;
    let _ = risk_field(constraints, "riskMax")?;
    let _ = effect_field(constraints, "effect")?;
    let _ = optional_string_array_field(constraints, "allowedContracts")?;
    let _ = optional_string_array_field(constraints, "allowedNamespaces")?;
    Ok(())
}

pub(super) fn validate_orchestration_constraints(
    constraints: &Value,
    entry: &CapabilityRegistryEntry,
) -> Result<(), CapabilityError> {
    validate_orchestration_constraint_shape(constraints)?;
    if let Some(max_risk) = risk_field(constraints, "riskMax")?
        && entry.function.risk_level > max_risk
    {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "selected target {} has risk {:?}, above constraint riskMax {:?}",
                entry.contract_id, entry.function.risk_level, max_risk
            ),
        });
    }
    if let Some(effect) = effect_field(constraints, "effect")?
        && entry.function.effect_class != effect
    {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "selected target {} has effect {:?}, not requested effect {:?}",
                entry.contract_id, entry.function.effect_class, effect
            ),
        });
    }
    let allowed_contracts = optional_string_array_field(constraints, "allowedContracts")?;
    if let Some(contracts) = allowed_contracts
        && !contracts
            .iter()
            .any(|contract| contract == &entry.contract_id)
    {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "selected target {} is outside execute.constraints.allowedContracts",
                entry.contract_id
            ),
        });
    }
    let allowed_namespaces = optional_string_array_field(constraints, "allowedNamespaces")?;
    if let Some(namespaces) = allowed_namespaces {
        let namespace = entry
            .contract_id
            .split_once("::")
            .map(|(namespace, _)| namespace)
            .unwrap_or(entry.contract_id.as_str());
        if !namespaces.iter().any(|allowed| allowed == namespace) {
            return Err(CapabilityError::InvalidParams {
                message: format!(
                    "selected target {} is outside execute.constraints.allowedNamespaces",
                    entry.contract_id
                ),
            });
        }
    }
    Ok(())
}

pub(super) fn orchestration_constraints_allow_hit(
    constraints: &Value,
    hit: &CapabilityIndexHit,
) -> Result<bool, CapabilityError> {
    validate_orchestration_constraint_shape(constraints)?;
    if let Some(max_risk) = risk_field(constraints, "riskMax")? {
        let hit_risk = risk_level_from_str(&hit.risk_level, "candidate riskLevel")?;
        if hit_risk > max_risk {
            return Ok(false);
        }
    }
    if let Some(effect) = effect_field(constraints, "effect")? {
        let hit_effect = effect_class_from_str(&hit.effect_class, "candidate effectClass")?;
        if hit_effect != effect {
            return Ok(false);
        }
    }
    if let Some(contracts) = optional_string_array_field(constraints, "allowedContracts")?
        && !contracts
            .iter()
            .any(|contract| contract == &hit.contract_id)
    {
        return Ok(false);
    }
    if let Some(namespaces) = optional_string_array_field(constraints, "allowedNamespaces")? {
        let namespace = hit
            .contract_id
            .split_once("::")
            .map(|(namespace, _)| namespace)
            .unwrap_or(hit.contract_id.as_str());
        if !namespaces.iter().any(|allowed| allowed == namespace) {
            return Ok(false);
        }
    }
    Ok(true)
}

fn optional_string_array_field(
    value: &Value,
    key: &str,
) -> Result<Option<Vec<String>>, CapabilityError> {
    let Some(raw) = value.get(key) else {
        return Ok(None);
    };
    let Some(values) = raw.as_array() else {
        return Err(CapabilityError::InvalidParams {
            message: format!("execute.constraints.{key} must be an array of strings"),
        });
    };
    let mut strings = Vec::new();
    for item in values {
        let Some(item) = item.as_str().map(str::trim).filter(|item| !item.is_empty()) else {
            return Err(CapabilityError::InvalidParams {
                message: format!("execute.constraints.{key} must contain only non-empty strings"),
            });
        };
        strings.push(item.to_owned());
    }
    Ok(Some(strings))
}

fn normalized_identifier_words(value: &str) -> Vec<String> {
    value
        .split(|character: char| !character.is_ascii_alphanumeric())
        .filter_map(|token| {
            let token = token.trim().to_ascii_lowercase();
            (!token.is_empty()).then_some(token)
        })
        .collect()
}

fn normalized_intent_words(value: &str) -> std::collections::BTreeSet<String> {
    normalized_identifier_words(value).into_iter().collect()
}

fn positive_intent_words(value: &str) -> std::collections::BTreeSet<String> {
    value
        .split(|character| matches!(character, '.' | ';' | '\n' | ','))
        .flat_map(|clause| {
            let words = normalized_identifier_words(clause);
            if negative_guard_clause(&words) {
                Vec::new()
            } else {
                words
            }
        })
        .collect()
}

fn negative_guard_clause(words: &[String]) -> bool {
    let Some(first) = words.first().map(String::as_str) else {
        return false;
    };
    matches!(first, "avoid" | "never" | "without" | "no" | "dont")
        || (first == "don" && words.get(1).map(String::as_str) == Some("t"))
        || (first == "do" && words.get(1).map(String::as_str) == Some("not"))
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

pub(super) fn deterministic_intent_route(
    intent: &str,
    arguments: &Value,
    snapshot: &CapabilityRegistrySnapshot,
    constraints: &Value,
) -> Result<Option<CapabilityIndexHit>, CapabilityError> {
    if intent_requests_worktree_diff(intent) {
        return deterministic_hit_for_function(
            "worktree::get_diff",
            snapshot,
            constraints,
            "deterministic_worktree_diff",
        );
    }
    if let Some(hit) = deterministic_operator_status_route(intent, snapshot, constraints)? {
        return Ok(Some(hit));
    }
    if intent_requests_resource_inventory(intent, arguments) {
        return deterministic_hit_for_function(
            "resource::list",
            snapshot,
            constraints,
            "deterministic_resource_inventory",
        );
    }
    if intent_requests_filesystem_read(intent, arguments) {
        return deterministic_hit_for_function(
            "filesystem::read_file",
            snapshot,
            constraints,
            "deterministic_path_read",
        );
    }
    Ok(None)
}

pub(super) fn apply_deterministic_intent_route(
    intent: &str,
    arguments: &Value,
    snapshot: &CapabilityRegistrySnapshot,
    constraints: &Value,
    executable_hits: &mut Vec<CapabilityIndexHit>,
) -> Result<(), CapabilityError> {
    if let Some(routed) = deterministic_intent_route(intent, arguments, snapshot, constraints)? {
        executable_hits.retain(|hit| hit.function_id != routed.function_id);
        executable_hits.insert(0, routed);
    }
    Ok(())
}

pub(super) fn clarification_candidates_for_intent(
    intent: &str,
    snapshot: &CapabilityRegistrySnapshot,
    constraints: &Value,
) -> Result<Option<Vec<Value>>, CapabilityError> {
    let namespaces = namespaces_referenced_by_intent(intent, snapshot);
    if namespaces.is_empty() {
        return Ok(None);
    }

    let mut hits = Vec::new();
    for entry in &snapshot.entries {
        if entry.function_id == "capability::execute" {
            continue;
        }
        let Some((namespace, _)) = entry.function_id.split_once("::") else {
            continue;
        };
        if !namespaces.contains(namespace) {
            continue;
        }
        let hit = orchestration_hit_from_entry(entry, "namespace_clarification", 0.05);
        if orchestration_constraints_allow_hit(constraints, &hit)? {
            hits.push(hit);
        }
    }

    if hits.is_empty() {
        return Ok(None);
    }
    hits.sort_by(|left, right| {
        left.contract_id
            .cmp(&right.contract_id)
            .then_with(|| left.function_id.cmp(&right.function_id))
    });
    hits.truncate(8);
    Ok(Some(
        hits.iter()
            .map(orchestration_candidate_summary)
            .collect::<Vec<_>>(),
    ))
}

fn namespaces_referenced_by_intent(
    intent: &str,
    snapshot: &CapabilityRegistrySnapshot,
) -> BTreeSet<String> {
    let words = normalized_intent_words(intent);
    if words.is_empty() {
        return BTreeSet::new();
    }
    let mut namespaces = BTreeSet::new();
    for entry in &snapshot.entries {
        let Some((namespace, _)) = entry.function_id.split_once("::") else {
            continue;
        };
        if namespace_intent_match(namespace, &words) {
            namespaces.insert(namespace.to_owned());
        }
    }
    namespaces
}

fn namespace_intent_match(namespace: &str, words: &BTreeSet<String>) -> bool {
    let namespace_words = normalized_identifier_words(namespace);
    namespace_words
        .iter()
        .any(|word| words.contains(word) || words.contains(&singular_word(word)))
        || namespace_aliases(namespace)
            .iter()
            .any(|alias| words.contains(*alias))
}

fn singular_word(word: &str) -> String {
    word.strip_suffix('s').unwrap_or(word).to_owned()
}

fn namespace_aliases(namespace: &str) -> &'static [&'static str] {
    match namespace {
        "filesystem" => &[
            "file",
            "files",
            "folder",
            "folders",
            "directory",
            "directories",
        ],
        "process" => &["command", "commands", "shell", "terminal"],
        "prompt_library" => &["prompt", "prompts", "snippet", "snippets", "history"],
        "resource" => &["resource", "resources", "artifact", "artifacts"],
        "worker" => &["worker", "workers"],
        "grant" => &["grant", "grants", "permission", "permissions"],
        "approval" => &["approval", "approvals"],
        "module" => &["module", "modules", "package", "packages"],
        "settings" => &[
            "setting",
            "settings",
            "preference",
            "preferences",
            "profile",
        ],
        "model" => &["model", "models", "provider", "providers"],
        "logs" => &["log", "logs", "event", "events"],
        "observability" => &["metric", "metrics", "trace", "traces", "span", "spans"],
        _ => &[],
    }
}

pub(super) fn apply_argument_schema_fit_filter(
    arguments: &Value,
    snapshot: &CapabilityRegistrySnapshot,
    executable_hits: &mut Vec<CapabilityIndexHit>,
) -> Vec<Value> {
    if arguments.as_object().is_none_or(Map::is_empty) {
        return Vec::new();
    }

    let original_hits = std::mem::take(executable_hits);
    let mut compatible = Vec::new();
    let mut missing_required = Vec::new();
    let mut rejected = Vec::new();

    for hit in &original_hits {
        match argument_schema_fit_for_hit(hit, arguments, snapshot) {
            ArgumentSchemaFit::Compatible => compatible.push(hit.clone()),
            ArgumentSchemaFit::MissingRequired => missing_required.push(hit.clone()),
            ArgumentSchemaFit::Incompatible(reason) => {
                rejected.push(rejected_candidate_summary(
                    hit,
                    "argument_schema_mismatch",
                    reason,
                ));
            }
        }
    }

    if !compatible.is_empty() {
        for hit in &missing_required {
            rejected.push(rejected_candidate_summary(
                hit,
                "argument_missing_required",
                "candidate is missing required arguments while another candidate accepts the supplied arguments",
            ));
        }
        *executable_hits = compatible;
        return rejected;
    }

    if !missing_required.is_empty() {
        *executable_hits = missing_required;
        return rejected;
    }

    *executable_hits = original_hits;
    Vec::new()
}

pub(super) fn promote_argument_schema_fit_candidates(
    arguments: &Value,
    snapshot: &CapabilityRegistrySnapshot,
    constraints: &Value,
    executable_hits: &mut Vec<CapabilityIndexHit>,
) -> Result<(), CapabilityError> {
    if arguments.as_object().is_none_or(Map::is_empty) {
        return Ok(());
    }

    let mut promoted = Vec::new();
    for entry in &snapshot.entries {
        if entry.function_id == "capability::execute"
            || executable_hits
                .iter()
                .any(|hit| hit.function_id == entry.function_id)
        {
            continue;
        }
        let hit = orchestration_hit_from_entry(entry, "argument_schema_fit", 0.0);
        if !orchestration_constraints_allow_hit(constraints, &hit)? {
            continue;
        }
        let Some(score) = argument_schema_promotion_score(entry, arguments) else {
            continue;
        };
        promoted.push(orchestration_hit_from_entry(
            entry,
            "argument_schema_fit",
            score,
        ));
    }

    if promoted.is_empty() {
        return Ok(());
    }

    executable_hits.extend(promoted);
    executable_hits.sort_by(|left, right| {
        right
            .fused_score
            .partial_cmp(&left.fused_score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| left.function_id.cmp(&right.function_id))
    });
    executable_hits.dedup_by(|left, right| left.function_id == right.function_id);
    Ok(())
}

fn argument_schema_promotion_score(
    entry: &CapabilityRegistryEntry,
    arguments: &Value,
) -> Option<f32> {
    let mut normalized_arguments = arguments.clone();
    let mut ignored_corrections = Vec::new();
    normalize_target_arguments(
        &entry.function,
        &mut normalized_arguments,
        &mut ignored_corrections,
    );
    let supplied = normalized_arguments
        .as_object()
        .filter(|object| !object.is_empty())?;
    if validate_target_payload(entry, &normalized_arguments).is_err() {
        return None;
    }

    let properties = schema_property_names(entry.function.request_schema.as_ref()?);
    if properties.is_empty() {
        return None;
    }
    let matched = supplied
        .keys()
        .filter(|key| properties.contains(key.as_str()))
        .count();
    if matched == 0 {
        return None;
    }
    let required = schema_required_property_names(entry.function.request_schema.as_ref()?);
    let required_matched = required
        .iter()
        .filter(|key| supplied.contains_key(**key))
        .count();
    Some(50.0 + (matched as f32) + (required_matched as f32 * 2.0))
}

fn schema_property_names(schema: &Value) -> BTreeSet<&str> {
    schema
        .get("properties")
        .and_then(Value::as_object)
        .map(|properties| properties.keys().map(String::as_str).collect())
        .unwrap_or_default()
}

fn schema_required_property_names(schema: &Value) -> BTreeSet<&str> {
    schema
        .get("required")
        .and_then(Value::as_array)
        .map(|required| required.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default()
}

enum ArgumentSchemaFit {
    Compatible,
    MissingRequired,
    Incompatible(String),
}

fn argument_schema_fit_for_hit(
    hit: &CapabilityIndexHit,
    arguments: &Value,
    snapshot: &CapabilityRegistrySnapshot,
) -> ArgumentSchemaFit {
    let Some(entry) = snapshot
        .entries
        .iter()
        .find(|entry| entry.function_id == hit.function_id)
    else {
        return ArgumentSchemaFit::Incompatible(
            "candidate is not present in the live registry snapshot".to_owned(),
        );
    };
    let mut normalized_arguments = arguments.clone();
    let mut ignored_corrections = Vec::new();
    normalize_target_arguments(
        &entry.function,
        &mut normalized_arguments,
        &mut ignored_corrections,
    );
    match validate_target_payload(entry, &normalized_arguments) {
        Ok(()) => ArgumentSchemaFit::Compatible,
        Err(error) if run::is_missing_required_argument_error(&error) => {
            ArgumentSchemaFit::MissingRequired
        }
        Err(error) => ArgumentSchemaFit::Incompatible(error.to_string()),
    }
}

fn rejected_candidate_summary(
    hit: &CapabilityIndexHit,
    reason: &str,
    message: impl Into<String>,
) -> Value {
    let mut summary = orchestration_candidate_summary(hit);
    if let Some(object) = summary.as_object_mut() {
        object.insert("rejectionReason".to_owned(), json!(reason));
        object.insert("rejectionMessage".to_owned(), json!(message.into()));
    }
    summary
}

fn intent_requests_filesystem_read(intent: &str, arguments: &Value) -> bool {
    let words = normalized_intent_words(intent);
    let asks_for_read = ["read", "open", "cat", "content", "line", "lines"]
        .iter()
        .any(|word| words.contains(*word));
    let asks_for_write = [
        "write",
        "edit",
        "modify",
        "delete",
        "remove",
        "create",
        "overwrite",
        "patch",
    ]
    .iter()
    .any(|word| words.contains(*word));
    if !asks_for_read || asks_for_write {
        return false;
    }
    arguments
        .get("path")
        .and_then(Value::as_str)
        .is_some_and(|path| !path.trim().is_empty())
        || !intent_file_read_requests(intent).is_empty()
}

fn intent_requests_resource_inventory(intent: &str, arguments: &Value) -> bool {
    arguments
        .get("kind")
        .and_then(Value::as_str)
        .is_some_and(|kind| !kind.trim().is_empty())
        || !intent_resource_kind_requests(intent).is_empty()
}

fn deterministic_operator_status_route(
    intent: &str,
    snapshot: &CapabilityRegistrySnapshot,
    constraints: &Value,
) -> Result<Option<CapabilityIndexHit>, CapabilityError> {
    for function_id in intent_operator_status_targets(intent) {
        if let Some(hit) = deterministic_hit_for_function(
            function_id,
            snapshot,
            constraints,
            "deterministic_operator_status",
        )? {
            return Ok(Some(hit));
        }
    }
    Ok(None)
}

fn intent_operator_status_targets(intent: &str) -> Vec<&'static str> {
    let words = positive_intent_words(intent);
    if words.is_empty() {
        return Vec::new();
    }
    let status_words = [
        "current",
        "status",
        "summary",
        "available",
        "list",
        "inspect",
        "report",
        "count",
        "recent",
    ];
    if !status_words.iter().any(|word| words.contains(*word)) {
        return Vec::new();
    }

    let mut targets = Vec::new();
    if ["model", "models", "provider", "providers"]
        .iter()
        .any(|word| words.contains(*word))
    {
        targets.push("model::list");
    }
    if [
        "setting",
        "settings",
        "preference",
        "preferences",
        "profile",
        "configuration",
        "config",
    ]
    .iter()
    .any(|word| words.contains(*word))
    {
        targets.push("settings::get");
    }
    if ["log", "logs"].iter().any(|word| words.contains(*word)) {
        targets.push("logs::recent");
    }
    if [
        "metric",
        "metrics",
        "server",
        "engine",
        "invocation",
        "invocations",
        "trace",
        "traces",
    ]
    .iter()
    .any(|word| words.contains(*word))
        || (words.contains("event") || words.contains("events")) && words.contains("count")
    {
        targets.push("observability::metrics_snapshot");
    }
    targets
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct IntentResourceKindRequest {
    kind: &'static str,
}

fn intent_resource_kind_requests(intent: &str) -> Vec<IntentResourceKindRequest> {
    let normalized = intent
        .to_ascii_lowercase()
        .replace(['_', '-'], " ")
        .replace('\n', " ");
    let words = normalized_intent_words(intent);
    let asks_for_inventory = [
        "resource",
        "resources",
        "record",
        "records",
        "existing",
        "current",
        "list",
        "inventory",
        "whether",
        "present",
        "available",
    ]
    .iter()
    .any(|word| words.contains(*word));
    if !asks_for_inventory {
        return Vec::new();
    }

    let mut requests = Vec::new();
    let mut seen = BTreeSet::new();
    for (kind, phrases) in [
        (
            WORKER_PACKAGE_KIND,
            &[
                "worker package",
                "worker packages",
                "module package",
                "module packages",
                "package resource",
                "package resources",
                "package record",
                "package records",
            ][..],
        ),
        (
            ACTIVATION_RECORD_KIND,
            &[
                "activation record",
                "activation records",
                "module activation",
                "module activations",
                "activation resource",
                "activation resources",
            ][..],
        ),
        (
            MODULE_CONFIG_KIND,
            &[
                "module config",
                "module configs",
                "module configuration",
                "module configurations",
                "config resource",
                "configuration resource",
            ][..],
        ),
        (UI_SURFACE_KIND, &["ui surface", "ui surfaces"][..]),
        (
            MATERIALIZED_FILE_RESOURCE_KIND,
            &["materialized file", "materialized files"][..],
        ),
        (ARTIFACT_RESOURCE_KIND, &["artifact", "artifacts"][..]),
    ] {
        if phrases.iter().any(|phrase| normalized.contains(phrase)) && seen.insert(kind) {
            requests.push(IntentResourceKindRequest { kind });
        }
    }
    requests
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct IntentFileReadRequest {
    path: String,
    start_line: Option<u64>,
    end_line: Option<u64>,
}

fn decomposition_phase_details(
    resolve: &OrchestrationResolve,
    target: &ResolvedCapabilityTarget,
    intent: Option<&str>,
    arguments: &Value,
) -> Option<Value> {
    if target.entry.function.id.as_str() == "resource::list" {
        if arguments
            .get("kind")
            .and_then(Value::as_str)
            .is_some_and(|kind| !kind.trim().is_empty())
        {
            return None;
        }
        let requests = intent_resource_kind_requests(intent?);
        if requests.len() <= 1 {
            return None;
        }
        let suggested_calls = requests
            .iter()
            .map(|request| {
                json!({
                    "intent": format!("List {} resources", request.kind),
                    "target": "resource::list",
                    "arguments": { "kind": request.kind }
                })
            })
            .collect::<Vec<_>>();
        return Some(json!({
            "phase": "prepare",
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
            },
            "decomposition": {
                "reason": "multiple_resource_kinds_for_single_inventory_request",
                "targetCount": requests.len(),
            },
            "guidance": {
                "kind": "one_resource_kind_per_execute",
                "message": "resource inventory requests should list one resource kind per execute call so the result stays bounded and auditable. The suggested calls are guidance, not automatic retries.",
                "suggestedCalls": suggested_calls,
            },
            "suggestedCalls": suggested_calls,
        }));
    }
    if target.entry.function.id.as_str() != "filesystem::read_file" {
        return None;
    }
    if arguments
        .get("path")
        .and_then(Value::as_str)
        .is_some_and(|path| !path.trim().is_empty())
    {
        return None;
    }
    let requests = intent_file_read_requests(intent?);
    if requests.len() <= 1 {
        return None;
    }
    let suggested_calls = requests
        .iter()
        .map(|request| {
            let mut arguments = json!({ "path": request.path });
            if let Some(object) = arguments.as_object_mut() {
                if let Some(start_line) = request.start_line {
                    object.insert("startLine".to_owned(), json!(start_line));
                }
                if let Some(end_line) = request.end_line {
                    object.insert("endLine".to_owned(), json!(end_line));
                }
            }
            json!({
                "intent": format!("Read {}", request.path),
                "target": "filesystem::read_file",
                "arguments": arguments
            })
        })
        .collect::<Vec<_>>();
    Some(json!({
        "phase": "prepare",
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
        },
        "decomposition": {
            "reason": "multiple_files_for_single_target",
            "targetCount": requests.len(),
        },
        "guidance": {
            "kind": "one_target_per_execute",
            "message": "filesystem::read_file reads one path per execute call. The suggested calls are guidance, not automatic retries. If the user still wants the reads performed, call execute separately for each suggested request so every child invocation is explicit and auditable; if the user asked only to report the decomposition, stop and report this result.",
            "suggestedCalls": suggested_calls,
        },
        "suggestedCalls": suggested_calls,
    }))
}

fn decomposition_result_message(details: &Value) -> String {
    let mut message = "execute needs decomposition before child execution: the selected capability accepts one target per call. No child invocation was created. Suggested calls are available for a follow-up only if the user wants the work performed.".to_owned();
    let Some(calls) = details.get("suggestedCalls").and_then(Value::as_array) else {
        return message;
    };
    if calls.is_empty() {
        return message;
    }
    message.push_str("\nSuggested execute calls:");
    for (index, call) in calls.iter().take(5).enumerate() {
        let target = call
            .get("target")
            .and_then(Value::as_str)
            .unwrap_or("<target>");
        let arguments = call.get("arguments").cloned().unwrap_or_else(|| json!({}));
        message.push_str(&format!(
            "\n{}. target={} arguments={}",
            index + 1,
            target,
            compact_json(&arguments)
        ));
    }
    if calls.len() > 5 {
        message.push_str(&format!(
            "\n... {} additional calls omitted",
            calls.len() - 5
        ));
    }
    message
}

fn compact_json(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "{}".to_owned())
}

fn intent_file_read_requests(intent: &str) -> Vec<IntentFileReadRequest> {
    let mut requests = Vec::new();
    let mut seen = BTreeSet::new();
    for clause in intent_read_clauses(intent) {
        let line_bounds = intent_line_bounds(&clause);
        for path in intent_file_path_candidates(&clause) {
            if !seen.insert(path.clone()) {
                continue;
            }
            requests.push(IntentFileReadRequest {
                path,
                start_line: line_bounds.map(|bounds| bounds.0),
                end_line: line_bounds.map(|bounds| bounds.1),
            });
        }
    }
    requests
}

fn intent_read_clauses(intent: &str) -> Vec<String> {
    let mut clauses = Vec::new();
    for clause in intent.split(|character: char| matches!(character, ',' | ';' | '\n')) {
        clauses.extend(split_read_clause_connectors(clause));
    }
    clauses
}

fn split_read_clause_connectors(clause: &str) -> Vec<String> {
    let lower = clause.to_ascii_lowercase();
    let markers = [
        (" and read ", 5usize),
        (" and open ", 5usize),
        (" and cat ", 5usize),
        (" then read ", 6usize),
        (" then open ", 6usize),
        (" then cat ", 6usize),
        (" also read ", 6usize),
        (" plus read ", 6usize),
    ];
    let mut parts = Vec::new();
    let mut start = 0usize;
    loop {
        let Some((marker_start, marker_offset)) = markers
            .iter()
            .filter_map(|(marker, verb_offset)| {
                lower[start..]
                    .find(marker)
                    .map(|index| (start + index, *verb_offset))
            })
            .min_by_key(|(index, _)| *index)
        else {
            break;
        };
        let before = clause[start..marker_start].trim();
        if !before.is_empty() {
            parts.push(before.to_owned());
        }
        start = marker_start + marker_offset;
    }
    let tail = clause[start..].trim();
    if !tail.is_empty() {
        parts.push(tail.to_owned());
    }
    parts
}

fn intent_file_path_candidates(intent: &str) -> Vec<String> {
    intent
        .split_whitespace()
        .filter_map(|token| {
            let token = clean_intent_path_token(token)?;
            safe_relative_intent_path(&token).then_some(token)
        })
        .collect()
}

fn clean_intent_path_token(token: &str) -> Option<String> {
    let mut value = token
        .trim_matches(|character: char| {
            matches!(
                character,
                '"' | '\'' | '`' | '(' | ')' | '[' | ']' | '{' | '}' | '<' | '>'
            )
        })
        .trim_end_matches(|character: char| {
            matches!(
                character,
                '"' | '\'' | '`' | ')' | ']' | '}' | ',' | ':' | ';'
            )
        })
        .to_owned();
    while value.ends_with('.') && value[..value.len().saturating_sub(1)].contains('.') {
        value.pop();
    }
    while let Some(stripped) = value.strip_prefix("./") {
        value = stripped.to_owned();
    }
    (!value.is_empty()).then_some(value)
}

fn safe_relative_intent_path(path: &str) -> bool {
    if path.is_empty()
        || path.len() > 240
        || path.starts_with('/')
        || path.starts_with('~')
        || path.contains("://")
        || !path
            .chars()
            .any(|character| character.is_ascii_alphabetic())
        || path.chars().any(|character| {
            !(character.is_ascii_alphanumeric() || matches!(character, '.' | '/' | '_' | '-' | '@'))
        })
    {
        return false;
    }
    let mut segments = path.split('/').peekable();
    if segments.peek().is_none() {
        return false;
    }
    if segments.any(|segment| segment.is_empty() || segment == "." || segment == "..") {
        return false;
    }
    let Some(file_name) = path.rsplit('/').next() else {
        return false;
    };
    path.contains('/') || file_name.contains('.') || is_common_file_name(file_name)
}

fn is_common_file_name(file_name: &str) -> bool {
    matches!(
        file_name,
        "README" | "LICENSE" | "Makefile" | "Dockerfile" | "Gemfile" | "Rakefile"
    )
}

fn intent_line_bounds(intent: &str) -> Option<(u64, u64)> {
    let words = normalized_identifier_words(intent);
    for (index, word) in words.iter().enumerate() {
        if word != "line" && word != "lines" {
            continue;
        }
        let Some(start) = words
            .get(index + 1)
            .and_then(|word| intent_number_word(word))
        else {
            continue;
        };
        let separator = words.get(index + 2).map(String::as_str);
        let Some(end) = words
            .get(index + 3)
            .and_then(|word| intent_number_word(word))
        else {
            continue;
        };
        if matches!(separator, Some("through" | "thru" | "to" | "until" | "and")) && start <= end {
            return Some((start, end));
        }
    }
    intent_first_line_count_from_words(&words).map(|count| (1, count))
}

fn intent_first_line_count_from_words(words: &[String]) -> Option<u64> {
    for (index, word) in words.iter().enumerate() {
        if word != "first" {
            continue;
        }
        match words.get(index + 1).map(String::as_str) {
            Some("line" | "lines") => return Some(1),
            Some(count_word) => {
                let Some(count) = intent_number_word(count_word) else {
                    continue;
                };
                if words
                    .get(index + 2)
                    .is_some_and(|next| next == "line" || next == "lines")
                {
                    return Some(count);
                }
            }
            None => {}
        }
    }
    None
}

fn apply_intent_line_bounds(
    object: &mut Map<String, Value>,
    start_line: Option<u64>,
    end_line: Option<u64>,
    corrections: &mut Vec<Value>,
) {
    let Some(end_line) = end_line else {
        return;
    };
    let start_line = start_line.unwrap_or(1);
    if !object.contains_key("startLine") {
        object.insert("startLine".to_owned(), json!(start_line));
    }
    if !object.contains_key("endLine") {
        object.insert("endLine".to_owned(), json!(end_line));
    }
    corrections.push(correction_record(
        "intent_line_bounds_to_target_arguments",
        format!("bound line range {start_line} through {end_line} from execute intent into filesystem::read_file arguments"),
        0.9,
    ));
}

fn intent_number_word(word: &str) -> Option<u64> {
    if let Ok(value) = word.parse::<u64>() {
        return (1..=200).contains(&value).then_some(value);
    }
    match word {
        "one" => Some(1),
        "two" => Some(2),
        "three" => Some(3),
        "four" => Some(4),
        "five" => Some(5),
        "six" => Some(6),
        "seven" => Some(7),
        "eight" => Some(8),
        "nine" => Some(9),
        "ten" => Some(10),
        "eleven" => Some(11),
        "twelve" => Some(12),
        "twenty" => Some(20),
        _ => None,
    }
}

fn intent_requests_worktree_diff(intent: &str) -> bool {
    let words = normalized_intent_words(intent);
    let asks_for_diff = words.contains("diff") || words.contains("difference");
    let asks_for_changes = words.contains("changes") || words.contains("uncommitted");
    if !(asks_for_diff || asks_for_changes) {
        return false;
    }
    let strong_worktree_or_git = [
        "worktree",
        "git",
        "repo",
        "repository",
        "branch",
        "uncommitted",
        "status",
    ]
    .iter()
    .any(|word| words.contains(*word));
    asks_for_diff && (strong_worktree_or_git || words.contains("current"))
        || asks_for_changes && strong_worktree_or_git
}

fn deterministic_hit_for_function(
    function_id: &str,
    snapshot: &CapabilityRegistrySnapshot,
    constraints: &Value,
    matched_by: &str,
) -> Result<Option<CapabilityIndexHit>, CapabilityError> {
    let Some(entry) = snapshot
        .entries
        .iter()
        .find(|entry| entry.function_id == function_id)
    else {
        return Ok(None);
    };
    let hit = orchestration_hit_from_entry(entry, matched_by, 100.0);
    if !orchestration_constraints_allow_hit(constraints, &hit)? {
        return Ok(None);
    }
    Ok(Some(hit))
}

pub(super) fn orchestration_hit_from_entry(
    entry: &CapabilityRegistryEntry,
    matched_by: &str,
    score: f32,
) -> CapabilityIndexHit {
    let document = entry.search_document();
    CapabilityIndexHit {
        kind: document.kind,
        capability_id: document.capability_id,
        contract_id: document.contract_id,
        implementation_id: document.implementation_id,
        plugin_id: document.plugin_id,
        worker_id: document.worker_id,
        function_id: document.function_id,
        catalog_revision: document.catalog_revision,
        schema_digest: document.schema_digest,
        trust_tier: document.trust_tier,
        health: document.health,
        visibility: document.visibility,
        effect_class: document.effect_class,
        risk_level: document.risk_level,
        lexical_score: score,
        vector_score: None,
        fused_score: score,
        matched_by: matched_by.to_owned(),
        snippet: bounded_snippet(&document.text),
        requires_inspect: requires_fresh_revision(&entry.function),
        recipe: document.recipe,
    }
}

fn bounded_snippet(value: &str) -> String {
    const MAX: usize = 240;
    let mut snippet = value.chars().take(MAX).collect::<String>();
    if value.chars().count() > MAX {
        snippet.push_str("...");
    }
    snippet
}

fn orchestration_candidate_summary(hit: &CapabilityIndexHit) -> Value {
    json!({
        "kind": hit.kind.as_str(),
        "contractId": hit.contract_id.as_str(),
        "implementationId": hit.implementation_id.as_str(),
        "functionId": hit.function_id.as_str(),
        "score": hit.fused_score,
        "matchedBy": hit.matched_by.as_str(),
        "riskLevel": hit.risk_level.as_str(),
        "effectClass": hit.effect_class.as_str(),
        "snippet": hit.snippet.as_str(),
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
            " Related triggers visible as metadata: {}; invoke this capability by function id, not by trigger id.",
            related_trigger_ids.join(", ")
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

pub(super) fn lacks_sufficient_intent_resolution_evidence(
    intent: &str,
    arguments: &Value,
    selected: &CapabilityIndexHit,
) -> bool {
    if intent_strongly_matches_hit(intent, selected) {
        return false;
    }
    if arguments
        .as_object()
        .is_some_and(|object| !object.is_empty())
    {
        return false;
    }
    if selected.matched_by == "local_lexical" {
        return true;
    }
    if selected.fused_score >= MIN_UNANCHORED_INTENT_SCORE {
        return false;
    }
    true
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
mod tests {
    use super::*;
    use crate::domains::capability::types::CapabilityBindingDecision;
    use crate::engine::{ActorId, AuthorityGrantId, CausalContext, FunctionId, TraceId};

    fn test_invocation_with_session_context() -> Invocation {
        Invocation::new_sync(
            FunctionId::new("capability::execute").expect("function id"),
            json!({}),
            CausalContext::new(
                ActorId::new("agent:test").expect("actor id"),
                crate::engine::ActorKind::Agent,
                AuthorityGrantId::new("grant:test").expect("grant id"),
                TraceId::new("trace:test").expect("trace id"),
            )
            .with_session_id("sess-context")
            .with_runtime_metadata(
                crate::engine::invocation::RUNTIME_METADATA_WORKING_DIRECTORY,
                "/tmp/tron/.worktrees/session/sess-context",
            ),
        )
    }

    fn function_from_capability(function_id: &str) -> FunctionDefinition {
        let specs = crate::domains::filesystem::contract::capabilities()
            .expect("filesystem specs")
            .into_iter()
            .chain(crate::domains::worktree::contract::capabilities().expect("worktree specs"))
            .chain(crate::domains::git::contract::capabilities().expect("git specs"))
            .chain(crate::domains::settings::contract::capabilities().expect("settings specs"))
            .chain(crate::domains::model::contract::capabilities().expect("model specs"))
            .chain(crate::domains::logs::contract::capabilities().expect("logs specs"));
        let spec = specs
            .into_iter()
            .find(|spec| spec.function_id.as_str() == function_id)
            .unwrap_or_else(|| panic!("{function_id} spec"));
        crate::domains::contract::function_definition_for_capability(&spec)
    }

    fn resource_list_function() -> FunctionDefinition {
        FunctionDefinition::new(
            FunctionId::new("resource::list").expect("function id"),
            crate::engine::WorkerId::new("resource").expect("worker id"),
            "list typed resources",
            crate::engine::VisibilityScope::System,
            crate::engine::EffectClass::PureRead,
        )
        .with_request_schema(json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "kind": {"type": "string"},
                "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"},
                "lifecycle": {"type": "string"},
                "limit": {"type": "integer"}
            }
        }))
    }

    #[test]
    fn discovery_message_surfaces_related_trigger_metadata() {
        let mut function = FunctionDefinition::new(
            FunctionId::new("rwo_n7::echo").expect("function id"),
            crate::engine::WorkerId::new("rwo-n7-worker").expect("worker id"),
            "RWO-N7 fixture",
            crate::engine::VisibilityScope::System,
            crate::engine::EffectClass::PureRead,
        );
        function.metadata = json!({
            "relatedTriggers": [{
                "triggerId": "manual:rwo_n7.echo",
                "triggerType": "manual",
                "targetFunction": "rwo_n7::echo"
            }]
        });
        let entry = CapabilityRegistryEntry::from_function(function, 7);
        let target = ResolvedCapabilityTarget {
            binding_decision: CapabilityBindingDecision {
                decision_id: "decision-test".to_owned(),
                contract_id: entry.contract_id.clone(),
                selected_implementation: entry.implementation_id.clone(),
                selected_function_id: entry.function_id.clone(),
                selection_policy: "test".to_owned(),
                rejected_candidates: Vec::new(),
                catalog_revision: entry.catalog_revision,
                schema_digest: entry.schema_digest.clone(),
            },
            entry,
        };

        let message = discovery_message(&target);

        assert!(message.contains("manual:rwo_n7.echo"));
        assert!(message.contains("visible as metadata"));
        assert!(message.contains("not by trigger id"));
    }

    fn observability_metrics_function() -> FunctionDefinition {
        FunctionDefinition::new(
            FunctionId::new("observability::metrics_snapshot").expect("function id"),
            crate::engine::WorkerId::new("observability").expect("worker id"),
            "return a local metrics snapshot for engine primitives",
            crate::engine::VisibilityScope::System,
            crate::engine::EffectClass::PureRead,
        )
        .with_request_schema(json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {}
        }))
    }

    fn resolved_target_for(function: FunctionDefinition) -> ResolvedCapabilityTarget {
        let entry = CapabilityRegistryEntry::from_function(function, 391);
        ResolvedCapabilityTarget {
            binding_decision: crate::domains::capability::types::CapabilityBindingDecision {
                decision_id: "decision:test".to_owned(),
                contract_id: entry.contract_id.clone(),
                selected_implementation: entry.implementation_id.clone(),
                selected_function_id: entry.function_id.clone(),
                selection_policy: "test".to_owned(),
                rejected_candidates: Vec::new(),
                catalog_revision: entry.catalog_revision,
                schema_digest: entry.schema_digest.clone(),
            },
            entry,
        }
    }

    #[test]
    fn discovery_only_intent_is_guidance_not_execution() {
        let input = parse_orchestrated_execute_input(&json!({
            "intent": "Discover module package registration required fields. Do not execute mutations.",
            "reason": "RWO discovery only"
        }))
        .expect("input");

        assert!(input.discovery_only());
        assert_eq!(input.operation, None);
        assert!(!orchestration_status_is_error("capability_discovery"));
        assert!(!orchestration_status_is_error("needs_selection"));
        assert!(!orchestration_status_is_error("needs_input"));
        assert!(!orchestration_status_is_error("needs_capability"));
        assert!(orchestration_status_is_error("request_invalid"));
        assert!(orchestration_status_is_error("target_policy_rejected"));
    }

    #[test]
    fn explicit_execute_operation_controls_discovery_inference() {
        let discover = parse_orchestrated_execute_input(&json!({
            "operation": "discover",
            "intent": "module package registration",
            "arguments": {}
        }))
        .expect("discover input");
        assert!(discover.discovery_only());

        let run = parse_orchestrated_execute_input(&json!({
            "operation": "run",
            "intent": "Discover README.md by reading it",
            "arguments": {}
        }))
        .expect("run input");
        assert!(!run.discovery_only());

        let invalid = parse_orchestrated_execute_input(&json!({
            "operation": "unsupported-probe",
            "intent": "read README.md"
        }))
        .expect_err("invalid operation");
        assert!(invalid.to_string().contains("execute.operation"));
    }

    #[test]
    fn safety_constraints_do_not_make_pure_read_targets_discovery_only() {
        let input = parse_orchestrated_execute_input(&json!({
            "intent": "Get recent server/event/log counts from a pure-read observability metrics snapshot. Do not mutate anything and do not use shell/process.",
            "target": "observability::metrics_snapshot",
            "arguments": {},
            "constraints": {"effect": "pure_read"}
        }))
        .expect("input");

        assert!(!input.discovery_only());
    }

    #[test]
    fn current_status_discovery_wording_still_runs_pure_read_target() {
        let input = parse_orchestrated_execute_input(&json!({
            "intent": "Discover current model/provider status.",
            "target": "model::list",
            "arguments": {},
            "constraints": {"effect": "pure_read"}
        }))
        .expect("input");

        assert!(!input.discovery_only());
    }

    #[test]
    fn resource_inventory_discovery_runs_pure_read_instead_of_schema_only() {
        let mut input = parse_orchestrated_execute_input(&json!({
            "operation": "discover",
            "intent": "Discover whether current engine has existing module_package resources.",
            "arguments": {}
        }))
        .expect("discover input");
        assert!(input.discovery_only());

        normalize_live_resource_inventory_operation(&mut input);

        assert_eq!(input.operation.as_deref(), Some("run"));
        assert!(!input.discovery_only());
        assert!(input.corrections.iter().any(|correction| {
            correction["kind"] == json!("resource_inventory_discovery_to_read_only_run")
        }));
    }

    #[test]
    fn resource_inventory_required_fields_remains_discovery_only() {
        let mut input = parse_orchestrated_execute_input(&json!({
            "operation": "discover",
            "intent": "Discover module package registration required fields. Do not execute mutations.",
            "arguments": {}
        }))
        .expect("discover input");

        normalize_live_resource_inventory_operation(&mut input);

        assert_eq!(input.operation.as_deref(), Some("discover"));
        assert!(input.discovery_only());
        assert!(input.corrections.iter().all(|correction| {
            correction["kind"] != json!("resource_inventory_discovery_to_read_only_run")
        }));
    }

    #[test]
    fn observe_phase_promotes_child_resource_refs_and_approval_state() {
        let resource_refs = json!([
            {
                "kind": "materialized_file",
                "resourceId": "materialized_file:test",
                "versionId": "ver_test",
                "role": "updated"
            },
            {
                "kind": "execution_output",
                "resourceId": "res_test",
                "versionId": "ver_output",
                "role": "created"
            }
        ]);
        let result = capability_result_value(CapabilityResult {
            content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
                "ok".to_owned(),
            )]),
            details: Some(json!({
                "status": "ok",
                "output": {
                    "stdout": "ok\n",
                    "resourceRefs": resource_refs.clone()
                },
                "approvalState": {
                    "approvalId": "approval-test",
                    "approvalCreated": true,
                    "approvalExecuted": true,
                    "status": "Executed"
                },
                "childInvocations": ["child-test"]
            })),
            is_error: None,
            stop_turn: None,
        })
        .expect("capability result");

        let mut orchestration = json!({
            "status": "ok",
            "childInvocationIds": ["child-test"]
        });
        enrich_orchestration_with_result(&mut orchestration, &result);
        assert_eq!(orchestration["resourceRefs"], resource_refs);
        assert_eq!(
            orchestration["approvalDecision"]["approvalId"],
            json!("approval-test")
        );

        let attached =
            attach_orchestration_details(result, orchestration).expect("attached result");
        let attached: CapabilityResult =
            serde_json::from_value(attached).expect("capability result");
        let details = attached.details.expect("details");
        assert_eq!(details["resourceRefs"], resource_refs);
        assert_eq!(details["orchestration"]["resourceRefs"], resource_refs);
        assert_eq!(
            details["orchestration"]["approvalDecision"]["approvalId"],
            json!("approval-test")
        );
    }

    #[test]
    fn observe_phase_promotes_normalized_approval_decision_to_audit() {
        let result = capability_result_value(CapabilityResult {
            content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
                "ok".to_owned(),
            )]),
            details: Some(json!({
                "status": "ok",
                "approvalDecision": {
                    "approvalRequired": false,
                    "approvalCreated": false,
                    "approvalExecuted": false,
                    "approvalReplayed": false,
                    "status": "not_required"
                },
                "childInvocations": ["child-read"]
            })),
            is_error: None,
            stop_turn: None,
        })
        .expect("capability result");
        let mut orchestration = json!({
            "status": "ok",
            "childInvocationIds": ["child-read"]
        });

        enrich_orchestration_with_result(&mut orchestration, &result);

        assert_eq!(
            orchestration["approvalDecision"]["status"],
            json!("not_required")
        );
        assert_eq!(
            orchestration["approvalDecision"]["approvalRequired"],
            json!(false)
        );
    }

    #[test]
    fn observe_phase_defaults_empty_refs_and_no_approval() {
        let result = capability_result_value(CapabilityResult {
            content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
                "ok".to_owned(),
            )]),
            details: Some(json!({
                "status": "ok",
                "output": {
                    "entries": []
                },
                "childInvocations": ["child-read"]
            })),
            is_error: None,
            stop_turn: None,
        })
        .expect("capability result");
        let orchestration = json!({
            "status": "ok",
            "childInvocationIds": ["child-read"]
        });
        let mut audit_orchestration = orchestration.clone();

        enrich_orchestration_with_result(&mut audit_orchestration, &result);
        assert_eq!(
            audit_orchestration["approvalDecision"]["status"],
            json!("not_required")
        );

        let attached =
            attach_orchestration_details(result, orchestration).expect("attached result");
        let attached: CapabilityResult =
            serde_json::from_value(attached).expect("capability result");
        let details = attached.details.expect("details");

        assert_eq!(details["resourceRefs"], json!([]));
        assert_eq!(details["childInvocationIds"], json!(["child-read"]));
        assert_eq!(details["approvalDecision"]["status"], json!("not_required"));
        assert_eq!(details["approvalDecision"]["approvalCreated"], json!(false));
    }

    #[test]
    fn orchestrated_execute_result_exposes_its_own_invocation_id() {
        let invocation = Invocation::new_sync(
            crate::engine::FunctionId::new("capability::execute").expect("function id"),
            json!({"target": "filesystem::read_file", "arguments": {"path": "README.md"}}),
            crate::engine::CausalContext::new(
                crate::engine::ActorId::new("agent:test").expect("actor id"),
                crate::engine::ActorKind::Agent,
                crate::engine::AuthorityGrantId::new("agent-capability-runtime").expect("grant id"),
                crate::engine::TraceId::new("trace").expect("trace id"),
            ),
        );
        let result = capability_result_value(CapabilityResult {
            content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
                "ok".to_owned(),
            )]),
            details: Some(json!({
                "status": "ok",
                "orchestration": {
                    "orchestrationId": "capability-orchestration:test",
                    "status": "ok",
                    "childInvocationIds": ["child-read"]
                }
            })),
            is_error: None,
            stop_turn: None,
        })
        .expect("capability result");

        let attached =
            attach_execute_invocation_metadata(result, &invocation).expect("attached result");
        let attached: CapabilityResult =
            serde_json::from_value(attached).expect("capability result");
        let details = attached.details.expect("details");

        assert_eq!(
            details["executeInvocationId"],
            json!(invocation.id.as_str())
        );
        assert_eq!(
            details["primitiveInvocationId"],
            json!(invocation.id.as_str())
        );
        assert_eq!(
            details["orchestration"]["executeInvocationId"],
            json!(invocation.id.as_str())
        );
    }

    #[test]
    fn orchestrated_execute_removes_self_target_before_resolution() {
        for target in [
            json!("capability::execute"),
            json!({"functionId": "capability::execute"}),
            json!({"capabilityId": "capability::execute"}),
            json!({"implementationId": "function:capability::execute"}),
            json!({"implementationId": "first_party.capability.v1.execute"}),
        ] {
            let input = parse_orchestrated_execute_input(&json!({
                "intent": "read README.md lines 1 through 5",
                "target": target
            }))
            .expect("parse execute input");

            assert!(
                input.target_params.is_none(),
                "self-target should be removed before resolve"
            );
            assert!(
                input.corrections.iter().any(|correction| {
                    correction["kind"] == json!("execute_self_target_removed")
                })
            );
        }
    }

    #[test]
    fn contextual_normalization_binds_current_session_id_for_session_scoped_targets() {
        let function = function_from_capability("git::list_local_branches");
        let invocation = test_invocation_with_session_context();
        let mut arguments = json!({
            "path": "/tmp/tron/.worktrees/session/sess-context"
        });
        let mut corrections = Vec::new();

        normalize_contextual_target_arguments(
            &function,
            &invocation,
            &mut arguments,
            &mut corrections,
        );

        assert_eq!(arguments["sessionId"], json!("sess-context"));
        assert!(arguments.get("path").is_none());
        assert!(corrections.iter().any(|correction| {
            correction["kind"] == json!("runtime_session_id_to_target_argument")
        }));
        assert!(corrections.iter().any(|correction| {
            correction["kind"] == json!("current_worktree_path_hint_removed")
        }));
        let entry = CapabilityRegistryEntry::from_function(function, 391);
        validate_target_payload(&entry, &arguments)
            .expect("trusted session binding should make payload schema-valid");
    }

    #[test]
    fn contextual_normalization_does_not_hide_arbitrary_path_arguments() {
        let function = function_from_capability("git::list_local_branches");
        let invocation = test_invocation_with_session_context();
        let mut arguments = json!({
            "path": "/tmp/other-repo"
        });
        let mut corrections = Vec::new();

        normalize_contextual_target_arguments(
            &function,
            &invocation,
            &mut arguments,
            &mut corrections,
        );

        assert_eq!(arguments["sessionId"], json!("sess-context"));
        assert_eq!(arguments["path"], json!("/tmp/other-repo"));
        let entry = CapabilityRegistryEntry::from_function(function, 391);
        validate_target_payload(&entry, &arguments)
            .expect_err("non-current path must remain visible to schema validation");
    }

    #[test]
    fn contextual_normalization_binds_working_directory_for_git_repo_probe() {
        let function = function_from_capability("worktree::is_git_repo");
        let invocation = test_invocation_with_session_context();
        let mut arguments = json!({});
        let mut corrections = Vec::new();

        normalize_contextual_target_arguments(
            &function,
            &invocation,
            &mut arguments,
            &mut corrections,
        );

        assert_eq!(
            arguments["path"],
            json!("/tmp/tron/.worktrees/session/sess-context")
        );
        assert!(corrections.iter().any(|correction| {
            correction["kind"] == json!("runtime_working_directory_to_target_path")
        }));
        let entry = CapabilityRegistryEntry::from_function(function, 391);
        validate_target_payload(&entry, &arguments)
            .expect("trusted working directory should make repo probe schema-valid");
    }

    #[test]
    fn intent_argument_normalization_binds_safe_filesystem_path_and_line_range() {
        let function = function_from_capability("filesystem::read_file");
        let mut arguments = json!({});
        let mut corrections = Vec::new();

        normalize_intent_target_arguments(
            &function,
            Some("Read only the first three lines of README.md."),
            &mut arguments,
            &mut corrections,
        );

        assert_eq!(arguments["path"], json!("README.md"));
        assert_eq!(arguments["startLine"], json!(1));
        assert_eq!(arguments["endLine"], json!(3));
        assert!(corrections.iter().any(|correction| {
            correction["kind"] == json!("intent_file_path_to_target_argument")
        }));
        assert!(corrections.iter().any(|correction| {
            correction["kind"] == json!("intent_line_bounds_to_target_arguments")
        }));
        let entry = CapabilityRegistryEntry::from_function(function, 391);
        validate_target_payload(&entry, &arguments)
            .expect("intent binding should make read_file payload schema-valid");
    }

    #[test]
    fn deterministic_intent_route_prefers_resource_list_for_module_resource_inventory() {
        let resource_list = resource_list_function();
        let mut binding_list = FunctionDefinition::new(
            FunctionId::new("capability::binding_list").expect("function id"),
            crate::engine::WorkerId::new("capability").expect("worker id"),
            "list capability bindings",
            crate::engine::VisibilityScope::System,
            crate::engine::EffectClass::PureRead,
        );
        binding_list.description =
            "inspect capability registration and binding metadata".to_owned();
        let snapshot = CapabilityRegistrySnapshot::new(vec![binding_list, resource_list], 391);

        let hit = deterministic_intent_route(
            "Discover whether current engine has existing worker_package and activation_record resources by using pure-read resource listing only, and report whether full RWO-011 can proceed safely from the app without hand-authoring a manifest.",
            &json!({}),
            &snapshot,
            &json!({}),
        )
        .expect("route check")
        .expect("resource list route");

        assert_eq!(hit.function_id, "resource::list");
        assert_eq!(hit.matched_by, "deterministic_resource_inventory");
    }

    #[test]
    fn deterministic_intent_route_prefers_operator_status_targets() {
        let snapshot = CapabilityRegistrySnapshot::new(
            vec![
                function_from_capability("filesystem::read_file"),
                function_from_capability("model::list"),
                function_from_capability("settings::get"),
                function_from_capability("logs::recent"),
                observability_metrics_function(),
            ],
            391,
        );

        let cases = [
            (
                "Report the current model/provider status without running shell or mutating anything.",
                "model::list",
            ),
            (
                "Report the current settings summary without mutating settings.",
                "settings::get",
            ),
            (
                "Report the recent server/event/log count from pure-read capabilities.",
                "logs::recent",
            ),
            (
                "Do not mutate settings, state, resources, files, prompts, or memory. Use the canonical pure-read logs capability to fetch recent server/app logs.",
                "logs::recent",
            ),
            (
                "Report the current engine metrics count from pure-read observability.",
                "observability::metrics_snapshot",
            ),
        ];
        for (intent, expected) in cases {
            let hit = deterministic_intent_route(intent, &json!({}), &snapshot, &json!({}))
                .expect("route check")
                .unwrap_or_else(|| panic!("expected route for {intent}"));
            assert_eq!(hit.function_id, expected);
            assert_eq!(hit.matched_by, "deterministic_operator_status");
        }
    }

    #[test]
    fn intent_argument_normalization_binds_module_resource_kind_for_resource_list() {
        let function = resource_list_function();
        let mut arguments = json!({});
        let mut corrections = Vec::new();

        normalize_intent_target_arguments(
            &function,
            Some("List existing module_package resources."),
            &mut arguments,
            &mut corrections,
        );

        assert_eq!(arguments["kind"], json!(WORKER_PACKAGE_KIND));
        assert!(corrections.iter().any(|correction| {
            correction["kind"] == json!("intent_resource_kind_to_target_argument")
        }));
        let entry = CapabilityRegistryEntry::from_function(function, 391);
        validate_target_payload(&entry, &arguments)
            .expect("intent binding should make resource::list payload schema-valid");
    }

    #[test]
    fn multi_resource_kind_inventory_requires_decomposition() {
        let target = resolved_target_for(resource_list_function());
        let resolve = OrchestrationResolve {
            target_params: json!({"functionId": "resource::list"}),
            mode: "intent_resolution".to_owned(),
            candidates: Vec::new(),
            rejected_candidates: Vec::new(),
            search_status: Value::Null,
        };

        let details = decomposition_phase_details(
            &resolve,
            &target,
            Some("List existing module_package and module_activation resources."),
            &json!({}),
        )
        .expect("resource inventory should decompose by kind");

        assert_eq!(
            details["decomposition"]["reason"],
            json!("multiple_resource_kinds_for_single_inventory_request")
        );
        assert_eq!(
            details["suggestedCalls"][0]["target"],
            json!("resource::list")
        );
        assert_eq!(
            details["suggestedCalls"][0]["arguments"]["kind"],
            json!(WORKER_PACKAGE_KIND)
        );
        assert_eq!(
            details["suggestedCalls"][1]["arguments"]["kind"],
            json!(ACTIVATION_RECORD_KIND)
        );
    }

    #[test]
    fn intent_argument_normalization_binds_explicit_line_range() {
        let function = function_from_capability("filesystem::read_file");
        let mut arguments = json!({});
        let mut corrections = Vec::new();

        normalize_intent_target_arguments(
            &function,
            Some(
                "Read packages/agent/docs/capability-orchestration-test-scorecard.md lines 1 through 20.",
            ),
            &mut arguments,
            &mut corrections,
        );

        assert_eq!(
            arguments["path"],
            json!("packages/agent/docs/capability-orchestration-test-scorecard.md")
        );
        assert_eq!(arguments["startLine"], json!(1));
        assert_eq!(arguments["endLine"], json!(20));
        assert!(corrections.iter().any(|correction| {
            correction["kind"] == json!("intent_line_bounds_to_target_arguments")
        }));
        let entry = CapabilityRegistryEntry::from_function(function, 391);
        validate_target_payload(&entry, &arguments)
            .expect("explicit line range should make read_file payload schema-valid");
    }

    #[test]
    fn multi_file_read_intent_requires_decomposition_instead_of_partial_binding() {
        let function = function_from_capability("filesystem::read_file");
        let intent = "Read packages/agent/docs/capability-orchestration-test-scorecard.md lines 1 through 20, read README.md lines 1 through 5.";
        let requests = intent_file_read_requests(intent);

        assert_eq!(requests.len(), 2);
        assert_eq!(
            requests[0],
            IntentFileReadRequest {
                path: "packages/agent/docs/capability-orchestration-test-scorecard.md".to_owned(),
                start_line: Some(1),
                end_line: Some(20),
            }
        );
        assert_eq!(
            requests[1],
            IntentFileReadRequest {
                path: "README.md".to_owned(),
                start_line: Some(1),
                end_line: Some(5),
            }
        );

        let mut arguments = json!({});
        let mut corrections = Vec::new();
        normalize_intent_target_arguments(
            &function,
            Some(intent),
            &mut arguments,
            &mut corrections,
        );

        assert_eq!(
            arguments,
            json!({}),
            "multi-target intent must not silently bind only the first path"
        );
        assert!(corrections.is_empty());
        assert!(!orchestration_status_is_error("needs_decomposition"));
    }

    #[test]
    fn multi_file_read_intent_splits_conjunction_line_bounds_per_target() {
        let intent = "Read packages/agent/docs/capability-orchestration-test-scorecard.md lines 1 through 20 and read README.md lines 1 through 5.";
        let requests = intent_file_read_requests(intent);

        assert_eq!(
            requests,
            vec![
                IntentFileReadRequest {
                    path: "packages/agent/docs/capability-orchestration-test-scorecard.md"
                        .to_owned(),
                    start_line: Some(1),
                    end_line: Some(20),
                },
                IntentFileReadRequest {
                    path: "README.md".to_owned(),
                    start_line: Some(1),
                    end_line: Some(5),
                }
            ]
        );
    }

    #[test]
    fn decomposition_result_message_surfaces_suggested_calls_in_content() {
        let details = json!({
            "suggestedCalls": [
                {
                    "target": "filesystem::read_file",
                    "arguments": {
                        "path": "packages/agent/docs/capability-orchestration-test-scorecard.md",
                        "startLine": 1,
                        "endLine": 20
                    }
                },
                {
                    "target": "filesystem::read_file",
                    "arguments": {
                        "path": "README.md",
                        "startLine": 1,
                        "endLine": 5
                    }
                }
            ]
        });

        let message = decomposition_result_message(&details);

        assert!(message.contains("Suggested execute calls:"));
        assert!(message.contains("target=filesystem::read_file"));
        assert!(message.contains("\"path\":\"README.md\""));
        assert!(message.contains("\"endLine\":5"));
    }

    #[test]
    fn intent_argument_normalization_rejects_unsafe_paths_from_intent() {
        let function = function_from_capability("filesystem::read_file");
        let unsafe_intents = [
            "Read the first line of /etc/passwd.",
            "Read the first line of ../README.md.",
            "Read the first line of https://example.com/README.md.",
            "Read the first line of README.md;rm.",
        ];

        for intent in unsafe_intents {
            let mut arguments = json!({});
            let mut corrections = Vec::new();

            normalize_intent_target_arguments(
                &function,
                Some(intent),
                &mut arguments,
                &mut corrections,
            );

            assert!(
                arguments.get("path").is_none(),
                "unsafe intent should not bind a path: {intent}"
            );
            assert!(corrections.is_empty());
        }
    }

    #[test]
    fn observe_phase_promotes_needs_input_recovery_fields() {
        let result = capability_result_value(CapabilityResult {
            content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
                "filesystem::read_file needs input before child execution".to_owned(),
            )]),
            details: Some(json!({
                "status": "needs_input",
                "error": {
                    "code": "INVALID_PARAMS",
                    "details": {
                        "validationKind": "missing_required_argument",
                        "missingFields": ["path"],
                        "missingArgumentPaths": ["arguments.path"]
                    }
                },
                "guidance": {
                    "kind": "provide_missing_arguments",
                    "missingFields": ["path"],
                    "missingArgumentPaths": ["arguments.path"]
                },
                "missingFields": ["path"],
                "missingArgumentPaths": ["arguments.path"],
                "childInvocationCreated": false,
                "childInvocationIds": [],
                "approvalCreated": false,
                "resourceRefs": []
            })),
            is_error: Some(true),
            stop_turn: None,
        })
        .expect("capability result");
        let mut orchestration = json!({
            "status": "needs_input",
            "childInvocationIds": []
        });

        enrich_orchestration_with_result(&mut orchestration, &result);
        assert_eq!(orchestration["missingFields"], json!(["path"]));
        assert_eq!(
            orchestration["missingArgumentPaths"],
            json!(["arguments.path"])
        );
        assert_eq!(
            orchestration["approvalDecision"]["status"],
            json!("not_required")
        );

        let attached =
            attach_orchestration_details(result, orchestration).expect("attached result");
        let attached: CapabilityResult =
            serde_json::from_value(attached).expect("capability result");
        let details = attached.details.expect("details");

        assert_eq!(details["missingFields"], json!(["path"]));
        assert_eq!(details["missingArgumentPaths"], json!(["arguments.path"]));
        assert_eq!(details["childInvocationIds"], json!([]));
        assert_eq!(details["approvalDecision"]["status"], json!("not_required"));
        assert_eq!(
            details["approvalDecision"]["approvalRequired"],
            json!(false)
        );
        assert_eq!(details["orchestration"]["missingFields"], json!(["path"]));
        assert_eq!(
            details["orchestration"]["missingArgumentPaths"],
            json!(["arguments.path"])
        );
    }

    #[test]
    fn terminal_orchestration_result_promotes_recovery_fields() {
        let diagnostics = json!({
            "orchestrationId": "capability-orchestration:test",
            "status": "needs_selection",
            "intent": "do something with files",
            "correctedRequest": {
                "intent": "do something with files",
                "arguments": {}
            },
            "correctionsApplied": [],
            "correctionConfidence": 1.0,
            "phaseDetails": {
                "phase": "resolve",
                "candidates": [
                    {
                        "functionId": "filesystem::read_file",
                        "contractId": "filesystem::read_file"
                    },
                    {
                        "functionId": "filesystem::list_dir",
                        "contractId": "filesystem::list_dir"
                    }
                ],
                "searchStatus": {
                    "vectorIndex": "ready"
                }
            },
            "childInvocationIds": []
        });

        let result = orchestration_result(
            "needs_selection",
            "Multiple visible capabilities match that intent.",
            diagnostics,
            true,
        )
        .expect("orchestration result");
        let result: CapabilityResult = serde_json::from_value(result).expect("capability result");
        let details = result.details.expect("details");

        assert_eq!(details["status"], json!("needs_selection"));
        assert_eq!(
            details["candidates"][0]["functionId"],
            json!("filesystem::read_file")
        );
        assert_eq!(details["searchStatus"]["vectorIndex"], json!("ready"));
        assert_eq!(
            details["correctedRequest"]["intent"],
            json!("do something with files")
        );
        assert_eq!(details["childInvocationCreated"], json!(false));
        assert_eq!(details["approvalDecision"]["status"], json!("not_required"));
        assert_eq!(details["resourceRefs"], json!([]));
    }

    #[test]
    fn terminal_orchestration_result_promotes_guidance_for_invalid_capability_primitive_target() {
        let diagnostics = json!({
            "orchestrationId": "capability-orchestration:test",
            "status": "request_invalid",
            "intent": "wrap capability search",
            "correctedRequest": {
                "intent": "wrap capability search",
                "target": "capability::search",
                "arguments": {}
            },
            "correctionsApplied": [],
            "correctionConfidence": 1.0,
            "phaseDetails": {
                "phase": "prepare",
                "selectedTarget": {
                    "functionId": "capability::search"
                },
                "error": {
                    "code": "INVALID_PARAMS",
                    "message": "execute cannot target capability::search because it is a capability primitive"
                },
                "guidance": {
                    "kind": "target_real_capability",
                    "message": "Call execute once.",
                    "examples": [
                        {"target": "filesystem::read_file", "arguments": {"path": "README.md"}}
                    ]
                }
            },
            "childInvocationIds": []
        });

        let result = orchestration_result(
            "request_invalid",
            "execute target is invalid.",
            diagnostics,
            true,
        )
        .expect("orchestration result");
        let result: CapabilityResult = serde_json::from_value(result).expect("capability result");
        let details = result.details.expect("details");

        assert_eq!(details["status"], json!("request_invalid"));
        assert_eq!(
            details["selectedTarget"]["functionId"],
            json!("capability::search")
        );
        assert_eq!(details["guidance"]["kind"], json!("target_real_capability"));
        assert_eq!(details["childInvocationIds"], json!([]));
        assert_eq!(details["approvalDecision"]["status"], json!("not_required"));
        assert_eq!(details["resourceRefs"], json!([]));
    }

    #[test]
    fn terminal_orchestration_result_promotes_decomposition_guidance() {
        let diagnostics = json!({
            "orchestrationId": "capability-orchestration:test",
            "status": "needs_decomposition",
            "intent": "read two files",
            "correctedRequest": {
                "intent": "read two files",
                "target": {"functionId": "filesystem::read_file"},
                "arguments": {}
            },
            "correctionsApplied": [],
            "correctionConfidence": 1.0,
            "phaseDetails": {
                "phase": "prepare",
                "decomposition": {
                    "reason": "multiple_files_for_single_target",
                    "targetCount": 2
                },
                "guidance": {
                    "kind": "one_target_per_execute",
                    "suggestedCalls": [
                        {"target": "filesystem::read_file", "arguments": {"path": "README.md"}},
                        {"target": "filesystem::read_file", "arguments": {"path": "packages/agent/README.md"}}
                    ]
                },
                "suggestedCalls": [
                    {"target": "filesystem::read_file", "arguments": {"path": "README.md"}},
                    {"target": "filesystem::read_file", "arguments": {"path": "packages/agent/README.md"}}
                ]
            },
            "childInvocationIds": []
        });

        let result = orchestration_result(
            "needs_decomposition",
            "execute needs decomposition before child execution.",
            diagnostics,
            orchestration_status_is_error("needs_decomposition"),
        )
        .expect("orchestration result");
        let result: CapabilityResult = serde_json::from_value(result).expect("capability result");
        let details = result.details.expect("details");

        assert_eq!(details["status"], json!("needs_decomposition"));
        assert_eq!(details["childInvocationCreated"], json!(false));
        assert_eq!(details["childInvocationIds"], json!([]));
        assert_eq!(details["decomposition"]["targetCount"], json!(2));
        assert_eq!(
            details["suggestedCalls"][0]["arguments"]["path"],
            json!("README.md")
        );
        assert_eq!(details["isError"], Value::Null);
    }

    #[test]
    fn orchestration_failure_status_keeps_policy_denials_in_prepare_phase() {
        let denied = CapabilityError::Custom {
            code: "CAPABILITY_DENIED".to_owned(),
            message: "process::run is not allowed by the active capability policy".to_owned(),
            details: None,
        };
        let runtime = CapabilityError::Internal {
            message: "worker disappeared".to_owned(),
        };

        assert_eq!(orchestration_failure_status(&denied), "prepare_failed");
        assert_eq!(orchestration_failure_status(&runtime), "run_failed");
    }
}
