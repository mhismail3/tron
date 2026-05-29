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

use crate::domains::model::provider_protocol::{
    CapabilityCallContext, parse_capability_call_arguments,
};
use crate::shared::events::StreamEvent;
use crate::shared::messages::CapabilityInvocationDraft;

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
        }
    }

    /// Process a text delta. Emits `TextStart` on the first call, then `TextDelta`.
    pub fn process_text_delta(&mut self, text: &str) -> Vec<StreamEvent> {
        let mut events = Vec::new();
        if !self.text_started {
            self.text_started = true;
            events.push(StreamEvent::TextStart);
        }
        self.accumulated_text.push_str(text);
        events.push(StreamEvent::TextDelta {
            delta: text.to_string(),
        });
        events
    }

    /// Process a thinking delta. Emits `ThinkingStart` on the first call, then `ThinkingDelta`.
    pub fn process_thinking_delta(&mut self, text: &str) -> Vec<StreamEvent> {
        let mut events = Vec::new();
        if !self.thinking_started {
            self.thinking_started = true;
            events.push(StreamEvent::ThinkingStart);
        }
        self.accumulated_thinking.push_str(text);
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
        self.accumulated_text.push_str(text);
    }

    /// Accumulate thinking without emitting start/delta events.
    pub fn accumulate_thinking(&mut self, text: &str) {
        self.accumulated_thinking.push_str(text);
    }

    /// Accumulate signature content.
    pub fn accumulate_signature(&mut self, sig: &str) {
        self.accumulated_signature.push_str(sig);
    }

    /// Start tracking a new capability invocation. Emits `CapabilityInvocationDraftStart`.
    pub fn start_capability_invocation(&mut self, id: String, name: String) -> Vec<StreamEvent> {
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
            tc.args.push_str(delta);
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

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── new / default ───────────────────────────────────────────────

    #[test]
    fn new_accumulator_is_empty() {
        let acc = StreamAccumulator::new();
        assert!(acc.accumulated_text.is_empty());
        assert!(acc.accumulated_thinking.is_empty());
        assert!(acc.accumulated_signature.is_empty());
        assert!(!acc.text_started);
        assert!(!acc.thinking_started);
        assert!(acc.capability_invocations.is_empty());
        assert_eq!(acc.input_tokens, 0);
        assert_eq!(acc.output_tokens, 0);
    }

    #[test]
    fn default_matches_new() {
        let a = StreamAccumulator::new();
        let b = StreamAccumulator::default();
        assert_eq!(a.accumulated_text, b.accumulated_text);
        assert_eq!(a.text_started, b.text_started);
    }

    // ── process_text_delta ──────────────────────────────────────────

    #[test]
    fn text_delta_emits_start_on_first_call() {
        let mut acc = StreamAccumulator::new();
        let events = acc.process_text_delta("hello");
        assert_eq!(events.len(), 2);
        assert!(matches!(events[0], StreamEvent::TextStart));
        assert!(matches!(&events[1], StreamEvent::TextDelta { delta } if delta == "hello"));
        assert!(acc.text_started);
        assert_eq!(acc.accumulated_text, "hello");
    }

    #[test]
    fn text_delta_only_delta_on_subsequent() {
        let mut acc = StreamAccumulator::new();
        let _ = acc.process_text_delta("hello");
        let events = acc.process_text_delta(" world");
        assert_eq!(events.len(), 1);
        assert!(matches!(&events[0], StreamEvent::TextDelta { delta } if delta == " world"));
        assert_eq!(acc.accumulated_text, "hello world");
    }

    // ── process_thinking_delta ──────────────────────────────────────

    #[test]
    fn thinking_delta_emits_start_on_first_call() {
        let mut acc = StreamAccumulator::new();
        let events = acc.process_thinking_delta("thinking...");
        assert_eq!(events.len(), 2);
        assert!(matches!(events[0], StreamEvent::ThinkingStart));
        assert!(
            matches!(&events[1], StreamEvent::ThinkingDelta { delta } if delta == "thinking...")
        );
        assert!(acc.thinking_started);
        assert_eq!(acc.accumulated_thinking, "thinking...");
    }

    #[test]
    fn thinking_delta_only_delta_on_subsequent() {
        let mut acc = StreamAccumulator::new();
        let _ = acc.process_thinking_delta("first");
        let events = acc.process_thinking_delta(" second");
        assert_eq!(events.len(), 1);
        assert!(matches!(&events[0], StreamEvent::ThinkingDelta { delta } if delta == " second"));
        assert_eq!(acc.accumulated_thinking, "first second");
    }

    // ── mark_text_started / mark_thinking_started ───────────────────

    #[test]
    fn mark_text_started_returns_event_once() {
        let mut acc = StreamAccumulator::new();
        assert!(acc.mark_text_started().is_some());
        assert!(acc.mark_text_started().is_none());
    }

    #[test]
    fn mark_thinking_started_returns_event_once() {
        let mut acc = StreamAccumulator::new();
        assert!(acc.mark_thinking_started().is_some());
        assert!(acc.mark_thinking_started().is_none());
    }

    // ── accumulate_text / accumulate_thinking / accumulate_signature ─

    #[test]
    fn accumulate_text_does_not_emit_events() {
        let mut acc = StreamAccumulator::new();
        acc.accumulate_text("silent");
        assert_eq!(acc.accumulated_text, "silent");
        assert!(!acc.text_started);
    }

    #[test]
    fn accumulate_thinking_does_not_emit_events() {
        let mut acc = StreamAccumulator::new();
        acc.accumulate_thinking("silent thought");
        assert_eq!(acc.accumulated_thinking, "silent thought");
        assert!(!acc.thinking_started);
    }

    #[test]
    fn accumulate_signature_appends() {
        let mut acc = StreamAccumulator::new();
        acc.accumulate_signature("part1");
        acc.accumulate_signature("_part2");
        assert_eq!(acc.accumulated_signature, "part1_part2");
    }

    // ── capability invocation lifecycle ─────────────────────────────────────────

    #[test]
    fn start_capability_invocation_emits_start_event() {
        let mut acc = StreamAccumulator::new();
        let events = acc.start_capability_invocation("call_1".into(), "execute".into());
        assert_eq!(events.len(), 1);
        match &events[0] {
            StreamEvent::CapabilityInvocationDraftStart {
                invocation_id,
                name,
            } => {
                assert_eq!(invocation_id, "call_1");
                assert_eq!(name, "execute");
            }
            _ => panic!("expected CapabilityInvocationDraftStart"),
        }
        assert_eq!(acc.capability_invocations.len(), 1);
    }

    #[test]
    fn append_tool_args_emits_delta() {
        let mut acc = StreamAccumulator::new();
        let _ = acc.start_capability_invocation("call_1".into(), "execute".into());
        let events = acc.append_tool_args("call_1", r#"{"cmd":"#);
        assert_eq!(events.len(), 1);
        match &events[0] {
            StreamEvent::CapabilityInvocationDraftDelta {
                invocation_id,
                arguments_delta,
            } => {
                assert_eq!(invocation_id, "call_1");
                assert_eq!(arguments_delta, r#"{"cmd":"#);
            }
            _ => panic!("expected CapabilityInvocationDraftDelta"),
        }
        assert_eq!(acc.capability_invocations[0].args, r#"{"cmd":"#);
    }

    #[test]
    fn append_tool_args_unknown_id_returns_empty() {
        let mut acc = StreamAccumulator::new();
        let events = acc.append_tool_args("unknown", "data");
        assert!(events.is_empty());
    }

    #[test]
    fn finish_capability_invocation_emits_end_with_parsed_args() {
        let mut acc = StreamAccumulator::new();
        let _ = acc.start_capability_invocation("call_1".into(), "execute".into());
        let _ = acc.append_tool_args("call_1", r#"{"cmd":"ls"}"#);
        let events = acc.finish_capability_invocation("call_1");
        assert_eq!(events.len(), 1);
        match &events[0] {
            StreamEvent::CapabilityInvocationDraftEnd {
                capability_invocation,
            } => {
                assert_eq!(capability_invocation.id, "call_1");
                assert_eq!(capability_invocation.name, "execute");
                assert_eq!(capability_invocation.arguments["cmd"], "ls");
            }
            _ => panic!("expected CapabilityInvocationDraftEnd"),
        }
        assert!(acc.capability_invocations.is_empty());
    }

    #[test]
    fn finish_capability_invocation_unknown_id_returns_empty() {
        let mut acc = StreamAccumulator::new();
        let events = acc.finish_capability_invocation("unknown");
        assert!(events.is_empty());
    }

    #[test]
    fn finish_capability_invocation_empty_args_gives_empty_map() {
        let mut acc = StreamAccumulator::new();
        let _ = acc.start_capability_invocation("call_1".into(), "execute".into());
        let events = acc.finish_capability_invocation("call_1");
        match &events[0] {
            StreamEvent::CapabilityInvocationDraftEnd {
                capability_invocation,
            } => {
                assert!(capability_invocation.arguments.is_empty());
            }
            _ => panic!("expected CapabilityInvocationDraftEnd"),
        }
    }

    #[test]
    fn finish_capability_invocation_malformed_args_emits_error() {
        let mut acc = StreamAccumulator::new();
        let _ = acc.start_capability_invocation("call_1".into(), "execute".into());
        let _ = acc.append_tool_args("call_1", "not json");
        let events = acc.finish_capability_invocation_with_provider("call_1", Some("anthropic"));
        assert_eq!(events.len(), 1);
        match &events[0] {
            StreamEvent::Error { error } => {
                assert!(error.contains("anthropic capability invocation arguments"));
                assert!(error.contains("malformed JSON"));
            }
            _ => panic!("expected Error"),
        }
    }

    #[test]
    fn finish_capability_invocation_with_thought_signature() {
        let mut acc = StreamAccumulator::new();
        let _ = acc.start_capability_invocation("call_1".into(), "execute".into());
        let _ = acc.append_tool_args("call_1", r#"{"cmd":"ls"}"#);
        let args: Map<String, serde_json::Value> = serde_json::from_str(r#"{"cmd":"ls"}"#).unwrap();
        let events = acc.finish_capability_invocation_with("call_1", args, Some("sig-abc".into()));
        match &events[0] {
            StreamEvent::CapabilityInvocationDraftEnd {
                capability_invocation,
            } => {
                assert_eq!(
                    capability_invocation.thought_signature.as_deref(),
                    Some("sig-abc")
                );
            }
            _ => panic!("expected CapabilityInvocationDraftEnd"),
        }
    }

    // ── close_thinking / close_text ─────────────────────────────────

    #[test]
    fn close_thinking_emits_end_when_started() {
        let mut acc = StreamAccumulator::new();
        let _ = acc.process_thinking_delta("thought");
        let events = acc.close_thinking(Some("sig".into()));
        assert_eq!(events.len(), 1);
        match &events[0] {
            StreamEvent::ThinkingEnd {
                thinking,
                signature,
            } => {
                assert_eq!(thinking, "thought");
                assert_eq!(signature.as_deref(), Some("sig"));
            }
            _ => panic!("expected ThinkingEnd"),
        }
        assert!(!acc.thinking_started);
    }

    #[test]
    fn close_thinking_noop_when_not_started() {
        let mut acc = StreamAccumulator::new();
        let events = acc.close_thinking(None);
        assert!(events.is_empty());
    }

    #[test]
    fn close_text_emits_end_when_started() {
        let mut acc = StreamAccumulator::new();
        let _ = acc.process_text_delta("hello");
        let events = acc.close_text(None);
        assert_eq!(events.len(), 1);
        match &events[0] {
            StreamEvent::TextEnd { text, signature } => {
                assert_eq!(text, "hello");
                assert!(signature.is_none());
            }
            _ => panic!("expected TextEnd"),
        }
        assert!(!acc.text_started);
    }

    #[test]
    fn close_text_noop_when_not_started() {
        let mut acc = StreamAccumulator::new();
        let events = acc.close_text(None);
        assert!(events.is_empty());
    }

    // ── take helpers ────────────────────────────────────────────────

    #[test]
    fn take_text_resets_buffer_and_flag() {
        let mut acc = StreamAccumulator::new();
        let _ = acc.process_text_delta("data");
        let text = acc.take_text();
        assert_eq!(text, "data");
        assert!(acc.accumulated_text.is_empty());
        assert!(!acc.text_started);
    }

    #[test]
    fn take_thinking_resets_buffer_and_flag() {
        let mut acc = StreamAccumulator::new();
        let _ = acc.process_thinking_delta("thought");
        let text = acc.take_thinking();
        assert_eq!(text, "thought");
        assert!(acc.accumulated_thinking.is_empty());
        assert!(!acc.thinking_started);
    }

    #[test]
    fn take_signature_returns_none_when_empty() {
        let mut acc = StreamAccumulator::new();
        assert!(acc.take_signature().is_none());
    }

    #[test]
    fn take_signature_returns_some_and_resets() {
        let mut acc = StreamAccumulator::new();
        acc.accumulate_signature("sig123");
        let sig = acc.take_signature();
        assert_eq!(sig.as_deref(), Some("sig123"));
        assert!(acc.accumulated_signature.is_empty());
    }

    // ── token tracking ──────────────────────────────────────────────

    #[test]
    fn set_tokens_updates_counts() {
        let mut acc = StreamAccumulator::new();
        acc.set_tokens(100, 50);
        assert_eq!(acc.input_tokens, 100);
        assert_eq!(acc.output_tokens, 50);
    }

    // ── capability_invocations accessor ─────────────────────────────────────────

    #[test]
    fn capability_invocations_returns_active_calls() {
        let mut acc = StreamAccumulator::new();
        let _ = acc.start_capability_invocation("a".into(), "tool_a".into());
        let _ = acc.start_capability_invocation("b".into(), "tool_b".into());
        assert_eq!(acc.capability_invocations().len(), 2);
        let _ = acc.finish_capability_invocation("a");
        assert_eq!(acc.capability_invocations().len(), 1);
        assert_eq!(acc.capability_invocations()[0].id, "b");
    }

    #[test]
    fn capability_invocation_mut_returns_mutable_ref() {
        let mut acc = StreamAccumulator::new();
        let _ = acc.start_capability_invocation("call_1".into(), "execute".into());
        let tc = acc.capability_invocation_mut("call_1").unwrap();
        tc.args.push_str("modified");
        assert_eq!(acc.capability_invocations()[0].args, "modified");
    }

    // ── full lifecycle ──────────────────────────────────────────────

    #[test]
    fn full_text_lifecycle() {
        let mut acc = StreamAccumulator::new();
        let e1 = acc.process_text_delta("Hello ");
        let e2 = acc.process_text_delta("world");
        let e3 = acc.close_text(None);

        assert_eq!(e1.len(), 2); // TextStart + TextDelta
        assert_eq!(e2.len(), 1); // TextDelta only
        assert_eq!(e3.len(), 1); // TextEnd
        match &e3[0] {
            StreamEvent::TextEnd { text, .. } => assert_eq!(text, "Hello world"),
            _ => panic!("expected TextEnd"),
        }
    }

    #[test]
    fn full_thinking_then_text_lifecycle() {
        let mut acc = StreamAccumulator::new();
        let _ = acc.process_thinking_delta("Let me think");
        let close_events = acc.close_thinking(Some("sig".into()));
        assert_eq!(close_events.len(), 1);

        let text_events = acc.process_text_delta("The answer");
        assert_eq!(text_events.len(), 2); // TextStart + TextDelta
    }

    #[test]
    fn full_capability_invocation_lifecycle() {
        let mut acc = StreamAccumulator::new();
        let start = acc.start_capability_invocation("call_1".into(), "execute".into());
        let d1 = acc.append_tool_args("call_1", r#"{"cm"#);
        let d2 = acc.append_tool_args("call_1", r#"d":"ls"}"#);
        let end = acc.finish_capability_invocation("call_1");

        assert_eq!(start.len(), 1);
        assert_eq!(d1.len(), 1);
        assert_eq!(d2.len(), 1);
        assert_eq!(end.len(), 1);
        match &end[0] {
            StreamEvent::CapabilityInvocationDraftEnd {
                capability_invocation,
            } => {
                assert_eq!(capability_invocation.id, "call_1");
                assert_eq!(capability_invocation.arguments["cmd"], "ls");
            }
            _ => panic!("expected CapabilityInvocationDraftEnd"),
        }
    }
}
