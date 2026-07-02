use super::*;
mod drain;
mod stream_state;
use async_stream::stream;
use std::collections::HashSet;
use std::pin::Pin;

use super::super::stream_state::{build_message, finalize_capability_invocation};
use crate::domains::model::providers::google::stream_handler as google_stream_handler;
use crate::domains::model::providers::google::types::{
    FunctionCallData, GeminiCandidate, GeminiCandidateContent, GeminiPart, GeminiStreamChunk,
};
use crate::domains::model::providers::openai::stream_handler as openai_stream_handler;
use crate::domains::model::providers::openai::types::{
    OutputContent, OutputItemType, ResponsesOutputItem, ResponsesResponse, ResponsesSseEvent,
    ResponsesUsage, SseEventType,
};
use crate::domains::model::responder::{ModelResponseError, ModelResponseStream};
use crate::shared::protocol::content::AssistantContent;
use crate::shared::protocol::events::{AssistantMessage, RetryErrorInfo, StreamEvent, TronEvent};
use crate::shared::protocol::messages::{CapabilityInvocationDraft, TokenUsage};

fn make_emitter() -> Arc<EventEmitter> {
    Arc::new(EventEmitter::new())
}

fn no_stopping_capabilities() -> HashSet<String> {
    HashSet::new()
}

fn stream_from_provider_events(events: Vec<StreamEvent>) -> ModelResponseStream {
    Box::pin(futures::stream::iter(
        events.into_iter().map(Ok::<_, ModelResponseError>),
    ))
}

fn text_stream(text: &str) -> ModelResponseStream {
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
    Box::pin(s)
        as Pin<Box<dyn futures::Stream<Item = Result<StreamEvent, ModelResponseError>> + Send>>
}

fn thinking_then_text_stream() -> ModelResponseStream {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::ThinkingStart);
        yield Ok(StreamEvent::ThinkingDelta {
            delta: "Let me think".into(),
            kind: crate::shared::protocol::content::ThinkingContentKind::Thinking,
        });
        yield Ok(StreamEvent::ThinkingEnd {
            thinking: "Let me think".into(),
            kind: crate::shared::protocol::content::ThinkingContentKind::Thinking,
            signature: None,
        });
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: "Answer".into() });
        yield Ok(StreamEvent::TextEnd { text: "Answer".into(), signature: None });
        yield Ok(StreamEvent::Done {
            message: AssistantMessage {
                content: vec![
                    AssistantContent::Thinking {
                        thinking: "Let me think".into(),
                        kind: crate::shared::protocol::content::ThinkingContentKind::Thinking,
                        signature: None,
                    },
                    AssistantContent::text("Answer"),
                ],
                token_usage: None,
            },
            stop_reason: "end_turn".into(),
        });
    };
    Box::pin(s)
}

fn capability_invocation_stream() -> ModelResponseStream {
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
async fn openai_final_only_text_function_text_uses_provider_done_order() {
    let mut provider_state = openai_stream_handler::create_stream_state();
    let provider_events = openai_stream_handler::process_stream_event(
        &ResponsesSseEvent {
            event_type: SseEventType::Completed,
            response: Some(ResponsesResponse {
                id: Some("resp-final-only".into()),
                output: vec![
                    ResponsesOutputItem {
                        item_type: OutputItemType::Message,
                        content: Some(vec![OutputContent {
                            content_type: "output_text".into(),
                            text: Some("before".into()),
                        }]),
                        ..Default::default()
                    },
                    ResponsesOutputItem {
                        item_type: OutputItemType::FunctionCall,
                        call_id: Some("call_mid".into()),
                        name: Some("execute".into()),
                        arguments: Some(r#"{"operation":"inspect"}"#.into()),
                        ..Default::default()
                    },
                    ResponsesOutputItem {
                        item_type: OutputItemType::Message,
                        content: Some(vec![OutputContent {
                            content_type: "output_text".into(),
                            text: Some("after".into()),
                        }]),
                        ..Default::default()
                    },
                ],
                usage: Some(ResponsesUsage {
                    input_tokens: 12,
                    output_tokens: 8,
                    total_tokens: 20,
                    ..Default::default()
                }),
            }),
            ..Default::default()
        },
        &mut provider_state,
    );

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    let result = process_stream(
        stream_from_provider_events(provider_events),
        "s1",
        &emitter,
        &cancel,
        &no_stopping_capabilities(),
        None,
        None,
    )
    .await
    .unwrap();

    assert_eq!(result.token_usage.as_ref().unwrap().input_tokens, 12);
    assert_eq!(result.capability_invocations.len(), 1);
    assert_eq!(result.message.content.len(), 3);
    assert!(matches!(
        &result.message.content[0],
        AssistantContent::Text { text } if text == "before"
    ));
    assert!(matches!(
        &result.message.content[1],
        AssistantContent::CapabilityInvocation { id, name, .. }
            if id == "call_mid" && name == "execute"
    ));
    assert!(matches!(
        &result.message.content[2],
        AssistantContent::Text { text } if text == "after"
    ));
}

#[tokio::test]
async fn google_streamed_text_function_text_keeps_block_boundaries() {
    let mut provider_state = google_stream_handler::create_stream_state();
    let provider_events = google_stream_handler::process_stream_chunk(
        &GeminiStreamChunk {
            candidates: Some(vec![GeminiCandidate {
                content: Some(GeminiCandidateContent {
                    parts: vec![
                        GeminiPart::Text {
                            text: "before".into(),
                            thought: None,
                            thought_signature: None,
                        },
                        GeminiPart::FunctionCall {
                            function_call: FunctionCallData {
                                name: "execute".into(),
                                args: serde_json::json!({"operation": "inspect"}),
                            },
                            thought_signature: None,
                        },
                        GeminiPart::Text {
                            text: "after".into(),
                            thought: None,
                            thought_signature: None,
                        },
                    ],
                    role: None,
                }),
                finish_reason: Some("TOOL_USE".into()),
                safety_ratings: None,
            }]),
            ..Default::default()
        },
        &mut provider_state,
    );

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    let result = process_stream(
        stream_from_provider_events(provider_events),
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
    assert_eq!(result.message.content.len(), 3);
    assert!(matches!(
        &result.message.content[0],
        AssistantContent::Text { text } if text == "before"
    ));
    assert!(matches!(
        &result.message.content[1],
        AssistantContent::CapabilityInvocation { name, .. } if name == "execute"
    ));
    assert!(matches!(
        &result.message.content[2],
        AssistantContent::Text { text } if text == "after"
    ));
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
async fn stream_order_overrides_bucketed_provider_done_content() {
    let mut args = serde_json::Map::new();
    let _ = args.insert("operation".into(), serde_json::json!("inspect"));
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::ThinkingStart);
        yield Ok(StreamEvent::ThinkingDelta {
            delta: "summary".into(),
            kind: crate::shared::protocol::content::ThinkingContentKind::Thinking,
        });
        yield Ok(StreamEvent::ThinkingEnd {
            thinking: "full thinking".into(),
            kind: crate::shared::protocol::content::ThinkingContentKind::Thinking,
            signature: None,
        });
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: "before".into() });
        yield Ok(StreamEvent::TextEnd { text: "before".into(), signature: None });
        yield Ok(StreamEvent::CapabilityInvocationDraftStart { invocation_id: "tc-1".into(), name: "execute".into() });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-1", "execute", args.clone()),
        });
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: "after".into() });
        yield Ok(StreamEvent::TextEnd { text: "after".into(), signature: None });
        yield Ok(StreamEvent::Done {
            message: AssistantMessage {
                content: vec![
                    AssistantContent::Thinking {
                        thinking: "full thinking".into(),
                        kind: crate::shared::protocol::content::ThinkingContentKind::Thinking,
                        signature: None,
                    },
                    AssistantContent::text("beforeafter"),
                    AssistantContent::CapabilityInvocation {
                        id: "tc-1".into(),
                        name: "execute".into(),
                        arguments: args,
                        thought_signature: None,
                    },
                ],
                token_usage: Some(TokenUsage { input_tokens: 11, output_tokens: 7, ..Default::default() }),
            },
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

    assert_eq!(result.token_usage.as_ref().unwrap().input_tokens, 11);
    assert_eq!(result.message.content.len(), 4);
    assert!(matches!(
        &result.message.content[0],
        AssistantContent::Thinking { thinking, .. } if thinking == "full thinking"
    ));
    assert!(matches!(
        &result.message.content[1],
        AssistantContent::Text { text } if text == "before"
    ));
    assert!(matches!(
        &result.message.content[2],
        AssistantContent::CapabilityInvocation { id, .. } if id == "tc-1"
    ));
    assert!(matches!(
        &result.message.content[3],
        AssistantContent::Text { text } if text == "after"
    ));
}

#[tokio::test]
async fn capability_blocks_keep_first_observed_order_when_done_is_reversed() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::CapabilityInvocationDraftStart { invocation_id: "tc-a".into(), name: "execute".into() });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-a", "execute", serde_json::Map::new()),
        });
        yield Ok(StreamEvent::CapabilityInvocationDraftStart { invocation_id: "tc-b".into(), name: "inspect".into() });
        yield Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: CapabilityInvocationDraft::new("tc-b", "inspect", serde_json::Map::new()),
        });
        yield Ok(StreamEvent::Done {
            message: AssistantMessage {
                content: vec![
                    AssistantContent::CapabilityInvocation {
                        id: "tc-b".into(),
                        name: "inspect".into(),
                        arguments: serde_json::Map::new(),
                        thought_signature: None,
                    },
                    AssistantContent::CapabilityInvocation {
                        id: "tc-a".into(),
                        name: "execute".into(),
                        arguments: serde_json::Map::new(),
                        thought_signature: None,
                    },
                ],
                token_usage: None,
            },
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

    let ids: Vec<&str> = result
        .message
        .content
        .iter()
        .filter_map(|content| match content {
            AssistantContent::CapabilityInvocation { id, .. } => Some(id.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(ids, vec!["tc-a", "tc-b"]);
}

#[tokio::test]
async fn error_mid_stream() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::TextDelta { delta: "partial".into() });
        yield Err(ModelResponseError::other("server error"));
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
    assert!(matches!(
        result.unwrap_err(),
        RuntimeError::ModelResponse(_)
    ));
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
