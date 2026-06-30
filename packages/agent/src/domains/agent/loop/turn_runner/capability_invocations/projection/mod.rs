//! Provider-visible model-context evidence projection.
//!
//! The turn runner stores full capability details for UI, audit, and replay,
//! but providers only receive this bounded projection appended to result text.
//! Keep the allowlists narrow: ids, lifecycle/status, refs, truncation metadata,
//! and schema failure coordinates are useful to the model; raw content, local
//! paths, commands, secrets, grant ids, and authority ids stay out of this
//! channel.

use std::sync::LazyLock;

use crate::domains::agent::r#loop::types::CapabilityInvocationExecutionResult;
use crate::shared::foundation::redaction::redact_sensitive_content;
use crate::shared::protocol::content::CapabilityResultContent;
use crate::shared::protocol::messages::CapabilityResultMessageContent;
use regex::Regex;
use serde_json::{Map, Value, json};

mod metadata_operations;

use self::metadata_operations::projects_metadata_operation;

pub(super) fn extract_model_context_result_text(
    exec_result: &CapabilityInvocationExecutionResult,
) -> String {
    match extract_result_content(exec_result) {
        CapabilityResultMessageContent::Text(text) => text,
        CapabilityResultMessageContent::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| match block {
                CapabilityResultContent::Text { text } => Some(text.as_str()),
                CapabilityResultContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

const MODEL_CONTEXT_EVIDENCE_MAX_CHARS: usize = 12_000;
const MODEL_CONTEXT_STRING_MAX_CHARS: usize = 800;
const MODEL_CONTEXT_ARRAY_MAX_ITEMS: usize = 20;
const MODEL_CONTEXT_OBJECT_MAX_KEYS: usize = 80;

pub(super) fn extract_result_content(
    exec_result: &CapabilityInvocationExecutionResult,
) -> CapabilityResultMessageContent {
    let projected = model_context_evidence(exec_result.result.details.as_ref());
    match &exec_result.result.content {
        crate::shared::protocol::model_capabilities::CapabilityResultBody::Text(text) => {
            CapabilityResultMessageContent::Text(append_model_context_evidence(
                text.clone(),
                projected,
            ))
        }
        crate::shared::protocol::model_capabilities::CapabilityResultBody::Blocks(blocks) => {
            let has_images = blocks
                .iter()
                .any(|b| matches!(b, CapabilityResultContent::Image { .. }));
            if has_images {
                let mut blocks = blocks.clone();
                if let Some(projected) = projected {
                    blocks.push(CapabilityResultContent::text(projected));
                }
                CapabilityResultMessageContent::Blocks(blocks)
            } else {
                let text = blocks
                    .iter()
                    .filter_map(|b| match b {
                        CapabilityResultContent::Text { text } => Some(text.as_str()),
                        CapabilityResultContent::Image { .. } => None,
                    })
                    .collect::<Vec<_>>()
                    .join("\n");
                CapabilityResultMessageContent::Text(append_model_context_evidence(text, projected))
            }
        }
    }
}

fn append_model_context_evidence(text: String, projected: Option<String>) -> String {
    let Some(projected) = projected else {
        return text;
    };
    if text.is_empty() {
        projected
    } else {
        format!("{text}\n\n{projected}")
    }
}

fn model_context_evidence(details: Option<&Value>) -> Option<String> {
    let details = details?;
    if let Some(projected) = project_error_evidence(details) {
        return render_model_context_evidence(projected);
    }
    let operation = details
        .get("primitiveOperation")
        .and_then(Value::as_str)
        .or_else(|| details.get("operation").and_then(Value::as_str))?;
    let projected = match operation {
        "catalog_search" | "catalog_inspect" => project_catalog_evidence(details),
        "log_recent" => project_log_evidence(details),
        "trace_list" | "trace_get" => project_trace_evidence(details),
        operation if projects_metadata_operation(operation) => {
            project_metadata_operation_evidence(operation, details)
        }
        _ => None,
    }?;
    render_model_context_evidence(projected)
}

fn render_model_context_evidence(projected: Value) -> Option<String> {
    let mut text = serde_json::to_string_pretty(&json!({
        "modelContextEvidence": projected
    }))
    .ok()?;
    if text.len() > MODEL_CONTEXT_EVIDENCE_MAX_CHARS {
        text.truncate(MODEL_CONTEXT_EVIDENCE_MAX_CHARS);
        text.push_str("\n... [model context evidence truncated]");
    }
    Some(text)
}

fn project_catalog_evidence(details: &Value) -> Option<Value> {
    let discovery = details.get("catalogDiscovery")?;
    let mut projected = Map::new();
    copy_key(&mut projected, details, "primitiveOperation");
    copy_key(&mut projected, details, "status");
    copy_key(&mut projected, discovery, "kind");
    copy_key(&mut projected, discovery, "id");
    copy_key(&mut projected, discovery, "aliasResolvedFrom");
    copy_key(&mut projected, discovery, "summary");
    if let Some(guidance) = discovery.get("modelFacingGuidance") {
        projected.insert(
            "modelFacingGuidance".to_owned(),
            project_model_facing_guidance(guidance),
        );
    }
    copy_key(&mut projected, discovery, "modelFacingInvocation");
    if let Some(functions) = discovery.get("functions").and_then(Value::as_array) {
        projected.insert(
            "functions".to_owned(),
            Value::Array(
                functions
                    .iter()
                    .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                    .map(project_catalog_function)
                    .collect(),
            ),
        );
        if functions.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS {
            projected.insert(
                "functionsOmitted".to_owned(),
                json!(functions.len() - MODEL_CONTEXT_ARRAY_MAX_ITEMS),
            );
        }
    }
    Some(Value::Object(projected))
}

fn project_model_facing_guidance(guidance: &Value) -> Value {
    let mut projected = Map::new();
    for key in ["catalogInspect", "capabilityExecute"] {
        copy_key(&mut projected, guidance, key);
    }
    if let Some(operations) = guidance
        .get("supportedExecuteOperations")
        .and_then(Value::as_array)
    {
        let returned = operations
            .iter()
            .filter_map(Value::as_str)
            .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
            .map(|operation| Value::String(operation.to_owned()))
            .collect::<Vec<_>>();
        projected.insert(
            "supportedExecuteOperations".to_owned(),
            json!({
                "total": operations.len(),
                "returned": returned,
                "truncated": operations.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS,
                "omitted": operations.len().saturating_sub(MODEL_CONTEXT_ARRAY_MAX_ITEMS),
                "maxItems": MODEL_CONTEXT_ARRAY_MAX_ITEMS
            }),
        );
    }
    Value::Object(projected)
}

fn project_catalog_function(function: &Value) -> Value {
    let mut projected = Map::new();
    for key in [
        "id",
        "name",
        "description",
        "ownerWorkerId",
        "visibility",
        "effectClass",
        "riskLevel",
        "modelFacingInvocation",
    ] {
        copy_key(&mut projected, function, key);
    }
    Value::Object(projected)
}

fn project_log_evidence(details: &Value) -> Option<Value> {
    let mut projected = Map::new();
    copy_key(&mut projected, details, "primitiveOperation");
    copy_key(&mut projected, details, "status");
    let entries = details.get("entries")?.as_array()?;
    projected.insert(
        "entries".to_owned(),
        Value::Array(
            entries
                .iter()
                .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                .map(|entry| {
                    let mut projected = Map::new();
                    for key in [
                        "id",
                        "timestamp",
                        "level",
                        "component",
                        "message",
                        "sessionId",
                        "traceId",
                        "errorMessage",
                    ] {
                        copy_key(&mut projected, entry, key);
                    }
                    Value::Object(projected)
                })
                .collect(),
        ),
    );
    if entries.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS {
        projected.insert(
            "entriesOmitted".to_owned(),
            json!(entries.len() - MODEL_CONTEXT_ARRAY_MAX_ITEMS),
        );
    }
    Some(Value::Object(projected))
}

fn project_trace_evidence(details: &Value) -> Option<Value> {
    let mut projected = Map::new();
    copy_key(&mut projected, details, "primitiveOperation");
    copy_key(&mut projected, details, "status");
    if let Some(records) = details.get("records").and_then(Value::as_array) {
        projected.insert(
            "records".to_owned(),
            Value::Array(
                records
                    .iter()
                    .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                    .map(project_trace_record)
                    .collect(),
            ),
        );
        if records.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS {
            projected.insert(
                "recordsOmitted".to_owned(),
                json!(records.len() - MODEL_CONTEXT_ARRAY_MAX_ITEMS),
            );
        }
    }
    if let Some(record) = details.get("record") {
        projected.insert("record".to_owned(), project_trace_record(record));
    }
    Some(Value::Object(projected))
}

fn project_trace_record(record: &Value) -> Value {
    let mut projected = Map::new();
    let metadata = record
        .get("metadata")
        .and_then(|metadata| metadata.get("dev.tron"))
        .unwrap_or(&Value::Null);
    for key in [
        "id",
        "traceRecordId",
        "traceId",
        "invocationId",
        "providerInvocationId",
        "parentInvocationId",
        "modelPrimitiveName",
        "operation",
        "status",
        "timestamp",
        "completedAt",
        "durationMs",
        "sessionId",
        "turn",
    ] {
        copy_key(&mut projected, record, key);
        copy_key(&mut projected, metadata, key);
    }
    if let Some(error) = record.get("error").or_else(|| metadata.get("error")) {
        if let Some(error) = project_failure_value(error) {
            projected.insert("error".to_owned(), error);
        }
    }
    Value::Object(projected)
}

fn project_error_evidence(details: &Value) -> Option<Value> {
    let failure = details.get("failure")?;
    let mut projected = Map::new();
    copy_key(&mut projected, details, "modelPrimitiveName");
    copy_key(&mut projected, details, "providerInvocationId");
    copy_key(&mut projected, details, "primitiveTargetId");
    if let Some(failure) = project_failure_value(failure) {
        projected.extend(failure.as_object()?.clone());
    }
    Some(Value::Object(projected))
}

fn project_failure_value(failure: &Value) -> Option<Value> {
    let mut projected = Map::new();
    for key in [
        "code",
        "category",
        "origin",
        "retryable",
        "recoverable",
        "message",
        "suggestion",
    ] {
        copy_key(&mut projected, failure, key);
    }
    if let Some(details) = failure.get("details") {
        let mut failure_details = Map::new();
        copy_error_detail_keys(&mut failure_details, details);
        if !failure_details.is_empty() {
            projected.insert(
                "details".to_owned(),
                Value::Object(failure_details.into_iter().take(24).collect()),
            );
        }
    }
    Some(Value::Object(projected))
}

fn copy_error_detail_keys(projected: &mut Map<String, Value>, value: &Value) {
    let Some(object) = value.as_object() else {
        return;
    };
    for (key, field) in object {
        if key == "actual" {
            continue;
        }
        if matches!(
            key.as_str(),
            "code"
                | "path"
                | "field"
                | "functionId"
                | "direction"
                | "operation"
                | "required"
                | "requiredFields"
                | "missingFields"
                | "expected"
        ) {
            projected.insert(key.clone(), bounded_model_context_value(field));
        } else if field.is_object() {
            copy_error_detail_keys(projected, field);
        }
    }
}

fn project_metadata_operation_evidence(operation: &str, details: &Value) -> Option<Value> {
    let mut projected = Map::new();
    copy_key(&mut projected, details, "primitiveOperation");
    copy_key(&mut projected, details, "status");
    projected.insert("operation".to_owned(), json!(operation));
    for (key, value) in details.as_object()? {
        if key == "primitiveOperation" || key == "status" {
            continue;
        }
        if let Some(projected_value) = project_safe_metadata_value(key, value, 0) {
            projected.insert(key.clone(), projected_value);
        }
        if projected.len() >= MODEL_CONTEXT_OBJECT_MAX_KEYS {
            break;
        }
    }
    (projected.len() > 2).then_some(Value::Object(projected))
}

fn project_safe_metadata_value(key: &str, value: &Value, depth: usize) -> Option<Value> {
    if depth > 5 || denied_model_context_key(key) {
        return None;
    }
    if safe_scalar_metadata_key(key) {
        return bounded_safe_scalar_metadata_value(value);
    }
    match value {
        Value::Object(object) => {
            let mut projected = Map::new();
            for (child_key, child_value) in object {
                if let Some(value) = project_safe_metadata_value(child_key, child_value, depth + 1)
                {
                    projected.insert(child_key.clone(), value);
                }
                if projected.len() >= MODEL_CONTEXT_OBJECT_MAX_KEYS {
                    break;
                }
            }
            (!projected.is_empty()).then_some(Value::Object(projected))
        }
        Value::Array(items) if safe_array_metadata_key(key) => {
            let projected = items
                .iter()
                .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                .filter_map(|item| project_array_item_metadata(item, depth + 1))
                .collect::<Vec<_>>();
            let mut wrapper = Map::new();
            wrapper.insert("total".to_owned(), json!(items.len()));
            wrapper.insert("returned".to_owned(), json!(projected.len()));
            wrapper.insert(
                "truncated".to_owned(),
                json!(items.len() > MODEL_CONTEXT_ARRAY_MAX_ITEMS),
            );
            wrapper.insert(
                "omitted".to_owned(),
                json!(items.len().saturating_sub(MODEL_CONTEXT_ARRAY_MAX_ITEMS)),
            );
            wrapper.insert("items".to_owned(), Value::Array(projected));
            Some(Value::Object(wrapper))
        }
        _ => None,
    }
}

fn bounded_safe_scalar_metadata_value(value: &Value) -> Option<Value> {
    match value {
        Value::String(_) | Value::Bool(_) | Value::Number(_) | Value::Null => {
            Some(bounded_model_context_value(value))
        }
        Value::Array(items) => {
            let projected = items
                .iter()
                .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                .filter_map(|item| match item {
                    Value::String(_) | Value::Bool(_) | Value::Number(_) | Value::Null => {
                        Some(bounded_model_context_value(item))
                    }
                    Value::Object(_) | Value::Array(_) => None,
                })
                .collect::<Vec<_>>();
            (!projected.is_empty()).then_some(Value::Array(projected))
        }
        Value::Object(_) => None,
    }
}

fn project_array_item_metadata(item: &Value, depth: usize) -> Option<Value> {
    match item {
        Value::Object(object) => {
            let mut projected = Map::new();
            for (key, value) in object {
                if let Some(value) = project_safe_metadata_value(key, value, depth + 1) {
                    projected.insert(key.clone(), value);
                }
            }
            (!projected.is_empty()).then_some(Value::Object(projected))
        }
        Value::String(value) => Some(Value::String(truncate_model_context_string(value))),
        Value::Bool(_) | Value::Number(_) | Value::Null => Some(bounded_model_context_value(item)),
        Value::Array(_) => None,
    }
}

fn safe_array_metadata_key(key: &str) -> bool {
    matches!(
        key,
        "records"
            | "entries"
            | "items"
            | "results"
            | "resourceRefs"
            | "resources"
            | "versions"
            | "modules"
            | "media"
            | "memories"
            | "queries"
            | "decisions"
            | "requests"
            | "reviews"
            | "sources"
            | "goals"
            | "questions"
            | "artifacts"
            | "programs"
            | "snapshots"
            | "reports"
            | "refs"
            | "traceRefs"
            | "replayRefs"
    )
}

fn safe_scalar_metadata_key(key: &str) -> bool {
    let lower = key.to_ascii_lowercase();
    matches!(
        key,
        "schemaVersion"
            | "primitiveOperation"
            | "operation"
            | "status"
            | "state"
            | "lifecycle"
            | "kind"
            | "type"
            | "role"
            | "title"
            | "summary"
            | "description"
            | "reason"
            | "decision"
            | "scope"
            | "namespace"
            | "key"
            | "mode"
            | "enabled"
            | "active"
            | "configured"
            | "createdAt"
            | "updatedAt"
            | "recordedAt"
            | "completedAt"
            | "startedAt"
            | "timestamp"
            | "count"
            | "total"
            | "returned"
            | "limit"
            | "truncated"
            | "omitted"
            | "hasMore"
            | "networkPolicy"
            | "remotePolicy"
            | "selector"
            | "selectors"
            | "resourceSelectors"
            | "requiredAuthorityScopes"
            | "requiredScopes"
            | "requiredSelectors"
            | "current"
            | "currentVersionId"
            | "versionId"
            | "expectedCurrentVersionId"
    ) || safe_id_like_metadata_key(&lower)
}

fn safe_id_like_metadata_key(lower: &str) -> bool {
    (lower.ends_with("id")
        || lower.ends_with("ids")
        || lower.ends_with("versionid")
        || lower.ends_with("resourceid"))
        && !lower.contains("grant")
        && !lower.contains("authority")
        && !lower.contains("secret")
        && !lower.contains("token")
}

fn denied_model_context_key(key: &str) -> bool {
    let lower = key.to_ascii_lowercase();
    lower == "authority"
        || lower.contains("grant")
        || lower.contains("authoritygrant")
        || lower.contains("secret")
        || lower.contains("token")
        || lower.contains("credential")
        || lower.contains("password")
        || lower.contains("raw")
        || lower.contains("command")
        || lower == "cmd"
        || lower.contains("stdout")
        || lower.contains("stderr")
        || lower == "log"
        || lower == "logs"
        || lower.contains("package")
        || lower.contains("environment")
        || lower == "env"
        || lower.contains("promptbody")
        || lower == "prompt"
        || lower == "content"
        || lower.contains("content")
        || lower == "body"
        || lower == "payload"
        || lower == "filecontents"
        || lower == "diff"
        || lower == "preview"
        || lower == "path"
        || lower.ends_with("path")
        || lower == "uri"
}

fn copy_key(target: &mut Map<String, Value>, source: &Value, key: &str) {
    if let Some(value) = source.get(key) {
        target.insert(key.to_owned(), bounded_model_context_value(value));
    }
}

fn bounded_model_context_value(value: &Value) -> Value {
    match value {
        Value::String(text) => Value::String(truncate_model_context_string(text)),
        Value::Array(values) => Value::Array(
            values
                .iter()
                .take(MODEL_CONTEXT_ARRAY_MAX_ITEMS)
                .map(bounded_model_context_value)
                .collect(),
        ),
        Value::Object(object) => Value::Object(
            object
                .iter()
                .map(|(key, value)| (key.clone(), bounded_model_context_value(value)))
                .collect(),
        ),
        other => other.clone(),
    }
}

fn truncate_model_context_string(text: &str) -> String {
    let redacted = redact_model_context_string(text);
    if redacted.chars().count() <= MODEL_CONTEXT_STRING_MAX_CHARS {
        return redacted;
    }
    let mut truncated = redacted
        .chars()
        .take(MODEL_CONTEXT_STRING_MAX_CHARS)
        .collect::<String>();
    truncated.push_str("... [truncated]");
    truncated
}

fn redact_model_context_string(text: &str) -> String {
    static ABSOLUTE_PATHS: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(^|[\s"'=:,\[])(/(?:Users|home|private|tmp|var|Volumes)/[^\s"',}\]]+)"#)
            .expect("valid absolute path redaction regex")
    });
    static UNSAFE_RELATIVE_PATHS: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r#"(^|[\s"'=:,\[])(\.\.(?:/|\\)[^\s"',}\]]*)"#)
            .expect("valid relative path redaction regex")
    });

    let redacted = redact_sensitive_content(text);
    let redacted = ABSOLUTE_PATHS
        .replace_all(&redacted, "${1}[redacted-path]")
        .to_string();
    UNSAFE_RELATIVE_PATHS
        .replace_all(&redacted, "${1}[redacted-path]")
        .to_string()
}

#[cfg(test)]
mod tests;
