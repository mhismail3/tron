use super::*;
use async_stream::stream;
use std::collections::HashSet;
use std::pin::Pin;

use super::super::stream_state::{build_message, finalize_capability_invocation};
use crate::domains::model::providers::provider::ProviderError;
use crate::shared::content::AssistantContent;
use crate::shared::events::{AssistantMessage, RetryErrorInfo, StreamEvent, TronEvent};
use crate::shared::messages::{CapabilityInvocationDraft, TokenUsage};

fn make_emitter() -> Arc<EventEmitter> {
    Arc::new(EventEmitter::new())
}

fn no_stopping_capabilities() -> HashSet<String> {
    HashSet::new()
}

fn text_stream(text: &str) -> StreamEventStream {
    let text = text.to_owned();
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: text.clone() });
        yield Ok(StreamEvent::TextEnd { text: text.clone(), signature: None });
        yield Ok(StreamEvent::Done {
            message: AssistantMessage {
                content: vec![AssistantContent::text(&text)],
                token_usage: Some(TokenUsage {
                    input_tokens: 10,
                    output_tokens: 5,
                    ..Default::default()
                }),
            },
            stop_reason: "end_turn".into(),
        });
    };
    Box::pin(s) as Pin<Box<dyn futures::Stream<Item = Result<StreamEvent, ProviderError>> + Send>>
}

fn thinking_then_text_stream() -> StreamEventStream {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::ThinkingStart);
        yield Ok(StreamEvent::ThinkingDelta { delta: "Let me think".into() });
        yield Ok(StreamEvent::ThinkingEnd { thinking: "Let me think".into(), signature: None });
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: "Answer".into() });
        yield Ok(StreamEvent::TextEnd { text: "Answer".into(), signature: None });
        yield Ok(StreamEvent::Done {
            message: AssistantMessage {
                content: vec![
                    AssistantContent::Thinking { thinking: "Let me think".into(), signature: None },
                    AssistantContent::text("Answer"),
                ],
                token_usage: None,
            },
            stop_reason: "end_turn".into(),
        });
    };
    Box::pin(s)
}

fn capability_invocation_stream() -> StreamEventStream {
    let mut args = serde_json::Map::new();
    let _ = args.insert("command".into(), serde_json::json!("ls"));
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: "Running:".into() });
        yield Ok(StreamEvent::TextEnd { text: "Running:".into(), signature: None });
        yield Ok(StreamEvent::CapabilityInvocationDraftStart { invocation_id: "tc-1".into(), name: "execute".into() });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta { invocation_id: "tc-1".into(), arguments_delta: r#"{"command":"ls"}"#.into() });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-1", "execute", {
                let mut m = serde_json::Map::new();
                let _ = m.insert("command".into(), serde_json::json!("ls"));
                m
            }),
        });
        yield Ok(StreamEvent::Done {
            message: AssistantMessage {
                content: vec![
                    AssistantContent::text("Running:"),
                    AssistantContent::CapabilityInvocation {
                        id: "tc-1".into(),
                        name: "execute".into(),
                        arguments: {
                            let mut m = serde_json::Map::new();
                            let _ = m.insert("command".into(), serde_json::json!("ls"));
                            m
                        },
                        thought_signature: None,
                    },
                ],
                token_usage: Some(TokenUsage { input_tokens: 50, output_tokens: 30, ..Default::default() }),
            },
            stop_reason: "capability_invocation".into(),
        });
    };
    Box::pin(s)
}

#[tokio::test]
async fn pure_text_response() {
    let emitter = make_emitter();
    let cancel = CancellationToken::new();

    let result = process_stream(
        text_stream("hello world"),
        "s1",
        &emitter,
        &cancel,
        &no_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    assert!(!result.interrupted);
    assert_eq!(result.stop_reason, "end_turn");
    assert!(result.partial_content.is_none());
    assert!(result.capability_invocations.is_empty());
    assert!(result.token_usage.is_some());
    assert_eq!(result.token_usage.as_ref().unwrap().input_tokens, 10);
}

#[tokio::test]
async fn thinking_plus_text_response() {
    let emitter = make_emitter();
    let mut rx = emitter.subscribe();
    let cancel = CancellationToken::new();

    let result = process_stream(
        thinking_then_text_stream(),
        "s1",
        &emitter,
        &cancel,
        &no_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    assert!(!result.interrupted);
    assert_eq!(result.stop_reason, "end_turn");

    // Check thinking events were emitted
    let mut saw_thinking_start = false;
    let mut saw_thinking_delta = false;
    let mut saw_thinking_end = false;
    while let Ok(event) = rx.try_recv() {
        match event {
            TronEvent::ThinkingStart { .. } => saw_thinking_start = true,
            TronEvent::ThinkingDelta { .. } => saw_thinking_delta = true,
            TronEvent::ThinkingEnd { .. } => saw_thinking_end = true,
            _ => {}
        }
    }
    assert!(saw_thinking_start);
    assert!(saw_thinking_delta);
    assert!(saw_thinking_end);
}

#[tokio::test]
async fn text_plus_capability_invocation() {
    let emitter = make_emitter();
    let cancel = CancellationToken::new();

    let result = process_stream(
        capability_invocation_stream(),
        "s1",
        &emitter,
        &cancel,
        &no_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    assert_eq!(result.stop_reason, "capability_invocation");
    assert_eq!(result.capability_invocations.len(), 1);
    assert_eq!(result.capability_invocations[0].name, "execute");
    assert_eq!(
        result.capability_invocations[0].arguments["command"],
        serde_json::json!("ls")
    );
}

#[tokio::test]
async fn multiple_capability_invocations() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::CapabilityInvocationDraftStart { invocation_id: "tc-1".into(), name: "inspect".into() });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-1", "inspect", serde_json::Map::new()),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftStart { invocation_id: "tc-2".into(), name: "search".into() });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-2", "search", serde_json::Map::new()),
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

    assert_eq!(result.capability_invocations.len(), 2);
    assert_eq!(result.capability_invocations[0].name, "inspect");
    assert_eq!(result.capability_invocations[1].name, "search");
}

#[tokio::test]
async fn error_mid_stream() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::TextDelta { delta: "partial".into() });
        yield Err(ProviderError::Api {
            status: 500,
            message: "server error".into(),
            code: None,
            retryable: false,
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
    .await;

    assert!(result.is_err());
    assert!(matches!(result.unwrap_err(), RuntimeError::Provider(_)));
}

#[tokio::test]
async fn abort_mid_stream() {
    let cancel = CancellationToken::new();
    let cancel_clone = cancel.clone();

    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::TextDelta { delta: "partial".into() });
        cancel_clone.cancel();
        // Yield another event that should be caught by cancellation
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
    assert_eq!(result.stop_reason, "interrupted");
    // partial_content should contain at least "partial"
    assert!(result.partial_content.is_some());
}

#[tokio::test]
async fn retry_event_emission() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::Retry {
            attempt: 1,
            max_retries: 3,
            delay_ms: 1000,
            error: RetryErrorInfo {
                category: "rate_limit".into(),
                message: "429".into(),
                is_retryable: true,
            },
        });
        yield Ok(StreamEvent::TextDelta { delta: "ok".into() });
        yield Ok(StreamEvent::Done {
            message: AssistantMessage {
                content: vec![AssistantContent::text("ok")],
                token_usage: None,
            },
            stop_reason: "end_turn".into(),
        });
    };

    let emitter = make_emitter();
    let mut rx = emitter.subscribe();
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
    assert!(!result.interrupted);

    let mut saw_retry = false;
    while let Ok(event) = rx.try_recv() {
        if matches!(event, TronEvent::ApiRetry { .. }) {
            saw_retry = true;
        }
    }
    assert!(saw_retry);
}

#[tokio::test]
async fn safety_block_returns_error() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::SafetyBlock {
            blocked_categories: vec!["DANGEROUS".into()],
            error: "blocked".into(),
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
    .await;

    assert!(result.is_err());
    let err = result.unwrap_err();
    assert!(err.to_string().contains("Safety block"));
}

#[tokio::test]
async fn empty_response() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::Done {
            message: AssistantMessage { content: vec![], token_usage: None },
            stop_reason: "end_turn".into(),
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

    assert!(!result.interrupted);
    assert_eq!(result.stop_reason, "end_turn");
    assert!(result.capability_invocations.is_empty());
}

#[tokio::test]
async fn token_usage_extraction() {
    let emitter = make_emitter();
    let cancel = CancellationToken::new();

    let result = process_stream(
        text_stream("hello"),
        "s1",
        &emitter,
        &cancel,
        &no_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    let usage = result.token_usage.unwrap();
    assert_eq!(usage.input_tokens, 10);
    assert_eq!(usage.output_tokens, 5);
}

#[tokio::test]
async fn message_update_events_emitted() {
    let emitter = make_emitter();
    let mut rx = emitter.subscribe();
    let cancel = CancellationToken::new();

    let _ = process_stream(
        text_stream("hello"),
        "s1",
        &emitter,
        &cancel,
        &no_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    let mut updates = vec![];
    while let Ok(event) = rx.try_recv() {
        if let TronEvent::MessageUpdate { content, .. } = event {
            updates.push(content);
        }
    }
    assert!(!updates.is_empty());
    assert_eq!(updates[0], "hello");
}

#[tokio::test]
async fn capability_invocation_generating_event_emitted() {
    let emitter = make_emitter();
    let mut rx = emitter.subscribe();
    let cancel = CancellationToken::new();

    let _ = process_stream(
        capability_invocation_stream(),
        "s1",
        &emitter,
        &cancel,
        &no_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    let mut saw_generating = false;
    while let Ok(event) = rx.try_recv() {
        if matches!(event, TronEvent::CapabilityInvocationGenerating { .. }) {
            saw_generating = true;
        }
    }
    assert!(saw_generating);
}

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

// -- drain mode tests --

fn ask_user_stopping_capabilities() -> HashSet<String> {
    HashSet::from(["agent::ask_user".to_string()])
}

fn both_stopping_capabilities() -> HashSet<String> {
    HashSet::from(["agent::ask_user".to_string(), "agent::ask_user".to_string()])
}

/// Helper: build a Done event with token usage.
fn done_with_usage(content: Vec<AssistantContent>, stop_reason: &str) -> StreamEvent {
    StreamEvent::Done {
        message: AssistantMessage {
            content,
            token_usage: Some(TokenUsage {
                input_tokens: 100,
                output_tokens: 42,
                ..Default::default()
            }),
        },
        stop_reason: stop_reason.into(),
    }
}

#[tokio::test]
async fn drain_after_interactive_capability_drops_trailing_text() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: "hello".into() });
        yield Ok(StreamEvent::TextEnd { text: "hello".into(), signature: None });
        yield Ok(StreamEvent::CapabilityInvocationDraftStart {
            invocation_id: "tc-ask".into(),
            name: "agent::ask_user".into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "tc-ask".into(),
            arguments_delta: r#"{"questions":["q1"]}"#.into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-ask", "agent::ask_user", {
                let mut m = serde_json::Map::new();
                let _ = m.insert("questions".into(), serde_json::json!(["q1"]));
                m
            }),
        });
        // Trailing text — should be drained
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: " trailing garbage".into() });
        yield Ok(StreamEvent::TextEnd { text: " trailing garbage".into(), signature: None });
        yield Ok(done_with_usage(vec![], "end_turn"));
    };

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    let result = process_stream(
        Box::pin(s),
        "s1",
        &emitter,
        &cancel,
        &ask_user_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    assert!(!result.interrupted);
    assert_eq!(result.stop_reason, "capability_invocation");
    assert_eq!(result.capability_invocations.len(), 1);
    assert_eq!(result.capability_invocations[0].name, "agent::ask_user");

    // Token usage captured from Done event
    let usage = result.token_usage.expect("should have token usage");
    assert_eq!(usage.input_tokens, 100);
    assert_eq!(usage.output_tokens, 42);

    // Message should have text + capability invocation, no trailing text
    let text_blocks: Vec<_> = result
        .message
        .content
        .iter()
        .filter(|c| matches!(c, AssistantContent::Text { .. }))
        .collect();
    assert_eq!(text_blocks.len(), 1);
    if let AssistantContent::Text { text, .. } = &text_blocks[0] {
        assert_eq!(text, "hello");
    }
    let capability_blocks: Vec<_> = result
        .message
        .content
        .iter()
        .filter(|c| matches!(c, AssistantContent::CapabilityInvocation { .. }))
        .collect();
    assert_eq!(capability_blocks.len(), 1);
}

#[tokio::test]
async fn drain_after_execute_targeting_turn_stopping_contract() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: "before".into() });
        yield Ok(StreamEvent::TextEnd { text: "before".into(), signature: None });
        yield Ok(StreamEvent::CapabilityInvocationDraftStart {
            invocation_id: "tc-execute-ask".into(),
            name: "execute".into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "tc-execute-ask".into(),
            arguments_delta: r#"{"mode":"invoke","contractId":"agent::ask_user","payload":{"questions":[{"question":"Proceed?"}]}}"#.into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-execute-ask", "execute", {
                let mut m = serde_json::Map::new();
                let _ = m.insert("mode".into(), serde_json::json!("invoke"));
                let _ = m.insert("contractId".into(), serde_json::json!("agent::ask_user"));
                let _ = m.insert("payload".into(), serde_json::json!({"questions":[{"question":"Proceed?"}]}));
                m
            }),
        });
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: " should not appear".into() });
        yield Ok(StreamEvent::TextEnd { text: " should not appear".into(), signature: None });
        yield Ok(done_with_usage(vec![], "end_turn"));
    };

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    let result = process_stream(
        Box::pin(s),
        "s1",
        &emitter,
        &cancel,
        &ask_user_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    assert!(!result.interrupted);
    assert_eq!(result.stop_reason, "capability_invocation");
    assert_eq!(result.capability_invocations.len(), 1);
    assert_eq!(result.capability_invocations[0].name, "execute");
    let text = result
        .message
        .content
        .iter()
        .find_map(|content| match content {
            AssistantContent::Text { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .expect("pre-invocation text");
    assert_eq!(text, "before");
}

#[tokio::test]
async fn drain_preserves_thinking_and_text_before_interactive() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::ThinkingStart);
        yield Ok(StreamEvent::ThinkingDelta { delta: "deep thought".into() });
        yield Ok(StreamEvent::ThinkingEnd { thinking: "deep thought".into(), signature: Some("sig-1".into()) });
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: "answer".into() });
        yield Ok(StreamEvent::TextEnd { text: "answer".into(), signature: None });
        yield Ok(StreamEvent::CapabilityInvocationDraftStart {
            invocation_id: "tc-ask-confirm".into(),
            name: "agent::ask_user".into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "tc-ask-confirm".into(),
            arguments_delta: r#"{"questions":[{"question":"Proceed?"}]}"#.into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-ask-confirm", "agent::ask_user", {
                let mut m = serde_json::Map::new();
                let _ = m.insert("questions".into(), serde_json::json!([{ "question": "Proceed?" }]));
                m
            }),
        });
        // Trailing text — drained
        yield Ok(StreamEvent::TextDelta { delta: "extra".into() });
        yield Ok(done_with_usage(vec![], "end_turn"));
    };

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    let result = process_stream(
        Box::pin(s),
        "s1",
        &emitter,
        &cancel,
        &both_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    assert!(!result.interrupted);
    // Thinking preserved
    let thinking = result
        .message
        .content
        .iter()
        .find(|c| matches!(c, AssistantContent::Thinking { .. }));
    assert!(thinking.is_some());
    if let AssistantContent::Thinking {
        thinking: t,
        signature,
    } = thinking.unwrap()
    {
        assert_eq!(t, "deep thought");
        assert_eq!(signature.as_deref(), Some("sig-1"));
    }
    // Text preserved
    let text = result
        .message
        .content
        .iter()
        .find(|c| matches!(c, AssistantContent::Text { .. }));
    assert!(text.is_some());
    if let AssistantContent::Text { text: t, .. } = text.unwrap() {
        assert_eq!(t, "answer");
    }
    // ModelCapability preserved
    assert_eq!(result.capability_invocations.len(), 1);
    assert_eq!(result.capability_invocations[0].name, "agent::ask_user");
}

#[tokio::test]
async fn drain_with_preceding_tools_keeps_all_before_interactive() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::CapabilityInvocationDraftStart { invocation_id: "tc-bash".into(), name: "process::run".into() });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "tc-bash".into(),
            arguments_delta: r#"{"command":"ls"}"#.into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-bash", "process::run", {
                let mut m = serde_json::Map::new();
                let _ = m.insert("command".into(), serde_json::json!("ls"));
                m
            }),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftStart {
            invocation_id: "tc-ask".into(),
            name: "agent::ask_user".into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "tc-ask".into(),
            arguments_delta: r#"{"questions":["q"]}"#.into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-ask", "agent::ask_user", {
                let mut m = serde_json::Map::new();
                let _ = m.insert("questions".into(), serde_json::json!(["q"]));
                m
            }),
        });
        // ModelCapability after interactive — should be drained
        yield Ok(StreamEvent::CapabilityInvocationDraftStart { invocation_id: "tc-edit".into(), name: "filesystem::edit_file".into() });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "tc-edit".into(),
            arguments_delta: r#"{"file":"x"}"#.into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-edit", "filesystem::edit_file", serde_json::Map::new()),
        });
        yield Ok(done_with_usage(vec![], "capability_invocation"));
    };

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    let result = process_stream(
        Box::pin(s),
        "s1",
        &emitter,
        &cancel,
        &ask_user_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    assert_eq!(result.capability_invocations.len(), 2);
    assert_eq!(result.capability_invocations[0].name, "process::run");
    assert_eq!(result.capability_invocations[1].name, "agent::ask_user");
    // filesystem::edit_file should NOT be in capability_invocations
    assert!(
        !result
            .capability_invocations
            .iter()
            .any(|tc| tc.name == "filesystem::edit_file")
    );
}

#[tokio::test]
async fn no_drain_for_non_stopping_capabilities() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: "hello".into() });
        yield Ok(StreamEvent::TextEnd { text: "hello".into(), signature: None });
        yield Ok(StreamEvent::CapabilityInvocationDraftStart { invocation_id: "tc-1".into(), name: "process::run".into() });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "tc-1".into(),
            arguments_delta: r#"{"command":"ls"}"#.into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-1", "process::run", {
                let mut m = serde_json::Map::new();
                let _ = m.insert("command".into(), serde_json::json!("ls"));
                m
            }),
        });
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: " world".into() });
        yield Ok(StreamEvent::TextEnd { text: " world".into(), signature: None });
        yield Ok(StreamEvent::Done {
            message: AssistantMessage {
                content: vec![
                    AssistantContent::text("hello world"),
                    AssistantContent::CapabilityInvocation {
                        id: "tc-1".into(),
                        name: "process::run".into(),
                        arguments: serde_json::Map::new(),
                        thought_signature: None,
                    },
                ],
                token_usage: Some(TokenUsage { input_tokens: 50, output_tokens: 20, ..Default::default() }),
            },
            stop_reason: "capability_invocation".into(),
        });
    };

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    // agent::ask_user is in the set, but process::run is not — no drain
    let result = process_stream(
        Box::pin(s),
        "s1",
        &emitter,
        &cancel,
        &ask_user_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    assert!(!result.interrupted);
    assert_eq!(result.stop_reason, "capability_invocation");
    assert_eq!(result.capability_invocations.len(), 1);
    assert_eq!(result.capability_invocations[0].name, "process::run");
    // Message should come from final_message (has combined text)
    let usage = result.token_usage.unwrap();
    assert_eq!(usage.input_tokens, 50);
}

#[tokio::test]
async fn cancel_during_drain_returns_interrupted() {
    let cancel = CancellationToken::new();
    let cancel_clone = cancel.clone();

    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::CapabilityInvocationDraftStart {
            invocation_id: "tc-ask".into(),
            name: "agent::ask_user".into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "tc-ask".into(),
            arguments_delta: r#"{"questions":["q"]}"#.into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-ask", "agent::ask_user", {
                let mut m = serde_json::Map::new();
                let _ = m.insert("questions".into(), serde_json::json!(["q"]));
                m
            }),
        });
        // Now draining — cancel before Done arrives
        cancel_clone.cancel();
        yield Ok(StreamEvent::TextDelta { delta: "never seen".into() });
        yield Ok(done_with_usage(vec![], "end_turn"));
    };

    let emitter = make_emitter();
    let result = process_stream(
        Box::pin(s),
        "s1",
        &emitter,
        &cancel,
        &ask_user_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    assert!(result.interrupted);
    assert_eq!(result.stop_reason, "interrupted");
    // Capability invocation should still be in the result (was finalized before drain)
    assert_eq!(result.capability_invocations.len(), 1);
    assert_eq!(result.capability_invocations[0].name, "agent::ask_user");
}

#[tokio::test]
async fn drain_empty_stopping_set_no_change() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: "hello".into() });
        yield Ok(StreamEvent::TextEnd { text: "hello".into(), signature: None });
        yield Ok(StreamEvent::CapabilityInvocationDraftStart {
            invocation_id: "tc-ask".into(),
            name: "agent::ask_user".into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftDelta {
            invocation_id: "tc-ask".into(),
            arguments_delta: r#"{"questions":["q"]}"#.into(),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-ask", "agent::ask_user", {
                let mut m = serde_json::Map::new();
                let _ = m.insert("questions".into(), serde_json::json!(["q"]));
                m
            }),
        });
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: " trailing".into() });
        yield Ok(StreamEvent::TextEnd { text: " trailing".into(), signature: None });
        yield Ok(StreamEvent::Done {
            message: AssistantMessage {
                content: vec![AssistantContent::text("hello trailing")],
                token_usage: Some(TokenUsage { input_tokens: 10, output_tokens: 5, ..Default::default() }),
            },
            stop_reason: "capability_invocation".into(),
        });
    };

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    // Empty set — no drain should happen
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

    // Trailing text should be present (from final_message)
    assert_eq!(result.stop_reason, "capability_invocation");
    assert_eq!(result.capability_invocations.len(), 1);
    // Message comes from final_message which has combined text
    let has_text = result
        .message
        .content
        .iter()
        .any(|c| matches!(c, AssistantContent::Text { text, .. } if text.contains("trailing")));
    assert!(has_text, "trailing text should be preserved when no drain");
}
