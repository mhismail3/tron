use super::PromptEngineCausality;
use serde_json::Value;

#[derive(Clone)]
pub struct PromptRequest {
    pub session_id: String,
    pub prompt: String,
    pub reasoning_level: Option<String>,
    pub images: Option<Vec<Value>>,
    pub attachments: Option<Vec<Value>>,
    /// Optional structured metadata merged into the emitted `message.user`
    /// event payload. Queue drains use this for event-source metadata that
    /// must survive until the queued prompt is emitted.
    pub message_metadata: Option<Value>,
    /// Optional engine causality propagated from accepted/apply invocations
    /// into completion-triggered prompt queue drains.
    pub engine_causality: Option<PromptEngineCausality>,
}
