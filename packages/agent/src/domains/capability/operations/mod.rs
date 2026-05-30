//! Live capability projection and execution primitives.
//!
//! The functions here intentionally adapt the existing engine catalog rather
//! than creating a second capability catalog. A catalog function is projected as a
//! stable contract plus one concrete implementation. Future plugin manifests
//! can add richer contract/binding rows without changing the model-facing
//! single `execute` surface. Target-specific argument affordances are isolated in
//! `target_arguments`, deterministic route and argument-fit heuristics live in
//! `target_resolution`, target payload guidance lives in `schema_validation`,
//! model-visible summaries live in `presentation`, and profile policy
//! persistence lives in `policy_profile`, so the shared execute flow does not
//! grow new per-capability branches unnoticed.

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::sync::atomic::{AtomicU64, Ordering};

use super::Deps;
use super::registry::{
    CapabilityContextPrimerPolicy, CapabilityRegistryEntry, CapabilityRegistrySnapshot,
    CapabilityRegistryStore, CapabilitySearchPolicy, CapabilityTarget, binding_decision,
    bool_field, parse_target, render_capability_primer as render_primer_from_snapshot,
    requires_fresh_revision, string_field, u64_field,
};
use super::types::{
    CapabilityBindingDecision, CapabilityIndexStatus, CapabilityPluginManifest,
    CapabilityRejectedCandidate,
};
use crate::domains::capability_support::implementations::primitive_surface::{
    CONTRACT_ALLOW_SCOPE_PREFIX, CONTRACT_DENY_SCOPE_PREFIX, IMPLEMENTATION_ALLOW_SCOPE_PREFIX,
    IMPLEMENTATION_DENY_SCOPE_PREFIX, PLUGIN_ALLOW_SCOPE_PREFIX, PLUGIN_DENY_SCOPE_PREFIX,
};
use crate::engine::{
    ActorContext, ActorKind, AuthorityGrantId, EffectClass, FunctionDefinition, FunctionHealth,
    FunctionQuery, Invocation, RiskLevel,
};
#[cfg(test)]
use crate::engine::{
    ApprovalStatus, CausalContext, DeliveryMode, EngineApprovalRecord, InvocationRecord,
};
#[cfg(test)]
use crate::shared::content::CapabilityResultContent;
use crate::shared::model_capabilities::CapabilityResult;
#[cfg(test)]
use crate::shared::model_capabilities::CapabilityResultBody;
use crate::shared::profile::CapabilityExecutionPolicySpec;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;

static IN_FLIGHT_VECTOR_WARMUP_SIGNATURE: AtomicU64 = AtomicU64::new(0);

mod audit;
mod execute;
mod inspect;
mod policy_profile;
mod presentation;
mod run;
mod schema_validation;
mod search;
mod target_arguments;
mod target_resolution;

pub(crate) use audit::audit_query_value;
#[cfg(test)]
use audit::{audit_event_matches_orchestration_filters, filter_orchestration_audit_result};
pub(crate) use execute::execute_value;
#[cfg(test)]
use execute::{parse_orchestrated_execute_input, prepared_execute_payload};
#[cfg(test)]
use inspect::inspect_targets;
pub(crate) use inspect::{inspect_value, status_value};
use policy_profile::{
    current_profile_toml_path, validate_capability_execution_policy_payload, validate_profile_id,
    write_capability_execution_policy_to_profile_and_reload,
};
use presentation::{
    missing_inspection_requirements_error, render_inspection_summary, render_search_summary,
};
#[cfg(test)]
use run::{
    approval_child_invocation_ids_from_records, approval_was_replayed_for_invocation,
    approved_execution_result, child_execute_causal_context, payload_preflight_status,
    policy_preflight_status, preflight_rejection_result,
};
use schema_validation::validate_target_payload;
pub(crate) use search::search_value;
#[cfg(test)]
use search::{render_search_result_value, search_queries};
#[cfg(test)]
use target_arguments::{
    normalize_target_arguments, normalize_target_idempotency_argument,
    normalize_target_specific_arguments,
};
#[cfg(test)]
use target_resolution::{
    apply_argument_schema_fit_filter, apply_deterministic_intent_route,
    clarification_candidates_for_intent, deterministic_intent_route, intent_strongly_matches_hit,
    lacks_sufficient_intent_resolution_evidence, orchestration_constraints_allow_hit,
    orchestration_hit_from_entry, promote_argument_schema_fit_candidates,
    validate_orchestration_constraint_shape, validate_orchestration_constraints,
};

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
            actor: Some(actor.clone()),
            health: Some(FunctionHealth::Healthy),
            ..FunctionQuery::default()
        })
        .await;
    let revision = engine_host.catalog_revision().await;
    let triggers = engine_host.visible_triggers(&actor).await;
    let snapshot = CapabilityRegistrySnapshot::with_triggers(functions, triggers, revision.0);
    Ok(render_primer_from_snapshot(&snapshot, policy))
}

pub(super) async fn registry_snapshot_for_functions(
    deps: &Deps,
    actor: &ActorContext,
    functions: Vec<FunctionDefinition>,
) -> CapabilityRegistrySnapshot {
    let catalog_revision = deps.engine_host.catalog_revision().await;
    let triggers = deps.engine_host.visible_triggers(actor).await;
    CapabilityRegistrySnapshot::with_triggers(functions, triggers, catalog_revision.0)
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
    let snapshot = registry_snapshot_for_functions(deps, actor, functions).await;
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
            actor: Some(actor.clone()),
            ..FunctionQuery::default()
        })
        .await;
    let snapshot = registry_snapshot_for_functions(deps, &actor, functions).await;
    let catalog_revision = snapshot.catalog_revision;
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

fn capability_primitive_target_error(function: &FunctionDefinition) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: format!(
            "execute cannot target {} because it is a capability primitive. This call is already the execute primitive; set target to the real capability, for example filesystem::read_file or process::run, and put only that target's arguments inside arguments.",
            function.id.as_str()
        ),
    }
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
        if message == crate::domains::process::approval::sandbox_output_path_relative_message() {
            return Err(CapabilityError::Custom {
                code: "INVALID_PARAMS".to_owned(),
                message: message.to_owned(),
                details: Some(json!({
                    "validationKind": "repairable_argument",
                    "invalidFields": ["expectedOutputs[].path"],
                    "invalidArgumentPaths": ["arguments.expectedOutputs[].path"]
                })),
            });
        }
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
            "capability-execute:v2:{}",
            sha256_hex_128(&serialized)
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

fn sha256_hex_128(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(&hasher.finalize()[..16])
}

#[cfg(test)]
mod tests;
