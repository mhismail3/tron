//! Engine queue primitive.
//!
//! Queues provide durable at-least-once handoff for engine invocations. The
//! primitive stores invocation payload plus causality so a later drain can
//! invoke the same function with the original authority and trace context. A
//! retried queue item keeps the original logical idempotency key on the item,
//! but executes retry attempts with attempt-scoped target keys so a stored
//! handler failure does not turn into a permanent replay result. Queue failure
//! lifecycle events are emitted from the post-fail item state, so stream
//! subscribers see the authoritative retry/dead-letter status and attempt count.
//! Cancellation is terminal for an in-flight item: the queue clears the lease,
//! publishes cancellation, and a late target result cannot complete or fail the
//! cancelled receipt.
//! Attempt records live on the queue item, not only in lifecycle streams. They
//! keep delivery/result ids, replay refs, errors, lease owner, resource leases,
//! and compensation refs for `queue::get`/`queue::list` inspection.
//! Worker transport loss before a non-mutating queued target returns is treated
//! as delivery failure: the queue publishes retry state, but the target
//! invocation ledger does not record an application-level handler failure.

use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::engine::catalog::discovery::ActorKind;
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, TriggerId,
};

mod memory;
mod runtime;
mod sqlite_codec;
mod sqlite_store;

pub use memory::InMemoryEngineQueueStore;
pub use runtime::{EngineQueueDrainer, EngineQueueRuntime, publish_queue_lifecycle_event};
pub(in crate::engine) use runtime::{queue_failure_event_type, queue_lifecycle_stream_event};
pub use sqlite_store::SqliteEngineQueueStore;

/// Queue item lifecycle.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QueueItemStatus {
    /// Ready to be claimed.
    Ready,
    /// Claimed by a worker until the lease expires.
    Leased,
    /// Completed.
    Completed,
    /// Cancelled before completion.
    Cancelled,
    /// Dead-lettered after retry exhaustion.
    DeadLettered,
}

impl QueueItemStatus {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Ready => "ready",
            Self::Leased => "leased",
            Self::Completed => "completed",
            Self::Cancelled => "cancelled",
            Self::DeadLettered => "dead_lettered",
        }
    }
}

/// Durable queue attempt outcome.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QueueAttemptOutcome {
    /// Target completed successfully.
    Completed,
    /// Target failed and will retry if attempts remain.
    Failed,
    /// Target failed and exhausted retry attempts.
    DeadLettered,
}

/// One durable queue delivery attempt.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineQueueAttemptRecord {
    /// One-based delivery attempt number.
    pub attempt: u32,
    /// Outcome for this attempt.
    pub outcome: QueueAttemptOutcome,
    /// Queue lease owner that executed the attempt.
    pub lease_owner: Option<String>,
    /// Delivery result id even when no target invocation row was committed.
    pub delivery_invocation_id: Option<InvocationId>,
    /// Target invocation row id, when the target result was ledgered.
    pub result_invocation_id: Option<InvocationId>,
    /// Idempotent source invocation reused by this attempt, if any.
    pub replayed_from_invocation_id: Option<InvocationId>,
    /// Stable error string, if the attempt failed.
    pub error: Option<String>,
    /// Whether an invocation row was recorded for the target attempt.
    pub recorded_invocation: bool,
    /// Resource leases acquired by the target invocation.
    pub resource_lease_ids: Vec<String>,
    /// Compensation status recorded for the target invocation.
    pub compensation_status: Option<String>,
    /// Compensation audit record id, when one was written.
    pub compensation_id: Option<String>,
}

/// Durable queued engine invocation.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineQueueItem {
    /// Receipt id returned to enqueue caller.
    pub receipt_id: String,
    /// Queue name.
    pub queue: String,
    /// Target function id.
    pub function_id: FunctionId,
    /// Payload to invoke.
    pub payload: Value,
    /// Actor id.
    pub actor_id: ActorId,
    /// Actor kind.
    pub actor_kind: ActorKind,
    /// Authority grant.
    pub authority_grant_id: AuthorityGrantId,
    /// Authority scopes.
    pub authority_scopes: Vec<String>,
    /// Engine runtime metadata.
    pub runtime_metadata: BTreeMap<String, String>,
    /// Trace id.
    pub trace_id: TraceId,
    /// Parent invocation id.
    pub parent_invocation_id: Option<InvocationId>,
    /// Trigger id.
    pub trigger_id: Option<TriggerId>,
    /// Session id.
    pub session_id: Option<String>,
    /// Workspace id.
    pub workspace_id: Option<String>,
    /// Idempotency key for the target invocation.
    pub idempotency_key: Option<String>,
    /// Status.
    pub status: QueueItemStatus,
    /// Number of failed attempts.
    pub attempts: u32,
    /// Durable delivery attempt records.
    pub attempt_records: Vec<EngineQueueAttemptRecord>,
    /// Current lease owner.
    pub lease_owner: Option<String>,
    /// Current lease expiry.
    pub lease_expires_at: Option<DateTime<Utc>>,
    /// Next time the item may be claimed.
    pub not_before: DateTime<Utc>,
    /// Creation time.
    pub created_at: DateTime<Utc>,
    /// Last update time.
    pub updated_at: DateTime<Utc>,
}

/// Request to enqueue one invocation.
#[derive(Clone, Debug, PartialEq)]
pub struct EnqueueInvocation {
    /// Queue name.
    pub queue: String,
    /// Target function id.
    pub function_id: FunctionId,
    /// Payload.
    pub payload: Value,
    /// Actor id.
    pub actor_id: ActorId,
    /// Actor kind.
    pub actor_kind: ActorKind,
    /// Authority grant.
    pub authority_grant_id: AuthorityGrantId,
    /// Authority scopes.
    pub authority_scopes: Vec<String>,
    /// Engine runtime metadata.
    pub runtime_metadata: BTreeMap<String, String>,
    /// Trace id.
    pub trace_id: TraceId,
    /// Parent invocation id.
    pub parent_invocation_id: Option<InvocationId>,
    /// Trigger id.
    pub trigger_id: Option<TriggerId>,
    /// Session id.
    pub session_id: Option<String>,
    /// Workspace id.
    pub workspace_id: Option<String>,
    /// Idempotency key.
    pub idempotency_key: Option<String>,
}
