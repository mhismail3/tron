//! Streaming event payloads: turn start/end, text/thinking deltas.

use serde::{Deserialize, Serialize};

use crate::shared::protocol::model_audit::ModelProviderReasoningStatusEvidence;

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
    /// Token usage for this turn, when the provider reported usage.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_usage: Option<TokenUsage>,
    /// Canonical token record.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_record: Option<TokenRecord>,
    /// Cost in USD.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cost: Option<f64>,
    /// Metadata-only provider reasoning/status evidence.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_status_evidence: Option<ModelProviderReasoningStatusEvidence>,
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shared::protocol::messages::Provider;
    use crate::shared::protocol::model_audit::{
        ModelProviderReasoningStatusEvidence, ModelProviderReasoningStatusPhase,
    };
    use serde_json::json;

    #[test]
    fn turn_end_payload_decodes_older_rows_without_reasoning_status() {
        let payload: StreamTurnEndPayload = serde_json::from_value(json!({
            "turn": 1,
            "tokenUsage": {
                "inputTokens": 10,
                "outputTokens": 5
            },
            "cost": 0.01
        }))
        .unwrap();

        assert_eq!(payload.turn, 1);
        assert!(payload.reasoning_status_evidence.is_none());
    }

    #[test]
    fn turn_end_payload_round_trips_reasoning_status_evidence() {
        let evidence = ModelProviderReasoningStatusEvidence::response(
            ModelProviderReasoningStatusPhase::TurnEnd,
            Provider::Google,
            "google",
            "gemini-3-pro-preview",
            Some("medium".to_owned()),
            "end_turn",
            true,
            None,
            Some("trace-17a".to_owned()),
            None,
        );
        let payload = StreamTurnEndPayload {
            turn: 2,
            token_usage: None,
            token_record: None,
            cost: None,
            reasoning_status_evidence: Some(evidence),
        };

        let json = serde_json::to_value(&payload).unwrap();
        assert_eq!(json["reasoningStatusEvidence"]["phase"], "turn_end");
        assert_eq!(
            json["reasoningStatusEvidence"]["safety"]["rawReasoningText"],
            "omitted"
        );

        let back: StreamTurnEndPayload = serde_json::from_value(json).unwrap();
        let back_evidence = back.reasoning_status_evidence.unwrap();
        assert_eq!(
            back_evidence.requested_reasoning_level.as_deref(),
            Some("medium")
        );
    }
}
