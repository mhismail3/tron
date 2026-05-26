//! Live capability projection and execution primitives.
//!
//! The functions here intentionally adapt the existing engine catalog rather
//! than creating a second capability catalog. A catalog function is projected as a
//! stable contract plus one concrete implementation. Future plugin manifests
//! can add richer contract/binding rows without changing the model-facing
//! single `execute` surface.

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use super::Deps;
use super::registry::{
    CapabilityContextPrimerPolicy, CapabilityRegistryEntry, CapabilityRegistrySnapshot,
    CapabilityRegistryStore, CapabilitySearchFilters, CapabilitySearchPolicy, CapabilityTarget,
    binding_decision, bool_field, parse_target,
    render_capability_primer as render_primer_from_snapshot, requires_fresh_revision, string_field,
    u64_field,
};
use super::types::{
    CapabilityBindingDecision, CapabilityExecutionRecord, CapabilityIndexHit,
    CapabilityIndexStatus, CapabilityPluginManifest, CapabilityRejectedCandidate,
};
use crate::domains::capability_support::implementations::primitive_surface::{
    CONTRACT_ALLOW_SCOPE_PREFIX, CONTRACT_DENY_SCOPE_PREFIX, IMPLEMENTATION_ALLOW_SCOPE_PREFIX,
    IMPLEMENTATION_DENY_SCOPE_PREFIX, PLUGIN_ALLOW_SCOPE_PREFIX, PLUGIN_DENY_SCOPE_PREFIX,
};
use crate::engine::{
    ActorContext, ActorKind, ApprovalStatus, AuthorityGrantId, CausalContext, DeliveryMode,
    EffectClass, EngineApprovalRecord, EngineApprovalRequest, FunctionDefinition, FunctionHealth,
    FunctionQuery, FunctionRevision, Invocation, InvocationRecord, RiskLevel,
};
use crate::shared::content::CapabilityResultContent;
use crate::shared::model_capabilities::{CapabilityResult, CapabilityResultBody};
use crate::shared::paths::files;
use crate::shared::profile::CapabilityExecutionPolicySpec;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::error_mapping::engine_error_to_capability_error;
use crate::shared::server::errors::{self as capability_error_codes, CapabilityError};

const DEFAULT_LIMIT: usize = 12;
const MAX_LIMIT: usize = 50;
static IN_FLIGHT_VECTOR_WARMUP_SIGNATURE: AtomicU64 = AtomicU64::new(0);

pub(crate) async fn search_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let params = &invocation.payload;
    let queries = search_queries(params)?;
    let limit = u64_field(params, "limit")
        .map(|value| value.clamp(1, MAX_LIMIT as u64) as usize)
        .unwrap_or(DEFAULT_LIMIT);
    let cursor_offset = parse_cursor(params)?;
    let filters = CapabilitySearchFilters {
        kind: string_field(params, "kind"),
        contract_id: string_field(params, "contractId")
            .or_else(|| string_field(params, "contract_id")),
        namespace: string_field(params, "namespace"),
        plugin_id: string_field(params, "pluginId").or_else(|| string_field(params, "plugin_id")),
        effect: effect_field(params, "effect")?,
        risk_max: risk_field(params, "riskMax")?,
        trust_tier_min: string_field(params, "trustTierMin")
            .or_else(|| string_field(params, "trust_tier_min")),
        include_unavailable: bool_field(params, "includeUnavailable").unwrap_or(false),
        scope: string_field(params, "scope"),
    };

    let actor = actor_from_invocation(invocation)?;
    let functions = deps
        .engine_host
        .discover(&filters.function_query(actor))
        .await;

    let catalog_revision = deps.engine_host.catalog_revision().await;
    let snapshot = CapabilityRegistrySnapshot::new(functions, catalog_revision.0);
    let policy = search_policy_from_runtime(invocation)?;
    let allow_degraded_vector_search = allows_degraded_vector_search(&policy);
    let warmup_snapshot = if policy.local_vector {
        Some(snapshot.clone())
    } else {
        None
    };
    let queries_for_index = queries.clone();
    let index_limit = cursor_offset.saturating_add(limit).saturating_add(1);
    let store = deps.registry_store.clone();
    let embedding_provider = deps.embedding_provider.clone();
    let trace_id = invocation.causal_context.trace_id.as_str().to_owned();
    let filters_for_index = filters.clone();
    let catalog_revision_value = catalog_revision.0;
    let search_result = run_blocking_task("capability.search.index", move || {
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        let admin_before = store.admin_status().map_err(registry_store_error)?;
        if registry_needs_metadata_sync(&admin_before, catalog_revision_value) {
            let sync_policy = registry_metadata_sync_policy();
            if let Err(error) =
                store.sync_snapshot(&snapshot, embedding_provider.as_ref(), &sync_policy)
            {
                let _ = store.record_audit_event(
                    "capability.search",
                    Some(&trace_id),
                    json!({
                        "status": "error",
                        "queries": queries_for_index,
                        "catalogRevision": catalog_revision_value,
                        "error": error.clone(),
                    }),
                );
                return Err(registry_store_error(error));
            }
        }
        let mut effective_policy = policy.clone();
        let mut degraded_status = None;
        if allow_degraded_vector_search {
            let admin = store.admin_status().map_err(registry_store_error)?;
            if !admin_vector_ready(&admin) {
                effective_policy.local_vector = false;
                effective_policy.require_local_vector = false;
                degraded_status = Some(degraded_search_status(
                    &admin,
                    &policy,
                    embedding_provider.as_ref(),
                ));
            }
        }
        let mut results = Vec::new();
        for query in &queries_for_index {
            let mut result = store
                .search(
                    query,
                    &filters_for_index,
                    &effective_policy,
                    index_limit,
                    embedding_provider.as_ref(),
                )
                .map_err(registry_store_error)?;
            if let Some(status) = degraded_status.clone() {
                result.status = status;
            }
            results.push((query.clone(), result));
        }
        store
            .record_audit_event(
                "capability.search",
                Some(&trace_id),
                json!({
                    "queries": queries_for_index,
                    "filters": {
                        "kind": filters_for_index.kind,
                        "contractId": filters_for_index.contract_id,
                        "namespace": filters_for_index.namespace,
                        "pluginId": filters_for_index.plugin_id,
                    },
                    "catalogRevision": catalog_revision_value,
                    "indexStatus": results
                        .first()
                        .map(|(_, result)| result.status.clone()),
                }),
            )
            .map_err(registry_store_error)?;
        Ok(results)
    })
    .await;
    let search_results = search_result?;
    if let Some(snapshot) = warmup_snapshot
        && search_results_need_vector_warmup(&search_results)
    {
        schedule_vector_warmup(snapshot, deps);
    }
    render_search_result_value(search_results, catalog_revision.0, cursor_offset, limit)
}

fn search_queries(params: &Value) -> Result<Vec<String>, CapabilityError> {
    if let Some(values) = params.get("queries").and_then(Value::as_array)
        && !values.is_empty()
    {
        let mut queries = Vec::new();
        for value in values.iter().take(8) {
            let Some(query) = value.as_str() else {
                return Err(CapabilityError::InvalidParams {
                    message: "capability search queries must be strings".to_owned(),
                });
            };
            queries.push(query.to_owned());
        }
        return Ok(queries);
    }
    Ok(vec![string_field(params, "query").unwrap_or_default()])
}

fn render_search_result_value(
    search_results: Vec<(String, super::registry::CapabilityIndexSearchResult)>,
    catalog_revision: u64,
    cursor_offset: usize,
    limit: usize,
) -> Result<Value, CapabilityError> {
    if search_results.len() == 1 {
        let (query, search_result) = search_results
            .into_iter()
            .next()
            .expect("single search result exists");
        let next_cursor = if search_result.hits.len() > cursor_offset.saturating_add(limit) {
            Some(cursor_offset.saturating_add(limit).to_string())
        } else {
            None
        };
        let page_hits = search_result
            .hits
            .into_iter()
            .skip(cursor_offset)
            .take(limit)
            .collect::<Vec<_>>();
        let summary = render_search_summary(&query, &page_hits);
        let results =
            serde_json::to_value(&page_hits).map_err(|error| CapabilityError::Internal {
                message: error.to_string(),
            })?;
        return capability_result_value(CapabilityResult {
            content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(summary)]),
            details: Some(json!({
                "query": query,
                "catalogRevision": catalog_revision,
                "results": results,
                "nextCursor": next_cursor,
                "searchMode": search_result.status
            })),
            is_error: None,
            stop_turn: None,
        });
    }

    let mut batch_results = Vec::new();
    let mut summary_lines = Vec::new();
    for (query, search_result) in search_results {
        let next_cursor = if search_result.hits.len() > cursor_offset.saturating_add(limit) {
            Some(cursor_offset.saturating_add(limit).to_string())
        } else {
            None
        };
        let page_hits = search_result
            .hits
            .into_iter()
            .skip(cursor_offset)
            .take(limit)
            .collect::<Vec<_>>();
        let result_count = page_hits.len();
        let query_summary = render_search_summary(&query, &page_hits);
        let results =
            serde_json::to_value(&page_hits).map_err(|error| CapabilityError::Internal {
                message: error.to_string(),
            })?;
        summary_lines.push(format!(
            "## Query: {query}\n{query_summary}\n({result_count} result(s))"
        ));
        batch_results.push(json!({
            "query": query,
            "results": results,
            "nextCursor": next_cursor,
            "searchMode": search_result.status,
        }));
    }
    capability_result_value(CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(format!(
            "Capability batch search completed.\n\n{}",
            summary_lines.join("\n\n")
        ))]),
        details: Some(json!({
            "queries": batch_results,
            "catalogRevision": catalog_revision,
        })),
        is_error: None,
        stop_turn: None,
    })
}

fn parse_cursor(params: &Value) -> Result<usize, CapabilityError> {
    let Some(cursor) = string_field(params, "cursor") else {
        return Ok(0);
    };
    let raw = cursor
        .strip_prefix("offset:")
        .unwrap_or(cursor.as_str())
        .trim();
    raw.parse::<usize>()
        .map_err(|_| CapabilityError::InvalidParams {
            message: format!("Unsupported capability search cursor '{cursor}'"),
        })
}

pub(crate) async fn inspect_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let actor = actor_from_invocation(invocation)?;
    let trace_id = invocation.causal_context.trace_id.as_str().to_owned();
    if let Some(targets) = inspect_targets(&invocation.payload)? {
        let mut inspections = Vec::new();
        let mut summaries = Vec::new();
        for target_payload in targets {
            let inspection = inspect_one(&target_payload, deps, &actor, &trace_id).await?;
            summaries.push(render_inspection_summary(&inspection));
            inspections.push(inspection);
        }
        return capability_result_value(CapabilityResult {
            content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(format!(
                "Inspected {} capability target(s): {}",
                inspections.len(),
                summaries.join("; ")
            ))]),
            details: Some(json!({ "inspections": inspections })),
            is_error: None,
            stop_turn: None,
        });
    }
    let details = inspect_one(&invocation.payload, deps, &actor, &trace_id).await?;
    let summary = render_inspection_summary(&details);
    capability_result_value(CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(summary)]),
        details: Some(details),
        is_error: None,
        stop_turn: None,
    })
}

async fn inspect_one(
    params: &Value,
    deps: &Deps,
    actor: &ActorContext,
    trace_id: &str,
) -> Result<Value, CapabilityError> {
    let target = resolve_target(params, deps, actor).await?;
    let inspection = target.entry.inspection(target.binding_decision.clone());
    {
        let store = deps.registry_store.clone();
        let entry = target.entry.clone();
        let decision = target.binding_decision.clone();
        let handle = inspection.inspection_handle.clone();
        let trace_id = trace_id.to_owned();
        run_blocking_task("capability.inspect.record", move || {
            let mut store = store.lock().map_err(|_| CapabilityError::Internal {
                message: "capability registry store mutex poisoned".to_owned(),
            })?;
            store
                .record_inspection(&handle, &entry, &decision)
                .map_err(registry_store_error)?;
            store
                .record_audit_event(
                    "capability.inspect",
                    Some(&trace_id),
                    json!({
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
    }
    serde_json::to_value(inspection).map_err(|error| CapabilityError::Internal {
        message: error.to_string(),
    })
}

fn inspect_targets(params: &Value) -> Result<Option<Vec<Value>>, CapabilityError> {
    let Some(values) = params.get("targets").and_then(Value::as_array) else {
        return Ok(None);
    };
    if values.is_empty() {
        return Ok(None);
    }
    let mut targets = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    for value in values.iter().take(8) {
        let target = if let Some(id) = value.as_str() {
            json!({ "capabilityId": id })
        } else if value.is_object() {
            value.clone()
        } else {
            return Err(CapabilityError::InvalidParams {
                message: "capability inspect targets must be objects or capability id strings"
                    .to_owned(),
            });
        };
        if parse_target(&target).is_none() {
            return Err(CapabilityError::InvalidParams {
                message: "Each capability inspect target must include one of functionId, implementationId, capabilityId, or contractId".to_owned(),
            });
        }
        let key = serde_json::to_string(&target).map_err(|error| CapabilityError::Internal {
            message: error.to_string(),
        })?;
        if seen.insert(key) {
            targets.push(target);
        }
    }
    Ok(Some(targets))
}

pub(crate) async fn execute_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    if is_orchestrated_execute_payload(&invocation.payload) {
        return execute_orchestrated_value(invocation, deps).await;
    }
    let mode = string_field(&invocation.payload, "mode").unwrap_or_else(|| "invoke".to_owned());
    match mode.as_str() {
        "invoke" => execute_invoke_value(invocation, deps).await,
        "program" => execute_program_value(invocation, deps).await,
        other => Err(CapabilityError::InvalidParams {
            message: format!("Unsupported capability execute mode '{other}'"),
        }),
    }
}

#[derive(Debug)]
struct OrchestratedExecuteInput {
    intent: Option<String>,
    target_params: Option<Value>,
    arguments: Value,
    constraints: Value,
    idempotency_key: Option<String>,
    reason: Option<String>,
    corrections: Vec<Value>,
}

fn is_orchestrated_execute_payload(params: &Value) -> bool {
    params.get("intent").is_some()
        || params.get("target").is_some()
        || params.get("arguments").is_some()
        || params.get("constraints").is_some()
        || (params.get("mode").is_none() && params.get("payload").is_some())
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
            let Some(intent) = input.intent.as_deref() else {
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
                    true,
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
                        true,
                    );
                }
                IntentResolveOutcome::NeedsSelection {
                    candidates,
                    search_status,
                } => {
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
                        "Multiple visible capabilities match that intent. Re-run execute with target set to the intended capability.",
                        diagnostics,
                        true,
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
                true,
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
            record_orchestration_audit(deps, invocation, diagnostics).await?;
            return Err(error);
        }
    };
    let function = target.entry.function.clone();
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
    normalize_target_specific_arguments(&function, &mut input.arguments, &mut input.corrections);
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
    let mut result = match execute_invoke_value(&prepared_invocation, deps).await {
        Ok(result) => result,
        Err(error) => {
            let diagnostics = orchestration_details(
                &orchestration_id,
                "run_failed",
                input.intent.as_deref(),
                Some(corrected_request),
                &input,
                json!({
                    "phase": "run",
                    "prepare": prepare_diagnostics,
                    "error": capability_error_details(&error),
                }),
                Vec::new(),
            );
            record_orchestration_audit(deps, invocation, diagnostics).await?;
            return Err(error);
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
    let diagnostics = orchestration_details(
        &orchestration_id,
        &result_status,
        input.intent.as_deref(),
        Some(corrected_request),
        &input,
        prepare_diagnostics,
        orchestration_child_invocations(&result),
    );
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

fn parse_orchestrated_execute_input(
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

    normalize_nested_wrapper_shape(
        &mut arguments,
        &mut target_params,
        &mut idempotency_key,
        &mut reason,
        &mut corrections,
    )?;

    Ok(OrchestratedExecuteInput {
        intent,
        target_params,
        arguments,
        constraints,
        idempotency_key,
        reason,
        corrections,
    })
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

fn normalize_target_specific_arguments(
    function: &FunctionDefinition,
    arguments: &mut Value,
    corrections: &mut Vec<Value>,
) {
    if function.id.as_str() != "process::run" {
        return;
    }
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
    let catalog_revision = deps.engine_host.catalog_revision().await;
    let snapshot = CapabilityRegistrySnapshot::new(functions, catalog_revision.0);
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
    let argument_rejected_candidates =
        apply_argument_schema_fit_filter(arguments, &snapshot, &mut executable_hits);
    let candidates = executable_hits
        .iter()
        .map(orchestration_candidate_summary)
        .collect::<Vec<_>>();
    let search_status = serde_json::to_value(&search.status).unwrap_or(Value::Null);
    let Some(selected) = executable_hits.first() else {
        return Ok(IntentResolveOutcome::NeedsCapability {
            candidates,
            search_status,
        });
    };
    if selected.fused_score <= 0.0 {
        return Ok(IntentResolveOutcome::NeedsCapability {
            candidates,
            search_status,
        });
    }
    let selected_has_strong_name_match = intent_strongly_matches_hit(intent, selected);
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

fn intent_strongly_matches_hit(intent: &str, hit: &CapabilityIndexHit) -> bool {
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

fn validate_orchestration_constraint_shape(constraints: &Value) -> Result<(), CapabilityError> {
    validate_orchestration_constraint_keys(constraints)?;
    let _ = risk_field(constraints, "riskMax")?;
    let _ = effect_field(constraints, "effect")?;
    let _ = optional_string_array_field(constraints, "allowedContracts")?;
    let _ = optional_string_array_field(constraints, "allowedNamespaces")?;
    Ok(())
}

fn validate_orchestration_constraints(
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

fn orchestration_constraints_allow_hit(
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

fn prepared_execute_payload(target_params: &Value, input: &OrchestratedExecuteInput) -> Value {
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

fn deterministic_intent_route(
    intent: &str,
    arguments: &Value,
    snapshot: &CapabilityRegistrySnapshot,
    constraints: &Value,
) -> Result<Option<CapabilityIndexHit>, CapabilityError> {
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

fn apply_deterministic_intent_route(
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

fn apply_argument_schema_fit_filter(
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
    normalize_target_specific_arguments(
        &entry.function,
        &mut normalized_arguments,
        &mut ignored_corrections,
    );
    match validate_target_payload(entry, &normalized_arguments) {
        Ok(()) => ArgumentSchemaFit::Compatible,
        Err(error) if is_missing_required_argument_error(&error) => {
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
    let Some(path) = arguments.get("path").and_then(Value::as_str) else {
        return false;
    };
    if path.trim().is_empty() {
        return false;
    }
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
    asks_for_read && !asks_for_write
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

fn orchestration_hit_from_entry(
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
    value
        .get("details")
        .and_then(|details| details.get("childInvocations"))
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

fn orchestration_result(
    status: &str,
    message: &str,
    diagnostics: Value,
    is_error: bool,
) -> Result<Value, CapabilityError> {
    capability_result_value(CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            message.to_owned(),
        )]),
        details: Some(json!({
            "status": status,
            "orchestration": diagnostics,
            "childInvocationCreated": false,
            "approvalCreated": false,
            "resourceRefs": [],
        })),
        is_error: is_error.then_some(true),
        stop_turn: None,
    })
}

fn capability_error_details(error: &CapabilityError) -> Value {
    json!({
        "code": error.code(),
        "message": error.to_string(),
        "details": error.details(),
    })
}

async fn record_orchestration_audit(
    deps: &Deps,
    invocation: &Invocation,
    diagnostics: Value,
) -> Result<(), CapabilityError> {
    let store = deps.registry_store.clone();
    let trace_id = invocation.causal_context.trace_id.as_str().to_owned();
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

pub(crate) async fn status_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    sync_registry_for_admin(invocation, deps).await?;
    let include_snapshot = bool_field(&invocation.payload, "includeSnapshot").unwrap_or(false);
    let store = deps.registry_store.clone();
    let mut status = run_blocking_task("capability.status", move || {
        let store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store.admin_status().map_err(registry_store_error)
    })
    .await?;
    status["serverProfile"] = json!({
        "profileName": deps.profile_runtime.current().profile_name(),
        "profileHash": deps.profile_runtime.current().spec_hash(),
    });
    if include_snapshot {
        let snapshot = registry_snapshot_from_store(deps).await?;
        status["snapshot"] = snapshot;
    }
    record_admin_audit(
        deps,
        invocation,
        "capability.status",
        json!({"includeSnapshot": include_snapshot}),
    )
    .await?;
    Ok(status)
}

pub(crate) async fn registry_snapshot_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    sync_registry_for_admin(invocation, deps).await?;
    let mut snapshot = registry_snapshot_from_store(deps).await?;
    if !bool_field(&invocation.payload, "includeDocuments").unwrap_or(true) {
        snapshot["documents"] = json!([]);
    }
    if !bool_field(&invocation.payload, "includeBindings").unwrap_or(true) {
        snapshot["bindings"] = json!([]);
    }
    record_admin_audit(
        deps,
        invocation,
        "capability.registry_snapshot",
        json!({
            "includeDocuments": bool_field(&invocation.payload, "includeDocuments").unwrap_or(true),
            "includeBindings": bool_field(&invocation.payload, "includeBindings").unwrap_or(true),
        }),
    )
    .await?;
    Ok(snapshot)
}

pub(crate) async fn audit_query_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let event_type = string_field(&invocation.payload, "eventType");
    let trace_id = string_field(&invocation.payload, "traceId");
    let orchestration_status = string_field(&invocation.payload, "orchestrationStatus");
    let correction_kind = string_field(&invocation.payload, "correctionKind");
    let phase = string_field(&invocation.payload, "phase");
    let orchestration_filters_present =
        orchestration_status.is_some() || correction_kind.is_some() || phase.is_some();
    let limit = u64_field(&invocation.payload, "limit")
        .map(|value| value.clamp(1, 200) as usize)
        .unwrap_or(50);
    let reveal_payloads = bool_field(&invocation.payload, "revealPayloads").unwrap_or(false);
    let store = deps.registry_store.clone();
    let event_type_for_query = event_type
        .clone()
        .or_else(|| orchestration_filters_present.then(|| "capability.orchestration".to_owned()));
    let trace_id_for_query = trace_id.clone();
    let query_limit = if orchestration_filters_present {
        200
    } else {
        limit
    };
    let reveal_for_query = reveal_payloads || orchestration_filters_present;
    let result = run_blocking_task("capability.audit_query", move || {
        let store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .audit_query(
                event_type_for_query.as_deref(),
                trace_id_for_query.as_deref(),
                query_limit,
                reveal_for_query,
            )
            .map_err(registry_store_error)
    })
    .await?;
    let result = if orchestration_filters_present {
        filter_orchestration_audit_result(
            result,
            orchestration_status.as_deref(),
            correction_kind.as_deref(),
            phase.as_deref(),
            limit,
            reveal_payloads,
        )?
    } else {
        result
    };
    record_admin_audit(
        deps,
        invocation,
        "capability.audit_query",
        json!({
            "eventType": event_type,
            "traceId": trace_id,
            "orchestrationStatus": orchestration_status,
            "correctionKind": correction_kind,
            "phase": phase,
            "limit": limit,
            "revealPayloads": reveal_payloads,
        }),
    )
    .await?;
    Ok(result)
}

fn filter_orchestration_audit_result(
    result: Value,
    orchestration_status: Option<&str>,
    correction_kind: Option<&str>,
    phase: Option<&str>,
    limit: usize,
    reveal_payloads: bool,
) -> Result<Value, CapabilityError> {
    let events = result
        .get("events")
        .and_then(Value::as_array)
        .ok_or_else(|| CapabilityError::Internal {
            message: "capability audit query returned invalid events".to_owned(),
        })?;
    let mut filtered = Vec::new();
    for event in events {
        if !audit_event_matches_orchestration_filters(
            event,
            orchestration_status,
            correction_kind,
            phase,
        ) {
            continue;
        }
        let event = if reveal_payloads {
            let mut event = event.clone();
            event["redacted"] = json!(false);
            event
        } else {
            redact_orchestration_audit_event(event.clone())
        };
        filtered.push(event);
        if filtered.len() >= limit {
            break;
        }
    }
    Ok(json!({
        "events": filtered,
        "redacted": !reveal_payloads,
        "filters": {
            "orchestrationStatus": orchestration_status,
            "correctionKind": correction_kind,
            "phase": phase,
        }
    }))
}

fn audit_event_matches_orchestration_filters(
    event: &Value,
    orchestration_status: Option<&str>,
    correction_kind: Option<&str>,
    phase: Option<&str>,
) -> bool {
    let payload = event.get("payload").unwrap_or(&Value::Null);
    if let Some(expected) = orchestration_status
        && payload.get("status").and_then(Value::as_str) != Some(expected)
    {
        return false;
    }
    if let Some(expected) = phase
        && payload
            .get("phaseDetails")
            .and_then(|details| details.get("phase"))
            .and_then(Value::as_str)
            != Some(expected)
    {
        return false;
    }
    if let Some(expected) = correction_kind {
        let has_correction = payload
            .get("correctionsApplied")
            .and_then(Value::as_array)
            .is_some_and(|corrections| {
                corrections.iter().any(|correction| {
                    correction.get("kind").and_then(Value::as_str) == Some(expected)
                })
            });
        if !has_correction {
            return false;
        }
    }
    true
}

fn redact_orchestration_audit_event(mut event: Value) -> Value {
    let payload = event.get("payload").cloned().unwrap_or(Value::Null);
    let keys = payload
        .as_object()
        .map(|object| object.keys().cloned().collect::<Vec<_>>())
        .unwrap_or_default();
    event["payloadSummary"] = orchestration_audit_payload_summary(&payload);
    event["payload"] = json!({
        "redacted": true,
        "keys": keys,
    });
    event["redacted"] = json!(true);
    event
}

fn orchestration_audit_payload_summary(payload: &Value) -> Value {
    let Some(object) = payload.as_object() else {
        return json!({ "type": audit_payload_type(payload) });
    };
    let mut summary = Map::new();
    for key in [
        "orchestrationId",
        "status",
        "intent",
        "correctionConfidence",
    ] {
        if let Some(value) = object.get(key) {
            summary.insert(key.to_owned(), value.clone());
        }
    }
    if let Some(phase) = object
        .get("phaseDetails")
        .and_then(|details| details.get("phase"))
        .cloned()
    {
        summary.insert("phase".to_owned(), phase);
    }
    let correction_kinds = object
        .get("correctionsApplied")
        .and_then(Value::as_array)
        .map(|corrections| {
            corrections
                .iter()
                .filter_map(|correction| correction.get("kind").and_then(Value::as_str))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if !correction_kinds.is_empty() {
        summary.insert("correctionKinds".to_owned(), json!(correction_kinds));
    }
    summary.insert("keyCount".to_owned(), json!(object.len()));
    Value::Object(summary)
}

fn audit_payload_type(payload: &Value) -> &'static str {
    match payload {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

pub(crate) async fn program_run_list_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let trace_id = string_field(&invocation.payload, "traceId");
    let status = string_field(&invocation.payload, "status");
    let limit = u64_field(&invocation.payload, "limit")
        .map(|value| value.clamp(1, 200) as usize)
        .unwrap_or(50);
    let reveal_payloads = bool_field(&invocation.payload, "revealPayloads").unwrap_or(false);
    let store = deps.registry_store.clone();
    let trace_id_for_query = trace_id.clone();
    let status_for_query = status.clone();
    let result = run_blocking_task("capability.program_run_list", move || {
        let store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .program_run_query(
                trace_id_for_query.as_deref(),
                status_for_query.as_deref(),
                limit,
                reveal_payloads,
            )
            .map_err(registry_store_error)
    })
    .await?;
    record_admin_audit(
        deps,
        invocation,
        "capability.program_run_list",
        json!({
            "traceId": trace_id,
            "status": status,
            "limit": limit,
            "revealPayloads": reveal_payloads,
        }),
    )
    .await?;
    Ok(result)
}

pub(crate) async fn binding_list_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    sync_registry_for_admin(invocation, deps).await?;
    let store = deps.registry_store.clone();
    let result = run_blocking_task("capability.binding_list", move || {
        let store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store.list_bindings().map_err(registry_store_error)
    })
    .await?;
    record_admin_audit(deps, invocation, "capability.binding_list", json!({})).await?;
    Ok(result)
}

pub(crate) async fn binding_set_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    sync_registry_for_admin(invocation, deps).await?;
    let contract_id = required_string(&invocation.payload, "contractId")?;
    let selected_implementation = required_string(&invocation.payload, "selectedImplementation")?;
    let scope_kind =
        string_field(&invocation.payload, "scopeKind").unwrap_or_else(|| "system".to_owned());
    let scope_value =
        string_field(&invocation.payload, "scopeValue").unwrap_or_else(|| "default".to_owned());
    validate_binding_scope(&scope_kind)?;
    let selection_policy = string_field(&invocation.payload, "selectionPolicy")
        .unwrap_or_else(|| "explicit".to_owned());
    let secondary_implementations =
        string_array_field(&invocation.payload, "secondaryImplementations")?;
    let priority = u64_field(&invocation.payload, "priority").unwrap_or(0) as i64;
    let enabled = bool_field(&invocation.payload, "enabled").unwrap_or(true);
    ensure_implementation_known(deps, &selected_implementation).await?;
    let store = deps.registry_store.clone();
    let contract_for_result = contract_id.clone();
    let implementation_for_result = selected_implementation.clone();
    let scope_kind_for_result = scope_kind.clone();
    let scope_value_for_result = scope_value.clone();
    let selection_policy_for_result = selection_policy.clone();
    let secondary_for_result = secondary_implementations.clone();
    run_blocking_task("capability.binding_set", move || {
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .upsert_binding(
                &contract_id,
                &scope_kind,
                &scope_value,
                &selected_implementation,
                &selection_policy,
                &secondary_implementations,
                priority,
                enabled,
            )
            .map_err(registry_store_error)
    })
    .await?;
    let result = json!({
        "binding": {
            "contractId": contract_for_result,
            "scopeKind": scope_kind_for_result,
            "scopeValue": scope_value_for_result,
            "selectedImplementation": implementation_for_result,
            "selectionPolicy": selection_policy_for_result,
            "secondaryImplementations": secondary_for_result,
            "priority": priority,
            "enabled": enabled,
        }
    });
    record_admin_audit(deps, invocation, "capability.binding_set", result.clone()).await?;
    Ok(result)
}

pub(crate) async fn plugin_list_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    sync_registry_for_admin(invocation, deps).await?;
    let store = deps.registry_store.clone();
    let result = run_blocking_task("capability.plugin_list", move || {
        let store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store.list_plugins().map_err(registry_store_error)
    })
    .await?;
    record_admin_audit(deps, invocation, "capability.plugin_list", json!({})).await?;
    Ok(result)
}

pub(crate) async fn plugin_inspect_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    sync_registry_for_admin(invocation, deps).await?;
    let plugin_id = required_string(&invocation.payload, "pluginId")?;
    let store = deps.registry_store.clone();
    let plugin_id_for_query = plugin_id.clone();
    let result = run_blocking_task("capability.plugin_inspect", move || {
        let store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .plugin_inspect(&plugin_id_for_query)
            .map_err(registry_store_error)?
            .ok_or_else(|| CapabilityError::NotFound {
                code: "CAPABILITY_PLUGIN_NOT_FOUND".to_owned(),
                message: format!("Capability plugin '{plugin_id_for_query}' was not found"),
            })
    })
    .await?;
    record_admin_audit(
        deps,
        invocation,
        "capability.plugin_inspect",
        json!({"pluginId": plugin_id}),
    )
    .await?;
    Ok(result)
}

pub(crate) async fn plugin_install_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    upsert_plugin_from_payload(invocation, deps, "install").await
}

pub(crate) async fn plugin_update_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    upsert_plugin_from_payload(invocation, deps, "update").await
}

pub(crate) async fn plugin_set_state_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let plugin_id = required_string(&invocation.payload, "pluginId")?;
    let state = required_string(&invocation.payload, "state")?;
    validate_conformance_state(&state)?;
    let store = deps.registry_store.clone();
    let plugin_id_for_update = plugin_id.clone();
    let state_for_update = state.clone();
    run_blocking_task("capability.plugin_set_state", move || {
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .set_plugin_state(&plugin_id_for_update, &state_for_update)
            .map_err(registry_store_error)
    })
    .await?;
    let result = json!({"pluginId": plugin_id, "state": state});
    record_admin_audit(
        deps,
        invocation,
        "capability.plugin_set_state",
        result.clone(),
    )
    .await?;
    Ok(result)
}

pub(crate) async fn plugin_promote_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let plugin_id = required_string(&invocation.payload, "pluginId")?;
    let target_visibility = required_string(&invocation.payload, "targetVisibility")?;
    if !matches!(target_visibility.as_str(), "workspace" | "system") {
        return Err(CapabilityError::InvalidParams {
            message: "targetVisibility must be workspace or system".to_owned(),
        });
    }
    let inspected = inspect_plugin_manifest(deps, &plugin_id).await?;
    let manifest_value =
        inspected
            .get("manifest")
            .cloned()
            .ok_or_else(|| CapabilityError::Internal {
                message: "plugin inspect did not return a manifest".to_owned(),
            })?;
    let mut manifest: CapabilityPluginManifest =
        serde_json::from_value(manifest_value).map_err(|error| CapabilityError::Internal {
            message: format!("decode plugin manifest: {error}"),
        })?;
    if manifest.conformance_state != "healthy" {
        return Err(CapabilityError::Custom {
            code: "PLUGIN_PROMOTION_REQUIRES_HEALTHY_CONFORMANCE".to_owned(),
            message: format!(
                "{} cannot be promoted while conformanceState={}",
                manifest.id, manifest.conformance_state
            ),
            details: Some(json!({
                "pluginId": manifest.id,
                "conformanceState": manifest.conformance_state,
            })),
        });
    }
    manifest.visibility_ceiling = target_visibility.clone();
    let catalog_revision = deps.engine_host.catalog_revision().await.0;
    let store = deps.registry_store.clone();
    let manifest_for_update = manifest.clone();
    run_blocking_task("capability.plugin_promote", move || {
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .upsert_plugin_manifest(&manifest_for_update, "healthy", catalog_revision)
            .map_err(registry_store_error)
    })
    .await?;
    let result = json!({
        "pluginId": plugin_id,
        "targetVisibility": target_visibility,
        "state": "healthy",
    });
    record_admin_audit(
        deps,
        invocation,
        "capability.plugin_promote",
        result.clone(),
    )
    .await?;
    Ok(result)
}

pub(crate) async fn conformance_run_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    sync_registry_for_admin(invocation, deps).await?;
    let plugin_id = required_string(&invocation.payload, "pluginId")?;
    let requested_implementation = string_field(&invocation.payload, "implementationId");
    let inspected = inspect_plugin_manifest(deps, &plugin_id).await?;
    let manifest_value =
        inspected
            .get("manifest")
            .cloned()
            .ok_or_else(|| CapabilityError::Internal {
                message: "plugin inspect did not return a manifest".to_owned(),
            })?;
    let manifest: CapabilityPluginManifest =
        serde_json::from_value(manifest_value).map_err(|error| CapabilityError::Internal {
            message: format!("decode plugin manifest: {error}"),
        })?;
    let implementations = inspected
        .get("implementations")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let known = implementations
        .iter()
        .filter_map(|implementation| {
            implementation
                .get("implementationId")
                .and_then(Value::as_str)
        })
        .map(ToOwned::to_owned)
        .collect::<std::collections::BTreeSet<_>>();
    let expected = requested_implementation
        .clone()
        .map(|implementation| vec![implementation])
        .unwrap_or_else(|| manifest.provided_implementations.clone());
    let missing = expected
        .iter()
        .filter(|implementation| !known.contains(*implementation))
        .cloned()
        .collect::<Vec<_>>();
    let next_state = if missing.is_empty() {
        "healthy"
    } else {
        "degraded"
    };
    let store = deps.registry_store.clone();
    let plugin_for_update = plugin_id.clone();
    let expected_for_update = expected.clone();
    let next_state_for_update = next_state.to_owned();
    run_blocking_task("capability.conformance_run", move || {
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .set_plugin_state(&plugin_for_update, &next_state_for_update)
            .map_err(registry_store_error)?;
        for implementation_id in expected_for_update {
            let _ = store.set_implementation_state(&implementation_id, &next_state_for_update);
        }
        Ok(())
    })
    .await?;
    let result = json!({
        "pluginId": plugin_id,
        "implementationId": requested_implementation,
        "state": next_state,
        "checks": {
            "manifestImplementationsPresent": missing.is_empty(),
            "missingImplementations": missing,
        }
    });
    record_admin_audit(
        deps,
        invocation,
        "capability.conformance_run",
        result.clone(),
    )
    .await?;
    Ok(result)
}

pub(crate) async fn implementation_set_state_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let implementation_id = required_string(&invocation.payload, "implementationId")?;
    let state = required_string(&invocation.payload, "state")?;
    validate_conformance_state(&state)?;
    let store = deps.registry_store.clone();
    let implementation_for_update = implementation_id.clone();
    let state_for_update = state.clone();
    run_blocking_task("capability.implementation_set_state", move || {
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .set_implementation_state(&implementation_for_update, &state_for_update)
            .map_err(registry_store_error)
    })
    .await?;
    let result = json!({"implementationId": implementation_id, "state": state});
    record_admin_audit(
        deps,
        invocation,
        "capability.implementation_set_state",
        result.clone(),
    )
    .await?;
    Ok(result)
}

pub(crate) async fn policy_get_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let policy_id = string_field(&invocation.payload, "policyId");
    let current = deps.profile_runtime.current();
    let document = current.execution_spec().document();
    let policies = if let Some(policy_id) = &policy_id {
        let policy = document
            .capability_execution_policies
            .get(policy_id)
            .ok_or_else(|| CapabilityError::NotFound {
                code: "CAPABILITY_POLICY_NOT_FOUND".to_owned(),
                message: format!("Capability policy '{policy_id}' was not found"),
            })?;
        json!({ policy_id: policy })
    } else {
        serde_json::to_value(&document.capability_execution_policies).map_err(|error| {
            CapabilityError::Internal {
                message: format!("serialize capability execution policies: {error}"),
            }
        })?
    };
    let result = json!({
        "profileName": current.profile_name(),
        "profileHash": current.spec_hash(),
        "policyId": policy_id,
        "capabilityExecutionPolicies": policies,
    });
    record_admin_audit(deps, invocation, "capability.policy_get", result.clone()).await?;
    Ok(result)
}

pub(crate) async fn policy_validate_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let raw_policy = invocation.payload.get("policy").cloned().ok_or_else(|| {
        CapabilityError::InvalidParams {
            message: "policy is required".to_owned(),
        }
    })?;
    let validation = validate_capability_execution_policy_payload(raw_policy);
    record_admin_audit(
        deps,
        invocation,
        "capability.policy_validate",
        json!({
            "policyId": string_field(&invocation.payload, "policyId"),
            "valid": validation.get("valid").and_then(Value::as_bool).unwrap_or(false),
        }),
    )
    .await?;
    Ok(validation)
}

pub(crate) async fn policy_update_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let policy_id = required_string(&invocation.payload, "policyId")?;
    validate_profile_id(&policy_id)?;
    let raw_policy = invocation.payload.get("policy").cloned().ok_or_else(|| {
        CapabilityError::InvalidParams {
            message: "policy is required".to_owned(),
        }
    })?;
    let policy: CapabilityExecutionPolicySpec =
        serde_json::from_value(raw_policy).map_err(|error| CapabilityError::InvalidParams {
            message: format!("Invalid capability execution policy: {error}"),
        })?;
    let runtime = deps.profile_runtime.clone();
    let path = current_profile_toml_path(deps);
    let policy_id_for_write = policy_id.clone();
    let result = run_blocking_task("capability.policy_update", move || {
        write_capability_execution_policy_to_profile_and_reload(
            &path,
            &policy_id_for_write,
            &policy,
            runtime.as_ref(),
        )?;
        Ok(json!({
            "policyId": policy_id_for_write,
            "profilePath": path.display().to_string(),
            "updated": true,
        }))
    })
    .await?;
    record_admin_audit(deps, invocation, "capability.policy_update", result.clone()).await?;
    Ok(result)
}

pub(crate) async fn render_capability_primer(
    engine_host: &crate::engine::EngineHostHandle,
    session_id: &str,
    workspace_id: Option<&str>,
    policy: &CapabilityContextPrimerPolicy,
) -> Result<Option<String>, CapabilityError> {
    let mut actor = ActorContext::new(
        crate::engine::ActorId::new(format!("agent:{session_id}")).map_err(|error| {
            CapabilityError::Internal {
                message: error.to_string(),
            }
        })?,
        ActorKind::Agent,
        AuthorityGrantId::new("agent-capability-primer").map_err(|error| {
            CapabilityError::Internal {
                message: error.to_string(),
            }
        })?,
    )
    .with_scope("capability.search")
    .with_scope("capability.inspect")
    .with_scope("capability.execute")
    .with_session_id(session_id.to_owned());
    if let Some(workspace_id) = workspace_id {
        actor = actor.with_workspace_id(workspace_id.to_owned());
    }
    let functions = engine_host
        .discover(&FunctionQuery {
            actor: Some(actor),
            health: Some(FunctionHealth::Healthy),
            ..FunctionQuery::default()
        })
        .await;
    let revision = engine_host.catalog_revision().await;
    let snapshot = CapabilityRegistrySnapshot::new(functions, revision.0);
    Ok(render_primer_from_snapshot(&snapshot, policy))
}

async fn execute_invoke_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let actor = actor_from_invocation(invocation)?;
    let target = resolve_target(&invocation.payload, deps, &actor).await?;
    let function = target.entry.function.clone();
    if is_capability_primitive(&function) {
        return Err(CapabilityError::InvalidParams {
            message: "execute cannot recursively invoke capability primitives. This call is already the execute primitive; set target to the real capability, for example process::run, and put only that target's arguments inside arguments.".to_owned(),
        });
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
        return preflight_rejection_result(&function, &target, error, "target_policy_rejected");
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
            })
            .await
            .map_err(engine_error_to_capability_error)?;
        return await_approval_result(invocation, deps, &function, &target, approval).await;
    }
    let result = deps.engine_host.invoke(child).await;
    if let Some(error) = result.error.clone() {
        return Err(engine_error_to_capability_error(error));
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

fn preflight_rejection_result(
    function: &FunctionDefinition,
    target: &ResolvedCapabilityTarget,
    error: CapabilityError,
    status: &str,
) -> Result<Value, CapabilityError> {
    let code = error.code().to_owned();
    let details = error.details();
    let message = error.to_string();
    let guidance = preflight_guidance(status, details.as_ref());
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
            "approvalCreated": false,
            "resourceRefs": []
        })),
        is_error: Some(true),
        stop_turn: None,
    })
}

fn payload_preflight_status(error: &CapabilityError) -> &'static str {
    if is_missing_required_argument_error(error) {
        "needs_input"
    } else {
        "target_payload_invalid"
    }
}

fn is_missing_required_argument_error(error: &CapabilityError) -> bool {
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
    json!({
        "kind": "provide_missing_arguments",
        "message": "Re-run execute with the same selected target and provide the missing fields inside execute.arguments.",
        "missingFields": missing_fields,
        "missingArgumentPaths": argument_paths,
    })
}

fn child_execute_causal_context(
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

fn approved_execution_result(
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

fn approval_was_replayed_for_invocation(
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
            "traceId": approval.trace_id.as_str()
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

fn approval_child_invocation_ids_from_records(
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

async fn execute_program_value(
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

struct ResolvedCapabilityTarget {
    entry: super::registry::CapabilityRegistryEntry,
    binding_decision: CapabilityBindingDecision,
}

async fn resolve_target(
    params: &Value,
    deps: &Deps,
    actor: &ActorContext,
) -> Result<ResolvedCapabilityTarget, CapabilityError> {
    let Some(target) = parse_target(params) else {
        return Err(CapabilityError::InvalidParams {
            message: "Pass one of functionId, implementationId, capabilityId, or contractId"
                .to_owned(),
        });
    };
    let functions = deps
        .engine_host
        .discover(&FunctionQuery {
            actor: Some(actor.clone()),
            health: Some(FunctionHealth::Healthy),
            ..FunctionQuery::default()
        })
        .await;
    let catalog_revision = deps.engine_host.catalog_revision().await;
    let snapshot = CapabilityRegistrySnapshot::new(functions, catalog_revision.0);
    let candidates = snapshot.find_candidates(&target);
    let store = deps.registry_store.clone();
    let embedding_provider = deps.embedding_provider.clone();
    let target_for_resolver = target.clone();
    let actor_session_id = actor.session_id.as_deref().map(ToOwned::to_owned);
    let actor_workspace_id = actor.workspace_id.as_deref().map(ToOwned::to_owned);
    let resolved = run_blocking_task("capability.binding.resolve", move || {
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        let sync_policy = registry_metadata_sync_policy();
        store
            .sync_snapshot(&snapshot, embedding_provider.as_ref(), &sync_policy)
            .map_err(registry_store_error)?;
        let resolved = binding_decision_with_store(
            store.as_mut(),
            &target_for_resolver,
            &candidates,
            actor_session_id.as_deref(),
            actor_workspace_id.as_deref(),
        )?;
        if let Some((entry, decision)) = &resolved {
            store
                .record_binding_decision(decision, entry)
                .map_err(registry_store_error)?;
            store
                .record_audit_event(
                    "capability.binding",
                    None,
                    json!({
                        "contractId": decision.contract_id,
                        "implementationId": decision.selected_implementation,
                        "functionId": decision.selected_function_id,
                        "selectionPolicy": decision.selection_policy,
                        "catalogRevision": decision.catalog_revision,
                        "schemaDigest": decision.schema_digest,
                        "rejectedCandidates": decision.rejected_candidates,
                    }),
                )
                .map_err(registry_store_error)?;
        }
        Ok(resolved)
    })
    .await?;
    let Some((entry, decision)) = resolved else {
        return Err(CapabilityError::NotFound {
            code: "CAPABILITY_NOT_FOUND".to_owned(),
            message: "No visible healthy capability matches the requested target".to_owned(),
        });
    };
    Ok(ResolvedCapabilityTarget {
        entry,
        binding_decision: decision,
    })
}

async fn validate_inspection_handle(
    deps: &Deps,
    handle: &str,
    entry: CapabilityRegistryEntry,
) -> Result<bool, CapabilityError> {
    let store = deps.registry_store.clone();
    let handle = handle.to_owned();
    run_blocking_task("capability.inspect.validate", move || {
        let store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .validate_inspection(&handle, &entry)
            .map_err(registry_store_error)
    })
    .await
}

fn binding_decision_with_store(
    store: &mut dyn CapabilityRegistryStore,
    target: &CapabilityTarget,
    candidates: &[CapabilityRegistryEntry],
    session_id: Option<&str>,
    workspace_id: Option<&str>,
) -> Result<Option<(CapabilityRegistryEntry, CapabilityBindingDecision)>, CapabilityError> {
    if candidates.is_empty() {
        return Ok(None);
    }
    let explicit = matches!(
        target,
        CapabilityTarget::Function(_) | CapabilityTarget::Implementation(_)
    );
    if explicit {
        let Some((entry, mut decision)) = binding_decision(target, candidates) else {
            return Ok(None);
        };
        ensure_selectable(store, &entry)?;
        decision.selection_policy = "explicit".to_owned();
        decision.rejected_candidates = rejected_candidates_for(candidates, &entry, store)?;
        return Ok(Some((entry, decision)));
    }

    let contract_id = candidates
        .first()
        .map(|entry| entry.contract_id.as_str())
        .unwrap_or_default();
    if let Some(binding) = store
        .active_binding(contract_id, session_id, workspace_id)
        .map_err(registry_store_error)?
        && let Some(entry) = candidates
            .iter()
            .find(|entry| entry.implementation_id == binding.selected_implementation)
            .cloned()
    {
        ensure_selectable(store, &entry)?;
        return Ok(Some((
            entry.clone(),
            decision_for_entry(
                &entry,
                &binding.selection_policy,
                rejected_candidates_for(candidates, &entry, store)?,
            ),
        )));
    }

    let tiers = [
        ("first_party_healthy", &["first_party_signed"][..]),
        ("trusted_healthy", &["trusted_signed"][..]),
        (
            "approved_external_or_session_healthy",
            &[
                "user_installed",
                "session_generated",
                "external_mcp",
                "external_openapi",
            ][..],
        ),
    ];
    for (policy, allowed_tiers) in tiers {
        for entry in candidates {
            if !allowed_tiers.contains(&entry.trust_tier.as_str()) {
                continue;
            }
            if is_selectable(store, entry)? {
                return Ok(Some((
                    entry.clone(),
                    decision_for_entry(
                        entry,
                        policy,
                        rejected_candidates_for(candidates, entry, store)?,
                    ),
                )));
            }
        }
    }
    Ok(None)
}

fn is_selectable(
    store: &mut dyn CapabilityRegistryStore,
    entry: &CapabilityRegistryEntry,
) -> Result<bool, CapabilityError> {
    let state = store
        .implementation_conformance_state(&entry.implementation_id)
        .map_err(registry_store_error)?
        .unwrap_or_else(|| "candidate".to_owned());
    Ok(state == "healthy")
}

fn ensure_selectable(
    store: &mut dyn CapabilityRegistryStore,
    entry: &CapabilityRegistryEntry,
) -> Result<(), CapabilityError> {
    if is_selectable(store, entry)? {
        return Ok(());
    }
    let state = store
        .implementation_conformance_state(&entry.implementation_id)
        .map_err(registry_store_error)?
        .unwrap_or_else(|| "candidate".to_owned());
    Err(CapabilityError::Custom {
        code: "CAPABILITY_IMPLEMENTATION_NOT_SELECTABLE".to_owned(),
        message: format!(
            "{} is not binding-selectable because conformanceState={state}",
            entry.implementation_id
        ),
        details: Some(json!({
            "implementationId": entry.implementation_id,
            "functionId": entry.function_id,
            "conformanceState": state,
        })),
    })
}

fn decision_for_entry(
    entry: &CapabilityRegistryEntry,
    selection_policy: &str,
    rejected_candidates: Vec<CapabilityRejectedCandidate>,
) -> CapabilityBindingDecision {
    CapabilityBindingDecision {
        decision_id: format!("binding_decision_{}", uuid::Uuid::now_v7()),
        contract_id: entry.contract_id.clone(),
        selected_implementation: entry.implementation_id.clone(),
        selected_function_id: entry.function_id.clone(),
        selection_policy: selection_policy.to_owned(),
        rejected_candidates,
        catalog_revision: entry.catalog_revision,
        schema_digest: entry.schema_digest.clone(),
    }
}

fn rejected_candidates_for(
    candidates: &[CapabilityRegistryEntry],
    selected: &CapabilityRegistryEntry,
    store: &mut dyn CapabilityRegistryStore,
) -> Result<Vec<CapabilityRejectedCandidate>, CapabilityError> {
    candidates
        .iter()
        .filter(|entry| entry.implementation_id != selected.implementation_id)
        .map(|entry| {
            let state = store
                .implementation_conformance_state(&entry.implementation_id)
                .map_err(registry_store_error)?
                .unwrap_or_else(|| "candidate".to_owned());
            let reason = if state == "healthy" {
                "lower_precedence_candidate".to_owned()
            } else {
                format!("conformance_state_{state}")
            };
            Ok(CapabilityRejectedCandidate {
                implementation_id: entry.implementation_id.clone(),
                function_id: entry.function_id.clone(),
                reason,
            })
        })
        .collect()
}

fn registry_metadata_sync_policy() -> CapabilitySearchPolicy {
    CapabilitySearchPolicy {
        local_vector: false,
        require_local_vector: false,
        ..CapabilitySearchPolicy::default()
    }
}

fn registry_operator_sync_policy() -> CapabilitySearchPolicy {
    CapabilitySearchPolicy {
        local_vector: true,
        require_local_vector: false,
        allow_lexical_only_when_degraded: true,
        ..CapabilitySearchPolicy::default()
    }
}

fn allows_degraded_vector_search(policy: &CapabilitySearchPolicy) -> bool {
    policy.local_vector && !policy.require_local_vector && policy.allow_lexical_only_when_degraded
}

fn admin_vector_ready(admin: &Value) -> bool {
    admin
        .get("indexStatus")
        .and_then(|status| status.get("state"))
        .and_then(Value::as_str)
        == Some("ready")
}

fn registry_needs_metadata_sync(admin: &Value, catalog_revision: u64) -> bool {
    admin.get("catalogRevision").and_then(Value::as_u64) != Some(catalog_revision)
        || admin.get("documents").and_then(Value::as_u64).unwrap_or(0) == 0
}

fn degraded_search_status(
    admin: &Value,
    policy: &CapabilitySearchPolicy,
    embedding_provider: &dyn super::embeddings::EmbeddingProvider,
) -> CapabilityIndexStatus {
    let index = admin.get("indexStatus").unwrap_or(&Value::Null);
    let state = index
        .get("state")
        .and_then(Value::as_str)
        .unwrap_or("unavailable");
    let degraded_reason = index
        .get("degradedReason")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| {
            if state == "unavailable" {
                "local vector index is warming; lexical capability search returned".to_owned()
            } else {
                format!("local vector index state is {state}; lexical capability search returned")
            }
        });
    CapabilityIndexStatus {
        lexical: policy.lexical,
        local_vector: policy.local_vector,
        cloud_embeddings: false,
        vector_store: index
            .get("vectorStore")
            .and_then(Value::as_str)
            .unwrap_or("sqlite-vec")
            .to_owned(),
        embedding_model: index
            .get("embeddingModel")
            .and_then(Value::as_str)
            .unwrap_or_else(|| embedding_provider.model_id())
            .to_owned(),
        state: state.to_owned(),
        degraded_reason: Some(degraded_reason),
    }
}

fn search_policy_from_runtime(
    invocation: &Invocation,
) -> Result<CapabilitySearchPolicy, CapabilityError> {
    if let Some(raw) = invocation
        .causal_context
        .runtime_metadata("capability.searchPolicy")
    {
        return serde_json::from_str(raw).map_err(|error| CapabilityError::InvalidParams {
            message: format!("Invalid internal capability search policy metadata: {error}"),
        });
    }
    if matches!(
        invocation.causal_context.actor_kind,
        ActorKind::System | ActorKind::Admin
    ) {
        return Ok(CapabilitySearchPolicy::default());
    }
    Err(CapabilityError::Custom {
        code: "CAPABILITY_SEARCH_POLICY_REQUIRED".to_owned(),
        message: "capability::search requires an active profile search policy in runtime metadata"
            .to_owned(),
        details: Some(json!({
            "requiredRuntimeMetadata": "capability.searchPolicy"
        })),
    })
}

fn registry_store_error(error: String) -> CapabilityError {
    if let Some(message) = error.strip_prefix("CAPABILITY_INDEX_UNAVAILABLE: ") {
        return CapabilityError::Custom {
            code: "CAPABILITY_INDEX_UNAVAILABLE".to_owned(),
            message: message.to_owned(),
            details: None,
        };
    }
    CapabilityError::Internal { message: error }
}

async fn sync_registry_for_admin(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<u64, CapabilityError> {
    let actor = actor_from_invocation(invocation)?;
    let functions = deps
        .engine_host
        .discover(&FunctionQuery {
            actor: Some(actor),
            ..FunctionQuery::default()
        })
        .await;
    let catalog_revision = deps.engine_host.catalog_revision().await.0;
    let snapshot = CapabilityRegistrySnapshot::new(functions, catalog_revision);
    let warmup_snapshot = snapshot.clone();
    let store = deps.registry_store.clone();
    let embedding_provider = deps.embedding_provider.clone();
    run_blocking_task("capability.admin.sync_registry", move || {
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .sync_snapshot(
                &snapshot,
                embedding_provider.as_ref(),
                &registry_metadata_sync_policy(),
            )
            .map_err(registry_store_error)?;
        Ok(())
    })
    .await?;
    schedule_vector_warmup(warmup_snapshot, deps);
    Ok(catalog_revision)
}

fn schedule_vector_warmup(snapshot: CapabilityRegistrySnapshot, deps: &Deps) {
    let signature = vector_warmup_signature(&snapshot);
    if IN_FLIGHT_VECTOR_WARMUP_SIGNATURE
        .compare_exchange(0, signature, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return;
    }
    let store = deps.registry_store.clone();
    let embedding_provider = deps.embedding_provider.clone();
    tokio::spawn(async move {
        let result = run_blocking_task("capability.registry.vector_warmup", move || {
            let mut store = store.lock().map_err(|_| CapabilityError::Internal {
                message: "capability registry store mutex poisoned".to_owned(),
            })?;
            store
                .sync_snapshot(
                    &snapshot,
                    embedding_provider.as_ref(),
                    &registry_operator_sync_policy(),
                )
                .map_err(registry_store_error)?;
            Ok(())
        })
        .await;
        IN_FLIGHT_VECTOR_WARMUP_SIGNATURE.store(0, Ordering::SeqCst);
        if let Err(error) = result {
            tracing::warn!(%error, "capability vector warm-up failed");
        }
    });
}

fn search_results_need_vector_warmup(
    search_results: &[(String, super::registry::CapabilityIndexSearchResult)],
) -> bool {
    search_results
        .iter()
        .any(|(_, result)| index_status_needs_vector_warmup(&result.status))
}

fn index_status_needs_vector_warmup(status: &CapabilityIndexStatus) -> bool {
    status.local_vector
        && (status.state != "ready"
            || status
                .degraded_reason
                .as_deref()
                .is_some_and(is_vector_indexing_error))
}

fn is_vector_indexing_error(error: &str) -> bool {
    error.starts_with("CAPABILITY_INDEX_INDEXING:")
}

fn vector_warmup_signature(snapshot: &CapabilityRegistrySnapshot) -> u64 {
    let mut hasher = Sha256::new();
    hasher.update(snapshot.catalog_revision.to_le_bytes());
    for document in snapshot.index_documents() {
        hasher.update(document.kind.as_bytes());
        hasher.update([0]);
        hasher.update(document.contract_id.as_bytes());
        hasher.update([0]);
        hasher.update(document.implementation_id.as_bytes());
        hasher.update([0]);
        hasher.update(document.function_id.as_bytes());
        hasher.update([0]);
        hasher.update(document.text.as_bytes());
        hasher.update([0]);
    }
    let digest = hasher.finalize();
    let mut bytes = [0u8; 8];
    bytes.copy_from_slice(&digest[..8]);
    u64::from_le_bytes(bytes).max(1)
}

async fn registry_snapshot_from_store(deps: &Deps) -> Result<Value, CapabilityError> {
    let store = deps.registry_store.clone();
    run_blocking_task("capability.registry_snapshot.store", move || {
        let store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store.registry_snapshot().map_err(registry_store_error)
    })
    .await
}

async fn record_admin_audit(
    deps: &Deps,
    invocation: &Invocation,
    event_type: &'static str,
    payload: Value,
) -> Result<(), CapabilityError> {
    let store = deps.registry_store.clone();
    let trace_id = invocation.causal_context.trace_id.as_str().to_owned();
    run_blocking_task("capability.admin.audit", move || {
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .record_audit_event(event_type, Some(&trace_id), payload)
            .map_err(registry_store_error)
    })
    .await
}

async fn inspect_plugin_manifest(deps: &Deps, plugin_id: &str) -> Result<Value, CapabilityError> {
    let store = deps.registry_store.clone();
    let plugin_id = plugin_id.to_owned();
    run_blocking_task("capability.plugin.inspect.store", move || {
        let store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .plugin_inspect(&plugin_id)
            .map_err(registry_store_error)?
            .ok_or_else(|| CapabilityError::NotFound {
                code: "CAPABILITY_PLUGIN_NOT_FOUND".to_owned(),
                message: format!("Capability plugin '{plugin_id}' was not found"),
            })
    })
    .await
}

async fn upsert_plugin_from_payload(
    invocation: &Invocation,
    deps: &Deps,
    action: &'static str,
) -> Result<Value, CapabilityError> {
    let manifest_value = invocation.payload.get("manifest").cloned().ok_or_else(|| {
        CapabilityError::InvalidParams {
            message: "manifest is required".to_owned(),
        }
    })?;
    let manifest: CapabilityPluginManifest =
        serde_json::from_value(manifest_value).map_err(|error| CapabilityError::InvalidParams {
            message: format!("Invalid capability plugin manifest: {error}"),
        })?;
    validate_plugin_manifest(&manifest)?;
    let catalog_revision = deps.engine_host.catalog_revision().await.0;
    let state = if action == "install" {
        "candidate".to_owned()
    } else {
        manifest.conformance_state.clone()
    };
    validate_conformance_state(&state)?;
    let store = deps.registry_store.clone();
    let manifest_for_store = manifest.clone();
    let state_for_store = state.clone();
    run_blocking_task("capability.plugin_upsert", move || {
        let mut store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .upsert_plugin_manifest(&manifest_for_store, &state_for_store, catalog_revision)
            .map_err(registry_store_error)
    })
    .await?;
    let result = json!({
        "action": action,
        "pluginId": manifest.id,
        "conformanceState": state,
        "catalogRevision": catalog_revision,
    });
    record_admin_audit(
        deps,
        invocation,
        if action == "install" {
            "capability.plugin_install"
        } else {
            "capability.plugin_update"
        },
        result.clone(),
    )
    .await?;
    Ok(result)
}

async fn ensure_implementation_known(
    deps: &Deps,
    selected_implementation: &str,
) -> Result<(), CapabilityError> {
    let snapshot = registry_snapshot_from_store(deps).await?;
    let known = snapshot
        .get("implementations")
        .and_then(Value::as_array)
        .is_some_and(|implementations| {
            implementations.iter().any(|implementation| {
                implementation
                    .get("implementationId")
                    .and_then(Value::as_str)
                    == Some(selected_implementation)
            })
        });
    if known {
        return Ok(());
    }
    Err(CapabilityError::NotFound {
        code: "CAPABILITY_IMPLEMENTATION_NOT_FOUND".to_owned(),
        message: format!("Capability implementation '{selected_implementation}' was not found"),
    })
}

fn required_string(params: &Value, key: &str) -> Result<String, CapabilityError> {
    string_field(params, key).ok_or_else(|| CapabilityError::InvalidParams {
        message: format!("{key} is required"),
    })
}

fn string_array_field(params: &Value, key: &str) -> Result<Vec<String>, CapabilityError> {
    let Some(value) = params.get(key) else {
        return Ok(Vec::new());
    };
    let Some(values) = value.as_array() else {
        return Err(CapabilityError::InvalidParams {
            message: format!("{key} must be an array of strings"),
        });
    };
    values
        .iter()
        .map(|value| {
            value
                .as_str()
                .map(ToOwned::to_owned)
                .ok_or_else(|| CapabilityError::InvalidParams {
                    message: format!("{key} must be an array of strings"),
                })
        })
        .collect()
}

fn validate_binding_scope(scope_kind: &str) -> Result<(), CapabilityError> {
    if matches!(scope_kind, "session" | "workspace" | "profile" | "system") {
        return Ok(());
    }
    Err(CapabilityError::InvalidParams {
        message: "scopeKind must be session, workspace, profile, or system".to_owned(),
    })
}

fn validate_conformance_state(state: &str) -> Result<(), CapabilityError> {
    if matches!(
        state,
        "candidate" | "healthy" | "degraded" | "quarantined" | "disabled"
    ) {
        return Ok(());
    }
    Err(CapabilityError::InvalidParams {
        message: "state must be candidate, healthy, degraded, quarantined, or disabled".to_owned(),
    })
}

fn validate_plugin_manifest(manifest: &CapabilityPluginManifest) -> Result<(), CapabilityError> {
    validate_nonempty_id("manifest.id", &manifest.id)?;
    validate_nonempty_id("manifest.name", &manifest.name)?;
    validate_nonempty_id("manifest.version", &manifest.version)?;
    validate_nonempty_id("manifest.publisher", &manifest.publisher)?;
    validate_conformance_state(&manifest.conformance_state)?;
    if manifest.namespace_claims.is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "manifest.namespaceClaims must not be empty".to_owned(),
        });
    }
    for namespace in &manifest.namespace_claims {
        validate_namespace_claim(namespace)?;
    }
    for contract_id in &manifest.provided_contracts {
        ensure_claim_covers_id("providedContracts", &manifest.namespace_claims, contract_id)?;
    }
    for implementation_id in &manifest.provided_implementations {
        ensure_claim_covers_id(
            "providedImplementations",
            &manifest.namespace_claims,
            implementation_id,
        )?;
    }
    if manifest.trust_tier == "first_party_signed" && manifest.signature_status != "valid" {
        return Err(CapabilityError::InvalidParams {
            message: "first_party_signed plugins require signatureStatus=valid".to_owned(),
        });
    }
    Ok(())
}

fn validate_nonempty_id(field: &str, value: &str) -> Result<(), CapabilityError> {
    if value.trim().is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: format!("{field} must not be empty"),
        });
    }
    Ok(())
}

fn validate_namespace_claim(namespace: &str) -> Result<(), CapabilityError> {
    validate_nonempty_id("namespaceClaim", namespace)?;
    if namespace == "capability" || namespace.starts_with("capability::") {
        return Err(CapabilityError::InvalidParams {
            message: "plugins cannot claim the reserved capability namespace".to_owned(),
        });
    }
    if namespace.contains('*') {
        return Err(CapabilityError::InvalidParams {
            message: "namespace claims must be explicit prefixes and cannot contain '*'".to_owned(),
        });
    }
    Ok(())
}

fn ensure_claim_covers_id(
    field: &str,
    namespace_claims: &[String],
    id: &str,
) -> Result<(), CapabilityError> {
    if namespace_claims
        .iter()
        .any(|claim| id == claim || id.starts_with(&format!("{claim}::")) || id.starts_with(claim))
    {
        return Ok(());
    }
    Err(CapabilityError::InvalidParams {
        message: format!("{field} id '{id}' is outside namespaceClaims"),
    })
}

fn validate_capability_execution_policy_payload(raw_policy: Value) -> Value {
    match serde_json::from_value::<CapabilityExecutionPolicySpec>(raw_policy) {
        Ok(policy) => json!({
            "valid": true,
            "policy": policy,
            "errors": []
        }),
        Err(error) => json!({
            "valid": false,
            "errors": [error.to_string()]
        }),
    }
}

fn validate_profile_id(policy_id: &str) -> Result<(), CapabilityError> {
    validate_nonempty_id("policyId", policy_id)?;
    let valid = policy_id
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | '.' | ':'));
    if valid {
        return Ok(());
    }
    Err(CapabilityError::InvalidParams {
        message: "policyId contains unsupported characters".to_owned(),
    })
}

fn current_profile_toml_path(deps: &Deps) -> PathBuf {
    deps.profile_runtime
        .current()
        .profile
        .active_dir
        .join(files::PROFILE_TOML)
}

fn write_capability_execution_policy_to_profile_and_reload(
    path: &Path,
    policy_id: &str,
    policy: &CapabilityExecutionPolicySpec,
    runtime: &crate::domains::agent::runner::profile_runtime::ProfileRuntime,
) -> Result<(), CapabilityError> {
    let previous = fs::read_to_string(path).map_err(|error| CapabilityError::Internal {
        message: format!("read profile TOML {}: {error}", path.display()),
    })?;
    write_capability_execution_policy_to_profile_inner(path, policy_id, policy, &previous)?;
    if let Err(error) = runtime.reload_now("capability::policy_update") {
        atomic_write(path, previous.as_bytes())?;
        let _ = runtime.reload_now("capability::policy_update.rollback");
        return Err(CapabilityError::Internal {
            message: format!(
                "profile runtime rejected updated capability policy; profile TOML was rolled back: {error}"
            ),
        });
    }
    Ok(())
}

fn write_capability_execution_policy_to_profile_inner(
    path: &Path,
    policy_id: &str,
    policy: &CapabilityExecutionPolicySpec,
    previous: &str,
) -> Result<(), CapabilityError> {
    let mut value: toml::Value =
        toml::from_str(previous).map_err(|error| CapabilityError::InvalidParams {
            message: format!("profile TOML is invalid and cannot be updated: {error}"),
        })?;
    let Some(table) = value.as_table_mut() else {
        return Err(CapabilityError::InvalidParams {
            message: "profile TOML root must be a table".to_owned(),
        });
    };
    let policies = table
        .entry("capabilityExecutionPolicies".to_owned())
        .or_insert_with(|| toml::Value::Table(Default::default()));
    let Some(policies_table) = policies.as_table_mut() else {
        return Err(CapabilityError::InvalidParams {
            message: "profile capabilityExecutionPolicies must be a table".to_owned(),
        });
    };
    let policy_value =
        toml::Value::try_from(policy).map_err(|error| CapabilityError::Internal {
            message: format!("serialize capability execution policy to TOML: {error}"),
        })?;
    policies_table.insert(policy_id.to_owned(), policy_value);
    let next = toml::to_string_pretty(&value).map_err(|error| CapabilityError::Internal {
        message: format!("serialize profile TOML: {error}"),
    })?;
    atomic_write(path, next.as_bytes())
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), CapabilityError> {
    let parent = path.parent().ok_or_else(|| CapabilityError::Internal {
        message: format!("path {} has no parent", path.display()),
    })?;
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("profile.toml");
    let tmp = parent.join(format!(
        ".{file_name}.tmp-{}",
        uuid::Uuid::now_v7().as_simple()
    ));
    fs::write(&tmp, bytes).map_err(|error| CapabilityError::Internal {
        message: format!("write temporary profile TOML {}: {error}", tmp.display()),
    })?;
    fs::rename(&tmp, path).map_err(|error| CapabilityError::Internal {
        message: format!("replace profile TOML {}: {error}", path.display()),
    })
}

fn actor_from_invocation(invocation: &Invocation) -> Result<ActorContext, CapabilityError> {
    let mut actor = ActorContext::new(
        invocation.causal_context.actor_id.clone(),
        invocation.causal_context.actor_kind.clone(),
        AuthorityGrantId::new(invocation.causal_context.authority_grant_id.as_str()).map_err(
            |error| CapabilityError::Internal {
                message: error.to_string(),
            },
        )?,
    );
    actor.authority_scopes = invocation.causal_context.authority_scopes.clone();
    actor.session_id = invocation.causal_context.session_id.clone();
    actor.workspace_id = invocation.causal_context.workspace_id.clone();
    if !matches!(
        actor.actor_kind,
        ActorKind::Agent | ActorKind::System | ActorKind::Admin
    ) {
        tracing::debug!(
            actor_kind = ?actor.actor_kind,
            "capability primitive invoked by non-agent actor"
        );
    }
    Ok(actor)
}

fn is_capability_primitive(function: &FunctionDefinition) -> bool {
    function
        .metadata
        .get("capabilityPrimitive")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn enforce_execution_policy(
    invocation: &Invocation,
    decision: &CapabilityBindingDecision,
    function: &FunctionDefinition,
) -> Result<(), CapabilityError> {
    if matches!(
        invocation.causal_context.actor_kind,
        ActorKind::System | ActorKind::Admin
    ) {
        return Ok(());
    }

    let contract_candidates = [decision.contract_id.as_str()];
    let implementation_candidates = [decision.selected_implementation.as_str()];
    let function_candidates = [decision.selected_function_id.as_str(), function.id.as_str()];
    let plugin_id = string_field(&function.metadata, "pluginId")
        .unwrap_or_else(|| function.owner_worker.as_str().to_owned());
    let plugin_candidates = [plugin_id.as_str()];
    if policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        CONTRACT_DENY_SCOPE_PREFIX,
        &contract_candidates,
    ) || policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        IMPLEMENTATION_DENY_SCOPE_PREFIX,
        &implementation_candidates,
    ) || policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        IMPLEMENTATION_DENY_SCOPE_PREFIX,
        &function_candidates,
    ) || policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        PLUGIN_DENY_SCOPE_PREFIX,
        &plugin_candidates,
    ) {
        return Err(CapabilityError::Custom {
            code: "CAPABILITY_DENIED".to_owned(),
            message: format!(
                "{} is denied by the active capability policy",
                function.id.as_str()
            ),
            details: Some(json!({
                "contractId": decision.contract_id.as_str(),
                "implementationId": decision.selected_implementation.as_str(),
                "functionId": function.id.as_str()
            })),
        });
    }
    let contract_allowed = policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        CONTRACT_ALLOW_SCOPE_PREFIX,
        &contract_candidates,
    );
    let implementation_allowed = policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        IMPLEMENTATION_ALLOW_SCOPE_PREFIX,
        &implementation_candidates,
    ) || policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        IMPLEMENTATION_ALLOW_SCOPE_PREFIX,
        &function_candidates,
    );
    let plugin_allowed = policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        PLUGIN_ALLOW_SCOPE_PREFIX,
        &plugin_candidates,
    );
    if contract_allowed && implementation_allowed && plugin_allowed {
        return Ok(());
    }
    Err(CapabilityError::Custom {
        code: "CAPABILITY_DENIED".to_owned(),
        message: format!(
            "{} is not allowed by the active capability policy",
            function.id.as_str()
        ),
        details: Some(json!({
            "contractId": decision.contract_id.as_str(),
            "implementationId": decision.selected_implementation.as_str(),
            "functionId": function.id.as_str()
        })),
    })
}

fn validate_target_payload(
    entry: &CapabilityRegistryEntry,
    payload: &Value,
) -> Result<(), CapabilityError> {
    let function = &entry.function;
    if let Some(schema) = &function.request_schema {
        crate::engine::schema::validate_payload(&function.id, "request", schema, payload)
            .map_err(|error| recipe_validation_error(entry, error))?;
    }
    Ok(())
}

fn recipe_validation_error(
    entry: &CapabilityRegistryEntry,
    error: crate::engine::EngineError,
) -> CapabilityError {
    let schema_details = schema_violation_details(&error);
    let mapped = engine_error_to_capability_error(error);
    let recipe = entry.agent_recipe();
    let example = serde_json::to_string(&recipe.execute_template).unwrap_or_else(|_| {
        format!(
            "{{\"mode\":\"invoke\",\"contractId\":\"{}\",\"payload\":{{}}}}",
            recipe.contract_id
        )
    });
    let guidance = format!(
        "Invalid arguments for {}. Put target arguments inside execute.arguments. Required arguments: {}. Optional arguments: {}.{} Example: {}",
        entry.contract_id,
        if recipe.required_payload.is_empty() {
            "none".to_owned()
        } else {
            recipe.required_payload.join("; ")
        },
        if recipe.optional_payload.is_empty() {
            "none".to_owned()
        } else {
            recipe.optional_payload.join("; ")
        },
        conditional_argument_guidance(entry),
        example
    );
    match mapped {
        CapabilityError::InvalidParams { message } => {
            let message = format!("{message}. {guidance}");
            if let Some(details) = schema_details {
                CapabilityError::Custom {
                    code: capability_error_codes::INVALID_PARAMS.to_owned(),
                    message,
                    details: Some(details),
                }
            } else {
                CapabilityError::InvalidParams { message }
            }
        }
        CapabilityError::Custom {
            code,
            message,
            details,
        } => CapabilityError::Custom {
            code,
            message: format!("{message}. {guidance}"),
            details: merge_validation_details(details, schema_details),
        },
        other => other,
    }
}

fn schema_violation_details(error: &crate::engine::EngineError) -> Option<Value> {
    let crate::engine::EngineError::SchemaViolation {
        path,
        message,
        direction,
        ..
    } = error
    else {
        return None;
    };
    let argument_path = schema_path_to_argument_path(path);
    let mut details = json!({
        "schemaPath": path,
        "schemaDirection": direction,
        "schemaMessage": message,
        "argumentPath": argument_path,
    });
    if message == "required field is missing" {
        let missing = schema_path_leaf(path);
        details["validationKind"] = json!("missing_required_argument");
        details["missingFields"] = json!([missing]);
        details["missingArgumentPaths"] = json!([argument_path]);
    }
    Some(details)
}

fn merge_validation_details(
    details: Option<Value>,
    schema_details: Option<Value>,
) -> Option<Value> {
    match (details, schema_details) {
        (Some(Value::Object(mut base)), Some(Value::Object(extra))) => {
            for (key, value) in extra {
                base.insert(key, value);
            }
            Some(Value::Object(base))
        }
        (Some(details), None) => Some(details),
        (None, Some(schema_details)) => Some(schema_details),
        (Some(details), Some(schema_details)) => Some(json!({
            "original": details,
            "schema": schema_details,
        })),
        (None, None) => None,
    }
}

fn schema_path_to_argument_path(path: &str) -> String {
    let trimmed = path.strip_prefix("$.").unwrap_or(path);
    if trimmed == "$" || trimmed.is_empty() {
        "arguments".to_owned()
    } else {
        format!("arguments.{trimmed}")
    }
}

fn schema_path_leaf(path: &str) -> String {
    let trimmed = path.strip_prefix("$.").unwrap_or(path);
    trimmed
        .rsplit('.')
        .next()
        .filter(|leaf| !leaf.is_empty() && *leaf != "$")
        .unwrap_or(trimmed)
        .to_owned()
}

fn conditional_argument_guidance(entry: &CapabilityRegistryEntry) -> &'static str {
    if entry.contract_id.as_str() == "process::run" {
        " For sandbox_materialized process::run, include expectedOutputs: [{\"path\":\"<relative-output-path>\"}] and verify the returned materializedOutputs summary before guessing follow-up commands."
    } else {
        ""
    }
}

fn requires_fresh_revision_for_payload(
    function: &FunctionDefinition,
    invocation_payload: &Value,
) -> bool {
    if function.id.as_str() == "process::run" {
        let target_payload = invocation_payload
            .get("payload")
            .unwrap_or(invocation_payload);
        if !crate::domains::process::approval::run_execution_requires_approval(target_payload) {
            return false;
        }
    }
    if function.id.as_str() == "notifications::send" {
        return false;
    }
    requires_fresh_revision(function)
}

fn execution_requires_approval(function: &FunctionDefinition, payload: &Value) -> bool {
    function.required_authority.approval_required
        || (function.id.as_str() == "process::run"
            && crate::domains::process::approval::run_execution_requires_approval(payload))
}

fn validate_target_policy_before_approval(
    function: &FunctionDefinition,
    payload: &Value,
) -> Result<(), CapabilityError> {
    if function.id.as_str() == "process::run"
        && let Err(message) =
            crate::domains::process::approval::validate_run_payload_before_approval(payload)
    {
        return Err(CapabilityError::InvalidParams {
            message: message.to_owned(),
        });
    }
    Ok(())
}

fn policy_scope_matches(scopes: &[String], prefix: &str, candidates: &[&str]) -> bool {
    scopes.iter().any(|scope| {
        let Some(value) = scope.strip_prefix(prefix) else {
            return false;
        };
        value == "*" || candidates.contains(&value)
    })
}

fn child_idempotency_key(
    invocation: &Invocation,
    function: &FunctionDefinition,
    payload: &Value,
    required: bool,
) -> Result<Option<String>, CapabilityError> {
    if let Some(key) = string_field(&invocation.payload, "idempotencyKey")
        .or_else(|| string_field(&invocation.payload, "idempotency_key"))
    {
        return Ok(Some(key));
    }
    if let Some(parent_key) = invocation.causal_context.idempotency_key.as_deref() {
        let material = json!({
            "parent": parent_key,
            "functionId": function.id.as_str(),
            "payload": payload,
        });
        let serialized = serde_json::to_vec(&material).unwrap_or_default();
        return Ok(Some(format!(
            "capability-execute:v1:{}",
            sha256_hex(&serialized)
        )));
    }
    if required {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "{} mutates state; pass idempotencyKey or invoke through a model capability invocation with engine idempotency",
                function.id.as_str()
            ),
        });
    }
    Ok(None)
}

fn child_idempotency_required(function: &FunctionDefinition, payload: &Value) -> bool {
    if function.id.as_str() == "process::run"
        && !crate::domains::process::approval::run_execution_requires_approval(payload)
    {
        return false;
    }
    function.effect_class.is_mutating()
}

fn render_search_summary(query: &str, results: &[CapabilityIndexHit]) -> String {
    if results.is_empty() {
        return if query.trim().is_empty() {
            "No visible capabilities found.".to_owned()
        } else {
            format!("No visible capabilities found for '{query}'.")
        };
    }
    let mut lines = vec![format!(
        "Found {} visible capabilities. Use one `execute` call with intent, optional target, and target arguments inside `arguments`. Do not wrap another `capability::execute` call, and do not run example/probe calls unless the user requested that exact action. Inspect is an operator detail view; model-facing execution prepares freshness internally.",
        results.len()
    )];
    let full_recipe_count = results.len().min(5);
    for result in results.iter().take(full_recipe_count) {
        lines.push(render_search_hit_recipe(result));
    }
    if results.len() > full_recipe_count {
        lines.push("Additional compact matches:".to_owned());
        for result in results.iter().skip(full_recipe_count).take(10) {
            lines.push(format!(
                "- `{}` via `{}` ({})",
                result.contract_id, result.function_id, result.matched_by
            ));
        }
    }
    lines.join("\n")
}

fn render_search_hit_recipe(hit: &CapabilityIndexHit) -> String {
    let Some(recipe) = hit.recipe.as_ref() else {
        return format!(
            "- `{}` via `{}`. Inspect this {} result for invocation details.",
            hit.contract_id, hit.function_id, hit.kind
        );
    };
    let mut lines = Vec::new();
    lines.push(format!(
        "\n### `{}` — {}",
        recipe.contract_id, recipe.display_name
    ));
    lines.push(format!("Use when: {}", recipe.use_when));
    if let Ok(template) = serde_json::to_string(&recipe.execute_template) {
        lines.push(format!("Execute:\n```json\n{template}\n```"));
    }
    if !recipe.required_payload.is_empty() {
        lines.push(format!(
            "Required arguments: {}.",
            recipe.required_payload.join("; ")
        ));
    }
    if !recipe.optional_payload.is_empty() {
        let optional = recipe
            .optional_payload
            .iter()
            .take(8)
            .cloned()
            .collect::<Vec<_>>();
        lines.push(format!("Optional payload: {}.", optional.join("; ")));
    }
    if recipe.inspect_required {
        lines
            .push("Freshness is required for elevated-risk work; model-facing execute prepares it before approval.".to_owned());
    } else {
        lines.push(format!("Direct execution: {}.", recipe.direct_execution));
    }
    if recipe.approval_behavior != "none" {
        lines.push(format!("Approval: {}.", recipe.approval_behavior));
    }
    lines.push(format!("Result: {}", recipe.result_summary));
    lines.join("\n")
}

fn render_inspection_summary(details: &Value) -> String {
    let implementation = &details["implementation"];
    let contract = &details["contract"];
    let recipe = &details["recipe"];
    let requirements = &details["executionRequirements"];
    let function_id = implementation["functionId"].as_str().unwrap_or("<unknown>");
    let contract_id = contract["contractId"].as_str().unwrap_or("<unknown>");
    let effect = contract["effectClass"].as_str().unwrap_or("unknown");
    let risk = contract["riskLevel"].as_str().unwrap_or("unknown");
    let expected_revision = requirements["expectedRevision"]
        .as_u64()
        .unwrap_or_default();
    let mut summary = format!(
        "{contract_id} is implemented by {function_id}. effect={effect}, risk={risk}, expectedRevision={expected_revision}."
    );

    if let Some(use_when) = recipe["useWhen"].as_str() {
        summary.push_str(&format!("\nUse when: {use_when}"));
    }
    if let Ok(template) = serde_json::to_string(&recipe["executeTemplate"])
        && template != "null"
    {
        summary.push_str(&format!("\nExecute:\n```json\n{template}\n```"));
        summary.push_str(
            "\nCall the `execute` primitive with this target and arguments shape; do not set target to `capability::execute`, and do not run example/probe calls unless they are the requested action.",
        );
    }

    if requirements["freshInspectionRequired"]
        .as_bool()
        .unwrap_or(false)
    {
        let inspection_handle = requirements["inspectionHandle"]
            .as_str()
            .unwrap_or("<missing>");
        let expected_schema_digest = requirements["expectedSchemaDigest"]
            .as_str()
            .unwrap_or("<missing>");
        summary.push_str("\nFreshness material prepared by model-facing execute:");
        summary.push_str(&format!("\n- inspectionHandle={inspection_handle}"));
        summary.push_str(&format!("\n- expectedRevision={expected_revision}"));
        summary.push_str(&format!(
            "\n- expectedSchemaDigest={expected_schema_digest}"
        ));
    }

    let required_payload_fields = recipe["requiredPayload"]
        .as_array()
        .map(|fields| {
            fields
                .iter()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>()
        })
        .filter(|fields| !fields.is_empty())
        .unwrap_or_else(|| required_payload_fields(contract));
    if !required_payload_fields.is_empty() {
        summary.push_str(&format!(
            "\nExecute arguments must include: {}.",
            required_payload_fields.join(", ")
        ));
    }
    let optional_payload_fields = recipe["optionalPayload"]
        .as_array()
        .map(|fields| {
            fields
                .iter()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if !optional_payload_fields.is_empty() {
        summary.push_str(&format!(
            "\nOptional arguments include: {}.",
            optional_payload_fields
                .iter()
                .take(8)
                .cloned()
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    if contract_id == "process::run" {
        summary.push_str(
            "\nFor sandbox_materialized process::run, include expectedOutputs exactly as an array of objects like [{\"path\":\"result.txt\"}]. The result includes materializedOutputs with targetPath, resourceId, versionId, file content hash, and bounded contentPreview for verification.",
        );
    }

    if requirements["idempotencyKeyRequired"]
        .as_bool()
        .unwrap_or(false)
    {
        summary.push_str(
            "\n- idempotencyKey is required; choose a stable key for this intended action.",
        );
    }

    if requirements["approvalRequired"].as_bool().unwrap_or(false) {
        summary.push_str("\n- approvalRequired=true; execution may pause for user approval.");
    } else if requirements["approvalMode"].as_str() == Some("conditional") {
        summary.push_str(
            "\n- approvalMode=conditional; safe read-only payloads run directly, while risky payloads pause for user approval.",
        );
    }

    summary
}

fn required_payload_fields(contract: &Value) -> Vec<String> {
    contract["inputSchema"]["required"]
        .as_array()
        .map(|fields| {
            fields
                .iter()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

fn missing_inspection_requirements_error(
    function: &FunctionDefinition,
    entry: &CapabilityRegistryEntry,
    expected_revision: Option<u64>,
    expected_schema_digest: Option<&str>,
    inspection_handle: Option<&str>,
) -> CapabilityError {
    let mut missing_fields = Vec::new();
    if inspection_handle.is_none() {
        missing_fields.push("inspectionHandle");
    }
    if expected_revision.is_none() {
        missing_fields.push("expectedRevision");
    }
    if expected_schema_digest.is_none() {
        missing_fields.push("expectedSchemaDigest");
    }

    CapabilityError::Custom {
        code: "INSPECTION_REQUIRED".to_owned(),
        message: format!(
            "{} is mutating or elevated-risk; inspect it first and copy inspectionHandle, expectedRevision={}, and expectedSchemaDigest={} into execute",
            function.id.as_str(),
            function.revision.0,
            entry.schema_digest
        ),
        details: Some(json!({
            "functionId": function.id.as_str(),
            "missingFields": missing_fields,
            "inspect": {
                "functionId": function.id.as_str(),
                "expectedRevision": function.revision.0,
                "expectedSchemaDigest": entry.schema_digest,
                "copyFieldsFromInspection": [
                    "inspectionHandle",
                    "expectedRevision",
                    "expectedSchemaDigest"
                ]
            },
            "riskLevel": format!("{:?}", function.risk_level),
            "effectClass": format!("{:?}", function.effect_class)
        })),
    }
}

fn capability_result_value(result: CapabilityResult) -> Result<Value, CapabilityError> {
    serde_json::to_value(result).map_err(|error| CapabilityError::Internal {
        message: error.to_string(),
    })
}

fn merge_optional_details(existing: Option<Value>, extra: Value) -> Value {
    match existing {
        Some(Value::Object(mut object)) => {
            let _ = object.insert("capabilityExecution".to_owned(), extra);
            Value::Object(object)
        }
        Some(value) => json!({
            "toolDetails": value,
            "capabilityExecution": extra
        }),
        None => extra,
    }
}

fn risk_field(params: &Value, key: &str) -> Result<Option<RiskLevel>, CapabilityError> {
    let Some(raw) = params.get(key) else {
        return Ok(None);
    };
    let Some(value) = raw
        .as_str()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return Err(CapabilityError::InvalidParams {
            message: format!("{key} must be a non-empty string"),
        });
    };
    risk_level_from_str(value, key).map(Some)
}

fn risk_level_from_str(value: &str, label: &str) -> Result<RiskLevel, CapabilityError> {
    match value.to_ascii_lowercase().as_str() {
        "low" => Ok(RiskLevel::Low),
        "medium" => Ok(RiskLevel::Medium),
        "high" => Ok(RiskLevel::High),
        "critical" => Ok(RiskLevel::Critical),
        _ => Err(CapabilityError::InvalidParams {
            message: format!("Unsupported {label} '{value}'"),
        }),
    }
}

fn effect_field(params: &Value, key: &str) -> Result<Option<EffectClass>, CapabilityError> {
    let Some(raw) = params.get(key) else {
        return Ok(None);
    };
    let Some(value) = raw
        .as_str()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return Err(CapabilityError::InvalidParams {
            message: format!("{key} must be a non-empty string"),
        });
    };
    effect_class_from_str(value, key).map(Some)
}

fn effect_class_from_str(value: &str, label: &str) -> Result<EffectClass, CapabilityError> {
    let normalized = value
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .collect::<String>()
        .to_ascii_lowercase();
    match normalized.as_str() {
        "pureread" => Ok(EffectClass::PureRead),
        "deterministiccompute" => Ok(EffectClass::DeterministicCompute),
        "delegatedinvocation" => Ok(EffectClass::DelegatedInvocation),
        "idempotentwrite" => Ok(EffectClass::IdempotentWrite),
        "appendonlyevent" => Ok(EffectClass::AppendOnlyEvent),
        "reversiblesideeffect" => Ok(EffectClass::ReversibleSideEffect),
        "externalsideeffect" => Ok(EffectClass::ExternalSideEffect),
        "irreversiblesideeffect" => Ok(EffectClass::IrreversibleSideEffect),
        _ => Err(CapabilityError::InvalidParams {
            message: format!("Unsupported {label} '{value}'"),
        }),
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::capability::types::CapabilityIndexHit;
    use crate::engine::{
        ActorId, AuthorityGrantId, AuthorityRequirement, CatalogRevision, FunctionId,
        FunctionRevision, InvocationId, TraceId, VisibilityScope, WorkerId,
    };

    fn test_function(id: &str) -> FunctionDefinition {
        FunctionDefinition::new(
            FunctionId::new(id).expect("function id"),
            WorkerId::new(id.split("::").next().expect("namespace")).expect("worker id"),
            "Searchable test function",
            VisibilityScope::System,
            EffectClass::PureRead,
        )
    }

    fn test_approval_record(
        function_id: FunctionId,
        parent_invocation_id: InvocationId,
        trace_id: TraceId,
        idempotency_key: &str,
    ) -> EngineApprovalRecord {
        let now = chrono::Utc::now();
        EngineApprovalRecord {
            approval_id: "approval-test".to_owned(),
            function_id,
            payload: json!({ "ok": true }),
            payload_fingerprint: "fingerprint".to_owned(),
            actor_id: ActorId::new("agent:test").expect("actor id"),
            actor_kind: ActorKind::Agent,
            authority_grant_id: AuthorityGrantId::new("grant:test").expect("grant id"),
            authority_scopes: vec!["process.run".to_owned()],
            trace_id,
            parent_invocation_id: Some(parent_invocation_id),
            trigger_id: None,
            session_id: Some("session-test".to_owned()),
            workspace_id: None,
            idempotency_key: Some(idempotency_key.to_owned()),
            delivery_mode: DeliveryMode::Sync,
            status: ApprovalStatus::Executed,
            decision_actor_id: Some(ActorId::new("engine-user").expect("actor id")),
            decided_at: Some(now),
            result: Some(json!({ "exitCode": 0, "stdout": "ok\n", "resourceRefs": [] })),
            error: None,
            created_at: now,
            updated_at: now,
        }
    }

    fn test_invocation_record(
        invocation_id: InvocationId,
        function: &FunctionDefinition,
        parent_invocation_id: InvocationId,
        trace_id: TraceId,
        idempotency_key: &str,
    ) -> InvocationRecord {
        InvocationRecord {
            invocation_id,
            function_id: function.id.clone(),
            worker_id: function.owner_worker.clone(),
            function_revision: FunctionRevision(1),
            catalog_revision: CatalogRevision(77),
            actor_id: ActorId::new("agent:test").expect("actor id"),
            actor_kind: ActorKind::Agent,
            authority_grant_id: AuthorityGrantId::new("grant:test").expect("grant id"),
            authority_scopes: vec!["process.run".to_owned()],
            trace_id,
            parent_invocation_id: Some(parent_invocation_id),
            trigger_id: None,
            session_id: Some("session-test".to_owned()),
            workspace_id: None,
            delivery_mode: DeliveryMode::Sync,
            idempotency_key: Some(idempotency_key.to_owned()),
            idempotency_scope: None,
            resource_lease_ids: Vec::new(),
            compensation_status: None,
            produced_resource_refs: Vec::new(),
            replayed_from: None,
            succeeded: true,
            result_value: Some(json!({ "exitCode": 0, "stdout": "ok\n" })),
            error: None,
            timestamp: chrono::Utc::now(),
        }
    }

    #[test]
    fn registry_defaults_contract_and_implementation_from_function() {
        let function = test_function("filesystem::read_file");
        let entry = super::super::registry::CapabilityRegistryEntry::from_function(function, 7);
        assert_eq!(entry.contract_id, "filesystem::read_file");
        assert_eq!(
            entry.implementation_id,
            "first_party.filesystem.v1.read_file"
        );
        assert_eq!(entry.plugin_id, "first_party.filesystem");
        assert_eq!(entry.catalog_revision, 7);
        assert!(!entry.schema_digest.is_empty());
    }

    #[test]
    fn search_queries_supports_batch_without_splitting_into_many_primitive_calls() {
        let queries = search_queries(&json!({
            "query": "ignored when batch is present",
            "queries": [
                "notify",
                "ask user",
                "spawn subagent",
                "wait job",
                "display image",
                "computer action",
                "web fetch",
                "read file",
                "extra ignored by schema cap"
            ]
        }))
        .expect("queries");

        assert_eq!(queries.len(), 8);
        assert_eq!(queries[0], "notify");
        assert_eq!(queries[7], "read file");
    }

    #[test]
    fn inspect_targets_accepts_string_shorthand_and_dedupes_targets() {
        let targets = inspect_targets(&json!({
            "targets": [
                "process::run",
                {"contractId": "process::run"},
                "process::run",
                {"functionId": "filesystem::read_file"}
            ]
        }))
        .expect("valid targets")
        .expect("targets");

        assert_eq!(targets.len(), 3);
        assert_eq!(targets[0]["capabilityId"], json!("process::run"));
        assert_eq!(targets[1]["contractId"], json!("process::run"));
        assert_eq!(targets[2]["functionId"], json!("filesystem::read_file"));
    }

    #[test]
    fn render_batch_search_preserves_per_query_statuses() {
        let ready_status = CapabilityIndexStatus {
            lexical: true,
            local_vector: true,
            cloud_embeddings: false,
            vector_store: "sqlite-vec:vec0".to_owned(),
            embedding_model: "fastembed:test".to_owned(),
            state: "ready".to_owned(),
            degraded_reason: None,
        };
        let degraded_status = CapabilityIndexStatus {
            lexical: true,
            local_vector: false,
            cloud_embeddings: false,
            vector_store: "none".to_owned(),
            embedding_model: "none".to_owned(),
            state: "unavailable".to_owned(),
            degraded_reason: Some("embedding assets unavailable".to_owned()),
        };
        let hit = CapabilityIndexHit {
            kind: "implementation".to_owned(),
            capability_id: "process::run".to_owned(),
            contract_id: "process::run".to_owned(),
            implementation_id: "first_party.process.v1.run".to_owned(),
            plugin_id: "first_party.process".to_owned(),
            worker_id: "process".to_owned(),
            function_id: "process::run".to_owned(),
            catalog_revision: 7,
            schema_digest: "digest".to_owned(),
            trust_tier: "first_party_signed".to_owned(),
            health: "Healthy".to_owned(),
            visibility: "system".to_owned(),
            effect_class: "external_side_effect".to_owned(),
            risk_level: "low".to_owned(),
            lexical_score: 1.0,
            vector_score: Some(0.5),
            fused_score: 1.5,
            matched_by: "hybrid".to_owned(),
            snippet: "Run a process".to_owned(),
            requires_inspect: false,
            recipe: None,
        };

        let value = render_search_result_value(
            vec![
                (
                    "process".to_owned(),
                    super::super::registry::CapabilityIndexSearchResult {
                        hits: vec![hit],
                        status: ready_status,
                    },
                ),
                (
                    "notify".to_owned(),
                    super::super::registry::CapabilityIndexSearchResult {
                        hits: Vec::new(),
                        status: degraded_status,
                    },
                ),
            ],
            7,
            0,
            10,
        )
        .expect("result");
        let details = value["details"].as_object().expect("details");
        let queries = details["queries"].as_array().expect("batch queries");

        assert_eq!(queries.len(), 2);
        assert_eq!(queries[0]["query"], json!("process"));
        assert_eq!(queries[0]["searchMode"]["state"], json!("ready"));
        assert_eq!(queries[1]["query"], json!("notify"));
        assert_eq!(
            queries[1]["searchMode"]["degradedReason"],
            json!("embedding assets unavailable")
        );
    }

    #[test]
    fn search_visible_content_contains_actionable_recipe() {
        let process_spec = crate::domains::process::contract::capabilities()
            .expect("process specs")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "process::run")
            .expect("process::run spec");
        let function = crate::domains::contract::function_definition_for_capability(&process_spec);
        let entry = CapabilityRegistryEntry::from_function(function, 9);
        let recipe = entry.agent_recipe();
        let hit = CapabilityIndexHit {
            kind: "implementation".to_owned(),
            capability_id: entry.capability_id(),
            contract_id: entry.contract_id.clone(),
            implementation_id: entry.implementation_id.clone(),
            plugin_id: entry.plugin_id.clone(),
            worker_id: entry.worker_id.clone(),
            function_id: entry.function_id.clone(),
            catalog_revision: entry.catalog_revision,
            schema_digest: entry.schema_digest.clone(),
            trust_tier: entry.trust_tier.clone(),
            health: "Healthy".to_owned(),
            visibility: "system".to_owned(),
            effect_class: "external_side_effect".to_owned(),
            risk_level: "high".to_owned(),
            lexical_score: 1.0,
            vector_score: None,
            fused_score: 1.0,
            matched_by: "local_lexical".to_owned(),
            snippet: "Run a bounded shell command".to_owned(),
            requires_inspect: false,
            recipe: Some(recipe),
        };
        let status = CapabilityIndexStatus {
            lexical: true,
            local_vector: false,
            cloud_embeddings: false,
            vector_store: "none".to_owned(),
            embedding_model: "none".to_owned(),
            state: "ready".to_owned(),
            degraded_reason: None,
        };

        let value = render_search_result_value(
            vec![(
                "process run shell command date".to_owned(),
                super::super::registry::CapabilityIndexSearchResult {
                    hits: vec![hit],
                    status,
                },
            )],
            9,
            0,
            10,
        )
        .expect("search result");
        let content = value["content"][0]["text"].as_str().expect("text content");

        assert!(content.contains("process::run"));
        assert!(content.contains("intent, optional target"));
        assert!(content.contains("Do not wrap another `capability::execute` call"));
        assert!(content.contains("do not run example/probe calls"));
        assert!(
            content
                .contains("\"arguments\":{\"command\":\"date\",\"executionMode\":\"read_only\"}")
        );
        assert!(content.contains("Required arguments: command: string"));
        assert!(content.contains("executionMode: string"));
        assert!(!content.contains("process::run -> process::run"));
        assert_eq!(
            value["details"]["results"][0]["recipe"]["contractId"],
            json!("process::run")
        );
        let required_command = value["details"]["results"][0]["recipe"]["requiredPayload"][0]
            .as_str()
            .expect("required command summary");
        assert!(required_command.starts_with("command: string"));
        assert!(required_command.contains("Shell command to run"));
    }

    #[test]
    fn stale_revision_needed_for_mutating_or_risky_functions() {
        let mut read = test_function("alpha::read");
        assert!(!requires_fresh_revision(&read));
        read.effect_class = EffectClass::IdempotentWrite;
        assert!(requires_fresh_revision(&read));
        read.effect_class = EffectClass::PureRead;
        read.risk_level = RiskLevel::Medium;
        assert!(requires_fresh_revision(&read));
    }

    #[test]
    fn child_idempotency_derives_from_parent_capability_invocation_key() {
        let function = test_function("filesystem::read_file");
        let causal = CausalContext::new(
            crate::engine::ActorId::new("agent:s1").expect("actor id"),
            ActorKind::Agent,
            AuthorityGrantId::new("agent-capability-runtime").expect("grant id"),
            crate::engine::TraceId::new("trace").expect("trace id"),
        )
        .with_idempotency_key("parent-key");
        let invocation = Invocation::new_sync(
            FunctionId::new("capability::execute").expect("function id"),
            json!({"payload": {"path": "a"}}),
            causal,
        );
        let key = child_idempotency_key(&invocation, &function, &json!({"path": "a"}), true)
            .expect("key")
            .expect("derived key");
        assert!(key.starts_with("capability-execute:v1:"));
    }

    #[test]
    fn process_run_date_does_not_require_approval_but_destructive_command_does() {
        let process_spec = crate::domains::process::contract::capabilities()
            .expect("process specs")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "process::run")
            .expect("process::run spec");
        let function = crate::domains::contract::function_definition_for_capability(&process_spec);
        assert!(!execution_requires_approval(
            &function,
            &json!({ "command": "date +%Y-%m-%d", "executionMode": "read_only" })
        ));
        assert!(!child_idempotency_required(
            &function,
            &json!({ "command": "date +%Y-%m-%d", "executionMode": "read_only" })
        ));
        assert!(
            validate_target_policy_before_approval(
                &function,
                &json!({
                    "command": "echo hi > should_not_exist.txt",
                    "executionMode": "read_only"
                })
            )
            .is_err()
        );
        assert!(execution_requires_approval(
            &function,
            &json!({
                "command": "echo hi > result.txt",
                "executionMode": "sandbox_materialized",
                "expectedOutputs": [{"path": "result.txt"}]
            })
        ));
        assert!(child_idempotency_required(
            &function,
            &json!({
                "command": "echo hi > result.txt",
                "executionMode": "sandbox_materialized",
                "expectedOutputs": [{"path": "result.txt"}]
            })
        ));
    }

    #[test]
    fn process_run_sandbox_requires_declared_outputs_before_approval() {
        let process_spec = crate::domains::process::contract::capabilities()
            .expect("process specs")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "process::run")
            .expect("process::run spec");
        let function = crate::domains::contract::function_definition_for_capability(&process_spec);
        let error = validate_target_policy_before_approval(
            &function,
            &json!({
                "command": "printf hi > out.txt",
                "executionMode": "sandbox_materialized"
            }),
        )
        .expect_err("missing expected outputs rejected before approval");

        assert!(error.to_string().contains("expectedOutputs"));
        assert!(error.to_string().contains("\"path\""));
    }

    #[test]
    fn orchestrated_execute_normalizes_common_shape_mistakes() {
        let input = parse_orchestrated_execute_input(&json!({
            "intent": "write a sandboxed output file",
            "payload": {
                "contractId": "process::run",
                "command": "printf hi > out.txt",
                "executionMode": "sandbox_materialized",
                "expectedOutputs": [
                    {"path": "out.txt", "kind": "materialized_file", "role": "updated", "type": "file"}
                ],
                "idempotencyKey": "write-out",
                "reason": "Create a declared output"
            }
        }))
        .expect("normalized input");
        assert_eq!(
            input.target_params,
            Some(json!({"contractId": "process::run"}))
        );
        assert_eq!(input.idempotency_key.as_deref(), Some("write-out"));
        assert_eq!(input.reason.as_deref(), Some("Create a declared output"));
        assert_eq!(input.arguments["command"], json!("printf hi > out.txt"));
        let kinds = input
            .corrections
            .iter()
            .filter_map(|correction| correction["kind"].as_str())
            .collect::<Vec<_>>();
        assert!(kinds.contains(&"payload_to_arguments"));
        assert!(kinds.contains(&"nested_target_to_target"));
        assert!(kinds.contains(&"nested_idempotency_key_to_wrapper"));
        assert!(kinds.contains(&"nested_reason_to_wrapper"));

        let process_spec = crate::domains::process::contract::capabilities()
            .expect("process specs")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "process::run")
            .expect("process::run spec");
        let function = crate::domains::contract::function_definition_for_capability(&process_spec);
        let mut arguments = input.arguments;
        let mut corrections = input.corrections;
        normalize_target_specific_arguments(&function, &mut arguments, &mut corrections);
        assert!(arguments["expectedOutputs"][0].get("kind").is_none());
        assert!(arguments["expectedOutputs"][0].get("role").is_none());
        assert!(arguments["expectedOutputs"][0].get("type").is_none());
        assert!(
            corrections
                .iter()
                .any(|correction| correction["kind"] == json!("process_expected_outputs_shape"))
        );
    }

    #[test]
    fn orchestrated_execute_normalizes_process_output_aliases_before_schema_validation() {
        let process_spec = crate::domains::process::contract::capabilities()
            .expect("process specs")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "process::run")
            .expect("process::run spec");
        let function = crate::domains::contract::function_definition_for_capability(&process_spec);
        let entry = CapabilityRegistryEntry::from_function(function.clone(), 77);
        let mut arguments = json!({
            "command": "printf hi > out.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputPaths": ["out.txt"]
        });
        let mut corrections = Vec::new();

        normalize_target_specific_arguments(&function, &mut arguments, &mut corrections);

        assert_eq!(arguments["expectedOutputs"], json!([{ "path": "out.txt" }]));
        assert!(arguments.get("expectedOutputPaths").is_none());
        assert!(
            corrections.iter().any(|correction| {
                correction["kind"] == json!("process_expected_outputs_alias")
            })
        );
        validate_target_payload(&entry, &arguments).expect("normalized payload schema-valid");
    }

    #[test]
    fn orchestrated_execute_prepared_payload_preserves_target_arguments_only() {
        let input = parse_orchestrated_execute_input(&json!({
            "intent": "read the readme",
            "target": "filesystem::read_file",
            "arguments": {"path": "README.md"},
            "reason": "Read the project README"
        }))
        .expect("input");
        let prepared = prepared_execute_payload(input.target_params.as_ref().unwrap(), &input);

        assert_eq!(prepared["mode"], json!("invoke"));
        assert_eq!(prepared["capabilityId"], json!("filesystem::read_file"));
        assert_eq!(prepared["payload"], json!({"path": "README.md"}));
        assert_eq!(prepared["reason"], json!("Read the project README"));
        assert!(prepared.get("arguments").is_none());
        assert!(prepared.get("target").is_none());
    }

    #[test]
    fn orchestration_audit_filters_match_status_phase_and_correction() {
        let matching = json!({
            "eventType": "capability.orchestration",
            "traceId": "trace-a",
            "payload": {
                "orchestrationId": "capability-orchestration:test",
                "status": "executed",
                "intent": "run a command",
                "correctionsApplied": [
                    {"kind": "payload_to_arguments", "confidence": 1.0}
                ],
                "phaseDetails": {"phase": "prepare"}
            }
        });
        let different = json!({
            "eventType": "capability.orchestration",
            "traceId": "trace-a",
            "payload": {
                "status": "needs_selection",
                "correctionsApplied": [],
                "phaseDetails": {"phase": "resolve"}
            }
        });

        assert!(audit_event_matches_orchestration_filters(
            &matching,
            Some("executed"),
            Some("payload_to_arguments"),
            Some("prepare")
        ));
        assert!(!audit_event_matches_orchestration_filters(
            &different,
            Some("executed"),
            Some("payload_to_arguments"),
            Some("prepare")
        ));

        let filtered = filter_orchestration_audit_result(
            json!({"events": [different, matching], "redacted": false}),
            Some("executed"),
            Some("payload_to_arguments"),
            Some("prepare"),
            10,
            false,
        )
        .expect("filtered");
        assert_eq!(filtered["events"].as_array().expect("events").len(), 1);
        assert_eq!(filtered["redacted"], json!(true));
        assert_eq!(filtered["events"][0]["payload"]["redacted"], json!(true));
        assert_eq!(
            filtered["events"][0]["payloadSummary"]["status"],
            json!("executed")
        );
        assert_eq!(
            filtered["events"][0]["payloadSummary"]["phase"],
            json!("prepare")
        );
        assert_eq!(
            filtered["events"][0]["payloadSummary"]["correctionKinds"],
            json!(["payload_to_arguments"])
        );
    }

    #[test]
    fn intent_strong_name_match_breaks_near_score_filesystem_ties() {
        let read = CapabilityIndexHit {
            kind: "implementation".to_owned(),
            capability_id: "filesystem::read_file".to_owned(),
            contract_id: "filesystem::read_file".to_owned(),
            implementation_id: "first_party.filesystem.v1.read_file".to_owned(),
            plugin_id: "first_party.filesystem".to_owned(),
            worker_id: "filesystem".to_owned(),
            function_id: "filesystem::read_file".to_owned(),
            catalog_revision: 1,
            schema_digest: "digest-read".to_owned(),
            trust_tier: "first_party_signed".to_owned(),
            health: "Healthy".to_owned(),
            visibility: "system".to_owned(),
            effect_class: "pure_read".to_owned(),
            risk_level: "low".to_owned(),
            lexical_score: 1.0,
            vector_score: Some(0.1),
            fused_score: 0.09,
            matched_by: "hybrid_local".to_owned(),
            snippet: "read a file".to_owned(),
            requires_inspect: false,
            recipe: None,
        };
        let list = CapabilityIndexHit {
            contract_id: "filesystem::list_dir".to_owned(),
            function_id: "filesystem::list_dir".to_owned(),
            implementation_id: "first_party.filesystem.v1.list_dir".to_owned(),
            capability_id: "filesystem::list_dir".to_owned(),
            schema_digest: "digest-list".to_owned(),
            snippet: "list a directory".to_owned(),
            ..read.clone()
        };

        assert!(intent_strongly_matches_hit(
            "Use the filesystem read file capability to read a file",
            &read
        ));
        assert!(!intent_strongly_matches_hit(
            "Use the filesystem read file capability to read a file",
            &list
        ));
    }

    #[test]
    fn deterministic_intent_route_prefers_filesystem_read_for_path_arguments() {
        let read = test_function("filesystem::read_file");
        let mut stop = test_function("sandbox::stop_spawned_worker");
        stop.effect_class = EffectClass::ExternalSideEffect;
        stop.risk_level = RiskLevel::High;
        let snapshot = CapabilityRegistrySnapshot::new(vec![stop, read], 7);

        let hit = deterministic_intent_route(
            "Read the first 3 lines of README.md from the current workspace.",
            &json!({"path": "README.md", "startLine": 1, "endLine": 3}),
            &snapshot,
            &json!({}),
        )
        .expect("route check")
        .expect("filesystem read route");

        assert_eq!(hit.function_id, "filesystem::read_file");
        assert_eq!(hit.matched_by, "deterministic_path_read");
        assert!(hit.fused_score > 10.0);
    }

    #[test]
    fn deterministic_intent_route_preempts_bad_search_ranking() {
        let read = test_function("filesystem::read_file");
        let mut stop = test_function("sandbox::stop_spawned_worker");
        stop.effect_class = EffectClass::ExternalSideEffect;
        stop.risk_level = RiskLevel::High;
        let snapshot = CapabilityRegistrySnapshot::new(vec![stop.clone(), read], 7);
        let mut hits = vec![orchestration_hit_from_entry(
            &CapabilityRegistryEntry::from_function(stop, 7),
            "local_lexical",
            7.8,
        )];

        apply_deterministic_intent_route(
            "Read the first 3 lines of README.md from the current workspace.",
            &json!({"path": "README.md", "startLine": 1, "endLine": 3}),
            &snapshot,
            &json!({}),
            &mut hits,
        )
        .expect("route applied");

        assert_eq!(hits[0].function_id, "filesystem::read_file");
        assert_eq!(hits[1].function_id, "sandbox::stop_spawned_worker");
    }

    #[test]
    fn deterministic_intent_route_respects_constraints_and_write_intents() {
        let read = test_function("filesystem::read_file");
        let snapshot = CapabilityRegistrySnapshot::new(vec![read], 7);

        let write_intent = deterministic_intent_route(
            "Write the first 3 lines to README.md.",
            &json!({"path": "README.md"}),
            &snapshot,
            &json!({}),
        )
        .expect("route check");
        assert!(write_intent.is_none());

        let constrained_out = deterministic_intent_route(
            "Read the first 3 lines of README.md.",
            &json!({"path": "README.md"}),
            &snapshot,
            &json!({"allowedNamespaces": ["sandbox"]}),
        )
        .expect("route check");
        assert!(constrained_out.is_none());
    }

    #[test]
    fn orchestration_constraints_reject_broader_or_unsupported_targets() {
        let mut function = test_function("process::run");
        function.effect_class = EffectClass::ExternalSideEffect;
        function.risk_level = RiskLevel::High;
        let entry = CapabilityRegistryEntry::from_function(function, 4);

        validate_orchestration_constraints(
            &json!({
                "riskMax": "high",
                "effect": "external_side_effect",
                "allowedContracts": ["process::run"],
                "allowedNamespaces": ["process"]
            }),
            &entry,
        )
        .expect("covered constraints");

        let risk_error = validate_orchestration_constraints(&json!({"riskMax": "medium"}), &entry)
            .expect_err("risk rejected");
        assert!(risk_error.to_string().contains("above constraint riskMax"));

        let contract_error = validate_orchestration_constraints(
            &json!({"allowedContracts": ["filesystem::read_file"]}),
            &entry,
        )
        .expect_err("contract rejected");
        assert!(
            contract_error
                .to_string()
                .contains("outside execute.constraints.allowedContracts")
        );

        let unsupported_error =
            validate_orchestration_constraints(&json!({"networkPolicy": "none"}), &entry)
                .expect_err("unsupported rejected");
        assert!(
            unsupported_error
                .to_string()
                .contains("Unsupported execute.constraints field")
        );

        let typed_error = validate_orchestration_constraints(&json!({"riskMax": 1}), &entry)
            .expect_err("typed risk rejected");
        assert!(typed_error.to_string().contains("riskMax must be"));
    }

    #[test]
    fn orchestration_constraint_shape_rejects_malformed_values_before_resolution() {
        let unsupported =
            validate_orchestration_constraint_shape(&json!({"networkPolicy": "none"}))
                .expect_err("unsupported rejected");
        assert!(
            unsupported
                .to_string()
                .contains("Unsupported execute.constraints field")
        );

        let bad_risk = validate_orchestration_constraint_shape(&json!({"riskMax": "impossible"}))
            .expect_err("risk rejected");
        assert!(bad_risk.to_string().contains("Unsupported riskMax"));

        let bad_namespaces = validate_orchestration_constraint_shape(
            &json!({"allowedNamespaces": ["filesystem", 1]}),
        )
        .expect_err("namespace rejected");
        assert!(
            bad_namespaces
                .to_string()
                .contains("allowedNamespaces must contain only non-empty strings")
        );
    }

    #[test]
    fn orchestration_constraints_filter_resolution_candidates() {
        let read_hit = CapabilityIndexHit {
            kind: "implementation".to_owned(),
            capability_id: "filesystem::read_file".to_owned(),
            contract_id: "filesystem::read_file".to_owned(),
            implementation_id: "first_party.filesystem.v1.read_file".to_owned(),
            plugin_id: "first_party.filesystem".to_owned(),
            worker_id: "filesystem".to_owned(),
            function_id: "filesystem::read_file".to_owned(),
            catalog_revision: 1,
            schema_digest: "digest-read".to_owned(),
            trust_tier: "first_party_signed".to_owned(),
            health: "Healthy".to_owned(),
            visibility: "system".to_owned(),
            effect_class: "pure_read".to_owned(),
            risk_level: "low".to_owned(),
            lexical_score: 1.0,
            vector_score: Some(0.1),
            fused_score: 0.9,
            matched_by: "hybrid_local".to_owned(),
            snippet: "read a file".to_owned(),
            requires_inspect: false,
            recipe: None,
        };
        let process_hit = CapabilityIndexHit {
            contract_id: "process::run".to_owned(),
            function_id: "process::run".to_owned(),
            implementation_id: "first_party.process.v1.run".to_owned(),
            capability_id: "process::run".to_owned(),
            schema_digest: "digest-process".to_owned(),
            effect_class: "external_side_effect".to_owned(),
            risk_level: "high".to_owned(),
            snippet: "run a process".to_owned(),
            ..read_hit.clone()
        };

        let constraints = json!({
            "riskMax": "low",
            "effect": "pure_read",
            "allowedNamespaces": ["filesystem"]
        });
        assert!(
            orchestration_constraints_allow_hit(&constraints, &read_hit).expect("read constraints")
        );
        assert!(
            !orchestration_constraints_allow_hit(&constraints, &process_hit)
                .expect("process constraints")
        );
    }

    #[test]
    fn orchestration_argument_filter_prefers_candidate_that_accepts_supplied_arguments() {
        let functions = crate::domains::filesystem::contract::capabilities()
            .expect("filesystem specs")
            .into_iter()
            .filter(|spec| {
                matches!(
                    spec.function_id.as_str(),
                    "filesystem::search_text" | "filesystem::glob"
                )
            })
            .map(|spec| crate::domains::contract::function_definition_for_capability(&spec))
            .collect::<Vec<_>>();
        let snapshot = CapabilityRegistrySnapshot::new(functions, 42);
        let mut hits = snapshot
            .entries
            .iter()
            .map(|entry| orchestration_hit_from_entry(entry, "hybrid_local", 0.09))
            .collect::<Vec<_>>();
        hits.sort_by(|left, right| left.function_id.cmp(&right.function_id));

        let rejected = apply_argument_schema_fit_filter(
            &json!({
                "pattern": "Testing out",
                "path": ".",
                "filePattern": "README.md",
                "maxResults": 5
            }),
            &snapshot,
            &mut hits,
        );

        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].function_id, "filesystem::search_text");
        assert!(
            rejected.iter().any(|candidate| {
                candidate["functionId"] == json!("filesystem::glob")
                    && candidate["rejectionReason"] == json!("argument_schema_mismatch")
            }),
            "glob should not remain ambiguous when filePattern proves search_text"
        );
    }

    #[test]
    fn orchestration_argument_filter_uses_target_specific_normalization() {
        let process_spec = crate::domains::process::contract::capabilities()
            .expect("process specs")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "process::run")
            .expect("process::run spec");
        let read_spec = crate::domains::filesystem::contract::capabilities()
            .expect("filesystem specs")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "filesystem::read_file")
            .expect("filesystem::read_file spec");
        let snapshot = CapabilityRegistrySnapshot::new(
            vec![
                crate::domains::contract::function_definition_for_capability(&process_spec),
                crate::domains::contract::function_definition_for_capability(&read_spec),
            ],
            43,
        );
        let mut hits = snapshot
            .entries
            .iter()
            .map(|entry| orchestration_hit_from_entry(entry, "hybrid_local", 0.09))
            .collect::<Vec<_>>();
        hits.sort_by(|left, right| left.function_id.cmp(&right.function_id));

        let rejected = apply_argument_schema_fit_filter(
            &json!({
                "command": "printf hi > out.txt",
                "executionMode": "sandbox_materialized",
                "expectedOutputPaths": ["out.txt"]
            }),
            &snapshot,
            &mut hits,
        );

        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].function_id, "process::run");
        assert!(
            rejected.iter().any(|candidate| {
                candidate["functionId"] == json!("filesystem::read_file")
                    && candidate["rejectionReason"] == json!("argument_missing_required")
            }),
            "read_file should not remain ambiguous when process aliases normalize cleanly"
        );
    }

    #[test]
    fn execute_preflight_policy_rejection_is_structured_capability_result() {
        let process_spec = crate::domains::process::contract::capabilities()
            .expect("process specs")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "process::run")
            .expect("process::run spec");
        let function = crate::domains::contract::function_definition_for_capability(&process_spec);
        let entry = CapabilityRegistryEntry::from_function(function.clone(), 77);
        let target = ResolvedCapabilityTarget {
            binding_decision: decision_for_entry(&entry, "test", Vec::new()),
            entry,
        };
        let payload = json!({
            "command": "echo hi > should_not_exist.txt",
            "executionMode": "read_only"
        });
        let error =
            validate_target_policy_before_approval(&function, &payload).expect_err("policy error");

        let value = preflight_rejection_result(&function, &target, error, "target_policy_rejected")
            .expect("structured result");
        let result: CapabilityResult = serde_json::from_value(value).expect("capability result");
        let CapabilityResultBody::Blocks(blocks) = result.content else {
            panic!("expected block content");
        };

        assert_eq!(result.is_error, Some(true));
        assert_eq!(result.stop_turn, None);
        let CapabilityResultContent::Text { text } = &blocks[0] else {
            panic!("expected text content");
        };
        assert!(text.contains("process::run rejected before child execution"));
        let details = result.details.expect("details");
        assert_eq!(details["status"], json!("target_policy_rejected"));
        assert_eq!(details["error"]["code"], json!("INVALID_PARAMS"));
        assert_eq!(details["functionId"], json!("process::run"));
        assert_eq!(details["childInvocationCreated"], json!(false));
        assert_eq!(details["approvalCreated"], json!(false));
        assert_eq!(details["resourceRefs"], json!([]));
    }

    #[test]
    fn execute_missing_required_argument_is_needs_input_result() {
        let mut function = test_function("process::run");
        function.request_schema = Some(json!({
            "type": "object",
            "additionalProperties": false,
            "required": ["command"],
            "properties": {
                "command": {"type": "string"}
            }
        }));
        let entry = CapabilityRegistryEntry::from_function(function.clone(), 77);
        let target = ResolvedCapabilityTarget {
            binding_decision: decision_for_entry(&entry, "test", Vec::new()),
            entry: entry.clone(),
        };
        let error = validate_target_payload(&entry, &json!({})).expect_err("payload error");
        assert_eq!(payload_preflight_status(&error), "needs_input");

        let value = preflight_rejection_result(&function, &target, error, "needs_input")
            .expect("structured result");
        let result: CapabilityResult = serde_json::from_value(value).expect("capability result");
        let CapabilityResultBody::Blocks(blocks) = result.content else {
            panic!("expected block content");
        };
        let CapabilityResultContent::Text { text } = &blocks[0] else {
            panic!("expected text content");
        };
        assert!(text.contains("process::run needs input before child execution"));
        assert!(!text.contains("process::run rejected before child execution"));

        assert_eq!(result.is_error, Some(true));
        let details = result.details.expect("details");
        assert_eq!(details["status"], json!("needs_input"));
        assert_eq!(details["error"]["code"], json!("INVALID_PARAMS"));
        assert_eq!(
            details["error"]["details"]["validationKind"],
            json!("missing_required_argument")
        );
        assert_eq!(
            details["error"]["details"]["missingFields"],
            json!(["command"])
        );
        assert_eq!(
            details["guidance"]["missingArgumentPaths"],
            json!(["arguments.command"])
        );
        assert_eq!(details["childInvocationCreated"], json!(false));
        assert_eq!(details["approvalCreated"], json!(false));
        assert_eq!(details["resourceRefs"], json!([]));
        assert!(
            details["error"]["message"]
                .as_str()
                .expect("message")
                .contains("Required arguments: command")
        );
    }

    #[test]
    fn execute_invalid_target_payload_remains_target_payload_invalid() {
        let mut function = test_function("process::run");
        function.request_schema = Some(json!({
            "type": "object",
            "additionalProperties": false,
            "required": ["command"],
            "properties": {
                "command": {"type": "string"}
            }
        }));
        let entry = CapabilityRegistryEntry::from_function(function.clone(), 77);
        let target = ResolvedCapabilityTarget {
            binding_decision: decision_for_entry(&entry, "test", Vec::new()),
            entry: entry.clone(),
        };
        let error = validate_target_payload(
            &entry,
            &json!({
                "command": "echo ok",
                "unexpected": true
            }),
        )
        .expect_err("payload error");
        assert_eq!(payload_preflight_status(&error), "target_payload_invalid");

        let value = preflight_rejection_result(&function, &target, error, "target_payload_invalid")
            .expect("structured result");
        let result: CapabilityResult = serde_json::from_value(value).expect("capability result");
        let CapabilityResultBody::Blocks(blocks) = result.content else {
            panic!("expected block content");
        };
        let CapabilityResultContent::Text { text } = &blocks[0] else {
            panic!("expected text content");
        };
        assert!(text.contains("process::run rejected before child execution"));
        let details = result.details.expect("details");
        assert_eq!(details["status"], json!("target_payload_invalid"));
        assert_eq!(details["error"]["code"], json!("INVALID_PARAMS"));
        assert_eq!(details["childInvocationCreated"], json!(false));
        assert_eq!(details["approvalCreated"], json!(false));
        assert_eq!(details["resourceRefs"], json!([]));
    }

    #[test]
    fn approved_execute_result_reports_approval_and_child_invocation() {
        let function = test_function("process::run");
        let entry = CapabilityRegistryEntry::from_function(function.clone(), 77);
        let target = ResolvedCapabilityTarget {
            binding_decision: decision_for_entry(&entry, "test", Vec::new()),
            entry,
        };
        let trace_id = TraceId::generate();
        let causal = CausalContext::new(
            ActorId::new("agent:test").expect("actor id"),
            ActorKind::Agent,
            AuthorityGrantId::new("grant:test").expect("grant id"),
            trace_id.clone(),
        )
        .with_idempotency_key("wrapper-key");
        let invocation = Invocation::new_sync(
            FunctionId::new("capability::execute").expect("function id"),
            json!({ "contractId": "process::run" }),
            causal,
        );
        let approval = test_approval_record(
            function.id.clone(),
            invocation.id.clone(),
            trace_id.clone(),
            "approved-child-key",
        );
        let child_invocation_id = InvocationId::generate();
        let records = vec![test_invocation_record(
            child_invocation_id.clone(),
            &function,
            invocation.id.clone(),
            trace_id,
            "approved-child-key",
        )];
        let child_invocations =
            approval_child_invocation_ids_from_records(&records, &approval, &function);

        assert_eq!(
            child_invocations,
            vec![child_invocation_id.as_str().to_owned()]
        );

        let value = approved_execution_result(
            &invocation,
            &function,
            &target,
            &approval,
            json!({ "exitCode": 0, "stdout": "ok\n", "resourceRefs": [] }),
            child_invocations,
        )
        .expect("approved execution result");
        let result: CapabilityResult = serde_json::from_value(value).expect("capability result");
        let details = result.details.expect("details");

        assert_eq!(details["approvalRequired"], json!(true));
        assert_eq!(details["approvalCreated"], json!(true));
        assert_eq!(details["approvalExecuted"], json!(true));
        assert_eq!(details["childInvocationCreated"], json!(true));
        assert_eq!(
            details["childInvocations"],
            json!([child_invocation_id.as_str()])
        );
        assert_eq!(
            details["approvalState"]["childInvocationId"],
            json!(child_invocation_id.as_str())
        );
        assert_eq!(
            details["approvalState"]["childInvocationIds"],
            json!([child_invocation_id.as_str()])
        );
    }

    #[test]
    fn replayed_approval_execute_result_does_not_report_fresh_approval_or_child() {
        let function = test_function("process::run");
        let entry = CapabilityRegistryEntry::from_function(function.clone(), 77);
        let target = ResolvedCapabilityTarget {
            binding_decision: decision_for_entry(&entry, "test", Vec::new()),
            entry,
        };
        let original_trace_id = TraceId::generate();
        let original_parent_invocation_id = InvocationId::generate();
        let approval = test_approval_record(
            function.id.clone(),
            original_parent_invocation_id.clone(),
            original_trace_id.clone(),
            "approved-child-key",
        );
        let replay_trace_id = TraceId::generate();
        let replay_causal = CausalContext::new(
            ActorId::new("agent:test").expect("actor id"),
            ActorKind::Agent,
            AuthorityGrantId::new("grant:test").expect("grant id"),
            replay_trace_id,
        )
        .with_idempotency_key("wrapper-key-replay");
        let replay_invocation = Invocation::new_sync(
            FunctionId::new("capability::execute").expect("function id"),
            json!({ "contractId": "process::run" }),
            replay_causal,
        );
        let child_invocation_id = InvocationId::generate();

        assert!(approval_was_replayed_for_invocation(
            &replay_invocation,
            &approval
        ));

        let value = approved_execution_result(
            &replay_invocation,
            &function,
            &target,
            &approval,
            json!({ "exitCode": 0, "stdout": "ok\n", "resourceRefs": [] }),
            vec![child_invocation_id.as_str().to_owned()],
        )
        .expect("replayed approval execution result");
        let result: CapabilityResult = serde_json::from_value(value).expect("capability result");
        let details = result.details.expect("details");

        assert_eq!(details["approvalRequired"], json!(false));
        assert_eq!(details["approvalCreated"], json!(false));
        assert_eq!(details["approvalExecuted"], json!(false));
        assert_eq!(details["approvalReplayed"], json!(true));
        assert_eq!(details["childInvocationCreated"], json!(false));
        assert!(details["approvalState"].is_null());
        assert_eq!(
            details["approvalReplay"]["approvalId"],
            json!(approval.approval_id)
        );
        assert_eq!(
            details["approvalReplay"]["childInvocationIds"],
            json!([child_invocation_id.as_str()])
        );
        assert_eq!(
            details["replayedFromTraceId"],
            json!(original_trace_id.as_str())
        );
    }

    #[test]
    fn execute_validates_target_payload_before_requesting_approval() {
        let mut function = test_function("process::run");
        function.request_schema = Some(json!({
            "type": "object",
            "additionalProperties": false,
            "required": ["command"],
            "properties": {
                "command": {"type": "string"}
            }
        }));

        let entry = CapabilityRegistryEntry::from_function(function, 1);
        let error = validate_target_payload(&entry, &json!({})).expect_err("schema error");

        match error {
            CapabilityError::InvalidParams { message } => {
                assert!(message.contains("required field is missing"));
                assert!(message.contains("Required arguments"));
                assert!(message.contains("command"));
            }
            CapabilityError::Custom { message, .. } => {
                assert!(message.contains("required field is missing"));
                assert!(message.contains("Required arguments"));
                assert!(message.contains("command"));
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn explicit_implementation_id_can_address_function_ids() {
        let params = json!({"implementationId": "function:filesystem::read_file"});
        let target = parse_target(&params).expect("target");
        assert!(matches!(
            target,
            super::super::registry::CapabilityTarget::Implementation(value)
                if value == "function:filesystem::read_file"
        ));
    }

    #[test]
    fn parse_target_ignores_blank_higher_priority_fields() {
        let params = json!({
            "functionId": "",
            "implementationId": "   ",
            "contractId": "",
            "capabilityId": " process::run "
        });
        let target = parse_target(&params).expect("target");
        assert!(matches!(
            target,
            super::super::registry::CapabilityTarget::Capability(value)
                if value == "process::run"
        ));
    }

    #[test]
    fn inspection_summary_surfaces_copyable_execute_requirements() {
        let details = json!({
            "contract": {
                "contractId": "process::run",
                "effectClass": "external_side_effect",
                "riskLevel": "high",
                "inputSchema": {
                    "type": "object",
                    "required": ["command"]
                }
            },
            "implementation": {
                "functionId": "process::run"
            },
            "recipe": {
                "executeTemplate": {
                    "intent": "Run a read-only process command.",
                    "target": "process::run",
                    "arguments": {
                        "command": "date",
                        "executionMode": "read_only"
                    }
                },
                "requiredPayload": [
                    "command: string",
                    "executionMode: string [read_only|sandbox_materialized]"
                ],
                "optionalPayload": [
                    "expectedOutputs: array<object>",
                    "cwd: string"
                ]
            },
            "executionRequirements": {
                "approvalRequired": true,
                "expectedRevision": 1,
                "expectedSchemaDigest": "digest-123",
                "freshInspectionRequired": true,
                "idempotencyKeyRequired": true,
                "inspectionHandle": "capability-inspection:v1:test"
            }
        });

        let summary = render_inspection_summary(&details);

        assert!(summary.contains("inspectionHandle=capability-inspection:v1:test"));
        assert!(summary.contains("\"target\":\"process::run\""));
        assert!(summary.contains("\"executionMode\":\"read_only\""));
        assert!(summary.contains("do not set target to `capability::execute`"));
        assert!(summary.contains("do not run example/probe calls"));
        assert!(summary.contains("expectedRevision=1"));
        assert!(summary.contains("expectedSchemaDigest=digest-123"));
        assert!(summary.contains("Execute arguments must include: command: string, executionMode: string [read_only|sandbox_materialized]."));
        assert!(
            summary.contains(
                "Optional arguments include: expectedOutputs: array<object>, cwd: string."
            )
        );
        assert!(summary.contains("For sandbox_materialized process::run, include expectedOutputs exactly as an array of objects"));
        assert!(summary.contains("materializedOutputs"));
        assert!(summary.contains("idempotencyKey is required"));
        assert!(summary.contains("approvalRequired=true"));
    }

    #[test]
    fn inspection_summary_explains_conditional_approval() {
        let details = json!({
            "contract": {
                "contractId": "process::run",
                "effectClass": "external_side_effect",
                "riskLevel": "high",
                "inputSchema": {
                    "type": "object",
                    "required": ["command"]
                }
            },
            "implementation": {
                "functionId": "process::run"
            },
            "executionRequirements": {
                "approvalMode": "conditional",
                "approvalRequired": false,
                "expectedRevision": 1,
                "expectedSchemaDigest": "digest-123",
                "freshInspectionRequired": true,
                "idempotencyKeyRequired": true,
                "inspectionHandle": "capability-inspection:v1:test"
            }
        });

        let summary = render_inspection_summary(&details);

        assert!(summary.contains("approvalMode=conditional"));
        assert!(summary.contains("safe read-only payloads run directly"));
    }

    #[test]
    fn missing_inspection_error_reports_exact_missing_execute_fields() {
        let mut function = test_function("process::run");
        function.effect_class = EffectClass::ExternalSideEffect;
        function.risk_level = RiskLevel::High;
        let entry =
            super::super::registry::CapabilityRegistryEntry::from_function(function.clone(), 303);

        let error = missing_inspection_requirements_error(&function, &entry, Some(1), None, None);

        match error {
            CapabilityError::Custom {
                code,
                message,
                details: Some(details),
            } => {
                assert_eq!(code, "INSPECTION_REQUIRED");
                assert!(message.contains("copy inspectionHandle"));
                assert_eq!(
                    details["missingFields"],
                    json!(["inspectionHandle", "expectedSchemaDigest"])
                );
                assert_eq!(details["inspect"]["functionId"], json!("process::run"));
                assert_eq!(details["inspect"]["expectedRevision"], json!(1));
                assert_eq!(
                    details["inspect"]["expectedSchemaDigest"],
                    json!(entry.schema_digest)
                );
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn process_run_date_does_not_require_fresh_inspection_handle() {
        let mut function = test_function("process::run");
        function.effect_class = EffectClass::ExternalSideEffect;
        function.risk_level = RiskLevel::High;

        assert!(!requires_fresh_revision_for_payload(
            &function,
            &json!({"payload": {"command": "date", "executionMode": "read_only"}})
        ));
        assert!(!requires_fresh_revision_for_payload(
            &function,
            &json!({"payload": {"command": "git status --short", "executionMode": "read_only"}})
        ));
        assert!(!requires_fresh_revision_for_payload(
            &function,
            &json!({"payload": {"command": "cd /tmp && git status --short && git log --oneline -3", "executionMode": "read_only"}})
        ));
        assert!(!requires_fresh_revision_for_payload(
            &function,
            &json!({"payload": {"command": "echo hello > should_not_exist.txt", "executionMode": "read_only"}})
        ));
    }

    #[test]
    fn process_run_risky_commands_still_require_fresh_inspection_handle() {
        let mut function = test_function("process::run");
        function.effect_class = EffectClass::ExternalSideEffect;
        function.risk_level = RiskLevel::High;

        assert!(requires_fresh_revision_for_payload(
            &function,
            &json!({"payload": {"command": "rm -rf target", "executionMode": "sandbox_materialized", "expectedOutputs": [{"path": "result.txt"}]}})
        ));
        assert!(requires_fresh_revision_for_payload(
            &function,
            &json!({"payload": {"command": "echo hello > file.txt", "executionMode": "sandbox_materialized", "expectedOutputs": [{"path": "file.txt"}]}})
        ));
    }

    #[test]
    fn notifications_send_runs_direct_with_idempotency_without_fresh_inspection() {
        let mut function = test_function("notifications::send");
        function.effect_class = EffectClass::ExternalSideEffect;
        function.risk_level = RiskLevel::Low;

        assert!(!requires_fresh_revision_for_payload(
            &function,
            &json!({
                "contractId": "notifications::send",
                "idempotencyKey": "notify-test",
                "payload": {"title": "Tron test", "body": "hello"}
            })
        ));
    }

    #[test]
    fn inspection_summary_keeps_low_risk_capabilities_concise() {
        let details = json!({
            "contract": {
                "contractId": "filesystem::read_file",
                "effectClass": "pure_read",
                "riskLevel": "low"
            },
            "implementation": {
                "functionId": "filesystem::read_file"
            },
            "executionRequirements": {
                "approvalRequired": false,
                "expectedRevision": 1,
                "expectedSchemaDigest": "digest-read",
                "freshInspectionRequired": false,
                "idempotencyKeyRequired": false,
                "inspectionHandle": "capability-inspection:v1:read"
            }
        });

        let summary = render_inspection_summary(&details);

        assert!(summary.contains("filesystem::read_file is implemented by filesystem::read_file"));
        assert!(!summary.contains("inspectionHandle="));
        assert!(!summary.contains("idempotencyKey is required"));
    }

    #[test]
    fn function_target_accepts_implementation_id_for_model_recovery() {
        let function = test_function("process::run");
        let entry = super::super::registry::CapabilityRegistryEntry::from_function(function, 7);
        let target = super::super::registry::CapabilityTarget::Function(
            "first_party.process.v1.run".to_owned(),
        );
        assert!(target.matches(&entry));
    }

    #[test]
    fn agent_search_requires_profile_policy_runtime_metadata() {
        let causal = CausalContext::new(
            crate::engine::ActorId::new("agent:s1").expect("actor id"),
            ActorKind::Agent,
            AuthorityGrantId::new("agent-capability-runtime").expect("grant id"),
            crate::engine::TraceId::new("trace").expect("trace id"),
        );
        let invocation = Invocation::new_sync(
            FunctionId::new("capability::search").expect("function id"),
            json!({"query": "read"}),
            causal,
        );
        let error = search_policy_from_runtime(&invocation).unwrap_err();
        assert!(matches!(
            error,
            CapabilityError::Custom { code, .. } if code == "CAPABILITY_SEARCH_POLICY_REQUIRED"
        ));
    }

    #[test]
    fn agent_search_uses_internal_profile_policy_metadata() {
        let policy = CapabilitySearchPolicy {
            require_local_vector: false,
            allow_lexical_only_when_degraded: true,
            ..CapabilitySearchPolicy::default()
        };
        let causal = CausalContext::new(
            crate::engine::ActorId::new("agent:s1").expect("actor id"),
            ActorKind::Agent,
            AuthorityGrantId::new("agent-capability-runtime").expect("grant id"),
            crate::engine::TraceId::new("trace").expect("trace id"),
        )
        .with_runtime_metadata(
            "capability.searchPolicy",
            serde_json::to_string(&policy).expect("policy json"),
        );
        let invocation = Invocation::new_sync(
            FunctionId::new("capability::search").expect("function id"),
            json!({"query": "read"}),
            causal,
        );
        let parsed = search_policy_from_runtime(&invocation).expect("policy");
        assert!(!parsed.require_local_vector);
        assert!(parsed.allow_lexical_only_when_degraded);
    }

    #[test]
    fn capability_execute_child_invocations_preserve_runtime_metadata() {
        let function = test_function("filesystem::read_file")
            .with_required_authority(AuthorityRequirement::scope("filesystem.read"));
        let parent = Invocation::new_sync(
            FunctionId::new("capability::execute").expect("function id"),
            json!({
                "contractId": "filesystem::read_file",
                "mode": "invoke",
                "payload": {"path": "README.md"}
            }),
            CausalContext::new(
                crate::engine::ActorId::new("agent:s1").expect("actor id"),
                ActorKind::Agent,
                AuthorityGrantId::new("agent-capability-runtime").expect("grant id"),
                crate::engine::TraceId::new("trace").expect("trace id"),
            )
            .with_session_id("sess-1")
            .with_workspace_id("workspace-1")
            .with_scope("capability.execute")
            .with_runtime_metadata(
                crate::engine::invocation::RUNTIME_METADATA_WORKING_DIRECTORY,
                "/tmp/session-worktree",
            ),
        );

        let child = child_execute_causal_context(&parent, &function, Some("child-key".to_owned()));

        assert_eq!(
            child.runtime_metadata(crate::engine::invocation::RUNTIME_METADATA_WORKING_DIRECTORY),
            Some("/tmp/session-worktree")
        );
        assert_eq!(child.session_id.as_deref(), Some("sess-1"));
        assert_eq!(child.workspace_id.as_deref(), Some("workspace-1"));
        assert!(child.has_scope("capability.execute"));
        assert!(child.has_scope("filesystem.read"));
        assert_eq!(child.idempotency_key.as_deref(), Some("child-key"));
    }

    #[test]
    fn operator_vector_warmup_policy_allows_visible_degradation() {
        let policy = registry_operator_sync_policy();

        assert!(policy.local_vector);
        assert!(!policy.require_local_vector);
        assert!(policy.allow_lexical_only_when_degraded);
        assert!(allows_degraded_vector_search(&policy));
    }

    #[test]
    fn vector_warmup_status_detects_incomplete_indexes() {
        let ready = CapabilityIndexStatus {
            lexical: true,
            local_vector: true,
            cloud_embeddings: false,
            vector_store: "sqlite-vec".to_owned(),
            embedding_model: "test".to_owned(),
            state: "ready".to_owned(),
            degraded_reason: None,
        };
        assert!(!index_status_needs_vector_warmup(&ready));

        let indexing = CapabilityIndexStatus {
            state: "indexing".to_owned(),
            degraded_reason: Some(
                "CAPABILITY_INDEX_INDEXING: local vector index has 606/716 current documents"
                    .to_owned(),
            ),
            ..ready.clone()
        };
        assert!(index_status_needs_vector_warmup(&indexing));

        let stale_ready_metadata = CapabilityIndexStatus {
            degraded_reason: Some(
                "CAPABILITY_INDEX_INDEXING: local vector index has 606/716 current documents"
                    .to_owned(),
            ),
            ..ready
        };
        assert!(index_status_needs_vector_warmup(&stale_ready_metadata));
    }

    #[test]
    fn vector_warmup_signature_changes_when_documents_change_without_catalog_revision() {
        let first =
            CapabilityRegistrySnapshot::new(vec![test_function("filesystem::read_file")], 7);
        let second = CapabilityRegistrySnapshot::new(
            vec![
                test_function("filesystem::read_file"),
                test_function("filesystem::search_text"),
            ],
            7,
        );

        assert_ne!(
            vector_warmup_signature(&first),
            vector_warmup_signature(&second)
        );
    }

    #[test]
    fn binding_resolution_sync_stays_metadata_only() {
        let policy = registry_metadata_sync_policy();

        assert!(!policy.local_vector);
        assert!(!policy.require_local_vector);
    }

    #[test]
    fn search_metadata_sync_runs_only_for_empty_or_changed_catalog() {
        let current = json!({
            "catalogRevision": 42,
            "documents": 178,
        });
        assert!(!registry_needs_metadata_sync(&current, 42));

        let changed = json!({
            "catalogRevision": 41,
            "documents": 178,
        });
        assert!(registry_needs_metadata_sync(&changed, 42));

        let empty = json!({
            "catalogRevision": 42,
            "documents": 0,
        });
        assert!(registry_needs_metadata_sync(&empty, 42));
    }

    #[test]
    fn plugin_manifest_validation_rejects_reserved_namespace_claims() {
        let manifest = CapabilityPluginManifest {
            id: "external.test".to_owned(),
            name: "Test".to_owned(),
            version: "1.0.0".to_owned(),
            publisher: "test".to_owned(),
            signature_status: "unsigned".to_owned(),
            runtime: "mcp".to_owned(),
            namespace_claims: vec!["capability".to_owned()],
            provided_contracts: vec!["capability::status".to_owned()],
            provided_implementations: vec!["capability.status.impl".to_owned()],
            requested_authorities: Vec::new(),
            trust_tier: "external_mcp".to_owned(),
            visibility_ceiling: "session".to_owned(),
            conformance_state: "candidate".to_owned(),
            docs: json!({}),
            examples: Vec::new(),
            search_metadata: json!({}),
        };
        let error = validate_plugin_manifest(&manifest).unwrap_err();
        assert!(matches!(error, CapabilityError::InvalidParams { .. }));
    }

    #[test]
    fn policy_validation_reports_structured_errors_without_updating() {
        let validation = validate_capability_execution_policy_payload(json!({
            "allowedContracts": "filesystem::read_file"
        }));
        assert_eq!(validation["valid"], json!(false));
        assert!(
            validation["errors"]
                .as_array()
                .is_some_and(|errors| !errors.is_empty())
        );
    }

    #[test]
    fn retired_harness_symbols_do_not_reappear_in_runtime_source() {
        let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let src = manifest.join("src");
        let forbidden = [
            concat!("Tron", "ModelCapability"),
            concat!("ModelCapability", "Context"),
            concat!("capability", "_runtime"),
            concat!("builtin", "_function", "_registrations"),
            concat!("Mcp", "Search"),
            concat!("Mcp", "Call"),
            concat!("Engine", "Discover"),
            concat!("Engine", "Inspect"),
            concat!("Engine", "Invoke"),
            concat!("Engine", "Watch"),
            concat!("allowed", "Too", "ls"),
            concat!("denied", "Too", "ls"),
            concat!("inherit", "Too", "ls"),
            concat!("to", "ol", "Policy"),
            concat!("to", "ol", "Policies"),
            concat!("allowed", "_tools"),
            concat!("denied", "_tools"),
            concat!("inherit", "_tools"),
            concat!("PROGRAM", "_RUNTIME", "_NOT", "_LINKED"),
            concat!("Ask", "User", "Question"),
            concat!("Web", "Fetch"),
            concat!("Web", "Search"),
            concat!("Spawn", "Subagent"),
        ];
        let mut failures = Vec::new();
        scan_source_for_forbidden(&src, &forbidden, &mut failures);
        assert!(
            failures.is_empty(),
            "retired harness symbols found:\n{}",
            failures.join("\n")
        );
    }

    fn scan_source_for_forbidden(
        path: &std::path::Path,
        forbidden: &[&str],
        failures: &mut Vec<String>,
    ) {
        let Ok(entries) = std::fs::read_dir(path) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                scan_source_for_forbidden(&path, forbidden, failures);
                continue;
            }
            if path.extension().and_then(|ext| ext.to_str()) != Some("rs") {
                continue;
            }
            if path.ends_with("domains/session/event_store/types/generated.rs") {
                continue;
            }
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            for symbol in forbidden {
                if text.contains(symbol) {
                    failures.push(format!("{} contains {symbol}", path.display()));
                }
            }
        }
    }
}
