//! Domain types for the cron scheduling system.
//!
//! - [`Schedule`]: When to run (cron expression, fixed interval, or one-shot)
//! - [`Payload`]: What to run (agent turn, shell command, webhook, system event)
//! - [`Delivery`]: Where to send results (silent, WebSocket, APNS, webhook)
//! - [`CronJob`]: Complete job definition (schedule + payload + delivery + policies)
//! - [`CronRun`]: Execution record for a single job run

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

// ── Defaults for serde ──────────────────────────────────────────────

fn default_true() -> bool {
    true
}
fn default_utc() -> String {
    "UTC".to_string()
}
fn default_post() -> String {
    "POST".to_string()
}
fn default_300() -> u64 {
    300
}
fn default_30() -> u64 {
    30
}
fn default_7200() -> u64 {
    7200
}

// ── Schedule ────────────────────────────────────────────────────────

/// When a cron job should fire.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Schedule {
    /// Standard 5-field cron expression with IANA timezone.
    #[serde(rename = "cron")]
    Cron {
        /// Five-field cron expression (minute hour day-of-month month day-of-week).
        expression: String,
        /// IANA timezone (e.g. `"America/New_York"`). Defaults to UTC.
        #[serde(default = "default_utc")]
        timezone: String,
    },
    /// Fixed interval with optional anchor time.
    #[serde(rename = "every", rename_all = "camelCase")]
    Every {
        /// Interval in seconds. Minimum: 10.
        interval_secs: u64,
        /// Wall-clock anchor. Next fire = anchor + N*interval >= now.
        /// If None, anchored to epoch (consistent across restarts).
        #[serde(skip_serializing_if = "Option::is_none")]
        anchor: Option<DateTime<Utc>>,
    },
    /// Fire once at a specific time, then auto-disable.
    #[serde(rename = "at")]
    OneShot {
        /// The UTC time to fire at.
        at: DateTime<Utc>,
    },
}

// ── Payload ─────────────────────────────────────────────────────────

/// What to execute when a cron job fires.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Payload {
    /// Run an isolated agent turn with a prompt.
    #[serde(rename = "agentTurn", rename_all = "camelCase")]
    AgentTurn {
        /// Prompt text for the agent.
        prompt: String,
        /// Override model (uses default if None).
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<String>,
        /// Workspace scope for the agent turn.
        #[serde(skip_serializing_if = "Option::is_none")]
        workspace_id: Option<String>,
        /// Custom system prompt override.
        #[serde(skip_serializing_if = "Option::is_none")]
        system_prompt: Option<String>,
    },
    /// Execute a shell command via bash.
    #[serde(rename = "shellCommand", rename_all = "camelCase")]
    ShellCommand {
        /// The shell command to execute.
        command: String,
        /// Working directory (defaults to $HOME).
        #[serde(skip_serializing_if = "Option::is_none")]
        working_directory: Option<String>,
        /// Timeout in seconds. Default: 300. Max: 3600.
        #[serde(default = "default_300")]
        timeout_secs: u64,
    },
    /// HTTP request to an endpoint.
    #[serde(rename = "webhook", rename_all = "camelCase")]
    Webhook {
        /// Target URL.
        url: String,
        /// HTTP method (GET, POST, PUT, PATCH, DELETE).
        #[serde(default = "default_post")]
        method: String,
        /// Custom headers.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        headers: Option<serde_json::Map<String, serde_json::Value>>,
        /// Request body (JSON).
        #[serde(skip_serializing_if = "Option::is_none")]
        body: Option<serde_json::Value>,
        /// Response timeout in seconds. Default: 30. Max: 300.
        #[serde(default = "default_30")]
        timeout_secs: u64,
    },
    /// Inject a message into an existing session.
    #[serde(rename = "systemEvent", rename_all = "camelCase")]
    SystemEvent {
        /// Target session ID.
        session_id: String,
        /// Message to inject.
        message: String,
    },
}

// ── Delivery ────────────────────────────────────────────────────────

/// How to deliver the result of a cron job run.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Delivery {
    /// Log only, no notification.
    #[serde(rename = "silent")]
    Silent,
    /// Broadcast via WebSocket to connected clients.
    #[serde(rename = "websocket")]
    WebSocket,
    /// Send push notification via APNS.
    #[serde(rename = "apns")]
    Apns {
        /// Custom notification title.
        #[serde(skip_serializing_if = "Option::is_none")]
        title: Option<String>,
    },
    /// POST result to a webhook URL.
    #[serde(rename = "webhook")]
    Webhook {
        /// Target URL.
        url: String,
        /// Custom headers.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        headers: Option<serde_json::Map<String, serde_json::Value>>,
    },
}

// ── Policies ────────────────────────────────────────────────────────

/// How to handle overlapping executions.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OverlapPolicy {
    /// Skip if previous run is still in progress.
    #[default]
    Skip,
    /// Allow concurrent executions.
    Allow,
}

/// How to handle missed schedules (e.g. server was down).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MisfirePolicy {
    /// Compute next future occurrence, skip missed runs.
    #[default]
    Skip,
    /// Run once immediately on startup, then resume normal schedule.
    RunOnce,
}

impl OverlapPolicy {
    /// SQL string representation.
    #[must_use]
    pub fn as_sql(&self) -> &'static str {
        match self {
            Self::Skip => "skip",
            Self::Allow => "allow",
        }
    }

    /// Parse from SQL column value. Unknown values default to `Skip`.
    #[must_use]
    pub fn from_sql(s: &str) -> Self {
        match s {
            "allow" => Self::Allow,
            _ => Self::Skip,
        }
    }
}

impl MisfirePolicy {
    /// SQL string representation.
    #[must_use]
    pub fn as_sql(&self) -> &'static str {
        match self {
            Self::Skip => "skip",
            Self::RunOnce => "run_once",
        }
    }

    /// Parse from SQL column value. Unknown values default to `Skip`.
    #[must_use]
    pub fn from_sql(s: &str) -> Self {
        match s {
            "run_once" => Self::RunOnce,
            _ => Self::Skip,
        }
    }
}

// ── CronJob ─────────────────────────────────────────────────────────

/// Complete cron job definition.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CronJob {
    /// Unique identifier (`cron_{uuid_v7}`).
    pub id: String,
    /// Human-readable name (must be unique).
    pub name: String,
    /// Optional description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Whether the job is active.
    #[serde(default = "default_true")]
    pub enabled: bool,
    /// When to run.
    pub schedule: Schedule,
    /// What to run.
    pub payload: Payload,
    /// Where to deliver results.
    #[serde(default)]
    pub delivery: Vec<Delivery>,
    /// Overlap handling policy.
    #[serde(default)]
    pub overlap_policy: OverlapPolicy,
    /// Misfire handling policy.
    #[serde(default)]
    pub misfire_policy: MisfirePolicy,
    /// Max retry attempts per execution. 0 = no retries.
    #[serde(default)]
    pub max_retries: u32,
    /// Auto-disable after N consecutive failures. 0 = never.
    #[serde(default)]
    pub auto_disable_after: u32,
    /// Stuck job timeout in seconds. Default: 7200 (2h).
    #[serde(default = "default_7200")]
    pub stuck_timeout_secs: u64,
    /// Tags for filtering.
    #[serde(default)]
    pub tags: Vec<String>,
    /// Workspace scope.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
    /// When the job was created.
    pub created_at: DateTime<Utc>,
    /// When the job was last modified.
    pub updated_at: DateTime<Utc>,
}

// ── CronRun ─────────────────────────────────────────────────────────

/// Status of a cron run.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RunStatus {
    /// Currently executing.
    Running,
    /// Finished successfully.
    Completed,
    /// Finished with error.
    Failed,
    /// Killed due to timeout.
    TimedOut,
    /// Skipped due to overlap policy.
    Skipped,
    /// Cancelled (shutdown or job disabled mid-retry).
    Cancelled,
}

impl RunStatus {
    /// `SQLite` column value.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::TimedOut => "timed_out",
            Self::Skipped => "skipped",
            Self::Cancelled => "cancelled",
        }
    }

    /// Parse from `SQLite` column value.
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "running" => Some(Self::Running),
            "completed" => Some(Self::Completed),
            "failed" => Some(Self::Failed),
            "timed_out" => Some(Self::TimedOut),
            "skipped" => Some(Self::Skipped),
            "cancelled" => Some(Self::Cancelled),
            _ => None,
        }
    }
}

/// Outcome of result delivery attempts.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DeliveryOutcome {
    /// All channels delivered successfully.
    Ok,
    /// Some channels succeeded, some failed.
    Partial,
    /// All channels failed.
    Failed,
}

impl DeliveryOutcome {
    /// SQL string representation.
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Partial => "partial",
            Self::Failed => "failed",
        }
    }

    /// Parse from SQL column value. Unknown values default to `Failed`.
    #[must_use]
    pub fn from_sql(s: &str) -> Self {
        match s {
            "ok" => Self::Ok,
            "partial" => Self::Partial,
            _ => Self::Failed,
        }
    }
}

/// Execution record for a single cron job run.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CronRun {
    /// Unique identifier (`cronrun_{uuid_v7}`).
    pub id: String,
    /// Job that spawned this run (nullable if job was deleted).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub job_id: Option<String>,
    /// Job name at time of run (preserved for audit trail).
    pub job_name: String,
    /// Execution status.
    pub status: RunStatus,
    /// When execution started.
    pub started_at: DateTime<Utc>,
    /// When execution completed (None if still running).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<DateTime<Utc>>,
    /// Execution duration in milliseconds.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<i64>,
    /// Captured output (up to 1MB from pipe read).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    /// Whether the output was truncated.
    #[serde(default)]
    pub output_truncated: bool,
    /// Error message (if failed).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// Process exit code (shell commands only).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    /// Retry attempt number (0 = first try).
    #[serde(default)]
    pub attempt: u32,
    /// Associated session ID (agent turns only).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    /// Delivery outcome.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delivery_status: Option<DeliveryOutcome>,
}

/// Runtime state for a job (SQLite-only, not in JSON config file).
#[derive(Clone, Debug)]
pub struct JobRuntimeState {
    /// Job ID.
    pub job_id: String,
    /// Next scheduled run time.
    pub next_run_at: Option<DateTime<Utc>>,
    /// Last completed run time.
    pub last_run_at: Option<DateTime<Utc>>,
    /// Consecutive failure count.
    pub consecutive_failures: u32,
    /// When the currently running execution started (None if idle).
    pub running_since: Option<DateTime<Utc>>,
}

/// JSON config file schema.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CronConfig {
    /// Schema version (currently 1).
    pub version: u32,
    /// Job definitions.
    pub jobs: Vec<CronJob>,
}

impl Default for CronConfig {
    fn default() -> Self {
        Self {
            version: 1,
            jobs: Vec::new(),
        }
    }
}

/// Output captured from a payload execution.
#[derive(Clone, Debug, Default)]
pub struct ExecutionOutput {
    /// Combined stdout content.
    pub stdout: String,
    /// Combined stderr content.
    pub stderr: String,
    /// Process exit code (if applicable).
    pub exit_code: Option<i32>,
    /// Whether output was truncated to the size limit.
    pub truncated: bool,
    /// Whether the execution timed out.
    pub timed_out: bool,
    /// Session ID (agent turns only).
    pub session_id: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schedule_cron_serde_roundtrip() {
        let s = Schedule::Cron {
            expression: "0 9 * * *".into(),
            timezone: "America/New_York".into(),
        };
        let json = serde_json::to_string(&s).unwrap();
        let back: Schedule = serde_json::from_str(&json).unwrap();
        assert_eq!(s, back);
    }

    #[test]
    fn schedule_every_serde_roundtrip() {
        let s = Schedule::Every {
            interval_secs: 300,
            anchor: None,
        };
        let json = serde_json::to_string(&s).unwrap();
        let back: Schedule = serde_json::from_str(&json).unwrap();
        assert_eq!(s, back);
    }

    #[test]
    fn schedule_oneshot_serde_roundtrip() {
        let at = DateTime::parse_from_rfc3339("2026-03-01T12:00:00Z")
            .unwrap()
            .to_utc();
        let s = Schedule::OneShot { at };
        let json = serde_json::to_string(&s).unwrap();
        let back: Schedule = serde_json::from_str(&json).unwrap();
        assert_eq!(s, back);
    }

    #[test]
    fn payload_agent_turn_serde_roundtrip() {
        let p = Payload::AgentTurn {
            prompt: "Summarize work".into(),
            model: Some("claude-opus-4-6".into()),
            workspace_id: None,
            system_prompt: None,
        };
        let json = serde_json::to_string(&p).unwrap();
        let back: Payload = serde_json::from_str(&json).unwrap();
        assert_eq!(p, back);
    }

    #[test]
    fn payload_shell_command_serde_roundtrip() {
        let p = Payload::ShellCommand {
            command: "echo hello".into(),
            working_directory: Some("/tmp".into()),
            timeout_secs: 60,
        };
        let json = serde_json::to_string(&p).unwrap();
        let back: Payload = serde_json::from_str(&json).unwrap();
        assert_eq!(p, back);
    }

    #[test]
    fn payload_webhook_serde_roundtrip() {
        let p = Payload::Webhook {
            url: "https://example.com/hook".into(),
            method: "POST".into(),
            headers: None,
            body: Some(serde_json::json!({"key": "value"})),
            timeout_secs: 30,
        };
        let json = serde_json::to_string(&p).unwrap();
        let back: Payload = serde_json::from_str(&json).unwrap();
        assert_eq!(p, back);
    }

    #[test]
    fn payload_system_event_serde_roundtrip() {
        let p = Payload::SystemEvent {
            session_id: "sess_123".into(),
            message: "Hello".into(),
        };
        let json = serde_json::to_string(&p).unwrap();
        let back: Payload = serde_json::from_str(&json).unwrap();
        assert_eq!(p, back);
    }

    #[test]
    fn delivery_all_variants_serde() {
        let variants = vec![
            Delivery::Silent,
            Delivery::WebSocket,
            Delivery::Apns {
                title: Some("Test".into()),
            },
            Delivery::Webhook {
                url: "https://example.com".into(),
                headers: None,
            },
        ];
        for d in &variants {
            let json = serde_json::to_string(d).unwrap();
            let back: Delivery = serde_json::from_str(&json).unwrap();
            assert_eq!(d, &back);
        }
    }

    #[test]
    fn cron_job_full_serde_roundtrip() {
        let now = Utc::now();
        let job = CronJob {
            id: "cron_test".into(),
            name: "Test Job".into(),
            description: Some("A test".into()),
            enabled: true,
            schedule: Schedule::Cron {
                expression: "0 9 * * *".into(),
                timezone: "UTC".into(),
            },
            payload: Payload::ShellCommand {
                command: "echo hi".into(),
                working_directory: None,
                timeout_secs: 300,
            },
            delivery: vec![Delivery::Silent],
            overlap_policy: OverlapPolicy::Skip,
            misfire_policy: MisfirePolicy::Skip,
            max_retries: 2,
            auto_disable_after: 5,
            stuck_timeout_secs: 7200,
            tags: vec!["test".into()],
            workspace_id: None,
            created_at: now,
            updated_at: now,
        };
        let json = serde_json::to_string(&job).unwrap();
        let back: CronJob = serde_json::from_str(&json).unwrap();
        assert_eq!(job.id, back.id);
        assert_eq!(job.name, back.name);
        assert_eq!(job.max_retries, back.max_retries);
    }

    #[test]
    fn cron_job_minimal_defaults() {
        let json = r#"{
            "id": "cron_min",
            "name": "Minimal",
            "schedule": {"type": "every", "intervalSecs": 60},
            "payload": {"type": "shellCommand", "command": "echo ok"},
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z"
        }"#;
        let job: CronJob = serde_json::from_str(json).unwrap();
        assert!(job.enabled);
        assert!(job.delivery.is_empty());
        assert_eq!(job.overlap_policy, OverlapPolicy::Skip);
        assert_eq!(job.misfire_policy, MisfirePolicy::Skip);
        assert_eq!(job.max_retries, 0);
        assert_eq!(job.auto_disable_after, 0);
        assert_eq!(job.stuck_timeout_secs, 7200);
        assert!(job.tags.is_empty());
    }

    #[test]
    fn delivery_outcome_serde_roundtrip() {
        for outcome in [DeliveryOutcome::Ok, DeliveryOutcome::Partial, DeliveryOutcome::Failed] {
            let json = serde_json::to_string(&outcome).unwrap();
            let back: DeliveryOutcome = serde_json::from_str(&json).unwrap();
            assert_eq!(back, outcome);
        }
    }

    #[test]
    fn delivery_outcome_serde_values() {
        assert_eq!(serde_json::to_string(&DeliveryOutcome::Ok).unwrap(), "\"ok\"");
        assert_eq!(serde_json::to_string(&DeliveryOutcome::Partial).unwrap(), "\"partial\"");
        assert_eq!(serde_json::to_string(&DeliveryOutcome::Failed).unwrap(), "\"failed\"");
    }

    #[test]
    fn delivery_outcome_as_str() {
        assert_eq!(DeliveryOutcome::Ok.as_str(), "ok");
        assert_eq!(DeliveryOutcome::Partial.as_str(), "partial");
        assert_eq!(DeliveryOutcome::Failed.as_str(), "failed");
    }

    #[test]
    fn delivery_outcome_from_sql() {
        assert_eq!(DeliveryOutcome::from_sql("ok"), DeliveryOutcome::Ok);
        assert_eq!(DeliveryOutcome::from_sql("partial"), DeliveryOutcome::Partial);
        assert_eq!(DeliveryOutcome::from_sql("failed"), DeliveryOutcome::Failed);
        assert_eq!(DeliveryOutcome::from_sql("garbage"), DeliveryOutcome::Failed);
    }

    #[test]
    fn overlap_policy_sql_roundtrip() {
        for p in [OverlapPolicy::Skip, OverlapPolicy::Allow] {
            assert_eq!(OverlapPolicy::from_sql(p.as_sql()), p);
        }
    }

    #[test]
    fn overlap_policy_from_sql_unknown_defaults_to_skip() {
        assert_eq!(OverlapPolicy::from_sql("garbage"), OverlapPolicy::Skip);
    }

    #[test]
    fn misfire_policy_sql_roundtrip() {
        for p in [MisfirePolicy::Skip, MisfirePolicy::RunOnce] {
            assert_eq!(MisfirePolicy::from_sql(p.as_sql()), p);
        }
    }

    #[test]
    fn misfire_policy_from_sql_unknown_defaults_to_skip() {
        assert_eq!(MisfirePolicy::from_sql("garbage"), MisfirePolicy::Skip);
    }

    #[test]
    fn overlap_policy_default_is_skip() {
        assert_eq!(OverlapPolicy::default(), OverlapPolicy::Skip);
    }

    #[test]
    fn misfire_policy_default_is_skip() {
        assert_eq!(MisfirePolicy::default(), MisfirePolicy::Skip);
    }

    #[test]
    fn run_status_roundtrip() {
        let statuses = [
            RunStatus::Running,
            RunStatus::Completed,
            RunStatus::Failed,
            RunStatus::TimedOut,
            RunStatus::Skipped,
            RunStatus::Cancelled,
        ];
        for s in &statuses {
            let str_val = s.as_str();
            let back = RunStatus::parse(str_val).unwrap();
            assert_eq!(s, &back);
        }
    }

    #[test]
    fn run_status_unknown_returns_none() {
        assert!(RunStatus::parse("unknown").is_none());
    }

    #[test]
    fn shell_command_default_timeout() {
        let json = r#"{"type": "shellCommand", "command": "ls"}"#;
        let p: Payload = serde_json::from_str(json).unwrap();
        match p {
            Payload::ShellCommand { timeout_secs, .. } => assert_eq!(timeout_secs, 300),
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn webhook_default_method() {
        let json = r#"{"type": "webhook", "url": "https://example.com"}"#;
        let p: Payload = serde_json::from_str(json).unwrap();
        match p {
            Payload::Webhook { method, .. } => assert_eq!(method, "POST"),
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn cron_config_default() {
        let c = CronConfig::default();
        assert_eq!(c.version, 1);
        assert!(c.jobs.is_empty());
    }
}
