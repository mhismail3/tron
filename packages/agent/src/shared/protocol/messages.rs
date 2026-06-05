//! Message types for the Tron agent conversation model.
//!
//! Messages form the conversation history passed to LLM providers.
//! Three roles: user, assistant, and capability result. Each uses distinct
//! content types appropriate to that role.

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::shared::content::{AssistantContent, CapabilityResultContent, UserContent};
use crate::shared::model_capabilities::ModelCapability;

// ─────────────────────────────────────────────────────────────────────────────
// Capability invocation
// ─────────────────────────────────────────────────────────────────────────────

fn default_capability_invocation() -> String {
    "capability_invocation".into()
}

/// A capability invocation emitted by the assistant.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CapabilityInvocationDraft {
    /// Discriminator — always `"capability_invocation"`.
    #[serde(rename = "type", default = "default_capability_invocation")]
    content_type: String,
    /// Unique capability invocation ID.
    pub id: String,
    /// Capability name.
    pub name: String,
    /// Capability arguments (JSON object).
    pub arguments: Map<String, Value>,
    /// Thought signature for Gemini models.
    #[serde(rename = "thoughtSignature", skip_serializing_if = "Option::is_none")]
    pub thought_signature: Option<String>,
}

impl Default for CapabilityInvocationDraft {
    fn default() -> Self {
        Self {
            content_type: "capability_invocation".into(),
            id: String::new(),
            name: String::new(),
            arguments: Map::new(),
            thought_signature: None,
        }
    }
}

impl CapabilityInvocationDraft {
    /// Create a new capability invocation.
    #[must_use]
    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        arguments: Map<String, Value>,
    ) -> Self {
        Self {
            content_type: "capability_invocation".into(),
            id: id.into(),
            name: name.into(),
            arguments,
            thought_signature: None,
        }
    }

    /// Create a new capability invocation with a thought signature.
    #[must_use]
    pub fn with_thought_signature(mut self, sig: impl Into<String>) -> Self {
        self.thought_signature = Some(sig.into());
        self
    }
}

/// Normalize capability arguments from canonical `arguments`.
#[must_use]
pub fn normalize_capability_arguments(block: &Value) -> Map<String, Value> {
    if let Some(args) = block.get("arguments").and_then(Value::as_object) {
        return args.clone();
    }
    Map::new()
}

/// Normalize capability result ID — handles both `capability_invocation_id` and `invocationId`.
#[must_use]
pub fn normalize_capability_result_id(block: &Value) -> String {
    block
        .get("capability_invocation_id")
        .or_else(|| block.get("invocationId"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned()
}

/// Normalize error flag — handles both `is_error` and `isError`.
#[must_use]
pub fn normalize_is_error(block: &Value) -> bool {
    block
        .get("is_error")
        .or_else(|| block.get("isError"))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

// ─────────────────────────────────────────────────────────────────────────────
// Token and cost tracking
// ─────────────────────────────────────────────────────────────────────────────

/// LLM provider identity — single canonical enum used across all crates.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Provider {
    /// Anthropic (Claude).
    Anthropic,
    /// `OpenAI`.
    #[serde(rename = "openai")]
    OpenAi,
    /// `OpenAI` Codex (o-series pricing).
    #[serde(rename = "openai-codex")]
    OpenAiCodex,
    /// Google (Gemini).
    Google,
    /// `MiniMax` (M2 series).
    #[serde(rename = "minimax")]
    MiniMax,
    /// Kimi (Moonshot AI).
    #[serde(rename = "kimi")]
    Kimi,
    /// Ollama (local models).
    #[serde(rename = "ollama")]
    Ollama,
    /// Unrecognized provider (defensive deserialization).
    #[default]
    #[serde(other, rename = "unknown")]
    Unknown,
}

impl Provider {
    /// Wire-format string for this provider.
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Anthropic => "anthropic",
            Self::OpenAi => "openai",
            Self::OpenAiCodex => "openai-codex",
            Self::Google => "google",
            Self::MiniMax => "minimax",
            Self::Kimi => "kimi",
            Self::Ollama => "ollama",
            Self::Unknown => "unknown",
        }
    }
}

impl std::fmt::Display for Provider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

impl std::str::FromStr for Provider {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "anthropic" => Ok(Self::Anthropic),
            "openai" => Ok(Self::OpenAi),
            "openai-codex" => Ok(Self::OpenAiCodex),
            "google" => Ok(Self::Google),
            "minimax" => Ok(Self::MiniMax),
            "kimi" => Ok(Self::Kimi),
            "ollama" => Ok(Self::Ollama),
            _ => Err(format!("unknown provider: {s}")),
        }
    }
}

/// Token usage information from an LLM response.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenUsage {
    /// Provider-reported input tokens.
    ///
    /// Anthropic reports uncached input tokens here while `cache_read_tokens`
    /// and `cache_creation_tokens` hold the cached buckets. OpenAI and Google
    /// report the full effective prompt/context here, including cached input.
    pub input_tokens: u64,
    /// Output tokens generated.
    pub output_tokens: u64,
    /// Tokens read from prompt cache.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_read_tokens: Option<u64>,
    /// Cached input tokens as a provider-native field.
    ///
    /// This intentionally mirrors `cache_read_tokens` for providers that only
    /// expose cached input rather than a cache-read billing bucket. Keeping the
    /// raw field lets audits distinguish provider vocabulary from normalized
    /// cache billing buckets.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cached_input_tokens: Option<u64>,
    /// Tokens written to prompt cache.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_creation_tokens: Option<u64>,
    /// 5-minute TTL cache creation tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_creation_5m_tokens: Option<u64>,
    /// 1-hour TTL cache creation tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_creation_1h_tokens: Option<u64>,
    /// Output tokens spent on hidden reasoning, when the provider reports them.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_output_tokens: Option<u64>,
    /// Output tokens spent on provider thinking, when reported separately.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thought_tokens: Option<u64>,
    /// Prompt tokens attributed to tool-use scaffolding, when reported.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_use_prompt_tokens: Option<u64>,
    /// Provider-reported total tokens for this model call.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub total_tokens: Option<u64>,
    /// Provider type for normalization.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider_type: Option<Provider>,
}

/// Cost information in USD.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Cost {
    /// Input cost.
    pub input_cost: f64,
    /// Output cost.
    pub output_cost: f64,
    /// Total cost.
    pub total: f64,
    /// Currency code (always `"USD"`).
    pub currency: String,
}

/// Reasons why the model stopped generating.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StopReason {
    /// Natural end of response.
    EndTurn,
    /// Model wants to invoke a capability.
    CapabilityInvocation,
    /// Hit the max output token limit.
    MaxTokens,
    /// Hit a stop sequence.
    StopSequence,
    /// Model refused to answer (safety).
    Refusal,
    /// Exceeded the model's context window.
    #[serde(rename = "model_context_window_exceeded")]
    ModelContextWindowExceeded,
}

// ─────────────────────────────────────────────────────────────────────────────
// Message types
// ─────────────────────────────────────────────────────────────────────────────

/// Content of a user message — either a plain string or structured blocks.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum UserMessageContent {
    /// Simple text.
    Text(String),
    /// Structured content blocks.
    Blocks(Vec<UserContent>),
}

/// Content of a capability result message — either a plain string or structured blocks.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum CapabilityResultMessageContent {
    /// Simple text.
    Text(String),
    /// Structured content blocks.
    Blocks(Vec<CapabilityResultContent>),
}

/// A conversation message (discriminated by `role`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "role")]
pub enum Message {
    /// User message.
    #[serde(rename = "user")]
    User {
        /// Message content.
        content: UserMessageContent,
        /// Optional timestamp (epoch ms).
        #[serde(skip_serializing_if = "Option::is_none")]
        timestamp: Option<f64>,
    },
    /// Assistant message.
    #[serde(rename = "assistant")]
    Assistant {
        /// Content blocks.
        content: Vec<AssistantContent>,
        /// Token usage.
        #[serde(skip_serializing_if = "Option::is_none")]
        usage: Option<Box<TokenUsage>>,
        /// Cost.
        #[serde(skip_serializing_if = "Option::is_none")]
        cost: Option<Cost>,
        /// Stop reason.
        #[serde(rename = "stopReason", skip_serializing_if = "Option::is_none")]
        stop_reason: Option<StopReason>,
        /// Convenience thinking content.
        #[serde(skip_serializing_if = "Option::is_none")]
        thinking: Option<String>,
    },
    /// Capability result message.
    #[serde(rename = "capabilityResult")]
    CapabilityResult {
        /// Capability invocation ID.
        #[serde(rename = "invocationId")]
        invocation_id: String,
        /// Result content.
        content: CapabilityResultMessageContent,
        /// Error flag.
        #[serde(rename = "isError", skip_serializing_if = "Option::is_none")]
        is_error: Option<bool>,
    },
}

// ─────────────────────────────────────────────────────────────────────────────
// Message helpers
// ─────────────────────────────────────────────────────────────────────────────

impl Message {
    /// Returns `true` if this is a user message.
    #[must_use]
    pub fn is_user(&self) -> bool {
        matches!(self, Self::User { .. })
    }

    /// Returns `true` if this is an assistant message.
    #[must_use]
    pub fn is_assistant(&self) -> bool {
        matches!(self, Self::Assistant { .. })
    }

    /// Returns `true` if this is a capability result message.
    #[must_use]
    pub fn is_capability_result(&self) -> bool {
        matches!(self, Self::CapabilityResult { .. })
    }

    /// Create a user message from a plain string.
    #[must_use]
    pub fn user(text: impl Into<String>) -> Self {
        Self::User {
            content: UserMessageContent::Text(text.into()),
            timestamp: None,
        }
    }

    /// Returns `true` if this is a compaction summary message (not a real user turn).
    #[must_use]
    pub fn is_compaction_summary(&self) -> bool {
        matches!(self, Self::User { content: UserMessageContent::Text(t), .. }
            if t.starts_with("[Context from earlier in this conversation]"))
    }

    /// Returns `true` if this is a real user turn (user message, not a compaction summary).
    #[must_use]
    pub fn is_real_user_turn(&self) -> bool {
        self.is_user() && !self.is_compaction_summary()
    }

    /// Create an assistant message from text.
    #[must_use]
    pub fn assistant(text: impl Into<String>) -> Self {
        Self::Assistant {
            content: vec![AssistantContent::text(text)],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }
    }
}

/// Extract capability invocation blocks from assistant content.
pub fn extract_capability_invocations(content: &[AssistantContent]) -> Vec<&AssistantContent> {
    content
        .iter()
        .filter(|c| c.is_capability_invocation())
        .collect()
}

/// Extract text from assistant content blocks.
#[must_use]
pub fn extract_assistant_text(content: &[AssistantContent]) -> String {
    content
        .iter()
        .filter_map(AssistantContent::as_text)
        .collect::<Vec<_>>()
        .join("\n")
}

// ─────────────────────────────────────────────────────────────────────────────
// Context
// ─────────────────────────────────────────────────────────────────────────────

/// Full context for an LLM request.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Context {
    /// System prompt.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system_prompt: Option<String>,
    /// Conversation messages (shared via `Arc` to avoid deep cloning per turn).
    pub messages: Arc<[Message]>,
    /// Available capabilities.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capabilities: Option<Vec<ModelCapability>>,
    /// Working directory for file operations.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub working_directory: Option<String>,
    /// Rules content from AGENTS.md / CLAUDE.md.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rules_content: Option<String>,
    /// Memory content.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub memory_content: Option<String>,
    /// Lightweight skill index (name + description for all available skills).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skill_index_context: Option<String>,
    /// Skill activation directive ("follow these active skills").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skill_activation_context: Option<String>,
    /// Skill context (full content of explicitly invoked skills).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skill_context: Option<String>,
    /// Skill removal notice (one-turn "stop following" instruction for deactivated skills).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skill_removal_context: Option<String>,
    /// Completed background job results (unified processes + subagents).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub job_results_context: Option<String>,
    /// Dynamic rules context from path-scoped files.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dynamic_rules_context: Option<String>,
    /// Generated compact Worker Guide from the live capability catalog.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capability_primer_context: Option<String>,
    /// Context injected by hooks. This is audited as its own context block even
    /// when provider parity requires the text to remain folded into the user
    /// message for now.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hook_context: Option<String>,
    /// Server origin (e.g. `"localhost:9847"`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server_origin: Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Type guard helpers for untyped values
// ─────────────────────────────────────────────────────────────────────────────

/// Check if a JSON value is an API-format `capability_result` block.
#[must_use]
pub fn is_provider_capability_result_block(block: &Value) -> bool {
    block.get("type").and_then(Value::as_str) == Some("capability_result")
        && block
            .get("capability_invocation_id")
            .and_then(Value::as_str)
            .is_some()
}

/// Check if a JSON value is an internal-format `capability_result` block.
#[must_use]
pub fn is_internal_capability_result_block(block: &Value) -> bool {
    block.get("type").and_then(Value::as_str) == Some("capability_result")
        && block.get("invocationId").and_then(Value::as_str).is_some()
}

/// Check if a JSON value is any `capability_result` block (API or internal format).
#[must_use]
pub fn is_any_capability_result_block(block: &Value) -> bool {
    is_provider_capability_result_block(block) || is_internal_capability_result_block(block)
}

/// Check if a JSON value is an API-format `capability_invocation` block.
#[must_use]
pub fn is_provider_capability_invocation_block(block: &Value) -> bool {
    block.get("type").and_then(Value::as_str) == Some("capability_invocation")
        && block.get("id").and_then(Value::as_str).is_some()
        && block.get("arguments").is_some()
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
#[path = "messages/tests.rs"]
mod tests;
