use super::PromptEngineCausality;
use crate::domains::agent::r#loop::types::AgentRunTrigger;
use serde_json::Value;

/// Accepted run inputs and the sole plan-level invocation-causality owner
/// until execution consumes the request.
pub struct PromptRequest {
    pub session_id: String,
    pub trigger: AgentRunTrigger,
    pub reasoning_level: Option<String>,
    pub attachments: Option<Vec<Value>>,
    /// Structured presentation metadata merged into the admitted user event.
    /// Only trusted agent-domain handlers construct this value.
    pub user_event_metadata: Option<Value>,
    /// Engine causality moved from the accepted invocation into the provider
    /// turn, completion events, and runtime stream records.
    pub engine_causality: Option<PromptEngineCausality>,
}
