use super::*;
use crate::domains::agent::runner::types::CapabilityInvocationExecutionResult;
use crate::shared::content::CapabilityResultContent;
use crate::shared::model_capabilities::{CapabilityResult, CapabilityResultBody};

fn make_exec_result(content: CapabilityResultBody) -> CapabilityInvocationExecutionResult {
    CapabilityInvocationExecutionResult {
        invocation_id: "test".into(),
        result: CapabilityResult {
            content,
            details: None,
            is_error: None,
            stop_turn: None,
        },
        duration_ms: 100,
        blocked_by_hook: false,
        blocked_by_guardrail: false,
        is_interactive: false,
        stops_turn: false,
    }
}

fn make_exec_result_with_details(
    content: CapabilityResultBody,
    details: Value,
) -> CapabilityInvocationExecutionResult {
    CapabilityInvocationExecutionResult {
        result: CapabilityResult {
            details: Some(details),
            ..make_exec_result(content).result
        },
        ..make_exec_result(CapabilityResultBody::Text(String::new()))
    }
}

// ── extract_result_content tests ──

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
fn extract_result_content_image_only_blocks() {
    let exec = make_exec_result(CapabilityResultBody::Blocks(vec![
        CapabilityResultContent::image("imgdata", "image/jpeg"),
    ]));
    let content = extract_result_content(&exec);
    match content {
        CapabilityResultMessageContent::Blocks(blocks) => {
            assert_eq!(blocks.len(), 1);
            assert!(matches!(&blocks[0], CapabilityResultContent::Image { .. }));
        }
        CapabilityResultMessageContent::Text(_) => panic!("expected Blocks variant"),
    }
}

#[test]
fn extract_result_content_projects_execute_observation_for_model() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Text("Testing out a README here.\n".into()),
        json!({
            "status": "ok",
            "executeInvocationId": "execute-123",
            "functionId": "filesystem::read_file",
            "selectedImplementation": "first_party.filesystem.v1.read_file",
            "childInvocations": ["child-123"],
            "resourceRefs": [],
            "orchestration": {
                "status": "ok",
                "correctionsApplied": []
            }
        }),
    );

    let content = extract_result_content(&exec);

    let CapabilityResultMessageContent::Text(text) = content else {
        panic!("expected text projection");
    };
    assert!(text.starts_with("[execute result - exact target output or status text]\n"));
    let output_pos = text
        .find("Testing out a README here.\n")
        .expect("exact output should be visible");
    let observation_pos = text
        .find("[execute observation")
        .expect("metadata observation should be visible");
    assert!(output_pos < observation_pos);
    assert!(text.contains("[/execute result]"));
    assert!(text.contains("[execute observation"));
    assert!(text.contains("\"executeInvocationId\": \"execute-123\""));
    assert!(text.contains("\"selectedTarget\": \"filesystem::read_file\""));
    assert!(text.contains("\"child-123\""));
    assert!(text.contains("\"approval\": \"not_required\""));
}

#[test]
fn extract_result_content_projects_execute_guidance_for_model() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Text("process::run needs more input".into()),
        json!({
            "status": "needs_input",
            "functionId": "process::run",
            "resourceRefs": [],
            "guidance": {
                "kind": "provide_missing_arguments",
                "missingFields": ["command", "executionMode"],
                "missingArgumentPaths": ["arguments.command", "arguments.executionMode"]
            },
            "orchestration": {
                "status": "needs_input",
                "childInvocationIds": [],
                "correctionsApplied": []
            }
        }),
    );

    let content = extract_result_content(&exec);

    let CapabilityResultMessageContent::Text(text) = content else {
        panic!("expected text projection");
    };
    assert!(text.contains("\"guidance\""));
    assert!(text.contains("\"missingFields\""));
    assert!(text.contains("\"command\""));
    assert!(text.contains("\"executionMode\""));
    assert!(text.contains("\"missingArgumentPaths\""));
    assert!(text.contains("\"arguments.command\""));
    assert!(text.contains("\"arguments.executionMode\""));
}

#[test]
fn extract_result_content_projects_needs_capability_guidance_for_model() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Text(
            "No visible healthy capability matches the requested target.".into(),
        ),
        json!({
            "status": "needs_capability",
            "resourceRefs": [],
            "childInvocationIds": [],
            "approvalDecision": {
                "status": "not_required",
                "approvalRequired": false,
                "approvalCreated": false,
                "approvalExecuted": false,
                "approvalReplayed": false
            },
            "proposedCapabilityShape": {
                "contractId": "<namespace>::<function>",
                "argumentsSchema": {},
                "effect": "pure_read|idempotent_write|external_side_effect",
                "risk": "low|medium|high|critical"
            },
            "orchestration": {
                "status": "needs_capability",
                "childInvocationIds": [],
                "correctionsApplied": []
            }
        }),
    );

    let content = extract_result_content(&exec);

    let CapabilityResultMessageContent::Text(text) = content else {
        panic!("expected text projection");
    };
    assert!(text.contains("\"status\": \"needs_capability\""));
    assert!(text.contains("\"approvalDecision\""));
    assert!(text.contains("\"status\": \"not_required\""));
    assert!(text.contains("\"childInvocationIds\": []"));
    assert!(text.contains("\"proposedCapabilityShape\""));
    assert!(text.contains("\"contractId\": \"<namespace>::<function>\""));
}

#[test]
fn execute_observation_approval_summary_reads_structured_decision() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Text("Approval is pending.".into()),
        json!({
            "status": "approval_required",
            "orchestration": {"status": "approval_required"},
            "approvalDecision": {
                "status": "pending",
                "approvalRequired": true,
                "approvalCreated": true,
                "approvalExecuted": false,
                "approvalReplayed": false
            },
            "childInvocationIds": [],
            "resourceRefs": []
        }),
    );

    let content = extract_result_content(&exec);

    let CapabilityResultMessageContent::Text(text) = content else {
        panic!("expected text projection");
    };
    assert!(text.contains("\"approval\": \"pending\""));
    assert!(text.contains("\"approvalDecision\""));
    assert!(text.contains("\"status\": \"pending\""));
}

#[test]
fn execute_observation_projects_replay_idempotency_key_for_model() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Text("Approved command output.".into()),
        json!({
            "status": "ok",
            "functionId": "process::run",
            "selectedImplementation": "first_party.process.v1.run",
            "executeInvocationId": "execute-approved",
            "idempotencyKey": "approved-child-key",
            "approvalDecision": {
                "status": "executed",
                "approvalRequired": true,
                "approvalCreated": true,
                "approvalExecuted": true,
                "approvalReplayed": false,
                "childInvocationId": "child-approved",
                "childInvocationIds": ["child-approved"],
                "functionId": "process::run",
                "idempotencyKey": "approved-child-key"
            },
            "childInvocationIds": ["child-approved"],
            "resourceRefs": [],
            "orchestration": {
                "status": "ok",
                "childInvocationIds": ["child-approved"],
                "correctionsApplied": []
            }
        }),
    );

    let content = extract_result_content(&exec);

    let CapabilityResultMessageContent::Text(text) = content else {
        panic!("expected text projection");
    };
    assert!(text.contains("\"idempotencyKey\": \"approved-child-key\""));
    assert!(text.contains("\"replay\""));
    assert!(text.contains("[execute replay - use this exact top-level execute idempotencyKey]"));
    assert!(text.contains("idempotencyKey: approved-child-key"));
    assert!(text.contains("topLevelExecuteField: idempotencyKey"));
    assert!(text.contains("expectedChildInvocationCreated: false"));
    assert!(text.contains("\"topLevelExecuteField\": \"idempotencyKey\""));
    assert!(text.contains("\"reuseExactly\": true"));
    assert!(text.contains("\"expectedChildInvocationCreated\": false"));
}

#[test]
fn model_context_result_text_preserves_execute_observation_for_reconstruction() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Text("Approved command output.".into()),
        json!({
            "status": "ok",
            "functionId": "process::run",
            "idempotencyKey": "approved-child-key",
            "approvalDecision": {
                "status": "executed",
                "approvalRequired": true,
                "approvalCreated": true,
                "approvalExecuted": true,
                "approvalReplayed": false,
                "idempotencyKey": "approved-child-key"
            },
            "orchestration": {
                "status": "ok",
                "childInvocationIds": [],
                "correctionsApplied": []
            }
        }),
    );

    let display_text = extract_result_text(&exec);
    let model_context_text = extract_model_context_result_text(&exec);

    assert_eq!(display_text, "Approved command output.");
    assert!(model_context_text.contains("Approved command output."));
    assert!(model_context_text.contains("[execute observation - metadata for reasoning]"));
    assert!(model_context_text.contains("idempotencyKey: approved-child-key"));
}

#[test]
fn extract_result_content_projects_execute_observation_before_images() {
    let exec = make_exec_result_with_details(
        CapabilityResultBody::Blocks(vec![CapabilityResultContent::image("imgdata", "image/png")]),
        json!({
            "status": "ok",
            "functionId": "browser::screenshot",
            "childInvocations": ["child-image"],
            "orchestration": {"status": "ok"}
        }),
    );

    let content = extract_result_content(&exec);

    let CapabilityResultMessageContent::Blocks(blocks) = content else {
        panic!("expected block projection");
    };
    assert_eq!(blocks.len(), 2);
    assert!(
        matches!(&blocks[0], CapabilityResultContent::Text { text } if text.contains("child-image"))
    );
    assert!(matches!(&blocks[1], CapabilityResultContent::Image { .. }));
}

// ── extract_result_text regression tests ──

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
fn extract_result_text_joins_text_blocks() {
    let exec = make_exec_result(CapabilityResultBody::Blocks(vec![
        CapabilityResultContent::text("a"),
        CapabilityResultContent::text("b"),
    ]));
    assert_eq!(extract_result_text(&exec), "a\nb");
}

#[test]
fn extract_result_text_body_passthrough() {
    let exec = make_exec_result(CapabilityResultBody::Text("plain".into()));
    assert_eq!(extract_result_text(&exec), "plain");
}
