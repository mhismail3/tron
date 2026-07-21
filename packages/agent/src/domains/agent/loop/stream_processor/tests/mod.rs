use super::*;
mod stream_state;
use async_stream::stream;
use std::pin::Pin;

use super::super::stream_state::{build_message, finalize_tool_invocation};
use crate::domains::model::responder::{ModelResponseError, ModelResponseStream};
use crate::shared::protocol::content::AssistantContent;
use crate::shared::protocol::events::{AssistantMessage, RetryErrorInfo, StreamEvent, TronEvent};
use crate::shared::protocol::messages::{TokenUsage, ToolInvocationDraft};

fn make_emitter() -> Arc<EventEmitter> {
    Arc::new(EventEmitter::new())
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

fn tool_invocation_stream() -> ModelResponseStream {
    let mut args = serde_json::Map::new();
    let _ = args.insert("command".into(), serde_json::json!("ls"));
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::TextStart);
        yield Ok(StreamEvent::TextDelta { delta: "Running:".into() });
        yield Ok(StreamEvent::TextEnd { text: "Running:".into(), signature: None });
        yield Ok(StreamEvent::ToolInvocationDraftStart { invocation_id: "tc-1".into(), name: "test_tool".into() });
        yield Ok(StreamEvent::ToolInvocationDraftDelta { invocation_id: "tc-1".into(), arguments_delta: r#"{"command":"ls"}"#.into() });
        yield Ok(StreamEvent::ToolInvocationDraftEnd {
            tool_invocation: ToolInvocationDraft::new("tc-1", "test_tool", {
                let mut m = serde_json::Map::new();
                let _ = m.insert("command".into(), serde_json::json!("ls"));
                m
            }),
        });
        yield Ok(StreamEvent::Done {
            message: AssistantMessage {
                content: vec![
                    AssistantContent::text("Running:"),
                    AssistantContent::ToolInvocation {
                        id: "tc-1".into(),
                        name: "test_tool".into(),
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
            stop_reason: "tool_invocation".into(),
        });
    };
    Box::pin(s)
}

#[tokio::test]
async fn normalized_final_only_text_call_text_uses_stream_order() {
    let provider_events = vec![
        StreamEvent::Start,
        StreamEvent::TextStart,
        StreamEvent::TextDelta {
            delta: "before".into(),
        },
        StreamEvent::TextEnd {
            text: "before".into(),
            signature: None,
        },
        StreamEvent::ToolInvocationDraftStart {
            invocation_id: "call_mid".into(),
            name: "test_tool".into(),
        },
        StreamEvent::ToolInvocationDraftDelta {
            invocation_id: "call_mid".into(),
            arguments_delta: r#"{"operation":"inspect"}"#.into(),
        },
        StreamEvent::ToolInvocationDraftEnd {
            tool_invocation: ToolInvocationDraft::new("call_mid", "test_tool", {
                let mut args = serde_json::Map::new();
                let _ = args.insert("operation".into(), serde_json::json!("inspect"));
                args
            }),
        },
        StreamEvent::TextStart,
        StreamEvent::TextDelta {
            delta: "after".into(),
        },
        StreamEvent::TextEnd {
            text: "after".into(),
            signature: None,
        },
        StreamEvent::Done {
            message: AssistantMessage {
                content: vec![
                    AssistantContent::text("before"),
                    AssistantContent::ToolInvocation {
                        id: "call_mid".into(),
                        name: "test_tool".into(),
                        arguments: {
                            let mut args = serde_json::Map::new();
                            let _ = args.insert("operation".into(), serde_json::json!("inspect"));
                            args
                        },
                        thought_signature: None,
                    },
                    AssistantContent::text("after"),
                ],
                token_usage: Some(TokenUsage {
                    input_tokens: 12,
                    output_tokens: 8,
                    total_tokens: Some(20),
                    ..Default::default()
                }),
            },
            stop_reason: "tool_invocation".into(),
        },
    ];

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    let result = process_stream(
        stream_from_provider_events(provider_events),
        "s1",
        &emitter,
        &cancel,
        None,
        None,
    )
    .await
    .unwrap();

    assert_eq!(result.token_usage.as_ref().unwrap().input_tokens, 12);
    assert_eq!(result.tool_invocations.len(), 1);
    assert_eq!(result.message.content.len(), 3);
    assert!(matches!(
        &result.message.content[0],
        AssistantContent::Text { text } if text == "before"
    ));
    assert!(matches!(
        &result.message.content[1],
        AssistantContent::ToolInvocation { id, name, .. }
            if id == "call_mid" && name == "test_tool"
    ));
    assert!(matches!(
        &result.message.content[2],
        AssistantContent::Text { text } if text == "after"
    ));
}

#[tokio::test]
async fn normalized_streamed_text_call_text_keeps_block_boundaries() {
    let provider_events = vec![
        StreamEvent::Start,
        StreamEvent::TextStart,
        StreamEvent::TextDelta {
            delta: "before".into(),
        },
        StreamEvent::TextEnd {
            text: "before".into(),
            signature: None,
        },
        StreamEvent::ToolInvocationDraftStart {
            invocation_id: "test_tool".into(),
            name: "test_tool".into(),
        },
        StreamEvent::ToolInvocationDraftEnd {
            tool_invocation: ToolInvocationDraft::new("test_tool", "test_tool", {
                let mut args = serde_json::Map::new();
                let _ = args.insert("operation".into(), serde_json::json!("inspect"));
                args
            }),
        },
        StreamEvent::TextStart,
        StreamEvent::TextDelta {
            delta: "after".into(),
        },
        StreamEvent::TextEnd {
            text: "after".into(),
            signature: None,
        },
        StreamEvent::Done {
            message: AssistantMessage {
                content: vec![
                    AssistantContent::text("before"),
                    AssistantContent::ToolInvocation {
                        id: "test_tool".into(),
                        name: "test_tool".into(),
                        arguments: {
                            let mut args = serde_json::Map::new();
                            let _ = args.insert("operation".into(), serde_json::json!("inspect"));
                            args
                        },
                        thought_signature: None,
                    },
                    AssistantContent::text("after"),
                ],
                token_usage: None,
            },
            stop_reason: "tool_invocation".into(),
        },
    ];

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    let result = process_stream(
        stream_from_provider_events(provider_events),
        "s1",
        &emitter,
        &cancel,
        None,
        None,
    )
    .await
    .unwrap();

    assert_eq!(result.stop_reason, "tool_invocation");
    assert_eq!(result.tool_invocations.len(), 1);
    assert_eq!(result.message.content.len(), 3);
    assert!(matches!(
        &result.message.content[0],
        AssistantContent::Text { text } if text == "before"
    ));
    assert!(matches!(
        &result.message.content[1],
        AssistantContent::ToolInvocation { name, .. } if name == "test_tool"
    ));
    assert!(matches!(
        &result.message.content[2],
        AssistantContent::Text { text } if text == "after"
    ));
}

#[tokio::test]
async fn terminal_thinking_snapshot_after_call_is_not_duplicated_and_normalizes_stop_reason() {
    let thinking = "Inspect the current tool state.";
    let arguments = {
        let mut args = serde_json::Map::new();
        let _ = args.insert("query".into(), serde_json::json!("workers"));
        args
    };
    let tool_invocation =
        ToolInvocationDraft::new("call_after_thinking", "lookup", arguments.clone());
    let provider_events = vec![
        StreamEvent::Start,
        StreamEvent::ThinkingStart,
        StreamEvent::ThinkingDelta {
            delta: thinking.into(),
            kind: crate::shared::protocol::content::ThinkingContentKind::Thinking,
        },
        StreamEvent::ToolInvocationDraftStart {
            invocation_id: "call_after_thinking".into(),
            name: "lookup".into(),
        },
        StreamEvent::ToolInvocationDraftDelta {
            invocation_id: "call_after_thinking".into(),
            arguments_delta: r#"{"query":"workers"}"#.into(),
        },
        StreamEvent::ToolInvocationDraftEnd {
            tool_invocation: tool_invocation.clone(),
        },
        StreamEvent::ThinkingEnd {
            thinking: thinking.into(),
            kind: crate::shared::protocol::content::ThinkingContentKind::Thinking,
            signature: Some("final-signature".into()),
        },
        StreamEvent::Done {
            message: AssistantMessage {
                content: vec![
                    AssistantContent::Thinking {
                        thinking: thinking.into(),
                        kind: crate::shared::protocol::content::ThinkingContentKind::Thinking,
                        signature: Some("final-signature".into()),
                    },
                    AssistantContent::ToolInvocation {
                        id: "call_after_thinking".into(),
                        name: "lookup".into(),
                        arguments,
                        thought_signature: None,
                    },
                    AssistantContent::Thinking {
                        thinking: thinking.into(),
                        kind: crate::shared::protocol::content::ThinkingContentKind::Thinking,
                        signature: Some("final-signature".into()),
                    },
                ],
                token_usage: None,
            },
            stop_reason: "end_turn".into(),
        },
    ];

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    let result = process_stream(
        stream_from_provider_events(provider_events),
        "s1",
        &emitter,
        &cancel,
        None,
        None,
    )
    .await
    .unwrap();

    assert_eq!(result.stop_reason, "tool_invocation");
    assert_eq!(result.tool_invocations.len(), 1);
    assert_eq!(result.message.content.len(), 2);
    assert!(matches!(
        &result.message.content[0],
        AssistantContent::Thinking {
            thinking: current,
            signature,
            ..
        } if current == thinking && signature.as_deref() == Some("final-signature")
    ));
    assert!(matches!(
        &result.message.content[1],
        AssistantContent::ToolInvocation { id, .. } if id == "call_after_thinking"
    ));
}

#[tokio::test]
async fn distinct_thinking_after_call_remains_a_separate_ordered_block() {
    let provider_events = vec![
        StreamEvent::Start,
        StreamEvent::ThinkingStart,
        StreamEvent::ThinkingDelta {
            delta: "before".into(),
            kind: crate::shared::protocol::content::ThinkingContentKind::Thinking,
        },
        StreamEvent::ThinkingEnd {
            thinking: "before".into(),
            kind: crate::shared::protocol::content::ThinkingContentKind::Thinking,
            signature: None,
        },
        StreamEvent::ToolInvocationDraftStart {
            invocation_id: "call_between_thinking".into(),
            name: "test_tool".into(),
        },
        StreamEvent::ToolInvocationDraftEnd {
            tool_invocation: ToolInvocationDraft::new(
                "call_between_thinking",
                "test_tool",
                serde_json::Map::new(),
            ),
        },
        StreamEvent::ThinkingStart,
        StreamEvent::ThinkingDelta {
            delta: "after".into(),
            kind: crate::shared::protocol::content::ThinkingContentKind::Thinking,
        },
        StreamEvent::ThinkingEnd {
            thinking: "after".into(),
            kind: crate::shared::protocol::content::ThinkingContentKind::Thinking,
            signature: None,
        },
        StreamEvent::Done {
            message: AssistantMessage {
                content: Vec::new(),
                token_usage: None,
            },
            stop_reason: "end_turn".into(),
        },
    ];

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    let result = process_stream(
        stream_from_provider_events(provider_events),
        "s1",
        &emitter,
        &cancel,
        None,
        None,
    )
    .await
    .unwrap();

    assert_eq!(result.stop_reason, "tool_invocation");
    assert_eq!(result.message.content.len(), 3);
    assert!(matches!(
        &result.message.content[0],
        AssistantContent::Thinking { thinking, .. } if thinking == "before"
    ));
    assert!(matches!(
        &result.message.content[1],
        AssistantContent::ToolInvocation { id, .. } if id == "call_between_thinking"
    ));
    assert!(matches!(
        &result.message.content[2],
        AssistantContent::Thinking { thinking, .. } if thinking == "after"
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
        None,
        None,
    )
    .await
    .unwrap();

    assert!(!result.interrupted);
    assert_eq!(result.stop_reason, "end_turn");
    assert!(result.partial_content.is_none());
    assert!(result.tool_invocations.is_empty());
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
async fn text_plus_tool_invocation() {
    let emitter = make_emitter();
    let cancel = CancellationToken::new();

    let result = process_stream(
        tool_invocation_stream(),
        "s1",
        &emitter,
        &cancel,
        None,
        None,
    )
    .await
    .unwrap();

    assert_eq!(result.stop_reason, "tool_invocation");
    assert_eq!(result.tool_invocations.len(), 1);
    assert_eq!(result.tool_invocations[0].name, "test_tool");
    assert_eq!(
        result.tool_invocations[0].arguments["command"],
        serde_json::json!("ls")
    );
}

#[tokio::test]
async fn multiple_tool_invocations() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::ToolInvocationDraftStart { invocation_id: "tc-1".into(), name: "inspect".into() });
        yield Ok(StreamEvent::ToolInvocationDraftEnd {
            tool_invocation: ToolInvocationDraft::new("tc-1", "inspect", serde_json::Map::new()),
        });
        yield Ok(StreamEvent::ToolInvocationDraftStart { invocation_id: "tc-2".into(), name: "search".into() });
        yield Ok(StreamEvent::ToolInvocationDraftEnd {
            tool_invocation: ToolInvocationDraft::new("tc-2", "search", serde_json::Map::new()),
        });
        yield Ok(StreamEvent::Done {
            message: AssistantMessage { content: vec![], token_usage: None },
            stop_reason: "tool_invocation".into(),
        });
    };

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    let result = process_stream(Box::pin(s), "s1", &emitter, &cancel, None, None)
        .await
        .unwrap();

    assert_eq!(result.tool_invocations.len(), 2);
    assert_eq!(result.tool_invocations[0].name, "inspect");
    assert_eq!(result.tool_invocations[1].name, "search");
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
        yield Ok(StreamEvent::ToolInvocationDraftStart { invocation_id: "tc-1".into(), name: "test_tool".into() });
        yield Ok(StreamEvent::ToolInvocationDraftEnd {
            tool_invocation: ToolInvocationDraft::new("tc-1", "test_tool", args.clone()),
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
                    AssistantContent::ToolInvocation {
                        id: "tc-1".into(),
                        name: "test_tool".into(),
                        arguments: args,
                        thought_signature: None,
                    },
                ],
                token_usage: Some(TokenUsage { input_tokens: 11, output_tokens: 7, ..Default::default() }),
            },
            stop_reason: "tool_invocation".into(),
        });
    };

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    let result = process_stream(Box::pin(s), "s1", &emitter, &cancel, None, None)
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
        AssistantContent::ToolInvocation { id, .. } if id == "tc-1"
    ));
    assert!(matches!(
        &result.message.content[3],
        AssistantContent::Text { text } if text == "after"
    ));
}

#[tokio::test]
async fn tool_blocks_keep_first_observed_order_when_done_is_reversed() {
    let s = stream! {
        yield Ok(StreamEvent::Start);
        yield Ok(StreamEvent::ToolInvocationDraftStart { invocation_id: "tc-a".into(), name: "test_tool".into() });
        yield Ok(StreamEvent::ToolInvocationDraftEnd {
            tool_invocation: ToolInvocationDraft::new("tc-a", "test_tool", serde_json::Map::new()),
        });
        yield Ok(StreamEvent::ToolInvocationDraftStart { invocation_id: "tc-b".into(), name: "inspect".into() });
        yield Ok(StreamEvent::ToolInvocationDraftEnd {
            tool_invocation: ToolInvocationDraft::new("tc-b", "inspect", serde_json::Map::new()),
        });
        yield Ok(StreamEvent::Done {
            message: AssistantMessage {
                content: vec![
                    AssistantContent::ToolInvocation {
                        id: "tc-b".into(),
                        name: "inspect".into(),
                        arguments: serde_json::Map::new(),
                        thought_signature: None,
                    },
                    AssistantContent::ToolInvocation {
                        id: "tc-a".into(),
                        name: "test_tool".into(),
                        arguments: serde_json::Map::new(),
                        thought_signature: None,
                    },
                ],
                token_usage: None,
            },
            stop_reason: "tool_invocation".into(),
        });
    };

    let emitter = make_emitter();
    let cancel = CancellationToken::new();
    let result = process_stream(Box::pin(s), "s1", &emitter, &cancel, None, None)
        .await
        .unwrap();

    let ids: Vec<&str> = result
        .message
        .content
        .iter()
        .filter_map(|content| match content {
            AssistantContent::ToolInvocation { id, .. } => Some(id.as_str()),
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
    let result = process_stream(Box::pin(s), "s1", &emitter, &cancel, None, None).await;

    assert!(result.is_err());
    let failure = result.unwrap_err();
    assert!(matches!(failure.error, RuntimeError::ModelResponse(_)));
    assert_eq!(failure.partial.partial_content.as_deref(), Some("partial"));
    assert_eq!(failure.partial.stop_reason, "error");
    assert!(!failure.partial.interrupted);
}

#[tokio::test]
async fn journal_write_failure_stops_before_unrecoverable_live_delta() {
    let temp = tempfile::NamedTempFile::new().unwrap();
    let read_only = std::fs::File::open(temp.path()).unwrap();
    let mut journal =
        StreamingJournal::from_test_file(read_only, temp.path().to_path_buf(), "s1", 1);
    let emitter = make_emitter();
    let mut receiver = emitter.subscribe();
    let cancel = CancellationToken::new();
    let stream = stream_from_provider_events(vec![
        StreamEvent::Start,
        StreamEvent::TextDelta {
            delta: "must not be shown".into(),
        },
    ]);

    let failure = process_stream(stream, "s1", &emitter, &cancel, None, Some(&mut journal))
        .await
        .unwrap_err();

    assert!(matches!(failure.error, RuntimeError::Persistence(_)));
    assert!(failure.partial.message.content.is_empty());
    assert!(matches!(
        receiver.try_recv(),
        Err(tokio::sync::broadcast::error::TryRecvError::Empty)
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
    let result = process_stream(Box::pin(s), "s1", &emitter, &cancel, None, None)
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

    let result = process_stream(Box::pin(s), "s1", &emitter, &cancel, None, None)
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
    let result = process_stream(Box::pin(s), "s1", &emitter, &cancel, None, None).await;

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
    let result = process_stream(Box::pin(s), "s1", &emitter, &cancel, None, None)
        .await
        .unwrap();

    assert!(!result.interrupted);
    assert_eq!(result.stop_reason, "end_turn");
    assert!(result.tool_invocations.is_empty());
}

#[tokio::test]
async fn token_usage_extraction() {
    let emitter = make_emitter();
    let cancel = CancellationToken::new();

    let result = process_stream(text_stream("hello"), "s1", &emitter, &cancel, None, None)
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

    let _ = process_stream(text_stream("hello"), "s1", &emitter, &cancel, None, None)
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
async fn tool_invocation_generating_event_emitted() {
    let emitter = make_emitter();
    let mut rx = emitter.subscribe();
    let cancel = CancellationToken::new();

    let _ = process_stream(
        tool_invocation_stream(),
        "s1",
        &emitter,
        &cancel,
        None,
        None,
    )
    .await
    .unwrap();

    let mut saw_generating = false;
    while let Ok(event) = rx.try_recv() {
        if matches!(event, TronEvent::ToolInvocationGenerating { .. }) {
            saw_generating = true;
        }
    }
    assert!(saw_generating);
}
