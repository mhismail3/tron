//! OpenAI Responses API request and SSE wire DTOs.

use serde::{Deserialize, Serialize};
use serde_json::Value;

// ─────────────────────────────────────────────────────────────────────────────
// Responses API Request Types
// ─────────────────────────────────────────────────────────────────────────────

/// A message content block in the Responses API.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum MessageContent {
    /// Output text (assistant).
    #[serde(rename = "output_text")]
    OutputText {
        /// The text content.
        text: String,
    },
    /// Input text (user).
    #[serde(rename = "input_text")]
    InputText {
        /// The text content.
        text: String,
    },
    /// Input image (user).
    #[serde(rename = "input_image")]
    InputImage {
        /// Base64 data URL.
        image_url: String,
        /// Detail level.
        #[serde(skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
    },
}

/// An input item for the Responses API.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ResponsesInputItem {
    /// Simple text input.
    #[serde(rename = "input_text")]
    InputText {
        /// The text content.
        text: String,
    },
    /// Message with role and content.
    #[serde(rename = "message")]
    Message {
        /// Role: "user", "assistant", or "developer".
        role: String,
        /// Content blocks.
        content: Vec<MessageContent>,
        /// Optional message ID (returned by API, omitted in requests).
        #[serde(skip_serializing_if = "Option::is_none")]
        id: Option<String>,
    },
    /// Function call (tool invocation by assistant).
    #[serde(rename = "function_call")]
    FunctionCall {
        /// Optional item ID (returned by API, omitted in requests).
        #[serde(skip_serializing_if = "Option::is_none")]
        id: Option<String>,
        /// Call ID.
        call_id: String,
        /// Function name.
        name: String,
        /// JSON-encoded arguments.
        arguments: String,
    },
    /// Function call output (tool result).
    #[serde(rename = "function_call_output")]
    FunctionCallOutput {
        /// Call ID this result corresponds to.
        call_id: String,
        /// Output string.
        output: String,
    },
}

/// Polymorphic tool entry for the Responses API.
///
/// The primitive branch exports only concrete function tools. Hosted tool
/// search and computer-use entries are intentionally not represented here.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ResponsesToolEntry {
    /// Standard function tool.
    #[serde(rename = "function")]
    Function {
        /// Function name.
        name: String,
        /// Function description.
        description: String,
        /// JSON Schema for parameters.
        parameters: Value,
    },
}

/// Request body for the Responses API.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResponsesRequest {
    /// Model ID.
    pub model: String,
    /// Input items.
    pub input: Vec<ResponsesInputItem>,
    /// System instructions.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub instructions: Option<String>,
    /// Whether to stream the response.
    pub stream: bool,
    /// Whether to store the conversation.
    pub store: bool,
    /// Temperature.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f64>,
    /// Provider-wire tools generated from Tron's resolved tool surface.
    #[serde(rename = "tools")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tools: Option<Vec<ResponsesToolEntry>>,
    /// Max output tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_output_tokens: Option<u32>,
    /// Reasoning configuration.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning: Option<ReasoningConfig>,
    /// Text output configuration.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<ResponseTextConfig>,
}

/// Reasoning configuration for the Responses API.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ReasoningConfig {
    /// Effort level.
    pub effort: String,
    /// Summary format (always "detailed").
    pub summary: String,
}

/// Text output configuration for the Responses API.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResponseTextConfig {
    /// Verbosity level.
    pub verbosity: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// Responses API SSE Event Types
// ─────────────────────────────────────────────────────────────────────────────

/// An output item from the Responses API.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ResponsesOutputItem {
    /// Item type: `function_call`, `message`, `reasoning`, etc.
    #[serde(rename = "type")]
    pub item_type: OutputItemType,
    /// Item ID.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// Call ID (for `function_call` items).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub call_id: Option<String>,
    /// Function name (for `function_call` items).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Function arguments (for `function_call` items).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub arguments: Option<String>,
    /// Content blocks (for message items).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<Vec<OutputContent>>,
    /// Reasoning summary parts.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<Vec<OutputContent>>,
}

/// Content block within an output item.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OutputContent {
    /// Content type.
    #[serde(rename = "type")]
    pub content_type: String,
    /// Text content.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

/// Usage information from the Responses API.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ResponsesUsage {
    /// Input tokens.
    #[serde(default)]
    pub input_tokens: u64,
    /// Input token details.
    #[serde(default)]
    pub input_tokens_details: InputTokensDetails,
    /// Output tokens.
    #[serde(default)]
    pub output_tokens: u64,
    /// Output token details.
    #[serde(default)]
    pub output_tokens_details: OutputTokensDetails,
    /// Total tokens.
    #[serde(default)]
    pub total_tokens: u64,
}

/// Detailed input token accounting from the Responses API.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct InputTokensDetails {
    /// Prompt tokens served from cache.
    #[serde(default)]
    pub cached_tokens: u64,
}

/// Detailed output token accounting from the Responses API.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct OutputTokensDetails {
    /// Hidden reasoning tokens.
    #[serde(default)]
    pub reasoning_tokens: u64,
}

/// Full response object (from `response.completed`).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResponsesResponse {
    /// Response ID.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// Provider error attached to a failed response.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ResponsesError>,
    /// Provider reason attached to an incomplete response.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub incomplete_details: Option<ResponsesIncompleteDetails>,
    /// Output items.
    #[serde(default)]
    pub output: Vec<ResponsesOutputItem>,
    /// Usage information.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usage: Option<ResponsesUsage>,
}

/// Error details carried by a failed Responses API response.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ResponsesError {
    /// Provider error type when it is distinct from or substitutes for `code`.
    #[serde(default, rename = "type")]
    pub error_type: Option<String>,
    /// Provider-specific error code.
    #[serde(default)]
    pub code: Option<String>,
    /// Human-readable provider error message.
    #[serde(default)]
    pub message: String,
}

/// Reason carried by an incomplete Responses API response.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ResponsesIncompleteDetails {
    /// Provider reason, such as `max_output_tokens` or `content_filter`.
    #[serde(default)]
    pub reason: Option<String>,
}

/// A Responses API SSE event.
///
/// Events are parsed from the SSE stream by matching on the `type` field.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ResponsesSseEvent {
    /// Event type (e.g., [`SseEventType::OutputTextDelta`]).
    #[serde(rename = "type")]
    pub event_type: SseEventType,
    /// Text delta (for text and reasoning summary deltas).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delta: Option<String>,
    /// Content index.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content_index: Option<u32>,
    /// Summary index (for reasoning summary deltas).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary_index: Option<u32>,
    /// Output item (for `output_item.added` / `output_item.done`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub item: Option<ResponsesOutputItem>,
    /// Call ID (for `function_call_arguments.delta`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub call_id: Option<String>,
    /// Error code on a top-level `error` stream event.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    /// Error message on a top-level `error` stream event.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    /// Nested error envelope used by some Responses-compatible streaming paths.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ResponsesError>,
    /// Full response (for `response.completed`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub response: Option<ResponsesResponse>,
}

/// SSE event types from the Responses API.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum SseEventType {
    /// Streaming text content.
    #[serde(rename = "response.output_text.delta")]
    OutputTextDelta,
    /// New output item (tool invocation or reasoning started).
    #[serde(rename = "response.output_item.added")]
    OutputItemAdded,
    /// Output item finished.
    #[serde(rename = "response.output_item.done")]
    OutputItemDone,
    /// New reasoning summary part added.
    #[serde(rename = "response.reasoning_summary_part.added")]
    ReasoningSummaryPartAdded,
    /// Full reasoning text delta.
    #[serde(rename = "response.reasoning_text.delta")]
    ReasoningTextDelta,
    /// Streaming reasoning summary text.
    #[serde(rename = "response.reasoning_summary_text.delta")]
    ReasoningSummaryTextDelta,
    /// Streaming function call arguments.
    #[serde(rename = "response.function_call_arguments.delta")]
    FunctionCallArgsDelta,
    /// Final complete response.
    #[serde(rename = "response.completed")]
    Completed,
    /// Terminal provider failure containing a failed response object.
    #[serde(rename = "response.failed")]
    Failed,
    /// Terminal response with partial output and an incomplete reason.
    #[serde(rename = "response.incomplete")]
    Incomplete,
    /// Top-level Responses API stream error.
    #[serde(rename = "error")]
    Error,
    /// Forward-compatible catch-all for unknown event types.
    #[default]
    #[serde(other)]
    Unknown,
}

/// Output item types from the Responses API.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OutputItemType {
    /// Function call (tool invocation by assistant).
    FunctionCall,
    /// Message content.
    Message,
    /// Reasoning/thinking.
    Reasoning,
    /// Forward-compatible catch-all for unknown item types.
    #[default]
    #[serde(other)]
    Unknown,
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────
