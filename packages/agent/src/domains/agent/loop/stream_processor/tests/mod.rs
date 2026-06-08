use super::*;
mod drain;
mod stream_state;
use async_stream::stream;
use std::collections::HashSet;
use std::pin::Pin;

use super::super::stream_state::{build_message, finalize_capability_invocation};
use crate::domains::model::providers::shared::provider::ProviderError;
use crate::shared::protocol::content::AssistantContent;
use crate::shared::protocol::events::{AssistantMessage, RetryErrorInfo, StreamEvent, TronEvent};
use crate::shared::protocol::messages::{CapabilityInvocationDraft, TokenUsage};

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
