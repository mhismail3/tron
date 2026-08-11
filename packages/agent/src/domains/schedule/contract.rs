//! Closed scheduling contract and canonical domain records.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Maximum schedules returned by one list request.
pub(crate) const MAX_SCHEDULE_PAGE_SIZE: u16 = 100;
/// Default schedules returned by one list request.
pub(crate) const DEFAULT_SCHEDULE_PAGE_SIZE: u16 = 50;
/// Maximum recurrence dates or exception dates on one schedule.
pub(crate) const MAX_EXPLICIT_DATES: usize = 256;
/// Maximum occurrence candidates inspected during one bounded expansion.
pub(crate) const MAX_EXPANSION_CANDIDATES: usize = 65_535;
/// Maximum catch-up assignments admitted by one reconciliation.
pub(crate) const MAX_CATCH_UP: u16 = 256;
/// Occurrences this close to the dispatcher clock are treated as on-time.
pub(crate) const MISFIRE_GRACE_SECONDS: i64 = 30;

/// One internal request to the single scheduling capability.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub(crate) enum ScheduleAction {
    /// Create one schedule idempotently.
    Create {
        /// Provider invocation-derived idempotency key.
        idempotency_key: String,
        /// Stable agent that owns and may manage this schedule.
        owner_agent_id: String,
        /// User-facing label.
        name: String,
        /// Reusable-agent, fresh-agent, or namespaced capability target.
        target: ScheduleTarget,
        /// Immutable authority admitted by the authenticated caller. The
        /// execution boundary may narrow it but never expand it.
        authority: ScheduleAuthoritySnapshot,
        /// One-time or recurring timing.
        timing: ScheduleTiming,
        /// Restart and concurrency behavior.
        #[serde(default)]
        policy: SchedulePolicy,
    },
    /// List schedules using stable `(created_at, schedule_id)` keyset order.
    List {
        /// Restrict results to one owner when present.
        owner_agent_id: Option<String>,
        /// Include deleted tombstones.
        #[serde(default)]
        include_deleted: bool,
        /// Opaque cursor returned by a prior page.
        cursor: Option<String>,
        /// Bounded page size.
        limit: Option<u16>,
    },
    /// Read one schedule and its recent occurrence audit.
    Get {
        /// Stable schedule identifier.
        schedule_id: String,
        /// Number of recent occurrences to return.
        occurrence_limit: Option<u16>,
    },
    /// Replace selected mutable fields using revision compare-and-set.
    Update {
        /// Stable schedule identifier.
        schedule_id: String,
        /// Revision observed by the caller.
        expected_revision: u64,
        /// Closed patch; omitted values retain their prior value.
        patch: SchedulePatch,
    },
    /// Pause future time-based admission.
    Pause {
        /// Stable schedule identifier.
        schedule_id: String,
        /// Revision observed by the caller.
        expected_revision: u64,
    },
    /// Resume time-based admission from the current durable cursor.
    Resume {
        /// Stable schedule identifier.
        schedule_id: String,
        /// Revision observed by the caller.
        expected_revision: u64,
    },
    /// Tombstone a schedule while retaining occurrence evidence.
    Delete {
        /// Stable schedule identifier.
        schedule_id: String,
        /// Revision observed by the caller.
        expected_revision: u64,
    },
    /// Admit one manual occurrence idempotently, even while paused.
    RunNow {
        /// Stable schedule identifier.
        schedule_id: String,
        /// Provider invocation-derived idempotency key.
        idempotency_key: String,
    },
}

/// The three substrate-neutral public execution targets.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub(crate) enum ScheduleTarget {
    /// Queue a new assignment on an existing reusable agent.
    ReusableAgent {
        /// Stable target agent.
        agent_id: String,
        /// Normal assignment admitted for each occurrence.
        assignment: ScheduledAssignment,
    },
    /// Spawn a new agent and its first assignment for each occurrence.
    FreshAgent {
        /// Stable parent that owns each fresh agent.
        parent_agent_id: String,
        /// Optional display name inherited by each fresh agent.
        name: Option<String>,
        /// Optional non-authority model defaults for each fresh agent.
        defaults: Option<ScheduledAgentDefaults>,
        /// First normal assignment admitted for each occurrence.
        assignment: ScheduledAssignment,
    },
    /// Invoke one registry/package entrypoint without forcing an agent turn.
    Capability {
        /// Namespaced capability identifier resolved by the Engine registry.
        capability_id: String,
        /// Immutable resolved version when the registry entry is versioned.
        capability_version: Option<String>,
        /// Closed input retained with the schedule definition.
        input: Value,
    },
}

/// Non-authority defaults captured for a fresh scheduled agent.
///
/// Capability grants, write scopes, and limits belong exclusively to the
/// Engine-authored [`ScheduleAuthoritySnapshot`]; this value cannot smuggle a
/// second authority document into the execution boundary.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ScheduledAgentDefaults {
    /// Explicit model override admitted by provider/profile policy.
    pub model: Option<String>,
    /// Explicit reasoning override admitted by provider/profile policy.
    pub reasoning_level: Option<String>,
}

/// Normal assignment payload used by both agent target kinds.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ScheduledAssignment {
    /// Assignment objective.
    pub task: String,
    /// Structured context supplied beside the task.
    #[serde(default)]
    pub context: Value,
}

/// Exact schedule-time authority snapshot.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ScheduleAuthoritySnapshot {
    /// Authenticated principal whose authority was intersected at admission.
    pub principal_agent_id: String,
    /// Engine-authored immutable capability/write/management grant snapshot.
    pub grant: Value,
}

/// Time semantics for one schedule.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub(crate) enum ScheduleTiming {
    /// Run at one absolute RFC 3339 instant.
    Once {
        /// UTC or offset-bearing instant.
        at: String,
    },
    /// Run according to a bounded RFC 5545 recurrence set.
    Recurring {
        /// Floating local date-time (`YYYY-MM-DDTHH:MM:SS`).
        start_local: String,
        /// IANA timezone name, including `UTC` when desired.
        time_zone: String,
        /// One RFC 5545 RRULE value, with or without the `RRULE:` prefix.
        rrule: String,
        /// Additional floating local date-times in the same timezone.
        #[serde(default)]
        rdates: Vec<String>,
        /// Excluded floating local date-times in the same timezone.
        #[serde(default)]
        exdates: Vec<String>,
    },
}

/// Restart and overlap policy.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SchedulePolicy {
    /// How occurrences missed while the Engine was unavailable are handled.
    #[serde(default)]
    pub misfire: MisfirePolicy,
    /// How an occurrence behaves while earlier work remains active.
    #[serde(default)]
    pub overlap: OverlapPolicy,
    /// Catch-up admission ceiling; ignored by other misfire policies.
    #[serde(default = "default_max_catch_up")]
    pub max_catch_up: u16,
}

impl Default for SchedulePolicy {
    fn default() -> Self {
        Self {
            misfire: MisfirePolicy::RunOnce,
            overlap: OverlapPolicy::Queue,
            max_catch_up: default_max_catch_up(),
        }
    }
}

const fn default_max_catch_up() -> u16 {
    32
}

/// Durable restart misfire behavior.
#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum MisfirePolicy {
    /// Record the missed window without running it.
    Skip,
    /// Run only the most recent missed occurrence.
    #[default]
    RunOnce,
    /// Run the most recent bounded set, in chronological FIFO order.
    CatchUp,
}

/// Durable overlap behavior.
#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum OverlapPolicy {
    /// Keep occurrences queued in chronological FIFO order.
    #[default]
    Queue,
    /// Audit but do not run an occurrence while prior work is active.
    Skip,
}

/// Fields mutable through `update`.
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SchedulePatch {
    /// Replacement display name.
    pub name: Option<String>,
    /// Replacement target. Must be paired with a newly admitted authority
    /// snapshot so retargeting cannot reuse unrelated authority implicitly.
    pub target: Option<ScheduleTarget>,
    /// Replacement authority paired exactly with `target`.
    pub authority: Option<ScheduleAuthoritySnapshot>,
    /// Replacement timing. This resets the durable recurrence cursor.
    pub timing: Option<ScheduleTiming>,
    /// Replacement policy.
    pub policy: Option<SchedulePolicy>,
}

/// Canonical schedule lifecycle.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ScheduleState {
    /// The dispatcher may admit due occurrences.
    Active,
    /// Time-based admission is suspended; manual runs remain allowed.
    Paused,
    /// Tombstone retained for audit.
    Deleted,
}

/// Canonical schedule projection.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ScheduleRecord {
    /// Stable opaque identifier.
    pub schedule_id: String,
    /// Stable managing agent.
    pub owner_agent_id: String,
    /// User-facing label.
    pub name: String,
    /// Execution target.
    pub target: ScheduleTarget,
    /// Immutable schedule-time authority.
    pub authority: ScheduleAuthoritySnapshot,
    /// Canonical timing contract.
    pub timing: ScheduleTiming,
    /// Restart and overlap behavior.
    pub policy: SchedulePolicy,
    /// Lifecycle state.
    pub state: ScheduleState,
    /// Compare-and-set revision.
    pub revision: u64,
    /// Exclusive durable evaluation cursor.
    pub cursor_at: String,
    /// Next known occurrence, or `None` when exhausted.
    pub next_due_at: Option<String>,
    /// Last expansion failure, retained until a successful update/reconcile.
    pub last_error: Option<String>,
    /// Creation instant.
    pub created_at: String,
    /// Last mutation instant.
    pub updated_at: String,
    /// Tombstone instant.
    pub deleted_at: Option<String>,
}

/// Occurrence admission/audit state.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum OccurrenceState {
    /// Accepted and awaiting the agent execution boundary.
    Queued,
    /// Claimed by the execution boundary.
    Running,
    /// Assignment completed successfully.
    Completed,
    /// Assignment failed.
    Failed,
    /// Policy intentionally suppressed execution.
    Skipped,
    /// Cancelled during structural shutdown.
    Cancelled,
}

/// Why an occurrence exists.
#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum OccurrenceKind {
    /// Generated from `DTSTART`, RRULE, or RDATE.
    Scheduled,
    /// Explicit `run_now` request.
    Manual,
    /// One compact audit row describing a skipped misfire range.
    MisfireSummary,
}

/// Durable occurrence record, including the immutable execution snapshot.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ScheduleOccurrence {
    /// Stable opaque identifier.
    pub occurrence_id: String,
    /// Deterministic replay key.
    pub occurrence_key: String,
    /// Owning schedule.
    pub schedule_id: String,
    /// Schedule revision captured at admission.
    pub schedule_revision: u64,
    /// Admission origin.
    pub kind: OccurrenceKind,
    /// Nominal UTC instant.
    pub scheduled_for: String,
    /// Current lifecycle state.
    pub state: OccurrenceState,
    /// Immutable target snapshot.
    pub target: ScheduleTarget,
    /// Immutable authority snapshot.
    pub authority: ScheduleAuthoritySnapshot,
    /// Number represented by a compact misfire summary.
    pub missed_count: u64,
    /// First instant represented by a compact summary.
    pub window_start: Option<String>,
    /// Last instant represented by a compact summary.
    pub window_end: Option<String>,
    /// Why policy skipped this row.
    pub skip_reason: Option<String>,
    /// Stable agent created or reused by the execution boundary.
    pub agent_id: Option<String>,
    /// Stable assignment created by the execution boundary.
    pub assignment_id: Option<String>,
    /// Stable direct/service/script invocation created by the execution
    /// boundary for a capability target.
    pub invocation_id: Option<String>,
    /// Terminal output/result reference.
    pub output_ref: Option<String>,
    /// Terminal failure evidence.
    pub failure: Option<String>,
    /// Admission timestamp.
    pub created_at: String,
    /// Claim timestamp.
    pub started_at: Option<String>,
    /// Terminal timestamp.
    pub finished_at: Option<String>,
}

/// Stable keyset page.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SchedulePage {
    /// Canonical rows.
    pub schedules: Vec<ScheduleRecord>,
    /// Cursor for the following page.
    pub next_cursor: Option<String>,
}

/// `get` response with bounded recent audit.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ScheduleDetail {
    /// Canonical schedule.
    pub schedule: ScheduleRecord,
    /// Newest-first occurrence audit.
    pub occurrences: Vec<ScheduleOccurrence>,
}

/// Closed response union matching [`ScheduleAction`].
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub(crate) enum ScheduleResponse {
    /// Created schedule (or its exact idempotent replay).
    Create { schedule: ScheduleRecord },
    /// Bounded list page.
    List { page: SchedulePage },
    /// Schedule detail.
    Get { detail: ScheduleDetail },
    /// Updated canonical schedule.
    Update { schedule: ScheduleRecord },
    /// Paused canonical schedule.
    Pause { schedule: ScheduleRecord },
    /// Resumed canonical schedule.
    Resume { schedule: ScheduleRecord },
    /// Deleted tombstone.
    Delete { schedule: ScheduleRecord },
    /// Manual occurrence (or exact idempotent replay).
    RunNow { occurrence: ScheduleOccurrence },
}
