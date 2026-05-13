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
    #[default]
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
    /// Input tokens (new tokens for Anthropic, full context for others).
    pub input_tokens: u64,
    /// Output tokens generated.
    pub output_tokens: u64,
    /// Tokens read from prompt cache.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_read_tokens: Option<u64>,
    /// Tokens written to prompt cache.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_creation_tokens: Option<u64>,
    /// 5-minute TTL cache creation tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_creation_5m_tokens: Option<u64>,
    /// 1-hour TTL cache creation tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_creation_1h_tokens: Option<u64>,
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
        usage: Option<TokenUsage>,
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
    /// Generated compact capability catalog primer.
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
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::Arc;

    // -- CapabilityInvocationDraft --

    #[test]
    fn capability_invocation_default() {
        let tc = CapabilityInvocationDraft::default();
        assert!(tc.id.is_empty());
    }

    #[test]
    fn capability_invocation_serializes_type_field() {
        let tc = CapabilityInvocationDraft {
            id: "tc_1".into(),
            name: "test".into(),
            ..CapabilityInvocationDraft::default()
        };
        let json = serde_json::to_value(&tc).unwrap();
        assert_eq!(json["type"], "capability_invocation");
    }

    #[test]
    fn capability_invocation_deserializes_type_field() {
        let json = r#"{"type":"capability_invocation","id":"tc_1","name":"test","arguments":{}}"#;
        let tc: CapabilityInvocationDraft = serde_json::from_str(json).unwrap();
        assert_eq!(tc.id, "tc_1");
    }

    #[test]
    fn capability_invocation_serde_roundtrip() {
        let mut args = Map::new();
        let _ = args.insert("cmd".into(), json!("ls"));
        let tc = CapabilityInvocationDraft {
            id: "call-1".into(),
            name: "execute".into(),
            arguments: args,
            ..CapabilityInvocationDraft::default()
        };
        let json = serde_json::to_value(&tc).unwrap();
        let back: CapabilityInvocationDraft = serde_json::from_value(json).unwrap();
        assert_eq!(tc, back);
    }

    // -- normalize helpers --

    #[test]
    fn normalize_capability_arguments_requires_arguments() {
        let v = json!({"input": {"a": 1}});
        let args = normalize_capability_arguments(&v);
        assert!(args.is_empty());
    }

    #[test]
    fn normalize_capability_arguments_from_arguments() {
        let v = json!({"arguments": {"b": 2}});
        let args = normalize_capability_arguments(&v);
        assert_eq!(args["b"], 2);
    }

    #[test]
    fn normalize_capability_arguments_empty() {
        let v = json!({});
        let args = normalize_capability_arguments(&v);
        assert!(args.is_empty());
    }

    #[test]
    fn normalize_capability_result_id_api_format() {
        let v = json!({"capability_invocation_id": "tc-1"});
        assert_eq!(normalize_capability_result_id(&v), "tc-1");
    }

    #[test]
    fn normalize_capability_result_id_internal_format() {
        let v = json!({"invocationId": "tc-2"});
        assert_eq!(normalize_capability_result_id(&v), "tc-2");
    }

    #[test]
    fn normalize_capability_result_id_missing() {
        let v = json!({});
        assert_eq!(normalize_capability_result_id(&v), "");
    }

    #[test]
    fn normalize_is_error_api_format() {
        let v = json!({"is_error": true});
        assert!(normalize_is_error(&v));
    }

    #[test]
    fn normalize_is_error_internal_format() {
        let v = json!({"isError": true});
        assert!(normalize_is_error(&v));
    }

    #[test]
    fn normalize_is_error_default_false() {
        let v = json!({});
        assert!(!normalize_is_error(&v));
    }

    // -- TokenUsage --

    #[test]
    fn token_usage_default() {
        let usage = TokenUsage::default();
        assert_eq!(usage.input_tokens, 0);
        assert_eq!(usage.output_tokens, 0);
        assert!(usage.cache_read_tokens.is_none());
    }

    #[test]
    fn token_usage_serde() {
        let usage = TokenUsage {
            input_tokens: 100,
            output_tokens: 50,
            cache_read_tokens: Some(30),
            cache_creation_tokens: None,
            cache_creation_5m_tokens: None,
            cache_creation_1h_tokens: None,
            provider_type: Some(Provider::Anthropic),
        };
        let json = serde_json::to_value(&usage).unwrap();
        assert_eq!(json["inputTokens"], 100);
        assert_eq!(json["cacheReadTokens"], 30);
        assert!(json.get("cacheCreationTokens").is_none());
    }

    #[test]
    fn provider_minimax_serde_roundtrip() {
        let pt = Provider::MiniMax;
        let json = serde_json::to_string(&pt).unwrap();
        assert_eq!(json, "\"minimax\"");
        let back: Provider = serde_json::from_str(&json).unwrap();
        assert_eq!(back, Provider::MiniMax);
    }

    #[test]
    fn provider_kimi_serde_roundtrip() {
        let pt = Provider::Kimi;
        let json = serde_json::to_string(&pt).unwrap();
        assert_eq!(json, "\"kimi\"");
        let back: Provider = serde_json::from_str(&json).unwrap();
        assert_eq!(back, Provider::Kimi);
    }

    #[test]
    fn token_usage_with_minimax_provider() {
        let usage = TokenUsage {
            input_tokens: 200,
            output_tokens: 100,
            provider_type: Some(Provider::MiniMax),
            ..Default::default()
        };
        let json = serde_json::to_value(&usage).unwrap();
        assert_eq!(json["providerType"], "minimax");
    }

    // -- StopReason --

    #[test]
    fn stop_reason_serde() {
        assert_eq!(
            serde_json::to_string(&StopReason::EndTurn).unwrap(),
            "\"end_turn\""
        );
        assert_eq!(
            serde_json::to_string(&StopReason::CapabilityInvocation).unwrap(),
            "\"capability_invocation\""
        );
        assert_eq!(
            serde_json::to_string(&StopReason::ModelContextWindowExceeded).unwrap(),
            "\"model_context_window_exceeded\""
        );
    }

    // -- Message enum --

    #[test]
    fn message_user_text() {
        let msg = Message::user("hello");
        assert!(msg.is_user());
        assert!(!msg.is_assistant());
        assert!(!msg.is_capability_result());

        let json = serde_json::to_value(&msg).unwrap();
        assert_eq!(json["role"], "user");
        assert_eq!(json["content"], "hello");
    }

    #[test]
    fn message_assistant_text() {
        let msg = Message::assistant("world");
        assert!(msg.is_assistant());
        let json = serde_json::to_value(&msg).unwrap();
        assert_eq!(json["role"], "assistant");
    }

    #[test]
    fn message_assistant_with_stop_reason() {
        let msg = Message::Assistant {
            content: vec![AssistantContent::text("done")],
            usage: None,
            cost: None,
            stop_reason: Some(StopReason::EndTurn),
            thinking: None,
        };
        let json = serde_json::to_value(&msg).unwrap();
        assert_eq!(json["stopReason"], "end_turn");
    }

    #[test]
    fn message_capability_result() {
        let msg = Message::CapabilityResult {
            invocation_id: "tc-1".into(),
            content: CapabilityResultMessageContent::Text("done".into()),
            is_error: None,
        };
        assert!(msg.is_capability_result());
        let json = serde_json::to_value(&msg).unwrap();
        assert_eq!(json["role"], "capabilityResult");
        assert_eq!(json["invocationId"], "tc-1");
    }

    #[test]
    fn message_serde_roundtrip() {
        let msg = Message::user("test");
        let json = serde_json::to_string(&msg).unwrap();
        let back: Message = serde_json::from_str(&json).unwrap();
        assert_eq!(msg, back);
    }

    // -- extract helpers --

    #[test]
    fn extract_capability_invocations_from_content() {
        let content = vec![
            AssistantContent::text("text"),
            AssistantContent::CapabilityInvocation {
                id: "tc-1".into(),
                name: "execute".into(),
                arguments: Map::new(),
                thought_signature: None,
            },
            AssistantContent::Thinking {
                thinking: "hmm".into(),
                signature: None,
            },
            AssistantContent::CapabilityInvocation {
                id: "tc-2".into(),
                name: "inspect".into(),
                arguments: Map::new(),
                thought_signature: None,
            },
        ];
        let tcs = extract_capability_invocations(&content);
        assert_eq!(tcs.len(), 2);
    }

    #[test]
    fn extract_assistant_text_from_content() {
        let content = vec![
            AssistantContent::text("first"),
            AssistantContent::CapabilityInvocation {
                id: "tc-1".into(),
                name: "execute".into(),
                arguments: Map::new(),
                thought_signature: None,
            },
            AssistantContent::text("second"),
        ];
        assert_eq!(extract_assistant_text(&content), "first\nsecond");
    }

    // -- Type guard functions --

    #[test]
    fn is_provider_capability_result_block_positive() {
        let v = json!({"type": "capability_result", "capability_invocation_id": "tc-1", "content": "ok"});
        assert!(is_provider_capability_result_block(&v));
    }

    #[test]
    fn is_provider_capability_result_block_negative() {
        let v = json!({"type": "capability_result", "invocationId": "tc-1", "content": "ok"});
        assert!(!is_provider_capability_result_block(&v));
    }

    #[test]
    fn is_internal_capability_result_block_positive() {
        let v = json!({"type": "capability_result", "invocationId": "tc-1", "content": "ok"});
        assert!(is_internal_capability_result_block(&v));
    }

    #[test]
    fn is_any_capability_result_block_both_formats() {
        let api = json!({"type": "capability_result", "capability_invocation_id": "tc-1", "content": "ok"});
        let internal =
            json!({"type": "capability_result", "invocationId": "tc-1", "content": "ok"});
        assert!(is_any_capability_result_block(&api));
        assert!(is_any_capability_result_block(&internal));
    }

    #[test]
    fn is_provider_capability_invocation_block_positive() {
        let v = json!({"type": "capability_invocation", "id": "tc-1", "name": "execute", "arguments": {}});
        assert!(is_provider_capability_invocation_block(&v));
    }

    #[test]
    fn is_provider_capability_invocation_block_negative_missing_arguments() {
        let v = json!({"type": "capability_invocation", "id": "tc-1", "name": "execute"});
        assert!(!is_provider_capability_invocation_block(&v));
    }

    // -- Context --

    #[test]
    fn context_default_is_empty() {
        let ctx = Context::default();
        assert!(ctx.system_prompt.is_none());
        assert!(ctx.messages.is_empty());
        assert!(ctx.capabilities.is_none());
    }

    #[test]
    fn context_serde_roundtrip() {
        let ctx = Context {
            system_prompt: Some("You are a helpful assistant.".into()),
            messages: vec![Message::user("hi")].into(),
            capabilities: None,
            working_directory: Some("/tmp".into()),
            rules_content: None,
            memory_content: None,
            skill_index_context: None,
            skill_activation_context: None,
            skill_context: None,
            skill_removal_context: None,
            job_results_context: None,
            dynamic_rules_context: None,
            capability_primer_context: None,
            hook_context: None,
            server_origin: None,
        };
        let json = serde_json::to_string(&ctx).unwrap();
        let back: Context = serde_json::from_str(&json).unwrap();
        assert_eq!(ctx, back);
    }

    #[test]
    fn context_messages_deref_to_slice() {
        let ctx = Context {
            messages: vec![Message::user("hello")].into(),
            ..Default::default()
        };
        let slice: &[Message] = &ctx.messages;
        assert_eq!(slice.len(), 1);
    }

    #[test]
    fn context_clone_shares_arc() {
        let ctx = Context {
            messages: vec![Message::user("hello")].into(),
            ..Default::default()
        };
        let ctx2 = ctx.clone();
        assert!(Arc::ptr_eq(&ctx.messages, &ctx2.messages));
    }

    // -- Provider --

    #[test]
    fn provider_serde_roundtrip() {
        assert_eq!(
            serde_json::to_string(&Provider::Anthropic).unwrap(),
            "\"anthropic\""
        );
        assert_eq!(
            serde_json::to_string(&Provider::OpenAi).unwrap(),
            "\"openai\""
        );
        assert_eq!(
            serde_json::to_string(&Provider::OpenAiCodex).unwrap(),
            "\"openai-codex\""
        );
        assert_eq!(
            serde_json::to_string(&Provider::Google).unwrap(),
            "\"google\""
        );
        assert_eq!(
            serde_json::to_string(&Provider::MiniMax).unwrap(),
            "\"minimax\""
        );
        assert_eq!(serde_json::to_string(&Provider::Kimi).unwrap(), "\"kimi\"");
        assert_eq!(
            serde_json::to_string(&Provider::Ollama).unwrap(),
            "\"ollama\""
        );
        assert_eq!(
            serde_json::to_string(&Provider::Unknown).unwrap(),
            "\"unknown\""
        );

        let back: Provider = serde_json::from_str("\"anthropic\"").unwrap();
        assert_eq!(back, Provider::Anthropic);

        // Unknown catches unrecognized strings via #[serde(other)]
        let unknown: Provider = serde_json::from_str("\"some-future-provider\"").unwrap();
        assert_eq!(unknown, Provider::Unknown);
    }

    #[test]
    fn provider_display() {
        assert_eq!(Provider::Anthropic.to_string(), "anthropic");
        assert_eq!(Provider::OpenAi.to_string(), "openai");
        assert_eq!(Provider::OpenAiCodex.to_string(), "openai-codex");
        assert_eq!(Provider::MiniMax.to_string(), "minimax");
        assert_eq!(Provider::Kimi.to_string(), "kimi");
        assert_eq!(Provider::Ollama.to_string(), "ollama");
        assert_eq!(Provider::Unknown.to_string(), "unknown");
    }

    #[test]
    fn provider_from_str() {
        assert_eq!(
            "anthropic".parse::<Provider>().unwrap(),
            Provider::Anthropic
        );
        assert_eq!("openai".parse::<Provider>().unwrap(), Provider::OpenAi);
        assert_eq!(
            "openai-codex".parse::<Provider>().unwrap(),
            Provider::OpenAiCodex
        );
        assert_eq!("google".parse::<Provider>().unwrap(), Provider::Google);
        assert_eq!("minimax".parse::<Provider>().unwrap(), Provider::MiniMax);
        assert_eq!("kimi".parse::<Provider>().unwrap(), Provider::Kimi);
        assert_eq!("ollama".parse::<Provider>().unwrap(), Provider::Ollama);
        assert!("nonexistent".parse::<Provider>().is_err());
    }

    #[test]
    fn provider_as_str() {
        assert_eq!(Provider::Anthropic.as_str(), "anthropic");
        assert_eq!(Provider::OpenAi.as_str(), "openai");
        assert_eq!(Provider::OpenAiCodex.as_str(), "openai-codex");
        assert_eq!(Provider::Google.as_str(), "google");
    }

    // -- is_compaction_summary --

    #[test]
    fn is_compaction_summary_true() {
        let msg = Message::user("[Context from earlier in this conversation]\n\nSummary here.");
        assert!(msg.is_compaction_summary());
    }

    #[test]
    fn is_compaction_summary_false_regular_user() {
        let msg = Message::user("Hello, can you help me?");
        assert!(!msg.is_compaction_summary());
    }

    #[test]
    fn is_compaction_summary_false_assistant() {
        let msg = Message::assistant("[Context from earlier in this conversation]");
        assert!(!msg.is_compaction_summary());
    }

    #[test]
    fn is_compaction_summary_false_capability_result() {
        let msg = Message::CapabilityResult {
            invocation_id: "tc-1".into(),
            content: CapabilityResultMessageContent::Text(
                "[Context from earlier in this conversation]".into(),
            ),
            is_error: None,
        };
        assert!(!msg.is_compaction_summary());
    }

    #[test]
    fn is_compaction_summary_false_similar_prefix() {
        let msg = Message::user("[Context from another source]");
        assert!(!msg.is_compaction_summary());
    }

    // -- is_real_user_turn --

    #[test]
    fn is_real_user_turn_regular() {
        let msg = Message::user("Help me with this code.");
        assert!(msg.is_real_user_turn());
    }

    #[test]
    fn is_real_user_turn_compaction_summary() {
        let msg = Message::user("[Context from earlier in this conversation]\n\nSummary.");
        assert!(!msg.is_real_user_turn());
    }

    #[test]
    fn is_real_user_turn_assistant() {
        let msg = Message::assistant("Sure, I can help.");
        assert!(!msg.is_real_user_turn());
    }
}
