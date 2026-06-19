use super::*;
use crate::shared::observability::test_utils::{capture_global_logs, capture_logs};
use tracing::Level;

#[test]
fn build_message_text_only() {
    let msg = build_message("hello", "", None, &[]);
    assert_eq!(msg.content.len(), 1);
    assert!(matches!(&msg.content[0], AssistantContent::Text { text, .. } if text == "hello"));
}

#[test]
fn build_message_thinking_and_text() {
    let msg = build_message("answer", "thinking", None, &[]);
    assert_eq!(msg.content.len(), 2);
    assert!(matches!(&msg.content[0], AssistantContent::Thinking { .. }));
    assert!(matches!(&msg.content[1], AssistantContent::Text { .. }));
}

#[test]
fn build_message_empty() {
    let msg = build_message("", "", None, &[]);
    assert!(msg.content.is_empty());
}

#[test]
fn build_message_trims_trailing_whitespace() {
    let msg = build_message("Hello world\n\n\n", "", None, &[]);
    assert_eq!(msg.content.len(), 1);
    if let AssistantContent::Text { text, .. } = &msg.content[0] {
        assert_eq!(text, "Hello world");
    } else {
        panic!("Expected text content");
    }
}

#[test]
fn build_message_preserves_leading_whitespace() {
    let msg = build_message("  indented\n\n", "", None, &[]);
    if let AssistantContent::Text { text, .. } = &msg.content[0] {
        assert_eq!(text, "  indented");
    } else {
        panic!("Expected text content");
    }
}

#[test]
fn build_message_only_whitespace_produces_empty() {
    let msg = build_message("\n\n  \n", "", None, &[]);
    assert!(msg.content.is_empty());
}

#[test]
fn build_message_preserves_internal_newlines() {
    let msg = build_message("line1\n\nline2\n\n", "", None, &[]);
    if let AssistantContent::Text { text, .. } = &msg.content[0] {
        assert_eq!(text, "line1\n\nline2");
    } else {
        panic!("Expected text content");
    }
}

#[tokio::test]
async fn duplicate_capability_invocations_deduped_by_id() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        // First occurrence — empty/malformed args
        yield Ok(StreamEvent::CapabilityInvocationDraftStart { invocation_id: "tc-dup".into(), name: "execute".into() });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta { invocation_id: "tc-dup".into(), arguments_delta: "{}".into() });
        // Second occurrence — valid args (replaces via CapabilityInvocationDraftEnd dedup)
        yield Ok(StreamEvent::CapabilityInvocationDraftStart { invocation_id: "tc-dup".into(), name: "execute".into() });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-dup", "execute", {
                let mut m = serde_json::Map::new();
                let _ = m.insert("command".into(), serde_json::json!("ls"));
                m
            }),
        });
        yield Ok(StreamEvent::Done {
            message: AssistantMessage { content: vec![], token_usage: None },
            stop_reason: "capability_invocation".into(),
        });
    };

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    let result = process_stream(
        Box::pin(s),
        "s1",
        &emitter,
        &cancel,
        &no_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    assert_eq!(
        result.capability_invocations.len(),
        1,
        "duplicate capability invocations should be deduped"
    );
    assert_eq!(result.capability_invocations[0].id, "tc-dup");
    assert_eq!(
        result.capability_invocations[0].arguments["command"],
        serde_json::json!("ls")
    );
}

// -- finalize_capability_invocation unit tests --

#[test]
fn finalize_capability_invocation_with_valid_json() {
    let mut capability_invocations = Vec::new();
    let mut id = Some("tc-1".to_string());
    let mut name = Some("execute".to_string());
    let mut args = r#"{"command":"ls"}"#.to_string();

    finalize_capability_invocation(&mut capability_invocations, &mut id, &mut name, &mut args);

    assert_eq!(capability_invocations.len(), 1);
    assert_eq!(capability_invocations[0].name, "execute");
    assert_eq!(capability_invocations[0].id, "tc-1");
    assert_eq!(
        capability_invocations[0].arguments["command"],
        serde_json::json!("ls")
    );
}

#[test]
fn finalize_capability_invocation_with_malformed_json() {
    let mut capability_invocations = Vec::new();
    let mut id = Some("tc-2".to_string());
    let mut name = Some("inspect".to_string());
    let mut args = "{ not valid".to_string();

    finalize_capability_invocation(&mut capability_invocations, &mut id, &mut name, &mut args);

    assert_eq!(capability_invocations.len(), 1);
    assert_eq!(capability_invocations[0].name, "inspect");
    assert_eq!(capability_invocations[0].id, "tc-2");
    assert!(capability_invocations[0].arguments.is_empty());
}

#[test]
fn finalize_capability_invocation_with_empty_string() {
    let mut capability_invocations = Vec::new();
    let mut id = Some("tc-3".to_string());
    let mut name = Some("search".to_string());
    let mut args = String::new();

    finalize_capability_invocation(&mut capability_invocations, &mut id, &mut name, &mut args);

    assert!(
        capability_invocations.is_empty(),
        "empty partial arguments are ignored because providers may send the final capability-invocation arguments on the done item"
    );
    assert!(args.is_empty());
}

#[test]
fn build_message_preserves_thinking_signature() {
    let msg = build_message("answer", "thinking", Some("sig-abc"), &[]);
    assert_eq!(msg.content.len(), 2);
    if let AssistantContent::Thinking { signature, .. } = &msg.content[0] {
        assert_eq!(signature.as_deref(), Some("sig-abc"));
    } else {
        panic!("Expected thinking content");
    }
}

#[test]
fn build_message_thinking_signature_none_when_absent() {
    let msg = build_message("answer", "thinking", None, &[]);
    if let AssistantContent::Thinking { signature, .. } = &msg.content[0] {
        assert!(signature.is_none());
    } else {
        panic!("Expected thinking content");
    }
}

#[tokio::test]
async fn abort_mid_thinking_preserves_signature() {
    let cancel = CancellationToken::new();
    let cancel_clone = cancel.clone();

    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::ThinkingStart);
        yield Ok(StreamEvent::ThinkingDelta { delta: "deep thought".into() });
        yield Ok(StreamEvent::ThinkingEnd { thinking: "deep thought".into(), signature: Some("sig-xyz".into()) });
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: "partial".into() });
        cancel_clone.cancel();
        yield Ok(StreamEvent::TextDelta { delta: " more".into() });
        yield Ok(StreamEvent::Done {
            message: AssistantMessage { content: vec![], token_usage: None },
            stop_reason: "end_turn".into(),
        });
    };

    let emitter = make_emitter();
    let result = process_stream(
        Box::pin(s),
        "s1",
        &emitter,
        &cancel,
        &no_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    assert!(result.interrupted);
    // The thinking signature must be preserved on the message
    let thinking_block = result
        .message
        .content
        .iter()
        .find(|c| matches!(c, AssistantContent::Thinking { .. }));
    assert!(thinking_block.is_some(), "should have thinking block");
    if let AssistantContent::Thinking { signature, .. } = thinking_block.unwrap() {
        assert_eq!(signature.as_deref(), Some("sig-xyz"));
    }
}

#[tokio::test(flavor = "current_thread")]
async fn stream_trace_logs_metadata_without_content() {
    let logs = capture_global_logs();
    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    let secret_text = "secret-body-that-must-not-be-logged";

    let result = process_stream(
        text_stream(secret_text),
        "s1",
        &emitter,
        &cancel,
        &no_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    assert_eq!(result.stop_reason, "end_turn");
    let events = logs.events();
    assert!(
        events.iter().any(|event| {
            event.level == Level::TRACE
                && has_field(event, "agent_event", "stream_text_delta")
                && has_field(event, "session_id", "s1")
                && has_field(event, "delta_len", &secret_text.len().to_string())
        }),
        "missing metadata-only stream_text_delta trace event: {events:#?}"
    );
    assert!(
        events.iter().all(|event| {
            !event.message.contains(secret_text)
                && event
                    .fields
                    .iter()
                    .all(|(_, value)| !value.contains(secret_text))
        }),
        "stream trace logs must not include streamed text content: {events:#?}"
    );
}

#[test]
fn malformed_capability_arguments_log_length_not_preview() {
    let (logs, _guard) = capture_logs();
    let mut capability_invocations = Vec::new();
    let mut id = Some("tc-sensitive".to_string());
    let mut name = Some("execute".to_string());
    let secret_args = r#"{"content":"secret-file-content""#.to_string();
    let mut malformed_args = secret_args.clone();

    finalize_capability_invocation(
        &mut capability_invocations,
        &mut id,
        &mut name,
        &mut malformed_args,
    );

    let events = logs.events();
    assert!(
        events.iter().any(|event| {
            event.level == Level::WARN
                && has_field(
                    event,
                    "agent_event",
                    "stream_capability_invocation_arguments_malformed",
                )
                && has_field(event, "invocation_id", "tc-sensitive")
                && has_field(event, "args_len", &secret_args.len().to_string())
        }),
        "missing malformed arguments warning: {events:#?}"
    );
    assert!(
        events.iter().all(|event| {
            !event.message.contains("secret-file-content")
                && event
                    .fields
                    .iter()
                    .all(|(_, value)| !value.contains("secret-file-content"))
        }),
        "malformed argument logs must not include argument previews: {events:#?}"
    );
}

fn has_field(
    event: &crate::shared::observability::test_utils::CapturedEvent,
    key: &str,
    value: &str,
) -> bool {
    event.fields.iter().any(|(candidate_key, candidate_value)| {
        candidate_key == key && candidate_value.trim_matches('"') == value
    })
}
