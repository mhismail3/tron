use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub(super) const JOB_SCHEMA_VERSION: &str = "tron.jobs.process.v1";
pub(super) const EXECUTION_OUTPUT_KIND: &str = "execution_output";
pub(super) const EXECUTION_OUTPUT_SCHEMA_ID: &str = "tron.resource.execution_output.v1";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum JobState {
    Running,
    Completed,
    Failed,
    TimedOut,
    Cancelled,
    Archived,
}

impl JobState {
    pub(super) fn as_str(&self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::TimedOut => "timed_out",
            Self::Cancelled => "cancelled",
            Self::Archived => "archived",
        }
    }

    pub(super) fn is_terminal(&self) -> bool {
        !matches!(self, Self::Running)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct JobProcessRecord {
    pub(super) schema_version: String,
    pub(super) state: JobState,
    pub(super) command: JobCommandRecord,
    pub(super) authority: JobAuthorityRecord,
    pub(super) limits: JobLimitsRecord,
    pub(super) retention: Value,
    pub(super) created_at: DateTime<Utc>,
    pub(super) started_at: DateTime<Utc>,
    pub(super) completed_at: Option<DateTime<Utc>>,
    pub(super) cancellation: JobCancellationRecord,
    pub(super) terminal: Option<JobTerminalRecord>,
    pub(super) output: Option<JobOutputRef>,
    pub(super) trace_refs: Vec<Value>,
    pub(super) replay_refs: Vec<Value>,
    pub(super) revision: u64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct JobCommandRecord {
    pub(super) kind: String,
    pub(super) command: String,
    pub(super) working_directory: JobWorkingDirectory,
    pub(super) network_policy: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct JobWorkingDirectory {
    pub(super) root: String,
    pub(super) canonical_path: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct JobAuthorityRecord {
    pub(super) actor_id: String,
    pub(super) authority_grant_id: String,
    pub(super) authority_scopes: Vec<String>,
    pub(super) session_id: Option<String>,
    pub(super) workspace_id: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct JobLimitsRecord {
    pub(super) timeout_ms: u64,
    pub(super) max_output_bytes: usize,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct JobCancellationRecord {
    pub(super) requested: bool,
    pub(super) requested_at: Option<DateTime<Utc>>,
    pub(super) requested_by: Option<String>,
    pub(super) reason: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct JobTerminalRecord {
    pub(super) status: String,
    pub(super) exit_code: Option<i32>,
    pub(super) timed_out: bool,
    pub(super) cancelled: bool,
    pub(super) error: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct JobOutputRef {
    pub(super) output_resource_id: String,
    pub(super) output_version_id: String,
    pub(super) content_hash: String,
    pub(super) stdout_preview: String,
    pub(super) stderr_preview: String,
    pub(super) output_truncated: bool,
    pub(super) duration_ms: u64,
    pub(super) exit_code: Option<i32>,
}

#[derive(Clone, Debug)]
pub(super) struct JobRunOutcome {
    pub(super) state: JobState,
    pub(super) exit_code: Option<i32>,
    pub(super) timed_out: bool,
    pub(super) cancelled: bool,
    pub(super) stdout: String,
    pub(super) stderr: String,
    pub(super) stdout_truncated: bool,
    pub(super) stderr_truncated: bool,
    pub(super) duration_ms: u64,
    pub(super) error: Option<String>,
}
