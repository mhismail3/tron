//! Streaming event payloads: turn start/end, text/thinking deltas.

use serde::{Deserialize, Serialize};

use super::token_usage::{TokenRecord, TokenUsage};

/// Payload for `stream.turn_start` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StreamTurnStartPayload {
    /// Turn number.
    pub turn: i64,
}

/// Payload for `stream.turn_end` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StreamTurnEndPayload {
    /// Turn number.
    pub turn: i64,
    /// Token usage for this turn.
    pub token_usage: TokenUsage,
    /// Canonical token record.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_record: Option<TokenRecord>,
    /// Cost in USD.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cost: Option<f64>,
}

/// Payload for `stream.text_delta` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StreamTextDeltaPayload {
    /// Text fragment.
    pub delta: String,
    /// Turn number.
    pub turn: i64,
    /// Block index within the response.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub block_index: Option<i64>,
}

/// Payload for `stream.thinking_delta` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StreamThinkingDeltaPayload {
    /// Thinking text fragment.
    pub delta: String,
    /// Turn number.
    pub turn: i64,
}
