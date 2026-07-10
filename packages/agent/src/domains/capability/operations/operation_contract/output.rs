//! Canonical provider-visible result contract for `capability::execute`.
//!
//! Raw [`CapabilityResult`] values remain internal audit/UI state. This module
//! owns the exact model-facing envelope, operation profile, redacted evidence
//! projection, common failure branch, and structural byte budget. Provider
//! adapters transport the resulting bytes; they must not rebuild or truncate
//! the contract.

use crate::engine::{FunctionId, validate_engine_schema_payload};
use crate::shared::foundation::text::truncate_str;
use crate::shared::protocol::content::CapabilityResultContent;
use crate::shared::protocol::messages::CapabilityResultMessageContent;
use crate::shared::protocol::model_capabilities::{CapabilityResult, CapabilityResultBody};
use serde_json::{Value, json};

use super::OperationId;

mod normalize;
mod projection;
mod spec;
mod types;

use normalize::{bounded_text, normalize_error, normalize_evidence, normalize_next_actions};
use spec::{OutputProfile, profile};
use types::{
    PROVIDER_OUTPUT_MAX_BYTES, PROVIDER_OUTPUT_SCHEMA_VERSION, ProviderEvidence,
    ProviderOperationError, ProviderOperationOutput, ProviderTruncation,
};

pub(super) fn output_schema(operation: &str) -> Option<Value> {
    let operation = OperationId::parse(operation)?;
    Some(provider_output_schema(
        operation.as_str(),
        profile(operation),
    ))
}

pub(crate) fn provider_result_content(
    operation: &str,
    result: &CapabilityResult,
) -> CapabilityResultMessageContent {
    let rendered = render_provider_output(operation, result)
        .unwrap_or_else(|error| render_internal_contract_failure(operation, &error));
    match &result.content {
        CapabilityResultBody::Blocks(blocks)
            if blocks
                .iter()
                .any(|block| matches!(block, CapabilityResultContent::Image { .. })) =>
        {
            let mut projected = blocks
                .iter()
                .filter_map(|block| match block {
                    CapabilityResultContent::Image { data, mime_type } => Some(
                        CapabilityResultContent::image(data.clone(), mime_type.clone()),
                    ),
                    CapabilityResultContent::Text { .. } => None,
                })
                .collect::<Vec<_>>();
            projected.push(CapabilityResultContent::text(rendered));
            CapabilityResultMessageContent::Blocks(projected)
        }
        _ => CapabilityResultMessageContent::Text(rendered),
    }
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
    let profile = operation_id.map_or(OutputProfile::Summary, profile);
    let projected = projection::project_evidence(operation, profile, result.details.as_ref());
    let summary = bounded_text(&raw_result_text(result), 1_200);
    let (evidence, mut truncation) = normalize_evidence(projected.clone());
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
    let error = (!ok).then(|| normalize_error(projected.as_ref(), &summary));
    truncation.max_bytes = PROVIDER_OUTPUT_MAX_BYTES;
    let mut output = ProviderOperationOutput {
        schema_version: PROVIDER_OUTPUT_SCHEMA_VERSION,
        operation: operation.to_owned(),
        profile: profile.as_str(),
        ok,
        status,
        summary,
        evidence,
        next_actions: normalize_next_actions(projected.as_ref()),
        truncation,
        error,
    };
    fit_output_budget(&mut output)?;
    let value = serde_json::to_value(&output)
        .map_err(|error| format!("serialize provider output: {error}"))?;
    validate_provider_output(operation, profile, &value)?;
    serde_json::to_string(&output).map_err(|error| format!("encode provider output: {error}"))
}

fn fit_output_budget(output: &mut ProviderOperationOutput) -> Result<(), String> {
    loop {
        let encoded = serde_json::to_vec(output)
            .map_err(|error| format!("measure provider output: {error}"))?;
        output.truncation.serialized_bytes = encoded.len();
        if encoded.len() <= PROVIDER_OUTPUT_MAX_BYTES {
            let final_size = serde_json::to_vec(output)
                .map_err(|error| format!("remeasure provider output: {error}"))?
                .len();
            output.truncation.serialized_bytes = final_size;
            if final_size <= PROVIDER_OUTPUT_MAX_BYTES {
                return Ok(());
            }
        }
        output.truncation.truncated = true;
        if let Some(collection) = output.evidence.collections.pop() {
            output.truncation.omitted_collections += 1;
            output.truncation.omitted_items += collection.total;
        } else if output.evidence.facts.pop().is_some() {
            output.truncation.omitted_facts += 1;
        } else if output.evidence.resources.pop().is_some() {
            output.truncation.omitted_resources += 1;
        } else if output.next_actions.pop().is_some() {
            output.truncation.omitted_facts += 1;
        } else if output.summary.len() > 240 {
            output.summary = truncate_str(&output.summary, output.summary.len() / 2).to_owned();
        } else {
            return Err("minimal provider output exceeds structural byte budget".to_owned());
        }
    }
}

fn render_internal_contract_failure(operation: &str, message: &str) -> String {
    let error = ProviderOperationError {
        code: "PROVIDER_OUTPUT_CONTRACT_FAILED".to_owned(),
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
        r#"{"schemaVersion":"tron.provider_operation_output.v1","operation":"unknown","profile":"summary","ok":false,"status":"failed","summary":"Provider output failed closed.","evidence":{"facts":[],"resources":[],"collections":[]},"nextActions":[],"truncation":{"truncated":false,"omittedFacts":0,"omittedResources":0,"omittedCollections":0,"omittedItems":0,"serializedBytes":0,"maxBytes":15000},"error":{"code":"PROVIDER_OUTPUT_CONTRACT_FAILED","category":"internal","message":"Provider output failed closed.","recoverable":false}}"#.to_owned()
    })
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
    profile: OutputProfile,
    value: &Value,
) -> Result<(), String> {
    let function_id =
        FunctionId::new("capability::execute").expect("canonical capability function id");
    validate_engine_schema_payload(
        &function_id,
        "provider operation output",
        &provider_output_schema(operation, profile),
        value,
    )
    .map_err(|error| error.to_string())
}

fn provider_output_schema(operation: &str, profile: OutputProfile) -> Value {
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
            "profile": {"const": profile.as_str()},
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
        "schemaCompleteness": "exact_provider_operation_output"
    })
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
            "inspectId": {"type": "string", "maxLength": 800}
        }
    })
}

fn truncation_schema() -> Value {
    json!({
        "type": "object",
        "required": [
            "truncated", "omittedFacts", "omittedResources", "omittedCollections",
            "omittedItems", "serializedBytes", "maxBytes"
        ],
        "additionalProperties": false,
        "properties": {
            "truncated": {"type": "boolean"},
            "omittedFacts": {"type": "integer", "minimum": 0},
            "omittedResources": {"type": "integer", "minimum": 0},
            "omittedCollections": {"type": "integer", "minimum": 0},
            "omittedItems": {"type": "integer", "minimum": 0},
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
mod tests {
    use super::*;

    fn result(text: &str, is_error: bool, details: Value) -> CapabilityResult {
        CapabilityResult {
            content: CapabilityResultBody::Text(text.to_owned()),
            details: Some(details),
            is_error: is_error.then_some(true),
            stop_turn: None,
        }
    }

    #[test]
    fn every_operation_has_one_closed_profiled_output_schema() {
        for operation in OperationId::ALL_NAMES {
            let schema = output_schema(operation).expect("supported output schema");
            assert_eq!(schema["additionalProperties"], false, "{operation}");
            assert_eq!(schema["properties"]["operation"]["const"], *operation);
            assert_eq!(
                schema["schemaCompleteness"], "exact_provider_operation_output",
                "{operation}"
            );
        }
    }

    #[test]
    fn success_and_failure_outputs_are_closed_and_bounded() {
        for result in [
            result(
                "ok",
                false,
                json!({
                    "primitiveOperation": "git_status",
                    "status": "ok",
                    "git": {"status": "clean", "summary": {"stagedCount": 0}}
                }),
            ),
            result(
                "failed",
                true,
                json!({
                    "primitiveOperation": "git_status",
                    "failure": {
                        "code": "ROUTE_STALE",
                        "category": "invalid_request",
                        "message": "route evidence is stale",
                        "recoverable": true
                    },
                    "dynamicReplacement": {"status": "failed_closed"}
                }),
            ),
        ] {
            let rendered = render_provider_output("git_status", &result).expect("provider output");
            assert!(rendered.len() <= PROVIDER_OUTPUT_MAX_BYTES);
            let value: Value = serde_json::from_str(&rendered).expect("valid JSON");
            let operation = OperationId::GitStatus;
            validate_provider_output(operation.as_str(), profile(operation), &value)
                .expect("valid output");
        }
    }

    #[test]
    fn raw_details_cannot_bypass_provider_evidence_algebra() {
        let result = result(
            "done",
            false,
            json!({
                "primitiveOperation": "observe",
                "status": "ok",
                "command": "secret command",
                "workingDirectory": "/private/example",
                "apiKey": "sk-example-secret-value"
            }),
        );
        let rendered = render_provider_output("observe", &result).expect("provider output");
        assert!(!rendered.contains("secret command"));
        assert!(!rendered.contains("/private/example"));
        assert!(!rendered.contains("sk-example-secret-value"));
    }

    #[test]
    fn large_outputs_are_structurally_truncated_as_valid_json() {
        let values = (0..1_000)
            .map(|index| json!({"kind": "record", "resourceId": format!("record-{index}"), "summary": "x".repeat(1_000)}))
            .collect::<Vec<_>>();
        let result = result(
            "large",
            false,
            json!({
                "primitiveOperation": "module_list",
                "status": "ok",
                "records": values
            }),
        );
        let rendered = render_provider_output("module_list", &result).expect("provider output");
        assert!(rendered.len() <= PROVIDER_OUTPUT_MAX_BYTES);
        let value: Value = serde_json::from_str(&rendered).expect("valid JSON");
        assert_eq!(value["truncation"]["truncated"], true);
    }

    #[test]
    fn schema_rejects_wrong_operation_and_extra_fields() {
        let result = result(
            "ok",
            false,
            json!({
                "primitiveOperation": "git_status",
                "status": "ok",
                "git": {"status": "clean"}
            }),
        );
        let rendered = render_provider_output("git_status", &result).expect("provider output");
        let mut value: Value = serde_json::from_str(&rendered).expect("valid JSON");
        value["operation"] = json!("git_diff");
        assert!(validate_provider_output("git_status", OutputProfile::Git, &value).is_err());
        value["operation"] = json!("git_status");
        value["unexpected"] = json!(true);
        assert!(validate_provider_output("git_status", OutputProfile::Git, &value).is_err());
    }

    #[test]
    fn unsupported_operation_errors_keep_safe_recovery_evidence() {
        let result = result(
            "unsupported operation",
            true,
            json!({
                "failure": {
                    "code": "INVALID_PARAMS",
                    "category": "invalid_request",
                    "message": "Unsupported operation. Use catalog_search.",
                    "recoverable": true,
                    "suggestion": "Call catalog_search with the intended user goal."
                }
            }),
        );
        let rendered =
            render_provider_output("guessed_operation", &result).expect("common failure envelope");
        let value: Value = serde_json::from_str(&rendered).expect("valid JSON");
        assert_eq!(value["operation"], "guessed_operation");
        assert_eq!(value["profile"], "summary");
        assert_eq!(value["error"]["recoverable"], true);
        assert!(rendered.contains("catalog_search"));
        validate_provider_output("guessed_operation", OutputProfile::Summary, &value)
            .expect("valid common failure envelope");
    }
}
