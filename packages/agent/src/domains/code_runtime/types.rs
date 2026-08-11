use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Hard limits for one logical agent runtime.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RuntimeLimits {
    /// Maximum admitted source bytes in one cell.
    pub max_source_bytes: usize,
    /// Maximum compiled bytes across committed cells.
    pub max_journal_bytes: usize,
    /// Maximum committed cells before an explicit reset/consolidation.
    pub max_committed_cells: usize,
    /// Maximum calls across one evaluation, including replay.
    pub max_calls_per_evaluation: usize,
    /// QuickJS heap limit.
    pub memory_bytes: usize,
    /// QuickJS stack limit.
    pub stack_bytes: usize,
    /// Wall-clock limit for synchronous evaluation.
    pub wall_time_ms: u64,
    /// Maximum captured console bytes.
    pub max_output_bytes: usize,
}

impl Default for RuntimeLimits {
    fn default() -> Self {
        Self {
            max_source_bytes: 64 * 1024,
            max_journal_bytes: 512 * 1024,
            max_committed_cells: 128,
            max_calls_per_evaluation: 1_024,
            memory_bytes: 32 * 1024 * 1024,
            stack_bytes: 512 * 1024,
            wall_time_ms: 2_000,
            max_output_bytes: 64 * 1024,
        }
    }
}

/// Durable terminal/running state of a submitted cell.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CellStatus {
    /// Admitted but not terminal; restart recovery may replay it.
    Running,
    /// Successfully evaluated and part of future replay.
    Committed,
    /// Source did not compile or evaluation threw.
    Failed,
    /// Explicitly cancelled.
    Cancelled,
    /// Runtime wall-clock or resource bound was exceeded.
    TimedOut,
}

impl CellStatus {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Committed => "committed",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::TimedOut => "timed_out",
        }
    }

    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "running" => Some(Self::Running),
            "committed" => Some(Self::Committed),
            "failed" => Some(Self::Failed),
            "cancelled" => Some(Self::Cancelled),
            "timed_out" => Some(Self::TimedOut),
            _ => None,
        }
    }
}

/// Idempotent request to evaluate a TypeScript cell for one stable agent.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CodeRunRequest {
    /// Stable engine agent identity. Session ids are not runtime identities.
    pub agent_id: String,
    /// Provider/tool invocation id used as the idempotency key.
    pub invocation_key: String,
    /// Optional active assignment provenance.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assignment_id: Option<String>,
    /// TypeScript or JavaScript cell source.
    pub source: String,
}

/// Result of a cell invocation.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CodeRunResult {
    /// Stable logical runtime id.
    pub runtime_id: String,
    /// Manual-reset generation.
    pub epoch: u64,
    /// Durable cell id.
    pub cell_id: String,
    /// Monotonic cell sequence in this runtime.
    pub sequence: u64,
    /// Terminal state.
    pub status: CellStatus,
    /// JSON-safe evaluation result.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<Value>,
    /// Bounded console output.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub output: Vec<String>,
    /// Diagnostic for non-success.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// True when this invocation key returned an existing durable terminal row.
    pub replayed: bool,
}

/// Read-only runtime inspection returned to authenticated engine callers.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CodeInspect {
    /// Stable agent identity.
    pub agent_id: String,
    /// Current runtime id, when one has been created.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime_id: Option<String>,
    /// Current reset generation.
    pub epoch: u64,
    /// Successful cells participating in replay.
    pub committed_cells: usize,
    /// Compiled journal size.
    pub journal_bytes: usize,
    /// Nonterminal admitted cell, if crash recovery has work to resume.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unresolved_cell_id: Option<String>,
    /// Whether an explicit reset/consolidation is required before more cells.
    pub journal_limit_reached: bool,
}

/// Outcome of an explicit logical-runtime reset.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CodeReset {
    /// Stable agent identity.
    pub agent_id: String,
    /// Newly current runtime id.
    pub runtime_id: String,
    /// Newly current epoch.
    pub epoch: u64,
}
