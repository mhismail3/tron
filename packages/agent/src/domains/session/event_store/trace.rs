//! Agent trace records persisted with the primitive session store.
//!
//! The durable row keeps a human/agent-readable JSON record shaped after the
//! Agent Trace RFC, plus denormalized columns for the query path the agent uses
//! through `execute`.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Agent Trace-compatible record version emitted by this branch.
pub const AGENT_TRACE_VERSION: &str = "0.1";

/// Reverse-domain metadata key for Tron-specific runtime facts.
pub const TRON_TRACE_METADATA_KEY: &str = "dev.tron";

/// One persisted trace record.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentTraceRecord {
    /// Trace record id.
    pub id: String,
    /// Causal trace id shared across the turn.
    pub trace_id: String,
    /// Engine invocation id.
    pub invocation_id: String,
    /// Parent engine invocation id, when present.
    pub parent_invocation_id: Option<String>,
    /// Provider/model tool-call id, when present.
    pub provider_invocation_id: Option<String>,
    /// Session id, when present.
    pub session_id: Option<String>,
    /// Workspace id, when present.
    pub workspace_id: Option<String>,
    /// Turn number, when present.
    pub turn: Option<i64>,
    /// Model-facing primitive name, currently always `execute`.
    pub model_primitive_name: String,
    /// Execute operation name.
    pub operation: String,
    /// Lifecycle status: `running`, `ok`, `failed`, or `timeout`.
    pub status: String,
    /// RFC3339 record timestamp.
    pub timestamp: String,
    /// RFC3339 completion timestamp, when finished.
    pub completed_at: Option<String>,
    /// Duration in milliseconds, when finished.
    pub duration_ms: Option<i64>,
    /// Full Agent Trace-style JSON document.
    pub record_json: Value,
}

/// Filter for trace list queries.
#[derive(Clone, Copy, Debug, Default)]
pub struct AgentTraceListOptions<'a> {
    /// Restrict to one session.
    pub session_id: Option<&'a str>,
    /// Restrict to one trace.
    pub trace_id: Option<&'a str>,
    /// Maximum rows to return.
    pub limit: Option<i64>,
}
