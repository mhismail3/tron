//! Live capability projection and execution primitives.
//!
//! The functions here intentionally adapt the existing engine catalog rather
//! than creating a second capability catalog. A catalog function is projected as a
//! stable contract plus one concrete implementation. Future plugin manifests
//! can add richer contract/binding rows without changing the model-facing
//! single `execute` surface.

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use super::Deps;
use super::registry::{
    CapabilityContextPrimerPolicy, CapabilityRegistryEntry, CapabilityRegistrySnapshot,
    CapabilityRegistryStore, CapabilitySearchPolicy, CapabilityTarget, binding_decision,
    bool_field, parse_target, render_capability_primer as render_primer_from_snapshot,
    requires_fresh_revision, string_field, u64_field,
};
use super::types::{
    CapabilityBindingDecision, CapabilityIndexHit, CapabilityIndexStatus, CapabilityPluginManifest,
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
use crate::shared::paths::files;
use crate::shared::profile::CapabilityExecutionPolicySpec;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::error_mapping::engine_error_to_capability_error;
use crate::shared::server::errors::{self as capability_error_codes, CapabilityError};

static IN_FLIGHT_VECTOR_WARMUP_SIGNATURE: AtomicU64 = AtomicU64::new(0);

mod audit;
mod execute;
mod inspect;
mod run;
mod search;

pub(crate) use audit::audit_query_value;
#[cfg(test)]
use audit::{audit_event_matches_orchestration_filters, filter_orchestration_audit_result};
pub(crate) use execute::execute_value;
#[cfg(test)]
use execute::{
    apply_argument_schema_fit_filter, apply_deterministic_intent_route,
    clarification_candidates_for_intent, deterministic_intent_route, intent_strongly_matches_hit,
    lacks_sufficient_intent_resolution_evidence, normalize_target_idempotency_argument,
    normalize_target_specific_arguments, orchestration_constraints_allow_hit,
    orchestration_hit_from_entry, parse_orchestrated_execute_input, prepared_execute_payload,
    promote_argument_schema_fit_candidates, validate_orchestration_constraint_shape,
    validate_orchestration_constraints,
};
#[cfg(test)]
use inspect::inspect_targets;
pub(crate) use inspect::{inspect_value, status_value};
#[cfg(test)]
use run::{
    approval_child_invocation_ids_from_records, approval_was_replayed_for_invocation,
    approved_execution_result, child_execute_causal_context, payload_preflight_status,
    preflight_rejection_result,
};
pub(crate) use search::search_value;
#[cfg(test)]
use search::{render_search_result_value, search_queries};

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
            actor: Some(actor),
            health: Some(FunctionHealth::Healthy),
            ..FunctionQuery::default()
        })
        .await;
    let revision = engine_host.catalog_revision().await;
    let snapshot = CapabilityRegistrySnapshot::new(functions, revision.0);
    Ok(render_primer_from_snapshot(&snapshot, policy))
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

fn validate_target_payload(
    entry: &CapabilityRegistryEntry,
    payload: &Value,
) -> Result<(), CapabilityError> {
    let function = &entry.function;
    if let Some(schema) = &function.request_schema {
        crate::engine::schema::validate_payload(&function.id, "request", schema, payload)
            .map_err(|error| recipe_validation_error_for_payload(entry, payload, error))?;
    }
    Ok(())
}

fn recipe_validation_error_for_payload(
    entry: &CapabilityRegistryEntry,
    payload: &Value,
    error: crate::engine::EngineError,
) -> CapabilityError {
    let schema_details = schema_violation_details(
        &error,
        entry.function.request_schema.as_ref(),
        Some(payload),
    );
    recipe_validation_error_with_schema_details(entry, error, schema_details)
}

fn recipe_validation_error_with_schema_details(
    entry: &CapabilityRegistryEntry,
    error: crate::engine::EngineError,
    schema_details: Option<Value>,
) -> CapabilityError {
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

fn schema_violation_details(
    error: &crate::engine::EngineError,
    schema: Option<&Value>,
    payload: Option<&Value>,
) -> Option<Value> {
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
        let parent_path = schema_path_parent(path);
        let missing = schema_path_leaf(path);
        let (missing_fields, missing_argument_paths) =
            missing_required_arguments(schema, payload, &parent_path).unwrap_or_else(|| {
                (
                    vec![missing.clone()],
                    vec![schema_path_to_argument_path(path)],
                )
            });
        details["validationKind"] = json!("missing_required_argument");
        details["missingFields"] = json!(missing_fields);
        details["missingArgumentPaths"] = json!(missing_argument_paths);
    }
    Some(details)
}

fn missing_required_arguments(
    schema: Option<&Value>,
    payload: Option<&Value>,
    parent_path: &str,
) -> Option<(Vec<String>, Vec<String>)> {
    let schema_parent = schema_node_at_path(schema?, parent_path)?;
    let payload_parent = payload_node_at_path(payload?, parent_path)?;
    let required = schema_parent.get("required")?.as_array()?;
    let payload_object = payload_parent.as_object()?;
    let mut missing_fields = Vec::new();
    let mut missing_argument_paths = Vec::new();
    for item in required {
        let field = item.as_str()?;
        if !payload_object.contains_key(field) {
            missing_fields.push(field.to_owned());
            missing_argument_paths.push(argument_path_for_field(parent_path, field));
        }
    }
    if missing_fields.is_empty() {
        None
    } else {
        Some((missing_fields, missing_argument_paths))
    }
}

fn schema_node_at_path<'a>(schema: &'a Value, path: &str) -> Option<&'a Value> {
    let mut node = schema;
    for token in schema_path_tokens(path) {
        match token {
            SchemaPathToken::Property(name) => {
                node = node.get("properties")?.get(name)?;
            }
            SchemaPathToken::Index(_) => {
                node = node.get("items")?;
            }
        }
    }
    Some(node)
}

fn payload_node_at_path<'a>(payload: &'a Value, path: &str) -> Option<&'a Value> {
    let mut node = payload;
    for token in schema_path_tokens(path) {
        match token {
            SchemaPathToken::Property(name) => {
                node = node.as_object()?.get(name)?;
            }
            SchemaPathToken::Index(index) => {
                node = node.as_array()?.get(index)?;
            }
        }
    }
    Some(node)
}

#[derive(Debug, PartialEq, Eq)]
enum SchemaPathToken<'a> {
    Property(&'a str),
    Index(usize),
}

fn schema_path_tokens(path: &str) -> Vec<SchemaPathToken<'_>> {
    let mut tokens = Vec::new();
    let Some(mut rest) = path.strip_prefix('$') else {
        return tokens;
    };
    while !rest.is_empty() {
        if let Some(after_dot) = rest.strip_prefix('.') {
            let next_dot = after_dot.find('.');
            let next_bracket = after_dot.find('[');
            let end = match (next_dot, next_bracket) {
                (Some(dot), Some(bracket)) => dot.min(bracket),
                (Some(dot), None) => dot,
                (None, Some(bracket)) => bracket,
                (None, None) => after_dot.len(),
            };
            if end == 0 {
                break;
            }
            tokens.push(SchemaPathToken::Property(&after_dot[..end]));
            rest = &after_dot[end..];
            continue;
        }
        if let Some(after_bracket) = rest.strip_prefix('[') {
            let Some(end) = after_bracket.find(']') else {
                break;
            };
            if let Ok(index) = after_bracket[..end].parse::<usize>() {
                tokens.push(SchemaPathToken::Index(index));
            }
            rest = &after_bracket[end + 1..];
            continue;
        }
        break;
    }
    tokens
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

fn schema_path_parent(path: &str) -> String {
    let Some(last_dot) = path.rfind('.') else {
        return "$".to_owned();
    };
    if last_dot == 0 {
        "$".to_owned()
    } else {
        path[..last_dot].to_owned()
    }
}

fn argument_path_for_field(parent_path: &str, field: &str) -> String {
    if parent_path == "$" || parent_path.is_empty() {
        format!("arguments.{field}")
    } else {
        format!("{}.{}", schema_path_to_argument_path(parent_path), field)
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
    fn orchestrated_execute_normalizes_flattened_target_arguments() {
        let input = parse_orchestrated_execute_input(&json!({
            "path": "packages/agent/src",
            "pattern": "FunctionDefinition",
            "context": 2,
            "maxResults": 20,
            "reason": "Search source for function definitions."
        }))
        .expect("flattened target arguments are accepted");

        assert!(input.target_params.is_none());
        assert_eq!(input.arguments["path"], json!("packages/agent/src"));
        assert_eq!(input.arguments["pattern"], json!("FunctionDefinition"));
        assert_eq!(input.arguments["context"], json!(2));
        assert_eq!(input.arguments["maxResults"], json!(20));
        assert_eq!(
            input.reason.as_deref(),
            Some("Search source for function definitions.")
        );
        assert!(
            input.corrections.iter().any(|correction| {
                correction["kind"] == json!("top_level_arguments_to_arguments")
            })
        );
    }

    #[test]
    fn orchestrated_execute_dedupes_identical_flattened_argument_duplicates() {
        let input = parse_orchestrated_execute_input(&json!({
            "arguments": {
                "path": "packages/agent/src/engine/host.rs",
                "startLine": 2060,
                "endLine": 2300
            },
            "target": "filesystem::read_file",
            "path": "packages/agent/src/engine/host.rs",
            "startLine": 2060,
            "endLine": 2300
        }))
        .expect("identical duplicate flattened arguments should be deduped");

        assert_eq!(
            input.arguments["path"],
            json!("packages/agent/src/engine/host.rs")
        );
        assert_eq!(input.arguments["startLine"], json!(2060));
        assert_eq!(input.arguments["endLine"], json!(2300));
        assert!(input.corrections.iter().any(|correction| {
            correction["kind"] == json!("duplicate_flattened_arguments_deduped")
        }));
    }

    #[test]
    fn orchestrated_execute_rejects_conflicting_flattened_argument_duplicates() {
        let error = parse_orchestrated_execute_input(&json!({
            "arguments": {"path": "README.md"},
            "path": "packages/agent/src"
        }))
        .expect_err("conflicting flattened arguments should be explicit");

        assert!(
            error
                .to_string()
                .contains("conflicting values for target argument 'path'")
        );
    }

    #[test]
    fn orchestrated_execute_forwards_wrapper_idempotency_when_target_schema_requires_it() {
        let mut function = test_function("ui::submit_action");
        function.request_schema = Some(json!({
            "type": "object",
            "required": [
                "surfaceResourceId",
                "surfaceVersionId",
                "actionId",
                "userInput",
                "idempotencyKey"
            ],
            "additionalProperties": false,
            "properties": {
                "surfaceResourceId": {"type": "string"},
                "surfaceVersionId": {"type": "string"},
                "actionId": {"type": "string"},
                "userInput": {"type": "object"},
                "idempotencyKey": {"type": "string"}
            }
        }));
        let mut input = parse_orchestrated_execute_input(&json!({
            "target": "ui::submit_action",
            "arguments": {
                "surfaceResourceId": "ui-surface-resource_collection-artifact-prompt-snippet",
                "surfaceVersionId": "ver_test",
                "actionId": "create-snippet",
                "userInput": {"name": "Gateway", "text": "Created through stored UI action"}
            },
            "idempotencyKey": "ui-action-submit-key"
        }))
        .expect("input");

        normalize_target_idempotency_argument(
            &function,
            &mut input.arguments,
            input.idempotency_key.as_deref(),
            &mut input.corrections,
        );

        assert_eq!(
            input.arguments["idempotencyKey"],
            json!("ui-action-submit-key")
        );
        assert!(input.corrections.iter().any(|correction| {
            correction["kind"] == json!("wrapper_idempotency_key_to_target_argument")
        }));
        let prepared = prepared_execute_payload(input.target_params.as_ref().unwrap(), &input);
        assert_eq!(prepared["idempotencyKey"], json!("ui-action-submit-key"));
        assert_eq!(
            prepared["payload"]["idempotencyKey"],
            json!("ui-action-submit-key")
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
    fn orchestrated_execute_normalizes_list_dir_max_entries_alias_before_schema_validation() {
        let list_dir_spec = crate::domains::filesystem::contract::capabilities()
            .expect("filesystem specs")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "filesystem::list_dir")
            .expect("filesystem::list_dir spec");
        let function = crate::domains::contract::function_definition_for_capability(&list_dir_spec);
        let entry = CapabilityRegistryEntry::from_function(function.clone(), 79);
        let mut arguments = json!({
            "path": ".",
            "maxEntries": 20
        });
        let mut corrections = Vec::new();

        normalize_target_specific_arguments(&function, &mut arguments, &mut corrections);

        assert_eq!(arguments["maxResults"], json!(20));
        assert!(arguments.get("maxEntries").is_none());
        assert!(corrections.iter().any(|correction| {
            correction["kind"] == json!("filesystem_list_dir_max_entries_alias")
        }));
        validate_target_payload(&entry, &arguments)
            .expect("normalized list_dir payload schema-valid");
    }

    #[test]
    fn orchestrated_execute_normalizes_web_search_result_limit_aliases_before_schema_validation() {
        let web_search_spec = crate::domains::web::contract::capabilities()
            .expect("web specs")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "web::search")
            .expect("web::search spec");
        let function =
            crate::domains::contract::function_definition_for_capability(&web_search_spec);
        let entry = CapabilityRegistryEntry::from_function(function.clone(), 80);
        let mut arguments = json!({
            "query": "official OpenAI model docs",
            "maxResults": 5
        });
        let mut corrections = Vec::new();

        normalize_target_specific_arguments(&function, &mut arguments, &mut corrections);

        assert_eq!(arguments["count"], json!(5));
        assert!(arguments.get("maxResults").is_none());
        assert!(
            corrections
                .iter()
                .any(|correction| { correction["kind"] == json!("web_search_count_alias") })
        );
        validate_target_payload(&entry, &arguments)
            .expect("normalized web::search payload schema-valid");
    }

    #[test]
    fn orchestrated_execute_normalizes_apply_patch_append_intent() {
        let apply_patch_spec = crate::domains::filesystem::contract::capabilities()
            .expect("filesystem specs")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "filesystem::apply_patch")
            .expect("filesystem::apply_patch spec");
        let function =
            crate::domains::contract::function_definition_for_capability(&apply_patch_spec);
        let entry = CapabilityRegistryEntry::from_function(function.clone(), 78);
        let mut arguments = json!({
            "path": "README.md",
            "newString": "Execute append smoke\n"
        });
        let mut corrections = Vec::new();

        normalize_target_specific_arguments(&function, &mut arguments, &mut corrections);

        assert_eq!(arguments["oldString"], json!(""));
        assert!(corrections.iter().any(|correction| {
            correction["kind"] == json!("filesystem_apply_patch_append_shape")
        }));
        validate_target_payload(&entry, &arguments)
            .expect("normalized append payload schema-valid");
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
    fn low_confidence_unanchored_intent_is_not_treated_as_selection() {
        let hit = CapabilityIndexHit {
            kind: "implementation".to_owned(),
            capability_id: "module::verify_source".to_owned(),
            contract_id: "module::verify_source".to_owned(),
            implementation_id: "first_party.module.v1.verify_source".to_owned(),
            plugin_id: "first_party.module".to_owned(),
            worker_id: "module".to_owned(),
            function_id: "module::verify_source".to_owned(),
            catalog_revision: 1,
            schema_digest: "digest".to_owned(),
            trust_tier: "first_party_signed".to_owned(),
            health: "Healthy".to_owned(),
            visibility: "system".to_owned(),
            effect_class: "idempotent_write".to_owned(),
            risk_level: "medium".to_owned(),
            lexical_score: 0.01,
            vector_score: Some(0.07),
            fused_score: 0.07,
            matched_by: "hybrid_local".to_owned(),
            snippet: "verify package source refs".to_owned(),
            requires_inspect: false,
            recipe: None,
        };

        assert!(lacks_sufficient_intent_resolution_evidence(
            "calibrate the starship warp-core coolant pump",
            &json!({}),
            &hit
        ));

        let anchored_arguments = json!({"expectedCurrentVersionId": "ver_test"});
        assert!(!lacks_sufficient_intent_resolution_evidence(
            "verify source",
            &anchored_arguments,
            &hit
        ));
    }

    #[test]
    fn high_score_lexical_noise_without_anchor_is_not_treated_as_selection() {
        let hit = CapabilityIndexHit {
            kind: "implementation".to_owned(),
            capability_id: "module::run_conformance".to_owned(),
            contract_id: "module::run_conformance".to_owned(),
            implementation_id: "first_party.module.v1.run_conformance".to_owned(),
            plugin_id: "first_party.module".to_owned(),
            worker_id: "module".to_owned(),
            function_id: "module::run_conformance".to_owned(),
            catalog_revision: 1,
            schema_digest: "digest".to_owned(),
            trust_tier: "first_party_signed".to_owned(),
            health: "Healthy".to_owned(),
            visibility: "system".to_owned(),
            effect_class: "idempotent_write".to_owned(),
            risk_level: "medium".to_owned(),
            lexical_score: 11.17,
            vector_score: None,
            fused_score: 11.17,
            matched_by: "local_lexical".to_owned(),
            snippet: "record bounded package runtime conformance evidence".to_owned(),
            requires_inspect: false,
            recipe: None,
        };

        assert!(lacks_sufficient_intent_resolution_evidence(
            "calibrate warp-core coolant harmonics for a starship drive",
            &json!({}),
            &hit
        ));
    }

    #[test]
    fn vague_known_namespace_intent_returns_clarification_candidates() {
        let read = test_function("filesystem::read_file");
        let search = test_function("filesystem::search_text");
        let process = test_function("process::run");
        let execute = test_function("capability::execute");
        let snapshot = CapabilityRegistrySnapshot::new(vec![process, execute, search, read], 11);

        let candidates = clarification_candidates_for_intent(
            "do something useful with files",
            &snapshot,
            &json!({}),
        )
        .expect("clarification")
        .expect("filesystem candidates");

        assert!(
            candidates
                .iter()
                .any(|candidate| candidate["functionId"] == json!("filesystem::read_file"))
        );
        assert!(
            candidates
                .iter()
                .any(|candidate| candidate["functionId"] == json!("filesystem::search_text"))
        );
        assert!(
            candidates
                .iter()
                .all(|candidate| candidate["functionId"] != json!("process::run"))
        );
        assert!(
            candidates
                .iter()
                .all(|candidate| candidate["functionId"] != json!("capability::execute"))
        );
        assert!(candidates.iter().all(|candidate| {
            candidate["matchedBy"] == json!("namespace_clarification")
                && candidate["score"].as_f64().is_some_and(|score| score > 0.0)
        }));
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
    fn orchestration_argument_fit_promotes_schema_match_missing_from_search_hits() {
        let process_spec = crate::domains::process::contract::capabilities()
            .expect("process specs")
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "process::run")
            .expect("process::run spec");
        let mut unrelated = test_function("job::stream_output");
        unrelated.request_schema = Some(json!({
            "type": "object",
            "additionalProperties": false,
            "required": ["jobId"],
            "properties": {
                "jobId": {"type": "string"},
                "offset": {"type": "integer"}
            }
        }));
        let snapshot = CapabilityRegistrySnapshot::new(
            vec![
                unrelated.clone(),
                crate::domains::contract::function_definition_for_capability(&process_spec),
            ],
            44,
        );
        let mut hits = vec![orchestration_hit_from_entry(
            &CapabilityRegistryEntry::from_function(unrelated, 44),
            "hybrid_local",
            0.09,
        )];

        promote_argument_schema_fit_candidates(
            &json!({
                "command": "date",
                "executionMode": "read_only"
            }),
            &snapshot,
            &json!({}),
            &mut hits,
        )
        .expect("promotion");
        let rejected = apply_argument_schema_fit_filter(
            &json!({
                "command": "date",
                "executionMode": "read_only"
            }),
            &snapshot,
            &mut hits,
        );

        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].function_id, "process::run");
        assert_eq!(hits[0].matched_by, "argument_schema_fit");
        assert!(
            rejected.iter().any(|candidate| {
                candidate["functionId"] == json!("job::stream_output")
                    && candidate["rejectionReason"] == json!("argument_missing_required")
            }),
            "search hits that do not accept the supplied arguments must be rejected"
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
        assert_eq!(details["missingFields"], json!(["command"]));
        assert_eq!(
            details["missingArgumentPaths"],
            json!(["arguments.command"])
        );
        assert_eq!(
            details["guidance"]["missingArgumentPaths"],
            json!(["arguments.command"])
        );
        assert_eq!(details["childInvocationIds"], json!([]));
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
    fn execute_missing_required_arguments_reports_complete_same_scope_set() {
        let mut function = test_function("process::run");
        function.request_schema = Some(json!({
            "type": "object",
            "additionalProperties": false,
            "required": ["command", "executionMode"],
            "properties": {
                "command": {"type": "string"},
                "executionMode": {"type": "string", "enum": ["read_only", "sandbox_materialized"]},
                "expectedOutputs": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["path", "targetPath"],
                        "properties": {
                            "path": {"type": "string"},
                            "targetPath": {"type": "string"}
                        }
                    }
                }
            }
        }));
        let entry = CapabilityRegistryEntry::from_function(function.clone(), 77);
        let target = ResolvedCapabilityTarget {
            binding_decision: decision_for_entry(&entry, "test", Vec::new()),
            entry: entry.clone(),
        };
        let error = validate_target_payload(&entry, &json!({})).expect_err("payload error");

        let value = preflight_rejection_result(&function, &target, error, "needs_input")
            .expect("structured result");
        let details = value["details"].clone();
        assert_eq!(
            details["error"]["details"]["missingFields"],
            json!(["command", "executionMode"])
        );
        assert_eq!(
            details["missingFields"],
            json!(["command", "executionMode"])
        );
        assert_eq!(
            details["missingArgumentPaths"],
            json!(["arguments.command", "arguments.executionMode"])
        );
        assert_eq!(
            details["guidance"]["missingArgumentPaths"],
            json!(["arguments.command", "arguments.executionMode"])
        );

        let nested_error = validate_target_payload(
            &entry,
            &json!({
                "command": "echo hi",
                "executionMode": "sandbox_materialized",
                "expectedOutputs": [{}]
            }),
        )
        .expect_err("nested payload error");
        let nested_value =
            preflight_rejection_result(&function, &target, nested_error, "needs_input")
                .expect("structured result");
        let nested_details = nested_value["details"].clone();
        assert_eq!(
            nested_details["error"]["details"]["missingFields"],
            json!(["path", "targetPath"])
        );
        assert_eq!(
            nested_details["missingFields"],
            json!(["path", "targetPath"])
        );
        assert_eq!(
            nested_details["missingArgumentPaths"],
            json!([
                "arguments.expectedOutputs[0].path",
                "arguments.expectedOutputs[0].targetPath"
            ])
        );
        assert_eq!(
            nested_details["guidance"]["missingArgumentPaths"],
            json!([
                "arguments.expectedOutputs[0].path",
                "arguments.expectedOutputs[0].targetPath"
            ])
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
