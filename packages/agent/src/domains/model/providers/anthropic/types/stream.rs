//! Raw Anthropic Messages API streaming event DTOs.

use serde::Deserialize;

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
