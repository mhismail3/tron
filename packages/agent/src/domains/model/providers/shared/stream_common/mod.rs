//! Shared stream accumulator for LLM provider stream handlers.
//!
//! [`StreamAccumulator`] encapsulates the repeated delta-processing logic shared
//! across Anthropic, OpenAI, and Google stream handlers: text accumulation,
//! thinking accumulation, capability invocation argument buffering, and token tracking.
//!
//! Each provider handler owns a `StreamAccumulator` and delegates the mechanical
//! accumulation work to it, keeping only provider-specific event parsing and
//! protocol mapping in the provider module.

use serde_json::Map;

use crate::domains::model::protocol::{CapabilityCallContext, parse_capability_call_arguments};
use crate::shared::protocol::events::StreamEvent;
use crate::shared::protocol::messages::CapabilityInvocationDraft;

/// Maximum accumulated assistant text bytes retained for one provider stream.
pub const MAX_PROVIDER_STREAM_TEXT_BYTES: usize = 4 * 1024 * 1024;
/// Maximum accumulated thinking bytes retained for one provider stream.
pub const MAX_PROVIDER_STREAM_THINKING_BYTES: usize = 4 * 1024 * 1024;
/// Maximum accumulated provider thinking signature bytes retained per stream.
pub const MAX_PROVIDER_STREAM_SIGNATURE_BYTES: usize = 256 * 1024;
/// Maximum accumulated JSON argument bytes retained for one capability draft.
pub const MAX_PROVIDER_STREAM_TOOL_ARGUMENT_BYTES: usize = 1024 * 1024;
/// Maximum concurrently accumulated capability drafts in one provider stream.
pub const MAX_PROVIDER_STREAM_TOOL_INVOCATIONS: usize = 64;

/// Resource-limit error for provider stream accumulation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StreamAccumulatorLimitError {
    field: &'static str,
    max_bytes: usize,
    attempted_bytes: usize,
}

impl StreamAccumulatorLimitError {
    fn new(field: &'static str, max_bytes: usize, attempted_bytes: usize) -> Self {
        Self {
            field,
            max_bytes,
            attempted_bytes,
        }
    }
}

impl std::fmt::Display for StreamAccumulatorLimitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "provider stream {} exceeded {} byte limit (attempted {} bytes)",
            self.field, self.max_bytes, self.attempted_bytes
        )
    }
}

impl std::error::Error for StreamAccumulatorLimitError {}

/// Check that a full provider stream field value is within its byte ceiling.
pub fn check_stream_field_bytes(
    value: &str,
    max_bytes: usize,
    field: &'static str,
) -> Result<(), StreamAccumulatorLimitError> {
    if value.len() > max_bytes {
        return Err(StreamAccumulatorLimitError::new(
            field,
            max_bytes,
            value.len(),
        ));
    }
    Ok(())
}

/// Append a delta to a provider stream field only when the result stays bounded.
pub fn append_stream_field_bounded(
    target: &mut String,
    delta: &str,
    max_bytes: usize,
    field: &'static str,
) -> Result<(), StreamAccumulatorLimitError> {
    let attempted_bytes = target.len().saturating_add(delta.len());
    if attempted_bytes > max_bytes {
        return Err(StreamAccumulatorLimitError::new(
            field,
            max_bytes,
            attempted_bytes,
        ));
    }
    target.push_str(delta);
    Ok(())
}

/// Convert a provider stream resource-limit error into the canonical stream error path.
pub fn stream_limit_error_event(error: StreamAccumulatorLimitError) -> StreamEvent {
    StreamEvent::Error {
        error: error.to_string(),
    }
}

/// In-progress capability invocation being accumulated from streaming deltas.
#[derive(Clone, Debug)]
pub struct CapabilityInvocationAccumulator {
    /// Capability invocation ID.
    pub id: String,
    /// Capability name.
    pub name: String,
    /// Accumulated JSON arguments string.
    pub args: String,
}

/// Shared accumulator for LLM stream delta processing.
///
/// Tracks text, thinking, signature, and capability invocation state across streaming
/// deltas, emitting the appropriate [`StreamEvent`]s at each transition.
#[derive(Clone, Debug)]
pub struct StreamAccumulator {
    /// Accumulated text content.
    pub accumulated_text: String,
    /// Accumulated thinking/reasoning content.
    pub accumulated_thinking: String,
    /// Accumulated signature (Anthropic-specific, but stored here for uniformity).
    pub accumulated_signature: String,
    /// Whether a `TextStart` event has been emitted.
    pub text_started: bool,
    /// Whether a `ThinkingStart` event has been emitted.
    pub thinking_started: bool,
    /// In-progress capability invocations keyed by capability invocation ID.
    capability_invocations: Vec<CapabilityInvocationAccumulator>,
    /// Input token count.
    pub input_tokens: u64,
    /// Output token count.
    pub output_tokens: u64,
    /// Tokens read from cache/cached input.
    pub cache_read_tokens: u64,
    /// Hidden reasoning output tokens.
    pub reasoning_output_tokens: u64,
    /// Provider-reported total tokens.
    pub total_tokens: u64,
}

impl StreamAccumulator {
    /// Create a new empty accumulator.
    #[must_use]
    pub fn new() -> Self {
        Self {
            accumulated_text: String::new(),
            accumulated_thinking: String::new(),
            accumulated_signature: String::new(),
            text_started: false,
            thinking_started: false,
            capability_invocations: Vec::new(),
            input_tokens: 0,
            output_tokens: 0,
            cache_read_tokens: 0,
            reasoning_output_tokens: 0,
            total_tokens: 0,
        }
    }

    /// Process a text delta. Emits `TextStart` on the first call, then `TextDelta`.
    pub fn process_text_delta(&mut self, text: &str) -> Vec<StreamEvent> {
        if let Err(error) = self.try_accumulate_text(text) {
            return vec![stream_limit_error_event(error)];
        }
        let mut events = Vec::new();
        if !self.text_started {
            self.text_started = true;
            events.push(StreamEvent::TextStart);
        }
        events.push(StreamEvent::TextDelta {
            delta: text.to_string(),
        });
        events
    }

    /// Process a thinking delta. Emits `ThinkingStart` on the first call, then `ThinkingDelta`.
    pub fn process_thinking_delta(&mut self, text: &str) -> Vec<StreamEvent> {
        if let Err(error) = self.try_accumulate_thinking(text) {
            return vec![stream_limit_error_event(error)];
        }
        let mut events = Vec::new();
        if !self.thinking_started {
            self.thinking_started = true;
            events.push(StreamEvent::ThinkingStart);
        }
        events.push(StreamEvent::ThinkingDelta {
            delta: text.to_string(),
        });
        events
    }

    /// Mark text as started and emit `TextStart`.
    ///
    /// Returns `Some(TextStart)` if not already started, `None` otherwise.
    /// Use this when the provider protocol has explicit block-start events
    /// (e.g. Anthropic `content_block_start`).
    pub fn mark_text_started(&mut self) -> Option<StreamEvent> {
        if !self.text_started {
            self.text_started = true;
            Some(StreamEvent::TextStart)
        } else {
            None
        }
    }

    /// Mark thinking as started and emit `ThinkingStart`.
    ///
    /// Returns `Some(ThinkingStart)` if not already started, `None` otherwise.
    pub fn mark_thinking_started(&mut self) -> Option<StreamEvent> {
        if !self.thinking_started {
            self.thinking_started = true;
            Some(StreamEvent::ThinkingStart)
        } else {
            None
        }
    }

    /// Accumulate text without emitting start/delta events.
    ///
    /// Used by providers that emit deltas themselves (e.g. Anthropic where
    /// `TextStart` comes from `content_block_start`, not from first delta).
    pub fn accumulate_text(&mut self, text: &str) {
        if let Err(error) = self.try_accumulate_text(text) {
            tracing::warn!(error = %error, "provider stream text limit exceeded");
        }
    }

    /// Fallibly accumulate text without emitting events.
    pub fn try_accumulate_text(&mut self, text: &str) -> Result<(), StreamAccumulatorLimitError> {
        append_stream_field_bounded(
            &mut self.accumulated_text,
            text,
            MAX_PROVIDER_STREAM_TEXT_BYTES,
            "text",
        )
    }

    /// Accumulate thinking without emitting start/delta events.
    pub fn accumulate_thinking(&mut self, text: &str) {
        if let Err(error) = self.try_accumulate_thinking(text) {
            tracing::warn!(error = %error, "provider stream thinking limit exceeded");
        }
    }

    /// Fallibly accumulate thinking without emitting events.
    pub fn try_accumulate_thinking(
        &mut self,
        text: &str,
    ) -> Result<(), StreamAccumulatorLimitError> {
        append_stream_field_bounded(
            &mut self.accumulated_thinking,
            text,
            MAX_PROVIDER_STREAM_THINKING_BYTES,
            "thinking",
        )
    }

    /// Accumulate signature content.
    pub fn accumulate_signature(&mut self, sig: &str) {
        if let Err(error) = self.try_accumulate_signature(sig) {
            tracing::warn!(error = %error, "provider stream signature limit exceeded");
        }
    }

    /// Fallibly accumulate signature content.
    pub fn try_accumulate_signature(
        &mut self,
        sig: &str,
    ) -> Result<(), StreamAccumulatorLimitError> {
        append_stream_field_bounded(
            &mut self.accumulated_signature,
            sig,
            MAX_PROVIDER_STREAM_SIGNATURE_BYTES,
            "signature",
        )
    }

    /// Replace accumulated text with a complete provider value after checking size.
    pub fn try_set_text(&mut self, text: &str) -> Result<(), StreamAccumulatorLimitError> {
        check_stream_field_bytes(text, MAX_PROVIDER_STREAM_TEXT_BYTES, "text")?;
        self.accumulated_text.clear();
        self.accumulated_text.push_str(text);
        Ok(())
    }

    /// Replace accumulated thinking with a complete provider value after checking size.
    pub fn try_set_thinking(&mut self, text: &str) -> Result<(), StreamAccumulatorLimitError> {
        check_stream_field_bytes(text, MAX_PROVIDER_STREAM_THINKING_BYTES, "thinking")?;
        self.accumulated_thinking.clear();
        self.accumulated_thinking.push_str(text);
        Ok(())
    }

    /// Start tracking a new capability invocation. Emits `CapabilityInvocationDraftStart`.
    pub fn start_capability_invocation(&mut self, id: String, name: String) -> Vec<StreamEvent> {
        if self.capability_invocations.len() >= MAX_PROVIDER_STREAM_TOOL_INVOCATIONS {
            return vec![StreamEvent::Error {
                error: format!(
                    "provider stream capability invocations exceeded {} item limit",
                    MAX_PROVIDER_STREAM_TOOL_INVOCATIONS
                ),
            }];
        }
        let events = vec![StreamEvent::CapabilityInvocationDraftStart {
            invocation_id: id.clone(),
            name: name.clone(),
        }];
        self.capability_invocations
            .push(CapabilityInvocationAccumulator {
                id,
                name,
                args: String::new(),
            });
        events
    }

    /// Append argument JSON delta to a capability invocation. Emits `CapabilityInvocationDraftDelta`.
    pub fn append_tool_args(&mut self, id: &str, delta: &str) -> Vec<StreamEvent> {
        if let Some(tc) = self
            .capability_invocations
            .iter_mut()
            .find(|tc| tc.id == id)
        {
            if let Err(error) = append_stream_field_bounded(
                &mut tc.args,
                delta,
                MAX_PROVIDER_STREAM_TOOL_ARGUMENT_BYTES,
                "capability arguments",
            ) {
                return vec![stream_limit_error_event(error)];
            }
            vec![StreamEvent::CapabilityInvocationDraftDelta {
                invocation_id: id.to_string(),
                arguments_delta: delta.to_string(),
            }]
        } else {
            vec![]
        }
    }

    /// Finish a capability invocation by ID. Parses accumulated args and emits `CapabilityInvocationDraftEnd`.
    ///
    /// Returns the events and removes the capability invocation from the active set.
    pub fn finish_capability_invocation(&mut self, id: &str) -> Vec<StreamEvent> {
        self.finish_capability_invocation_with_provider(id, None)
    }

    /// Finish a capability invocation by ID with provider context for parse diagnostics.
    ///
    /// Returns the events and removes the capability invocation from the active set.
    pub fn finish_capability_invocation_with_provider(
        &mut self,
        id: &str,
        provider: Option<&str>,
    ) -> Vec<StreamEvent> {
        let pos = self
            .capability_invocations
            .iter()
            .position(|tc| tc.id == id);
        let Some(idx) = pos else {
            return vec![];
        };
        let tc = self.capability_invocations.remove(idx);
        let ctx = CapabilityCallContext {
            invocation_id: Some(tc.id.clone()),
            model_primitive_name: Some(tc.name.clone()),
            provider: provider.map(str::to_owned),
        };
        let arguments: Map<String, serde_json::Value> =
            match parse_capability_call_arguments(Some(&tc.args), Some(&ctx)) {
                Ok(arguments) => arguments,
                Err(error) => {
                    return vec![StreamEvent::Error {
                        error: error.to_string(),
                    }];
                }
            };
        let capability_invocation = CapabilityInvocationDraft::new(tc.id, tc.name, arguments);
        vec![StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation,
        }]
    }

    /// Finish a capability invocation with pre-parsed arguments and optional thought signature.
    pub fn finish_capability_invocation_with(
        &mut self,
        id: &str,
        arguments: Map<String, serde_json::Value>,
        thought_signature: Option<String>,
    ) -> Vec<StreamEvent> {
        let pos = self
            .capability_invocations
            .iter()
            .position(|tc| tc.id == id);
        let Some(idx) = pos else {
            return vec![];
        };
        let tc = self.capability_invocations.remove(idx);
        let mut capability_invocation = CapabilityInvocationDraft::new(tc.id, tc.name, arguments);
        if let Some(sig) = thought_signature {
            capability_invocation = capability_invocation.with_thought_signature(&sig);
        }
        vec![StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation,
        }]
    }

    /// Emit `ThinkingEnd` if thinking was started, closing the thinking block.
    ///
    /// Returns the event with accumulated thinking text and optional signature.
    /// Resets `thinking_started` to `false`.
    pub fn close_thinking(&mut self, signature: Option<String>) -> Vec<StreamEvent> {
        if self.thinking_started {
            self.thinking_started = false;
            vec![StreamEvent::ThinkingEnd {
                thinking: self.accumulated_thinking.clone(),
                signature,
            }]
        } else {
            vec![]
        }
    }

    /// Emit `TextEnd` if text was started, closing the text block.
    pub fn close_text(&mut self, signature: Option<String>) -> Vec<StreamEvent> {
        if self.text_started {
            self.text_started = false;
            vec![StreamEvent::TextEnd {
                text: self.accumulated_text.clone(),
                signature,
            }]
        } else {
            vec![]
        }
    }

    /// Take accumulated text, resetting the buffer. Returns the text.
    pub fn take_text(&mut self) -> String {
        self.text_started = false;
        std::mem::take(&mut self.accumulated_text)
    }

    /// Take accumulated thinking, resetting the buffer. Returns the text.
    pub fn take_thinking(&mut self) -> String {
        self.thinking_started = false;
        std::mem::take(&mut self.accumulated_thinking)
    }

    /// Take accumulated signature, resetting the buffer.
    pub fn take_signature(&mut self) -> Option<String> {
        if self.accumulated_signature.is_empty() {
            None
        } else {
            Some(std::mem::take(&mut self.accumulated_signature))
        }
    }

    /// Get a reference to the accumulated capability invocations.
    pub fn capability_invocations(&self) -> &[CapabilityInvocationAccumulator] {
        &self.capability_invocations
    }

    /// Get a mutable reference to a capability invocation by ID.
    pub fn capability_invocation_mut(
        &mut self,
        id: &str,
    ) -> Option<&mut CapabilityInvocationAccumulator> {
        self.capability_invocations
            .iter_mut()
            .find(|tc| tc.id == id)
    }

    /// Set input and output token counts.
    pub fn set_tokens(&mut self, input: u64, output: u64) {
        self.input_tokens = input;
        self.output_tokens = output;
    }
}

impl Default for StreamAccumulator {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests;
