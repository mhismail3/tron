//! Turn accumulator — tracks in-progress turn content for session resume.
//!
//! When a client reconnects to a running session, `agent.getState` returns the
//! accumulated text, thinking, and tool calls so the UI can render catch-up
//! content without waiting for the next delta.
//!
//! ## Lifecycle
//!
//! - `TurnStart` → creates/resets the accumulator for that session
//! - `MessageUpdate` / `ThinkingDelta` / `ToolCall*` → appends to the accumulator
//! - `TurnEnd` / `AgentEnd` → removes the accumulator (turn is complete)
//!
//! ## Thread Safety
//!
//! [`TurnAccumulatorMap`] uses a `Mutex<HashMap>` for interior mutability.
//! The lock is held only for short, non-async operations.

use std::collections::HashMap;
use std::sync::Mutex;

use serde_json::Value;
use tron_core::events::TronEvent;

// ─────────────────────────────────────────────────────────────────────────────
// ContentSequenceItem
// ─────────────────────────────────────────────────────────────────────────────

/// Ordered content item within a turn (text, thinking, or tool reference).
#[derive(Clone, Debug, PartialEq)]
pub enum ContentSequenceItem {
    /// Accumulated text content.
    Text(String),
    /// Accumulated thinking content.
    Thinking(String),
    /// Reference to a tool call by ID.
    ToolRef { tool_call_id: String },
}

impl ContentSequenceItem {
    fn to_json(&self) -> Value {
        match self {
            Self::Text(t) => serde_json::json!({ "type": "text", "content": t }),
            Self::Thinking(t) => serde_json::json!({ "type": "thinking", "content": t }),
            Self::ToolRef { tool_call_id } => {
                serde_json::json!({ "type": "toolRef", "toolCallId": tool_call_id })
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// AccumulatedToolCall
// ─────────────────────────────────────────────────────────────────────────────

/// Snapshot of a tool call's progress within the current turn.
#[derive(Clone, Debug)]
pub struct AccumulatedToolCall {
    pub tool_call_id: String,
    pub tool_name: String,
    pub arguments: Option<Value>,
    pub status: String,
    pub result: Option<String>,
    pub is_error: bool,
    pub started_at: Option<String>,
    pub completed_at: Option<String>,
}

impl AccumulatedToolCall {
    fn to_json(&self) -> Value {
        let mut obj = serde_json::json!({
            "toolCallId": self.tool_call_id,
            "toolName": self.tool_name,
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
        obj
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// TurnAccumulator
// ─────────────────────────────────────────────────────────────────────────────

/// Accumulates content for a single in-progress turn.
pub struct TurnAccumulator {
    pub text: String,
    pub thinking: String,
    pub tool_calls: Vec<AccumulatedToolCall>,
    pub content_sequence: Vec<ContentSequenceItem>,
}

impl TurnAccumulator {
    pub fn new() -> Self {
        Self {
            text: String::new(),
            thinking: String::new(),
            tool_calls: Vec::new(),
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

    /// Add a new tool call in "generating" state.
    pub fn add_tool_generating(&mut self, tool_call_id: &str, tool_name: &str) {
        self.tool_calls.push(AccumulatedToolCall {
            tool_call_id: tool_call_id.to_string(),
            tool_name: tool_name.to_string(),
            arguments: None,
            status: "generating".to_string(),
            result: None,
            is_error: false,
            started_at: None,
            completed_at: None,
        });
        self.content_sequence.push(ContentSequenceItem::ToolRef {
            tool_call_id: tool_call_id.to_string(),
        });
    }

    /// Transition a tool call to "running" state.
    pub fn update_tool_start(&mut self, tool_call_id: &str, arguments: Option<&Value>) {
        if let Some(tc) = self
            .tool_calls
            .iter_mut()
            .find(|tc| tc.tool_call_id == tool_call_id)
        {
            tc.status = "running".to_string();
            tc.arguments = arguments.cloned();
            tc.started_at = Some(chrono::Utc::now().to_rfc3339());
        }
    }

    /// Transition a tool call to "completed" or "error" state.
    pub fn update_tool_end(
        &mut self,
        tool_call_id: &str,
        result: Option<&str>,
        is_error: bool,
    ) {
        if let Some(tc) = self
            .tool_calls
            .iter_mut()
            .find(|tc| tc.tool_call_id == tool_call_id)
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

    /// Serialize the current state to JSON triple: (text, tool_calls, content_sequence).
    pub fn to_json(&self) -> (String, Value, Value) {
        let tools = Value::Array(self.tool_calls.iter().map(AccumulatedToolCall::to_json).collect());
        let sequence = Value::Array(
            self.content_sequence
                .iter()
                .map(ContentSequenceItem::to_json)
                .collect(),
        );
        (self.text.clone(), tools, sequence)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// TurnAccumulatorMap
// ─────────────────────────────────────────────────────────────────────────────

/// Thread-safe map of session ID → `TurnAccumulator`.
pub struct TurnAccumulatorMap {
    accumulators: Mutex<HashMap<String, TurnAccumulator>>,
}

impl TurnAccumulatorMap {
    pub fn new() -> Self {
        Self {
            accumulators: Mutex::new(HashMap::new()),
        }
    }

    // ── Per-session mutation methods ──

    pub fn handle_turn_start(&self, session_id: &str) {
        self.accumulators
            .lock()
            .unwrap()
            .insert(session_id.to_string(), TurnAccumulator::new());
    }

    pub fn handle_turn_end(&self, session_id: &str) {
        self.accumulators.lock().unwrap().remove(session_id);
    }

    pub fn handle_agent_end(&self, session_id: &str) {
        self.accumulators.lock().unwrap().remove(session_id);
    }

    pub fn handle_text_delta(&self, session_id: &str, delta: &str) {
        if let Some(acc) = self.accumulators.lock().unwrap().get_mut(session_id) {
            acc.append_text(delta);
        }
    }

    pub fn handle_thinking_delta(&self, session_id: &str, delta: &str) {
        if let Some(acc) = self.accumulators.lock().unwrap().get_mut(session_id) {
            acc.append_thinking(delta);
        }
    }

    pub fn handle_tool_generating(&self, session_id: &str, tool_call_id: &str, tool_name: &str) {
        if let Some(acc) = self.accumulators.lock().unwrap().get_mut(session_id) {
            acc.add_tool_generating(tool_call_id, tool_name);
        }
    }

    pub fn handle_tool_start(&self, session_id: &str, tool_call_id: &str, arguments: Option<&Value>) {
        if let Some(acc) = self.accumulators.lock().unwrap().get_mut(session_id) {
            acc.update_tool_start(tool_call_id, arguments);
        }
    }

    pub fn handle_tool_end(
        &self,
        session_id: &str,
        tool_call_id: &str,
        result: Option<&str>,
        is_error: bool,
    ) {
        if let Some(acc) = self.accumulators.lock().unwrap().get_mut(session_id) {
            acc.update_tool_end(tool_call_id, result, is_error);
        }
    }

    // ── Query ──

    /// Get a serialized snapshot of the current turn state for a session.
    /// Returns `None` if no turn is in progress.
    pub fn get_state(&self, session_id: &str) -> Option<(String, Value, Value)> {
        let guard = self.accumulators.lock().unwrap();
        let result = guard.get(session_id).map(|acc| {
            tracing::info!(
                session_id,
                text_len = acc.text.len(),
                tool_count = acc.tool_calls.len(),
                seq_count = acc.content_sequence.len(),
                "accumulator: get_state returning data"
            );
            acc.to_json()
        });
        if result.is_none() {
            tracing::warn!(session_id, "accumulator: get_state found no accumulator for session");
        }
        result
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
            TronEvent::ToolCallGenerating {
                tool_call_id,
                tool_name,
                ..
            } => {
                self.handle_tool_generating(session_id, tool_call_id, tool_name);
            }
            TronEvent::ToolExecutionStart {
                tool_call_id,
                arguments,
                ..
            } => {
                let args_value = arguments
                    .as_ref()
                    .map(|m| Value::Object(m.clone()));
                self.handle_tool_start(session_id, tool_call_id, args_value.as_ref());
            }
            TronEvent::ToolExecutionEnd {
                tool_call_id,
                is_error,
                result,
                ..
            } => {
                let result_text = result.as_ref().map(|r| {
                    match &r.content {
                        tron_core::tools::ToolResultBody::Text(t) => t.clone(),
                        tron_core::tools::ToolResultBody::Blocks(blocks) => blocks
                            .iter()
                            .filter_map(|b| {
                                if let tron_core::content::ToolResultContent::Text { text } = b {
                                    Some(text.as_str())
                                } else {
                                    None
                                }
                            })
                            .collect::<Vec<_>>()
                            .join("\n"),
                    }
                });
                self.handle_tool_end(
                    session_id,
                    tool_call_id,
                    result_text.as_deref(),
                    is_error.unwrap_or(false),
                );
            }
            _ => {} // Irrelevant events are no-ops
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_core::events::BaseEvent;

    // ── TurnAccumulator unit tests ──

    #[test]
    fn new_accumulator_is_empty() {
        let acc = TurnAccumulator::new();
        assert!(acc.text.is_empty());
        assert!(acc.thinking.is_empty());
        assert!(acc.tool_calls.is_empty());
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
    fn add_tool_call_generating() {
        let mut acc = TurnAccumulator::new();
        acc.add_tool_generating("tc_1", "bash");
        assert_eq!(acc.tool_calls.len(), 1);
        assert_eq!(acc.tool_calls[0].tool_call_id, "tc_1");
        assert_eq!(acc.tool_calls[0].tool_name, "bash");
        assert_eq!(acc.tool_calls[0].status, "generating");
        assert_eq!(acc.content_sequence.len(), 1);
        assert!(matches!(
            &acc.content_sequence[0],
            ContentSequenceItem::ToolRef { tool_call_id } if tool_call_id == "tc_1"
        ));
    }

    #[test]
    fn update_tool_start() {
        let mut acc = TurnAccumulator::new();
        acc.add_tool_generating("tc_1", "bash");
        acc.update_tool_start("tc_1", Some(&serde_json::json!({"command": "ls"})));
        assert_eq!(acc.tool_calls[0].status, "running");
        assert!(acc.tool_calls[0].arguments.is_some());
        assert!(acc.tool_calls[0].started_at.is_some());
    }

    #[test]
    fn update_tool_end_success() {
        let mut acc = TurnAccumulator::new();
        acc.add_tool_generating("tc_1", "bash");
        acc.update_tool_start("tc_1", None);
        acc.update_tool_end("tc_1", Some("output"), false);
        assert_eq!(acc.tool_calls[0].status, "completed");
        assert_eq!(acc.tool_calls[0].result.as_deref(), Some("output"));
        assert!(!acc.tool_calls[0].is_error);
        assert!(acc.tool_calls[0].completed_at.is_some());
    }

    #[test]
    fn update_tool_end_error() {
        let mut acc = TurnAccumulator::new();
        acc.add_tool_generating("tc_1", "bash");
        acc.update_tool_start("tc_1", None);
        acc.update_tool_end("tc_1", Some("command not found"), true);
        assert_eq!(acc.tool_calls[0].status, "error");
        assert!(acc.tool_calls[0].is_error);
    }

    #[test]
    fn update_tool_unknown_id_is_noop() {
        let mut acc = TurnAccumulator::new();
        acc.update_tool_start("unknown", None);
        acc.update_tool_end("unknown", None, false);
        assert!(acc.tool_calls.is_empty());
    }

    #[test]
    fn multiple_tool_calls_tracked_independently() {
        let mut acc = TurnAccumulator::new();
        acc.add_tool_generating("tc_1", "bash");
        acc.add_tool_generating("tc_2", "read");
        acc.update_tool_start("tc_1", None);
        acc.update_tool_end("tc_1", Some("ok"), false);
        acc.update_tool_start("tc_2", None);

        assert_eq!(acc.tool_calls.len(), 2);
        assert_eq!(acc.tool_calls[0].status, "completed");
        assert_eq!(acc.tool_calls[1].status, "running");
    }

    #[test]
    fn text_after_tool_creates_new_text_item() {
        let mut acc = TurnAccumulator::new();
        acc.append_text("before ");
        acc.add_tool_generating("tc_1", "bash");
        acc.append_text("after");
        assert_eq!(acc.content_sequence.len(), 3);
        assert!(matches!(
            &acc.content_sequence[0],
            ContentSequenceItem::Text(t) if t == "before "
        ));
        assert!(matches!(
            &acc.content_sequence[1],
            ContentSequenceItem::ToolRef { .. }
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
        acc.add_tool_generating("tc_1", "bash");
        let (text, tools, sequence) = acc.to_json();
        assert_eq!(text, "hello");
        assert!(tools.is_array());
        assert_eq!(tools.as_array().unwrap().len(), 1);
        assert!(sequence.is_array());
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
        map.handle_tool_generating("s1", "tc_1", "bash");
        map.handle_tool_start("s1", "tc_1", None);
        map.handle_tool_end("s1", "tc_1", Some("output"), false);
        map.handle_text_delta("s1", " and more");

        let (text, tools, sequence) = map.get_state("s1").unwrap();
        assert_eq!(text, "The answer is 42 and more");
        assert_eq!(tools.as_array().unwrap().len(), 1);
        assert_eq!(tools[0]["status"], "completed");
        let seq = sequence.as_array().unwrap();
        assert_eq!(seq.len(), 4); // thinking, text, tool_ref, text
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
    fn update_from_tool_lifecycle_events() {
        let map = TurnAccumulatorMap::new();
        map.update_from_event(&TronEvent::TurnStart {
            base: BaseEvent::now("s1"),
            turn: 1,
        });
        map.update_from_event(&TronEvent::ToolCallGenerating {
            base: BaseEvent::now("s1"),
            tool_call_id: "tc_1".into(),
            tool_name: "bash".into(),
        });
        map.update_from_event(&TronEvent::ToolExecutionStart {
            base: BaseEvent::now("s1"),
            tool_call_id: "tc_1".into(),
            tool_name: "bash".into(),
            arguments: None,
        });
        map.update_from_event(&TronEvent::ToolExecutionEnd {
            base: BaseEvent::now("s1"),
            tool_call_id: "tc_1".into(),
            tool_name: "bash".into(),
            duration: 100,
            is_error: Some(false),
            result: None,
        });
        let (_, tools, _) = map.get_state("s1").unwrap();
        assert_eq!(tools[0]["status"], "completed");
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
