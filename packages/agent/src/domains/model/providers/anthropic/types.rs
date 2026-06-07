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
        tokens: crate::domains::auth::provider_credentials::OAuthTokens,
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
    /// Supports capability invocation.
    pub supports_capabilities: bool,
    /// Supports image inputs.
    pub supports_images: bool,
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
    /// Whether this is a retired-generation model.
    pub retired_generation: bool,
    /// Model tier (e.g., "opus", "sonnet", "haiku").
    pub tier: &'static str,
    /// Display sort order within the provider (lower = higher priority).
    pub sort_order: u16,
    /// Release date (ISO-8601).
    pub release_date: &'static str,
    /// Whether this model is retired by the provider.
    pub is_retired: bool,
    /// Retirement date (ISO-8601), if retired.
    pub deprecation_date: Option<&'static str>,
    /// Supported reasoning/effort levels (e.g., `["low", "medium", "high", "max"]`).
    /// `None` means the model does not support reasoning levels.
    pub reasoning_levels: Option<&'static [&'static str]>,
    /// Default reasoning/effort level. `None` if reasoning not supported.
    pub default_reasoning_level: Option<&'static str>,
    /// Thinking display mode to send in `thinking.display`.
    /// `None` → omit the field (matches prior behavior for Opus 4.6 and below,
    /// where "summarized" was the API default). `Some("summarized")` → explicit
    /// opt-in (required on Opus 4.7+ to keep summarized thinking blocks visible,
    /// since their default is "omitted").
    pub thinking_display: Option<&'static str>,
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

impl ClaudeModelInfo {
    /// Serialize this model to JSON for the `model.list` API response.
    pub fn to_api_json(&self, id: &str) -> serde_json::Value {
        let mut obj = serde_json::json!({
            "id": id,
            "name": self.short_name,
            "provider": "anthropic",
            "providerDisplayName": "Anthropic",
            "providerSortOrder": 0,
            "contextWindow": self.context_window,
            "maxOutput": self.max_output,
            "supportsThinking": self.supports_thinking,
            "supportsImages": self.supports_images,
            "supportsDocuments": true,
            "inputCostPerMillion": self.input_cost_per_million,
            "outputCostPerMillion": self.output_cost_per_million,
            "tier": self.tier,
            "family": self.family,
            "description": self.description,
            "supportsReasoning": self.reasoning_levels.is_some(),
            "recommended": self.recommended,
            "isLegacy": self.retired_generation,
            "releaseDate": self.release_date,
            "sortOrder": self.sort_order,
        });
        let map = obj.as_object_mut().unwrap();
        if let Some(levels) = self.reasoning_levels {
            let _ = map.insert("reasoningLevels".into(), serde_json::json!(levels));
        }
        if let Some(default) = self.default_reasoning_level {
            let _ = map.insert("defaultReasoningLevel".into(), serde_json::json!(default));
        }
        if self.is_retired {
            let _ = map.insert("isDeprecated".into(), serde_json::json!(true));
        }
        if let Some(date) = self.deprecation_date {
            let _ = map.insert("deprecationDate".into(), serde_json::json!(date));
        }
        obj
    }
}

/// All Claude models serialized for the `model.list` API, sorted by `sort_order`.
pub fn all_claude_models_api_json() -> Vec<serde_json::Value> {
    let mut entries: Vec<_> = CLAUDE_MODELS.iter().collect();
    entries.sort_by_key(|(_, info)| info.sort_order);
    entries
        .into_iter()
        .map(|(id, info)| info.to_api_json(id))
        .collect()
}

/// Claude model registry.
///
/// Model IDs match the canonical constants from `crate::domains::model::providers::model_ids`.
static CLAUDE_MODELS: LazyLock<HashMap<&'static str, ClaudeModelInfo>> = LazyLock::new(|| {
    let mut m = HashMap::new();

    // Claude Opus 4.7 — released April 2026, most capable
    let _ = m.insert(
        "claude-opus-4-7",
        ClaudeModelInfo {
            name: "Claude Opus 4.7",
            short_name: "Opus 4.7",
            family: "Claude 4.7",
            context_window: 1_000_000,
            max_output: 128_000,
            supports_thinking: true,
            supports_thinking_beta_headers: false,
            supports_adaptive_thinking: true,
            supports_effort: true,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 5.0,
            output_cost_per_million: 25.0,
            cache_read_cost_per_million: 0.5,
            description: "Most capable Claude model — xhigh effort, high-res vision",
            recommended: true,
            retired_generation: false,
            tier: "opus",
            sort_order: 0,
            release_date: "2026-04-16",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: Some(&["low", "medium", "high", "xhigh", "max"]),
            default_reasoning_level: Some("xhigh"),
            thinking_display: Some("summarized"),
        },
    );

    // Claude Opus 4.6
    let _ = m.insert(
        "claude-opus-4-6",
        ClaudeModelInfo {
            name: "Claude Opus 4.6",
            short_name: "Opus 4.6",
            family: "Claude 4.6",
            context_window: 1_000_000,
            max_output: 128_000,
            supports_thinking: true,
            supports_thinking_beta_headers: false,
            supports_adaptive_thinking: true,
            supports_effort: true,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 5.0,
            output_cost_per_million: 25.0,
            cache_read_cost_per_million: 0.5,
            description: "Previous Opus — adaptive thinking, effort levels",
            recommended: false,
            retired_generation: false,
            tier: "opus",
            sort_order: 1,
            release_date: "2026-02-01",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: Some(&["low", "medium", "high", "max"]),
            default_reasoning_level: Some("high"),
            thinking_display: None,
        },
    );

    // Claude Sonnet 4.6
    let _ = m.insert(
        "claude-sonnet-4-6",
        ClaudeModelInfo {
            name: "Claude Sonnet 4.6",
            short_name: "Sonnet 4.6",
            family: "Claude 4.6",
            context_window: 1_000_000,
            max_output: 64_000,
            supports_thinking: true,
            supports_thinking_beta_headers: false,
            supports_adaptive_thinking: true,
            supports_effort: true,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 3.0,
            output_cost_per_million: 15.0,
            cache_read_cost_per_million: 0.3,
            description: "Best combination of speed and intelligence — adaptive thinking",
            recommended: true,
            retired_generation: false,
            tier: "sonnet",
            sort_order: 2,
            release_date: "2026-02-17",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: Some(&["low", "medium", "high", "max"]),
            default_reasoning_level: Some("medium"),
            thinking_display: None,
        },
    );

    // Claude 4.5 family
    let _ = m.insert(
        "claude-opus-4-5-20251101",
        ClaudeModelInfo {
            name: "Claude Opus 4.5",
            short_name: "Opus 4.5",
            family: "Claude 4.5",
            context_window: 200_000,
            max_output: 64_000,
            supports_thinking: true,
            supports_thinking_beta_headers: true,
            supports_adaptive_thinking: false,
            supports_effort: false,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 5.0,
            output_cost_per_million: 25.0,
            cache_read_cost_per_million: 0.5,
            description: "Opus-tier intelligence with extended thinking",
            recommended: false,
            retired_generation: false,
            tier: "opus",
            sort_order: 3,
            release_date: "2025-11-01",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: None,
            default_reasoning_level: None,
            thinking_display: None,
        },
    );

    let _ = m.insert(
        "claude-sonnet-4-5-20250929",
        ClaudeModelInfo {
            name: "Claude Sonnet 4.5",
            short_name: "Sonnet 4.5",
            family: "Claude 4.5",
            context_window: 200_000,
            max_output: 64_000,
            supports_thinking: true,
            supports_thinking_beta_headers: true,
            supports_adaptive_thinking: false,
            supports_effort: false,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 3.0,
            output_cost_per_million: 15.0,
            cache_read_cost_per_million: 0.3,
            description: "Best balance of speed and intelligence",
            recommended: false,
            retired_generation: true,
            tier: "sonnet",
            sort_order: 4,
            release_date: "2025-09-29",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: None,
            default_reasoning_level: None,
            thinking_display: None,
        },
    );

    let _ = m.insert(
        "claude-haiku-4-5-20251001",
        ClaudeModelInfo {
            name: "Claude Haiku 4.5",
            short_name: "Haiku 4.5",
            family: "Claude 4.5",
            context_window: 200_000,
            max_output: 64_000,
            supports_thinking: true,
            supports_thinking_beta_headers: true,
            supports_adaptive_thinking: false,
            supports_effort: false,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 1.0,
            output_cost_per_million: 5.0,
            cache_read_cost_per_million: 0.1,
            description: "Fast and affordable",
            recommended: true,
            retired_generation: false,
            tier: "haiku",
            sort_order: 5,
            release_date: "2025-10-01",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: None,
            default_reasoning_level: None,
            thinking_display: None,
        },
    );

    // Claude 4.1 (retired generation — August 2025)
    let _ = m.insert(
        "claude-opus-4-1-20250805",
        ClaudeModelInfo {
            name: "Claude Opus 4.1",
            short_name: "Opus 4.1",
            family: "Claude 4.1",
            context_window: 200_000,
            max_output: 32_000,
            supports_thinking: true,
            supports_thinking_beta_headers: true,
            supports_adaptive_thinking: false,
            supports_effort: false,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 15.0,
            output_cost_per_million: 75.0,
            cache_read_cost_per_million: 1.5,
            description: "Previous Opus with enhanced agentic capabilities",
            recommended: false,
            retired_generation: true,
            tier: "opus",
            sort_order: 6,
            release_date: "2025-08-05",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: None,
            default_reasoning_level: None,
            thinking_display: None,
        },
    );

    // Claude 4 (retired generation — May 2025)
    let _ = m.insert(
        "claude-opus-4-20250514",
        ClaudeModelInfo {
            name: "Claude Opus 4",
            short_name: "Opus 4",
            family: "Claude 4",
            context_window: 200_000,
            max_output: 32_000,
            supports_thinking: true,
            supports_thinking_beta_headers: true,
            supports_adaptive_thinking: false,
            supports_effort: false,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 15.0,
            output_cost_per_million: 75.0,
            cache_read_cost_per_million: 1.5,
            description: "Previous generation Opus",
            recommended: false,
            retired_generation: true,
            tier: "opus",
            sort_order: 7,
            release_date: "2025-05-14",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: None,
            default_reasoning_level: None,
            thinking_display: None,
        },
    );

    let _ = m.insert(
        "claude-sonnet-4-20250514",
        ClaudeModelInfo {
            name: "Claude Sonnet 4",
            short_name: "Sonnet 4",
            family: "Claude 4",
            context_window: 200_000,
            max_output: 64_000,
            supports_thinking: true,
            supports_thinking_beta_headers: true,
            supports_adaptive_thinking: false,
            supports_effort: false,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 3.0,
            output_cost_per_million: 15.0,
            cache_read_cost_per_million: 0.3,
            description: "Fast and capable",
            recommended: false,
            retired_generation: true,
            tier: "sonnet",
            sort_order: 8,
            release_date: "2025-05-14",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: None,
            default_reasoning_level: None,
            thinking_display: None,
        },
    );

    // Claude 3.7 (provider-retired; unavailable for new model selection)
    let _ = m.insert(
        "claude-3-7-sonnet-20250219",
        ClaudeModelInfo {
            name: "Claude 3.7 Sonnet",
            short_name: "Sonnet 3.7",
            family: "Claude 3.7",
            context_window: 200_000,
            max_output: 64_000,
            supports_thinking: true,
            supports_thinking_beta_headers: true,
            supports_adaptive_thinking: false,
            supports_effort: false,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 3.0,
            output_cost_per_million: 15.0,
            cache_read_cost_per_million: 0.3,
            description: "Retired — use Sonnet 4 or newer",
            recommended: false,
            retired_generation: true,
            tier: "sonnet",
            sort_order: 9,
            release_date: "2025-02-19",
            is_retired: true,
            deprecation_date: Some("2025-10-01"),
            reasoning_levels: None,
            default_reasoning_level: None,
            thinking_display: None,
        },
    );

    // Claude 3 (retired generation — oldest)
    let _ = m.insert(
        "claude-3-haiku-20240307",
        ClaudeModelInfo {
            name: "Claude 3 Haiku",
            short_name: "Haiku 3",
            family: "Claude 3",
            context_window: 200_000,
            max_output: 4_096,
            supports_thinking: false,
            supports_thinking_beta_headers: false,
            supports_adaptive_thinking: false,
            supports_effort: false,
            supports_capabilities: true,
            supports_images: true,
            input_cost_per_million: 0.25,
            output_cost_per_million: 1.25,
            cache_read_cost_per_million: 0.025,
            description: "Retired generation — fast and affordable",
            recommended: false,
            retired_generation: true,
            tier: "haiku",
            sort_order: 10,
            release_date: "2024-03-07",
            is_retired: false,
            deprecation_date: None,
            reasoning_levels: None,
            default_reasoning_level: None,
            thinking_display: None,
        },
    );

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
    /// Anthropic tool-use block.
    #[serde(rename = "tool_use")]
    CapabilityInvocation {
        /// Capability invocation ID.
        id: String,
        /// Capability name.
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
    /// Capability invocation arguments delta.
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
#[path = "types/tests.rs"]
mod tests;
