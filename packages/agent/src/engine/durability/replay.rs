//! Replay read DTOs for engine-owned durable rows.
//!
//! This module intentionally contains no replay executor. It is the typed
//! snapshot shape used by the session replay manifest builder to read engine
//! ledger, idempotency, stream, and queue rows without re-running engine work.

use crate::engine::durability::ledger::IdempotencyEntry;
use crate::engine::durability::queue::EngineQueueItem;
use crate::engine::durability::streams::EngineStreamEvent;
use crate::engine::invocation::model::InvocationRecord;

/// Durable engine rows scoped to one session.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct EngineReplaySnapshot {
    /// Engine invocation ledger rows in durable append order.
    pub(crate) invocations: Vec<InvocationRecord>,
    /// Engine idempotency entries that explain the session.
    pub(crate) idempotency_entries: Vec<IdempotencyEntry>,
    /// Engine stream rows in cursor order.
    pub(crate) streams: Vec<EngineStreamEvent>,
    /// Engine queue rows in replay durable-key order.
    pub(crate) queue_items: Vec<EngineQueueItem>,
}
