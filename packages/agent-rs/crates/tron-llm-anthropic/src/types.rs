//! Anthropic-specific types: configuration, model registry, and SSE event structures.
//!
//! The model registry uses flag-based capability detection — new models need
//! only one registry entry. The SSE event types mirror the raw JSON format
//! from the Anthropic Messages API streaming responses.

use std::collections::HashMap;
use std::sync::LazyLock;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

// ─────────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────────

/// Authentication for the Anthropic provider.
#[derive(Clone, Debug)]
pub enum AnthropicAuth {
    /// API key authentication.
    ApiKey {
        /// Anthropic API key.
        api_key: String,
    },
    /// OAuth token authentication.
    OAuth {
        /// OAuth tokens.
        tokens: tron_auth::OAuthTokens,
        /// Account label (for multi-account).
        account_label: Option<String>,
    },
}

/// Configuration for the Anthropic provider.
#[derive(Clone, Debug)]
pub struct AnthropicConfig {
    /// Model ID (e.g., `"claude-opus-4-6"`).
    pub model: String,
    /// Authentication.
    pub auth: AnthropicAuth,
    /// Maximum output tokens.
    pub max_tokens: Option<u32>,
    /// Base URL override.
    pub base_url: Option<String>,
    /// Retry configuration override (None = use defaults).
    pub retry: Option<tron_llm::StreamRetryConfig>,
    /// Provider settings (shared settings from tron-settings).
    pub provider_settings: AnthropicProviderSettings,
}

/// Shared Anthropic provider settings from global configuration.
#[derive(Clone, Debug, Default)]
pub struct AnthropicProviderSettings {
    /// OAuth system prompt prefix.
    pub system_prompt_prefix: Option<String>,
    /// Token expiry buffer in seconds.
    pub token_expiry_buffer_seconds: Option<i64>,
}

/// System prompt block with optional cache control.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SystemPromptBlock {
    /// Block type (always `"text"`).
    #[serde(rename = "type")]
    pub block_type: String,
    /// Text content.
    pub text: String,
    /// Cache control directive.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_control: Option<CacheControl>,
}

/// Anthropic prompt cache control.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CacheControl {
    /// Cache type (always `"ephemeral"`).
    #[serde(rename = "type")]
    pub cache_type: String,
    /// TTL (optional — `"5m"` or `"1h"`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ttl: Option<String>,
}

impl SystemPromptBlock {
    /// Create a text block without cache control.
    #[must_use]
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            block_type: "text".into(),
            text: text.into(),
            cache_control: None,
        }
    }

    /// Create a text block with ephemeral cache control.
    #[must_use]
    pub fn text_cached(text: impl Into<String>, ttl: Option<&str>) -> Self {
        Self {
            block_type: "text".into(),
            text: text.into(),
            cache_control: Some(CacheControl {
                cache_type: "ephemeral".into(),
                ttl: ttl.map(String::from),
            }),
        }
    }
}

/// OAuth system prompt prefix required by Anthropic for OAuth connections.
pub const OAUTH_SYSTEM_PROMPT_PREFIX: &str =
    "You are Claude Code, Anthropic's official CLI for Claude.";

/// Default max output tokens.
pub const DEFAULT_MAX_OUTPUT_TOKENS: u32 = 16_000;

// ─────────────────────────────────────────────────────────────────────────────
// Model registry
// ─────────────────────────────────────────────────────────────────────────────

/// Information about a Claude model.
#[derive(Clone, Debug)]
#[allow(clippy::struct_excessive_bools)]
pub struct ClaudeModelInfo {
    /// Human-readable name.
    pub name: &'static str,
    /// Short name for compact display.
    pub short_name: &'static str,
    /// Model family.
    pub family: &'static str,
    /// Context window size in tokens.
    pub context_window: u64,
    /// Maximum output tokens.
    pub max_output: u32,
    /// Supports extended thinking.
    pub supports_thinking: bool,
    /// Requires thinking beta headers (pre-Opus 4.6).
    pub supports_thinking_beta_headers: bool,
    /// Supports adaptive thinking (Opus 4.6+).
    pub supports_adaptive_thinking: bool,
    /// Supports effort levels (Opus 4.6+).
    pub supports_effort: bool,
    /// Supports tool use.
    pub supports_tools: bool,
    /// Input cost per million tokens (USD).
    pub input_cost_per_million: f64,
    /// Output cost per million tokens (USD).
    pub output_cost_per_million: f64,
    /// Cache read cost per million tokens (USD).
    pub cache_read_cost_per_million: f64,
    /// Model description.
    pub description: &'static str,
    /// Whether this is the recommended model.
    pub recommended: bool,
    /// Whether this is a legacy model.
    pub legacy: bool,
}

/// Get model info for a Claude model ID.
#[must_use]
pub fn get_claude_model(model_id: &str) -> Option<&'static ClaudeModelInfo> {
    CLAUDE_MODELS.get(model_id)
}

/// All registered Claude model IDs.
#[must_use]
pub fn all_claude_model_ids() -> Vec<&'static str> {
    CLAUDE_MODELS.keys().copied().collect()
}

/// Claude model registry.
///
/// Model IDs match the canonical constants from `tron_llm::model_ids`.
static CLAUDE_MODELS: LazyLock<HashMap<&'static str, ClaudeModelInfo>> = LazyLock::new(|| {
    let mut m = HashMap::new();

    // Claude Opus 4.6 — latest and most capable
    let _ = m.insert("claude-opus-4-6", ClaudeModelInfo {
        name: "Claude Opus 4.6",
        short_name: "Opus 4.6",
        family: "Claude 4.6",
        context_window: 200_000,
        max_output: 128_000,
        supports_thinking: true,
        supports_thinking_beta_headers: false,
        supports_adaptive_thinking: true,
        supports_effort: true,
        supports_tools: true,
        input_cost_per_million: 15.0,
        output_cost_per_million: 75.0,
        cache_read_cost_per_million: 1.5,
        description: "Most capable Claude model — adaptive thinking, effort levels",
        recommended: true,
        legacy: false,
    });

    // Claude 4.5 family
    let _ = m.insert("claude-opus-4-5-20251101", ClaudeModelInfo {
        name: "Claude Opus 4.5",
        short_name: "Opus 4.5",
        family: "Claude 4.5",
        context_window: 200_000,
        max_output: 64_000,
        supports_thinking: true,
        supports_thinking_beta_headers: true,
        supports_adaptive_thinking: false,
        supports_effort: false,
        supports_tools: true,
        input_cost_per_million: 5.0,
        output_cost_per_million: 25.0,
        cache_read_cost_per_million: 0.5,
        description: "Opus-tier intelligence with extended thinking",
        recommended: false,
        legacy: false,
    });

    let _ = m.insert("claude-sonnet-4-5-20250929", ClaudeModelInfo {
        name: "Claude Sonnet 4.5",
        short_name: "Sonnet 4.5",
        family: "Claude 4.5",
        context_window: 200_000,
        max_output: 64_000,
        supports_thinking: true,
        supports_thinking_beta_headers: true,
        supports_adaptive_thinking: false,
        supports_effort: false,
        supports_tools: true,
        input_cost_per_million: 3.0,
        output_cost_per_million: 15.0,
        cache_read_cost_per_million: 0.3,
        description: "Best balance of speed and intelligence",
        recommended: false,
        legacy: false,
    });

    let _ = m.insert("claude-haiku-4-5-20251001", ClaudeModelInfo {
        name: "Claude Haiku 4.5",
        short_name: "Haiku 4.5",
        family: "Claude 4.5",
        context_window: 200_000,
        max_output: 64_000,
        supports_thinking: true,
        supports_thinking_beta_headers: true,
        supports_adaptive_thinking: false,
        supports_effort: false,
        supports_tools: true,
        input_cost_per_million: 0.8,
        output_cost_per_million: 4.0,
        cache_read_cost_per_million: 0.08,
        description: "Fast and affordable",
        recommended: false,
        legacy: false,
    });

    // Claude 4.1 (Legacy — August 2025)
    let _ = m.insert("claude-opus-4-1-20250805", ClaudeModelInfo {
        name: "Claude Opus 4.1",
        short_name: "Opus 4.1",
        family: "Claude 4.1",
        context_window: 200_000,
        max_output: 32_000,
        supports_thinking: true,
        supports_thinking_beta_headers: true,
        supports_adaptive_thinking: false,
        supports_effort: false,
        supports_tools: true,
        input_cost_per_million: 15.0,
        output_cost_per_million: 75.0,
        cache_read_cost_per_million: 1.5,
        description: "Previous Opus with enhanced agentic capabilities",
        recommended: false,
        legacy: true,
    });

    // Claude 4 (Legacy — May 2025)
    let _ = m.insert("claude-opus-4-20250514", ClaudeModelInfo {
        name: "Claude Opus 4",
        short_name: "Opus 4",
        family: "Claude 4",
        context_window: 200_000,
        max_output: 32_000,
        supports_thinking: true,
        supports_thinking_beta_headers: true,
        supports_adaptive_thinking: false,
        supports_effort: false,
        supports_tools: true,
        input_cost_per_million: 15.0,
        output_cost_per_million: 75.0,
        cache_read_cost_per_million: 1.5,
        description: "Previous generation Opus",
        recommended: false,
        legacy: true,
    });

    let _ = m.insert("claude-sonnet-4-20250514", ClaudeModelInfo {
        name: "Claude Sonnet 4",
        short_name: "Sonnet 4",
        family: "Claude 4",
        context_window: 200_000,
        max_output: 64_000,
        supports_thinking: true,
        supports_thinking_beta_headers: true,
        supports_adaptive_thinking: false,
        supports_effort: false,
        supports_tools: true,
        input_cost_per_million: 3.0,
        output_cost_per_million: 15.0,
        cache_read_cost_per_million: 0.3,
        description: "Fast and capable",
        recommended: false,
        legacy: true,
    });

    // Claude 3.7 (Legacy — February 2025)
    let _ = m.insert("claude-3-7-sonnet-20250219", ClaudeModelInfo {
        name: "Claude 3.7 Sonnet",
        short_name: "Sonnet 3.7",
        family: "Claude 3.7",
        context_window: 200_000,
        max_output: 64_000,
        supports_thinking: true,
        supports_thinking_beta_headers: true,
        supports_adaptive_thinking: false,
        supports_effort: false,
        supports_tools: true,
        input_cost_per_million: 3.0,
        output_cost_per_million: 15.0,
        cache_read_cost_per_million: 0.3,
        description: "Legacy Sonnet with extended thinking",
        recommended: false,
        legacy: true,
    });

    // Claude 3 (Legacy — oldest)
    let _ = m.insert("claude-3-haiku-20240307", ClaudeModelInfo {
        name: "Claude 3 Haiku",
        short_name: "Haiku 3",
        family: "Claude 3",
        context_window: 200_000,
        max_output: 4_096,
        supports_thinking: false,
        supports_thinking_beta_headers: false,
        supports_adaptive_thinking: false,
        supports_effort: false,
        supports_tools: true,
        input_cost_per_million: 0.25,
        output_cost_per_million: 1.25,
        cache_read_cost_per_million: 0.025,
        description: "Legacy — fast and affordable",
        recommended: false,
        legacy: true,
    });

    m
});

/// Default model ID.
pub const DEFAULT_MODEL: &str = "claude-opus-4-6";

// ─────────────────────────────────────────────────────────────────────────────
// Anthropic SSE event types (raw API format)
// ─────────────────────────────────────────────────────────────────────────────

/// Top-level Anthropic SSE event.
#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "type")]
pub enum AnthropicSseEvent {
    /// `message_start` — first event, contains usage info.
    #[serde(rename = "message_start")]
    MessageStart {
        /// The message object.
        message: SseMessage,
    },
    /// `content_block_start` — a new content block begins.
    #[serde(rename = "content_block_start")]
    ContentBlockStart {
        /// Block index.
        index: usize,
        /// The content block.
        content_block: SseContentBlock,
    },
    /// `content_block_delta` — incremental content.
    #[serde(rename = "content_block_delta")]
    ContentBlockDelta {
        /// Block index.
        index: usize,
        /// The delta.
        delta: SseDelta,
    },
    /// `content_block_stop` — block finished.
    #[serde(rename = "content_block_stop")]
    ContentBlockStop {
        /// Block index.
        index: usize,
    },
    /// `message_delta` — message-level updates (stop reason, usage).
    #[serde(rename = "message_delta")]
    MessageDelta {
        /// Delta fields.
        delta: SseMessageDelta,
        /// Usage update.
        #[serde(default)]
        usage: Option<SseUsageDelta>,
    },
    /// `message_stop` — stream complete.
    #[serde(rename = "message_stop")]
    MessageStop,

    /// `ping` — keepalive.
    #[serde(rename = "ping")]
    Ping,

    /// `error` — API error.
    #[serde(rename = "error")]
    Error {
        /// Error details.
        error: SseError,
    },
}

/// Message object in `message_start`.
#[derive(Clone, Debug, Deserialize)]
pub struct SseMessage {
    /// Message ID.
    pub id: Option<String>,
    /// Model used.
    pub model: Option<String>,
    /// Stop reason (null during streaming).
    pub stop_reason: Option<String>,
    /// Usage information.
    #[serde(default)]
    pub usage: SseUsage,
}

/// Token usage in `message_start`.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct SseUsage {
    /// Input tokens.
    #[serde(default)]
    pub input_tokens: u64,
    /// Output tokens.
    #[serde(default)]
    pub output_tokens: u64,
    /// Cache creation tokens.
    #[serde(default)]
    pub cache_creation_input_tokens: u64,
    /// Cache read tokens.
    #[serde(default)]
    pub cache_read_input_tokens: u64,
    /// Detailed cache creation breakdown.
    #[serde(default)]
    pub cache_creation: Option<SseCacheCreation>,
}

/// Cache creation breakdown by TTL.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct SseCacheCreation {
    /// 5-minute ephemeral cache tokens.
    #[serde(default)]
    pub ephemeral_5m_input_tokens: u64,
    /// 1-hour ephemeral cache tokens.
    #[serde(default)]
    pub ephemeral_1h_input_tokens: u64,
}

/// Content block in `content_block_start`.
#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "type")]
pub enum SseContentBlock {
    /// Text block.
    #[serde(rename = "text")]
    Text {
        /// Initial text (usually empty).
        #[serde(default)]
        text: String,
    },
    /// Thinking block.
    #[serde(rename = "thinking")]
    Thinking {
        /// Initial thinking text.
        #[serde(default)]
        thinking: String,
    },
    /// Tool use block.
    #[serde(rename = "tool_use")]
    ToolUse {
        /// Tool call ID.
        id: String,
        /// Tool name.
        name: String,
    },
}

/// Delta in `content_block_delta`.
#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "type")]
pub enum SseDelta {
    /// Text content delta.
    #[serde(rename = "text_delta")]
    TextDelta {
        /// Text fragment.
        text: String,
    },
    /// Thinking content delta.
    #[serde(rename = "thinking_delta")]
    ThinkingDelta {
        /// Thinking text fragment.
        thinking: String,
    },
    /// Signature delta.
    #[serde(rename = "signature_delta")]
    SignatureDelta {
        /// Signature fragment.
        signature: String,
    },
    /// Tool call arguments delta.
    #[serde(rename = "input_json_delta")]
    InputJsonDelta {
        /// Partial JSON string.
        partial_json: String,
    },
}

/// Message-level delta in `message_delta`.
#[derive(Clone, Debug, Deserialize)]
pub struct SseMessageDelta {
    /// Stop reason.
    pub stop_reason: Option<String>,
}

/// Usage delta in `message_delta`.
#[derive(Clone, Debug, Deserialize)]
pub struct SseUsageDelta {
    /// Output tokens.
    #[serde(default)]
    pub output_tokens: u64,
}

/// Error in SSE `error` event.
#[derive(Clone, Debug, Deserialize)]
pub struct SseError {
    /// Error type.
    #[serde(rename = "type")]
    pub error_type: String,
    /// Error message.
    pub message: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// Anthropic API request types
// ─────────────────────────────────────────────────────────────────────────────

/// Tool definition for Anthropic API.
#[derive(Clone, Debug, Serialize)]
pub struct AnthropicTool {
    /// Tool name.
    pub name: String,
    /// Tool description.
    pub description: String,
    /// JSON Schema for input parameters.
    pub input_schema: Value,
    /// Cache control.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_control: Option<CacheControl>,
}

/// Anthropic Messages API request body.
#[derive(Clone, Debug, Serialize)]
pub struct AnthropicRequest {
    /// Model ID.
    pub model: String,
    /// Maximum tokens to generate.
    pub max_tokens: u32,
    /// Messages.
    pub messages: Vec<AnthropicMessageParam>,
    /// System prompt (string or array of blocks).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system: Option<Value>,
    /// Available tools.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tools: Option<Vec<AnthropicTool>>,
    /// Stream mode.
    pub stream: bool,
    /// Thinking configuration.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thinking: Option<Value>,
    /// Output configuration (effort).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output_config: Option<Value>,
    /// Stop sequences.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stop_sequences: Option<Vec<String>>,
}

/// A message in the Anthropic Messages API format.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AnthropicMessageParam {
    /// Role: `"user"` or `"assistant"`.
    pub role: String,
    /// Content blocks.
    pub content: Vec<Value>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Anthropic API content block types (for building requests)
// ─────────────────────────────────────────────────────────────────────────────

/// Build a text content block.
#[must_use]
pub fn text_block(text: &str) -> Value {
    serde_json::json!({
        "type": "text",
        "text": text,
    })
}

/// Build an image content block (base64).
#[must_use]
pub fn image_block(data: &str, media_type: &str) -> Value {
    serde_json::json!({
        "type": "image",
        "source": {
            "type": "base64",
            "media_type": media_type,
            "data": data,
        },
    })
}

/// Build a document content block (base64).
#[must_use]
pub fn document_block(data: &str, media_type: &str) -> Value {
    serde_json::json!({
        "type": "document",
        "source": {
            "type": "base64",
            "media_type": media_type,
            "data": data,
        },
    })
}

/// Build a thinking content block.
#[must_use]
pub fn thinking_block(thinking: &str, signature: &str) -> Value {
    serde_json::json!({
        "type": "thinking",
        "thinking": thinking,
        "signature": signature,
    })
}

/// Build a `tool_use` content block.
#[must_use]
pub fn tool_use_block(id: &str, name: &str, input: &Map<String, Value>) -> Value {
    serde_json::json!({
        "type": "tool_use",
        "id": id,
        "name": name,
        "input": input,
    })
}

/// Build a `tool_result` content block.
#[must_use]
pub fn tool_result_block(tool_use_id: &str, content: &[Value], is_error: bool) -> Value {
    let mut block = serde_json::json!({
        "type": "tool_result",
        "tool_use_id": tool_use_id,
        "content": content,
    });
    if is_error {
        block["is_error"] = serde_json::json!(true);
    }
    block
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // -- Model registry --

    #[test]
    fn get_claude_model_opus_46() {
        let info = get_claude_model("claude-opus-4-6").unwrap();
        assert_eq!(info.name, "Claude Opus 4.6");
        assert_eq!(info.context_window, 200_000);
        assert_eq!(info.max_output, 128_000);
        assert!(info.supports_thinking);
        assert!(!info.supports_thinking_beta_headers);
        assert!(info.supports_adaptive_thinking);
        assert!(info.supports_effort);
        assert!(info.supports_tools);
        assert!(info.recommended);
        assert!(!info.legacy);
    }

    #[test]
    fn get_claude_model_opus_45() {
        let info = get_claude_model("claude-opus-4-5-20251101").unwrap();
        assert_eq!(info.short_name, "Opus 4.5");
        assert!(info.supports_thinking);
        assert!(info.supports_thinking_beta_headers);
        assert!(!info.supports_adaptive_thinking);
        assert!(!info.supports_effort);
        assert_eq!(info.max_output, 64_000);
    }

    #[test]
    fn get_claude_model_sonnet_45() {
        let info = get_claude_model("claude-sonnet-4-5-20250929").unwrap();
        assert_eq!(info.short_name, "Sonnet 4.5");
        assert!(info.supports_thinking);
        assert!(info.supports_thinking_beta_headers);
        assert!(!info.supports_adaptive_thinking);
        assert!(!info.supports_effort);
    }

    #[test]
    fn get_claude_model_opus_41_is_opus_not_sonnet() {
        let info = get_claude_model("claude-opus-4-1-20250805").unwrap();
        assert_eq!(info.name, "Claude Opus 4.1");
        assert_eq!(info.short_name, "Opus 4.1");
        assert_eq!(info.max_output, 32_000);
        assert_eq!(info.input_cost_per_million, 15.0);
        assert!(info.legacy);
    }

    #[test]
    fn get_claude_model_haiku_3_legacy() {
        let info = get_claude_model("claude-3-haiku-20240307").unwrap();
        assert_eq!(info.max_output, 4_096);
        assert!(!info.supports_thinking);
        assert!(info.legacy);
    }

    #[test]
    fn get_claude_model_unknown_returns_none() {
        assert!(get_claude_model("gpt-5").is_none());
    }

    #[test]
    fn all_claude_model_ids_contains_expected() {
        let ids = all_claude_model_ids();
        assert!(ids.contains(&"claude-opus-4-6"));
        assert!(ids.contains(&"claude-opus-4-5-20251101"));
        assert!(ids.contains(&"claude-sonnet-4-5-20250929"));
        assert!(ids.contains(&"claude-3-haiku-20240307"));
        assert_eq!(ids.len(), 9); // 9 models total
    }

    // -- SystemPromptBlock --

    #[test]
    fn system_prompt_block_text_no_cache() {
        let block = SystemPromptBlock::text("hello");
        let json = serde_json::to_value(&block).unwrap();
        assert_eq!(json["type"], "text");
        assert_eq!(json["text"], "hello");
        assert!(json.get("cache_control").is_none());
    }

    #[test]
    fn system_prompt_block_cached_5m() {
        let block = SystemPromptBlock::text_cached("hello", Some("5m"));
        let json = serde_json::to_value(&block).unwrap();
        assert_eq!(json["cache_control"]["type"], "ephemeral");
        assert_eq!(json["cache_control"]["ttl"], "5m");
    }

    #[test]
    fn system_prompt_block_cached_no_ttl() {
        let block = SystemPromptBlock::text_cached("hello", None);
        let json = serde_json::to_value(&block).unwrap();
        assert_eq!(json["cache_control"]["type"], "ephemeral");
        assert!(json["cache_control"].get("ttl").is_none());
    }

    // -- SSE event deserialization --

    #[test]
    fn sse_message_start() {
        let json = r#"{
            "type": "message_start",
            "message": {
                "id": "msg_01XaBC",
                "model": "claude-opus-4-6",
                "stop_reason": null,
                "usage": {
                    "input_tokens": 100,
                    "output_tokens": 0,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 20
                }
            }
        }"#;
        let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
        match event {
            AnthropicSseEvent::MessageStart { message } => {
                assert_eq!(message.id.as_deref(), Some("msg_01XaBC"));
                assert_eq!(message.usage.input_tokens, 100);
                assert_eq!(message.usage.cache_creation_input_tokens, 50);
                assert_eq!(message.usage.cache_read_input_tokens, 20);
            }
            _ => panic!("expected MessageStart"),
        }
    }

    #[test]
    fn sse_message_start_with_cache_creation_breakdown() {
        let json = r#"{
            "type": "message_start",
            "message": {
                "usage": {
                    "input_tokens": 100,
                    "output_tokens": 0,
                    "cache_creation_input_tokens": 80,
                    "cache_read_input_tokens": 20,
                    "cache_creation": {
                        "ephemeral_5m_input_tokens": 30,
                        "ephemeral_1h_input_tokens": 50
                    }
                }
            }
        }"#;
        let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
        match event {
            AnthropicSseEvent::MessageStart { message } => {
                let cc = message.usage.cache_creation.unwrap();
                assert_eq!(cc.ephemeral_5m_input_tokens, 30);
                assert_eq!(cc.ephemeral_1h_input_tokens, 50);
            }
            _ => panic!("expected MessageStart"),
        }
    }

    #[test]
    fn sse_content_block_start_text() {
        let json = r#"{
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "text", "text": ""}
        }"#;
        let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
        match event {
            AnthropicSseEvent::ContentBlockStart { index, content_block } => {
                assert_eq!(index, 0);
                assert!(matches!(content_block, SseContentBlock::Text { .. }));
            }
            _ => panic!("expected ContentBlockStart"),
        }
    }

    #[test]
    fn sse_content_block_start_thinking() {
        let json = r#"{
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "thinking", "thinking": ""}
        }"#;
        let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
        match event {
            AnthropicSseEvent::ContentBlockStart { content_block, .. } => {
                assert!(matches!(content_block, SseContentBlock::Thinking { .. }));
            }
            _ => panic!("expected ContentBlockStart"),
        }
    }

    #[test]
    fn sse_content_block_start_tool_use() {
        let json = r#"{
            "type": "content_block_start",
            "index": 1,
            "content_block": {"type": "tool_use", "id": "toolu_01abc", "name": "bash"}
        }"#;
        let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
        match event {
            AnthropicSseEvent::ContentBlockStart { content_block, .. } => {
                match content_block {
                    SseContentBlock::ToolUse { id, name } => {
                        assert_eq!(id, "toolu_01abc");
                        assert_eq!(name, "bash");
                    }
                    _ => panic!("expected ToolUse"),
                }
            }
            _ => panic!("expected ContentBlockStart"),
        }
    }

    #[test]
    fn sse_content_block_delta_text() {
        let json = r#"{
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "text_delta", "text": "Hello"}
        }"#;
        let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
        match event {
            AnthropicSseEvent::ContentBlockDelta { delta, .. } => {
                match delta {
                    SseDelta::TextDelta { text } => assert_eq!(text, "Hello"),
                    _ => panic!("expected TextDelta"),
                }
            }
            _ => panic!("expected ContentBlockDelta"),
        }
    }

    #[test]
    fn sse_content_block_delta_thinking() {
        let json = r#"{
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "thinking_delta", "thinking": "Let me consider"}
        }"#;
        let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
        match event {
            AnthropicSseEvent::ContentBlockDelta { delta, .. } => {
                match delta {
                    SseDelta::ThinkingDelta { thinking } => {
                        assert_eq!(thinking, "Let me consider");
                    }
                    _ => panic!("expected ThinkingDelta"),
                }
            }
            _ => panic!("expected ContentBlockDelta"),
        }
    }

    #[test]
    fn sse_content_block_delta_signature() {
        let json = r#"{
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "signature_delta", "signature": "sig123"}
        }"#;
        let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
        match event {
            AnthropicSseEvent::ContentBlockDelta { delta, .. } => {
                match delta {
                    SseDelta::SignatureDelta { signature } => {
                        assert_eq!(signature, "sig123");
                    }
                    _ => panic!("expected SignatureDelta"),
                }
            }
            _ => panic!("expected ContentBlockDelta"),
        }
    }

    #[test]
    fn sse_content_block_delta_input_json() {
        let json = r#"{
            "type": "content_block_delta",
            "index": 1,
            "delta": {"type": "input_json_delta", "partial_json": "{\"cmd\":\"ls\"}"}
        }"#;
        let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
        match event {
            AnthropicSseEvent::ContentBlockDelta { delta, .. } => {
                match delta {
                    SseDelta::InputJsonDelta { partial_json } => {
                        assert_eq!(partial_json, r#"{"cmd":"ls"}"#);
                    }
                    _ => panic!("expected InputJsonDelta"),
                }
            }
            _ => panic!("expected ContentBlockDelta"),
        }
    }

    #[test]
    fn sse_message_delta() {
        let json = r#"{
            "type": "message_delta",
            "delta": {"stop_reason": "end_turn"},
            "usage": {"output_tokens": 42}
        }"#;
        let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
        match event {
            AnthropicSseEvent::MessageDelta { delta, usage } => {
                assert_eq!(delta.stop_reason.as_deref(), Some("end_turn"));
                assert_eq!(usage.unwrap().output_tokens, 42);
            }
            _ => panic!("expected MessageDelta"),
        }
    }

    #[test]
    fn sse_message_stop() {
        let json = r#"{"type": "message_stop"}"#;
        let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
        assert!(matches!(event, AnthropicSseEvent::MessageStop));
    }

    #[test]
    fn sse_ping() {
        let json = r#"{"type": "ping"}"#;
        let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
        assert!(matches!(event, AnthropicSseEvent::Ping));
    }

    #[test]
    fn sse_error() {
        let json = r#"{
            "type": "error",
            "error": {"type": "overloaded_error", "message": "Server overloaded"}
        }"#;
        let event: AnthropicSseEvent = serde_json::from_str(json).unwrap();
        match event {
            AnthropicSseEvent::Error { error } => {
                assert_eq!(error.error_type, "overloaded_error");
                assert_eq!(error.message, "Server overloaded");
            }
            _ => panic!("expected Error"),
        }
    }

    // -- Request building helpers --

    #[test]
    fn text_block_builds_correct_json() {
        let block = text_block("hello");
        assert_eq!(block["type"], "text");
        assert_eq!(block["text"], "hello");
    }

    #[test]
    fn image_block_builds_correct_json() {
        let block = image_block("base64data", "image/png");
        assert_eq!(block["type"], "image");
        assert_eq!(block["source"]["type"], "base64");
        assert_eq!(block["source"]["media_type"], "image/png");
        assert_eq!(block["source"]["data"], "base64data");
    }

    #[test]
    fn document_block_builds_correct_json() {
        let block = document_block("pdfdata", "application/pdf");
        assert_eq!(block["type"], "document");
        assert_eq!(block["source"]["media_type"], "application/pdf");
    }

    #[test]
    fn thinking_block_builds_correct_json() {
        let block = thinking_block("deep thought", "sig123");
        assert_eq!(block["type"], "thinking");
        assert_eq!(block["thinking"], "deep thought");
        assert_eq!(block["signature"], "sig123");
    }

    #[test]
    fn tool_use_block_builds_correct_json() {
        let mut input = Map::new();
        let _ = input.insert("cmd".into(), serde_json::json!("ls"));
        let block = tool_use_block("toolu_01abc", "bash", &input);
        assert_eq!(block["type"], "tool_use");
        assert_eq!(block["id"], "toolu_01abc");
        assert_eq!(block["name"], "bash");
        assert_eq!(block["input"]["cmd"], "ls");
    }

    #[test]
    fn tool_result_block_success() {
        let content = vec![text_block("output")];
        let block = tool_result_block("toolu_01abc", &content, false);
        assert_eq!(block["type"], "tool_result");
        assert_eq!(block["tool_use_id"], "toolu_01abc");
        assert!(block.get("is_error").is_none());
    }

    #[test]
    fn tool_result_block_error() {
        let content = vec![text_block("error msg")];
        let block = tool_result_block("toolu_01abc", &content, true);
        assert_eq!(block["is_error"], true);
    }

    // -- AnthropicTool --

    #[test]
    fn anthropic_tool_serde() {
        let tool = AnthropicTool {
            name: "bash".into(),
            description: "Run commands".into(),
            input_schema: serde_json::json!({"type": "object"}),
            cache_control: None,
        };
        let json = serde_json::to_value(&tool).unwrap();
        assert_eq!(json["name"], "bash");
        assert!(json.get("cache_control").is_none());
    }

    #[test]
    fn anthropic_tool_with_cache_control() {
        let tool = AnthropicTool {
            name: "bash".into(),
            description: "Run commands".into(),
            input_schema: serde_json::json!({"type": "object"}),
            cache_control: Some(CacheControl {
                cache_type: "ephemeral".into(),
                ttl: Some("1h".into()),
            }),
        };
        let json = serde_json::to_value(&tool).unwrap();
        assert_eq!(json["cache_control"]["ttl"], "1h");
    }

    // -- Constants --

    #[test]
    fn oauth_system_prompt_prefix_value() {
        assert!(OAUTH_SYSTEM_PROMPT_PREFIX.contains("Claude Code"));
    }

    #[test]
    fn default_model_exists_in_registry() {
        assert!(get_claude_model(DEFAULT_MODEL).is_some());
    }
}
