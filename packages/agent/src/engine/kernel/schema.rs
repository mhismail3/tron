//! Minimal JSON schema validation for Phase 1 engine contracts.

use serde_json::Value;

use super::errors::{EngineError, Result};
use super::ids::FunctionId;

const SUPPORTED_TYPES: &[&str] = &[
    "array", "boolean", "integer", "null", "number", "object", "string",
];

/// Validate that a schema only uses the subset enforced by Phase 1.
pub fn validate_schema_definition(
    function_id: &FunctionId,
    direction: &'static str,
    schema: &Value,
) -> Result<()> {
    validate_schema_node(function_id, direction, schema, "$")
}

/// Validate a payload against the supported Phase 1 schema subset.
pub fn validate_payload(
    function_id: &FunctionId,
    direction: &'static str,
    schema: &Value,
    payload: &Value,
) -> Result<()> {
    validate_schema_definition(function_id, direction, schema)?;
    validate_payload_node(function_id, direction, schema, payload, "$")
}

fn validate_schema_node(
    function_id: &FunctionId,
    direction: &'static str,
    schema: &Value,
    path: &str,
) -> Result<()> {
    let Some(object) = schema.as_object() else {
        return Err(invalid_schema(
            function_id,
            direction,
            format!("{path} must be an object"),
        ));
    };

    if let Some(schema_type) = object.get("type") {
        validate_type_keyword(function_id, direction, schema_type, path)?;
    }

    if let Some(required) = object.get("required") {
        let Some(items) = required.as_array() else {
            return Err(invalid_schema(
                function_id,
                direction,
                format!("{path}.required must be an array"),
            ));
        };
        for item in items {
            if !item.is_string() {
                return Err(invalid_schema(
                    function_id,
                    direction,
                    format!("{path}.required entries must be strings"),
                ));
            }
        }
    }

    if let Some(additional) = object.get("additionalProperties") {
        if !additional.is_boolean() {
            return Err(invalid_schema(
                function_id,
                direction,
                format!("{path}.additionalProperties must be a boolean"),
            ));
        }
    }

    if let Some(properties) = object.get("properties") {
        let Some(properties) = properties.as_object() else {
            return Err(invalid_schema(
                function_id,
                direction,
                format!("{path}.properties must be an object"),
            ));
        };
        for (name, child) in properties {
            validate_schema_node(function_id, direction, child, &format!("{path}.{name}"))?;
        }
    }

    if let Some(items) = object.get("items") {
        validate_schema_node(function_id, direction, items, &format!("{path}.items"))?;
    }

    if let Some(max_items) = object.get("maxItems") {
        match max_items.as_u64() {
            Some(_) => {}
            None => {
                return Err(invalid_schema(
                    function_id,
                    direction,
                    format!("{path}.maxItems must be a non-negative integer"),
                ));
            }
        }
    }

    if let Some(min_length) = object.get("minLength") {
        match min_length.as_u64() {
            Some(_) => {}
            None => {
                return Err(invalid_schema(
                    function_id,
                    direction,
                    format!("{path}.minLength must be a non-negative integer"),
                ));
            }
        }
    }

    if let Some(enum_values) = object.get("enum") {
        if !enum_values.is_array() {
            return Err(invalid_schema(
                function_id,
                direction,
                format!("{path}.enum must be an array"),
            ));
        }
    }

    Ok(())
}

fn validate_type_keyword(
    function_id: &FunctionId,
    direction: &'static str,
    schema_type: &Value,
    path: &str,
) -> Result<()> {
    if let Some(schema_type) = schema_type.as_str() {
        if SUPPORTED_TYPES.contains(&schema_type) {
            return Ok(());
        }
        return Err(invalid_schema(
            function_id,
            direction,
            format!("{path}.type {schema_type:?} is not supported"),
        ));
    }

    let Some(types) = schema_type.as_array() else {
        return Err(invalid_schema(
            function_id,
            direction,
            format!("{path}.type must be a string or array"),
        ));
    };
    if types.is_empty() {
        return Err(invalid_schema(
            function_id,
            direction,
            format!("{path}.type must not be empty"),
        ));
    }
    for item in types {
        let Some(schema_type) = item.as_str() else {
            return Err(invalid_schema(
                function_id,
                direction,
                format!("{path}.type entries must be strings"),
            ));
        };
        if !SUPPORTED_TYPES.contains(&schema_type) {
            return Err(invalid_schema(
                function_id,
                direction,
                format!("{path}.type {schema_type:?} is not supported"),
            ));
        }
    }
    Ok(())
}

fn validate_payload_node(
    function_id: &FunctionId,
    direction: &'static str,
    schema: &Value,
    payload: &Value,
    path: &str,
) -> Result<()> {
    let object = schema.as_object().expect("schema definition was validated");
    if let Some(schema_type) = object.get("type") {
        if !matches_schema_type(schema_type, payload) {
            return Err(schema_violation(
                function_id,
                direction,
                path,
                format!("expected type {}", describe_type(schema_type)),
            ));
        }
    }

    if let Some(enum_values) = object.get("enum").and_then(Value::as_array) {
        if !enum_values.iter().any(|candidate| candidate == payload) {
            return Err(schema_violation(
                function_id,
                direction,
                path,
                "value is not in enum".to_owned(),
            ));
        }
    }

    if let Some(min_length) = object.get("minLength").and_then(Value::as_u64)
        && let Some(text) = payload.as_str()
        && text.chars().count() < min_length as usize
    {
        return Err(schema_violation(
            function_id,
            direction,
            path,
            format!("string shorter than minLength {min_length}"),
        ));
    }

    if let Some(required) = object.get("required").and_then(Value::as_array) {
        let Some(payload_object) = payload.as_object() else {
            return Err(schema_violation(
                function_id,
                direction,
                path,
                "required fields need an object".to_owned(),
            ));
        };
        for item in required {
            let field = item.as_str().expect("schema definition was validated");
            if !payload_object.contains_key(field) {
                return Err(schema_violation(
                    function_id,
                    direction,
                    &format!("{path}.{field}"),
                    "required field is missing".to_owned(),
                ));
            }
        }
    }

    if let Some(properties) = object.get("properties").and_then(Value::as_object) {
        let Some(payload_object) = payload.as_object() else {
            return Ok(());
        };
        if object.get("additionalProperties").and_then(Value::as_bool) == Some(false) {
            for key in payload_object.keys() {
                if !properties.contains_key(key) {
                    return Err(schema_violation(
                        function_id,
                        direction,
                        &format!("{path}.{key}"),
                        "additional property is not allowed".to_owned(),
                    ));
                }
            }
        }
        for (key, child_schema) in properties {
            if let Some(child_payload) = payload_object.get(key) {
                validate_payload_node(
                    function_id,
                    direction,
                    child_schema,
                    child_payload,
                    &format!("{path}.{key}"),
                )?;
            }
        }
    }

    if let Some(items) = payload.as_array() {
        if let Some(max_items) = object.get("maxItems").and_then(Value::as_u64) {
            if items.len() as u64 > max_items {
                return Err(schema_violation(
                    function_id,
                    direction,
                    path,
                    format!("array has more than {max_items} items"),
                ));
            }
        }
    }

    if let Some(items_schema) = object.get("items") {
        if let Some(items) = payload.as_array() {
            for (index, item) in items.iter().enumerate() {
                validate_payload_node(
                    function_id,
                    direction,
                    items_schema,
                    item,
                    &format!("{path}[{index}]"),
                )?;
            }
        }
    }

    Ok(())
}

fn matches_schema_type(schema_type: &Value, payload: &Value) -> bool {
    if let Some(schema_type) = schema_type.as_str() {
        return matches_single_type(schema_type, payload);
    }
    schema_type
        .as_array()
        .expect("schema definition was validated")
        .iter()
        .any(|item| {
            matches_single_type(
                item.as_str().expect("schema definition was validated"),
                payload,
            )
        })
}

fn matches_single_type(schema_type: &str, payload: &Value) -> bool {
    match schema_type {
        "array" => payload.is_array(),
        "boolean" => payload.is_boolean(),
        "integer" => payload.as_i64().is_some() || payload.as_u64().is_some(),
        "null" => payload.is_null(),
        "number" => payload.is_number(),
        "object" => payload.is_object(),
        "string" => payload.is_string(),
        _ => false,
    }
}

fn describe_type(schema_type: &Value) -> String {
    if let Some(schema_type) = schema_type.as_str() {
        return schema_type.to_owned();
    }
    let types = schema_type
        .as_array()
        .expect("schema definition was validated")
        .iter()
        .map(|item| item.as_str().expect("schema definition was validated"))
        .collect::<Vec<_>>();
    types.join("|")
}

fn invalid_schema(
    function_id: &FunctionId,
    direction: &'static str,
    message: String,
) -> EngineError {
    EngineError::InvalidSchema {
        function_id: function_id.to_string(),
        direction,
        message,
    }
}

fn schema_violation(
    function_id: &FunctionId,
    direction: &'static str,
    path: &str,
    message: String,
) -> EngineError {
    EngineError::SchemaViolation {
        function_id: function_id.to_string(),
        direction,
        path: path.to_owned(),
        message,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn function_id() -> FunctionId {
        FunctionId::new("test::schema").unwrap()
    }

    #[test]
    fn min_length_rejects_short_strings() {
        let schema = json!({
            "type": "object",
            "properties": {
                "command": {"type": "string", "minLength": 1}
            },
            "required": ["command"]
        });

        let err = validate_payload(&function_id(), "request", &schema, &json!({"command": ""}))
            .unwrap_err();

        assert!(err.to_string().contains("minLength 1"));
        validate_payload(
            &function_id(),
            "request",
            &schema,
            &json!({"command": "date"}),
        )
        .unwrap();
    }

    #[test]
    fn min_length_keyword_must_be_non_negative_integer() {
        let schema = json!({"type": "string", "minLength": "1"});
        let err = validate_schema_definition(&function_id(), "request", &schema).unwrap_err();
        assert!(
            err.to_string()
                .contains("minLength must be a non-negative integer")
        );
    }
}
