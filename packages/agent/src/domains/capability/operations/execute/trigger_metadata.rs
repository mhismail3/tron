use serde_json::{Map, Value, json};
use std::collections::BTreeSet;

use super::super::super::registry::{
    CapabilityRegistryEntry, CapabilityRegistrySnapshot, CapabilityTarget, parse_target,
};
use super::super::target_resolution::bounded_snippet;
use super::super::{Deps, registry_snapshot_for_functions};
use crate::engine::{ActorContext, FunctionHealth, FunctionQuery};

pub(super) fn related_triggers_metadata(entry: &CapabilityRegistryEntry) -> Value {
    entry
        .function
        .metadata
        .get("relatedTriggers")
        .cloned()
        .unwrap_or_else(|| json!([]))
}

pub(super) fn related_trigger_ids(entry: &CapabilityRegistryEntry) -> Vec<String> {
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

pub(super) async fn trigger_metadata_target_guidance_for_visible_catalog(
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

pub(super) fn trigger_metadata_target_guidance_for_target_params(
    target_params: &Value,
    arguments: &Value,
    snapshot: &CapabilityRegistrySnapshot,
) -> Option<Value> {
    let target_id = target_id_from_params(target_params)?;
    trigger_metadata_target_guidance_for_ids([target_id.as_str()], arguments, snapshot)
}

pub(super) fn trigger_metadata_target_guidance_for_intent(
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

pub(super) fn trigger_metadata_target_phase_details(
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

pub(super) fn trigger_metadata_target_message(guidance: &Value) -> String {
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
