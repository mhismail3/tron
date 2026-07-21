//! Minimal enforced JSON Schema subset for engine contracts.

use serde_json::Value;

use super::errors::{EngineError, Result};
use super::ids::FunctionId;

const SUPPORTED_TYPES: &[&str] = &[
    "array", "boolean", "integer", "null", "number", "object", "string",
];

/// Validate that a schema only uses the enforced subset.
pub fn validate_schema_definition(
    function_id: &FunctionId,
    direction: &'static str,
    schema: &Value,
) -> Result<()> {
    validate_schema_node(function_id, direction, schema, "$")
}

/// Validate a payload against the enforced schema subset.
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

    if let (Some(constant), Some(schema_type)) = (object.get("const"), object.get("type"))
        && !matches_schema_type(schema_type, constant)
    {
        return Err(invalid_schema(
            function_id,
            direction,
            format!("{path}.const does not match the declared type"),
        ));
    }

    let minimum = validate_numeric_keyword(function_id, direction, object, path, "minimum")?;
    let maximum = validate_numeric_keyword(function_id, direction, object, path, "maximum")?;
    if let (Some(minimum), Some(maximum)) = (minimum, maximum)
        && minimum > maximum
    {
        return Err(invalid_schema(
            function_id,
            direction,
            format!("{path}.minimum must not exceed maximum"),
        ));
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
        if additional.is_object() {
            validate_schema_node(
                function_id,
                direction,
                additional,
                &format!("{path}.additionalProperties"),
            )?;
        } else if !additional.is_boolean() {
            return Err(invalid_schema(
                function_id,
                direction,
                format!("{path}.additionalProperties must be a boolean or schema"),
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

    for keyword in ["allOf", "anyOf", "oneOf"] {
        if let Some(branches) = object.get(keyword) {
            let Some(branches) = branches.as_array() else {
                return Err(invalid_schema(
                    function_id,
                    direction,
                    format!("{path}.{keyword} must be an array"),
                ));
            };
            if branches.is_empty() {
                return Err(invalid_schema(
                    function_id,
                    direction,
                    format!("{path}.{keyword} must not be empty"),
                ));
            }
            for (index, branch) in branches.iter().enumerate() {
                validate_schema_node(
                    function_id,
                    direction,
                    branch,
                    &format!("{path}.{keyword}[{index}]"),
                )?;
            }
        }
    }
    if let Some(branch) = object.get("not") {
        validate_schema_node(function_id, direction, branch, &format!("{path}.not"))?;
    }
    if let Some(condition) = object.get("if") {
        validate_schema_node(function_id, direction, condition, &format!("{path}.if"))?;
        for keyword in ["then", "else"] {
            if let Some(branch) = object.get(keyword) {
                validate_schema_node(function_id, direction, branch, &format!("{path}.{keyword}"))?;
            }
        }
    } else if object.contains_key("then") || object.contains_key("else") {
        return Err(invalid_schema(
            function_id,
            direction,
            format!("{path}.then/else requires an if schema"),
        ));
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
    if let Some(min_items) = object.get("minItems") {
        match min_items.as_u64() {
            Some(_) => {}
            None => {
                return Err(invalid_schema(
                    function_id,
                    direction,
                    format!("{path}.minItems must be a non-negative integer"),
                ));
            }
        }
    }
    if let (Some(min_items), Some(max_items)) = (
        object.get("minItems").and_then(Value::as_u64),
        object.get("maxItems").and_then(Value::as_u64),
    ) && min_items > max_items
    {
        return Err(invalid_schema(
            function_id,
            direction,
            format!("{path}.minItems must not exceed maxItems"),
        ));
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

fn validate_numeric_keyword(
    function_id: &FunctionId,
    direction: &'static str,
    object: &serde_json::Map<String, Value>,
    path: &str,
    keyword: &str,
) -> Result<Option<f64>> {
    let Some(value) = object.get(keyword) else {
        return Ok(None);
    };
    value.as_f64().map(Some).ok_or_else(|| {
        invalid_schema(
            function_id,
            direction,
            format!("{path}.{keyword} must be a number"),
        )
    })
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
    if let Some(constant) = object.get("const")
        && constant != payload
    {
        return Err(schema_violation(
            function_id,
            direction,
            path,
            "value does not match const".to_owned(),
        ));
    }
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

    if let Some(branches) = object.get("allOf").and_then(Value::as_array) {
        for branch in branches {
            validate_payload_node(function_id, direction, branch, payload, path)?;
        }
    }
    if let Some(branches) = object.get("anyOf").and_then(Value::as_array)
        && !branches.iter().any(|branch| {
            validate_payload_node(function_id, direction, branch, payload, path).is_ok()
        })
    {
        return Err(schema_violation(
            function_id,
            direction,
            path,
            "value does not match any anyOf branch".to_owned(),
        ));
    }
    if let Some(branches) = object.get("oneOf").and_then(Value::as_array) {
        let matches = branches
            .iter()
            .filter(|branch| {
                validate_payload_node(function_id, direction, branch, payload, path).is_ok()
            })
            .count();
        if matches != 1 {
            return Err(schema_violation(
                function_id,
                direction,
                path,
                format!("value matches {matches} oneOf branches; expected exactly one"),
            ));
        }
    }
    if let Some(branch) = object.get("not")
        && validate_payload_node(function_id, direction, branch, payload, path).is_ok()
    {
        return Err(schema_violation(
            function_id,
            direction,
            path,
            "value matches forbidden not schema".to_owned(),
        ));
    }
    if let Some(condition) = object.get("if") {
        let branch =
            if validate_payload_node(function_id, direction, condition, payload, path).is_ok() {
                object.get("then")
            } else {
                object.get("else")
            };
        if let Some(branch) = branch {
            validate_payload_node(function_id, direction, branch, payload, path)?;
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

    if let Some(number) = payload.as_f64() {
        if let Some(minimum) = object.get("minimum").and_then(Value::as_f64)
            && number < minimum
        {
            return Err(schema_violation(
                function_id,
                direction,
                path,
                format!("number is below minimum {minimum}"),
            ));
        }
        if let Some(maximum) = object.get("maximum").and_then(Value::as_f64)
            && number > maximum
        {
            return Err(schema_violation(
                function_id,
                direction,
                path,
                format!("number exceeds maximum {maximum}"),
            ));
        }
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

    if let Some(payload_object) = payload.as_object() {
        let properties = object.get("properties").and_then(Value::as_object);
        for (key, value) in payload_object {
            if properties.is_some_and(|properties| properties.contains_key(key)) {
                continue;
            }
            match object.get("additionalProperties") {
                Some(Value::Bool(false)) => {
                    return Err(schema_violation(
                        function_id,
                        direction,
                        &format!("{path}.{key}"),
                        "additional property is not allowed".to_owned(),
                    ));
                }
                Some(additional @ Value::Object(_)) => validate_payload_node(
                    function_id,
                    direction,
                    additional,
                    value,
                    &format!("{path}.{key}"),
                )?,
                _ => {}
            }
        }
    }

    if let Some(properties) = object.get("properties").and_then(Value::as_object) {
        let Some(payload_object) = payload.as_object() else {
            return Ok(());
        };
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
        if let Some(min_items) = object.get("minItems").and_then(Value::as_u64)
            && (items.len() as u64) < min_items
        {
            return Err(schema_violation(
                function_id,
                direction,
                path,
                format!("array has fewer than {min_items} items"),
            ));
        }
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
    fn schema_valued_additional_properties_are_enforced() {
        let schema = json!({
            "type":"object",
            "properties":{
                "files":{
                    "type":"object",
                    "additionalProperties":{"type":"string"}
                }
            },
            "required":["files"],
            "additionalProperties":false
        });

        validate_payload(
            &function_id(),
            "request",
            &schema,
            &json!({"files":{"worker.py":"print('ok')"}}),
        )
        .unwrap();
        let error = validate_payload(
            &function_id(),
            "request",
            &schema,
            &json!({"files":{"worker.py":17}}),
        )
        .unwrap_err();
        assert!(error.to_string().contains("$.files.worker.py"));
        assert!(error.to_string().contains("type string"));
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

    #[test]
    fn const_and_numeric_bounds_are_enforced() {
        let schema = json!({
            "type": "object",
            "additionalProperties": false,
            "required": ["operation", "limit"],
            "properties": {
                "operation": {"type": "string", "const": "lookup"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 500}
            }
        });

        let wrong_operation = validate_payload(
            &function_id(),
            "request",
            &schema,
            &json!({"operation": "inspect", "limit": 10}),
        )
        .unwrap_err();
        assert!(wrong_operation.to_string().contains("does not match const"));

        let below = validate_payload(
            &function_id(),
            "request",
            &schema,
            &json!({"operation": "lookup", "limit": 0}),
        )
        .unwrap_err();
        assert!(below.to_string().contains("below minimum 1"));

        let above = validate_payload(
            &function_id(),
            "request",
            &schema,
            &json!({"operation": "lookup", "limit": 501}),
        )
        .unwrap_err();
        assert!(above.to_string().contains("exceeds maximum 500"));

        validate_payload(
            &function_id(),
            "request",
            &schema,
            &json!({"operation": "lookup", "limit": 500}),
        )
        .unwrap();
    }

    #[test]
    fn numeric_bounds_must_be_numbers_and_ordered() {
        let non_numeric = json!({"type": "integer", "minimum": "1"});
        let error =
            validate_schema_definition(&function_id(), "request", &non_numeric).unwrap_err();
        assert!(error.to_string().contains("minimum must be a number"));

        let reversed = json!({"type": "integer", "minimum": 10, "maximum": 1});
        let error = validate_schema_definition(&function_id(), "request", &reversed).unwrap_err();
        assert!(
            error
                .to_string()
                .contains("minimum must not exceed maximum")
        );
    }

    #[test]
    fn composition_keywords_are_validated_and_enforced() {
        let schema = json!({
            "type": "object",
            "allOf": [{
                "anyOf": [
                    {"required": ["query"]},
                    {"required": ["glob"]}
                ]
            }],
            "oneOf": [
                {"required": ["operation"]},
                {"required": ["kind"]}
            ],
            "not": {"required": ["forbidden"]}
        });

        validate_payload(
            &function_id(),
            "request",
            &schema,
            &json!({"operation": "find", "query": "contract"}),
        )
        .unwrap();
        assert!(
            validate_payload(
                &function_id(),
                "request",
                &schema,
                &json!({"operation": "find"}),
            )
            .unwrap_err()
            .to_string()
            .contains("anyOf")
        );
        assert!(
            validate_payload(
                &function_id(),
                "request",
                &schema,
                &json!({"operation": "find", "kind": "query", "query": "contract"}),
            )
            .unwrap_err()
            .to_string()
            .contains("oneOf")
        );
        assert!(
            validate_payload(
                &function_id(),
                "request",
                &schema,
                &json!({"operation": "find", "query": "contract", "forbidden": true}),
            )
            .unwrap_err()
            .to_string()
            .contains("forbidden not schema")
        );
    }

    #[test]
    fn composition_keywords_reject_invalid_definitions() {
        for schema in [
            json!({"anyOf": {}}),
            json!({"allOf": []}),
            json!({"oneOf": ["not-a-schema"]}),
            json!({"not": "not-a-schema"}),
            json!({"then": {"required": ["value"]}}),
            json!({"type": "array", "minItems": 2, "maxItems": 1}),
        ] {
            assert!(validate_schema_definition(&function_id(), "request", &schema).is_err());
        }
    }

    #[test]
    fn conditional_and_min_items_keywords_are_enforced() {
        let schema = json!({
            "type": "object",
            "properties": {
                "mode": {"type": "string"},
                "items": {"type": "array", "minItems": 1}
            },
            "if": {
                "required": ["mode"],
                "properties": {"mode": {"const": "bounded"}}
            },
            "then": {"required": ["items"]}
        });
        validate_payload(&function_id(), "request", &schema, &json!({"mode": "free"})).unwrap();
        assert!(
            validate_payload(
                &function_id(),
                "request",
                &schema,
                &json!({"mode": "bounded"}),
            )
            .is_err()
        );
        assert!(
            validate_payload(
                &function_id(),
                "request",
                &schema,
                &json!({"mode": "bounded", "items": []}),
            )
            .unwrap_err()
            .to_string()
            .contains("fewer than 1")
        );
        validate_payload(
            &function_id(),
            "request",
            &schema,
            &json!({"mode": "bounded", "items": ["ready"]}),
        )
        .unwrap();
    }
}
