use super::PromptEngineCausality;
use serde_json::Value;

/// Accepted prompt inputs and the sole plan-level invocation-causality owner
/// until execution consumes the request.
pub struct PromptRequest {
    pub session_id: String,
    pub prompt: String,
    pub reasoning_level: Option<String>,
    pub attachments: Option<Vec<Value>>,
    /// Engine causality moved from the accepted invocation into the provider
    /// turn, completion events, and runtime stream records.
    pub engine_causality: Option<PromptEngineCausality>,
}
