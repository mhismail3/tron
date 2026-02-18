//! Stream processor — consumes `StreamEventStream`, accumulates content blocks.

use std::sync::Arc;
use std::time::Instant;

use futures::StreamExt;
use serde_json::Map;
use tokio_util::sync::CancellationToken;
use tron_core::content::AssistantContent;
use tron_core::events::{AssistantMessage, BaseEvent, StreamEvent, TronEvent};
use tron_core::messages::{TokenUsage, ToolCall};

use crate::agent::event_emitter::EventEmitter;
use crate::errors::RuntimeError;
use crate::types::StreamResult;
use tron_llm::provider::{ProviderError, StreamEventStream};

/// Process an LLM stream, accumulating content and emitting events.
#[allow(clippy::too_many_lines, clippy::cast_possible_truncation)]
pub async fn process_stream(
    mut stream: StreamEventStream,
    session_id: &str,
    emitter: &Arc<EventEmitter>,
    cancel: &CancellationToken,
) -> Result<StreamResult, RuntimeError> {
    let mut text_acc = String::with_capacity(4096);
    let mut thinking_acc = String::with_capacity(2048);
    let mut tool_calls: Vec<ToolCall> = Vec::with_capacity(4);
    let mut current_tool_id: Option<String> = None;
    let mut current_tool_name: Option<String> = None;
    let mut current_tool_args = String::with_capacity(512);
    let mut token_usage: Option<TokenUsage> = None;
    #[allow(unused_assignments)]
    let mut stop_reason = String::new();
    #[allow(unused_assignments)]
    let mut final_message: Option<AssistantMessage> = None;
    let mut thinking_signature: Option<String> = None;
    let stream_start = Instant::now();
    let mut ttft_ms: Option<u64> = None;

    loop {
        // biased: prefer cancellation when both a stream event and cancel are ready
        let event = tokio::select! {
            biased;
            () = cancel.cancelled() => {
                let partial = if text_acc.is_empty() { None } else { Some(text_acc.clone()) };
                return Ok(StreamResult {
                    message: build_message(&text_acc, &thinking_acc, thinking_signature.as_deref(), &tool_calls),
                    tool_calls,
                    stop_reason: "interrupted".into(),
                    token_usage,
                    interrupted: true,
                    partial_content: partial,
                    ttft_ms,
                });
            }
            event = stream.next() => event,
        };

        match event {
            None => {
                // Stream ended without Done — treat as error
                return Err(RuntimeError::Internal(
                    "Stream ended without Done event".into(),
                ));
            }
            Some(Err(ProviderError::Cancelled)) => {
                let partial = if text_acc.is_empty() {
                    None
                } else {
                    Some(text_acc.clone())
                };
                return Ok(StreamResult {
                    message: build_message(
                        &text_acc,
                        &thinking_acc,
                        thinking_signature.as_deref(),
                        &tool_calls,
                    ),
                    tool_calls,
                    stop_reason: "interrupted".into(),
                    token_usage,
                    interrupted: true,
                    partial_content: partial,
                    ttft_ms,
                });
            }
            Some(Err(e)) => {
                return Err(RuntimeError::Provider(e));
            }
            Some(Ok(stream_event)) => {
                match stream_event {
                    StreamEvent::TextDelta { delta } => {
                        if ttft_ms.is_none() {
                            ttft_ms = Some(stream_start.elapsed().as_millis() as u64);
                        }
                        text_acc.push_str(&delta);
                        let _ = emitter.emit(TronEvent::MessageUpdate {
                            base: BaseEvent::now(session_id),
                            content: delta,
                        });
                    }

                    StreamEvent::Start | StreamEvent::TextStart | StreamEvent::TextEnd { .. } => {}

                    StreamEvent::ThinkingStart => {
                        let _ = emitter.emit(TronEvent::ThinkingStart {
                            base: BaseEvent::now(session_id),
                        });
                    }

                    StreamEvent::ThinkingDelta { delta } => {
                        if ttft_ms.is_none() {
                            ttft_ms = Some(stream_start.elapsed().as_millis() as u64);
                        }
                        thinking_acc.push_str(&delta);
                        let _ = emitter.emit(TronEvent::ThinkingDelta {
                            base: BaseEvent::now(session_id),
                            delta,
                        });
                    }

                    StreamEvent::ThinkingEnd {
                        thinking,
                        signature,
                    } => {
                        thinking_acc.clone_from(&thinking);
                        thinking_signature = signature;
                        let _ = emitter.emit(TronEvent::ThinkingEnd {
                            base: BaseEvent::now(session_id),
                            thinking,
                        });
                    }

                    StreamEvent::ToolCallStart { tool_call_id, name } => {
                        // Finalize any previous in-progress tool call
                        finalize_tool_call(
                            &mut tool_calls,
                            &mut current_tool_id,
                            &mut current_tool_name,
                            &mut current_tool_args,
                        );

                        current_tool_id = Some(tool_call_id.clone());
                        current_tool_name = Some(name.clone());
                        current_tool_args.clear();

                        let _ = emitter.emit(TronEvent::ToolCallGenerating {
                            base: BaseEvent::now(session_id),
                            tool_call_id,
                            tool_name: name,
                        });
                    }

                    StreamEvent::ToolCallDelta {
                        tool_call_id,
                        arguments_delta,
                    } => {
                        current_tool_args.push_str(&arguments_delta);
                        let _ = emitter.emit(TronEvent::ToolCallArgumentDelta {
                            base: BaseEvent::now(session_id),
                            tool_call_id,
                            tool_name: current_tool_name.clone(),
                            arguments_delta,
                        });
                    }

                    StreamEvent::ToolCallEnd { tool_call } => {
                        // Use the provider-parsed tool call directly
                        current_tool_id = None;
                        current_tool_name = None;
                        current_tool_args.clear();
                        tool_calls.push(tool_call);
                    }

                    StreamEvent::Done {
                        message,
                        stop_reason: sr,
                    } => {
                        stop_reason = sr;
                        token_usage.clone_from(&message.token_usage);
                        final_message = Some(message);
                        break;
                    }

                    StreamEvent::Error { error } => {
                        return Err(RuntimeError::Internal(error));
                    }

                    StreamEvent::Retry {
                        attempt,
                        max_retries,
                        delay_ms,
                        error,
                    } => {
                        let _ = emitter.emit(TronEvent::ApiRetry {
                            base: BaseEvent::now(session_id),
                            attempt,
                            max_retries,
                            delay_ms,
                            error_category: error.category,
                            error_message: error.message,
                        });
                    }

                    StreamEvent::SafetyBlock {
                        blocked_categories,
                        error,
                    } => {
                        return Err(RuntimeError::Internal(format!(
                            "Safety block: {error} (categories: {})",
                            blocked_categories.join(", ")
                        )));
                    }
                }
            }
        }
    }

    // Finalize any trailing tool call
    finalize_tool_call(
        &mut tool_calls,
        &mut current_tool_id,
        &mut current_tool_name,
        &mut current_tool_args,
    );

    let message = final_message.unwrap_or_else(|| {
        build_message(
            &text_acc,
            &thinking_acc,
            thinking_signature.as_deref(),
            &tool_calls,
        )
    });

    Ok(StreamResult {
        message,
        tool_calls,
        stop_reason,
        token_usage,
        interrupted: false,
        partial_content: None,
        ttft_ms,
    })
}

/// Finalize an in-progress tool call from accumulated deltas.
fn finalize_tool_call(
    tool_calls: &mut Vec<ToolCall>,
    current_id: &mut Option<String>,
    current_name: &mut Option<String>,
    current_args: &mut String,
) {
    if let (Some(id), Some(name)) = (current_id.take(), current_name.take()) {
        let arguments: Map<String, serde_json::Value> =
            serde_json::from_str(current_args).unwrap_or_default();
        tool_calls.push(ToolCall {
            content_type: "tool_use".into(),
            id,
            name,
            arguments,
            thought_signature: None,
        });
        current_args.clear();
    }
}

/// Build an `AssistantMessage` from accumulated parts.
fn build_message(
    text: &str,
    thinking: &str,
    _thinking_signature: Option<&str>,
    tool_calls: &[ToolCall],
) -> AssistantMessage {
    let mut content: Vec<AssistantContent> = Vec::with_capacity(3);

    if !thinking.is_empty() {
        content.push(AssistantContent::Thinking {
            thinking: thinking.to_owned(),
            signature: None,
        });
    }

    if !text.is_empty() {
        let trimmed = text.trim_end();
        if !trimmed.is_empty() {
            content.push(AssistantContent::text(trimmed));
        }
    }

    for tc in tool_calls {
        content.push(AssistantContent::ToolUse {
            id: tc.id.clone(),
            name: tc.name.clone(),
            arguments: tc.arguments.clone(),
            thought_signature: tc.thought_signature.clone(),
        });
    }

    AssistantMessage {
        content,
        token_usage: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_stream::stream;
    use std::pin::Pin;
    use tron_core::events::RetryErrorInfo;

    fn make_emitter() -> Arc<EventEmitter> {
        Arc::new(EventEmitter::new())
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
        Box::pin(s)
            as Pin<Box<dyn futures::Stream<Item = Result<StreamEvent, ProviderError>> + Send>>
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

    fn tool_call_stream() -> StreamEventStream {
        let mut args = Map::new();
        let _ = args.insert("command".into(), serde_json::json!("ls"));
        let s = stream! {
            yield Ok(StreamEvent::Start);
            yield Ok(StreamEvent::TextStart);
            yield Ok(StreamEvent::TextDelta { delta: "Running:".into() });
            yield Ok(StreamEvent::TextEnd { text: "Running:".into(), signature: None });
            yield Ok(StreamEvent::ToolCallStart { tool_call_id: "tc-1".into(), name: "bash".into() });
            yield Ok(StreamEvent::ToolCallDelta { tool_call_id: "tc-1".into(), arguments_delta: r#"{"command":"ls"}"#.into() });
            yield Ok(StreamEvent::ToolCallEnd {
                tool_call: ToolCall {
                    content_type: "tool_use".into(),
                    id: "tc-1".into(),
                    name: "bash".into(),
                    arguments: {
                        let mut m = Map::new();
                        let _ = m.insert("command".into(), serde_json::json!("ls"));
                        m
                    },
                    thought_signature: None,
                },
            });
            yield Ok(StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![
                        AssistantContent::text("Running:"),
                        AssistantContent::ToolUse {
                            id: "tc-1".into(),
                            name: "bash".into(),
                            arguments: {
                                let mut m = Map::new();
                                let _ = m.insert("command".into(), serde_json::json!("ls"));
                                m
                            },
                            thought_signature: None,
                        },
                    ],
                    token_usage: Some(TokenUsage { input_tokens: 50, output_tokens: 30, ..Default::default() }),
                },
                stop_reason: "tool_use".into(),
            });
        };
        Box::pin(s)
    }

    #[tokio::test]
    async fn pure_text_response() {
        let emitter = make_emitter();
        let cancel = CancellationToken::new();

        let result = process_stream(text_stream("hello world"), "s1", &emitter, &cancel)
            .await
            .unwrap();

        assert!(!result.interrupted);
        assert_eq!(result.stop_reason, "end_turn");
        assert!(result.partial_content.is_none());
        assert!(result.tool_calls.is_empty());
        assert!(result.token_usage.is_some());
        assert_eq!(result.token_usage.as_ref().unwrap().input_tokens, 10);
    }

    #[tokio::test]
    async fn thinking_plus_text_response() {
        let emitter = make_emitter();
        let mut rx = emitter.subscribe();
        let cancel = CancellationToken::new();

        let result = process_stream(thinking_then_text_stream(), "s1", &emitter, &cancel)
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
    async fn text_plus_tool_call() {
        let emitter = make_emitter();
        let cancel = CancellationToken::new();

        let result = process_stream(tool_call_stream(), "s1", &emitter, &cancel)
            .await
            .unwrap();

        assert_eq!(result.stop_reason, "tool_use");
        assert_eq!(result.tool_calls.len(), 1);
        assert_eq!(result.tool_calls[0].name, "bash");
        assert_eq!(
            result.tool_calls[0].arguments["command"],
            serde_json::json!("ls")
        );
    }

    #[tokio::test]
    async fn multiple_tool_calls() {
        let s = stream! {
            yield Ok(StreamEvent::Start);
            yield Ok(StreamEvent::ToolCallStart { tool_call_id: "tc-1".into(), name: "read".into() });
            yield Ok(StreamEvent::ToolCallEnd {
                tool_call: ToolCall {
                    content_type: "tool_use".into(),
                    id: "tc-1".into(), name: "read".into(),
                    arguments: Map::new(), thought_signature: None,
                },
            });
            yield Ok(StreamEvent::ToolCallStart { tool_call_id: "tc-2".into(), name: "write".into() });
            yield Ok(StreamEvent::ToolCallEnd {
                tool_call: ToolCall {
                    content_type: "tool_use".into(),
                    id: "tc-2".into(), name: "write".into(),
                    arguments: Map::new(), thought_signature: None,
                },
            });
            yield Ok(StreamEvent::Done {
                message: AssistantMessage { content: vec![], token_usage: None },
                stop_reason: "tool_use".into(),
            });
        };

        let emitter = make_emitter();
        let cancel = CancellationToken::new();
        let result = process_stream(Box::pin(s), "s1", &emitter, &cancel)
            .await
            .unwrap();

        assert_eq!(result.tool_calls.len(), 2);
        assert_eq!(result.tool_calls[0].name, "read");
        assert_eq!(result.tool_calls[1].name, "write");
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
        let result = process_stream(Box::pin(s), "s1", &emitter, &cancel).await;

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
        let result = process_stream(Box::pin(s), "s1", &emitter, &cancel)
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

        let result = process_stream(Box::pin(s), "s1", &emitter, &cancel)
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
        let result = process_stream(Box::pin(s), "s1", &emitter, &cancel).await;

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
        let result = process_stream(Box::pin(s), "s1", &emitter, &cancel)
            .await
            .unwrap();

        assert!(!result.interrupted);
        assert_eq!(result.stop_reason, "end_turn");
        assert!(result.tool_calls.is_empty());
    }

    #[tokio::test]
    async fn token_usage_extraction() {
        let emitter = make_emitter();
        let cancel = CancellationToken::new();

        let result = process_stream(text_stream("hello"), "s1", &emitter, &cancel)
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

        let _ = process_stream(text_stream("hello"), "s1", &emitter, &cancel)
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
    async fn tool_call_generating_event_emitted() {
        let emitter = make_emitter();
        let mut rx = emitter.subscribe();
        let cancel = CancellationToken::new();

        let _ = process_stream(tool_call_stream(), "s1", &emitter, &cancel)
            .await
            .unwrap();

        let mut saw_generating = false;
        while let Ok(event) = rx.try_recv() {
            if matches!(event, TronEvent::ToolCallGenerating { .. }) {
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
}
