//! `OpenAI` provider types, configuration, and model registry.
//!
//! Covers the Responses API types (not legacy Chat Completions).
//! The `OpenAI` provider uses the Codex endpoint with OAuth authentication.

use std::collections::HashMap;
use std::sync::LazyLock;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Default base URL for the `OpenAI` Codex API.
pub const DEFAULT_BASE_URL: &str = "https://chatgpt.com/backend-api";

/// Default base URL for the `OpenAI` Platform API.
pub const DEFAULT_PLATFORM_BASE_URL: &str = "https://api.openai.com";

/// Default model.
pub const DEFAULT_MODEL: &str = "gpt-5.3-codex";

/// Default max output tokens for unknown models.
pub const DEFAULT_MAX_OUTPUT_TOKENS: u32 = 128_000;

/// Maximum length for tool result output strings (16 KB).
///
/// The Codex endpoint has a per-output size limit. Results exceeding this
/// threshold are truncated with a `[truncated]` marker.
pub const TOOL_RESULT_MAX_LENGTH: usize = 16_384;

// ─────────────────────────────────────────────────────────────────────────────
// API Endpoint
// ─────────────────────────────────────────────────────────────────────────────

/// Which `OpenAI` API endpoint a model targets.
///
/// Codex models use the `ChatGPT` backend; GPT 5.4+ use the standard Platform API.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ApiEndpoint {
    /// `ChatGPT` Codex backend (`chatgpt.com/backend-api/codex/responses`).
    #[default]
    Codex,
    /// Standard Platform API (`api.openai.com/v1/responses`).
    Platform,
}

impl ApiEndpoint {
    /// Default base URL for this endpoint.
    #[must_use]
    pub fn default_base_url(self) -> &'static str {
        match self {
            Self::Codex => DEFAULT_BASE_URL,
            Self::Platform => DEFAULT_PLATFORM_BASE_URL,
        }
    }

    /// URL path suffix for this endpoint.
    #[must_use]
    pub fn path(self) -> &'static str {
        match self {
            Self::Codex => "/codex/responses",
            Self::Platform => "/v1/responses",
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Authentication
// ─────────────────────────────────────────────────────────────────────────────

/// `OpenAI` authentication.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum OpenAIAuth {
    /// OAuth authentication (Codex endpoint).
    #[serde(rename = "oauth")]
    OAuth {
        /// OAuth tokens.
        tokens: crate::auth::OAuthTokens,
    },
    /// API key authentication (Platform endpoint).
    #[serde(rename = "api_key")]
    ApiKey {
        /// API key.
        api_key: String,
    },
}

/// `OpenAI` API settings (optional overrides).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenAIApiSettings {
    /// Base URL override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    /// Token URL for OAuth refresh.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_url: Option<String>,
    /// OAuth client ID.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_id: Option<String>,
    /// Default reasoning effort.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_reasoning_effort: Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────────

/// `OpenAI` provider configuration.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenAIConfig {
    /// Model ID.
    pub model: String,
    /// Authentication.
    pub auth: OpenAIAuth,
    /// Max output tokens override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u32>,
    /// Temperature override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f64>,
    /// Base URL override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    /// Reasoning effort override.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_effort: Option<String>,
    /// Provider-specific settings.
    #[serde(default)]
    pub provider_settings: OpenAIApiSettings,
}

// ─────────────────────────────────────────────────────────────────────────────
// Reasoning
// ─────────────────────────────────────────────────────────────────────────────

/// Re-export from `crate::provider` — the canonical definition lives at the shared boundary.
pub use crate::provider::ReasoningEffort;

// ─────────────────────────────────────────────────────────────────────────────
// Model Registry
// ─────────────────────────────────────────────────────────────────────────────

/// Information about an `OpenAI` model.
#[derive(Clone, Debug)]
pub struct OpenAIModelInfo {
    /// Display name.
    pub name: &'static str,
    /// Short name.
    pub short_name: &'static str,
    /// Model family (e.g., "GPT-5.3").
    pub family: &'static str,
    /// Model tier.
    pub tier: &'static str,
    /// Which API endpoint this model uses.
    pub api_endpoint: ApiEndpoint,
    /// Context window size in tokens.
    pub context_window: u64,
    /// Maximum output tokens.
    pub max_output: u64,
    /// Whether the model supports tool use.
    pub supports_tools: bool,
    /// Whether the model supports image inputs.
    pub supports_images: bool,
    /// Whether the model supports reasoning.
    pub supports_reasoning: bool,
    /// Whether the model supports tool search (dynamic tool loading).
    pub supports_tool_search: bool,
    /// Whether the model supports computer use.
    pub supports_computer_use: bool,
    /// Supported reasoning effort levels.
    pub reasoning_levels: &'static [&'static str],
    /// Default reasoning effort level.
    pub default_reasoning_level: &'static str,
    /// Input cost per million tokens (USD).
    pub input_cost_per_million: f64,
    /// Output cost per million tokens (USD).
    pub output_cost_per_million: f64,
    /// Cache read cost per million tokens (USD).
    pub cache_read_cost_per_million: f64,
}

/// Static model registry.
#[allow(unused_results)]
pub static OPENAI_MODELS: LazyLock<HashMap<&'static str, OpenAIModelInfo>> = LazyLock::new(|| {
    let mut m = HashMap::new();

    m.insert(
        "gpt-5.4",
        OpenAIModelInfo {
            name: "GPT-5.4",
            short_name: "GPT-5.4",
            family: "GPT-5.4",
            tier: "flagship",
            api_endpoint: ApiEndpoint::Platform,
            context_window: 1_000_000,
            max_output: 128_000,
            supports_tools: true,
            supports_images: true,
            supports_reasoning: true,
            supports_tool_search: true,
            supports_computer_use: true,
            reasoning_levels: &["none", "low", "medium", "high", "xhigh"],
            default_reasoning_level: "medium",
            input_cost_per_million: 2.0,
            output_cost_per_million: 16.0,
            cache_read_cost_per_million: 0.2,
        },
    );

    m.insert(
        "gpt-5.4-pro",
        OpenAIModelInfo {
            name: "GPT-5.4 Pro",
            short_name: "GPT-5.4 Pro",
            family: "GPT-5.4",
            tier: "flagship",
            api_endpoint: ApiEndpoint::Platform,
            context_window: 1_000_000,
            max_output: 128_000,
            supports_tools: true,
            supports_images: true,
            supports_reasoning: true,
            supports_tool_search: true,
            supports_computer_use: true,
            reasoning_levels: &["none", "low", "medium", "high", "xhigh"],
            default_reasoning_level: "high",
            input_cost_per_million: 4.0,
            output_cost_per_million: 32.0,
            cache_read_cost_per_million: 0.4,
        },
    );

    m.insert(
        "gpt-5.3-codex",
        OpenAIModelInfo {
            name: "GPT-5.3 Codex",
            short_name: "GPT-5.3",
            family: "GPT-5.3",
            tier: "flagship",
            api_endpoint: ApiEndpoint::Codex,
            context_window: 400_000,
            max_output: 128_000,
            supports_tools: true,
            supports_images: true,
            supports_reasoning: true,
            supports_tool_search: false,
            supports_computer_use: false,
            reasoning_levels: &["low", "medium", "high", "xhigh"],
            default_reasoning_level: "medium",
            input_cost_per_million: 1.75,
            output_cost_per_million: 14.0,
            cache_read_cost_per_million: 0.175,
        },
    );

    m.insert(
        "gpt-5.3-codex-spark",
        OpenAIModelInfo {
            name: "GPT-5.3 Codex Spark",
            short_name: "GPT-5.3 Spark",
            family: "GPT-5.3",
            tier: "standard",
            api_endpoint: ApiEndpoint::Codex,
            context_window: 128_000,
            max_output: 32_000,
            supports_tools: true,
            supports_images: false,
            supports_reasoning: true,
            supports_tool_search: false,
            supports_computer_use: false,
            reasoning_levels: &["low", "medium", "high"],
            default_reasoning_level: "low",
            input_cost_per_million: 1.75,
            output_cost_per_million: 14.0,
            cache_read_cost_per_million: 0.175,
        },
    );

    m.insert(
        "gpt-5.2-codex",
        OpenAIModelInfo {
            name: "GPT-5.2 Codex",
            short_name: "GPT-5.2",
            family: "GPT-5.2",
            tier: "flagship",
            api_endpoint: ApiEndpoint::Codex,
            context_window: 400_000,
            max_output: 128_000,
            supports_tools: true,
            supports_images: true,
            supports_reasoning: true,
            supports_tool_search: false,
            supports_computer_use: false,
            reasoning_levels: &["low", "medium", "high", "xhigh"],
            default_reasoning_level: "medium",
            input_cost_per_million: 1.75,
            output_cost_per_million: 14.0,
            cache_read_cost_per_million: 0.175,
        },
    );

    m.insert(
        "gpt-5.1-codex-max",
        OpenAIModelInfo {
            name: "GPT-5.1 Codex Max",
            short_name: "GPT-5.1 Max",
            family: "GPT-5.1",
            tier: "flagship",
            api_endpoint: ApiEndpoint::Codex,
            context_window: 400_000,
            max_output: 128_000,
            supports_tools: true,
            supports_images: true,
            supports_reasoning: true,
            supports_tool_search: false,
            supports_computer_use: false,
            reasoning_levels: &["low", "medium", "high", "xhigh"],
            default_reasoning_level: "high",
            input_cost_per_million: 1.25,
            output_cost_per_million: 10.0,
            cache_read_cost_per_million: 0.125,
        },
    );

    m.insert(
        "gpt-5.1-codex-mini",
        OpenAIModelInfo {
            name: "GPT-5.1 Codex Mini",
            short_name: "GPT-5.1 Mini",
            family: "GPT-5.1",
            tier: "standard",
            api_endpoint: ApiEndpoint::Codex,
            context_window: 400_000,
            max_output: 128_000,
            supports_tools: true,
            supports_images: true,
            supports_reasoning: true,
            supports_tool_search: false,
            supports_computer_use: false,
            reasoning_levels: &["low", "medium", "high"],
            default_reasoning_level: "low",
            input_cost_per_million: 0.25,
            output_cost_per_million: 2.0,
            cache_read_cost_per_million: 0.025,
        },
    );

    m
});

/// Look up model info by ID.
#[must_use]
pub fn get_openai_model(model_id: &str) -> Option<&'static OpenAIModelInfo> {
    OPENAI_MODELS.get(model_id)
}

/// Get all model IDs.
#[must_use]
pub fn all_openai_model_ids() -> Vec<&'static str> {
    OPENAI_MODELS.keys().copied().collect()
}

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
    /// Function call (tool use by assistant).
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
    /// Tool search sentinel — enables the model to dynamically discover tools.
    #[serde(rename = "tool_search")]
    ToolSearch {},
    /// Computer use tool (stub — full implementation deferred).
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
    /// Tool definitions (functions, tool search, computer use).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tools: Option<Vec<ResponsesToolEntry>>,
    /// Max output tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_output_tokens: Option<u32>,
    /// Reasoning configuration.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning: Option<ReasoningConfig>,
}

/// Reasoning configuration for the Responses API.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ReasoningConfig {
    /// Effort level.
    pub effort: String,
    /// Summary format (always "detailed").
    pub summary: String,
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
    /// Output tokens.
    #[serde(default)]
    pub output_tokens: u64,
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
    /// New output item (tool call or reasoning started).
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
    /// Tool search call started (hosted tool search).
    #[serde(rename = "response.tool_search_call.searching")]
    ToolSearchCallSearching,
    /// Tool search call completed (hosted tool search).
    #[serde(rename = "response.tool_search_call.completed")]
    ToolSearchCallCompleted,
    /// Computer call output (stub).
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
    /// Function call (tool use by assistant).
    FunctionCall,
    /// Message content.
    Message,
    /// Reasoning/thinking.
    Reasoning,
    /// Tool search call (hosted tool discovery).
    ToolSearchCall,
    /// Tool search output (hosted tool discovery result).
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn assert_float_eq(actual: f64, expected: f64) {
        assert!(
            (actual - expected).abs() < f64::EPSILON,
            "expected {expected}, got {actual}"
        );
    }

    // ── Model registry ─────────────────────────────────────────────────

    #[test]
    fn default_model_exists() {
        assert!(get_openai_model(DEFAULT_MODEL).is_some());
    }

    #[test]
    fn model_gpt_54() {
        let m = get_openai_model("gpt-5.4").unwrap();
        assert_eq!(m.context_window, 1_000_000);
        assert_eq!(m.max_output, 128_000);
        assert!(m.supports_reasoning);
        assert!(m.supports_tools);
        assert!(m.supports_tool_search);
        assert!(m.supports_computer_use);
        assert_eq!(
            m.reasoning_levels,
            &["none", "low", "medium", "high", "xhigh"]
        );
        assert_eq!(m.default_reasoning_level, "medium");
    }

    #[test]
    fn model_gpt_54_pro() {
        let m = get_openai_model("gpt-5.4-pro").unwrap();
        assert_eq!(m.context_window, 1_000_000);
        assert_eq!(m.max_output, 128_000);
        assert!(m.supports_tool_search);
        assert!(m.supports_computer_use);
        assert_eq!(m.default_reasoning_level, "high");
        assert_float_eq(m.input_cost_per_million, 4.0);
        assert_float_eq(m.output_cost_per_million, 32.0);
    }

    #[test]
    fn model_gpt_53_no_tool_search() {
        let m = get_openai_model("gpt-5.3-codex").unwrap();
        assert!(!m.supports_tool_search);
        assert!(!m.supports_computer_use);
    }

    #[test]
    fn model_gpt_53_codex() {
        let m = get_openai_model("gpt-5.3-codex").unwrap();
        assert_eq!(m.context_window, 400_000);
        assert_eq!(m.max_output, 128_000);
        assert!(m.supports_reasoning);
        assert!(m.supports_tools);
        assert_eq!(m.default_reasoning_level, "medium");
    }

    #[test]
    fn model_gpt_51_codex_mini() {
        let m = get_openai_model("gpt-5.1-codex-mini").unwrap();
        assert_eq!(m.tier, "standard");
        assert_eq!(m.context_window, 400_000);
        assert_eq!(m.max_output, 128_000);
        assert_eq!(m.reasoning_levels, &["low", "medium", "high"]);
        assert_eq!(m.default_reasoning_level, "low");
        assert_float_eq(m.input_cost_per_million, 0.25);
        assert_float_eq(m.output_cost_per_million, 2.0);
        assert_float_eq(m.cache_read_cost_per_million, 0.025);
    }

    #[test]
    fn model_gpt_53_codex_spark() {
        let m = get_openai_model("gpt-5.3-codex-spark").unwrap();
        assert_eq!(m.context_window, 128_000);
        assert_eq!(m.max_output, 32_000);
        assert_eq!(m.tier, "standard");
        assert!(m.supports_reasoning);
        assert!(m.supports_tools);
        assert_eq!(m.reasoning_levels, &["low", "medium", "high"]);
        assert_eq!(m.default_reasoning_level, "low");
        assert_float_eq(m.input_cost_per_million, 1.75);
        assert_float_eq(m.output_cost_per_million, 14.0);
        assert_float_eq(m.cache_read_cost_per_million, 0.175);
    }

    #[test]
    fn model_gpt_52_codex_pricing() {
        let m = get_openai_model("gpt-5.2-codex").unwrap();
        assert_float_eq(m.input_cost_per_million, 1.75);
        assert_float_eq(m.output_cost_per_million, 14.0);
        assert_float_eq(m.cache_read_cost_per_million, 0.175);
    }

    #[test]
    fn model_gpt_51_codex_max_pricing() {
        let m = get_openai_model("gpt-5.1-codex-max").unwrap();
        assert_float_eq(m.input_cost_per_million, 1.25);
        assert_float_eq(m.output_cost_per_million, 10.0);
        assert_float_eq(m.cache_read_cost_per_million, 0.125);
    }

    #[test]
    fn model_unknown_returns_none() {
        assert!(get_openai_model("gpt-99").is_none());
    }

    #[test]
    fn all_model_ids_contains_expected() {
        let ids = all_openai_model_ids();
        assert!(ids.contains(&"gpt-5.3-codex"));
        assert!(ids.contains(&"gpt-5.2-codex"));
        assert!(ids.contains(&"gpt-5.1-codex-max"));
        assert!(ids.contains(&"gpt-5.1-codex-mini"));
    }

    // ── Reasoning effort ───────────────────────────────────────────────

    #[test]
    fn reasoning_effort_serde_roundtrip() {
        let effort = ReasoningEffort::High;
        let json = serde_json::to_string(&effort).unwrap();
        assert_eq!(json, r#""high""#);
        let back: ReasoningEffort = serde_json::from_str(&json).unwrap();
        assert_eq!(back, ReasoningEffort::High);
    }

    #[test]
    fn reasoning_effort_all_variants() {
        for (variant, expected) in [
            (ReasoningEffort::None, "none"),
            (ReasoningEffort::Low, "low"),
            (ReasoningEffort::Medium, "medium"),
            (ReasoningEffort::High, "high"),
            (ReasoningEffort::Xhigh, "xhigh"),
            (ReasoningEffort::Max, "max"),
        ] {
            assert_eq!(variant.as_str(), expected);
            assert_eq!(variant.to_string(), expected);
        }
    }

    // ── ApiEndpoint ────────────────────────────────────────────────────

    #[test]
    fn api_endpoint_serde_roundtrip() {
        let codex = ApiEndpoint::Codex;
        let json = serde_json::to_string(&codex).unwrap();
        assert_eq!(json, r#""codex""#);
        let back: ApiEndpoint = serde_json::from_str(&json).unwrap();
        assert_eq!(back, ApiEndpoint::Codex);

        let platform = ApiEndpoint::Platform;
        let json = serde_json::to_string(&platform).unwrap();
        assert_eq!(json, r#""platform""#);
        let back: ApiEndpoint = serde_json::from_str(&json).unwrap();
        assert_eq!(back, ApiEndpoint::Platform);
    }

    #[test]
    fn api_endpoint_default_is_codex() {
        assert_eq!(ApiEndpoint::default(), ApiEndpoint::Codex);
    }

    #[test]
    fn api_endpoint_path() {
        assert_eq!(ApiEndpoint::Codex.path(), "/codex/responses");
        assert_eq!(ApiEndpoint::Platform.path(), "/v1/responses");
    }

    #[test]
    fn api_endpoint_default_base_url() {
        assert_eq!(ApiEndpoint::Codex.default_base_url(), DEFAULT_BASE_URL);
        assert_eq!(
            ApiEndpoint::Platform.default_base_url(),
            DEFAULT_PLATFORM_BASE_URL
        );
    }

    #[test]
    fn gpt_54_uses_platform_endpoint() {
        let m = get_openai_model("gpt-5.4").unwrap();
        assert_eq!(m.api_endpoint, ApiEndpoint::Platform);
    }

    #[test]
    fn gpt_54_pro_uses_platform_endpoint() {
        let m = get_openai_model("gpt-5.4-pro").unwrap();
        assert_eq!(m.api_endpoint, ApiEndpoint::Platform);
    }

    #[test]
    fn codex_models_use_codex_endpoint() {
        for id in &[
            "gpt-5.3-codex",
            "gpt-5.3-codex-spark",
            "gpt-5.2-codex",
            "gpt-5.1-codex-max",
            "gpt-5.1-codex-mini",
        ] {
            let m = get_openai_model(id).unwrap();
            assert_eq!(
                m.api_endpoint,
                ApiEndpoint::Codex,
                "expected Codex for {id}"
            );
        }
    }

    // ── Auth ───────────────────────────────────────────────────────────

    #[test]
    fn auth_oauth_serde() {
        let auth = OpenAIAuth::OAuth {
            tokens: crate::auth::OAuthTokens {
                access_token: "at".into(),
                refresh_token: "rt".into(),
                expires_at: 99999,
            },
        };
        let json = serde_json::to_value(&auth).unwrap();
        assert_eq!(json["type"], "oauth");
        assert_eq!(json["tokens"]["accessToken"], "at");
    }

    #[test]
    fn auth_api_key_serde() {
        let auth = OpenAIAuth::ApiKey {
            api_key: "sk-test-123".into(),
        };
        let json = serde_json::to_value(&auth).unwrap();
        assert_eq!(json["type"], "api_key");
        assert_eq!(json["api_key"], "sk-test-123");

        let back: OpenAIAuth = serde_json::from_value(json).unwrap();
        assert!(matches!(back, OpenAIAuth::ApiKey { api_key } if api_key == "sk-test-123"));
    }

    // ── Config ─────────────────────────────────────────────────────────

    #[test]
    fn config_serde() {
        let config = OpenAIConfig {
            model: "gpt-5.3-codex".into(),
            auth: OpenAIAuth::OAuth {
                tokens: crate::auth::OAuthTokens {
                    access_token: "at".into(),
                    refresh_token: "rt".into(),
                    expires_at: 99999,
                },
            },
            max_tokens: Some(4096),
            temperature: None,
            base_url: None,
            reasoning_effort: Some("high".into()),
            provider_settings: OpenAIApiSettings::default(),
        };
        let json = serde_json::to_value(&config).unwrap();
        assert_eq!(json["model"], "gpt-5.3-codex");
        assert_eq!(json["maxTokens"], 4096);
        assert_eq!(json["reasoningEffort"], "high");
    }

    // ── Responses API types ────────────────────────────────────────────

    #[test]
    fn responses_input_text_serde() {
        let item = ResponsesInputItem::InputText {
            text: "hello".into(),
        };
        let json = serde_json::to_value(&item).unwrap();
        assert_eq!(json["type"], "input_text");
        assert_eq!(json["text"], "hello");
    }

    #[test]
    fn responses_input_message_serde() {
        let item = ResponsesInputItem::Message {
            role: "user".into(),
            content: vec![MessageContent::InputText {
                text: "hello".into(),
            }],
            id: None,
        };
        let json = serde_json::to_value(&item).unwrap();
        assert_eq!(json["type"], "message");
        assert_eq!(json["role"], "user");
        assert_eq!(json["content"][0]["type"], "input_text");
    }

    #[test]
    fn responses_function_call_serde() {
        let item = ResponsesInputItem::FunctionCall {
            id: None,
            call_id: "call_abc".into(),
            name: "bash".into(),
            arguments: r#"{"cmd":"ls"}"#.into(),
        };
        let json = serde_json::to_value(&item).unwrap();
        assert_eq!(json["type"], "function_call");
        assert_eq!(json["call_id"], "call_abc");
        assert_eq!(json["name"], "bash");
    }

    #[test]
    fn responses_function_call_output_serde() {
        let item = ResponsesInputItem::FunctionCallOutput {
            call_id: "call_abc".into(),
            output: "file.txt".into(),
        };
        let json = serde_json::to_value(&item).unwrap();
        assert_eq!(json["type"], "function_call_output");
        assert_eq!(json["call_id"], "call_abc");
        assert_eq!(json["output"], "file.txt");
    }

    // ── ResponsesToolEntry ───────────────────────────────────────────

    #[test]
    fn tool_entry_function_serde() {
        let entry = ResponsesToolEntry::Function {
            name: "bash".into(),
            description: "Run commands".into(),
            parameters: json!({"type": "object"}),
            defer_loading: None,
        };
        let json = serde_json::to_value(&entry).unwrap();
        assert_eq!(json["type"], "function");
        assert_eq!(json["name"], "bash");
        assert!(json.get("defer_loading").is_none());

        let back: ResponsesToolEntry = serde_json::from_value(json).unwrap();
        assert!(matches!(back, ResponsesToolEntry::Function { .. }));
    }

    #[test]
    fn tool_entry_function_with_defer_loading() {
        let entry = ResponsesToolEntry::Function {
            name: "read_file".into(),
            description: "Read a file".into(),
            parameters: json!({"type": "object"}),
            defer_loading: Some(true),
        };
        let json = serde_json::to_value(&entry).unwrap();
        assert_eq!(json["defer_loading"], true);
    }

    #[test]
    fn tool_entry_tool_search_serde() {
        let entry = ResponsesToolEntry::ToolSearch {};
        let json = serde_json::to_value(&entry).unwrap();
        assert_eq!(json["type"], "tool_search");

        let back: ResponsesToolEntry = serde_json::from_value(json).unwrap();
        assert!(matches!(back, ResponsesToolEntry::ToolSearch {}));
    }

    #[test]
    fn tool_entry_computer_serde() {
        let entry = ResponsesToolEntry::Computer {
            viewport_width: Some(1280),
            viewport_height: Some(720),
        };
        let json = serde_json::to_value(&entry).unwrap();
        assert_eq!(json["type"], "computer");
        assert_eq!(json["viewport_width"], 1280);

        let back: ResponsesToolEntry = serde_json::from_value(json).unwrap();
        assert!(matches!(back, ResponsesToolEntry::Computer { .. }));
    }

    #[test]
    fn tool_entry_computer_minimal_serde() {
        let entry = ResponsesToolEntry::Computer {
            viewport_width: None,
            viewport_height: None,
        };
        let json = serde_json::to_value(&entry).unwrap();
        assert_eq!(json["type"], "computer");
        assert!(json.get("viewport_width").is_none());
    }

    #[test]
    fn tool_entry_serde_roundtrip_all_variants() {
        let entries = vec![
            ResponsesToolEntry::Function {
                name: "bash".into(),
                description: "Run".into(),
                parameters: json!({}),
                defer_loading: Some(true),
            },
            ResponsesToolEntry::ToolSearch {},
            ResponsesToolEntry::Computer {
                viewport_width: Some(1024),
                viewport_height: Some(768),
            },
        ];
        let json = serde_json::to_string(&entries).unwrap();
        let back: Vec<ResponsesToolEntry> = serde_json::from_str(&json).unwrap();
        assert_eq!(back.len(), 3);
        assert!(matches!(&back[0], ResponsesToolEntry::Function { .. }));
        assert!(matches!(&back[1], ResponsesToolEntry::ToolSearch {}));
        assert!(matches!(&back[2], ResponsesToolEntry::Computer { .. }));
    }

    // ── SSE event types for tool search ──────────────────────────────

    #[test]
    fn sse_tool_search_event_deserializes() {
        let json = json!({ "type": "response.tool_search_call.searching" });
        let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
        assert_eq!(event.event_type, SseEventType::ToolSearchCallSearching);
    }

    #[test]
    fn sse_tool_search_completed_deserializes() {
        let json = json!({ "type": "response.tool_search_call.completed" });
        let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
        assert_eq!(event.event_type, SseEventType::ToolSearchCallCompleted);
    }

    #[test]
    fn output_item_type_tool_search_call() {
        let json = json!({ "type": "tool_search_call" });
        let item: ResponsesOutputItem = serde_json::from_value(json).unwrap();
        assert_eq!(item.item_type, OutputItemType::ToolSearchCall);
    }

    #[test]
    fn output_item_type_computer_call() {
        let json = json!({ "type": "computer_call" });
        let item: ResponsesOutputItem = serde_json::from_value(json).unwrap();
        assert_eq!(item.item_type, OutputItemType::ComputerCall);
    }

    #[test]
    fn responses_request_serde() {
        let req = ResponsesRequest {
            model: "gpt-5.3-codex".into(),
            input: vec![ResponsesInputItem::InputText {
                text: "hello".into(),
            }],
            instructions: Some("Be helpful".into()),
            stream: true,
            store: false,
            temperature: None,
            tools: None,
            max_output_tokens: Some(16384),
            reasoning: Some(ReasoningConfig {
                effort: "medium".into(),
                summary: "detailed".into(),
            }),
        };
        let json = serde_json::to_value(&req).unwrap();
        assert_eq!(json["model"], "gpt-5.3-codex");
        assert!(json["stream"].as_bool().unwrap());
        assert!(!json["store"].as_bool().unwrap());
        assert_eq!(json["reasoning"]["effort"], "medium");
        assert_eq!(json["reasoning"]["summary"], "detailed");
    }

    // ── SSE event types ────────────────────────────────────────────────

    #[test]
    fn sse_text_delta() {
        let json = json!({
            "type": "response.output_text.delta",
            "delta": "Hello ",
            "content_index": 0,
        });
        let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
        assert_eq!(event.event_type, SseEventType::OutputTextDelta);
        assert_eq!(event.delta.as_deref(), Some("Hello "));
        assert_eq!(event.content_index, Some(0));
    }

    #[test]
    fn sse_output_item_added_function_call() {
        let json = json!({
            "type": "response.output_item.added",
            "item": {
                "type": "function_call",
                "call_id": "call_abc",
                "name": "bash",
            },
        });
        let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
        assert_eq!(event.event_type, SseEventType::OutputItemAdded);
        let item = event.item.unwrap();
        assert_eq!(item.item_type, OutputItemType::FunctionCall);
        assert_eq!(item.call_id.as_deref(), Some("call_abc"));
        assert_eq!(item.name.as_deref(), Some("bash"));
    }

    #[test]
    fn sse_output_item_added_reasoning() {
        let json = json!({
            "type": "response.output_item.added",
            "item": { "type": "reasoning" },
        });
        let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
        let item = event.item.unwrap();
        assert_eq!(item.item_type, OutputItemType::Reasoning);
    }

    #[test]
    fn sse_reasoning_summary_delta() {
        let json = json!({
            "type": "response.reasoning_summary_text.delta",
            "delta": "Thinking about...",
            "summary_index": 0,
        });
        let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
        assert_eq!(event.event_type, SseEventType::ReasoningSummaryTextDelta);
        assert_eq!(event.delta.as_deref(), Some("Thinking about..."));
    }

    #[test]
    fn sse_function_call_args_delta() {
        let json = json!({
            "type": "response.function_call_arguments.delta",
            "call_id": "call_abc",
            "delta": r#"{"cmd":"#,
        });
        let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
        assert_eq!(event.event_type, SseEventType::FunctionCallArgsDelta);
        assert_eq!(event.call_id.as_deref(), Some("call_abc"));
    }

    #[test]
    fn sse_completed() {
        let json = json!({
            "type": "response.completed",
            "response": {
                "id": "resp_123",
                "output": [],
                "usage": { "input_tokens": 100, "output_tokens": 50 },
            },
        });
        let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
        assert_eq!(event.event_type, SseEventType::Completed);
        let resp = event.response.unwrap();
        assert_eq!(resp.id.as_deref(), Some("resp_123"));
        let usage = resp.usage.unwrap();
        assert_eq!(usage.input_tokens, 100);
        assert_eq!(usage.output_tokens, 50);
    }

    #[test]
    fn sse_unknown_event_type_deserializes() {
        let json = json!({
            "type": "response.new_feature.delta",
        });
        let event: ResponsesSseEvent = serde_json::from_value(json).unwrap();
        assert_eq!(event.event_type, SseEventType::Unknown);
    }

    #[test]
    fn output_item_type_unknown_deserializes() {
        let json = json!({
            "type": "new_item_type",
        });
        let item: ResponsesOutputItem = serde_json::from_value(json).unwrap();
        assert_eq!(item.item_type, OutputItemType::Unknown);
    }

    #[test]
    fn message_content_input_text() {
        let mc = MessageContent::InputText {
            text: "hello".into(),
        };
        let json = serde_json::to_value(&mc).unwrap();
        assert_eq!(json["type"], "input_text");
    }

    #[test]
    fn message_content_input_image() {
        let mc = MessageContent::InputImage {
            image_url: "data:image/png;base64,abc".into(),
            detail: Some("auto".into()),
        };
        let json = serde_json::to_value(&mc).unwrap();
        assert_eq!(json["type"], "input_image");
        assert_eq!(json["detail"], "auto");
    }

    #[test]
    fn output_item_function_call() {
        let item = ResponsesOutputItem {
            item_type: OutputItemType::FunctionCall,
            call_id: Some("call_abc".into()),
            name: Some("bash".into()),
            arguments: Some(r#"{"cmd":"ls"}"#.into()),
            ..Default::default()
        };
        let json = serde_json::to_value(&item).unwrap();
        assert_eq!(json["type"], "function_call");
        assert_eq!(json["call_id"], "call_abc");
    }

    #[test]
    fn reasoning_config_serde() {
        let rc = ReasoningConfig {
            effort: "high".into(),
            summary: "detailed".into(),
        };
        let json = serde_json::to_value(&rc).unwrap();
        assert_eq!(json["effort"], "high");
        assert_eq!(json["summary"], "detailed");
        let back: ReasoningConfig = serde_json::from_value(json).unwrap();
        assert_eq!(back.effort, "high");
    }
}
