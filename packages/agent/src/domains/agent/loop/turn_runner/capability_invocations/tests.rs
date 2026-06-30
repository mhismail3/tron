use super::*;
use crate::domains::agent::r#loop::types::CapabilityInvocationExecutionResult;
use crate::shared::protocol::content::CapabilityResultContent;
use crate::shared::protocol::model_capabilities::{CapabilityResult, CapabilityResultBody};
use serde_json::{Map, Value, json};

fn make_exec_result(content: CapabilityResultBody) -> CapabilityInvocationExecutionResult {
    make_exec_result_with_details(content, None)
}

fn make_exec_result_with_details(
    content: CapabilityResultBody,
    details: Option<Value>,
) -> CapabilityInvocationExecutionResult {
    CapabilityInvocationExecutionResult {
        result: CapabilityResult {
            content,
            details,
            is_error: None,
            stop_turn: None,
        },
        duration_ms: 100,
        stops_turn: false,
    }
}

#[test]
fn primitive_identity_canonicalizes_only_supported_operation_payloads() {
    let mut args = Map::new();
    args.insert("operationName".to_owned(), json!("file_read"));

    let identity = primitive_identity_json("execute", &args, None, None);

    assert!(identity.get("operationName").is_none());
    assert_eq!(identity["requestedOperationName"], "file_read");
}

#[test]
fn primitive_identity_exposes_valid_execute_operation() {
    let mut args = Map::new();
    args.insert("operation".to_owned(), json!("log_recent"));

    let identity = primitive_identity_json("execute", &args, None, None);

    assert_eq!(identity["operationName"], "log_recent");
    assert!(identity.get("requestedOperationName").is_none());
}

#[test]
fn result_identity_does_not_promote_unsupported_operation_details() {
    let base_identity = primitive_identity_json("execute", &Map::new(), None, None);
    let result = make_exec_result_with_details(
        CapabilityResultBody::Text("failed".into()),
        Some(json!({
            "operation": "file_read",
            "traceId": "trace_1"
        })),
    );

    let identity = result_identity_json("execute", base_identity, &result);

    assert!(identity.get("operationName").is_none());
    assert_eq!(identity["traceId"], "trace_1");
}

#[test]
fn extract_result_text_drops_images() {
    let exec = make_exec_result(CapabilityResultBody::Blocks(vec![
        CapabilityResultContent::text("captured"),
        CapabilityResultContent::image("base64data", "image/png"),
    ]));
    let text = extract_result_text(&exec);
    assert_eq!(text, "captured");
    assert!(!text.contains("base64"));
}
