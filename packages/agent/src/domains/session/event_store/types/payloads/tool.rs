//! Tool event payloads: call, progress, result.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Payload for `tool.call` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolCallPayload {
    /// Tool call ID.
    pub tool_call_id: String,
    /// Tool name.
    pub name: String,
    /// Tool arguments.
    pub arguments: Value,
    /// Turn number.
    pub turn: i64,
}

/// Payload for `tool.progress` events.
///
/// Emitted by long-running capability calls (`process::run`, `web::fetch`,
/// `agent::spawn_subagent`, …) to keep
/// iOS chips from looking frozen and to let users cancel work that's taking
/// too long. Every field except `tool_call_id` is optional — tools pick
/// whichever fit their work: process::run streams a `message` with the latest stdout
/// line; web::fetch sets both `percent` (bytes/total) and `message` ("32 KiB of
/// 120 KiB"); subagent execution sets `message` with the child turn count.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolProgressPayload {
    /// The `tool.call` this progress update belongs to.
    pub tool_call_id: String,
    /// Free-form human-readable status ("downloaded 32 KiB", "turn 3 of 8").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    /// Fractional completion in `[0.0, 1.0]` when a total is known. Tools
    /// without a bound (process::run heartbeat, indefinite subagent) leave this unset
    /// rather than guessing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub percent: Option<f64>,
    /// Turn number the progress belongs to.
    pub turn: i64,
}

/// Payload for `tool.result` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolResultPayload {
    /// Tool call ID this result corresponds to.
    pub tool_call_id: String,
    /// Result content.
    pub content: String,
    /// Whether the tool execution errored.
    pub is_error: bool,
    /// Duration in milliseconds.
    pub duration: i64,
    /// Files affected by the tool.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub affected_files: Option<Vec<String>>,
    /// Whether the content was truncated.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub truncated: Option<bool>,
    /// Blob ID for truncated content.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blob_id: Option<String>,
    /// Tool-specific metadata (e.g. `web::fetch`: url, status, `fromCache`, `responseHeaders`;
    /// `process::run`: `exitCode`, command, `durationMs`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_progress_serializes_camel_case_with_turn() {
        let p = ToolProgressPayload {
            tool_call_id: "call-1".into(),
            message: Some("32 KiB of 120 KiB".into()),
            percent: Some(0.267),
            turn: 3,
        };
        let v = serde_json::to_value(&p).unwrap();
        assert_eq!(v["toolCallId"], "call-1");
        assert_eq!(v["message"], "32 KiB of 120 KiB");
        assert_eq!(v["percent"], 0.267);
        assert_eq!(v["turn"], 3);
        assert!(v.get("tool_call_id").is_none());
    }

    #[test]
    fn tool_progress_omits_optional_fields_when_none() {
        let p = ToolProgressPayload {
            tool_call_id: "call-1".into(),
            message: None,
            percent: None,
            turn: 1,
        };
        let v = serde_json::to_value(&p).unwrap();
        assert!(v.get("message").is_none(), "message should be omitted");
        assert!(v.get("percent").is_none(), "percent should be omitted");
        assert_eq!(v["toolCallId"], "call-1");
        assert_eq!(v["turn"], 1);
    }

    #[test]
    fn tool_progress_roundtrip_preserves_fields() {
        let p = ToolProgressPayload {
            tool_call_id: "c".into(),
            message: Some("m".into()),
            percent: Some(0.5),
            turn: 7,
        };
        let s = serde_json::to_string(&p).unwrap();
        let back: ToolProgressPayload = serde_json::from_str(&s).unwrap();
        assert_eq!(p, back);
    }
}
