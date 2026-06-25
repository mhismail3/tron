use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub(super) const SCHEDULE_SCHEMA_VERSION: &str = "tron.scheduler.schedule.v1";
pub(super) const SCHEDULE_RUN_SCHEMA_VERSION: &str = "tron.scheduler.run.v1";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum ScheduleState {
    Active,
    Paused,
    Completed,
    Cancelled,
}

impl ScheduleState {
    pub(super) fn as_str(&self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Paused => "paused",
            Self::Completed => "completed",
            Self::Cancelled => "cancelled",
        }
    }

    pub(super) fn is_terminal(&self) -> bool {
        matches!(self, Self::Completed | Self::Cancelled)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum ScheduleKind {
    Reminder,
    Monitor,
    Automation,
}

impl ScheduleKind {
    pub(super) fn as_str(&self) -> &'static str {
        match self {
            Self::Reminder => "reminder",
            Self::Monitor => "monitor",
            Self::Automation => "automation",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum TriggerKind {
    Once,
    Interval,
}

impl TriggerKind {
    pub(super) fn as_str(&self) -> &'static str {
        match self {
            Self::Once => "once",
            Self::Interval => "interval",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum MissedRunMode {
    Skip,
    FireOnce,
    CatchUp,
}

impl MissedRunMode {
    pub(super) fn as_str(&self) -> &'static str {
        match self {
            Self::Skip => "skip",
            Self::FireOnce => "fire_once",
            Self::CatchUp => "catch_up",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum ScheduleRunState {
    Recorded,
    SkippedMissed,
}

impl ScheduleRunState {
    pub(super) fn as_str(&self) -> &'static str {
        match self {
            Self::Recorded => "recorded",
            Self::SkippedMissed => "skipped_missed",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ScheduleRecord {
    pub(super) schema_version: String,
    pub(super) state: ScheduleState,
    pub(super) title: String,
    pub(super) schedule_kind: ScheduleKind,
    pub(super) trigger: TriggerRecord,
    pub(super) timezone_policy: TimezonePolicyRecord,
    pub(super) missed_run_policy: MissedRunPolicyRecord,
    pub(super) target: TargetRecord,
    pub(super) authority: Value,
    pub(super) retention: RetentionRecord,
    pub(super) created_at: DateTime<Utc>,
    pub(super) updated_at: DateTime<Utc>,
    pub(super) next_fire_at: Option<DateTime<Utc>>,
    pub(super) last_evaluated_at: Option<DateTime<Utc>>,
    pub(super) last_run_at: Option<DateTime<Utc>>,
    pub(super) cancellation: Option<CancellationRecord>,
    pub(super) trace_refs: Vec<Value>,
    pub(super) replay_refs: Vec<Value>,
    pub(super) revision: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct TriggerRecord {
    pub(super) kind: TriggerKind,
    pub(super) start_at: DateTime<Utc>,
    pub(super) interval_seconds: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct TimezonePolicyRecord {
    pub(super) timezone: String,
    pub(super) resolution: String,
    pub(super) dst_policy: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct MissedRunPolicyRecord {
    pub(super) mode: MissedRunMode,
    pub(super) max_catch_up_runs: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct TargetRecord {
    pub(super) resource_kind: String,
    pub(super) action: String,
    pub(super) resource_ids: Vec<String>,
    pub(super) selector_bound: u32,
    pub(super) dispatch: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct RetentionRecord {
    pub(super) max_run_records: u32,
    pub(super) max_age_days: u32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct CancellationRecord {
    pub(super) reason: String,
    pub(super) cancelled_at: DateTime<Utc>,
    pub(super) actor_id: String,
    pub(super) idempotency: IdempotencyRecord,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ScheduleRunRecord {
    pub(super) schema_version: String,
    pub(super) state: ScheduleRunState,
    pub(super) schedule_resource_id: String,
    pub(super) schedule_version_id: String,
    pub(super) schedule_kind: ScheduleKind,
    pub(super) scheduled_for: DateTime<Utc>,
    pub(super) evaluated_at: DateTime<Utc>,
    pub(super) trigger: TriggerRecord,
    pub(super) target: TargetRecord,
    pub(super) authority: Value,
    pub(super) missed: Value,
    pub(super) background_result: Value,
    pub(super) idempotency: IdempotencyRecord,
    pub(super) retention: RetentionRecord,
    pub(super) trace_refs: Vec<Value>,
    pub(super) replay_refs: Vec<Value>,
    pub(super) revision: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct IdempotencyRecord {
    pub(super) key: Option<String>,
    pub(super) invocation_id: String,
    pub(super) function_id: String,
}
