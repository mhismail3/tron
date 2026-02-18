//! Message types for the Tron agent conversation model.
//!
//! Messages form the conversation history passed to LLM providers.
//! Three roles: user, assistant, and tool result. Each uses distinct
//! content types appropriate to that role.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::content::{AssistantContent, ToolResultContent, UserContent};
use crate::tools::Tool;

// ─────────────────────────────────────────────────────────────────────────────
// Tool call
// ─────────────────────────────────────────────────────────────────────────────

fn default_tool_use() -> String {
    "tool_use".into()
}

/// A tool call emitted by the assistant.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ToolCall {
    /// Discriminator — always `"tool_use"`.
    #[serde(rename = "type", default = "default_tool_use")]
    content_type: String,
    /// Unique tool call ID.
    pub id: String,
    /// Tool name.
    pub name: String,
    /// Tool arguments (JSON object).
    pub arguments: Map<String, Value>,
    /// Thought signature for Gemini models.
    #[serde(rename = "thoughtSignature", skip_serializing_if = "Option::is_none")]
    pub thought_signature: Option<String>,
}

impl Default for ToolCall {
    fn default() -> Self {
        Self {
            content_type: "tool_use".into(),
            id: String::new(),
            name: String::new(),
            arguments: Map::new(),
            thought_signature: None,
        }
    }
}

impl ToolCall {
    /// Create a new tool call.
    #[must_use]
    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        arguments: Map<String, Value>,
    ) -> Self {
        Self {
            content_type: "tool_use".into(),
            id: id.into(),
            name: name.into(),
            arguments,
            thought_signature: None,
        }
    }

    /// Create a new tool call with a thought signature.
    #[must_use]
    pub fn with_thought_signature(mut self, sig: impl Into<String>) -> Self {
        self.thought_signature = Some(sig.into());
        self
    }
}

/// Normalize tool arguments from canonical `arguments`.
#[must_use]
pub fn normalize_tool_arguments(block: &Value) -> Map<String, Value> {
    if let Some(args) = block.get("arguments").and_then(Value::as_object) {
        return args.clone();
    }
    Map::new()
}

/// Normalize tool result ID — handles both `tool_use_id` and `toolCallId`.
#[must_use]
pub fn normalize_tool_result_id(block: &Value) -> String {
    block
        .get("tool_use_id")
        .or_else(|| block.get("toolCallId"))
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
            _ => Err(format!("unknown provider: {s}")),
        }
    }
}

/// Backward-compatible alias (use [`Provider`] in new code).
pub type ProviderType = Provider;

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
    /// Model wants to use a tool.
    ToolUse,
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

/// Content of a tool result message — either a plain string or structured blocks.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ToolResultMessageContent {
    /// Simple text.
    Text(String),
    /// Structured content blocks.
    Blocks(Vec<ToolResultContent>),
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
    /// Tool result message.
    #[serde(rename = "toolResult")]
    ToolResult {
        /// Tool call ID.
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        /// Result content.
        content: ToolResultMessageContent,
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

    /// Returns `true` if this is a tool result message.
    #[must_use]
    pub fn is_tool_result(&self) -> bool {
        matches!(self, Self::ToolResult { .. })
    }

    /// Create a user message from a plain string.
    #[must_use]
    pub fn user(text: impl Into<String>) -> Self {
        Self::User {
            content: UserMessageContent::Text(text.into()),
            timestamp: None,
        }
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

/// Extract tool use blocks from assistant content.
pub fn extract_tool_calls(content: &[AssistantContent]) -> Vec<&AssistantContent> {
    content.iter().filter(|c| c.is_tool_use()).collect()
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
    /// Conversation messages.
    pub messages: Vec<Message>,
    /// Available tools.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tools: Option<Vec<Tool>>,
    /// Working directory for file operations.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub working_directory: Option<String>,
    /// Rules content from AGENTS.md / CLAUDE.md.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rules_content: Option<String>,
    /// Memory content.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub memory_content: Option<String>,
    /// Skill context.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skill_context: Option<String>,
    /// Sub-agent results context.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subagent_results_context: Option<String>,
    /// Task context.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub task_context: Option<String>,
    /// Dynamic rules context from path-scoped files.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dynamic_rules_context: Option<String>,
}

// ─────────────────────────────────────────────────────────────────────────────
// Type guard helpers for untyped values
// ─────────────────────────────────────────────────────────────────────────────

/// Check if a JSON value is an API-format `tool_result` block.
#[must_use]
pub fn is_api_tool_result_block(block: &Value) -> bool {
    block.get("type").and_then(Value::as_str) == Some("tool_result")
        && block.get("tool_use_id").and_then(Value::as_str).is_some()
}

/// Check if a JSON value is an internal-format `tool_result` block.
#[must_use]
pub fn is_internal_tool_result_block(block: &Value) -> bool {
    block.get("type").and_then(Value::as_str) == Some("tool_result")
        && block.get("toolCallId").and_then(Value::as_str).is_some()
}

/// Check if a JSON value is any `tool_result` block (API or internal format).
#[must_use]
pub fn is_any_tool_result_block(block: &Value) -> bool {
    is_api_tool_result_block(block) || is_internal_tool_result_block(block)
}

/// Check if a JSON value is an API-format `tool_use` block.
#[must_use]
pub fn is_api_tool_use_block(block: &Value) -> bool {
    block.get("type").and_then(Value::as_str) == Some("tool_use")
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

    // -- ToolCall --

    #[test]
    fn tool_call_default() {
        let tc = ToolCall::default();
        assert!(tc.id.is_empty());
    }

    #[test]
    fn tool_call_serializes_type_field() {
        let tc = ToolCall {
            id: "tc_1".into(),
            name: "test".into(),
            ..ToolCall::default()
        };
        let json = serde_json::to_value(&tc).unwrap();
        assert_eq!(json["type"], "tool_use");
    }

    #[test]
    fn tool_call_deserializes_type_field() {
        let json = r#"{"type":"tool_use","id":"tc_1","name":"test","arguments":{}}"#;
        let tc: ToolCall = serde_json::from_str(json).unwrap();
        assert_eq!(tc.id, "tc_1");
    }

    #[test]
    fn tool_call_serde_roundtrip() {
        let mut args = Map::new();
        let _ = args.insert("cmd".into(), json!("ls"));
        let tc = ToolCall {
            id: "call-1".into(),
            name: "bash".into(),
            arguments: args,
            ..ToolCall::default()
        };
        let json = serde_json::to_value(&tc).unwrap();
        let back: ToolCall = serde_json::from_value(json).unwrap();
        assert_eq!(tc, back);
    }

    // -- normalize helpers --

    #[test]
    fn normalize_tool_arguments_requires_arguments() {
        let v = json!({"input": {"a": 1}});
        let args = normalize_tool_arguments(&v);
        assert!(args.is_empty());
    }

    #[test]
    fn normalize_tool_arguments_from_arguments() {
        let v = json!({"arguments": {"b": 2}});
        let args = normalize_tool_arguments(&v);
        assert_eq!(args["b"], 2);
    }

    #[test]
    fn normalize_tool_arguments_empty() {
        let v = json!({});
        let args = normalize_tool_arguments(&v);
        assert!(args.is_empty());
    }

    #[test]
    fn normalize_tool_result_id_api_format() {
        let v = json!({"tool_use_id": "tc-1"});
        assert_eq!(normalize_tool_result_id(&v), "tc-1");
    }

    #[test]
    fn normalize_tool_result_id_internal_format() {
        let v = json!({"toolCallId": "tc-2"});
        assert_eq!(normalize_tool_result_id(&v), "tc-2");
    }

    #[test]
    fn normalize_tool_result_id_missing() {
        let v = json!({});
        assert_eq!(normalize_tool_result_id(&v), "");
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
            serde_json::to_string(&StopReason::ToolUse).unwrap(),
            "\"tool_use\""
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
        assert!(!msg.is_tool_result());

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
    fn message_tool_result() {
        let msg = Message::ToolResult {
            tool_call_id: "tc-1".into(),
            content: ToolResultMessageContent::Text("done".into()),
            is_error: None,
        };
        assert!(msg.is_tool_result());
        let json = serde_json::to_value(&msg).unwrap();
        assert_eq!(json["role"], "toolResult");
        assert_eq!(json["toolCallId"], "tc-1");
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
    fn extract_tool_calls_from_content() {
        let content = vec![
            AssistantContent::text("text"),
            AssistantContent::ToolUse {
                id: "tc-1".into(),
                name: "bash".into(),
                arguments: Map::new(),
                thought_signature: None,
            },
            AssistantContent::Thinking {
                thinking: "hmm".into(),
                signature: None,
            },
            AssistantContent::ToolUse {
                id: "tc-2".into(),
                name: "read".into(),
                arguments: Map::new(),
                thought_signature: None,
            },
        ];
        let tcs = extract_tool_calls(&content);
        assert_eq!(tcs.len(), 2);
    }

    #[test]
    fn extract_assistant_text_from_content() {
        let content = vec![
            AssistantContent::text("first"),
            AssistantContent::ToolUse {
                id: "tc-1".into(),
                name: "bash".into(),
                arguments: Map::new(),
                thought_signature: None,
            },
            AssistantContent::text("second"),
        ];
        assert_eq!(extract_assistant_text(&content), "first\nsecond");
    }

    // -- Type guard functions --

    #[test]
    fn is_api_tool_result_block_positive() {
        let v = json!({"type": "tool_result", "tool_use_id": "tc-1", "content": "ok"});
        assert!(is_api_tool_result_block(&v));
    }

    #[test]
    fn is_api_tool_result_block_negative() {
        let v = json!({"type": "tool_result", "toolCallId": "tc-1", "content": "ok"});
        assert!(!is_api_tool_result_block(&v));
    }

    #[test]
    fn is_internal_tool_result_block_positive() {
        let v = json!({"type": "tool_result", "toolCallId": "tc-1", "content": "ok"});
        assert!(is_internal_tool_result_block(&v));
    }

    #[test]
    fn is_any_tool_result_block_both_formats() {
        let api = json!({"type": "tool_result", "tool_use_id": "tc-1", "content": "ok"});
        let internal = json!({"type": "tool_result", "toolCallId": "tc-1", "content": "ok"});
        assert!(is_any_tool_result_block(&api));
        assert!(is_any_tool_result_block(&internal));
    }

    #[test]
    fn is_api_tool_use_block_positive() {
        let v = json!({"type": "tool_use", "id": "tc-1", "name": "bash", "arguments": {}});
        assert!(is_api_tool_use_block(&v));
    }

    #[test]
    fn is_api_tool_use_block_negative_missing_arguments() {
        let v = json!({"type": "tool_use", "id": "tc-1", "name": "bash"});
        assert!(!is_api_tool_use_block(&v));
    }

    // -- Context --

    #[test]
    fn context_default_is_empty() {
        let ctx = Context::default();
        assert!(ctx.system_prompt.is_none());
        assert!(ctx.messages.is_empty());
        assert!(ctx.tools.is_none());
    }

    #[test]
    fn context_serde_roundtrip() {
        let ctx = Context {
            system_prompt: Some("You are a helpful assistant.".into()),
            messages: vec![Message::user("hi")],
            tools: None,
            working_directory: Some("/tmp".into()),
            rules_content: None,
            memory_content: None,
            skill_context: None,
            subagent_results_context: None,
            task_context: None,
            dynamic_rules_context: None,
        };
        let json = serde_json::to_string(&ctx).unwrap();
        let back: Context = serde_json::from_str(&json).unwrap();
        assert_eq!(ctx, back);
    }

    // -- Provider --

    #[test]
    fn provider_serde_roundtrip() {
        assert_eq!(serde_json::to_string(&Provider::Anthropic).unwrap(), "\"anthropic\"");
        assert_eq!(serde_json::to_string(&Provider::OpenAi).unwrap(), "\"openai\"");
        assert_eq!(serde_json::to_string(&Provider::OpenAiCodex).unwrap(), "\"openai-codex\"");
        assert_eq!(serde_json::to_string(&Provider::Google).unwrap(), "\"google\"");
        assert_eq!(serde_json::to_string(&Provider::MiniMax).unwrap(), "\"minimax\"");
        assert_eq!(serde_json::to_string(&Provider::Unknown).unwrap(), "\"unknown\"");

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
        assert_eq!(Provider::Unknown.to_string(), "unknown");
    }

    #[test]
    fn provider_from_str() {
        assert_eq!("anthropic".parse::<Provider>().unwrap(), Provider::Anthropic);
        assert_eq!("openai".parse::<Provider>().unwrap(), Provider::OpenAi);
        assert_eq!("openai-codex".parse::<Provider>().unwrap(), Provider::OpenAiCodex);
        assert_eq!("google".parse::<Provider>().unwrap(), Provider::Google);
        assert_eq!("minimax".parse::<Provider>().unwrap(), Provider::MiniMax);
        assert!("nonexistent".parse::<Provider>().is_err());
    }

    #[test]
    fn provider_as_str() {
        assert_eq!(Provider::Anthropic.as_str(), "anthropic");
        assert_eq!(Provider::OpenAi.as_str(), "openai");
        assert_eq!(Provider::OpenAiCodex.as_str(), "openai-codex");
        assert_eq!(Provider::Google.as_str(), "google");
    }

    #[test]
    fn provider_type_alias_works() {
        // ProviderType alias is backward-compatible
        let pt: ProviderType = Provider::Anthropic;
        assert_eq!(pt, Provider::Anthropic);
    }
}
