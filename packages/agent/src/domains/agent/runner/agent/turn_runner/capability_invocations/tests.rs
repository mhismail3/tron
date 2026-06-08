use super::*;
use crate::domains::agent::runner::types::CapabilityInvocationExecutionResult;
use crate::shared::protocol::content::CapabilityResultContent;
use crate::shared::protocol::model_capabilities::{CapabilityResult, CapabilityResultBody};

fn make_exec_result(content: CapabilityResultBody) -> CapabilityInvocationExecutionResult {
    CapabilityInvocationExecutionResult {
        result: CapabilityResult {
            content,
            details: None,
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
fn extract_result_text_drops_images() {
    let exec = make_exec_result(CapabilityResultBody::Blocks(vec![
        CapabilityResultContent::text("captured"),
        CapabilityResultContent::image("base64data", "image/png"),
    ]));
    let text = extract_result_text(&exec);
    assert_eq!(text, "captured");
    assert!(!text.contains("base64"));
}
