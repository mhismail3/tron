//! Canonical provider-visible result contract for `capability::execute`.
//!
//! Raw [`CapabilityResult`] values remain internal audit/UI state. This module
//! owns the exact model-facing envelope, operation profile, redacted evidence
//! projection, common failure branch, and structural byte budget. Provider
//! adapters transport the resulting bytes; they must not rebuild or truncate
//! the contract. Common semantic facts (`primitiveOperation` and `status`) are
//! synthesized from this envelope's authoritative invocation/result state, not
//! duplicated by every domain handler, and byte-budget reduction never removes
//! facts required by the operation's semantic evidence contract.

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
pub(super) use spec::OutputContract;
use spec::{contract as output_contract, unsupported_contract};
use types::{
    PROVIDER_OUTPUT_MAX_BYTES, PROVIDER_OUTPUT_SCHEMA_VERSION, ProviderEvidence, ProviderFact,
    ProviderOperationError, ProviderOperationOutput, ProviderTruncation,
};
#[cfg(test)]
use types::{ProviderCollection, ProviderCollectionItem, ProviderNextAction};

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
    let mut output = ProviderOperationOutput {
        schema_version: PROVIDER_OUTPUT_SCHEMA_VERSION,
        operation: operation.to_owned(),
        profile: output_contract.profile.as_str(),
        ok,
        status,
        summary,
        evidence,
        next_actions: normalize_next_actions(projected.as_ref()),
        truncation,
        error,
    };
    fit_output_budget(
        &mut output,
        output_contract.semantic_evidence.required_fact_fields,
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

fn fit_output_budget(
    output: &mut ProviderOperationOutput,
    required_fact_fields: &[&str],
) -> Result<(), String> {
    loop {
        let encoded_len = stabilize_serialized_byte_count(output)?;
        if encoded_len <= PROVIDER_OUTPUT_MAX_BYTES {
            return Ok(());
        }
        output.truncation.truncated = true;
        if let Some(collection) = output.evidence.collections.pop() {
            output.truncation.omitted_collections += 1;
            output.truncation.omitted_items += collection.returned;
        } else if let Some(index) = output
            .evidence
            .facts
            .iter()
            .rposition(|fact| !required_fact_fields.contains(&fact.field.as_str()))
        {
            output.evidence.facts.remove(index);
            output.truncation.omitted_facts += 1;
        } else if output.evidence.resources.pop().is_some() {
            output.truncation.omitted_resources += 1;
        } else if output.next_actions.pop().is_some() {
            output.truncation.omitted_actions += 1;
        } else if output.summary.len() > 240 {
            output.summary = truncate_str(&output.summary, output.summary.len() / 2).to_owned();
        } else {
            return Err("minimal provider output exceeds structural byte budget".to_owned());
        }
    }
}

fn stabilize_serialized_byte_count(output: &mut ProviderOperationOutput) -> Result<usize, String> {
    for _ in 0..8 {
        let encoded_len = serde_json::to_vec(&*output)
            .map_err(|error| format!("measure provider output: {error}"))?
            .len();
        if output.truncation.serialized_bytes == encoded_len {
            return Ok(encoded_len);
        }
        output.truncation.serialized_bytes = encoded_len;
    }
    Err("provider output serialized byte count did not converge".to_owned())
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
            "inspectId": {"type": "string", "maxLength": 800}
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

    fn successful_details(operation: &str) -> Value {
        match operation {
            "catalog_search" | "catalog_inspect" | "catalog_conformance" => json!({
                "primitiveOperation": operation,
                "status": "ok",
                "catalogDiscovery": {"kind": "execute_operation", "id": "execute::observe"}
            }),
            "git_status" => json!({
                "primitiveOperation": operation,
                "status": "ok",
                "git": {
                    "schemaVersion": "tron.git_readonly.v1",
                    "operation": "status",
                    "status": "clean",
                    "summary": {"stagedCount": 0}
                }
            }),
            "web_robots_check" => json!({
                "primitiveOperation": operation,
                "status": "ok",
                "web": {
                    "schemaVersion": "tron.web_robots_policy.v1",
                    "operation": operation,
                    "status": "checked",
                    "webRobotsPolicyResourceId": "web_robots_policy:test",
                    "webRobotsPolicyVersionId": "version:test",
                    "resourceRefs": []
                }
            }),
            "web_fetch" => json!({
                "primitiveOperation": operation,
                "status": "ok",
                "web": {
                    "schemaVersion": "tron.web_source.v1",
                    "operation": operation,
                    "status": "fetched",
                    "webSourceResourceId": "web_source:test",
                    "webSourceVersionId": "version:test",
                    "resourceRefs": []
                }
            }),
            "job_status" | "job_list" => json!({
                "primitiveOperation": operation,
                "status": "ok",
                "jobs": {"schemaVersion": "tron.jobs.provider_safe.v1", "jobs": []}
            }),
            "job_log" => json!({
                "primitiveOperation": operation,
                "status": "ok",
                "jobs": {
                    "schemaVersion": "tron.jobs.provider_safe.v1",
                    "jobResourceId": "job_process:test",
                    "jobVersionId": "version:test",
                    "resourceRefs": []
                }
            }),
            "trace_list" => json!({
                "primitiveOperation": operation,
                "status": "ok",
                "projectionBoundary": {"providerVisibleProjection": true},
                "statusSummary": {"totalRecords": 0},
                "records": []
            }),
            "trace_get" => json!({
                "primitiveOperation": operation,
                "status": "ok",
                "projectionBoundary": {"providerVisibleProjection": true},
                "record": {"schemaVersion": "tron.trace.provider_safe.v1"}
            }),
            "context_control_status" => json!({
                "primitiveOperation": operation,
                "status": "ok",
                "contextControl": {
                    "schemaVersion": "tron.context_control.v1",
                    "projection": {"status": {"epoch": "epoch-0"}}
                }
            }),
            "capability_binding_cockpit_overview" => json!({
                "primitiveOperation": operation,
                "status": "ok",
                "capabilityBinding": {
                    "summary": {"totalOperations": OperationId::ALL_NAMES.len()},
                    "operations": []
                }
            }),
            _ => json!({"primitiveOperation": operation, "status": "ok", "summary": "done"}),
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
                    "git": {
                        "schemaVersion": "tron.git_readonly.v1",
                        "operation": "status",
                        "status": "clean",
                        "summary": {"stagedCount": 0}
                    }
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
            assert_eq!(
                value["truncation"]["serializedBytes"],
                rendered.len(),
                "serialized byte proof must describe the transmitted bytes"
            );
            let operation = OperationId::GitStatus;
            validate_provider_output(operation.as_str(), contract(operation), &value)
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
                "summary": "safe",
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
    fn common_only_summary_evidence_remains_semantically_complete() {
        let result = result(
            "Observation recorded.",
            false,
            json!({
                "primitiveOperation": "observe",
                "status": "ok"
            }),
        );
        let rendered = render_provider_output("observe", &result).expect("provider output");
        let value: Value = serde_json::from_str(&rendered).expect("valid provider JSON");

        assert_eq!(value["ok"], true);
        assert!(value["evidence"]["facts"].as_array().is_some_and(|facts| {
            facts
                .iter()
                .any(|fact| fact["field"] == "primitiveOperation" && fact["value"] == "observe")
        }));
    }

    #[test]
    fn catalog_inspect_synthesizes_common_facts_from_the_canonical_envelope() {
        let result = result(
            "Catalog execute_operation inspected: execute::git_status.",
            false,
            json!({
                "catalogDiscovery": {
                    "kind": "execute_operation",
                    "id": "execute::git_status",
                    "operation": "git_status",
                    "providerCallable": true,
                    "inputSchema": {
                        "type": "object",
                        "required": ["operation"]
                    }
                }
            }),
        );

        let rendered = render_provider_output("catalog_inspect", &result)
            .expect("real catalog-inspect details must satisfy the canonical output contract");
        let value: Value = serde_json::from_str(&rendered).expect("valid provider JSON");

        assert_eq!(value["ok"], true);
        assert_eq!(value["status"], "ok");
        assert!(value["evidence"]["facts"].as_array().is_some_and(|facts| {
            facts.iter().any(|fact| {
                fact["field"] == "primitiveOperation" && fact["value"] == "catalog_inspect"
            }) && facts
                .iter()
                .any(|fact| fact["field"] == "status" && fact["value"] == "ok")
        }));
    }

    #[test]
    fn raw_content_is_sanitized_at_the_provider_boundary() {
        let result = result(
            "authority grant grant_123456789 at /private/example; providerInvocationId=call_123456789; token sk-example-secret-value",
            false,
            json!({
                "primitiveOperation": "observe",
                "status": "ok",
                "summary": "safe"
            }),
        );
        let rendered = render_provider_output("observe", &result).expect("provider output");
        assert!(!rendered.contains("grant_123456789"));
        assert!(!rendered.contains("/private/example"));
        assert!(!rendered.contains("call_123456789"), "{rendered}");
        assert!(!rendered.contains("sk-example-secret-value"));
    }

    #[test]
    fn inline_image_blocks_fail_closed_to_text_only_transport() {
        let result = CapabilityResult {
            content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::image(
                "base64-data",
                "image/png",
            )]),
            details: Some(successful_details("observe")),
            is_error: None,
            stop_turn: None,
        };
        let CapabilityResultMessageContent::Text(rendered) =
            provider_result_content("observe", &result)
        else {
            panic!("provider transport must be text only");
        };
        assert!(rendered.contains("PROVIDER_OUTPUT_UNCUSTODIED_MEDIA"));
        assert!(!rendered.contains("base64-data"));
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
    fn byte_budget_omission_proof_counts_each_removed_item_once() {
        let mut output = ProviderOperationOutput {
            schema_version: PROVIDER_OUTPUT_SCHEMA_VERSION,
            operation: "observe".to_owned(),
            profile: "summary",
            ok: true,
            status: "ok".to_owned(),
            summary: "x".repeat(PROVIDER_OUTPUT_MAX_BYTES),
            evidence: ProviderEvidence {
                facts: Vec::new(),
                resources: Vec::new(),
                collections: vec![ProviderCollection {
                    field: "records".to_owned(),
                    total: 100,
                    returned: 12,
                    truncated: true,
                    items: vec![ProviderCollectionItem::default(); 12],
                }],
            },
            next_actions: vec![ProviderNextAction {
                source: "agentNextStep".to_owned(),
                summary: "inspect".repeat(200),
                operation: Some("catalog_inspect".to_owned()),
                inspect_id: Some("execute::observe".to_owned()),
            }],
            truncation: ProviderTruncation {
                truncated: true,
                omitted_items: 88,
                max_bytes: PROVIDER_OUTPUT_MAX_BYTES,
                ..ProviderTruncation::default()
            },
            error: None,
        };

        fit_output_budget(&mut output, &[]).expect("output fits after structural removal");

        assert_eq!(output.truncation.omitted_collections, 1);
        assert_eq!(output.truncation.omitted_items, 100);
        assert_eq!(output.truncation.omitted_actions, 1);
        assert_eq!(output.truncation.omitted_facts, 0);
    }

    #[test]
    fn byte_budget_never_removes_required_semantic_facts() {
        let mut facts = vec![
            ProviderFact {
                field: "primitiveOperation".to_owned(),
                value: json!("observe"),
            },
            ProviderFact {
                field: "status".to_owned(),
                value: json!("ok"),
            },
        ];
        facts.extend((0..80).map(|index| ProviderFact {
            field: format!("extra.{index}"),
            value: json!("x".repeat(800)),
        }));
        let mut output = ProviderOperationOutput {
            schema_version: PROVIDER_OUTPUT_SCHEMA_VERSION,
            operation: "observe".to_owned(),
            profile: "summary",
            ok: true,
            status: "ok".to_owned(),
            summary: "done".to_owned(),
            evidence: ProviderEvidence {
                facts,
                resources: Vec::new(),
                collections: Vec::new(),
            },
            next_actions: Vec::new(),
            truncation: ProviderTruncation {
                max_bytes: PROVIDER_OUTPUT_MAX_BYTES,
                ..ProviderTruncation::default()
            },
            error: None,
        };

        fit_output_budget(&mut output, &["primitiveOperation", "status"])
            .expect("non-required facts make the envelope reducible");

        assert!(
            output
                .evidence
                .facts
                .iter()
                .any(|fact| fact.field == "primitiveOperation")
        );
        assert!(
            output
                .evidence
                .facts
                .iter()
                .any(|fact| fact.field == "status")
        );
        assert!(output.truncation.omitted_facts > 0);
    }

    #[test]
    fn schema_rejects_wrong_operation_and_extra_fields() {
        let result = result("ok", false, successful_details("git_status"));
        let rendered = render_provider_output("git_status", &result).expect("provider output");
        let mut value: Value = serde_json::from_str(&rendered).expect("valid JSON");
        value["operation"] = json!("git_diff");
        assert!(
            validate_provider_output("git_status", contract(OperationId::GitStatus), &value)
                .is_err()
        );
        value["operation"] = json!("git_status");
        value["unexpected"] = json!(true);
        assert!(
            validate_provider_output("git_status", contract(OperationId::GitStatus), &value)
                .is_err()
        );
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
        validate_provider_output("guessed_operation", unsupported_contract(), &value)
            .expect("valid common failure envelope");
    }

    #[test]
    fn every_operation_renders_a_valid_failure_envelope() {
        for operation in OperationId::ALL_NAMES {
            let result = result(
                "request failed",
                true,
                json!({
                    "primitiveOperation": operation,
                    "failure": {
                        "code": "INVALID_PARAMS",
                        "category": "invalid_request",
                        "message": "Inspect the exact operation contract and retry.",
                        "recoverable": true
                    }
                }),
            );
            let rendered = render_provider_output(operation, &result)
                .unwrap_or_else(|error| panic!("{operation}: {error}"));
            assert!(rendered.len() <= PROVIDER_OUTPUT_MAX_BYTES, "{operation}");
            let value: Value = serde_json::from_str(&rendered)
                .unwrap_or_else(|error| panic!("{operation}: {error}"));
            let operation_id = OperationId::parse(operation).expect("registered operation");
            validate_provider_output(operation, contract(operation_id), &value)
                .unwrap_or_else(|error| panic!("{operation}: {error}"));
            assert_eq!(
                value["truncation"]["serializedBytes"],
                rendered.len(),
                "{operation}"
            );
        }
    }

    #[test]
    fn every_output_profile_renders_required_success_semantics() {
        for operation in [
            "observe",
            "catalog_search",
            "filesystem_read",
            "git_status",
            "job_status",
            "trace_list",
            "context_control_status",
            "goal_list",
            "capability_binding_cockpit_overview",
            "web_robots_check",
        ] {
            let rendered = render_provider_output(
                operation,
                &result("completed", false, successful_details(operation)),
            )
            .unwrap_or_else(|error| panic!("{operation}: {error}"));
            let value: Value = serde_json::from_str(&rendered).expect("valid JSON");
            assert_eq!(value["ok"], true, "{operation}");
            assert_eq!(value["operation"], operation, "{operation}");
        }
    }
}
