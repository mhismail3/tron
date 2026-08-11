//! Private values exchanged between Agent Execution and EventStore.

use crate::domains::agent::coordination::{AgentRecord, AssignmentAttemptRecord, AssignmentRecord};

/// One durable assignment which may be driven without violating per-agent
/// single-flight or accepted-work FIFO ordering.
#[derive(Clone, Debug)]
pub(crate) struct AssignmentExecutionCandidate {
    pub(crate) agent: AgentRecord,
    pub(crate) assignment: AssignmentRecord,
    pub(crate) latest_attempt: Option<AssignmentAttemptRecord>,
}

/// Content-free startup repair evidence.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct AgentExecutionRecovery {
    pub(crate) interrupted_attempts: usize,
    pub(crate) recovered_wake_leases: usize,
}
