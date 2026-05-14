//! Stream accumulator state and event handlers.
//!
//! `StreamState` accumulates content blocks (text, thinking, capability invocations) as
//! they arrive from the LLM stream. Two handler methods—`handle_normal_event`
//! and `handle_drain_event`—classify each `StreamEvent` into a `StreamAction`
//! that the caller (`process_stream`) uses to drive the select loop.
//!
//! Also contains pure helpers: `finalize_capability_invocation` (JSON argument parsing)
//! and `build_message` (assembles `AssistantMessage` from accumulators).

use std::collections::HashSet;
use std::sync::atomic::AtomicI64;
use std::time::Instant;

use serde_json::Map;

use crate::engine::{InvocationId, TraceId};
use crate::shared::content::AssistantContent;
use crate::shared::events::{AssistantMessage, BaseEvent, StreamEvent, TronEvent};
use crate::shared::messages::{CapabilityInvocationDraft, TokenUsage};

use crate::domains::agent::runner::agent::event_emitter::EventEmitter;
use crate::domains::agent::runner::errors::RuntimeError;
use crate::domains::agent::runner::orchestrator::streaming_journal::StreamingJournal;

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

#[derive(Clone, Copy, Default)]
pub(super) struct StreamTraceContext<'a> {
    pub(super) trace_id: Option<&'a TraceId>,
    pub(super) parent_invocation_id: Option<&'a InvocationId>,
}

impl StreamTraceContext<'_> {
    fn base_event(&self, session_id: &str) -> BaseEvent {
        BaseEvent::now(session_id).with_trace_context(
            self.trace_id.map(|id| id.as_str().to_owned()),
            self.parent_invocation_id.map(|id| id.as_str().to_owned()),
        )
    }
}

pub(super) struct StreamState {
    pub(super) text_acc: String,
    pub(super) thinking_acc: String,
    pub(super) capability_invocations: Vec<CapabilityInvocationDraft>,
    pub(super) current_invocation_id: Option<String>,
    pub(super) current_model_primitive_name: Option<String>,
    pub(super) current_capability_args: String,
    pub(super) token_usage: Option<TokenUsage>,
    pub(super) thinking_signature: Option<String>,
    pub(super) stream_start: Instant,
    pub(super) ttft_ms: Option<u64>,
    /// When true, skip all content events (text, thinking, capability invocations) but keep
    /// reading the stream to capture token usage from the Done event.
    pub(super) draining: bool,
}

impl StreamState {
    pub(super) fn new() -> Self {
        Self {
            text_acc: String::with_capacity(4096),
            thinking_acc: String::with_capacity(2048),
            capability_invocations: Vec::with_capacity(4),
            current_invocation_id: None,
            current_model_primitive_name: None,
            current_capability_args: String::with_capacity(512),
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
        trace_context: StreamTraceContext<'_>,
    ) {
        self.record_ttft();
        self.text_acc.push_str(&delta);
        if let Some(counter) = counter {
            let _ = emitter.emit_sequenced(
                TronEvent::MessageUpdate {
                    base: trace_context.base_event(session_id),
                    content: delta,
                },
                counter,
            );
        } else {
            let _ = emitter.emit(TronEvent::MessageUpdate {
                base: trace_context.base_event(session_id),
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
        trace_context: StreamTraceContext<'_>,
    ) {
        self.record_ttft();
        self.thinking_acc.push_str(&delta);
        if let Some(counter) = counter {
            let _ = emitter.emit_sequenced(
                TronEvent::ThinkingDelta {
                    base: trace_context.base_event(session_id),
                    delta,
                },
                counter,
            );
        } else {
            let _ = emitter.emit(TronEvent::ThinkingDelta {
                base: trace_context.base_event(session_id),
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
        trace_context: StreamTraceContext<'_>,
    ) {
        self.thinking_acc.clone_from(&thinking);
        self.thinking_signature = signature;
        if let Some(counter) = counter {
            let _ = emitter.emit_sequenced(
                TronEvent::ThinkingEnd {
                    base: trace_context.base_event(session_id),
                    thinking,
                },
                counter,
            );
        } else {
            let _ = emitter.emit(TronEvent::ThinkingEnd {
                base: trace_context.base_event(session_id),
                thinking,
            });
        }
    }

    fn handle_capability_invocation_start(
        &mut self,
        invocation_id: String,
        name: String,
        session_id: &str,
        emitter: &EventEmitter,
        counter: Option<&AtomicI64>,
        trace_context: StreamTraceContext<'_>,
    ) {
        finalize_capability_invocation(
            &mut self.capability_invocations,
            &mut self.current_invocation_id,
            &mut self.current_model_primitive_name,
            &mut self.current_capability_args,
        );

        self.current_invocation_id = Some(invocation_id.clone());
        self.current_model_primitive_name = Some(name.clone());
        self.current_capability_args.clear();

        if let Some(counter) = counter {
            let _ = emitter.emit_sequenced(
                TronEvent::CapabilityInvocationGenerating {
                    base: trace_context.base_event(session_id),
                    invocation_id,
                    model_primitive_name: name.clone(),
                    capability_identity:
                        crate::shared::events::CapabilityEventIdentity::with_model_primitive(name),
                },
                counter,
            );
        } else {
            let _ = emitter.emit(TronEvent::CapabilityInvocationGenerating {
                base: trace_context.base_event(session_id),
                invocation_id,
                model_primitive_name: name.clone(),
                capability_identity:
                    crate::shared::events::CapabilityEventIdentity::with_model_primitive(name),
            });
        }
    }

    fn handle_capability_invocation_delta(
        &mut self,
        invocation_id: String,
        arguments_delta: String,
        session_id: &str,
        emitter: &EventEmitter,
        counter: Option<&AtomicI64>,
        trace_context: StreamTraceContext<'_>,
    ) {
        self.current_capability_args.push_str(&arguments_delta);
        if let Some(counter) = counter {
            let _ = emitter.emit_sequenced(
                TronEvent::CapabilityInvocationArgumentDelta {
                    base: trace_context.base_event(session_id),
                    invocation_id,
                    model_primitive_name: self.current_model_primitive_name.clone(),
                    arguments_delta,
                },
                counter,
            );
        } else {
            let _ = emitter.emit(TronEvent::CapabilityInvocationArgumentDelta {
                base: trace_context.base_event(session_id),
                invocation_id,
                model_primitive_name: self.current_model_primitive_name.clone(),
                arguments_delta,
            });
        }
    }

    fn handle_capability_invocation_end(
        &mut self,
        capability_invocation: CapabilityInvocationDraft,
    ) {
        self.current_invocation_id = None;
        self.current_model_primitive_name = None;
        self.current_capability_args.clear();
        if let Some(pos) = self
            .capability_invocations
            .iter()
            .position(|tc| tc.id == capability_invocation.id)
        {
            self.capability_invocations[pos] = capability_invocation;
        } else {
            self.capability_invocations.push(capability_invocation);
        }
    }

    pub(super) fn build_interrupted_result(
        self,
    ) -> crate::domains::agent::runner::types::StreamResult {
        let partial = if self.text_acc.is_empty() {
            None
        } else {
            Some(self.text_acc.clone())
        };
        crate::domains::agent::runner::types::StreamResult {
            message: build_message(
                &self.text_acc,
                &self.thinking_acc,
                self.thinking_signature.as_deref(),
                &self.capability_invocations,
            ),
            capability_invocations: self.capability_invocations,
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
    ) -> crate::domains::agent::runner::types::StreamResult {
        finalize_capability_invocation(
            &mut self.capability_invocations,
            &mut self.current_invocation_id,
            &mut self.current_model_primitive_name,
            &mut self.current_capability_args,
        );

        let message = final_message.unwrap_or_else(|| {
            build_message(
                &self.text_acc,
                &self.thinking_acc,
                self.thinking_signature.as_deref(),
                &self.capability_invocations,
            )
        });

        crate::domains::agent::runner::types::StreamResult {
            message,
            capability_invocations: self.capability_invocations,
            stop_reason,
            token_usage: self.token_usage,
            interrupted: false,
            partial_content: None,
            ttft_ms: self.ttft_ms,
        }
    }

    /// Handle a stream event while in drain mode (after a stopping capability completed).
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
        trace_context: StreamTraceContext<'_>,
    ) -> StreamAction {
        match stream_event {
            StreamEvent::Done { message, .. } => {
                self.token_usage.clone_from(&message.token_usage);
                StreamAction::Done {
                    stop_reason: "capability_invocation".into(),
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
                            base: trace_context.base_event(session_id),
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
                        base: trace_context.base_event(session_id),
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
    /// Accumulates text, thinking, and capability invocation content. When a capability in
    /// `turn_stopping_capabilities` completes, sets `self.draining = true` so the
    /// caller switches to `handle_drain_event` on subsequent events.
    pub(super) fn handle_normal_event(
        &mut self,
        stream_event: StreamEvent,
        session_id: &str,
        emitter: &EventEmitter,
        sequence_counter: Option<&AtomicI64>,
        turn_stopping_capabilities: &HashSet<String>,
        journal: &mut Option<&mut StreamingJournal>,
        trace_context: StreamTraceContext<'_>,
    ) -> StreamAction {
        match stream_event {
            StreamEvent::TextDelta { delta } => {
                if let Some(j) = journal {
                    if let Err(e) = j.append_delta("text", &delta) {
                        tracing::warn!(session_id, error = %e, "journal write failed for text delta");
                    }
                }
                self.handle_text_delta(delta, session_id, emitter, sequence_counter, trace_context);
            }

            StreamEvent::Start | StreamEvent::TextStart | StreamEvent::TextEnd { .. } => {}

            StreamEvent::ThinkingStart => {
                tracing::debug!(session_id, "stream_state: received ThinkingStart");
                if let Some(counter) = sequence_counter {
                    let _ = emitter.emit_sequenced(
                        TronEvent::ThinkingStart {
                            base: trace_context.base_event(session_id),
                        },
                        counter,
                    );
                } else {
                    let _ = emitter.emit(TronEvent::ThinkingStart {
                        base: trace_context.base_event(session_id),
                    });
                }
            }

            StreamEvent::ThinkingDelta { delta } => {
                if let Some(j) = journal {
                    if let Err(e) = j.append_delta("thinking", &delta) {
                        tracing::warn!(session_id, error = %e, "journal write failed for thinking delta");
                    }
                }
                self.handle_thinking_delta(
                    delta,
                    session_id,
                    emitter,
                    sequence_counter,
                    trace_context,
                );
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
                    trace_context,
                );
            }

            StreamEvent::CapabilityInvocationDraftStart {
                invocation_id,
                name,
            } => {
                self.handle_capability_invocation_start(
                    invocation_id,
                    name,
                    session_id,
                    emitter,
                    sequence_counter,
                    trace_context,
                );
            }

            StreamEvent::CapabilityInvocationDraftDelta {
                invocation_id,
                arguments_delta,
            } => {
                self.handle_capability_invocation_delta(
                    invocation_id,
                    arguments_delta,
                    session_id,
                    emitter,
                    sequence_counter,
                    trace_context,
                );
            }

            StreamEvent::CapabilityInvocationDraftEnd {
                capability_invocation,
            } => {
                if let Some(j) = journal {
                    if let Ok(serialized) = serde_json::to_string(&capability_invocation) {
                        if let Err(e) = j.append_delta("capability_invocation", &serialized) {
                            tracing::warn!(session_id, error = %e, "journal write failed for capability invocation");
                        }
                    }
                }
                let should_drain = capability_invocation_stops_turn(
                    &capability_invocation,
                    turn_stopping_capabilities,
                );
                self.handle_capability_invocation_end(capability_invocation);
                if should_drain {
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
                            base: trace_context.base_event(session_id),
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
                        base: trace_context.base_event(session_id),
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

fn capability_invocation_stops_turn(
    capability_invocation: &CapabilityInvocationDraft,
    turn_stopping_capabilities: &HashSet<String>,
) -> bool {
    if turn_stopping_capabilities.contains(&capability_invocation.name) {
        return true;
    }
    if capability_invocation.name != "execute" {
        return false;
    }
    execute_target_contract(&capability_invocation.arguments)
        .is_some_and(|target| turn_stopping_capabilities.contains(target))
}

fn execute_target_contract(arguments: &Map<String, serde_json::Value>) -> Option<&str> {
    [
        "contractId",
        "capabilityId",
        "functionId",
        "contract_id",
        "capability_id",
        "function_id",
    ]
    .iter()
    .find_map(|key| arguments.get(*key).and_then(serde_json::Value::as_str))
    .filter(|target| !target.trim().is_empty())
}

/// Finalize an in-progress capability invocation from accumulated deltas.
pub(super) fn finalize_capability_invocation(
    capability_invocations: &mut Vec<CapabilityInvocationDraft>,
    current_id: &mut Option<String>,
    current_name: &mut Option<String>,
    current_args: &mut String,
) {
    if let (Some(id), Some(name)) = (current_id.take(), current_name.take()) {
        if current_args.trim().is_empty() {
            current_args.clear();
            return;
        }
        let arguments: Map<String, serde_json::Value> = match serde_json::from_str(current_args) {
            Ok(map) => map,
            Err(e) => {
                let preview: String = current_args.chars().take(200).collect();
                tracing::warn!(
                    model_primitive_name = %name,
                    invocation_id = %id,
                    error = %e,
                    args_preview = %preview,
                    "malformed capability invocation arguments, using empty map"
                );
                Map::new()
            }
        };
        if let Some(pos) = capability_invocations.iter().position(|tc| tc.id == id) {
            capability_invocations[pos] = CapabilityInvocationDraft::new(id, name, arguments);
        } else {
            capability_invocations.push(CapabilityInvocationDraft::new(id, name, arguments));
        }
        current_args.clear();
    }
}

/// Build an `AssistantMessage` from accumulated parts.
pub(super) fn build_message(
    text: &str,
    thinking: &str,
    thinking_signature: Option<&str>,
    capability_invocations: &[CapabilityInvocationDraft],
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

    for tc in capability_invocations {
        content.push(AssistantContent::CapabilityInvocation {
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
