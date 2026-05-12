//! Live capability projection and execution primitives.
//!
//! The functions here intentionally adapt the existing engine catalog rather
//! than creating a second capability catalog. A catalog function is projected as a
//! stable contract plus one concrete implementation. Future plugin manifests
//! can add richer contract/binding rows without changing the model-facing
//! `search`/`inspect`/`execute` surface.

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::Deps;
use super::registry::{
    CapabilityContextPrimerPolicy, CapabilityRegistryEntry, CapabilityRegistrySnapshot,
    CapabilityRegistryStore, CapabilitySearchFilters, CapabilitySearchPolicy, CapabilityTarget,
    binding_decision, bool_field, parse_target,
    render_capability_primer as render_primer_from_snapshot, requires_fresh_revision, string_field,
    u64_field,
};
use super::types::{
    CapabilityBindingDecision, CapabilityExecutionRecord, CapabilityRejectedCandidate,
};
use crate::engine::{
    ActorContext, ActorKind, AuthorityGrantId, CausalContext, DeliveryMode, EffectClass,
    EngineApprovalRequest, FunctionDefinition, FunctionHealth, FunctionQuery, FunctionRevision,
    Invocation, RiskLevel,
};
use crate::shared::content::ToolResultContent;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::error_mapping::engine_error_to_capability_error;
use crate::shared::server::errors::CapabilityError;
use crate::shared::tools::{CapabilityResult, ToolResultBody};

const DEFAULT_LIMIT: usize = 12;
const MAX_LIMIT: usize = 50;
const CAPABILITY_ALLOW_SCOPE_PREFIX: &str = "capability.allow:";
const CAPABILITY_DENY_SCOPE_PREFIX: &str = "capability.deny:";

pub(crate) async fn search_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let params = &invocation.payload;
    let query = string_field(params, "query").unwrap_or_default();
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
    let query_for_index = query.clone();
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
        if let Err(error) = store.sync_snapshot(&snapshot, embedding_provider.as_ref(), &policy) {
            let _ = store.record_audit_event(
                "capability.search",
                Some(&trace_id),
                json!({
                    "status": "error",
                    "query": query_for_index,
                    "catalogRevision": catalog_revision_value,
                    "error": error.clone(),
                }),
            );
            return Err(registry_store_error(error));
        }
        let result = store
            .search(
                &query_for_index,
                &filters_for_index,
                &policy,
                index_limit,
                embedding_provider.as_ref(),
            )
            .map_err(registry_store_error)?;
        store
            .record_audit_event(
                "capability.search",
                Some(&trace_id),
                json!({
                    "query": query_for_index,
                    "filters": {
                        "kind": filters_for_index.kind,
                        "contractId": filters_for_index.contract_id,
                        "namespace": filters_for_index.namespace,
                        "pluginId": filters_for_index.plugin_id,
                    },
                    "catalogRevision": catalog_revision_value,
                    "indexStatus": result.status.clone(),
                }),
            )
            .map_err(registry_store_error)?;
        Ok(result)
    })
    .await?;
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
    let results = serde_json::to_value(&page_hits).map_err(|error| CapabilityError::Internal {
        message: error.to_string(),
    })?;
    let summary = render_search_summary(&query, &results);
    tool_result_value(CapabilityResult {
        content: ToolResultBody::Blocks(vec![ToolResultContent::text(summary)]),
        details: Some(json!({
            "query": query,
            "catalogRevision": catalog_revision.0,
            "results": results,
            "nextCursor": next_cursor,
            "searchMode": search_result.status
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
    let target = resolve_target(&invocation.payload, deps, &actor).await?;
    let inspection = target.entry.inspection(target.binding_decision.clone());
    {
        let store = deps.registry_store.clone();
        let entry = target.entry.clone();
        let decision = target.binding_decision.clone();
        let handle = inspection.inspection_handle.clone();
        let trace_id = invocation.causal_context.trace_id.as_str().to_owned();
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
    let details = serde_json::to_value(inspection).map_err(|error| CapabilityError::Internal {
        message: error.to_string(),
    })?;
    let summary = render_inspection_summary(&details);
    tool_result_value(CapabilityResult {
        content: ToolResultBody::Blocks(vec![ToolResultContent::text(summary)]),
        details: Some(details),
        is_error: None,
        stop_turn: None,
    })
}

pub(crate) async fn execute_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let mode = string_field(&invocation.payload, "mode").unwrap_or_else(|| "invoke".to_owned());
    match mode.as_str() {
        "invoke" => execute_invoke_value(invocation, deps).await,
        other => Err(CapabilityError::InvalidParams {
            message: format!("Unsupported capability execute mode '{other}'"),
        }),
    }
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
            message: "execute cannot recursively invoke capability primitives; call search or inspect directly".to_owned(),
        });
    }
    enforce_execution_policy(invocation, &target.binding_decision, &function)?;

    let expected_revision = u64_field(&invocation.payload, "expectedRevision");
    let expected_schema_digest = string_field(&invocation.payload, "expectedSchemaDigest")
        .or_else(|| string_field(&invocation.payload, "expected_schema_digest"));
    let inspection_handle = string_field(&invocation.payload, "inspectionHandle")
        .or_else(|| string_field(&invocation.payload, "inspection_handle"));
    if requires_fresh_revision(&function) {
        if expected_revision.is_none()
            || expected_schema_digest.is_none()
            || inspection_handle.is_none()
        {
            return Err(CapabilityError::Custom {
                code: "INSPECTION_REQUIRED".to_owned(),
                message: format!(
                    "{} is mutating or elevated-risk; inspect it first and pass inspectionHandle, expectedRevision={}, and expectedSchemaDigest={}",
                    function.id.as_str(),
                    function.revision.0,
                    target.entry.schema_digest
                ),
                details: Some(json!({
                    "functionId": function.id.as_str(),
                    "inspect": {
                        "functionId": function.id.as_str(),
                        "expectedRevision": function.revision.0,
                        "expectedSchemaDigest": target.entry.schema_digest
                    },
                    "riskLevel": format!("{:?}", function.risk_level),
                    "effectClass": format!("{:?}", function.effect_class)
                })),
            });
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
    let idempotency_key = child_idempotency_key(
        invocation,
        &function,
        &payload,
        function.effect_class.is_mutating(),
    )?;
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

    let mut child = Invocation::new_sync(function.id.clone(), payload, causal_context);
    if let Some(expected) = expected_revision {
        child = child.expecting_revision(FunctionRevision(expected));
    }
    if function.required_authority.approval_required {
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
        return tool_result_value(CapabilityResult {
            content: ToolResultBody::Blocks(vec![ToolResultContent::text(format!(
                "Approval required before executing {}.",
                function.id.as_str()
            ))]),
            details: Some(json!({
                "status": "approval_required",
                "approvalState": {
                    "approvalId": approval.approval_id,
                    "status": approval.status,
                    "functionId": function.id.as_str(),
                    "traceId": approval.trace_id.as_str()
                },
                "selectedImplementation": target.binding_decision.selected_implementation,
                "bindingDecision": target.binding_decision
            })),
            is_error: Some(true),
            stop_turn: Some(true),
        });
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
        return tool_result_value(nested);
    }

    let text = serde_json::to_string_pretty(&output).unwrap_or_else(|_| output.to_string());
    tool_result_value(CapabilityResult {
        content: ToolResultBody::Blocks(vec![ToolResultContent::text(text)]),
        details: Some(details),
        is_error: None,
        stop_turn: None,
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

    let candidates = [
        decision.contract_id.as_str(),
        decision.selected_implementation.as_str(),
        decision.selected_function_id.as_str(),
        function.id.as_str(),
    ];
    if policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        CAPABILITY_DENY_SCOPE_PREFIX,
        &candidates,
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
    if policy_scope_matches(
        &invocation.causal_context.authority_scopes,
        CAPABILITY_ALLOW_SCOPE_PREFIX,
        &candidates,
    ) {
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
                "{} mutates state; pass idempotencyKey or invoke through a model tool call with engine idempotency",
                function.id.as_str()
            ),
        });
    }
    Ok(None)
}

fn render_search_summary(query: &str, results: &Value) -> String {
    let result_values = results.as_array().cloned().unwrap_or_default();
    if result_values.is_empty() {
        return if query.trim().is_empty() {
            "No visible capabilities found.".to_owned()
        } else {
            format!("No visible capabilities found for '{query}'.")
        };
    }
    let mut lines = vec![format!(
        "Found {} visible capabilities. Inspect one before executing mutating or elevated-risk work.",
        result_values.len()
    )];
    for result in result_values.iter().take(8) {
        let function_id = result
            .get("functionId")
            .and_then(Value::as_str)
            .unwrap_or("<unknown>");
        let contract_id = result
            .get("contractId")
            .and_then(Value::as_str)
            .unwrap_or("<unknown>");
        lines.push(format!("- {contract_id} -> {function_id}"));
    }
    lines.join("\n")
}

fn render_inspection_summary(details: &Value) -> String {
    let implementation = &details["implementation"];
    let contract = &details["contract"];
    let function_id = implementation["functionId"].as_str().unwrap_or("<unknown>");
    let contract_id = contract["contractId"].as_str().unwrap_or("<unknown>");
    let effect = contract["effectClass"].as_str().unwrap_or("unknown");
    let risk = contract["riskLevel"].as_str().unwrap_or("unknown");
    let expected = details["executionRequirements"]["expectedRevision"]
        .as_u64()
        .unwrap_or_default();
    format!(
        "{contract_id} is implemented by {function_id}. effect={effect}, risk={risk}, expectedRevision={expected}."
    )
}

fn tool_result_value(result: CapabilityResult) -> Result<Value, CapabilityError> {
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
    let Some(value) = string_field(params, key) else {
        return Ok(None);
    };
    match value.to_ascii_lowercase().as_str() {
        "low" => Ok(Some(RiskLevel::Low)),
        "medium" => Ok(Some(RiskLevel::Medium)),
        "high" => Ok(Some(RiskLevel::High)),
        "critical" => Ok(Some(RiskLevel::Critical)),
        _ => Err(CapabilityError::InvalidParams {
            message: format!("Unsupported riskMax '{value}'"),
        }),
    }
}

fn effect_field(params: &Value, key: &str) -> Result<Option<EffectClass>, CapabilityError> {
    let Some(value) = string_field(params, key) else {
        return Ok(None);
    };
    let normalized = value
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .collect::<String>()
        .to_ascii_lowercase();
    match normalized.as_str() {
        "pureread" => Ok(Some(EffectClass::PureRead)),
        "deterministiccompute" => Ok(Some(EffectClass::DeterministicCompute)),
        "delegatedinvocation" => Ok(Some(EffectClass::DelegatedInvocation)),
        "idempotentwrite" => Ok(Some(EffectClass::IdempotentWrite)),
        "appendonlyevent" => Ok(Some(EffectClass::AppendOnlyEvent)),
        "reversiblesideeffect" => Ok(Some(EffectClass::ReversibleSideEffect)),
        "externalsideeffect" => Ok(Some(EffectClass::ExternalSideEffect)),
        "irreversiblesideeffect" => Ok(Some(EffectClass::IrreversibleSideEffect)),
        _ => Err(CapabilityError::InvalidParams {
            message: format!("Unsupported effect '{value}'"),
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
    use crate::engine::{FunctionId, VisibilityScope, WorkerId};

    fn test_function(id: &str) -> FunctionDefinition {
        FunctionDefinition::new(
            FunctionId::new(id).expect("function id"),
            WorkerId::new(id.split("::").next().expect("namespace")).expect("worker id"),
            "Searchable test function",
            VisibilityScope::System,
            EffectClass::PureRead,
        )
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
    fn child_idempotency_derives_from_parent_tool_call_key() {
        let function = test_function("filesystem::read_file");
        let causal = CausalContext::new(
            crate::engine::ActorId::new("agent:s1").expect("actor id"),
            ActorKind::Agent,
            AuthorityGrantId::new("agent-tool-runtime").expect("grant id"),
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
    fn agent_search_requires_profile_policy_runtime_metadata() {
        let causal = CausalContext::new(
            crate::engine::ActorId::new("agent:s1").expect("actor id"),
            ActorKind::Agent,
            AuthorityGrantId::new("agent-tool-runtime").expect("grant id"),
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
            AuthorityGrantId::new("agent-tool-runtime").expect("grant id"),
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
    fn retired_harness_symbols_do_not_reappear_in_runtime_source() {
        let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let src = manifest.join("src");
        let forbidden = [
            concat!("Tron", "Tool"),
            concat!("Tool", "Context"),
            concat!("capability", "_runtime"),
            concat!("builtin", "_function", "_registrations"),
            concat!("Mcp", "Search"),
            concat!("Mcp", "Call"),
            concat!("Engine", "Discover"),
            concat!("Engine", "Inspect"),
            concat!("Engine", "Invoke"),
            concat!("Engine", "Watch"),
            concat!("allowed", "Tools"),
            concat!("denied", "Tools"),
            concat!("inherit", "Tools"),
            concat!("tool", "Policy"),
            concat!("tool", "Policies"),
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
