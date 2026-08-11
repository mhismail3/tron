//! Core reusable-agent coordination.
//!
//! This is the dormant same-database successor to reusable-agent behavior that
//! is currently implemented by the Worker Kernel. It owns the durable meaning
//! of a stable agent, one-at-a-time FIFO assignments, semantic messages,
//! runtime parking, immutable results, and safe-boundary wake intents. It is
//! intentionally not registered as a provider or client surface yet.
//!
//! ## Identity model
//!
//! - `agentId` is a durable address with one persistent transcript.
//! - `assignmentId` is one queued/running/terminal unit of work and the only
//!   causal topology node.
//! - Attempts are restart evidence for an assignment, never new work identity.
//!
//! There is no `executionId`, worker kind, direct-worker adapter, or role
//! version or skill assignment in this model. Runtime-discovered capability
//! packages remain independent of agent identity and authority.
//!
//! ## Delivery model
//!
//! Message semantics, rather than model-selected wake flags, decide whether a
//! safe-boundary wake intent is durable. Information is passive. Instructions,
//! requests, questions, answers, and updates are actionable. Assignment
//! completion either creates one automatic result wake or is absorbed by an
//! explicit wait; a resolved wait owns one aggregate wake. Wake leasing must be
//! consumed by the Agent Execution service only between provider/tool calls.
//!
//! ## Storage boundary
//!
//! `CoordinationService` is a narrow domain facade. `EventStore` commits all
//! identity, transcript, assignment, result, wait, message, and wake facts in
//! `tron.sqlite`; no cross-database transaction or outbox is required. The
//! existing Worker implementation remains the advertised runtime until a
//! later all-at-once cutover wires this service into scheduling and tools.

use std::sync::Arc;

use crate::domains::session::event_store::{EventStore, Result};

mod model;

pub(crate) use model::*;

/// Domain entry point for the unadvertised core coordination store.
#[derive(Clone)]
pub(crate) struct CoordinationService {
    event_store: Arc<EventStore>,
}

impl CoordinationService {
    pub(crate) fn new(event_store: Arc<EventStore>) -> Self {
        Self { event_store }
    }

    pub(crate) fn ensure_root_agent(&self, request: &EnsureRootAgent) -> Result<AgentRecord> {
        self.event_store.ensure_core_root_agent(request)
    }

    pub(crate) fn spawn(&self, request: &SpawnAgent) -> Result<AgentAdmission> {
        self.event_store.spawn_core_agent(request)
    }

    pub(crate) fn admit_assignment(&self, request: &NewAssignment) -> Result<AssignmentRecord> {
        self.event_store.admit_core_assignment(request)
    }

    pub(crate) fn discover(&self, query: &AgentDiscoveryQuery) -> Result<AgentPage> {
        self.event_store.discover_core_agents(query)
    }

    pub(crate) fn inspect(
        &self,
        caller_agent_id: Option<&str>,
        agent_id: &str,
    ) -> Result<AgentInspection> {
        self.event_store
            .inspect_core_agent(caller_agent_id, agent_id)
    }

    pub(crate) fn assignments(
        &self,
        agent_id: &str,
        cursor: Option<&str>,
        limit: usize,
    ) -> Result<AssignmentPage> {
        self.event_store
            .core_agent_assignments(agent_id, cursor, limit)
    }

    pub(crate) fn messages(
        &self,
        agent_id: &str,
        cursor: Option<&str>,
        limit: usize,
    ) -> Result<AgentMessagePage> {
        self.event_store
            .core_agent_messages(agent_id, cursor, limit)
    }

    pub(crate) fn respond_to_offer(&self, request: &RespondToOffer) -> Result<AssignmentRecord> {
        self.event_store.respond_to_core_assignment_offer(request)
    }

    pub(crate) fn claim_next(
        &self,
        request: &ClaimAssignment,
    ) -> Result<Option<ClaimedAssignment>> {
        self.event_store.claim_next_core_assignment(request)
    }

    pub(crate) fn reconcile_parking(&self, assignment_id: &str) -> Result<AssignmentRecord> {
        self.event_store
            .reconcile_core_assignment_parking(assignment_id)
    }

    pub(crate) fn complete(&self, request: &CompleteAssignment) -> Result<AgentResultRecord> {
        self.event_store.complete_core_assignment(request)
    }

    pub(crate) fn send(&self, request: &SendMessage) -> Result<MessageAdmission> {
        self.event_store.send_core_agent_message(request)
    }

    pub(crate) fn wait(&self, request: &RegisterWait) -> Result<WaitAdmission> {
        self.event_store.register_core_agent_wait(request)
    }

    pub(crate) fn result(&self, result_id: &str) -> Result<Option<AgentResultRecord>> {
        self.event_store.core_agent_result(result_id)
    }

    pub(crate) fn pending_wakes(&self, limit: usize) -> Result<Vec<WakeIntentRecord>> {
        self.event_store.pending_core_agent_wakes(limit)
    }

    pub(crate) fn lease_wake(
        &self,
        agent_id: &str,
        lease_id: &str,
    ) -> Result<Option<WakeIntentRecord>> {
        self.event_store
            .lease_next_core_agent_wake(agent_id, lease_id)
    }

    pub(crate) fn finish_wake(
        &self,
        wake_id: &str,
        lease_id: &str,
        delivered: bool,
        error: Option<&str>,
    ) -> Result<WakeIntentRecord> {
        self.event_store
            .finish_core_agent_wake(wake_id, lease_id, delivered, error)
    }

    pub(crate) fn recover_wake_leases(&self) -> Result<usize> {
        self.event_store.recover_core_agent_wake_leases()
    }

    pub(crate) fn trace(&self, trace_id: &str) -> Result<Option<CoordinationTraceRecord>> {
        self.event_store.core_coordination_trace(trace_id)
    }

    /// Authenticated operator/user handling owns this call. Model-facing
    /// agent actions cannot resume their own paused causal graph.
    pub(crate) fn resume_trace(&self, trace_id: &str) -> Result<Option<WakeIntentRecord>> {
        self.event_store.resume_core_coordination_trace(trace_id)
    }

    pub(crate) fn cancel(&self, request: &CancelRequest) -> Result<CancelOutcome> {
        self.event_store.cancel_core_agent_work(request)
    }

    pub(crate) fn configure(&self, request: &ConfigureAgent) -> Result<AgentRecord> {
        self.event_store.configure_core_agent(request)
    }

    pub(crate) fn close(&self, request: &CloseAgent) -> Result<Vec<AgentRecord>> {
        self.event_store.close_core_agent(request)
    }

    pub(crate) fn retry(&self, request: &RetryAssignment) -> Result<AssignmentRecord> {
        self.event_store.retry_core_assignment(request)
    }

    pub(crate) fn promote(&self, request: &PromoteAgent) -> Result<AgentRecord> {
        self.event_store.promote_core_agent(request)
    }
}

#[cfg(test)]
mod tests;
