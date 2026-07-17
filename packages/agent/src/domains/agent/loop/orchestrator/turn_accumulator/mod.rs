//! Turn accumulator — tracks in-progress turn content for session resume.
//!
//! When a client reconnects to a running session, `session.reconstruct` returns
//! the accumulated text, thinking, and capability invocations as `inFlight` state so the UI
//! can render in-progress content without waiting for the next delta.
//!
//! ## Lifecycle
//!
//! - `TurnStart` → creates/resets the accumulator for that session
//! - streamed content and capability lifecycle/progress → update reconnect state
//! - compaction lifecycle → update reconnect-visible compaction state
//! - `TurnEnd` / `AgentEnd` → clear turn state while retaining processing ownership
//! - matching run release → atomically ends processing/admission ownership
//! - matching `StartedRun` drop → removes the completed run projection
//!
//! ## Thread Safety
//!
//! [`TurnAccumulatorMap`] uses a `Mutex<HashMap>` for interior mutability.
//! The lock is held only for short, non-async operations. [`EventEmitter`](crate::domains::agent::r#loop::event_emitter::EventEmitter)
//! invokes this observer synchronously before broadcast, committing projection
//! state and its source sequence together. The lossy async stream pump is not a
//! reconstruction-state owner.

use std::collections::HashMap;

use parking_lot::Mutex;

use crate::domains::agent::r#loop::event_emitter::TronEventObserver;
use crate::shared::protocol::content::ThinkingContentKind;
use crate::shared::protocol::events::{CapabilityEventIdentity, TronEvent};
use serde_json::Value;

// ─────────────────────────────────────────────────────────────────────────────
// ContentSequenceItem
// ─────────────────────────────────────────────────────────────────────────────

/// Ordered content item within a turn (text, thinking, or capability reference).
#[derive(Clone, Debug, PartialEq)]
pub enum ContentSequenceItem {
    /// Accumulated text content.
    Text(String),
    /// Accumulated thinking-like content.
    Thinking {
        /// The accumulated text.
        text: String,
        /// Source contract for the text.
        kind: ThinkingContentKind,
    },
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
            Self::Thinking { text, kind } => {
                let mut item = serde_json::json!({ "type": "thinking", "thinking": text });
                if *kind != ThinkingContentKind::Thinking {
                    item["kind"] = serde_json::json!(kind);
                }
                item
            }
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
    /// Lifecycle status: "generating", "running", "paused", "completed", or "error".
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
    /// Latest human-readable progress status.
    pub progress_message: Option<String>,
    /// Latest 0.0–1.0 progress fraction.
    pub progress_percent: Option<f64>,
    /// Latest async-run detail projection.
    pub details: Option<Value>,
    /// Provider-visible operation and presentation identity.
    pub capability_identity: CapabilityEventIdentity,
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
        if let Some(ref message) = self.progress_message {
            obj["progressMessage"] = Value::String(message.clone());
        }
        if let Some(percent) = self.progress_percent {
            obj["progressPercent"] = serde_json::json!(percent);
        }
        if let Some(ref details) = self.details {
            obj["details"] = details.clone();
        }
        if let Ok(Value::Object(identity)) = serde_json::to_value(&self.capability_identity) {
            for (key, value) in identity {
                obj[&key] = value;
            }
        }
        obj
    }

    fn merge_identity(&mut self, identity: &CapabilityEventIdentity) {
        if identity.model_primitive_name.is_some() {
            self.capability_identity.model_primitive_name = identity.model_primitive_name.clone();
        }
        if identity.operation_name.is_some() {
            self.capability_identity.operation_name = identity.operation_name.clone();
        }
        if identity.trace_id.is_some() {
            self.capability_identity.trace_id = identity.trace_id.clone();
        }
        if identity.root_invocation_id.is_some() {
            self.capability_identity.root_invocation_id = identity.root_invocation_id.clone();
        }
        if identity.theme_color.is_some() {
            self.capability_identity.theme_color = identity.theme_color.clone();
        }
        if identity.presentation_hints.is_some() {
            self.capability_identity.presentation_hints = identity.presentation_hints.clone();
        }
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
    /// Concatenated thinking/reasoning output so far. `ThinkingEnd` replaces
    /// this with the server-authoritative final snapshot.
    pub thinking: String,
    /// All capability invocations tracked in this turn.
    pub capability_invocations: Vec<AccumulatedCapabilityInvocation>,
    /// Ordered sequence of content items (text, thinking, capability refs).
    pub content_sequence: Vec<ContentSequenceItem>,
    /// Whether the provider response has finished streaming. Capability
    /// execution may keep the turn active after this boundary.
    pub response_complete: bool,
}

impl TurnAccumulator {
    /// Create an empty accumulator.
    pub fn new() -> Self {
        Self {
            text: String::new(),
            thinking: String::new(),
            capability_invocations: Vec::new(),
            content_sequence: Vec::new(),
            response_complete: false,
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
    pub fn append_thinking(&mut self, delta: &str, kind: ThinkingContentKind) {
        self.thinking.push_str(delta);
        if let Some(ContentSequenceItem::Thinking {
            text,
            kind: current_kind,
        }) = self.content_sequence.last_mut()
        {
            text.push_str(delta);
            *current_kind = kind;
        } else {
            self.content_sequence.push(ContentSequenceItem::Thinking {
                text: delta.to_string(),
                kind,
            });
        }
    }

    /// Replace the current thinking block with an authoritative final snapshot.
    pub fn finish_thinking(&mut self, thinking: &str, kind: ThinkingContentKind) {
        self.thinking.clear();
        self.thinking.push_str(thinking);
        if let Some(ContentSequenceItem::Thinking {
            text,
            kind: current_kind,
        }) = self
            .content_sequence
            .iter_mut()
            .rev()
            .find(|item| matches!(item, ContentSequenceItem::Thinking { .. }))
        {
            text.clear();
            text.push_str(thinking);
            *current_kind = kind;
        } else if !thinking.is_empty() {
            self.content_sequence.push(ContentSequenceItem::Thinking {
                text: thinking.to_string(),
                kind,
            });
        }
    }

    /// Mark the provider stream complete while retaining capability state for
    /// the rest of the active turn.
    pub fn finish_response(&mut self) {
        self.response_complete = true;
    }

    /// Add a new capability invocation in "generating" state.
    pub fn add_capability_generating(
        &mut self,
        invocation_id: &str,
        model_primitive_name: &str,
        capability_identity: &CapabilityEventIdentity,
    ) {
        if self
            .capability_invocations
            .iter()
            .any(|tc| tc.invocation_id == invocation_id)
        {
            return;
        }
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
                progress_message: None,
                progress_percent: None,
                details: None,
                capability_identity: capability_identity.clone(),
            });
        self.content_sequence
            .push(ContentSequenceItem::CapabilityRef {
                invocation_id: invocation_id.to_string(),
            });
    }

    /// Transition a capability invocation to "running" state.
    pub fn update_capability_started(
        &mut self,
        invocation_id: &str,
        arguments: Option<&Value>,
        capability_identity: &CapabilityEventIdentity,
    ) {
        if let Some(tc) = self
            .capability_invocations
            .iter_mut()
            .find(|tc| tc.invocation_id == invocation_id)
        {
            tc.status = "running".to_string();
            tc.arguments = arguments.cloned();
            tc.started_at = Some(chrono::Utc::now().to_rfc3339());
            tc.merge_identity(capability_identity);
        }
    }

    /// Transition a capability invocation to "completed" or "error" state.
    pub fn update_capability_completed(
        &mut self,
        invocation_id: &str,
        result: Option<&str>,
        is_error: bool,
        capability_identity: &CapabilityEventIdentity,
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
            tc.progress_message = None;
            tc.progress_percent = None;
            tc.merge_identity(capability_identity);
        }
    }

    /// Update user-visible progress for a running capability.
    pub fn update_capability_progress(
        &mut self,
        invocation_id: &str,
        message: Option<&str>,
        percent: Option<f64>,
        capability_identity: &CapabilityEventIdentity,
    ) {
        if let Some(capability) = self
            .capability_invocations
            .iter_mut()
            .find(|capability| capability.invocation_id == invocation_id)
        {
            if let Some(message) = message {
                capability.progress_message = Some(message.to_owned());
            }
            if let Some(percent) = percent {
                capability.progress_percent = Some(percent);
            }
            capability.merge_identity(capability_identity);
        }
    }

    /// Update the reconnect-visible state of an asynchronous capability run.
    pub fn update_capability_run_status(
        &mut self,
        invocation_id: &str,
        status: &str,
        details: Value,
        capability_identity: &CapabilityEventIdentity,
    ) {
        if let Some(capability) = self
            .capability_invocations
            .iter_mut()
            .find(|capability| capability.invocation_id == invocation_id)
        {
            let (projected_status, is_terminal, is_error) = match status {
                "pending" | "running" => ("running".to_owned(), false, false),
                "paused" => ("paused".to_owned(), false, false),
                "completed" | "ok" => ("completed".to_owned(), true, false),
                "cancelled" | "timeout" | "failed" | "worker_disconnected" | "policy_denied" => {
                    ("error".to_owned(), true, true)
                }
                _ => (capability.status.clone(), false, capability.is_error),
            };
            capability.status = projected_status;
            capability.is_error = is_error;
            if is_terminal {
                capability.completed_at = Some(chrono::Utc::now().to_rfc3339());
                capability.progress_message = None;
                capability.progress_percent = None;
            } else {
                capability.progress_message = Some(format!("Run {status}"));
            }
            capability.details = Some(details);
            capability.merge_identity(capability_identity);
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

struct SessionAccumulator {
    run_id: String,
    generation: u64,
    last_represented_sequence: Option<i64>,
    sequence_consistent: bool,
    admission_committed: tokio::sync::watch::Sender<bool>,
    compaction_reason: Option<String>,
    turn: Option<TurnAccumulator>,
}

impl SessionAccumulator {
    fn new(run_id: &str) -> Self {
        let (admission_committed, _) = tokio::sync::watch::channel(false);
        Self {
            run_id: run_id.to_owned(),
            generation: 0,
            last_represented_sequence: None,
            sequence_consistent: true,
            admission_committed,
            compaction_reason: None,
            turn: None,
        }
    }

    fn observe_represented_sequence(&mut self, sequence: Option<i64>) {
        let Some(sequence) = sequence else { return };
        if self
            .last_represented_sequence
            .is_some_and(|last| sequence <= last)
        {
            self.sequence_consistent = false;
            tracing::error!(
                run_id = self.run_id,
                previous_sequence = ?self.last_represented_sequence,
                sequence,
                "accumulator observed non-monotonic event sequence"
            );
            return;
        }
        self.last_represented_sequence = Some(sequence);
    }

    fn advance_generation(&mut self) {
        self.generation = self.generation.saturating_add(1);
    }
}

/// Atomic active-run projection used by session reconstruction.
#[derive(Clone, Debug)]
pub(crate) struct TurnReconstructionSnapshot {
    pub(crate) generation: u64,
    pub(crate) sequence_consistent: bool,
    pub(crate) last_sequence: Option<i64>,
    pub(crate) admission_committed: bool,
    pub(crate) compaction_reason: Option<String>,
    pub(crate) state: Option<(String, Value, Value, bool)>,
}

/// Thread-safe map of session ID → active-run reconstruction projection.
#[derive(Default)]
pub struct TurnAccumulatorMap {
    accumulators: Mutex<HashMap<String, SessionAccumulator>>,
}

impl TurnAccumulatorMap {
    /// Create an empty accumulator map.
    pub fn new() -> Self {
        Self {
            accumulators: Mutex::new(HashMap::new()),
        }
    }

    // ── Per-session mutation methods ──

    /// Start a new run generation before its first event is emitted.
    pub(crate) fn begin_run(&self, session_id: &str, run_id: &str) {
        let _ = self
            .accumulators
            .lock()
            .insert(session_id.to_owned(), SessionAccumulator::new(run_id));
    }

    /// Mark the run's durable user-message admission row as represented.
    pub(crate) fn commit_admission(&self, session_id: &str, run_id: &str, sequence: i64) -> bool {
        let mut accumulators = self.accumulators.lock();
        let Some(session) = accumulators
            .get_mut(session_id)
            .filter(|session| session.run_id == run_id)
        else {
            return false;
        };
        session.advance_generation();
        session.observe_represented_sequence(Some(sequence));
        session.admission_committed.send_replace(true);
        true
    }

    /// Subscribe to the admission commit owned by the matching active run.
    pub(crate) fn admission_receiver(
        &self,
        session_id: &str,
        run_id: &str,
    ) -> Option<tokio::sync::watch::Receiver<bool>> {
        self.accumulators
            .lock()
            .get(session_id)
            .filter(|session| session.run_id == run_id)
            .map(|session| session.admission_committed.subscribe())
    }

    /// Remove a completed run projection without deleting a replacement run.
    pub(crate) fn finish_run(&self, session_id: &str, run_id: &str) {
        let mut accumulators = self.accumulators.lock();
        if accumulators
            .get(session_id)
            .is_some_and(|session| session.run_id == run_id)
        {
            let _ = accumulators.remove(session_id);
        }
    }

    /// Clear every run-owned projection during orchestrator shutdown.
    pub(crate) fn clear(&self) {
        self.accumulators.lock().clear();
    }

    /// Project reconnect-visible compaction state.
    fn handle_compaction_state(
        &self,
        session_id: &str,
        reason: Option<String>,
        sequence: Option<i64>,
    ) {
        if let Some(session) = self.accumulators.lock().get_mut(session_id) {
            session.compaction_reason = reason;
            session.observe_represented_sequence(sequence);
        }
    }

    /// Reset the turn for an existing run-owned session projection.
    ///
    /// `begin_run` is the sole creator. Ignoring orphaned late events prevents
    /// cancelled shutdown tasks from recreating ownerless projections.
    pub fn handle_turn_start(&self, session_id: &str, sequence: Option<i64>) {
        let mut guard = self.accumulators.lock();
        if let Some(session) = guard.get_mut(session_id) {
            session.advance_generation();
            session.turn = Some(TurnAccumulator::new());
            session.observe_represented_sequence(sequence);
        }
    }

    /// Remove the accumulator when a turn ends.
    pub fn handle_turn_end(&self, session_id: &str, sequence: Option<i64>) {
        if let Some(session) = self.accumulators.lock().get_mut(session_id) {
            session.advance_generation();
            session.turn = None;
            session.observe_represented_sequence(sequence);
        }
    }

    /// Clear turn content when the agent loop ends while preserving processing
    /// ownership until completion publishes the final ready/admission boundary.
    pub fn handle_agent_end(&self, session_id: &str, sequence: Option<i64>) {
        if let Some(session) = self.accumulators.lock().get_mut(session_id) {
            session.advance_generation();
            session.compaction_reason = None;
            session.turn = None;
            session.observe_represented_sequence(sequence);
        }
    }

    /// Append a text delta to the session's accumulator.
    pub fn handle_text_delta(&self, session_id: &str, delta: &str, sequence: Option<i64>) {
        if let Some(session) = self.accumulators.lock().get_mut(session_id) {
            if let Some(turn) = session.turn.as_mut() {
                turn.append_text(delta);
            }
            session.observe_represented_sequence(sequence);
        }
    }

    /// Append a thinking delta to the session's accumulator.
    pub fn handle_thinking_delta(
        &self,
        session_id: &str,
        delta: &str,
        kind: ThinkingContentKind,
        sequence: Option<i64>,
    ) {
        if let Some(session) = self.accumulators.lock().get_mut(session_id) {
            if let Some(turn) = session.turn.as_mut() {
                turn.append_thinking(delta, kind);
            }
            session.observe_represented_sequence(sequence);
        }
    }

    /// Replace active thinking with the final full thinking snapshot.
    pub fn handle_thinking_end(
        &self,
        session_id: &str,
        thinking: &str,
        kind: ThinkingContentKind,
        sequence: Option<i64>,
    ) {
        if let Some(session) = self.accumulators.lock().get_mut(session_id) {
            if let Some(turn) = session.turn.as_mut() {
                turn.finish_thinking(thinking, kind);
            }
            session.observe_represented_sequence(sequence);
        }
    }

    /// Mark the provider response complete without ending the active turn.
    pub fn handle_response_complete(&self, session_id: &str, sequence: Option<i64>) {
        if let Some(session) = self.accumulators.lock().get_mut(session_id) {
            if let Some(turn) = session.turn.as_mut() {
                turn.finish_response();
            }
            session.observe_represented_sequence(sequence);
        }
    }

    /// Record a new capability invocation in "generating" state.
    pub fn handle_capability_generating(
        &self,
        session_id: &str,
        invocation_id: &str,
        model_primitive_name: &str,
        capability_identity: &CapabilityEventIdentity,
        sequence: Option<i64>,
    ) {
        if let Some(session) = self.accumulators.lock().get_mut(session_id) {
            if let Some(turn) = session.turn.as_mut() {
                turn.add_capability_generating(
                    invocation_id,
                    model_primitive_name,
                    capability_identity,
                );
            }
            session.observe_represented_sequence(sequence);
        }
    }

    /// Transition a capability invocation to "running" state.
    pub fn handle_capability_started(
        &self,
        session_id: &str,
        invocation_id: &str,
        arguments: Option<&Value>,
        capability_identity: &CapabilityEventIdentity,
        sequence: Option<i64>,
    ) {
        if let Some(session) = self.accumulators.lock().get_mut(session_id) {
            if let Some(turn) = session.turn.as_mut() {
                turn.update_capability_started(invocation_id, arguments, capability_identity);
            }
            session.observe_represented_sequence(sequence);
        }
    }

    /// Append streaming output to a running capability invocation.
    pub fn handle_capability_output(
        &self,
        session_id: &str,
        invocation_id: &str,
        output: &str,
        sequence: Option<i64>,
    ) {
        if let Some(session) = self.accumulators.lock().get_mut(session_id) {
            if let Some(turn) = session.turn.as_mut()
                && let Some(tc) = turn
                    .capability_invocations
                    .iter_mut()
                    .find(|tc| tc.invocation_id == invocation_id)
            {
                let streaming = tc.streaming_output.get_or_insert_with(String::new);
                streaming.push_str(output);
            }
            session.observe_represented_sequence(sequence);
        }
    }

    /// Record capability completion or error.
    pub fn handle_capability_completed(
        &self,
        session_id: &str,
        invocation_id: &str,
        result: Option<&str>,
        is_error: bool,
        capability_identity: &CapabilityEventIdentity,
        sequence: Option<i64>,
    ) {
        if let Some(session) = self.accumulators.lock().get_mut(session_id) {
            if let Some(turn) = session.turn.as_mut() {
                turn.update_capability_completed(
                    invocation_id,
                    result,
                    is_error,
                    capability_identity,
                );
            }
            session.observe_represented_sequence(sequence);
        }
    }

    fn handle_capability_progress(
        &self,
        session_id: &str,
        invocation_id: &str,
        message: Option<&str>,
        percent: Option<f64>,
        capability_identity: &CapabilityEventIdentity,
        sequence: Option<i64>,
    ) {
        if let Some(session) = self.accumulators.lock().get_mut(session_id) {
            if let Some(turn) = session.turn.as_mut() {
                turn.update_capability_progress(
                    invocation_id,
                    message,
                    percent,
                    capability_identity,
                );
            }
            session.observe_represented_sequence(sequence);
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn handle_capability_run_status(
        &self,
        session_id: &str,
        invocation_id: &str,
        run_id: &str,
        status: &str,
        stream_topic: Option<&str>,
        child_invocations: &[String],
        details: Option<&Value>,
        capability_identity: &CapabilityEventIdentity,
        sequence: Option<i64>,
    ) {
        if let Some(session) = self.accumulators.lock().get_mut(session_id) {
            if let Some(turn) = session.turn.as_mut() {
                turn.update_capability_run_status(
                    invocation_id,
                    status,
                    serde_json::json!({
                        "runId": run_id,
                        "runStatus": status,
                        "streamTopic": stream_topic,
                        "childInvocations": child_invocations,
                        "runDetails": details,
                    }),
                    capability_identity,
                );
            }
            session.observe_represented_sequence(sequence);
        }
    }

    /// Advance the projection cut for an event explicitly classified below as
    /// reconstructed elsewhere or intentionally transient.
    fn handle_covered_event(&self, session_id: &str, sequence: Option<i64>) {
        if let Some(session) = self.accumulators.lock().get_mut(session_id) {
            session.observe_represented_sequence(sequence);
        }
    }

    // ── Query ──

    /// Snapshot the state/cursor pair only when it belongs to `run_id`.
    pub(crate) fn reconstruction_snapshot(
        &self,
        session_id: &str,
        run_id: &str,
    ) -> Option<TurnReconstructionSnapshot> {
        let guard = self.accumulators.lock();
        let session = guard.get(session_id)?;
        if session.run_id != run_id {
            return None;
        }
        Some(TurnReconstructionSnapshot {
            generation: session.generation,
            sequence_consistent: session.sequence_consistent,
            last_sequence: session
                .sequence_consistent
                .then_some(session.last_represented_sequence)
                .flatten(),
            admission_committed: *session.admission_committed.borrow(),
            compaction_reason: session.compaction_reason.clone(),
            state: session.turn.as_ref().map(|turn| {
                let (text, capabilities, sequence) = turn.to_json();
                (text, capabilities, sequence, turn.response_complete)
            }),
        })
    }

    /// Name of the capability currently executing in the session's turn,
    /// if any. Returns the model-facing primitive of the most recently-started invocation
    /// whose status is `running` (capability.invocation.started persisted; capability.invocation.completed not
    /// yet). `generating` doesn't count — the LLM is still streaming
    /// the capability_invocation block and hasn't begun execution. Returns `None`
    /// when no turn is in flight or no capability has entered `running`.
    pub(crate) fn current_running_capability(
        &self,
        session_id: &str,
        run_id: &str,
    ) -> Option<CurrentCapabilitySnapshot> {
        let guard = self.accumulators.lock();
        let session = guard.get(session_id)?;
        if session.run_id != run_id {
            return None;
        }
        let acc = session.turn.as_ref()?;
        // Iterate from the end: the most recent running invocation wins. Capability
        // calls can run in parallel within one turn; the "current capability"
        // returned here is the most recently started.
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
        let sequence = event.sequence();
        match event {
            TronEvent::AgentStart { .. }
            | TronEvent::AgentReady { .. }
            | TronEvent::SessionProcessingChanged { .. } => {
                self.handle_covered_event(session_id, sequence);
            }
            TronEvent::AgentInterrupted { .. } | TronEvent::TurnFailed { .. } => {
                self.handle_agent_end(session_id, sequence);
            }
            TronEvent::TurnStart { turn, .. } => {
                tracing::debug!(session_id, turn, "accumulator: turn_start");
                self.handle_turn_start(session_id, sequence);
            }
            TronEvent::TurnEnd { turn, .. } => {
                tracing::debug!(session_id, turn, "accumulator: turn_end (clearing)");
                self.handle_turn_end(session_id, sequence);
            }
            TronEvent::AgentEnd { .. } => {
                tracing::debug!(session_id, "accumulator: agent_end (clearing)");
                self.handle_agent_end(session_id, sequence);
            }
            TronEvent::MessageUpdate { content, .. } => {
                tracing::trace!(session_id, len = content.len(), "accumulator: text_delta");
                self.handle_text_delta(session_id, content, sequence);
            }
            TronEvent::ThinkingDelta { delta, kind, .. } => {
                self.handle_thinking_delta(session_id, delta, *kind, sequence);
            }
            TronEvent::ThinkingEnd { thinking, kind, .. } => {
                self.handle_thinking_end(session_id, thinking, *kind, sequence);
            }
            TronEvent::ResponseComplete { .. } => {
                self.handle_response_complete(session_id, sequence);
            }
            TronEvent::CapabilityInvocationGenerating {
                invocation_id,
                model_primitive_name,
                capability_identity,
                ..
            } => {
                self.handle_capability_generating(
                    session_id,
                    invocation_id,
                    model_primitive_name,
                    capability_identity,
                    sequence,
                );
            }
            TronEvent::CapabilityInvocationStarted {
                invocation_id,
                arguments,
                capability_identity,
                ..
            } => {
                let args_value = arguments.as_ref().map(|m| Value::Object(m.clone()));
                self.handle_capability_started(
                    session_id,
                    invocation_id,
                    args_value.as_ref(),
                    capability_identity,
                    sequence,
                );
            }
            TronEvent::CapabilityInvocationCompleted {
                invocation_id,
                is_error,
                result,
                capability_identity,
                ..
            } => {
                let result_text = result.as_ref().map(|r| match &r.content {
                    crate::shared::protocol::model_capabilities::CapabilityResultBody::Text(t) => {
                        t.clone()
                    }
                    crate::shared::protocol::model_capabilities::CapabilityResultBody::Blocks(
                        blocks,
                    ) => blocks
                        .iter()
                        .filter_map(|b| {
                            if let crate::shared::protocol::content::CapabilityResultContent::Text {
                                    text,
                                } = b
                                {
                                    Some(text.as_str())
                                } else {
                                    None
                                }
                        })
                        .collect::<Vec<_>>()
                        .join("\n"),
                });
                self.handle_capability_completed(
                    session_id,
                    invocation_id,
                    result_text.as_deref(),
                    is_error.unwrap_or(false),
                    capability_identity,
                    sequence,
                );
            }
            TronEvent::CapabilityInvocationOutput {
                invocation_id,
                update,
                ..
            } => {
                self.handle_capability_output(session_id, invocation_id, update, sequence);
            }
            TronEvent::CapabilityInvocationProgress {
                invocation_id,
                message,
                percent,
                capability_identity,
                ..
            } => {
                self.handle_capability_progress(
                    session_id,
                    invocation_id,
                    message.as_deref(),
                    *percent,
                    capability_identity,
                    sequence,
                );
            }
            TronEvent::CapabilityRunStatus {
                run_id,
                invocation_id,
                status,
                stream_topic,
                child_invocations,
                details,
                capability_identity,
                ..
            } => {
                self.handle_capability_run_status(
                    session_id,
                    invocation_id,
                    run_id,
                    status,
                    stream_topic.as_deref(),
                    child_invocations,
                    details.as_ref(),
                    capability_identity,
                    sequence,
                );
            }
            TronEvent::CompactionStart { reason, .. } => {
                let reason = serde_json::to_value(reason)
                    .ok()
                    .and_then(|value| value.as_str().map(str::to_owned))
                    .unwrap_or_else(|| format!("{reason:?}"));
                self.handle_compaction_state(session_id, Some(reason), sequence);
            }
            TronEvent::CompactionComplete { .. } => {
                self.handle_compaction_state(session_id, None, sequence);
            }
            // Exhaustive coverage classification. These events either project
            // into durable reconstruction/metadata, are current-run phase
            // facts, or are presentation-only notifications that are not
            // replayed after reconnect. Keeping this list explicit forces a
            // new event variant to choose a reconstruction owner.
            TronEvent::CapabilityInvocationBatch { .. }
            | TronEvent::CapabilityInvocationArgumentDelta { .. }
            | TronEvent::SessionSaved { .. }
            | TronEvent::SessionLoaded { .. }
            | TronEvent::ContextWarning { .. }
            | TronEvent::Error { .. }
            | TronEvent::ApiRetry { .. }
            | TronEvent::ThinkingStart { .. }
            | TronEvent::SessionCreated { .. }
            | TronEvent::SessionArchived { .. }
            | TronEvent::SessionUnarchived { .. }
            | TronEvent::SessionForked { .. }
            | TronEvent::SessionUpdated { .. }
            | TronEvent::ContextCleared { .. }
            | TronEvent::MessageDeleted { .. } => {
                self.handle_covered_event(session_id, sequence);
            }
            TronEvent::SessionDeleted { .. } => {
                let _ = self.accumulators.lock().remove(session_id);
            }
        }
    }
}

impl TronEventObserver for TurnAccumulatorMap {
    fn observe_tron_event(&self, event: &TronEvent) {
        self.update_from_event(event);
    }
}

#[cfg(test)]
mod tests;
