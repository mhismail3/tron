use super::PromptEngineCausality;
use serde_json::Value;

#[derive(Clone)]
pub struct PromptRequest {
    pub session_id: String,
    pub prompt: String,
    pub reasoning_level: Option<String>,
    pub attachments: Option<Vec<Value>>,
    /// Optional engine causality propagated from accepted/apply invocations
    /// into the provider turn.
    pub engine_causality: Option<PromptEngineCausality>,
}
