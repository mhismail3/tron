use serde_json::{Value, json};

use super::super::registry::{bool_field, string_field, u64_field};
use super::super::types::CapabilityPluginManifest;
use super::policy_profile::{
    current_profile_toml_path, validate_capability_execution_policy_payload, validate_profile_id,
    write_capability_execution_policy_to_profile_and_reload,
};
use super::{Deps, registry_store_error, sync_registry_for_admin};
use crate::engine::Invocation;
use crate::shared::profile::CapabilityExecutionPolicySpec;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;

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

pub(super) async fn registry_snapshot_from_store(deps: &Deps) -> Result<Value, CapabilityError> {
    let store = deps.registry_store.clone();
    run_blocking_task("capability.registry_snapshot.store", move || {
        let store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store.registry_snapshot().map_err(registry_store_error)
    })
    .await
}

pub(super) async fn record_admin_audit(
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

pub(super) async fn inspect_plugin_manifest(
    deps: &Deps,
    plugin_id: &str,
) -> Result<Value, CapabilityError> {
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

pub(super) async fn upsert_plugin_from_payload(
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

pub(super) async fn ensure_implementation_known(
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

pub(super) fn required_string(params: &Value, key: &str) -> Result<String, CapabilityError> {
    string_field(params, key).ok_or_else(|| CapabilityError::InvalidParams {
        message: format!("{key} is required"),
    })
}

pub(super) fn string_array_field(
    params: &Value,
    key: &str,
) -> Result<Vec<String>, CapabilityError> {
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

pub(super) fn validate_binding_scope(scope_kind: &str) -> Result<(), CapabilityError> {
    if matches!(scope_kind, "session" | "workspace" | "profile" | "system") {
        return Ok(());
    }
    Err(CapabilityError::InvalidParams {
        message: "scopeKind must be session, workspace, profile, or system".to_owned(),
    })
}

pub(super) fn validate_conformance_state(state: &str) -> Result<(), CapabilityError> {
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

pub(super) fn validate_plugin_manifest(
    manifest: &CapabilityPluginManifest,
) -> Result<(), CapabilityError> {
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

pub(super) fn validate_nonempty_id(field: &str, value: &str) -> Result<(), CapabilityError> {
    if value.trim().is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: format!("{field} must not be empty"),
        });
    }
    Ok(())
}

pub(super) fn validate_namespace_claim(namespace: &str) -> Result<(), CapabilityError> {
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

pub(super) fn ensure_claim_covers_id(
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
