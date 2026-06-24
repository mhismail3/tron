use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};

use crate::engine::{
    CATALOG_DISCOVERY_REPORT_KIND, EffectClass, EngineHostHandle, EngineResource,
    FunctionDefinition, ListResources, RiskLevel, TriggerDefinition, TriggerTypeDefinition,
    UI_SURFACE_KIND, WorkerDefinition,
};
use crate::shared::server::errors::CapabilityError;

use super::errors::engine_error;
use super::params::{
    effect_key, health_key, optional_str, privileged_actor_context, query_from_payload, risk_key,
    visibility_key,
};

pub(super) async fn protected_omission_counts(
    engine_host: &EngineHostHandle,
    payload: &Value,
    visible_functions: &[FunctionDefinition],
    visible_workers: &[WorkerDefinition],
) -> Result<Value, CapabilityError> {
    let privileged_actor = privileged_actor_context();
    let privileged_query = query_from_payload(payload, privileged_actor.clone())?;
    let all_functions = engine_host.discover(&privileged_query).await;
    let all_workers = filtered_workers(
        engine_host.visible_workers(&privileged_actor).await,
        &all_functions,
        payload,
    )?;
    let visible_function_ids = visible_functions
        .iter()
        .map(|function| function.id.as_str())
        .collect::<BTreeSet<_>>();
    let visible_worker_ids = visible_workers
        .iter()
        .map(|worker| worker.id.as_str())
        .collect::<BTreeSet<_>>();

    Ok(json!({
        "included": true,
        "functions": omitted_counts(
            all_functions.iter().map(|function| {
                (function.id.as_str(), visibility_key(&function.visibility))
            }),
            &visible_function_ids
        ),
        "workers": omitted_counts(
            all_workers.iter().map(|worker| {
                (worker.id.as_str(), visibility_key(&worker.visibility))
            }),
            &visible_worker_ids
        ),
        "note": "protected item ids are intentionally omitted from this payload"
    }))
}

pub(super) fn catalog_summary(
    functions: &[FunctionDefinition],
    workers: &[WorkerDefinition],
    triggers: &[TriggerDefinition],
    trigger_types: &[TriggerTypeDefinition],
    protected: Value,
) -> Value {
    let mut by_effect = BTreeMap::new();
    let mut by_risk = BTreeMap::new();
    let mut by_health = BTreeMap::new();
    let mut by_namespace = BTreeMap::new();
    let mut missing_request_schema = 0_u64;
    let mut missing_response_schema = 0_u64;
    let mut non_routable = 0_u64;
    for function in functions {
        increment(&mut by_effect, effect_key(function.effect_class));
        increment(&mut by_risk, risk_key(function.risk_level));
        increment(&mut by_health, health_key(&function.health));
        increment(&mut by_namespace, function.id.namespace());
        if function.request_schema.is_none() {
            missing_request_schema += 1;
        }
        if function.response_schema.is_none() && !function.opaque_response {
            missing_response_schema += 1;
        }
        if !function.health.is_routable() {
            non_routable += 1;
        }
    }
    json!({
        "functions": {
            "visible": functions.len(),
            "byNamespace": by_namespace,
            "byEffect": by_effect,
            "byRisk": by_risk,
            "byHealth": by_health,
            "missingRequestSchema": missing_request_schema,
            "missingResponseSchema": missing_response_schema,
            "nonRoutable": non_routable
        },
        "workers": {"visible": workers.len()},
        "triggers": {"visible": triggers.len()},
        "triggerTypes": {"visible": trigger_types.len()},
        "protected": protected
    })
}

pub(super) fn function_report_entry(function: &FunctionDefinition) -> Value {
    let mut summary = function_summary(function);
    if let Some(object) = summary.as_object_mut() {
        object.insert("conformance".to_owned(), function_conformance(function));
    }
    summary
}

pub(super) fn function_summary(function: &FunctionDefinition) -> Value {
    json!({
        "id": function.id.as_str(),
        "ownerWorker": function.owner_worker.as_str(),
        "description": function.description,
        "visibility": visibility_key(&function.visibility),
        "effectClass": effect_key(function.effect_class),
        "riskLevel": risk_key(function.risk_level),
        "health": health_key(&function.health),
        "tags": function.tags,
        "schema": function_schema_hints(function),
        "metadata": {
            "domainWorker": function.metadata.get("domainWorker").cloned().unwrap_or(Value::Null),
            "operationKey": function.metadata.get("operationKey").cloned().unwrap_or(Value::Null),
            "streamTopics": function.metadata.get("streamTopics").cloned().unwrap_or(Value::Null),
            "presentationHints": function.metadata.get("presentationHints").cloned().unwrap_or(Value::Null)
        }
    })
}

pub(super) fn function_schema_hints(function: &FunctionDefinition) -> Value {
    json!({
        "requestSchemaPresent": function.request_schema.is_some(),
        "responseSchemaPresent": function.response_schema.is_some(),
        "opaqueResponse": function.opaque_response,
        "requestRequired": function.request_schema.as_ref()
            .and_then(|schema| schema.get("required"))
            .cloned()
            .unwrap_or_else(|| json!([])),
        "responseRequired": function.response_schema.as_ref()
            .and_then(|schema| schema.get("required"))
            .cloned()
            .unwrap_or_else(|| json!([]))
    })
}

pub(super) fn function_conformance(function: &FunctionDefinition) -> Value {
    json!({
        "routable": function.health.is_routable(),
        "effectContracts": {
            "mutating": function.effect_class.is_mutating(),
            "idempotency": function.idempotency.is_some(),
            "resourceLease": function.resource_lease.is_some(),
            "compensation": function.compensation.is_some(),
            "outputContract": function.output_contract
        },
        "authority": function.required_authority,
        "failures": function_conformance_failures(function)
    })
}

pub(super) fn function_conformance_failures(function: &FunctionDefinition) -> Vec<&'static str> {
    let mut failures = Vec::new();
    if function.request_schema.is_none() {
        failures.push("missing_request_schema");
    }
    if function.response_schema.is_none() && !function.opaque_response {
        failures.push("missing_response_schema");
    }
    if !function.health.is_routable() {
        failures.push("not_routable");
    }
    if !function_effect_contracts_ok(function) {
        failures.push("missing_effect_contract");
    }
    failures
}

pub(super) fn function_effect_contracts_ok(function: &FunctionDefinition) -> bool {
    if !function.effect_class.is_mutating() {
        return true;
    }
    if function.idempotency.is_none() {
        return false;
    }
    if function.risk_level >= RiskLevel::High && function.compensation.is_none() {
        return false;
    }
    if function.effect_class == EffectClass::IrreversibleSideEffect
        && function.compensation.is_none()
    {
        return false;
    }
    true
}

pub(super) fn worker_summary(worker: &WorkerDefinition) -> Value {
    json!({
        "id": worker.id.as_str(),
        "kind": format!("{:?}", worker.kind),
        "lifecycle": format!("{:?}", worker.lifecycle),
        "visibility": visibility_key(&worker.visibility),
        "namespaceClaims": worker.namespace_claims,
        "ownerActor": worker.owner_actor.as_str(),
        "authorityGrant": worker.authority_grant.as_str(),
    })
}

pub(super) fn trigger_summary(trigger: &TriggerDefinition) -> Value {
    json!({
        "id": trigger.id.as_str(),
        "ownerWorker": trigger.owner_worker.as_str(),
        "triggerType": trigger.trigger_type.as_str(),
        "targetFunction": trigger.target_function.as_str(),
        "deliveryMode": format!("{:?}", trigger.delivery_mode),
        "visibility": visibility_key(&trigger.visibility),
    })
}

pub(super) fn trigger_type_summary(trigger_type: &TriggerTypeDefinition) -> Value {
    json!({
        "id": trigger_type.id.as_str(),
        "ownerWorker": trigger_type.owner_worker.as_str(),
        "description": trigger_type.description,
        "visibility": visibility_key(&trigger_type.visibility),
        "configSchemaPresent": trigger_type.config_schema.is_some(),
        "allowedDeliveryModes": trigger_type.allowed_delivery_modes
            .iter()
            .map(|mode| format!("{mode:?}"))
            .collect::<Vec<_>>()
    })
}

pub(super) async fn resource_evidence(
    engine_host: &EngineHostHandle,
) -> Result<Value, CapabilityError> {
    let reports = engine_host
        .list_resources(ListResources {
            kind: Some(CATALOG_DISCOVERY_REPORT_KIND.to_owned()),
            scope: None,
            lifecycle: None,
            limit: 25,
        })
        .await
        .map_err(engine_error)?;
    let surfaces = engine_host
        .list_resources(ListResources {
            kind: Some(UI_SURFACE_KIND.to_owned()),
            scope: None,
            lifecycle: Some("active".to_owned()),
            limit: 25,
        })
        .await
        .map_err(engine_error)?;
    Ok(json!({
        "catalogDiscoveryReports": {
            "recentCount": reports.len(),
            "latest": reports.iter().max_by_key(|resource| resource.updated_at).map(resource_summary)
        },
        "runtimeSurfaces": {
            "activeCount": surfaces.len(),
            "latest": surfaces.iter().max_by_key(|resource| resource.updated_at).map(resource_summary)
        }
    }))
}

pub(super) fn resource_ref(resource: &EngineResource, role: &str) -> Value {
    json!({
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "versionId": resource.current_version_id,
        "role": role
    })
}

pub(super) fn next_actions(
    functions: &[FunctionDefinition],
    resource_evidence: &Value,
) -> Vec<Value> {
    let mut actions = Vec::new();
    if functions
        .iter()
        .any(|function| !function.health.is_routable())
    {
        actions.push(json!({
            "kind": "inspect_degraded",
            "label": "Inspect non-routable functions",
            "operation": "catalog_inspect"
        }));
    }
    if resource_evidence
        .pointer("/catalogDiscoveryReports/recentCount")
        .and_then(Value::as_u64)
        .unwrap_or(0)
        == 0
    {
        actions.push(json!({
            "kind": "create_report",
            "label": "Create conformance report",
            "operation": "catalog_conformance"
        }));
    }
    actions
}

pub(super) fn filtered_workers(
    workers: Vec<WorkerDefinition>,
    functions: &[FunctionDefinition],
    payload: &Value,
) -> Result<Vec<WorkerDefinition>, CapabilityError> {
    let namespace_prefix = optional_str(payload, "namespacePrefix")?.map(str::to_owned);
    let tokens = optional_str(payload, "text")?
        .map(search_tokens)
        .unwrap_or_default();
    if namespace_prefix.is_none() && tokens.is_empty() {
        return Ok(workers);
    }
    let owner_matches = functions
        .iter()
        .map(|function| function.owner_worker.as_str().to_owned())
        .collect::<BTreeSet<_>>();
    Ok(workers
        .into_iter()
        .filter(|worker| {
            owner_matches.contains(worker.id.as_str())
                || namespace_prefix.as_ref().is_some_and(|prefix| {
                    worker.id.as_str().starts_with(prefix)
                        || worker
                            .namespace_claims
                            .iter()
                            .any(|claim| claim.starts_with(prefix))
                })
                || tokens_match(&tokens, &worker_search_haystack(worker))
        })
        .collect())
}

pub(super) fn filtered_triggers(
    triggers: Vec<TriggerDefinition>,
    payload: &Value,
) -> Result<Vec<TriggerDefinition>, CapabilityError> {
    let namespace_prefix = optional_str(payload, "namespacePrefix")?.map(str::to_owned);
    let tokens = optional_str(payload, "text")?
        .map(search_tokens)
        .unwrap_or_default();
    Ok(triggers
        .into_iter()
        .filter(|trigger| {
            namespace_prefix.as_ref().is_none_or(|prefix| {
                trigger.id.as_str().starts_with(prefix)
                    || trigger.target_function.as_str().starts_with(prefix)
            }) && tokens_match(&tokens, &trigger_search_haystack(trigger))
        })
        .collect())
}

pub(super) fn filtered_trigger_types(
    trigger_types: Vec<TriggerTypeDefinition>,
    payload: &Value,
) -> Result<Vec<TriggerTypeDefinition>, CapabilityError> {
    let namespace_prefix = optional_str(payload, "namespacePrefix")?.map(str::to_owned);
    let tokens = optional_str(payload, "text")?
        .map(search_tokens)
        .unwrap_or_default();
    Ok(trigger_types
        .into_iter()
        .filter(|trigger_type| {
            namespace_prefix
                .as_ref()
                .is_none_or(|prefix| trigger_type.id.as_str().starts_with(prefix))
                && tokens_match(&tokens, &trigger_type_search_haystack(trigger_type))
        })
        .collect())
}

pub(super) fn protected_function_failure_counts(
    all_functions: &[FunctionDefinition],
    visible_functions: &[FunctionDefinition],
) -> BTreeMap<String, u64> {
    let visible_ids = visible_functions
        .iter()
        .map(|function| function.id.as_str())
        .collect::<BTreeSet<_>>();
    let mut counts = BTreeMap::new();
    for function in all_functions {
        if visible_ids.contains(function.id.as_str()) {
            continue;
        }
        for failure in function_conformance_failures(function) {
            increment(&mut counts, failure);
        }
    }
    counts
}

fn resource_summary(resource: &EngineResource) -> Value {
    json!({
        "resourceId": resource.resource_id,
        "kind": resource.kind,
        "lifecycle": resource.lifecycle,
        "currentVersionId": resource.current_version_id,
        "updatedAt": resource.updated_at.to_rfc3339()
    })
}

fn omitted_counts<'a>(
    all: impl Iterator<Item = (&'a str, &'a str)>,
    visible_ids: &BTreeSet<&str>,
) -> Value {
    let mut omitted = 0_u64;
    let mut by_visibility = BTreeMap::<String, u64>::new();
    for (id, visibility) in all {
        if visible_ids.contains(id) {
            continue;
        }
        omitted += 1;
        increment(&mut by_visibility, visibility);
    }
    json!({
        "omitted": omitted,
        "byVisibility": by_visibility
    })
}

fn increment(map: &mut BTreeMap<String, u64>, key: impl AsRef<str>) {
    *map.entry(key.as_ref().to_owned()).or_insert(0) += 1;
}

fn search_tokens(text: &str) -> Vec<String> {
    normalize_search_text(text)
        .split_whitespace()
        .map(ToOwned::to_owned)
        .collect()
}

fn tokens_match(tokens: &[String], haystack: &str) -> bool {
    tokens.is_empty() || tokens.iter().all(|token| haystack.contains(token))
}

fn worker_search_haystack(worker: &WorkerDefinition) -> String {
    normalize_search_text(&format!(
        "{} {:?} {:?} {}",
        worker.id.as_str(),
        worker.kind,
        worker.lifecycle,
        worker.namespace_claims.join(" ")
    ))
}

fn trigger_search_haystack(trigger: &TriggerDefinition) -> String {
    normalize_search_text(&format!(
        "{} {} {} {:?}",
        trigger.id.as_str(),
        trigger.trigger_type.as_str(),
        trigger.target_function.as_str(),
        trigger.delivery_mode
    ))
}

fn trigger_type_search_haystack(trigger_type: &TriggerTypeDefinition) -> String {
    normalize_search_text(&format!(
        "{} {} {:?}",
        trigger_type.id.as_str(),
        trigger_type.description,
        trigger_type.allowed_delivery_modes
    ))
}

fn normalize_search_text(text: &str) -> String {
    text.chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() {
                ch.to_ascii_lowercase()
            } else {
                ' '
            }
        })
        .collect()
}
