//! Target payload validation and schema-error guidance for capability execution.

use serde_json::{Value, json};

use super::super::registry::CapabilityRegistryEntry;
use crate::shared::server::error_mapping::engine_error_to_capability_error;
use crate::shared::server::errors::{self as capability_error_codes, CapabilityError};

pub(super) fn validate_target_payload(
    entry: &CapabilityRegistryEntry,
    payload: &Value,
) -> Result<(), CapabilityError> {
    let function = &entry.function;
    if let Some(schema) = &function.request_schema {
        crate::engine::schema::validate_payload(&function.id, "request", schema, payload)
            .map_err(|error| recipe_validation_error_for_payload(entry, payload, error))?;
    }
    Ok(())
}

fn recipe_validation_error_for_payload(
    entry: &CapabilityRegistryEntry,
    payload: &Value,
    error: crate::engine::EngineError,
) -> CapabilityError {
    let schema_details = schema_violation_details(
        &error,
        entry.function.request_schema.as_ref(),
        Some(payload),
    );
    recipe_validation_error_with_schema_details(entry, error, schema_details)
}

fn recipe_validation_error_with_schema_details(
    entry: &CapabilityRegistryEntry,
    error: crate::engine::EngineError,
    schema_details: Option<Value>,
) -> CapabilityError {
    let mapped = engine_error_to_capability_error(error);
    let recipe = entry.agent_recipe();
    let example = serde_json::to_string(&recipe.execute_template).unwrap_or_else(|_| {
        format!(
            "{{\"mode\":\"invoke\",\"contractId\":\"{}\",\"payload\":{{}}}}",
            recipe.contract_id
        )
    });
    let guidance = format!(
        "Invalid arguments for {}. Put target arguments inside execute.arguments. Required arguments: {}. Optional arguments: {}.{} Example: {}",
        entry.contract_id,
        if recipe.required_payload.is_empty() {
            "none".to_owned()
        } else {
            recipe.required_payload.join("; ")
        },
        if recipe.optional_payload.is_empty() {
            "none".to_owned()
        } else {
            recipe.optional_payload.join("; ")
        },
        conditional_argument_guidance(entry),
        example
    );
    match mapped {
        CapabilityError::InvalidParams { message } => {
            let message = format!("{message}. {guidance}");
            if let Some(details) = schema_details {
                CapabilityError::Custom {
                    code: capability_error_codes::INVALID_PARAMS.to_owned(),
                    message,
                    details: Some(details),
                }
            } else {
                CapabilityError::InvalidParams { message }
            }
        }
        CapabilityError::Custom {
            code,
            message,
            details,
        } => CapabilityError::Custom {
            code,
            message: format!("{message}. {guidance}"),
            details: merge_validation_details(details, schema_details),
        },
        other => other,
    }
}

fn schema_violation_details(
    error: &crate::engine::EngineError,
    schema: Option<&Value>,
    payload: Option<&Value>,
) -> Option<Value> {
    let crate::engine::EngineError::SchemaViolation {
        path,
        message,
        direction,
        ..
    } = error
    else {
        return None;
    };
    let argument_path = schema_path_to_argument_path(path);
    let mut details = json!({
        "schemaPath": path,
        "schemaDirection": direction,
        "schemaMessage": message,
        "argumentPath": argument_path,
    });
    if message == "required field is missing" {
        let parent_path = schema_path_parent(path);
        let missing = schema_path_leaf(path);
        let (missing_fields, missing_argument_paths) =
            missing_required_arguments(schema, payload, &parent_path).unwrap_or_else(|| {
                (
                    vec![missing.clone()],
                    vec![schema_path_to_argument_path(path)],
                )
            });
        details["validationKind"] = json!("missing_required_argument");
        details["missingFields"] = json!(missing_fields);
        details["missingArgumentPaths"] = json!(missing_argument_paths);
    } else if (message.starts_with("string shorter than minLength ")
        && required_string_field_is_empty(schema, payload, path).unwrap_or(false))
        || (message.starts_with("expected type ")
            && required_field_is_null(schema, payload, path).unwrap_or(false))
    {
        let field = schema_path_leaf(path);
        details["validationKind"] = json!("missing_required_argument");
        details["missingFields"] = json!([field.clone()]);
        details["missingArgumentPaths"] = json!([schema_path_to_argument_path(path)]);
    }
    Some(details)
}

fn required_string_field_is_empty(
    schema: Option<&Value>,
    payload: Option<&Value>,
    path: &str,
) -> Option<bool> {
    let parent_path = schema_path_parent(path);
    let field = schema_path_leaf(path);
    let schema_parent = schema_node_at_path(schema?, &parent_path)?;
    let required = schema_parent.get("required")?.as_array()?;
    if !required.iter().any(|item| item.as_str() == Some(&field)) {
        return Some(false);
    }
    let payload_value = payload_node_at_path(payload?, path)?;
    Some(payload_value.as_str().is_some_and(str::is_empty))
}

fn required_field_is_null(
    schema: Option<&Value>,
    payload: Option<&Value>,
    path: &str,
) -> Option<bool> {
    let parent_path = schema_path_parent(path);
    let field = schema_path_leaf(path);
    let schema_parent = schema_node_at_path(schema?, &parent_path)?;
    let required = schema_parent.get("required")?.as_array()?;
    if !required.iter().any(|item| item.as_str() == Some(&field)) {
        return Some(false);
    }
    let payload_value = payload_node_at_path(payload?, path)?;
    Some(payload_value.is_null())
}

fn missing_required_arguments(
    schema: Option<&Value>,
    payload: Option<&Value>,
    parent_path: &str,
) -> Option<(Vec<String>, Vec<String>)> {
    let schema_parent = schema_node_at_path(schema?, parent_path)?;
    let payload_parent = payload_node_at_path(payload?, parent_path)?;
    let required = schema_parent.get("required")?.as_array()?;
    let payload_object = payload_parent.as_object()?;
    let mut missing_fields = Vec::new();
    let mut missing_argument_paths = Vec::new();
    for item in required {
        let field = item.as_str()?;
        if !payload_object.contains_key(field) {
            missing_fields.push(field.to_owned());
            missing_argument_paths.push(argument_path_for_field(parent_path, field));
        }
    }
    if missing_fields.is_empty() {
        None
    } else {
        Some((missing_fields, missing_argument_paths))
    }
}

fn schema_node_at_path<'a>(schema: &'a Value, path: &str) -> Option<&'a Value> {
    let mut node = schema;
    for token in schema_path_tokens(path) {
        match token {
            SchemaPathToken::Property(name) => {
                node = node.get("properties")?.get(name)?;
            }
            SchemaPathToken::Index(_) => {
                node = node.get("items")?;
            }
        }
    }
    Some(node)
}

fn payload_node_at_path<'a>(payload: &'a Value, path: &str) -> Option<&'a Value> {
    let mut node = payload;
    for token in schema_path_tokens(path) {
        match token {
            SchemaPathToken::Property(name) => {
                node = node.as_object()?.get(name)?;
            }
            SchemaPathToken::Index(index) => {
                node = node.as_array()?.get(index)?;
            }
        }
    }
    Some(node)
}

#[derive(Debug, PartialEq, Eq)]
enum SchemaPathToken<'a> {
    Property(&'a str),
    Index(usize),
}

fn schema_path_tokens(path: &str) -> Vec<SchemaPathToken<'_>> {
    let mut tokens = Vec::new();
    let Some(mut rest) = path.strip_prefix('$') else {
        return tokens;
    };
    while !rest.is_empty() {
        if let Some(after_dot) = rest.strip_prefix('.') {
            let next_dot = after_dot.find('.');
            let next_bracket = after_dot.find('[');
            let end = match (next_dot, next_bracket) {
                (Some(dot), Some(bracket)) => dot.min(bracket),
                (Some(dot), None) => dot,
                (None, Some(bracket)) => bracket,
                (None, None) => after_dot.len(),
            };
            if end == 0 {
                break;
            }
            tokens.push(SchemaPathToken::Property(&after_dot[..end]));
            rest = &after_dot[end..];
            continue;
        }
        if let Some(after_bracket) = rest.strip_prefix('[') {
            let Some(end) = after_bracket.find(']') else {
                break;
            };
            if let Ok(index) = after_bracket[..end].parse::<usize>() {
                tokens.push(SchemaPathToken::Index(index));
            }
            rest = &after_bracket[end + 1..];
            continue;
        }
        break;
    }
    tokens
}

fn merge_validation_details(
    details: Option<Value>,
    schema_details: Option<Value>,
) -> Option<Value> {
    match (details, schema_details) {
        (Some(Value::Object(mut base)), Some(Value::Object(extra))) => {
            for (key, value) in extra {
                base.insert(key, value);
            }
            Some(Value::Object(base))
        }
        (Some(details), None) => Some(details),
        (None, Some(schema_details)) => Some(schema_details),
        (Some(details), Some(schema_details)) => Some(json!({
            "original": details,
            "schema": schema_details,
        })),
        (None, None) => None,
    }
}

fn schema_path_to_argument_path(path: &str) -> String {
    let trimmed = path.strip_prefix("$.").unwrap_or(path);
    if trimmed == "$" || trimmed.is_empty() {
        "arguments".to_owned()
    } else {
        format!("arguments.{trimmed}")
    }
}

fn schema_path_parent(path: &str) -> String {
    let Some(last_dot) = path.rfind('.') else {
        return "$".to_owned();
    };
    if last_dot == 0 {
        "$".to_owned()
    } else {
        path[..last_dot].to_owned()
    }
}

fn argument_path_for_field(parent_path: &str, field: &str) -> String {
    if parent_path == "$" || parent_path.is_empty() {
        format!("arguments.{field}")
    } else {
        format!("{}.{}", schema_path_to_argument_path(parent_path), field)
    }
}

fn schema_path_leaf(path: &str) -> String {
    let trimmed = path.strip_prefix("$.").unwrap_or(path);
    trimmed
        .rsplit('.')
        .next()
        .filter(|leaf| !leaf.is_empty() && *leaf != "$")
        .unwrap_or(trimmed)
        .to_owned()
}

fn conditional_argument_guidance(entry: &CapabilityRegistryEntry) -> &'static str {
    if entry.contract_id.as_str() == "process::run" {
        " For sandbox_materialized process::run, include expectedOutputs: [{\"path\":\"<relative-output-path>\"}] and verify the returned materializedOutputs summary before guessing follow-up commands."
    } else {
        ""
    }
}
