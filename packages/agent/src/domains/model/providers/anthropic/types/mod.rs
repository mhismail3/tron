//! Anthropic-specific types: configuration, model registry, and SSE event structures.
//!
//! The model registry uses flag-based capability detection — new models need
//! only one registry entry. The SSE event types mirror the raw JSON format
//! from the Anthropic Messages API streaming responses.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

mod catalog;
mod stream;

pub use catalog::{
    ClaudeModelInfo, DEFAULT_MODEL, all_claude_model_ids, all_claude_models_api_json,
    get_claude_model,
};
pub use stream::{
    AnthropicSseEvent, SseCacheCreation, SseContentBlock, SseDelta, SseError, SseMessage,
    SseMessageDelta, SseUsage, SseUsageDelta,
};

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
        tokens: crate::domains::auth::credentials::OAuthTokens,
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
    pub retry: Option<crate::domains::model::providers::StreamRetryConfig>,
    /// Provider settings (shared settings from settings).
    pub provider_settings: AnthropicProviderSettings,
}

/// Shared Anthropic provider settings from global configuration.
#[derive(Clone, Debug)]
pub struct AnthropicProviderSettings {
    /// OAuth system prompt prefix.
    pub system_prompt_prefix: Option<String>,
    /// Token expiry buffer in seconds.
    pub token_expiry_buffer_seconds: Option<u64>,
    /// Beta headers sent with OAuth requests (comma-separated).
    pub oauth_beta_headers: String,
}

impl Default for AnthropicProviderSettings {
    fn default() -> Self {
        Self {
            system_prompt_prefix: None,
            token_expiry_buffer_seconds: None,
            oauth_beta_headers: "oauth-2025-04-20,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14".to_string(),
        }
    }
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
// Anthropic API request types
// ─────────────────────────────────────────────────────────────────────────────

/// ModelCapability definition for Anthropic API.
#[derive(Clone, Debug, Serialize)]
pub struct AnthropicTool {
    /// Capability name.
    pub name: String,
    /// ModelCapability description.
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
    /// Provider-wire tools generated from Tron capability primitives.
    #[serde(rename = "tools")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capabilities: Option<Vec<AnthropicTool>>,
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
mod tests;
