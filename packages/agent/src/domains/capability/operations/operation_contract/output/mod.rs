//! Canonical provider-visible result contract for `capability::execute`.
//!
//! Raw [`CapabilityResult`] values remain internal audit/UI state. This module
//! owns the exact model-facing envelope, operation profile, redacted evidence
//! projection, common failure branch, and structural byte budget. Provider
//! adapters transport the resulting bytes; they must not rebuild or truncate
//! the contract. Common semantic facts (`primitiveOperation` and `status`) are
//! synthesized from this envelope's authoritative invocation/result state, not
//! duplicated by every domain handler, and byte-budget reduction never removes
//! facts or collections required by the operation's semantic evidence contract.
//! Required collections retain a bounded newest-first item subset with exact
//! omission proof, and collection normalization reserves its bounded fact
//! budget for navigation identifiers before optional audit detail. Unsupported
//! names return a structured `catalog_search`
//! recovery action rather than prose-only guidance.
//! Focused `trace_get` output preserves the provider-safe record schema/version
//! facts required by its semantic contract; raw provider and authority ids stay
//! outside the projection.
//! `budget`, `normalize`, `projection`, `spec`, and `types` own the production layers;
//! sibling `tests` owns envelope-wide contract and budget regression coverage.

use crate::engine::{FunctionId, validate_engine_schema_payload};
use crate::shared::protocol::content::CapabilityResultContent;
use crate::shared::protocol::messages::CapabilityResultMessageContent;
use crate::shared::protocol::model_capabilities::{CapabilityResult, CapabilityResultBody};
use serde_json::{Value, json};

use super::OperationId;

mod budget;
mod normalize;
mod projection;
mod spec;
mod types;

use budget::fit_output_budget;
use normalize::{bounded_text, normalize_error, normalize_evidence, normalize_next_actions};
pub(super) use spec::OutputContract;
use spec::{contract as output_contract, unsupported_contract};
use types::{
    PROVIDER_OUTPUT_MAX_BYTES, PROVIDER_OUTPUT_SCHEMA_VERSION, ProviderEvidence, ProviderFact,
    ProviderNextAction, ProviderOperationError, ProviderOperationOutput, ProviderTruncation,
};
#[cfg(test)]
use types::{ProviderCollection, ProviderCollectionItem};

#[cfg(test)]
pub(super) fn output_schema(operation: &str) -> Option<Value> {
    let operation = OperationId::parse(operation)?;
    Some(provider_output_schema(
        operation.as_str(),
        output_contract(operation),
    ))
}

pub(super) const fn contract(operation: OperationId) -> OutputContract {
    output_contract(operation)
}

pub(super) fn schema_for_contract(operation: &str, contract: OutputContract) -> Value {
    provider_output_schema(operation, contract)
}

pub(crate) fn provider_result_content(
    operation: &str,
    result: &CapabilityResult,
) -> CapabilityResultMessageContent {
    if result_contains_image(result) {
        return CapabilityResultMessageContent::Text(render_provider_boundary_failure(
            operation,
            "PROVIDER_OUTPUT_UNCUSTODIED_MEDIA",
            "Capability results must return durable media resource refs; inline image blocks are not part of the canonical provider transport.",
        ));
    }
    let rendered = render_provider_output(operation, result)
        .unwrap_or_else(|error| render_internal_contract_failure(operation, &error));
    CapabilityResultMessageContent::Text(rendered)
}

pub(crate) fn provider_result_text(operation: &str, result: &CapabilityResult) -> String {
    match provider_result_content(operation, result) {
        CapabilityResultMessageContent::Text(text) => text,
        CapabilityResultMessageContent::Blocks(blocks) => blocks
            .into_iter()
            .filter_map(|block| match block {
                CapabilityResultContent::Text { text } => Some(text),
                CapabilityResultContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

fn render_provider_output(operation: &str, result: &CapabilityResult) -> Result<String, String> {
    let operation_id = OperationId::parse(operation);
    let output_contract = operation_id.map_or_else(unsupported_contract, output_contract);
    let projected =
        projection::project_evidence(operation, output_contract.profile, result.details.as_ref());
    let summary = bounded_text(&raw_result_text(result), 1_200);
    let ok = !result.is_error.unwrap_or(false);
    let status = result
        .details
        .as_ref()
        .and_then(|details| details.get("status"))
        .and_then(Value::as_str)
        .map_or_else(
            || {
                if ok {
                    "ok".to_owned()
                } else {
                    "failed".to_owned()
                }
            },
            |status| bounded_text(status, 120),
        );
    let (mut evidence, mut truncation) = normalize_evidence(projected.clone());
    ensure_authoritative_fact(
        &mut evidence,
        &mut truncation,
        output_contract,
        "primitiveOperation",
        json!(operation),
    );
    ensure_authoritative_fact(
        &mut evidence,
        &mut truncation,
        output_contract,
        "status",
        json!(status.clone()),
    );
    let error = (!ok).then(|| normalize_error(projected.as_ref(), &summary));
    truncation.max_bytes = PROVIDER_OUTPUT_MAX_BYTES;
    let mut next_actions = normalize_next_actions(projected.as_ref());
    if operation_id.is_none() && !ok {
        next_actions.insert(0, unsupported_operation_recovery_action(operation));
        next_actions.truncate(8);
    }
    let mut output = ProviderOperationOutput {
        schema_version: PROVIDER_OUTPUT_SCHEMA_VERSION,
        operation: operation.to_owned(),
        profile: output_contract.profile.as_str(),
        ok,
        status,
        summary,
        evidence,
        next_actions,
        truncation,
        error,
    };
    fit_output_budget(
        &mut output,
        output_contract.semantic_evidence.required_fact_fields,
        output_contract.semantic_evidence.expected_collection_fields,
    )?;
    validate_semantic_evidence(output_contract, &output)?;
    let value = serde_json::to_value(&output)
        .map_err(|error| format!("serialize provider output: {error}"))?;
    validate_provider_output(operation, output_contract, &value)?;
    serde_json::to_string(&output).map_err(|error| format!("encode provider output: {error}"))
}

fn ensure_authoritative_fact(
    evidence: &mut ProviderEvidence,
    truncation: &mut ProviderTruncation,
    output_contract: OutputContract,
    field: &str,
    value: Value,
) {
    if let Some(fact) = evidence.facts.iter_mut().find(|fact| fact.field == field) {
        fact.value = value;
        return;
    }
    evidence.facts.insert(
        0,
        ProviderFact {
            field: field.to_owned(),
            value,
        },
    );
    if evidence.facts.len() > 160
        && let Some(index) = evidence.facts.iter().rposition(|fact| {
            !output_contract
                .semantic_evidence
                .required_fact_fields
                .contains(&fact.field.as_str())
        })
    {
        evidence.facts.remove(index);
        truncation.truncated = true;
        truncation.omitted_facts += 1;
    }
}

fn unsupported_operation_recovery_action(operation: &str) -> ProviderNextAction {
    ProviderNextAction {
        source: "unsupportedOperationRecovery".to_owned(),
        summary: format!(
            "Call catalog_search with the rejected operation name `{}` to discover an exact supported operation and inspect its schema before retrying.",
            bounded_text(operation, 160)
        ),
        operation: Some("catalog_search".to_owned()),
        inspect_id: None,
        arguments: Some(json!({
            "operation": "catalog_search",
            "text": bounded_text(operation, 160)
        })),
    }
}

fn render_provider_boundary_failure(operation: &str, code: &str, message: &str) -> String {
    let error = ProviderOperationError {
        code: code.to_owned(),
        category: "internal".to_owned(),
        message: bounded_text(message, 800),
        recoverable: false,
    };
    let output = ProviderOperationOutput {
        schema_version: PROVIDER_OUTPUT_SCHEMA_VERSION,
        operation: bounded_text(operation, 200),
        profile: "summary",
        ok: false,
        status: "failed".to_owned(),
        summary: "The operation completed, but its provider-safe output contract failed closed."
            .to_owned(),
        evidence: ProviderEvidence::default(),
        next_actions: Vec::new(),
        truncation: ProviderTruncation {
            max_bytes: PROVIDER_OUTPUT_MAX_BYTES,
            ..ProviderTruncation::default()
        },
        error: Some(error),
    };
    serde_json::to_string(&output).unwrap_or_else(|_| {
        r#"{"schemaVersion":"tron.provider_operation_output.v1","operation":"unknown","profile":"summary","ok":false,"status":"failed","summary":"Provider output failed closed.","evidence":{"facts":[],"resources":[],"collections":[]},"nextActions":[],"truncation":{"truncated":false,"omittedFacts":0,"omittedResources":0,"omittedCollections":0,"omittedItems":0,"omittedActions":0,"serializedBytes":0,"maxBytes":15000},"error":{"code":"PROVIDER_OUTPUT_CONTRACT_FAILED","category":"internal","message":"Provider output failed closed.","recoverable":false}}"#.to_owned()
    })
}

fn render_internal_contract_failure(operation: &str, message: &str) -> String {
    render_provider_boundary_failure(operation, "PROVIDER_OUTPUT_CONTRACT_FAILED", message)
}

fn result_contains_image(result: &CapabilityResult) -> bool {
    matches!(
        &result.content,
        CapabilityResultBody::Blocks(blocks)
            if blocks.iter().any(|block| matches!(block, CapabilityResultContent::Image { .. }))
    )
}

fn raw_result_text(result: &CapabilityResult) -> String {
    match &result.content {
        CapabilityResultBody::Text(text) => text.clone(),
        CapabilityResultBody::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| match block {
                CapabilityResultContent::Text { text } => Some(text.as_str()),
                CapabilityResultContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

fn validate_provider_output(
    operation: &str,
    output_contract: OutputContract,
    value: &Value,
) -> Result<(), String> {
    let function_id =
        FunctionId::new("capability::execute").expect("canonical capability function id");
    validate_engine_schema_payload(
        &function_id,
        "provider operation output",
        &provider_output_schema(operation, output_contract),
        value,
    )
    .map_err(|error| error.to_string())
}

fn provider_output_schema(operation: &str, output_contract: OutputContract) -> Value {
    json!({
        "type": "object",
        "required": [
            "schemaVersion", "operation", "profile", "ok", "status", "summary",
            "evidence", "nextActions", "truncation"
        ],
        "additionalProperties": false,
        "properties": {
            "schemaVersion": {"const": PROVIDER_OUTPUT_SCHEMA_VERSION},
            "operation": {"const": operation},
            "profile": {"const": output_contract.profile.as_str()},
            "ok": {"type": "boolean"},
            "status": {"type": "string", "maxLength": 120},
            "summary": {"type": "string", "maxLength": 1200},
            "evidence": evidence_schema(),
            "nextActions": {
                "type": "array",
                "maxItems": 8,
                "items": next_action_schema()
            },
            "truncation": truncation_schema(),
            "error": error_schema()
        },
        "allOf": [
            {
                "if": {"properties": {"ok": {"const": false}}},
                "then": {"required": ["error"]}
            },
            {
                "if": {"properties": {"ok": {"const": true}}},
                "then": {"not": {"required": ["error"]}}
            }
        ],
        "semanticEvidenceContract": {
            "description": output_contract.semantic_evidence.description,
            "summaryPolicy": output_contract.summary_policy.as_str(),
            "requiredFactFieldsOnSuccess": output_contract.semantic_evidence.required_fact_fields,
            "expectedCollectionFields": output_contract.semantic_evidence.expected_collection_fields,
            "expectedResourceKinds": output_contract.semantic_evidence.expected_resource_kinds,
            "safetyExclusions": output_contract.semantic_evidence.safety_exclusions
        },
        "schemaCompleteness": "exact_provider_operation_output"
    })
}

fn validate_semantic_evidence(
    contract: OutputContract,
    output: &ProviderOperationOutput,
) -> Result<(), String> {
    if !output.ok {
        return Ok(());
    }
    for required in contract.semantic_evidence.required_fact_fields {
        if !output
            .evidence
            .facts
            .iter()
            .any(|fact| fact.field == *required)
        {
            return Err(format!(
                "provider output is missing required semantic fact `{required}`"
            ));
        }
    }
    for expected in contract.semantic_evidence.expected_collection_fields {
        if !output
            .evidence
            .collections
            .iter()
            .any(|collection| collection.field == *expected)
        {
            return Err(format!(
                "provider output is missing expected semantic collection `{expected}`"
            ));
        }
    }
    Ok(())
}

fn evidence_schema() -> Value {
    json!({
        "type": "object",
        "required": ["facts", "resources", "collections"],
        "additionalProperties": false,
        "properties": {
            "facts": {
                "type": "array",
                "maxItems": 160,
                "items": fact_schema()
            },
            "resources": {
                "type": "array",
                "maxItems": 64,
                "items": resource_ref_schema()
            },
            "collections": {
                "type": "array",
                "maxItems": 24,
                "items": collection_schema()
            }
        }
    })
}

fn fact_schema() -> Value {
    json!({
        "type": "object",
        "required": ["field", "value"],
        "additionalProperties": false,
        "properties": {
            "field": {"type": "string", "maxLength": 200},
            "value": {"type": ["string", "number", "integer", "boolean", "null"]}
        }
    })
}

fn resource_ref_schema() -> Value {
    json!({
        "type": "object",
        "required": ["kind", "resourceId"],
        "additionalProperties": false,
        "properties": {
            "kind": {"type": "string", "maxLength": 200},
            "resourceId": {"type": "string", "maxLength": 800},
            "versionId": {"type": "string", "maxLength": 800},
            "role": {"type": "string", "maxLength": 200}
        }
    })
}

fn collection_schema() -> Value {
    json!({
        "type": "object",
        "required": ["field", "total", "returned", "truncated", "items"],
        "additionalProperties": false,
        "properties": {
            "field": {"type": "string", "maxLength": 200},
            "total": {"type": "integer", "minimum": 0},
            "returned": {"type": "integer", "minimum": 0, "maximum": 12},
            "truncated": {"type": "boolean"},
            "items": {
                "type": "array",
                "maxItems": 12,
                "items": {
                    "type": "object",
                    "required": ["facts", "resources"],
                    "additionalProperties": false,
                    "properties": {
                        "facts": {"type": "array", "maxItems": 32, "items": fact_schema()},
                        "resources": {"type": "array", "maxItems": 8, "items": resource_ref_schema()}
                    }
                }
            }
        }
    })
}

fn next_action_schema() -> Value {
    json!({
        "type": "object",
        "required": ["source", "summary"],
        "additionalProperties": false,
        "properties": {
            "source": {"type": "string", "maxLength": 200},
            "summary": {"type": "string", "maxLength": 500},
            "operation": {"type": "string", "maxLength": 200},
            "inspectId": {"type": "string", "maxLength": 800},
            "arguments": {
                "type": "object",
                "maxProperties": 8,
                "additionalProperties": false,
                "properties": {
                    "operation": {"type": "string", "maxLength": 200},
                    "text": {"type": "string", "maxLength": 200}
                }
            }
        }
    })
}

fn truncation_schema() -> Value {
    json!({
        "type": "object",
        "required": [
            "truncated", "omittedFacts", "omittedResources", "omittedCollections",
            "omittedItems", "omittedActions", "serializedBytes", "maxBytes"
        ],
        "additionalProperties": false,
        "properties": {
            "truncated": {"type": "boolean"},
            "omittedFacts": {"type": "integer", "minimum": 0},
            "omittedResources": {"type": "integer", "minimum": 0},
            "omittedCollections": {"type": "integer", "minimum": 0},
            "omittedItems": {"type": "integer", "minimum": 0},
            "omittedActions": {"type": "integer", "minimum": 0},
            "serializedBytes": {"type": "integer", "minimum": 0, "maximum": PROVIDER_OUTPUT_MAX_BYTES},
            "maxBytes": {"const": PROVIDER_OUTPUT_MAX_BYTES}
        }
    })
}

fn error_schema() -> Value {
    json!({
        "type": "object",
        "required": ["code", "category", "message", "recoverable"],
        "additionalProperties": false,
        "properties": {
            "code": {"type": "string", "maxLength": 800},
            "category": {"type": "string", "maxLength": 200},
            "message": {"type": "string", "maxLength": 800},
            "recoverable": {"type": "boolean"}
        }
    })
}

#[cfg(test)]
mod tests;
