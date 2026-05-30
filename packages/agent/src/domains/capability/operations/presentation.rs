//! Model-visible capability search, inspection, and freshness guidance text.

use serde_json::{Value, json};

use super::super::registry::{AgentCapabilityRecipeDisplay, CapabilityRegistryEntry};
use super::super::types::CapabilityIndexHit;
use crate::engine::FunctionDefinition;
use crate::shared::server::errors::CapabilityError;

pub(super) fn render_search_summary(query: &str, results: &[CapabilityIndexHit]) -> String {
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
    let display = AgentCapabilityRecipeDisplay::new(recipe);
    if let Some(template) = &display.execute_template_json {
        lines.push(format!("Execute:\n```json\n{template}\n```"));
    }
    if !recipe.required_payload.is_empty() {
        lines.push(format!(
            "Required arguments: {}.",
            display.required_arguments
        ));
    }
    if let Some(optional) = display.optional_arguments_limited(8) {
        lines.push(format!("Optional payload: {optional}."));
    }
    lines.push(display.search_execution_guidance);
    if let Some(approval) = display.approval_guidance {
        lines.push(approval);
    }
    lines.push(format!("Result: {}", recipe.result_summary));
    lines.join("\n")
}

pub(super) fn render_inspection_summary(details: &Value) -> String {
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

pub(super) fn missing_inspection_requirements_error(
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
