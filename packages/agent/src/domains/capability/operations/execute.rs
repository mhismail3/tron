//! Single execute orchestrator phases for the model-facing capability primitive.

use serde_json::{Map, Value, json};

use super::{
    ResolvedCapabilityTarget, actor_from_invocation, capability_primitive_target_error,
    index_status_needs_vector_warmup, is_capability_primitive, registry_metadata_sync_policy,
    registry_snapshot_for_functions, registry_store_error, requires_fresh_revision_for_payload,
    resolve_target, run, schedule_vector_warmup,
};
use crate::domains::capability::Deps;
use crate::domains::capability::registry::{
    CapabilitySearchFilters, CapabilitySearchPolicy, string_field,
};
use crate::engine::{ActorContext, FunctionHealth, FunctionQuery, Invocation};
use crate::shared::model_capabilities::CapabilityResult;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;

pub(super) use input::parse_orchestrated_execute_input;
use input::{
    OrchestratedExecuteInput, is_orchestrated_execute_payload,
    normalize_live_resource_inventory_operation,
};
use result::{
    attach_execute_invocation_metadata, attach_orchestration_details, capability_error_details,
    corrected_orchestrated_request, correction_record, discovery_message, discovery_phase_details,
    enrich_orchestration_with_result, needs_selection_message, orchestration_child_invocations,
    orchestration_details, orchestration_failure_status, orchestration_request_error_details,
    orchestration_result, orchestration_status_is_error, redacted_prepared_request_preview,
};
#[cfg(test)]
use trigger_metadata::trigger_metadata_target_guidance_for_target_params;
use trigger_metadata::{
    trigger_metadata_target_guidance_for_intent,
    trigger_metadata_target_guidance_for_visible_catalog, trigger_metadata_target_message,
    trigger_metadata_target_phase_details,
};

#[cfg(test)]
use super::target_arguments::intent_file_read_requests;
use super::target_arguments::{
    normalize_contextual_target_arguments, normalize_intent_target_arguments,
    normalize_target_arguments, normalize_target_idempotency_argument,
};
#[cfg(test)]
use super::target_resolution::deterministic_intent_route;
use super::target_resolution::{
    apply_argument_schema_fit_filter, apply_deterministic_intent_route,
    clarification_candidates_for_intent, decomposition_phase_details, decomposition_result_message,
    intent_strongly_matches_hit, lacks_sufficient_intent_resolution_evidence,
    orchestration_candidate_summary, orchestration_constraints_allow_hit,
    promote_argument_schema_fit_candidates, validate_orchestration_constraint_shape,
    validate_orchestration_constraints,
};
#[cfg(test)]
use super::validate_target_payload;

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

mod input;
mod result;
mod trigger_metadata;

#[cfg(test)]
mod tests;
