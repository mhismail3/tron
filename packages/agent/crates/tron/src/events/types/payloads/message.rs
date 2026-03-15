//! Message event payloads: user, assistant, system.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::token_usage::{TokenRecord, TokenUsage};

/// Payload for `message.user` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserMessagePayload {
    /// User message content — either a plain string or array of content blocks.
    pub content: Value,
    /// Turn number.
    pub turn: i64,
    /// Number of images attached.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image_count: Option<i64>,
    /// Skills attached to this message (raw iOS objects: `[{name, source, displayName}]`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skills: Option<Value>,
    /// Spells attached to this message (same format as skills).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub spells: Option<Value>,
}

/// Payload for `message.assistant` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssistantMessagePayload {
    /// Content blocks (text, `tool_use`, thinking).
    pub content: Value,
    /// Turn number.
    pub turn: i64,
    /// Token usage for this message.
    pub token_usage: TokenUsage,
    /// Canonical token record.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_record: Option<TokenRecord>,
    /// LLM stop reason.
    pub stop_reason: String,
    /// LLM call latency in ms.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub latency: Option<i64>,
    /// Model ID used.
    pub model: String,
    /// Whether the response included thinking blocks.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub has_thinking: Option<bool>,
}

/// Payload for `message.system` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SystemMessagePayload {
    /// System message content.
    pub content: String,
    /// Source of the system message.
    pub source: String,
}
