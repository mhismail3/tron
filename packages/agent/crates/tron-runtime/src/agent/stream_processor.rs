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

struct StreamState {
    text_acc: String,
    thinking_acc: String,
    tool_calls: Vec<ToolCall>,
    current_tool_id: Option<String>,
    current_tool_name: Option<String>,
    current_tool_args: String,
    token_usage: Option<TokenUsage>,
    thinking_signature: Option<String>,
    stream_start: Instant,
    ttft_ms: Option<u64>,
}

impl StreamState {
    fn new() -> Self {
        Self {
            text_acc: String::with_capacity(4096),
            thinking_acc: String::with_capacity(2048),
            tool_calls: Vec::with_capacity(4),
            current_tool_id: None,
            current_tool_name: None,
            current_tool_args: String::with_capacity(512),
            token_usage: None,
            thinking_signature: None,
            stream_start: Instant::now(),
            ttft_ms: None,
        }
    }

    #[allow(clippy::cast_possible_truncation)]
    fn record_ttft(&mut self) {
        if self.ttft_ms.is_none() {
            self.ttft_ms = Some(self.stream_start.elapsed().as_millis() as u64);
        }
    }

    fn handle_text_delta(&mut self, delta: String, session_id: &str, emitter: &EventEmitter) {
        self.record_ttft();
        self.text_acc.push_str(&delta);
        let _ = emitter.emit(TronEvent::MessageUpdate {
            base: BaseEvent::now(session_id),
            content: delta,
        });
    }

    fn handle_thinking_delta(&mut self, delta: String, session_id: &str, emitter: &EventEmitter) {
        self.record_ttft();
        self.thinking_acc.push_str(&delta);
        let _ = emitter.emit(TronEvent::ThinkingDelta {
            base: BaseEvent::now(session_id),
            delta,
        });
    }

    fn handle_thinking_end(
        &mut self,
        thinking: String,
        signature: Option<String>,
        session_id: &str,
        emitter: &EventEmitter,
    ) {
        self.thinking_acc.clone_from(&thinking);
        self.thinking_signature = signature;
        let _ = emitter.emit(TronEvent::ThinkingEnd {
            base: BaseEvent::now(session_id),
            thinking,
        });
    }

    fn handle_tool_call_start(
        &mut self,
        tool_call_id: String,
        name: String,
        session_id: &str,
        emitter: &EventEmitter,
    ) {
        finalize_tool_call(
            &mut self.tool_calls,
            &mut self.current_tool_id,
            &mut self.current_tool_name,
            &mut self.current_tool_args,
        );

        self.current_tool_id = Some(tool_call_id.clone());
        self.current_tool_name = Some(name.clone());
        self.current_tool_args.clear();

        let _ = emitter.emit(TronEvent::ToolCallGenerating {
            base: BaseEvent::now(session_id),
            tool_call_id,
            tool_name: name,
        });
    }

    fn handle_tool_call_delta(
        &mut self,
        tool_call_id: String,
        arguments_delta: String,
        session_id: &str,
        emitter: &EventEmitter,
    ) {
        self.current_tool_args.push_str(&arguments_delta);
        let _ = emitter.emit(TronEvent::ToolCallArgumentDelta {
            base: BaseEvent::now(session_id),
            tool_call_id,
            tool_name: self.current_tool_name.clone(),
            arguments_delta,
        });
    }

    fn handle_tool_call_end(&mut self, tool_call: ToolCall) {
        self.current_tool_id = None;
        self.current_tool_name = None;
        self.current_tool_args.clear();
        if let Some(pos) = self.tool_calls.iter().position(|tc| tc.id == tool_call.id) {
            self.tool_calls[pos] = tool_call;
        } else {
            self.tool_calls.push(tool_call);
        }
    }

    fn build_interrupted_result(self) -> StreamResult {
        let partial = if self.text_acc.is_empty() {
            None
        } else {
            Some(self.text_acc.clone())
        };
        StreamResult {
            message: build_message(
                &self.text_acc,
                &self.thinking_acc,
                self.thinking_signature.as_deref(),
                &self.tool_calls,
            ),
            tool_calls: self.tool_calls,
            stop_reason: "interrupted".into(),
            token_usage: self.token_usage,
            interrupted: true,
            partial_content: partial,
            ttft_ms: self.ttft_ms,
        }
    }

    fn finalize_stream_result(
        mut self,
        final_message: Option<AssistantMessage>,
        stop_reason: String,
    ) -> StreamResult {
        finalize_tool_call(
            &mut self.tool_calls,
            &mut self.current_tool_id,
            &mut self.current_tool_name,
            &mut self.current_tool_args,
        );

        let message = final_message.unwrap_or_else(|| {
            build_message(
                &self.text_acc,
                &self.thinking_acc,
                self.thinking_signature.as_deref(),
                &self.tool_calls,
            )
        });

        StreamResult {
            message,
            tool_calls: self.tool_calls,
            stop_reason,
            token_usage: self.token_usage,
            interrupted: false,
            partial_content: None,
            ttft_ms: self.ttft_ms,
        }
    }
}

/// Process an LLM stream, accumulating content and emitting events.
pub async fn process_stream(
    mut stream: StreamEventStream,
    session_id: &str,
    emitter: &Arc<EventEmitter>,
    cancel: &CancellationToken,
) -> Result<StreamResult, RuntimeError> {
    let mut state = StreamState::new();
    #[allow(unused_assignments)]
    let mut stop_reason = String::new();
    #[allow(unused_assignments)]
    let mut final_message: Option<AssistantMessage> = None;

    loop {
        // biased: prefer cancellation when both a stream event and cancel are ready
        let event = tokio::select! {
            biased;
            () = cancel.cancelled() => {
                return Ok(state.build_interrupted_result());
            }
            event = stream.next() => event,
        };

        match event {
            None => {
                return Err(RuntimeError::Internal(
                    "Stream ended without Done event".into(),
                ));
            }
            Some(Err(ProviderError::Cancelled)) => {
                return Ok(state.build_interrupted_result());
            }
            Some(Err(e)) => {
                return Err(RuntimeError::Provider(e));
            }
            Some(Ok(stream_event)) => match stream_event {
                StreamEvent::TextDelta { delta } => {
                    state.handle_text_delta(delta, session_id, emitter);
                }

                StreamEvent::Start | StreamEvent::TextStart | StreamEvent::TextEnd { .. } => {}

                StreamEvent::ThinkingStart => {
                    let _ = emitter.emit(TronEvent::ThinkingStart {
                        base: BaseEvent::now(session_id),
                    });
                }

                StreamEvent::ThinkingDelta { delta } => {
                    state.handle_thinking_delta(delta, session_id, emitter);
                }

                StreamEvent::ThinkingEnd {
                    thinking,
                    signature,
                } => {
                    state.handle_thinking_end(thinking, signature, session_id, emitter);
                }

                StreamEvent::ToolCallStart { tool_call_id, name } => {
                    state.handle_tool_call_start(tool_call_id, name, session_id, emitter);
                }

                StreamEvent::ToolCallDelta {
                    tool_call_id,
                    arguments_delta,
                } => {
                    state.handle_tool_call_delta(
                        tool_call_id,
                        arguments_delta,
                        session_id,
                        emitter,
                    );
                }

                StreamEvent::ToolCallEnd { tool_call } => {
                    state.handle_tool_call_end(tool_call);
                }

                StreamEvent::Done {
                    message,
                    stop_reason: sr,
                } => {
                    stop_reason = sr;
                    state.token_usage.clone_from(&message.token_usage);
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
            },
        }
    }

    Ok(state.finalize_stream_result(final_message, stop_reason))
}

/// Finalize an in-progress tool call from accumulated deltas.
fn finalize_tool_call(
    tool_calls: &mut Vec<ToolCall>,
    current_id: &mut Option<String>,
    current_name: &mut Option<String>,
    current_args: &mut String,
) {
    if let (Some(id), Some(name)) = (current_id.take(), current_name.take()) {
        let arguments: Map<String, serde_json::Value> = match serde_json::from_str(current_args) {
            Ok(map) => map,
            Err(e) => {
                let preview: String = current_args.chars().take(200).collect();
                tracing::warn!(
                    tool_name = %name,
                    tool_call_id = %id,
                    error = %e,
                    args_preview = %preview,
                    "malformed tool call arguments, using empty map"
                );
                Map::new()
            }
        };
        if let Some(pos) = tool_calls.iter().position(|tc| tc.id == id) {
            tool_calls[pos] = ToolCall::new(id, name, arguments);
        } else {
            tool_calls.push(ToolCall::new(id, name, arguments));
        }
        current_args.clear();
    }
}

/// Build an `AssistantMessage` from accumulated parts.
fn build_message(
    text: &str,
    thinking: &str,
    thinking_signature: Option<&str>,
    tool_calls: &[ToolCall],
) -> AssistantMessage {
    let mut content: Vec<AssistantContent> = Vec::with_capacity(3);

    if !thinking.is_empty() {
        content.push(AssistantContent::Thinking {
            thinking: thinking.to_owned(),
            signature: thinking_signature.map(String::from),
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
                tool_call: ToolCall::new("tc-1", "bash", {
                    let mut m = Map::new();
                    let _ = m.insert("command".into(), serde_json::json!("ls"));
                    m
                }),
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
                tool_call: ToolCall::new("tc-1", "read", Map::new()),
            });
            yield Ok(StreamEvent::ToolCallStart { tool_call_id: "tc-2".into(), name: "write".into() });
            yield Ok(StreamEvent::ToolCallEnd {
                tool_call: ToolCall::new("tc-2", "write", Map::new()),
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

    #[tokio::test]
    async fn duplicate_tool_calls_deduped_by_id() {
        let s = stream! {
            yield Ok(StreamEvent::Start);
            // First occurrence — empty/malformed args
            yield Ok(StreamEvent::ToolCallStart { tool_call_id: "tc-dup".into(), name: "bash".into() });
            yield Ok(StreamEvent::ToolCallDelta { tool_call_id: "tc-dup".into(), arguments_delta: "{}".into() });
            // Second occurrence — valid args (replaces via ToolCallEnd dedup)
            yield Ok(StreamEvent::ToolCallStart { tool_call_id: "tc-dup".into(), name: "bash".into() });
            yield Ok(StreamEvent::ToolCallEnd {
                tool_call: ToolCall::new("tc-dup", "bash", {
                    let mut m = Map::new();
                    let _ = m.insert("command".into(), serde_json::json!("ls"));
                    m
                }),
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

        assert_eq!(result.tool_calls.len(), 1, "duplicate tool calls should be deduped");
        assert_eq!(result.tool_calls[0].id, "tc-dup");
        assert_eq!(result.tool_calls[0].arguments["command"], serde_json::json!("ls"));
    }

    // -- finalize_tool_call unit tests --

    #[test]
    fn finalize_tool_call_with_valid_json() {
        let mut tool_calls = Vec::new();
        let mut id = Some("tc-1".to_string());
        let mut name = Some("bash".to_string());
        let mut args = r#"{"command":"ls"}"#.to_string();

        finalize_tool_call(&mut tool_calls, &mut id, &mut name, &mut args);

        assert_eq!(tool_calls.len(), 1);
        assert_eq!(tool_calls[0].name, "bash");
        assert_eq!(tool_calls[0].id, "tc-1");
        assert_eq!(tool_calls[0].arguments["command"], serde_json::json!("ls"));
    }

    #[test]
    fn finalize_tool_call_with_malformed_json() {
        let mut tool_calls = Vec::new();
        let mut id = Some("tc-2".to_string());
        let mut name = Some("read".to_string());
        let mut args = "{ not valid".to_string();

        finalize_tool_call(&mut tool_calls, &mut id, &mut name, &mut args);

        assert_eq!(tool_calls.len(), 1);
        assert_eq!(tool_calls[0].name, "read");
        assert_eq!(tool_calls[0].id, "tc-2");
        assert!(tool_calls[0].arguments.is_empty());
    }

    #[test]
    fn finalize_tool_call_with_empty_string() {
        let mut tool_calls = Vec::new();
        let mut id = Some("tc-3".to_string());
        let mut name = Some("write".to_string());
        let mut args = String::new();

        finalize_tool_call(&mut tool_calls, &mut id, &mut name, &mut args);

        assert_eq!(tool_calls.len(), 1);
        assert_eq!(tool_calls[0].name, "write");
        assert!(tool_calls[0].arguments.is_empty());
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
        let result = process_stream(Box::pin(s), "s1", &emitter, &cancel)
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
}
