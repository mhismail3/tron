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
    /// Function call (capability invocation by assistant).
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
    /// Function call output (capability result).
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
/// Uses internally tagged serialization on `"type"` to discriminate variants.
/// GPT 5.4+ supports `ToolSearch` and `Computer` entries alongside functions.
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
        /// When `true`, the tool is available but not loaded into the prompt
        /// until the model's tool search selects it.
        #[serde(skip_serializing_if = "Option::is_none")]
        defer_loading: Option<bool>,
    },
    /// ModelCapability search sentinel — enables the model to dynamically discover capabilities.
    #[serde(rename = "tool_search")]
    ToolSearch {},
    /// Provider wire variant for future computer-use responses.
    #[serde(rename = "computer")]
    Computer {
        /// Viewport width in pixels.
        #[serde(skip_serializing_if = "Option::is_none")]
        viewport_width: Option<u32>,
        /// Viewport height in pixels.
        #[serde(skip_serializing_if = "Option::is_none")]
        viewport_height: Option<u32>,
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
    /// Provider-wire tools generated from Tron capability primitives.
    #[serde(rename = "tools")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capabilities: Option<Vec<ResponsesToolEntry>>,
    /// Max output tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_output_tokens: Option<u32>,
    /// Reasoning configuration.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning: Option<ReasoningConfig>,
    /// Text output configuration.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<ResponseTextConfig>,
    /// Stable prompt-cache routing key.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt_cache_key: Option<String>,
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
    /// Output items.
    #[serde(default)]
    pub output: Vec<ResponsesOutputItem>,
    /// Usage information.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usage: Option<ResponsesUsage>,
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
    /// New output item (capability invocation or reasoning started).
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
    /// ModelCapability search call started (hosted tool search).
    #[serde(rename = "response.tool_search_call.searching")]
    ToolSearchCallSearching,
    /// ModelCapability search call completed (hosted tool search).
    #[serde(rename = "response.tool_search_call.completed")]
    ToolSearchCallCompleted,
    /// Provider wire variant for computer-call completion events.
    #[serde(rename = "response.computer_call.completed")]
    ComputerCallCompleted,
    /// Final complete response.
    #[serde(rename = "response.completed")]
    Completed,
    /// Forward-compatible catch-all for unknown event types.
    #[default]
    #[serde(other)]
    Unknown,
}

/// Output item types from the Responses API.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OutputItemType {
    /// Function call (capability invocation by assistant).
    FunctionCall,
    /// Message content.
    Message,
    /// Reasoning/thinking.
    Reasoning,
    /// ModelCapability search call (hosted tool discovery).
    ToolSearchCall,
    /// ModelCapability search output (hosted tool discovery result).
    ToolSearchOutput,
    /// Computer call (screenshot + action loop).
    ComputerCall,
    /// Forward-compatible catch-all for unknown item types.
    #[default]
    #[serde(other)]
    Unknown,
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────
