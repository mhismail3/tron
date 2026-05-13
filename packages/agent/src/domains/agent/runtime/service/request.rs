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
    /// event payload. Used by interactive capability handlers (confirmation,
    /// answers) to tag the message with `messageKind` and structured fields
    /// so iOS can render a chip without parsing text content.
    pub message_metadata: Option<Value>,
    /// Optional engine causality propagated from accepted/apply invocations
    /// into completion-triggered prompt queue drains.
    pub engine_causality: Option<PromptEngineCausality>,
}
