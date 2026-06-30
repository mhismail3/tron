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
fn extract_result_content_text_body_passthrough() {
    let exec = make_exec_result(CapabilityResultBody::Text("hello".into()));
    let content = extract_result_content(&exec);
    assert!(matches!(content, CapabilityResultMessageContent::Text(ref t) if t == "hello"));
}

#[test]
fn extract_result_content_text_blocks_flatten() {
    let exec = make_exec_result(CapabilityResultBody::Blocks(vec![
        CapabilityResultContent::text("line 1"),
        CapabilityResultContent::text("line 2"),
    ]));
    let content = extract_result_content(&exec);
    assert!(
        matches!(content, CapabilityResultMessageContent::Text(ref t) if t == "line 1\nline 2")
    );
}

#[test]
fn extract_result_content_mixed_blocks_preserve() {
    let exec = make_exec_result(CapabilityResultBody::Blocks(vec![
        CapabilityResultContent::text("screenshot taken"),
        CapabilityResultContent::image("base64data", "image/png"),
    ]));
    let content = extract_result_content(&exec);
    match content {
        CapabilityResultMessageContent::Blocks(blocks) => {
            assert_eq!(blocks.len(), 2);
            assert!(
                matches!(&blocks[0], CapabilityResultContent::Text { text } if text == "screenshot taken")
            );
            assert!(
                matches!(&blocks[1], CapabilityResultContent::Image { data, mime_type } if data == "base64data" && mime_type == "image/png")
            );
        }
        CapabilityResultMessageContent::Text(_) => panic!("expected Blocks variant"),
    }
}

#[test]
fn extract_model_context_result_text_matches_direct_text() {
    let exec = make_exec_result(CapabilityResultBody::Text("direct output".into()));
    assert_eq!(extract_result_text(&exec), "direct output");
    assert_eq!(extract_model_context_result_text(&exec), "direct output");
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

#[test]
fn extract_result_content_projects_catalog_ids_for_model_context() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Catalog search returned 1 visible functions.",
        )]),
        Some(json!({
            "primitiveOperation": "catalog_search",
            "status": "ok",
            "catalogDiscovery": {
                "summary": {"functions": {"visible": 1}},
                "functions": [{
                    "id": "logs::recent",
                    "description": "Recent logs",
                    "modelFacingInvocation": {
                        "tool": "capability::execute",
                        "operation": "log_recent",
                        "arguments": {"operation": "log_recent"},
                        "catalogInspectId": "logs::recent"
                    }
                }]
            }
        })),
    );

    let content = extract_result_content(&exec);

    let CapabilityResultMessageContent::Text(text) = content else {
        panic!("expected text result");
    };
    assert!(text.contains("modelContextEvidence"));
    assert!(text.contains("logs::recent"));
    assert!(text.contains("log_recent"));
}

#[test]
fn extract_result_content_projects_catalog_operation_truncation_metadata() {
    let operations = (0..25)
        .map(|index| json!(format!("operation_{index}")))
        .collect::<Vec<_>>();
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Catalog search returned 1 visible functions.",
        )]),
        Some(json!({
            "primitiveOperation": "catalog_search",
            "status": "ok",
            "catalogDiscovery": {
                "summary": {"functions": {"visible": 1}},
                "functions": [],
                "modelFacingGuidance": {
                    "catalogInspect": "Use functions[].id exactly.",
                    "capabilityExecute": "Use capability::execute.",
                    "supportedExecuteOperations": operations
                }
            }
        })),
    );

    let CapabilityResultMessageContent::Text(text) = extract_result_content(&exec) else {
        panic!("expected text result");
    };
    assert!(text.contains("\"total\": 25"));
    assert!(text.contains("\"returned\""));
    assert!(text.contains("\"truncated\": true"));
    assert!(text.contains("\"omitted\": 5"));
    assert!(text.contains("operation_19"));
    assert!(!text.contains("operation_20"));
}

#[test]
fn extract_result_content_projects_metadata_ids_without_raw_payload() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Procedural definition metadata recorded.",
        )]),
        Some(json!({
            "primitiveOperation": "procedural_definition_record",
            "status": "recorded",
            "procedural": {
                "proceduralRecordResourceId": "procedural_record:abc123",
                "proceduralRecordVersionId": "ver_abc123",
                "status": "draft",
                "summary": "Bounded metadata summary",
                "description": {
                    "title": "nested raw object must not be projected",
                    "rawPromptBody": "nested raw prompt must not be projected"
                },
                "rawPromptBody": "must not be projected",
                "authorityGrantId": "grant_secret",
                "activation": {
                    "performed": false,
                    "processStarted": false
                }
            }
        })),
    );

    let CapabilityResultMessageContent::Text(text) = extract_result_content(&exec) else {
        panic!("expected text result");
    };
    assert!(text.contains("modelContextEvidence"));
    assert!(text.contains("procedural_record:abc123"));
    assert!(text.contains("ver_abc123"));
    assert!(text.contains("Bounded metadata summary"));
    assert!(!text.contains("must not be projected"));
    assert!(!text.contains("nested raw object"));
    assert!(!text.contains("grant_secret"));
    assert!(!text.contains("authorityGrantId"));
}

#[test]
fn extract_result_content_projects_schema_error_code_and_path() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "domain server_capability failed",
        )]),
        Some(json!({
            "failure": {
                "code": "ENGINE_SCHEMA_VIOLATION",
                "category": "invalid_request",
                "message": "expected type string at /Users/example/Workspace/tron/secret.txt",
                "origin": "engine",
                "retryable": false,
                "recoverable": true,
                "details": {
                    "functionId": "resource::payload",
                    "path": "$.baseContentHash",
                    "direction": "resource_payload",
                    "rawCommand": "cat secret.txt"
                }
            },
            "modelPrimitiveName": "execute",
            "providerInvocationId": "call_123"
        })),
    );

    let CapabilityResultMessageContent::Text(text) = extract_result_content(&exec) else {
        panic!("expected text result");
    };
    assert!(text.contains("ENGINE_SCHEMA_VIOLATION"));
    assert!(text.contains("$.baseContentHash"));
    assert!(text.contains("resource::payload"));
    assert!(text.contains("[redacted-path]"));
    assert!(!text.contains("/Users/example"));
    assert!(!text.contains("cat secret.txt"));
}

#[test]
fn extract_result_content_projects_filesystem_resource_refs_without_diff_or_content() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "filesystem_write preview: new-note.txt",
        )]),
        Some(json!({
            "primitiveOperation": "filesystem_write",
            "status": "preview",
            "filesystem": {
                "path": {"root": "working_directory", "relativePath": "new-note.txt"},
                "diff": "--- raw diff must stay out",
                "after": {"preview": "raw file content must stay out"},
                "resourceRefs": [{
                    "kind": "patch_proposal",
                    "resourceId": "patch_proposal:provider-call",
                    "versionId": "ver_patch",
                    "lifecycle": "proposed"
                }]
            }
        })),
    );

    let CapabilityResultMessageContent::Text(text) = extract_result_content(&exec) else {
        panic!("expected text result");
    };
    assert!(text.contains("patch_proposal:provider-call"));
    assert!(text.contains("ver_patch"));
    assert!(!text.contains("--- raw diff"));
    assert!(!text.contains("raw file content"));
}

#[test]
fn extract_result_content_projects_trace_metadata_ids() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text("Trace records: 1.")]),
        Some(json!({
            "primitiveOperation": "trace_list",
            "status": "ok",
            "records": [{
                "id": "019f-trace-record",
                "timestamp": "2026-06-30T07:30:00Z",
                "metadata": {
                    "dev.tron": {
                        "traceId": "trace_nested",
                        "invocationId": "inv_nested",
                        "providerInvocationId": "provider_nested",
                        "operation": "procedural_definition_record",
                        "error": {
                            "code": "ENGINE_SCHEMA_VIOLATION",
                            "message": "failed at /Users/example/secret",
                            "details": {
                                "path": "$.field",
                                "rawCommand": "cat hidden"
                            }
                        },
                        "authority": {
                            "authorityGrantId": "grant_must_not_project",
                            "scopes": ["capability.execute"]
                        }
                    }
                }
            }]
        })),
    );

    let CapabilityResultMessageContent::Text(text) = extract_result_content(&exec) else {
        panic!("expected text result");
    };
    assert!(text.contains("019f-trace-record"));
    assert!(text.contains("trace_nested"));
    assert!(text.contains("inv_nested"));
    assert!(text.contains("provider_nested"));
    assert!(text.contains("procedural_definition_record"));
    assert!(text.contains("ENGINE_SCHEMA_VIOLATION"));
    assert!(text.contains("$.field"));
    assert!(text.contains("[redacted-path]"));
    assert!(!text.contains("grant_must_not_project"));
    assert!(!text.contains("authorityGrantId"));
    assert!(!text.contains("/Users/example"));
    assert!(!text.contains("cat hidden"));
}

#[test]
fn extract_result_content_projects_recent_logs_for_model_context() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text("Log entries: 1.")]),
        Some(json!({
            "primitiveOperation": "log_recent",
            "status": "ok",
            "entries": [{
                "id": 42,
                "timestamp": "2026-06-29T10:00:00Z",
                "level": "warn",
                "component": "ios.events",
                "message": "Unknown event type: capability.invocation.arguments_delta",
                "sessionId": "sess_1",
                "traceId": "trace_1"
            }]
        })),
    );

    let content = extract_result_content(&exec);

    let CapabilityResultMessageContent::Text(text) = content else {
        panic!("expected text result");
    };
    assert!(text.contains("modelContextEvidence"));
    assert!(text.contains("capability.invocation.arguments_delta"));
    assert!(text.contains("sess_1"));
}

#[test]
fn extract_result_content_redacts_log_evidence_for_model_context() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text("Log entries: 1.")]),
        Some(json!({
            "primitiveOperation": "log_recent",
            "status": "ok",
            "entries": [{
                "id": 42,
                "timestamp": "2026-06-29T10:00:00Z",
                "level": "warn",
                "component": "diagnostics",
                "message": "failed at /Users/example/Workspace/tron with ghp_xxxxxxxxxxxxxxxxxxxx123456",
                "sessionId": "sess_1",
                "traceId": "trace_1"
            }]
        })),
    );

    let content = extract_result_content(&exec);

    let CapabilityResultMessageContent::Text(text) = content else {
        panic!("expected text result");
    };
    assert!(text.contains("[redacted-path]"));
    assert!(text.contains("gh*_****"));
    assert!(!text.contains("/Users/example"));
    assert!(!text.contains("ghp_xxxxxxxxxxxxxxxxxxxx123456"));
}

#[test]
fn extract_result_content_does_not_project_unlisted_raw_details() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::text("Command completed.")]),
        Some(json!({
            "primitiveOperation": "process_run",
            "status": "ok",
            "stdout": "raw diagnostic payload that must stay out of model-context projection"
        })),
    );

    let content = extract_result_content(&exec);

    let CapabilityResultMessageContent::Text(text) = content else {
        panic!("expected text result");
    };
    assert_eq!(text, "Command completed.");
    assert!(!text.contains("raw diagnostic payload"));
}
