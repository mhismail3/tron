//! Subagent lineage helpers shared by agent operations and runner completion.
//!
//! Subagent result truth is represented by `agent_result` resources with a
//! deterministic `agent_result:subagent:{session}` id. Event rows and iOS
//! chips remain navigation affordances; this module keeps the resource identity
//! stable for status/result reconstruction and generated UI projections.

pub(crate) const SUBAGENT_RESULT_RESOURCE_PREFIX: &str = "agent_result:subagent:";

pub(crate) fn subagent_result_resource_id(subagent_session_id: &str) -> String {
    format!("{SUBAGENT_RESULT_RESOURCE_PREFIX}{subagent_session_id}")
}
