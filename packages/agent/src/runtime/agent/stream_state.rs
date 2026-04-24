//! Stream accumulator state and event handlers.
//!
//! `StreamState` accumulates content blocks (text, thinking, tool calls) as
//! they arrive from the LLM stream. Two handler methods—`handle_normal_event`
//! and `handle_drain_event`—classify each `StreamEvent` into a `StreamAction`
//! that the caller (`process_stream`) uses to drive the select loop.
//!
//! Also contains pure helpers: `finalize_tool_call` (JSON argument parsing)
//! and `build_message` (assembles `AssistantMessage` from accumulators).

use std::collections::HashSet;
use std::sync::atomic::AtomicI64;
use std::time::Instant;

use serde_json::Map;

use crate::core::content::AssistantContent;
use crate::core::events::{AssistantMessage, BaseEvent, StreamEvent, TronEvent};
use crate::core::messages::{TokenUsage, ToolCall};

use crate::runtime::agent::event_emitter::EventEmitter;
use crate::runtime::errors::RuntimeError;
use crate::runtime::orchestrator::streaming_journal::StreamingJournal;

/// What `process_stream` should do after handling one event.
pub(super) enum StreamAction {
    /// Keep reading the stream.
    Continue,
    /// The stream completed (normally or via drain). Build the final result.
    Done {
        stop_reason: String,
        final_message: Option<AssistantMessage>,
    },
    /// An unrecoverable error occurred.
    Err(RuntimeError),
}

pub(super) struct StreamState {
    pub(super) text_acc: String,
    pub(super) thinking_acc: String,
    pub(super) tool_calls: Vec<ToolCall>,
    pub(super) current_tool_id: Option<String>,
    pub(super) current_tool_name: Option<String>,
    pub(super) current_tool_args: String,
    pub(super) token_usage: Option<TokenUsage>,
    pub(super) thinking_signature: Option<String>,
    pub(super) stream_start: Instant,
    pub(super) ttft_ms: Option<u64>,
    /// When true, skip all content events (text, thinking, tool calls) but keep
    /// reading the stream to capture token usage from the Done event.
    pub(super) draining: bool,
}

impl StreamState {
    pub(super) fn new() -> Self {
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
            draining: false,
        }
    }

    #[allow(clippy::cast_possible_truncation)]
    fn record_ttft(&mut self) {
        if self.ttft_ms.is_none() {
            self.ttft_ms = Some(self.stream_start.elapsed().as_millis() as u64);
        }
    }

    fn handle_text_delta(
        &mut self,
        delta: String,
        session_id: &str,
        emitter: &EventEmitter,
        counter: Option<&AtomicI64>,
    ) {
        self.record_ttft();
        self.text_acc.push_str(&delta);
        if let Some(counter) = counter {
            let _ = emitter.emit_sequenced(
                TronEvent::MessageUpdate {
                    base: BaseEvent::now(session_id),
                    content: delta,
                },
                counter,
            );
        } else {
            let _ = emitter.emit(TronEvent::MessageUpdate {
                base: BaseEvent::now(session_id),
                content: delta,
            });
        }
    }

    fn handle_thinking_delta(
        &mut self,
        delta: String,
        session_id: &str,
        emitter: &EventEmitter,
        counter: Option<&AtomicI64>,
    ) {
        self.record_ttft();
        self.thinking_acc.push_str(&delta);
        if let Some(counter) = counter {
            let _ = emitter.emit_sequenced(
                TronEvent::ThinkingDelta {
                    base: BaseEvent::now(session_id),
                    delta,
                },
                counter,
            );
        } else {
            let _ = emitter.emit(TronEvent::ThinkingDelta {
                base: BaseEvent::now(session_id),
                delta,
            });
        }
    }

    fn handle_thinking_end(
        &mut self,
        thinking: String,
        signature: Option<String>,
        session_id: &str,
        emitter: &EventEmitter,
        counter: Option<&AtomicI64>,
    ) {
        self.thinking_acc.clone_from(&thinking);
        self.thinking_signature = signature;
        if let Some(counter) = counter {
            let _ = emitter.emit_sequenced(
                TronEvent::ThinkingEnd {
                    base: BaseEvent::now(session_id),
                    thinking,
                },
                counter,
            );
        } else {
            let _ = emitter.emit(TronEvent::ThinkingEnd {
                base: BaseEvent::now(session_id),
                thinking,
            });
        }
    }

    fn handle_tool_call_start(
        &mut self,
        tool_call_id: String,
        name: String,
        session_id: &str,
        emitter: &EventEmitter,
        counter: Option<&AtomicI64>,
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

        if let Some(counter) = counter {
            let _ = emitter.emit_sequenced(
                TronEvent::ToolCallGenerating {
                    base: BaseEvent::now(session_id),
                    tool_call_id,
                    tool_name: name,
                },
                counter,
            );
        } else {
            let _ = emitter.emit(TronEvent::ToolCallGenerating {
                base: BaseEvent::now(session_id),
                tool_call_id,
                tool_name: name,
            });
        }
    }

    fn handle_tool_call_delta(
        &mut self,
        tool_call_id: String,
        arguments_delta: String,
        session_id: &str,
        emitter: &EventEmitter,
        counter: Option<&AtomicI64>,
    ) {
        self.current_tool_args.push_str(&arguments_delta);
        if let Some(counter) = counter {
            let _ = emitter.emit_sequenced(
                TronEvent::ToolCallArgumentDelta {
                    base: BaseEvent::now(session_id),
                    tool_call_id,
                    tool_name: self.current_tool_name.clone(),
                    arguments_delta,
                },
                counter,
            );
        } else {
            let _ = emitter.emit(TronEvent::ToolCallArgumentDelta {
                base: BaseEvent::now(session_id),
                tool_call_id,
                tool_name: self.current_tool_name.clone(),
                arguments_delta,
            });
        }
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

    pub(super) fn build_interrupted_result(self) -> crate::runtime::types::StreamResult {
        let partial = if self.text_acc.is_empty() {
            None
        } else {
            Some(self.text_acc.clone())
        };
        crate::runtime::types::StreamResult {
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

    pub(super) fn finalize_stream_result(
        mut self,
        final_message: Option<AssistantMessage>,
        stop_reason: String,
    ) -> crate::runtime::types::StreamResult {
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

        crate::runtime::types::StreamResult {
            message,
            tool_calls: self.tool_calls,
            stop_reason,
            token_usage: self.token_usage,
            interrupted: false,
            partial_content: None,
            ttft_ms: self.ttft_ms,
        }
    }

    /// Handle a stream event while in drain mode (after a stopping tool completed).
    ///
    /// Only Done, Error, SafetyBlock, and Retry are processed; all content events
    /// are skipped. Token usage is captured from Done but the message is discarded
    /// (it contains post-drain content we don't want).
    pub(super) fn handle_drain_event(
        &mut self,
        stream_event: StreamEvent,
        session_id: &str,
        emitter: &EventEmitter,
        sequence_counter: Option<&AtomicI64>,
    ) -> StreamAction {
        match stream_event {
            StreamEvent::Done { message, .. } => {
                self.token_usage.clone_from(&message.token_usage);
                StreamAction::Done {
                    stop_reason: "tool_use".into(),
                    final_message: None,
                }
            }
            StreamEvent::Error { error } => StreamAction::Err(RuntimeError::Internal(error)),
            StreamEvent::SafetyBlock {
                blocked_categories,
                error,
            } => StreamAction::Err(RuntimeError::Internal(format!(
                "Safety block: {error} (categories: {})",
                blocked_categories.join(", ")
            ))),
            StreamEvent::Retry {
                attempt,
                max_retries,
                delay_ms,
                error,
            } => {
                if let Some(counter) = sequence_counter {
                    let _ = emitter.emit_sequenced(
                        TronEvent::ApiRetry {
                            base: BaseEvent::now(session_id),
                            attempt,
                            max_retries,
                            delay_ms,
                            error_category: error.category,
                            error_message: error.message,
                        },
                        counter,
                    );
                } else {
                    let _ = emitter.emit(TronEvent::ApiRetry {
                        base: BaseEvent::now(session_id),
                        attempt,
                        max_retries,
                        delay_ms,
                        error_category: error.category,
                        error_message: error.message,
                    });
                }
                StreamAction::Continue
            }
            _ => StreamAction::Continue, // Skip all content events
        }
    }

    /// Handle a stream event during normal (non-drain) processing.
    ///
    /// Accumulates text, thinking, and tool call content. When a tool in
    /// `turn_stopping_tools` completes, sets `self.draining = true` so the
    /// caller switches to `handle_drain_event` on subsequent events.
    pub(super) fn handle_normal_event(
        &mut self,
        stream_event: StreamEvent,
        session_id: &str,
        emitter: &EventEmitter,
        sequence_counter: Option<&AtomicI64>,
        turn_stopping_tools: &HashSet<String>,
        journal: &mut Option<&mut StreamingJournal>,
    ) -> StreamAction {
        match stream_event {
            StreamEvent::TextDelta { delta } => {
                if let Some(j) = journal {
                    if let Err(e) = j.append_delta("text", &delta) {
                        tracing::warn!(session_id, error = %e, "journal write failed for text delta");
                    }
                }
                self.handle_text_delta(delta, session_id, emitter, sequence_counter);
            }

            StreamEvent::Start | StreamEvent::TextStart | StreamEvent::TextEnd { .. } => {}

            StreamEvent::ThinkingStart => {
                tracing::debug!(session_id, "stream_state: received ThinkingStart");
                if let Some(counter) = sequence_counter {
                    let _ = emitter.emit_sequenced(
                        TronEvent::ThinkingStart {
                            base: BaseEvent::now(session_id),
                        },
                        counter,
                    );
                } else {
                    let _ = emitter.emit(TronEvent::ThinkingStart {
                        base: BaseEvent::now(session_id),
                    });
                }
            }

            StreamEvent::ThinkingDelta { delta } => {
                if let Some(j) = journal {
                    if let Err(e) = j.append_delta("thinking", &delta) {
                        tracing::warn!(session_id, error = %e, "journal write failed for thinking delta");
                    }
                }
                self.handle_thinking_delta(delta, session_id, emitter, sequence_counter);
            }

            StreamEvent::ThinkingEnd {
                thinking,
                signature,
            } => {
                tracing::debug!(
                    session_id,
                    thinking_len = thinking.len(),
                    "stream_state: received ThinkingEnd"
                );
                self.handle_thinking_end(
                    thinking,
                    signature,
                    session_id,
                    emitter,
                    sequence_counter,
                );
            }

            StreamEvent::ToolCallStart { tool_call_id, name } => {
                self.handle_tool_call_start(
                    tool_call_id,
                    name,
                    session_id,
                    emitter,
                    sequence_counter,
                );
            }

            StreamEvent::ToolCallDelta {
                tool_call_id,
                arguments_delta,
            } => {
                self.handle_tool_call_delta(
                    tool_call_id,
                    arguments_delta,
                    session_id,
                    emitter,
                    sequence_counter,
                );
            }

            StreamEvent::ToolCallEnd { tool_call } => {
                if let Some(j) = journal {
                    if let Ok(serialized) = serde_json::to_string(&tool_call) {
                        if let Err(e) = j.append_delta("tool_use", &serialized) {
                            tracing::warn!(session_id, error = %e, "journal write failed for tool call");
                        }
                    }
                }
                let name = tool_call.name.clone();
                self.handle_tool_call_end(tool_call);
                if turn_stopping_tools.contains(&name) {
                    self.draining = true;
                }
            }

            StreamEvent::Done {
                message,
                stop_reason: sr,
            } => {
                self.token_usage.clone_from(&message.token_usage);
                return StreamAction::Done {
                    stop_reason: sr,
                    final_message: Some(message),
                };
            }

            StreamEvent::Error { error } => {
                return StreamAction::Err(RuntimeError::Internal(error));
            }

            StreamEvent::Retry {
                attempt,
                max_retries,
                delay_ms,
                error,
            } => {
                if let Some(counter) = sequence_counter {
                    let _ = emitter.emit_sequenced(
                        TronEvent::ApiRetry {
                            base: BaseEvent::now(session_id),
                            attempt,
                            max_retries,
                            delay_ms,
                            error_category: error.category,
                            error_message: error.message,
                        },
                        counter,
                    );
                } else {
                    let _ = emitter.emit(TronEvent::ApiRetry {
                        base: BaseEvent::now(session_id),
                        attempt,
                        max_retries,
                        delay_ms,
                        error_category: error.category,
                        error_message: error.message,
                    });
                }
            }

            StreamEvent::SafetyBlock {
                blocked_categories,
                error,
            } => {
                return StreamAction::Err(RuntimeError::Internal(format!(
                    "Safety block: {error} (categories: {})",
                    blocked_categories.join(", ")
                )));
            }
        }
        StreamAction::Continue
    }
}

/// Finalize an in-progress tool call from accumulated deltas.
pub(super) fn finalize_tool_call(
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
pub(super) fn build_message(
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
