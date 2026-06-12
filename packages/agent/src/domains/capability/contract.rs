//! Capability contracts owned by the capability domain worker.
//!
//! This worker is the model-facing harness collapse point: providers see one
//! `execute` primitive that can observe, touch agent-owned state, read/write the
//! workspace, and run bounded local commands.

use serde_json::json;

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{
    EffectClass, IdempotencyContract, Result as EngineResult, RiskLevel, VisibilityScope,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["capability.runtime"];

pub(crate) const EXECUTE_FUNCTION_ID: &str = "capability::execute";

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            EXECUTE_FUNCTION_ID,
            "capability",
            EffectClass::DelegatedInvocation,
            RiskLevel::Medium,
            Some("capability.execute"),
        )
        .visibility(VisibilityScope::System)
        .domain_module("capability")
        .request_schema(execute_request_schema())
        .response_schema(primitive_result_schema())
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .build()?,
    ])
}

pub(crate) fn model_metadata(function_id: &str) -> serde_json::Value {
    match function_id {
        EXECUTE_FUNCTION_ID => json!({
            "capabilityPrimitive": true,
            "modelPrimitiveName": "execute",
            "capabilityOrder": 10,
            "capabilityExecutionMode": {"kind": "serialized", "group": "capability-execute"},
            "capabilitySchema": {
                "name": "execute",
                "description": concat!(
                    "Primitive host operation for the bare Tron loop. ",
                    "Use execute to observe, read/write agent-owned state, read/write files under the current working directory, run a bounded local command, and inspect agent trace/log records. ",
                    "It can also export the current session replay manifest without side effects. ",
                    "Choose one operation per call. Keep mutation reasons and idempotency keys in this payload when they matter for evidence."
                ),
                "parameters": execute_model_request_schema()
            }
        }),
        _ => serde_json::Value::Null,
    }
}

fn execute_request_schema() -> serde_json::Value {
    execute_model_request_schema()
}

fn execute_model_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["operation"],
        "properties": {
            "operation": {
                "type": "string",
                "description": "One primitive operation: observe, state_get, state_set, state_list, file_read, file_write, process_run, trace_list, trace_get, log_recent, or replay_manifest."
            },
            "input": {"type": "string", "description": "Text to record for observe."},
            "scope": {"type": "string", "description": "State scope: session, workspace, or system."},
            "namespace": {"type": "string", "description": "Agent-owned state namespace."},
            "key": {"type": "string", "description": "Agent-owned state key."},
            "value": {"description": "JSON value for state_set."},
            "path": {"type": "string", "description": "Relative file path under the current working directory."},
            "content": {"type": "string", "description": "UTF-8 file content for file_write."},
            "command": {"type": "string", "description": "Shell command for process_run."},
            "traceId": {"type": "string", "description": "Optional trace id filter for trace_list and log_recent."},
            "traceRecordId": {"type": "string", "description": "Trace record id for trace_get."},
            "limit": {"type": "integer", "minimum": 1, "maximum": 500},
            "timeoutMs": {"type": "integer", "minimum": 1, "maximum": 120000},
            "maxOutputBytes": {"type": "integer", "minimum": 1, "maximum": 200000},
            "idempotencyKey": {"type": "string", "description": "Stable caller key for writes or command side effects."},
            "reason": {"type": "string", "description": "Short evidence reason for the operation."}
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_execute_is_registered_and_model_facing() {
        let capabilities = capabilities().expect("contracts");
        let ids = capabilities
            .iter()
            .map(|spec| spec.function_id.as_str())
            .collect::<Vec<_>>();
        assert_eq!(ids, [EXECUTE_FUNCTION_ID]);
        assert!(!model_metadata(EXECUTE_FUNCTION_ID).is_null());
        assert!(model_metadata("not_execute").is_null());
    }

    #[test]
    fn execute_schema_exposes_primitive_operations_not_catalog_targets() {
        let metadata = model_metadata(EXECUTE_FUNCTION_ID);
        let description = metadata["capabilitySchema"]["description"]
            .as_str()
            .expect("execute description");
        assert!(description.contains("Primitive host operation"));
        assert!(description.contains("Choose one operation per call"));

        let schema = execute_model_request_schema();
        assert_eq!(schema["required"], json!(["operation"]));
        assert_eq!(
            schema["additionalProperties"],
            json!(false),
            "primitive execute should accept only its direct request shape"
        );
        assert_eq!(schema["properties"]["operation"]["type"], json!("string"));
        assert!(schema["properties"].get("target").is_none());
        assert!(schema["properties"].get("contractId").is_none());
        assert!(schema["properties"].get("functionId").is_none());
        assert!(schema["properties"].get("constraints").is_none());
    }

    #[test]
    fn execute_model_schema_stays_provider_portable() {
        let metadata = model_metadata(EXECUTE_FUNCTION_ID);
        let schema = &metadata["capabilitySchema"]["parameters"];
        assert_eq!(schema["type"], json!("object"));
        assert_provider_schema_has_no_unsupported_keywords(schema, "$");
    }

    fn assert_provider_schema_has_no_unsupported_keywords(value: &serde_json::Value, path: &str) {
        match value {
            serde_json::Value::Object(object) => {
                for key in ["oneOf", "anyOf", "allOf", "enum", "not"] {
                    assert!(
                        !object.contains_key(key),
                        "provider schema contains unsupported {key} at {path}"
                    );
                }
                for (key, child) in object {
                    assert_provider_schema_has_no_unsupported_keywords(
                        child,
                        &format!("{path}.{key}"),
                    );
                }
            }
            serde_json::Value::Array(values) => {
                for (index, child) in values.iter().enumerate() {
                    assert_provider_schema_has_no_unsupported_keywords(
                        child,
                        &format!("{path}[{index}]"),
                    );
                }
            }
            _ => {}
        }
    }
}

fn primitive_result_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": true,
        "properties": {
            "content": {},
            "details": {},
            "isError": {"type": "boolean"},
            "stopTurn": {"type": "boolean"}
        },
        "required": ["content"]
    })
}
