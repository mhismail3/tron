//! Canonical function inventory for the agent domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "agent::prompt",
    "agent::abort",
    "agent::abort_tool",
    "agent::status",
    "agent::queue_prompt",
    "agent::dequeue_prompt",
    "agent::clear_queue",
    "agent::deliver_subagent_results",
    "agent::submit_confirmation",
    "agent::submit_answers",
];
