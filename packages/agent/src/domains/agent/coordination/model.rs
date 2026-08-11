//! Domain values for durable, reusable agent coordination.
//!
//! These values deliberately describe agents and assignments without Worker
//! Kernel vocabulary. An assignment is both the unit of scheduling and the
//! causal graph node; stable agents retain their transcript and defaults across
//! assignments. Provider/client contracts will map onto this model only after
//! the dormant service replaces the compatibility runtime.

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub(crate) const DEFAULT_MAX_QUEUED_ASSIGNMENTS: u16 = 8;
pub(crate) const HARD_MAX_QUEUED_ASSIGNMENTS: u16 = 64;
pub(crate) const DEFAULT_MAX_TURNS: u16 = 32;
pub(crate) const HARD_MAX_TURNS: u16 = 250;
pub(crate) const DEFAULT_TIMEOUT_SECONDS: u32 = 15 * 60;
pub(crate) const HARD_TIMEOUT_SECONDS: u32 = 2 * 60 * 60;
pub(crate) const MAX_COORDINATION_MESSAGES: u32 = 256;
pub(crate) const MAX_AUTONOMOUS_WAKE_HOPS: u32 = 16;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AgentVisibility {
    Nested,
    Visible,
}

impl AgentVisibility {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Nested => "nested",
            Self::Visible => "visible",
        }
    }

    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "nested" => Some(Self::Nested),
            "visible" => Some(Self::Visible),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AgentLifecycle {
    Open,
    Closing,
    Closed,
}

impl AgentLifecycle {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Open => "open",
            Self::Closing => "closing",
            Self::Closed => "closed",
        }
    }

    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "open" => Some(Self::Open),
            "closing" => Some(Self::Closing),
            "closed" => Some(Self::Closed),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AssignmentLimits {
    pub(crate) max_turns: u16,
    pub(crate) timeout_seconds: u32,
    pub(crate) max_queued_assignments: u16,
}

impl Default for AssignmentLimits {
    fn default() -> Self {
        Self {
            max_turns: DEFAULT_MAX_TURNS,
            timeout_seconds: DEFAULT_TIMEOUT_SECONDS,
            max_queued_assignments: DEFAULT_MAX_QUEUED_ASSIGNMENTS,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentDefaults {
    pub(crate) model: Option<String>,
    pub(crate) reasoning_level: Option<String>,
    /// General capability authority, independent of whether an implementation
    /// is a direct module, script, persistent agent, schedule, or fixed service.
    pub(crate) capability_grant: Value,
    pub(crate) write_scopes: Vec<String>,
    pub(crate) limits: AssignmentLimits,
}

impl Default for AgentDefaults {
    fn default() -> Self {
        Self {
            model: None,
            reasoning_level: None,
            capability_grant: Value::Object(serde_json::Map::new()),
            write_scopes: Vec::new(),
            limits: AssignmentLimits::default(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentRecord {
    pub(crate) agent_id: String,
    pub(crate) transcript_session_id: String,
    pub(crate) root_agent_id: String,
    pub(crate) workspace_id: String,
    pub(crate) parent_agent_id: Option<String>,
    pub(crate) management_owner_agent_id: Option<String>,
    pub(crate) name: String,
    pub(crate) visibility: AgentVisibility,
    pub(crate) lifecycle: AgentLifecycle,
    pub(crate) defaults: AgentDefaults,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
    pub(crate) closed_at: Option<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct EnsureRootAgent {
    pub(crate) transcript_session_id: String,
    pub(crate) name: String,
    pub(crate) defaults: AgentDefaults,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AssignmentKind {
    Instruction,
    Request,
    Operator,
    Schedule,
}

impl AssignmentKind {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Instruction => "instruction",
            Self::Request => "request",
            Self::Operator => "operator",
            Self::Schedule => "schedule",
        }
    }

    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "instruction" => Some(Self::Instruction),
            "request" => Some(Self::Request),
            "operator" => Some(Self::Operator),
            "schedule" => Some(Self::Schedule),
            _ => None,
        }
    }

    pub(crate) const fn initial_status(self) -> AssignmentStatus {
        match self {
            Self::Request => AssignmentStatus::Offered,
            Self::Instruction | Self::Operator | Self::Schedule => AssignmentStatus::Queued,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AssignmentStatus {
    Offered,
    Queued,
    Running,
    Waiting,
    Completed,
    Declined,
    Failed,
    Cancelled,
    TimedOut,
    Expired,
}

impl AssignmentStatus {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Offered => "offered",
            Self::Queued => "queued",
            Self::Running => "running",
            Self::Waiting => "waiting",
            Self::Completed => "completed",
            Self::Declined => "declined",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::TimedOut => "timed_out",
            Self::Expired => "expired",
        }
    }

    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "offered" => Some(Self::Offered),
            "queued" => Some(Self::Queued),
            "running" => Some(Self::Running),
            "waiting" => Some(Self::Waiting),
            "completed" => Some(Self::Completed),
            "declined" => Some(Self::Declined),
            "failed" => Some(Self::Failed),
            "cancelled" => Some(Self::Cancelled),
            "timed_out" => Some(Self::TimedOut),
            "expired" => Some(Self::Expired),
            _ => None,
        }
    }

    pub(crate) const fn is_terminal(self) -> bool {
        matches!(
            self,
            Self::Completed
                | Self::Declined
                | Self::Failed
                | Self::Cancelled
                | Self::TimedOut
                | Self::Expired
        )
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum TerminalAssignmentStatus {
    Completed,
    Declined,
    Failed,
    Cancelled,
    TimedOut,
    Expired,
}

impl TerminalAssignmentStatus {
    pub(crate) const fn as_status(self) -> AssignmentStatus {
        match self {
            Self::Completed => AssignmentStatus::Completed,
            Self::Declined => AssignmentStatus::Declined,
            Self::Failed => AssignmentStatus::Failed,
            Self::Cancelled => AssignmentStatus::Cancelled,
            Self::TimedOut => AssignmentStatus::TimedOut,
            Self::Expired => AssignmentStatus::Expired,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AssignmentRecord {
    pub(crate) assignment_id: String,
    pub(crate) admission_key: String,
    pub(crate) agent_id: String,
    pub(crate) requested_by_agent_id: Option<String>,
    pub(crate) parent_assignment_id: Option<String>,
    pub(crate) retry_of_assignment_id: Option<String>,
    pub(crate) kind: AssignmentKind,
    pub(crate) status: AssignmentStatus,
    pub(crate) queue_ordinal: u64,
    pub(crate) trace_id: String,
    pub(crate) autonomous_hop: u32,
    pub(crate) causal_depth: u8,
    pub(crate) causal_ordinal: Option<u64>,
    pub(crate) task: String,
    pub(crate) context: Value,
    pub(crate) model: Option<String>,
    pub(crate) reasoning_level: Option<String>,
    pub(crate) capability_snapshot: Value,
    pub(crate) write_scopes_snapshot: Vec<String>,
    pub(crate) limits_snapshot: AssignmentLimits,
    pub(crate) deadline_at: Option<String>,
    pub(crate) created_at: String,
    pub(crate) accepted_at: Option<String>,
    pub(crate) started_at: Option<String>,
    pub(crate) completed_at: Option<String>,
    pub(crate) updated_at: String,
}

#[derive(Clone, Debug)]
pub(crate) struct NewAssignment {
    pub(crate) admission_key: String,
    pub(crate) agent_id: String,
    pub(crate) requested_by_agent_id: Option<String>,
    pub(crate) parent_assignment_id: Option<String>,
    pub(crate) retry_of_assignment_id: Option<String>,
    pub(crate) kind: AssignmentKind,
    pub(crate) task: String,
    pub(crate) context: Value,
    pub(crate) trace_id: Option<String>,
    pub(crate) autonomous_hop: u32,
    pub(crate) model: Option<String>,
    pub(crate) reasoning_level: Option<String>,
    pub(crate) capability_grant: Option<Value>,
    pub(crate) write_scopes: Option<Vec<String>>,
    pub(crate) limits: Option<AssignmentLimits>,
    pub(crate) deadline_at: Option<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct SpawnAgent {
    pub(crate) admission_key: String,
    pub(crate) parent_agent_id: String,
    pub(crate) parent_assignment_id: Option<String>,
    pub(crate) name: String,
    pub(crate) task: String,
    pub(crate) context: Value,
    pub(crate) defaults: AgentDefaults,
    pub(crate) trace_id: Option<String>,
    pub(crate) autonomous_hop: u32,
    pub(crate) deadline_at: Option<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct AgentAdmission {
    pub(crate) agent: AgentRecord,
    pub(crate) assignment: AssignmentRecord,
    pub(crate) created: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AssignmentAttemptRecord {
    pub(crate) attempt_id: String,
    pub(crate) assignment_id: String,
    pub(crate) attempt_number: u32,
    pub(crate) status: String,
    pub(crate) run_id: Option<String>,
    pub(crate) baseline_event_sequence: u64,
    pub(crate) started_at: String,
    pub(crate) completed_at: Option<String>,
    pub(crate) error: Option<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct ClaimAssignment {
    pub(crate) agent_id: String,
    pub(crate) run_id: String,
    pub(crate) baseline_event_sequence: u64,
}

#[derive(Clone, Debug)]
pub(crate) struct ClaimedAssignment {
    pub(crate) assignment: AssignmentRecord,
    pub(crate) attempt: AssignmentAttemptRecord,
}

#[derive(Clone, Debug)]
pub(crate) struct CompleteAssignment {
    pub(crate) assignment_id: String,
    pub(crate) terminal_status: TerminalAssignmentStatus,
    pub(crate) payload: Option<Value>,
    pub(crate) error: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentResultRecord {
    pub(crate) result_id: String,
    pub(crate) assignment_id: String,
    pub(crate) terminal_status: AssignmentStatus,
    pub(crate) payload: Option<Value>,
    pub(crate) payload_blob_id: Option<String>,
    pub(crate) payload_sha256: Option<String>,
    pub(crate) payload_byte_count: u64,
    pub(crate) error: Option<String>,
    pub(crate) created_at: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum MessageKind {
    Instruction,
    Request,
    Question,
    Answer,
    Information,
    Update,
}

impl MessageKind {
    pub(crate) const fn is_actionable(self) -> bool {
        !matches!(self, Self::Information)
    }
}

#[derive(Clone, Debug)]
pub(crate) struct SendMessage {
    pub(crate) idempotency_key: String,
    pub(crate) source_agent_id: String,
    pub(crate) target_agent_id: String,
    pub(crate) kind: MessageKind,
    pub(crate) content: String,
    pub(crate) assignment_id: Option<String>,
    pub(crate) reply_to_message_id: Option<String>,
    pub(crate) parent_assignment_id: Option<String>,
    pub(crate) trace_id: String,
    pub(crate) autonomous_hop: u32,
}

#[derive(Clone, Debug)]
pub(crate) struct MessageAdmission {
    pub(crate) message_id: String,
    pub(crate) assignment: Option<AssignmentRecord>,
    pub(crate) wake: Option<WakeIntentRecord>,
    pub(crate) autonomy_paused: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum WaitMode {
    All,
    Any,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "id", rename_all = "snake_case")]
pub(crate) enum WaitTarget {
    Assignment(String),
    Reply(String),
}

#[derive(Clone, Debug)]
pub(crate) struct RegisterWait {
    pub(crate) idempotency_key: String,
    pub(crate) owner_agent_id: String,
    pub(crate) owner_assignment_id: Option<String>,
    pub(crate) trace_id: String,
    pub(crate) autonomous_hop: u32,
    pub(crate) mode: WaitMode,
    pub(crate) targets: Vec<WaitTarget>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct WaitAdmission {
    pub(crate) wait_id: String,
    pub(crate) disposition: String,
    pub(crate) satisfied_targets: Vec<WaitTarget>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct WakeIntentRecord {
    pub(crate) wake_id: String,
    pub(crate) idempotency_key: String,
    pub(crate) target_agent_id: String,
    pub(crate) target_session_id: String,
    pub(crate) target_assignment_id: Option<String>,
    pub(crate) cause_kind: String,
    pub(crate) cause_id: String,
    pub(crate) trace_id: String,
    pub(crate) autonomous_hop: u32,
    pub(crate) materialized_message_id: Option<String>,
    pub(crate) priority: u8,
    pub(crate) disposition: String,
    pub(crate) not_before: Option<String>,
    pub(crate) lease_id: Option<String>,
    pub(crate) delivered_by_lease_id: Option<String>,
    pub(crate) lease_count: u32,
    pub(crate) last_error: Option<String>,
    pub(crate) created_at: String,
    pub(crate) leased_at: Option<String>,
    pub(crate) delivered_at: Option<String>,
    pub(crate) cancelled_at: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AgentRuntimeStatus {
    Active,
    Waiting,
    Queued,
    Idle,
    Closing,
    Closed,
    AutonomyPaused,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CoordinationTraceRecord {
    pub(crate) trace_id: String,
    pub(crate) root_agent_id: String,
    pub(crate) root_session_id: String,
    pub(crate) state: String,
    pub(crate) reason: Option<String>,
    pub(crate) message_count: u32,
    pub(crate) message_baseline: u32,
    pub(crate) max_autonomous_hop: u32,
    pub(crate) paused_agent_id: Option<String>,
    pub(crate) paused_assignment_id: Option<String>,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
    pub(crate) paused_at: Option<String>,
    pub(crate) resumed_at: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum AgentRelationship {
    SelfAgent,
    Parent,
    Ancestor,
    Child,
    Descendant,
    Managed,
    PromotedChild,
    Correspondent,
    Unrelated,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentSummary {
    pub(crate) agent_id: String,
    pub(crate) name: String,
    pub(crate) relationship: AgentRelationship,
    pub(crate) depth: Option<u8>,
    pub(crate) status: AgentRuntimeStatus,
    pub(crate) current_task: Option<String>,
    pub(crate) current_assignment_id: Option<String>,
    pub(crate) last_activity_at: String,
    pub(crate) can_message: bool,
    pub(crate) can_manage: bool,
}

#[derive(Clone, Debug)]
pub(crate) struct AgentDiscoveryQuery {
    pub(crate) caller_agent_id: String,
    pub(crate) query: Option<String>,
    pub(crate) status: Option<AgentRuntimeStatus>,
    pub(crate) cursor: Option<String>,
    pub(crate) limit: usize,
    pub(crate) include_closed: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentPage {
    pub(crate) items: Vec<AgentSummary>,
    pub(crate) next_cursor: Option<String>,
    pub(crate) total: u64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentInspection {
    pub(crate) agent: AgentRecord,
    pub(crate) summary: AgentSummary,
    pub(crate) current_assignment: Option<AssignmentRecord>,
    pub(crate) assignment_count: u64,
    pub(crate) message_count: u64,
    pub(crate) child_count: u64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AssignmentPage {
    pub(crate) items: Vec<AssignmentRecord>,
    pub(crate) next_cursor: Option<String>,
    pub(crate) total: u64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentMessageAuditRecord {
    pub(crate) message_id: String,
    pub(crate) source_agent_id: String,
    pub(crate) target_agent_id: String,
    pub(crate) kind: String,
    pub(crate) authority: String,
    pub(crate) assignment_id: Option<String>,
    pub(crate) reply_to_message_id: Option<String>,
    pub(crate) content: String,
    pub(crate) disposition: String,
    pub(crate) created_at: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentMessagePage {
    pub(crate) items: Vec<AgentMessageAuditRecord>,
    pub(crate) next_cursor: Option<String>,
    pub(crate) total: u64,
}

#[derive(Clone, Debug)]
pub(crate) struct RespondToOffer {
    pub(crate) actor_agent_id: String,
    pub(crate) assignment_id: String,
    pub(crate) accept: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "id", rename_all = "snake_case")]
pub(crate) enum CancelTarget {
    Assignment(String),
    Agent(String),
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CancelRequest {
    pub(crate) idempotency_key: String,
    pub(crate) actor_agent_id: Option<String>,
    pub(crate) target: CancelTarget,
    pub(crate) reason: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CancelOutcome {
    pub(crate) cancelled_assignment_ids: Vec<String>,
    pub(crate) cancelled_agent_ids: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ConfigureAgent {
    pub(crate) idempotency_key: String,
    pub(crate) actor_agent_id: Option<String>,
    pub(crate) target_agent_id: String,
    pub(crate) defaults: AgentDefaults,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CloseAgent {
    pub(crate) idempotency_key: String,
    pub(crate) actor_agent_id: Option<String>,
    pub(crate) target_agent_id: String,
}

#[derive(Clone, Debug)]
pub(crate) struct RetryAssignment {
    pub(crate) admission_key: String,
    pub(crate) actor_agent_id: Option<String>,
    pub(crate) assignment_id: String,
    pub(crate) trace_id: Option<String>,
    pub(crate) autonomous_hop: u32,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PromoteAgent {
    pub(crate) idempotency_key: String,
    pub(crate) agent_id: String,
}
