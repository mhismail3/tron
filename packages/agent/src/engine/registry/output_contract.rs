//! Function output-contract validation for live catalog invocations.

use serde_json::Value;

use crate::engine::errors::{EngineError, Result};
use crate::engine::invocation::Invocation;
use crate::engine::types::{DurableOutputContract, FunctionDefinition};

pub(super) fn validate_output_contract(
    function: &FunctionDefinition,
    invocation: &Invocation,
    value: &Value,
) -> Result<()> {
    match &function.output_contract {
        DurableOutputContract::None => Ok(()),
        DurableOutputContract::ResourceBacked {
            produced_resource_kinds,
            required_resource_refs,
        } => validate_resource_backed_output(
            function,
            value,
            produced_resource_kinds,
            *required_resource_refs,
        ),
        DurableOutputContract::Conditional {
            classifier,
            resource_backed_contract,
        } => {
            if output_classifier_matches(classifier, invocation) {
                match resource_backed_contract.as_ref() {
                    DurableOutputContract::ResourceBacked {
                        produced_resource_kinds,
                        required_resource_refs,
                    } => validate_resource_backed_output(
                        function,
                        value,
                        produced_resource_kinds,
                        *required_resource_refs,
                    ),
                    _ => Err(EngineError::PolicyViolation(format!(
                        "function {} has non-resource-backed conditional output contract",
                        function.id
                    ))),
                }
            } else {
                Ok(())
            }
        }
    }
}

pub(super) fn output_contract_resource_kinds(contract: &DurableOutputContract) -> Vec<String> {
    match contract {
        DurableOutputContract::None => Vec::new(),
        DurableOutputContract::ResourceBacked {
            produced_resource_kinds,
            ..
        } => produced_resource_kinds.clone(),
        DurableOutputContract::Conditional {
            resource_backed_contract,
            ..
        } => output_contract_resource_kinds(resource_backed_contract),
    }
}

fn validate_resource_backed_output(
    function: &FunctionDefinition,
    value: &Value,
    produced_resource_kinds: &[String],
    required_resource_refs: bool,
) -> Result<()> {
    let refs = value.get("resourceRefs").and_then(Value::as_array);
    let Some(refs) = refs else {
        return if required_resource_refs {
            Err(EngineError::PolicyViolation(format!(
                "function {} declared resource-backed output but result omitted top-level resourceRefs",
                function.id
            )))
        } else {
            Ok(())
        };
    };
    if required_resource_refs && refs.is_empty() {
        return Err(EngineError::PolicyViolation(format!(
            "function {} declared resource-backed output but result returned no resourceRefs",
            function.id
        )));
    }
    for resource_ref in refs {
        validate_resource_ref(function, resource_ref, produced_resource_kinds)?;
    }
    Ok(())
}

fn validate_resource_ref(
    function: &FunctionDefinition,
    resource_ref: &Value,
    produced_resource_kinds: &[String],
) -> Result<()> {
    let object = resource_ref.as_object().ok_or_else(|| {
        EngineError::PolicyViolation(format!(
            "function {} returned a non-object resourceRef",
            function.id
        ))
    })?;
    let resource_id = required_non_empty_ref_field(function, object, "resourceId")?;
    let kind = required_non_empty_ref_field(function, object, "kind")?;
    let _role = required_non_empty_ref_field(function, object, "role")?;
    for optional in ["versionId", "contentHash", "relation"] {
        if let Some(value) = object.get(optional)
            && !value.as_str().is_some_and(|text| !text.trim().is_empty())
            && !value.is_null()
        {
            return Err(EngineError::PolicyViolation(format!(
                "function {} returned invalid resourceRef {} for {resource_id}",
                function.id, optional
            )));
        }
    }
    if !produced_resource_kinds.iter().any(|allowed| allowed == "*")
        && !produced_resource_kinds
            .iter()
            .any(|allowed| allowed == kind)
    {
        return Err(EngineError::PolicyViolation(format!(
            "function {} returned resourceRef kind {kind}, allowed kinds: {}",
            function.id,
            produced_resource_kinds.join(", ")
        )));
    }
    Ok(())
}

fn required_non_empty_ref_field<'a>(
    function: &FunctionDefinition,
    object: &'a serde_json::Map<String, Value>,
    field: &str,
) -> Result<&'a str> {
    object
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "function {} returned resourceRef without {field}",
                function.id
            ))
        })
}

fn output_classifier_matches(classifier: &str, invocation: &Invocation) -> bool {
    match classifier {
        "always" => true,
        "process_write_like" => process_payload_is_write_like(&invocation.payload),
        "process_resource_output_required" => {
            process_payload_is_write_like(&invocation.payload)
                || invocation
                    .payload
                    .get("executionMode")
                    .and_then(Value::as_str)
                    .is_some_and(|mode| mode == "sandbox_materialized")
                || invocation
                    .payload
                    .get("retainOutput")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
        }
        _ => false,
    }
}

fn process_payload_is_write_like(payload: &Value) -> bool {
    let command = payload
        .get("command")
        .and_then(Value::as_str)
        .or_else(|| payload.get("program").and_then(Value::as_str))
        .unwrap_or_default();
    let args = payload
        .get("args")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join(" ")
        })
        .unwrap_or_default();
    let command_line = format!("{command} {args}").to_lowercase();
    [
        ">",
        ">>",
        "tee ",
        "sed -i",
        "perl -i",
        "mv ",
        "cp ",
        "rm ",
        "touch ",
        "mkdir ",
        "install ",
        "apply_patch",
        "git checkout",
        "git reset",
    ]
    .into_iter()
    .any(|needle| command_line.contains(needle))
}
