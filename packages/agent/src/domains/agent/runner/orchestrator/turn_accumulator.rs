//! Turn accumulator — tracks in-progress turn content for session resume.
//!
//! When a client reconnects to a running session, `session.reconstruct` returns
//! the accumulated text, thinking, and capability invocations as `inFlight` state so the UI
//! can render in-progress content without waiting for the next delta.
//!
//! ## Lifecycle
//!
//! - `TurnStart` → creates/resets the accumulator for that session
//! - `MessageUpdate` / `ThinkingDelta` / `CapabilityInvocation*` → appends to the accumulator
//! - `TurnEnd` / `AgentEnd` → removes the accumulator (turn is complete)
//!
//! ## Thread Safety
//!
//! [`TurnAccumulatorMap`] uses a `Mutex<HashMap>` for interior mutability.
//! The lock is held only for short, non-async operations.

use std::collections::HashMap;

use parking_lot::Mutex;

use crate::shared::events::TronEvent;
use serde_json::Value;

// ─────────────────────────────────────────────────────────────────────────────
// ContentSequenceItem
// ─────────────────────────────────────────────────────────────────────────────

/// Ordered content item within a turn (text, thinking, or capability reference).
#[derive(Clone, Debug, PartialEq)]
pub enum ContentSequenceItem {
    /// Accumulated text content.
    Text(String),
    /// Accumulated thinking content.
    Thinking(String),
    /// Reference to a capability invocation by ID.
    CapabilityRef {
        /// The capability invocation this item refers to.
        invocation_id: String,
    },
}

impl ContentSequenceItem {
    fn to_json(&self) -> Value {
        match self {
            Self::Text(t) => serde_json::json!({ "type": "text", "text": t }),
            Self::Thinking(t) => serde_json::json!({ "type": "thinking", "thinking": t }),
            Self::CapabilityRef { invocation_id } => {
                serde_json::json!({ "type": "capability_ref", "invocationId": invocation_id })
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// AccumulatedCapabilityInvocation
// ─────────────────────────────────────────────────────────────────────────────

/// Snapshot of a capability invocation's progress within the current turn.
#[derive(Clone, Debug)]
pub struct AccumulatedCapabilityInvocation {
    /// Unique identifier for this capability invocation.
    pub invocation_id: String,
    /// Model-facing primitive name (for example `execute` or `inspect`).
    pub model_primitive_name: String,
    /// Parsed arguments, populated when execution starts.
    pub arguments: Option<Value>,
    /// Lifecycle status: "generating", "running", "completed", or "error".
    pub status: String,
    /// Capability output text, populated on completion.
    pub result: Option<String>,
    /// Whether the capability invocation ended in error.
    pub is_error: bool,
    /// ISO-8601 timestamp when execution started.
    pub started_at: Option<String>,
    /// ISO-8601 timestamp when execution finished.
    pub completed_at: Option<String>,
    /// Progressive output accumulated during execution.
    pub streaming_output: Option<String>,
}

impl AccumulatedCapabilityInvocation {
    fn to_json(&self) -> Value {
        let mut obj = serde_json::json!({
            "invocationId": self.invocation_id,
            "modelPrimitiveName": self.model_primitive_name,
            "status": self.status,
            "isError": self.is_error,
        });
        if let Some(ref args) = self.arguments {
            obj["arguments"] = args.clone();
        }
        if let Some(ref result) = self.result {
            obj["result"] = Value::String(result.clone());
        }
        if let Some(ref started) = self.started_at {
            obj["startedAt"] = Value::String(started.clone());
        }
        if let Some(ref completed) = self.completed_at {
            obj["completedAt"] = Value::String(completed.clone());
        }
        if let Some(ref output) = self.streaming_output {
            obj["streamingOutput"] = Value::String(output.clone());
        }
        obj
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// CurrentCapabilitySnapshot
// ─────────────────────────────────────────────────────────────────────────────

/// Minimal projection of the capability currently executing within a
/// session's turn, returned by [`TurnAccumulatorMap::current_running_capability`].
///
/// Kept deliberately narrow — the `agent::status` capability wants human-readable
/// "what is the agent doing" info, not the full accumulator state.
#[derive(Clone, Debug, PartialEq)]
pub struct CurrentCapabilitySnapshot {
    /// The model-facing primitive or resolved capability name.
    pub model_primitive_name: String,
    /// Unique ID of the in-flight capability invocation.
    pub invocation_id: String,
    /// ISO-8601 timestamp when execution started. Lets callers compute
    /// elapsed duration without a separate clock fetch.
    pub started_at: Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// TurnAccumulator
// ─────────────────────────────────────────────────────────────────────────────

/// Accumulates content for a single in-progress turn.
#[derive(Default)]
pub struct TurnAccumulator {
    /// Concatenated assistant text output so far.
    pub text: String,
    /// Concatenated thinking/reasoning output so far.
    pub thinking: String,
    /// All capability invocations tracked in this turn.
    pub capability_invocations: Vec<AccumulatedCapabilityInvocation>,
    /// Ordered sequence of content items (text, thinking, capability refs).
    pub content_sequence: Vec<ContentSequenceItem>,
}

impl TurnAccumulator {
    /// Create an empty accumulator.
    pub fn new() -> Self {
        Self {
            text: String::new(),
            thinking: String::new(),
            capability_invocations: Vec::new(),
            content_sequence: Vec::new(),
        }
    }

    /// Append text, coalescing with the last Text item in the sequence.
    pub fn append_text(&mut self, delta: &str) {
        self.text.push_str(delta);
        if let Some(ContentSequenceItem::Text(t)) = self.content_sequence.last_mut() {
            t.push_str(delta);
        } else {
            self.content_sequence
                .push(ContentSequenceItem::Text(delta.to_string()));
        }
    }

    /// Append thinking content, coalescing with the last Thinking item in the sequence.
    pub fn append_thinking(&mut self, delta: &str) {
        self.thinking.push_str(delta);
        if let Some(ContentSequenceItem::Thinking(t)) = self.content_sequence.last_mut() {
            t.push_str(delta);
        } else {
            self.content_sequence
                .push(ContentSequenceItem::Thinking(delta.to_string()));
        }
    }

    /// Add a new capability invocation in "generating" state.
    pub fn add_capability_generating(&mut self, invocation_id: &str, model_primitive_name: &str) {
        self.capability_invocations
            .push(AccumulatedCapabilityInvocation {
                invocation_id: invocation_id.to_string(),
                model_primitive_name: model_primitive_name.to_string(),
                arguments: None,
                status: "generating".to_string(),
                result: None,
                is_error: false,
                started_at: None,
                completed_at: None,
                streaming_output: None,
            });
        self.content_sequence
            .push(ContentSequenceItem::CapabilityRef {
                invocation_id: invocation_id.to_string(),
            });
    }

    /// Transition a capability invocation to "running" state.
    pub fn update_capability_started(&mut self, invocation_id: &str, arguments: Option<&Value>) {
        if let Some(tc) = self
            .capability_invocations
            .iter_mut()
            .find(|tc| tc.invocation_id == invocation_id)
        {
            tc.status = "running".to_string();
            tc.arguments = arguments.cloned();
            tc.started_at = Some(chrono::Utc::now().to_rfc3339());
        }
    }

    /// Transition a capability invocation to "completed" or "error" state.
    pub fn update_capability_completed(
        &mut self,
        invocation_id: &str,
        result: Option<&str>,
        is_error: bool,
    ) {
        if let Some(tc) = self
            .capability_invocations
            .iter_mut()
            .find(|tc| tc.invocation_id == invocation_id)
        {
            tc.status = if is_error {
                "error".to_string()
            } else {
                "completed".to_string()
            };
            tc.result = result.map(str::to_string);
            tc.is_error = is_error;
            tc.completed_at = Some(chrono::Utc::now().to_rfc3339());
        }
    }

    /// Serialize the current state to JSON triple: (text, `capability_invocations`, `content_sequence`).
    pub fn to_json(&self) -> (String, Value, Value) {
        let capabilities = Value::Array(
            self.capability_invocations
                .iter()
                .map(AccumulatedCapabilityInvocation::to_json)
                .collect(),
        );
        let sequence = Value::Array(
            self.content_sequence
                .iter()
                .map(ContentSequenceItem::to_json)
                .collect(),
        );
        (self.text.clone(), capabilities, sequence)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// TurnAccumulatorMap
// ─────────────────────────────────────────────────────────────────────────────

/// Thread-safe map of session ID → `TurnAccumulator`.
#[derive(Default)]
pub struct TurnAccumulatorMap {
    accumulators: Mutex<HashMap<String, TurnAccumulator>>,
}

impl TurnAccumulatorMap {
    /// Create an empty accumulator map.
    pub fn new() -> Self {
        Self {
            accumulators: Mutex::new(HashMap::new()),
        }
    }

    // ── Per-session mutation methods ──

    /// Reset (or create) the accumulator for a session.
    pub fn handle_turn_start(&self, session_id: &str) {
        let _ = self
            .accumulators
            .lock()
            .insert(session_id.to_string(), TurnAccumulator::new());
    }

    /// Remove the accumulator when a turn ends.
    pub fn handle_turn_end(&self, session_id: &str) {
        let _ = self.accumulators.lock().remove(session_id);
    }

    /// Remove the accumulator when the agent ends.
    pub fn handle_agent_end(&self, session_id: &str) {
        let _ = self.accumulators.lock().remove(session_id);
    }

    /// Append a text delta to the session's accumulator.
    pub fn handle_text_delta(&self, session_id: &str, delta: &str) {
        if let Some(acc) = self.accumulators.lock().get_mut(session_id) {
            acc.append_text(delta);
        }
    }

    /// Append a thinking delta to the session's accumulator.
    pub fn handle_thinking_delta(&self, session_id: &str, delta: &str) {
        if let Some(acc) = self.accumulators.lock().get_mut(session_id) {
            acc.append_thinking(delta);
        }
    }

    /// Record a new capability invocation in "generating" state.
    pub fn handle_capability_generating(
        &self,
        session_id: &str,
        invocation_id: &str,
        model_primitive_name: &str,
    ) {
        if let Some(acc) = self.accumulators.lock().get_mut(session_id) {
            acc.add_capability_generating(invocation_id, model_primitive_name);
        }
    }

    /// Transition a capability invocation to "running" state.
    pub fn handle_capability_started(
        &self,
        session_id: &str,
        invocation_id: &str,
        arguments: Option<&Value>,
    ) {
        if let Some(acc) = self.accumulators.lock().get_mut(session_id) {
            acc.update_capability_started(invocation_id, arguments);
        }
    }

    /// Append streaming output to a running capability invocation.
    pub fn handle_capability_output(&self, session_id: &str, invocation_id: &str, output: &str) {
        if let Some(acc) = self.accumulators.lock().get_mut(session_id)
            && let Some(tc) = acc
                .capability_invocations
                .iter_mut()
                .find(|tc| tc.invocation_id == invocation_id)
        {
            let streaming = tc.streaming_output.get_or_insert_with(String::new);
            streaming.push_str(output);
        }
    }

    /// Record capability completion or error.
    pub fn handle_capability_completed(
        &self,
        session_id: &str,
        invocation_id: &str,
        result: Option<&str>,
        is_error: bool,
    ) {
        if let Some(acc) = self.accumulators.lock().get_mut(session_id) {
            acc.update_capability_completed(invocation_id, result, is_error);
        }
    }

    // ── Query ──

    /// Get a serialized snapshot of the current turn state for a session.
    /// Returns `None` if no turn is in progress.
    pub fn get_state(&self, session_id: &str) -> Option<(String, Value, Value)> {
        let guard = self.accumulators.lock();
        let result = guard.get(session_id).map(|acc| {
            tracing::info!(
                session_id,
                text_len = acc.text.len(),
                capability_count = acc.capability_invocations.len(),
                seq_count = acc.content_sequence.len(),
                "accumulator: get_state returning data"
            );
            acc.to_json()
        });
        if result.is_none() {
            tracing::warn!(
                session_id,
                "accumulator: get_state found no accumulator for session"
            );
        }
        result
    }

    /// Name of the capability currently executing in the session's turn,
    /// if any. Returns the model-facing primitive of the most recently-started invocation
    /// whose status is `running` (capability.invocation.started persisted; capability.invocation.completed not
    /// yet). `generating` doesn't count — the LLM is still streaming
    /// the capability_invocation block and hasn't begun execution. Returns `None`
    /// when no turn is in flight or no capability has entered `running`.
    pub fn current_running_capability(
        &self,
        session_id: &str,
    ) -> Option<CurrentCapabilitySnapshot> {
        let guard = self.accumulators.lock();
        let acc = guard.get(session_id)?;
        // Iterate from the end: the most recent running invocation wins. Capability
        // calls can run in parallel within one turn; the "current capability"
        // returned here is the most recently started. Callers that need
        // the full set should use `get_state` which exposes every
        // capability_invocation.
        acc.capability_invocations
            .iter()
            .rev()
            .find(|tc| tc.status == "running")
            .map(|tc| CurrentCapabilitySnapshot {
                model_primitive_name: tc.model_primitive_name.clone(),
                invocation_id: tc.invocation_id.clone(),
                started_at: tc.started_at.clone(),
            })
    }

    // ── Event dispatch ──

    /// Route a `TronEvent` to the appropriate handler method.
    pub fn update_from_event(&self, event: &TronEvent) {
        let session_id = event.session_id();
        match event {
            TronEvent::TurnStart { turn, .. } => {
                tracing::debug!(session_id, turn, "accumulator: turn_start");
                self.handle_turn_start(session_id);
            }
            TronEvent::TurnEnd { turn, .. } => {
                tracing::debug!(session_id, turn, "accumulator: turn_end (clearing)");
                self.handle_turn_end(session_id);
            }
            TronEvent::AgentEnd { .. } => {
                tracing::debug!(session_id, "accumulator: agent_end (clearing)");
                self.handle_agent_end(session_id);
            }
            TronEvent::MessageUpdate { content, .. } => {
                tracing::trace!(session_id, len = content.len(), "accumulator: text_delta");
                self.handle_text_delta(session_id, content);
            }
            TronEvent::ThinkingDelta { delta, .. } => {
                self.handle_thinking_delta(session_id, delta);
            }
            TronEvent::CapabilityInvocationGenerating {
                invocation_id,
                model_primitive_name,
                ..
            } => {
                self.handle_capability_generating(session_id, invocation_id, model_primitive_name);
            }
            TronEvent::CapabilityInvocationStarted {
                invocation_id,
                arguments,
                ..
            } => {
                let args_value = arguments.as_ref().map(|m| Value::Object(m.clone()));
                self.handle_capability_started(session_id, invocation_id, args_value.as_ref());
            }
            TronEvent::CapabilityInvocationCompleted {
                invocation_id,
                is_error,
                result,
                ..
            } => {
                let result_text = result.as_ref().map(|r| match &r.content {
                    crate::shared::model_capabilities::CapabilityResultBody::Text(t) => t.clone(),
                    crate::shared::model_capabilities::CapabilityResultBody::Blocks(blocks) => {
                        blocks
                            .iter()
                            .filter_map(|b| {
                                if let crate::shared::content::CapabilityResultContent::Text {
                                    text,
                                } = b
                                {
                                    Some(text.as_str())
                                } else {
                                    None
                                }
                            })
                            .collect::<Vec<_>>()
                            .join("\n")
                    }
                });
                self.handle_capability_completed(
                    session_id,
                    invocation_id,
                    result_text.as_deref(),
                    is_error.unwrap_or(false),
                );
            }
            TronEvent::CapabilityInvocationOutput {
                invocation_id,
                update,
                ..
            } => {
                self.handle_capability_output(session_id, invocation_id, update);
            }
            _ => {} // Irrelevant events are no-ops
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shared::events::BaseEvent;

    // ── TurnAccumulator unit tests ──

    #[test]
    fn new_accumulator_is_empty() {
        let acc = TurnAccumulator::new();
        assert!(acc.text.is_empty());
        assert!(acc.thinking.is_empty());
        assert!(acc.capability_invocations.is_empty());
        assert!(acc.content_sequence.is_empty());
    }

    #[test]
    fn append_text_accumulates() {
        let mut acc = TurnAccumulator::new();
        acc.append_text("Hello ");
        acc.append_text("world");
        assert_eq!(acc.text, "Hello world");
    }

    #[test]
    fn append_text_updates_content_sequence() {
        let mut acc = TurnAccumulator::new();
        acc.append_text("Hello ");
        acc.append_text("world");
        assert_eq!(acc.content_sequence.len(), 1);
        assert!(matches!(
            &acc.content_sequence[0],
            ContentSequenceItem::Text(t) if t == "Hello world"
        ));
    }

    #[test]
    fn append_thinking_accumulates() {
        let mut acc = TurnAccumulator::new();
        acc.append_thinking("step 1 ");
        acc.append_thinking("step 2");
        assert_eq!(acc.thinking, "step 1 step 2");
    }

    #[test]
    fn append_thinking_updates_content_sequence() {
        let mut acc = TurnAccumulator::new();
        acc.append_thinking("think");
        assert_eq!(acc.content_sequence.len(), 1);
        assert!(matches!(
            &acc.content_sequence[0],
            ContentSequenceItem::Thinking(t) if t == "think"
        ));
    }

    #[test]
    fn interleaved_text_and_thinking_creates_separate_sequence_items() {
        let mut acc = TurnAccumulator::new();
        acc.append_thinking("hmm");
        acc.append_text("answer");
        assert_eq!(acc.content_sequence.len(), 2);
        assert!(matches!(
            &acc.content_sequence[0],
            ContentSequenceItem::Thinking(_)
        ));
        assert!(matches!(
            &acc.content_sequence[1],
            ContentSequenceItem::Text(_)
        ));
    }

    #[test]
    fn add_capability_invocation_generating() {
        let mut acc = TurnAccumulator::new();
        acc.add_capability_generating("tc_1", "execute");
        assert_eq!(acc.capability_invocations.len(), 1);
        assert_eq!(acc.capability_invocations[0].invocation_id, "tc_1");
        assert_eq!(
            acc.capability_invocations[0].model_primitive_name,
            "execute"
        );
        assert_eq!(acc.capability_invocations[0].status, "generating");
        assert_eq!(acc.content_sequence.len(), 1);
        assert!(matches!(
            &acc.content_sequence[0],
            ContentSequenceItem::CapabilityRef { invocation_id } if invocation_id == "tc_1"
        ));
    }

    #[test]
    fn update_capability_started() {
        let mut acc = TurnAccumulator::new();
        acc.add_capability_generating("tc_1", "execute");
        acc.update_capability_started("tc_1", Some(&serde_json::json!({"command": "ls"})));
        assert_eq!(acc.capability_invocations[0].status, "running");
        assert!(acc.capability_invocations[0].arguments.is_some());
        assert!(acc.capability_invocations[0].started_at.is_some());
    }

    #[test]
    fn update_capability_completed_success() {
        let mut acc = TurnAccumulator::new();
        acc.add_capability_generating("tc_1", "execute");
        acc.update_capability_started("tc_1", None);
        acc.update_capability_completed("tc_1", Some("output"), false);
        assert_eq!(acc.capability_invocations[0].status, "completed");
        assert_eq!(
            acc.capability_invocations[0].result.as_deref(),
            Some("output")
        );
        assert!(!acc.capability_invocations[0].is_error);
        assert!(acc.capability_invocations[0].completed_at.is_some());
    }

    #[test]
    fn update_capability_completed_error() {
        let mut acc = TurnAccumulator::new();
        acc.add_capability_generating("tc_1", "execute");
        acc.update_capability_started("tc_1", None);
        acc.update_capability_completed("tc_1", Some("command not found"), true);
        assert_eq!(acc.capability_invocations[0].status, "error");
        assert!(acc.capability_invocations[0].is_error);
    }

    #[test]
    fn update_capability_unknown_id_is_noop() {
        let mut acc = TurnAccumulator::new();
        acc.update_capability_started("unknown", None);
        acc.update_capability_completed("unknown", None, false);
        assert!(acc.capability_invocations.is_empty());
    }

    #[test]
    fn multiple_capability_invocations_tracked_independently() {
        let mut acc = TurnAccumulator::new();
        acc.add_capability_generating("tc_1", "execute");
        acc.add_capability_generating("tc_2", "inspect");
        acc.update_capability_started("tc_1", None);
        acc.update_capability_completed("tc_1", Some("ok"), false);
        acc.update_capability_started("tc_2", None);

        assert_eq!(acc.capability_invocations.len(), 2);
        assert_eq!(acc.capability_invocations[0].status, "completed");
        assert_eq!(acc.capability_invocations[1].status, "running");
    }

    #[test]
    fn text_after_capability_creates_new_text_item() {
        let mut acc = TurnAccumulator::new();
        acc.append_text("before ");
        acc.add_capability_generating("tc_1", "execute");
        acc.append_text("after");
        assert_eq!(acc.content_sequence.len(), 3);
        assert!(matches!(
            &acc.content_sequence[0],
            ContentSequenceItem::Text(t) if t == "before "
        ));
        assert!(matches!(
            &acc.content_sequence[1],
            ContentSequenceItem::CapabilityRef { .. }
        ));
        assert!(matches!(
            &acc.content_sequence[2],
            ContentSequenceItem::Text(t) if t == "after"
        ));
    }

    #[test]
    fn to_json_produces_expected_format() {
        let mut acc = TurnAccumulator::new();
        acc.append_text("hello");
        acc.add_capability_generating("tc_1", "execute");
        let (text, capabilities, sequence) = acc.to_json();
        assert_eq!(text, "hello");
        assert!(capabilities.is_array());
        assert_eq!(capabilities.as_array().unwrap().len(), 1);
        assert!(sequence.is_array());
    }

    // ── ContentSequenceItem::to_json key tests (Phase 1 fix) ──

    #[test]
    fn to_json_text_uses_text_key() {
        let item = ContentSequenceItem::Text("hello".into());
        let json = item.to_json();
        assert_eq!(json["type"], "text");
        assert_eq!(json["text"], "hello");
        assert!(json.get("content").is_none());
    }

    #[test]
    fn to_json_thinking_uses_thinking_key() {
        let item = ContentSequenceItem::Thinking("hmm".into());
        let json = item.to_json();
        assert_eq!(json["type"], "thinking");
        assert_eq!(json["thinking"], "hmm");
        assert!(json.get("content").is_none());
    }

    #[test]
    fn to_json_capability_ref_uses_snake_case_type() {
        let item = ContentSequenceItem::CapabilityRef {
            invocation_id: "tc_1".into(),
        };
        let json = item.to_json();
        assert_eq!(json["type"], "capability_ref");
        assert_eq!(json["invocationId"], "tc_1");
    }

    // ── Streaming output tests (Phase 2) ──

    #[test]
    fn capability_streaming_output_accumulates() {
        let mut acc = TurnAccumulator::new();
        acc.add_capability_generating("tc_1", "execute");
        acc.update_capability_started("tc_1", None);
        let tc = &mut acc.capability_invocations[0];
        let streaming = tc.streaming_output.get_or_insert_with(String::new);
        streaming.push_str("line 1\n");
        streaming.push_str("line 2\n");
        assert_eq!(
            acc.capability_invocations[0].streaming_output.as_deref(),
            Some("line 1\nline 2\n")
        );
    }

    #[test]
    fn capability_streaming_output_included_in_json() {
        let mut acc = TurnAccumulator::new();
        acc.add_capability_generating("tc_1", "execute");
        acc.update_capability_started("tc_1", None);
        acc.capability_invocations[0].streaming_output = Some("partial output".into());
        let (_, capabilities, _) = acc.to_json();
        assert_eq!(capabilities[0]["streamingOutput"], "partial output");
    }

    #[test]
    fn capability_streaming_output_omitted_when_none() {
        let mut acc = TurnAccumulator::new();
        acc.add_capability_generating("tc_1", "execute");
        let (_, capabilities, _) = acc.to_json();
        assert!(capabilities[0].get("streamingOutput").is_none());
    }

    // ── TurnAccumulatorMap tests ──

    #[test]
    fn map_create_and_get() {
        let map = TurnAccumulatorMap::new();
        map.handle_turn_start("s1");
        let state = map.get_state("s1");
        assert!(state.is_some());
    }

    #[test]
    fn map_get_nonexistent_returns_none() {
        let map = TurnAccumulatorMap::new();
        assert!(map.get_state("missing").is_none());
    }

    #[test]
    fn map_turn_start_resets_existing() {
        let map = TurnAccumulatorMap::new();
        map.handle_turn_start("s1");
        map.handle_text_delta("s1", "old text");
        map.handle_turn_start("s1");
        let (text, _, _) = map.get_state("s1").unwrap();
        assert!(text.is_empty());
    }

    #[test]
    fn map_agent_end_removes_accumulator() {
        let map = TurnAccumulatorMap::new();
        map.handle_turn_start("s1");
        map.handle_text_delta("s1", "hello");
        map.handle_agent_end("s1");
        assert!(map.get_state("s1").is_none());
    }

    #[test]
    fn map_turn_end_removes_accumulator() {
        let map = TurnAccumulatorMap::new();
        map.handle_turn_start("s1");
        map.handle_text_delta("s1", "hello");
        map.handle_turn_end("s1");
        assert!(map.get_state("s1").is_none());
    }

    #[test]
    fn map_text_delta_without_turn_start_is_noop() {
        let map = TurnAccumulatorMap::new();
        map.handle_text_delta("s1", "orphan");
        assert!(map.get_state("s1").is_none());
    }

    #[test]
    fn map_full_event_sequence() {
        let map = TurnAccumulatorMap::new();
        map.handle_turn_start("s1");
        map.handle_thinking_delta("s1", "let me think...");
        map.handle_text_delta("s1", "The answer is ");
        map.handle_text_delta("s1", "42");
        map.handle_capability_generating("s1", "tc_1", "execute");
        map.handle_capability_started("s1", "tc_1", None);
        map.handle_capability_completed("s1", "tc_1", Some("output"), false);
        map.handle_text_delta("s1", " and more");

        let (text, capabilities, sequence) = map.get_state("s1").unwrap();
        assert_eq!(text, "The answer is 42 and more");
        assert_eq!(capabilities.as_array().unwrap().len(), 1);
        assert_eq!(capabilities[0]["status"], "completed");
        let seq = sequence.as_array().unwrap();
        assert_eq!(seq.len(), 4); // thinking, text, capability_ref, text
    }

    #[test]
    fn map_capability_streaming_output() {
        let map = TurnAccumulatorMap::new();
        map.handle_turn_start("s1");
        map.handle_capability_generating("s1", "tc_1", "execute");
        map.handle_capability_started("s1", "tc_1", None);
        map.handle_capability_output("s1", "tc_1", "partial ");
        map.handle_capability_output("s1", "tc_1", "output");
        let (_, capabilities, _) = map.get_state("s1").unwrap();
        assert_eq!(capabilities[0]["streamingOutput"], "partial output");
    }

    #[test]
    fn map_independent_sessions() {
        let map = TurnAccumulatorMap::new();
        map.handle_turn_start("s1");
        map.handle_turn_start("s2");
        map.handle_text_delta("s1", "session 1");
        map.handle_text_delta("s2", "session 2");

        let (text1, _, _) = map.get_state("s1").unwrap();
        let (text2, _, _) = map.get_state("s2").unwrap();
        assert_eq!(text1, "session 1");
        assert_eq!(text2, "session 2");
    }

    #[test]
    fn map_agent_end_one_session_doesnt_affect_other() {
        let map = TurnAccumulatorMap::new();
        map.handle_turn_start("s1");
        map.handle_turn_start("s2");
        map.handle_text_delta("s1", "s1");
        map.handle_text_delta("s2", "s2");
        map.handle_agent_end("s1");

        assert!(map.get_state("s1").is_none());
        assert!(map.get_state("s2").is_some());
    }

    // ── Integration: update_from_event tests ──

    #[test]
    fn update_from_turn_start_event() {
        let map = TurnAccumulatorMap::new();
        let event = TronEvent::TurnStart {
            base: BaseEvent::now("s1"),
            turn: 1,
        };
        map.update_from_event(&event);
        assert!(map.get_state("s1").is_some());
    }

    #[test]
    fn update_from_message_update_event() {
        let map = TurnAccumulatorMap::new();
        map.update_from_event(&TronEvent::TurnStart {
            base: BaseEvent::now("s1"),
            turn: 1,
        });
        map.update_from_event(&TronEvent::MessageUpdate {
            base: BaseEvent::now("s1"),
            content: "hello".into(),
        });
        let (text, _, _) = map.get_state("s1").unwrap();
        assert_eq!(text, "hello");
    }

    #[test]
    fn update_from_thinking_delta_event() {
        let map = TurnAccumulatorMap::new();
        map.update_from_event(&TronEvent::TurnStart {
            base: BaseEvent::now("s1"),
            turn: 1,
        });
        map.update_from_event(&TronEvent::ThinkingDelta {
            base: BaseEvent::now("s1"),
            delta: "hmm".into(),
        });
        let (_, _, sequence) = map.get_state("s1").unwrap();
        let seq = sequence.as_array().unwrap();
        assert_eq!(seq.len(), 1);
        assert_eq!(seq[0]["type"], "thinking");
    }

    #[test]
    fn update_from_capability_lifecycle_events() {
        let map = TurnAccumulatorMap::new();
        map.update_from_event(&TronEvent::TurnStart {
            base: BaseEvent::now("s1"),
            turn: 1,
        });
        map.update_from_event(&TronEvent::CapabilityInvocationGenerating {
            base: BaseEvent::now("s1"),
            invocation_id: "tc_1".into(),
            model_primitive_name: "execute".into(),
            capability_identity: crate::shared::events::CapabilityEventIdentity::default(),
        });
        map.update_from_event(&TronEvent::CapabilityInvocationStarted {
            base: BaseEvent::now("s1"),
            invocation_id: "tc_1".into(),
            model_primitive_name: "execute".into(),
            arguments: None,
            capability_identity: crate::shared::events::CapabilityEventIdentity::default(),
        });
        map.update_from_event(&TronEvent::CapabilityInvocationCompleted {
            base: BaseEvent::now("s1"),
            invocation_id: "tc_1".into(),
            model_primitive_name: "execute".into(),
            duration: 100,
            is_error: Some(false),
            result: None,
            capability_identity: crate::shared::events::CapabilityEventIdentity::default(),
        });
        let (_, capabilities, _) = map.get_state("s1").unwrap();
        assert_eq!(capabilities[0]["status"], "completed");
    }

    #[test]
    fn update_from_capability_invocation_output_event() {
        let map = TurnAccumulatorMap::new();
        map.update_from_event(&TronEvent::TurnStart {
            base: BaseEvent::now("s1"),
            turn: 1,
        });
        map.update_from_event(&TronEvent::CapabilityInvocationGenerating {
            base: BaseEvent::now("s1"),
            invocation_id: "tc_1".into(),
            model_primitive_name: "execute".into(),
            capability_identity: crate::shared::events::CapabilityEventIdentity::default(),
        });
        map.update_from_event(&TronEvent::CapabilityInvocationStarted {
            base: BaseEvent::now("s1"),
            invocation_id: "tc_1".into(),
            model_primitive_name: "execute".into(),
            arguments: None,
            capability_identity: crate::shared::events::CapabilityEventIdentity::default(),
        });
        map.update_from_event(&TronEvent::CapabilityInvocationOutput {
            base: BaseEvent::now("s1"),
            invocation_id: "tc_1".into(),
            update: "line 1\n".into(),
        });
        map.update_from_event(&TronEvent::CapabilityInvocationOutput {
            base: BaseEvent::now("s1"),
            invocation_id: "tc_1".into(),
            update: "line 2\n".into(),
        });
        let (_, capabilities, _) = map.get_state("s1").unwrap();
        assert_eq!(capabilities[0]["streamingOutput"], "line 1\nline 2\n");
    }

    #[test]
    fn update_from_agent_end_clears() {
        let map = TurnAccumulatorMap::new();
        map.update_from_event(&TronEvent::TurnStart {
            base: BaseEvent::now("s1"),
            turn: 1,
        });
        map.update_from_event(&TronEvent::MessageUpdate {
            base: BaseEvent::now("s1"),
            content: "hi".into(),
        });
        map.update_from_event(&TronEvent::AgentEnd {
            base: BaseEvent::now("s1"),
            error: None,
        });
        assert!(map.get_state("s1").is_none());
    }

    #[test]
    fn update_from_turn_end_clears() {
        let map = TurnAccumulatorMap::new();
        map.update_from_event(&TronEvent::TurnStart {
            base: BaseEvent::now("s1"),
            turn: 1,
        });
        map.update_from_event(&TronEvent::MessageUpdate {
            base: BaseEvent::now("s1"),
            content: "hi".into(),
        });
        map.update_from_event(&TronEvent::TurnEnd {
            base: BaseEvent::now("s1"),
            turn: 1,
            duration: 0,
            token_usage: None,
            token_record: None,
            cost: None,
            stop_reason: None,
            context_limit: None,
            model: None,
        });
        assert!(map.get_state("s1").is_none());
    }

    #[test]
    fn update_ignores_irrelevant_events() {
        let map = TurnAccumulatorMap::new();
        map.update_from_event(&TronEvent::AgentStart {
            base: BaseEvent::now("s1"),
        });
        map.update_from_event(&TronEvent::AgentReady {
            base: BaseEvent::now("s1"),
        });
        assert!(map.get_state("s1").is_none());
    }
}
