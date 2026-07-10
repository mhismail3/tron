use crate::shared::foundation::redaction::redact_sensitive_content;
use crate::shared::foundation::text::truncate_str;
use serde_json::Value;

use super::types::{
    ProviderCollection, ProviderCollectionItem, ProviderEvidence, ProviderFact, ProviderNextAction,
    ProviderOperationError, ProviderResourceRef, ProviderTruncation,
};

const MAX_FACTS: usize = 160;
const MAX_RESOURCES: usize = 64;
const MAX_COLLECTIONS: usize = 24;
const MAX_COLLECTION_ITEMS: usize = 12;
const MAX_ITEM_FACTS: usize = 32;
const MAX_NEXT_ACTIONS: usize = 8;
const MAX_FIELD_BYTES: usize = 200;
const MAX_VALUE_BYTES: usize = 800;
const MAX_ACTION_BYTES: usize = 500;

pub(super) fn normalize_evidence(
    projected: Option<Value>,
) -> (ProviderEvidence, ProviderTruncation) {
    let mut evidence = ProviderEvidence::default();
    let mut truncation = ProviderTruncation::default();
    if let Some(projected) = projected {
        collect_value(&projected, "", &mut evidence, &mut truncation);
    }
    (evidence, truncation)
}

pub(super) fn normalize_next_actions(projected: Option<&Value>) -> Vec<ProviderNextAction> {
    let mut actions = Vec::new();
    if let Some(projected) = projected {
        collect_next_actions(projected, "", &mut actions);
    }
    actions
}

pub(super) fn normalize_error(
    projected: Option<&Value>,
    fallback_summary: &str,
) -> ProviderOperationError {
    let code = find_scalar(projected, "code").unwrap_or_else(|| "CAPABILITY_FAILED".to_owned());
    let category = find_scalar(projected, "category").unwrap_or_else(|| "execution".to_owned());
    let message = find_scalar(projected, "message").unwrap_or_else(|| fallback_summary.to_owned());
    let recoverable = find_bool(projected, "recoverable").unwrap_or(false);
    ProviderOperationError {
        code: bounded_text(&code, MAX_VALUE_BYTES),
        category: bounded_text(&category, MAX_FIELD_BYTES),
        message: bounded_text(&message, MAX_VALUE_BYTES),
        recoverable,
    }
}

fn collect_value(
    value: &Value,
    field: &str,
    evidence: &mut ProviderEvidence,
    truncation: &mut ProviderTruncation,
) {
    match value {
        Value::Object(object) => {
            if let Some(resource) = resource_ref(value) {
                push_resource(resource, &mut evidence.resources, truncation);
            }
            for (key, value) in object {
                let child = join_field(field, key);
                collect_value(value, &child, evidence, truncation);
            }
        }
        Value::Array(items) => {
            if evidence.collections.len() >= MAX_COLLECTIONS {
                truncation.truncated = true;
                truncation.omitted_collections += 1;
                truncation.omitted_items += items.len();
                return;
            }
            let mut collection = ProviderCollection {
                field: bounded_text(field, MAX_FIELD_BYTES),
                total: items.len(),
                returned: 0,
                truncated: items.len() > MAX_COLLECTION_ITEMS,
                items: Vec::new(),
            };
            for item in items.iter().take(MAX_COLLECTION_ITEMS) {
                collection.items.push(normalize_collection_item(item));
            }
            collection.returned = collection.items.len();
            if collection.truncated {
                truncation.truncated = true;
                truncation.omitted_items += items.len().saturating_sub(MAX_COLLECTION_ITEMS);
            }
            evidence.collections.push(collection);
        }
        scalar => push_fact(field, scalar, &mut evidence.facts, truncation),
    }
}

fn normalize_collection_item(value: &Value) -> ProviderCollectionItem {
    let mut item = ProviderCollectionItem::default();
    collect_item_value(value, "", &mut item);
    item
}

fn collect_item_value(value: &Value, field: &str, item: &mut ProviderCollectionItem) {
    match value {
        Value::Object(object) => {
            if let Some(resource) = resource_ref(value)
                && item.resources.len() < 8
            {
                item.resources.push(resource);
            }
            for (key, value) in object {
                if item.facts.len() >= MAX_ITEM_FACTS {
                    break;
                }
                collect_item_value(value, &join_field(field, key), item);
            }
        }
        Value::Array(values) => {
            if item.facts.len() < MAX_ITEM_FACTS {
                item.facts.push(ProviderFact {
                    field: bounded_text(field, MAX_FIELD_BYTES),
                    value: Value::String(format!("{} item(s)", values.len())),
                });
            }
        }
        scalar if item.facts.len() < MAX_ITEM_FACTS => item.facts.push(ProviderFact {
            field: bounded_text(field, MAX_FIELD_BYTES),
            value: bounded_scalar(scalar),
        }),
        _ => {}
    }
}

fn push_fact(
    field: &str,
    value: &Value,
    facts: &mut Vec<ProviderFact>,
    truncation: &mut ProviderTruncation,
) {
    if facts.len() >= MAX_FACTS {
        truncation.truncated = true;
        truncation.omitted_facts += 1;
        return;
    }
    facts.push(ProviderFact {
        field: bounded_text(field, MAX_FIELD_BYTES),
        value: bounded_scalar(value),
    });
}

fn push_resource(
    resource: ProviderResourceRef,
    resources: &mut Vec<ProviderResourceRef>,
    truncation: &mut ProviderTruncation,
) {
    if resources.iter().any(|current| {
        current.kind == resource.kind
            && current.resource_id == resource.resource_id
            && current.version_id == resource.version_id
    }) {
        return;
    }
    if resources.len() >= MAX_RESOURCES {
        truncation.truncated = true;
        truncation.omitted_resources += 1;
        return;
    }
    resources.push(resource);
}

fn resource_ref(value: &Value) -> Option<ProviderResourceRef> {
    let object = value.as_object()?;
    let kind = object
        .get("kind")
        .or_else(|| object.get("resourceKind"))?
        .as_str()?;
    let resource_id = object
        .get("resourceId")
        .or_else(|| object.get("id"))?
        .as_str()?;
    Some(ProviderResourceRef {
        kind: bounded_text(kind, MAX_FIELD_BYTES),
        resource_id: bounded_text(resource_id, MAX_VALUE_BYTES),
        version_id: object
            .get("versionId")
            .and_then(Value::as_str)
            .map(|value| bounded_text(value, MAX_VALUE_BYTES)),
        role: object
            .get("role")
            .and_then(Value::as_str)
            .map(|value| bounded_text(value, MAX_FIELD_BYTES)),
    })
}

fn collect_next_actions(value: &Value, field: &str, actions: &mut Vec<ProviderNextAction>) {
    if actions.len() >= MAX_NEXT_ACTIONS {
        return;
    }
    match value {
        Value::Object(object) => {
            for (key, child) in object {
                let child_field = join_field(field, key);
                let normalized = key.to_ascii_lowercase();
                if normalized.contains("nextstep")
                    || normalized.contains("nextaction")
                    || normalized.contains("theninvoke")
                    || normalized.contains("schemainspection")
                    || normalized.contains("failurerecovery")
                {
                    actions.push(action_from_value(&child_field, child));
                    if actions.len() >= MAX_NEXT_ACTIONS {
                        return;
                    }
                }
                collect_next_actions(child, &child_field, actions);
            }
        }
        Value::Array(values) => {
            for child in values.iter().take(MAX_COLLECTION_ITEMS) {
                collect_next_actions(child, field, actions);
                if actions.len() >= MAX_NEXT_ACTIONS {
                    return;
                }
            }
        }
        _ => {}
    }
}

fn action_from_value(source: &str, value: &Value) -> ProviderNextAction {
    let operation = value
        .get("operation")
        .or_else(|| value.get("inspectOperation"))
        .or_else(|| value.pointer("/arguments/operation"))
        .and_then(Value::as_str)
        .map(|value| bounded_text(value, MAX_FIELD_BYTES));
    let inspect_id = value
        .get("id")
        .or_else(|| value.get("catalogInspectId"))
        .or_else(|| value.get("providerSchemaInspectId"))
        .or_else(|| value.pointer("/arguments/id"))
        .and_then(Value::as_str)
        .map(|value| bounded_text(value, MAX_VALUE_BYTES));
    let summary = match value {
        Value::String(value) => bounded_text(value, MAX_ACTION_BYTES),
        _ => serde_json::to_string(value)
            .map(|value| bounded_text(&value, MAX_ACTION_BYTES))
            .unwrap_or_else(|_| "Inspect the referenced evidence before continuing.".to_owned()),
    };
    ProviderNextAction {
        source: bounded_text(source, MAX_FIELD_BYTES),
        summary,
        operation,
        inspect_id,
    }
}

fn find_scalar(value: Option<&Value>, key: &str) -> Option<String> {
    let value = value?;
    match value {
        Value::Object(object) => {
            if let Some(value) = object.get(key).and_then(Value::as_str) {
                return Some(value.to_owned());
            }
            object
                .values()
                .find_map(|value| find_scalar(Some(value), key))
        }
        Value::Array(values) => values
            .iter()
            .find_map(|value| find_scalar(Some(value), key)),
        _ => None,
    }
}

fn find_bool(value: Option<&Value>, key: &str) -> Option<bool> {
    let value = value?;
    match value {
        Value::Object(object) => {
            if let Some(value) = object.get(key).and_then(Value::as_bool) {
                return Some(value);
            }
            object
                .values()
                .find_map(|value| find_bool(Some(value), key))
        }
        Value::Array(values) => values.iter().find_map(|value| find_bool(Some(value), key)),
        _ => None,
    }
}

fn bounded_scalar(value: &Value) -> Value {
    match value {
        Value::String(value) => Value::String(bounded_text(value, MAX_VALUE_BYTES)),
        Value::Null | Value::Bool(_) | Value::Number(_) => value.clone(),
        _ => Value::String("[structured value projected separately]".to_owned()),
    }
}

fn join_field(parent: &str, child: &str) -> String {
    if parent.is_empty() {
        child.to_owned()
    } else {
        format!("{parent}.{child}")
    }
}

pub(super) fn bounded_text(value: &str, max_bytes: usize) -> String {
    let redacted = redact_sensitive_content(value);
    truncate_str(&redacted, max_bytes).to_owned()
}
