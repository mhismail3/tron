//! JSON wire DTOs and validation helpers for `/engine` messages.

use serde::{Deserialize, Serialize};

use serde_json::{Map, Value};

use crate::shared::server::errors::{CapabilityError, INVALID_PARAMS};
use crate::shared::server::events::ServerEventPayload;

use super::{STREAM_DEFAULT_LIMIT, STREAM_MAX_LIMIT};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct HelloMessage {
    #[serde(rename = "type")]
    pub(super) _message_type: String,
    pub(super) id: Option<String>,
    pub(super) protocol_version: u64,
    #[serde(default)]
    pub(super) _client_name: Option<String>,
    #[serde(default)]
    pub(super) _client_version: Option<String>,
    #[serde(default)]
    pub(super) session_id: Option<String>,
    #[serde(default)]
    pub(super) workspace_id: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct WireContext {
    #[serde(default)]
    pub(super) session_id: Option<String>,
    #[serde(default)]
    pub(super) workspace_id: Option<String>,
    #[serde(default)]
    pub(super) trace_id: Option<String>,
    #[serde(default)]
    pub(super) parent_invocation_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct InvokeMessage {
    #[serde(rename = "type")]
    pub(super) _message_type: String,
    pub(super) id: Option<String>,
    pub(super) function_id: String,
    #[serde(default)]
    pub(super) payload: Option<Value>,
    #[serde(default)]
    pub(super) idempotency_key: Option<String>,
    #[serde(default)]
    pub(super) context: Option<WireContext>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct PromoteMessage {
    #[serde(rename = "type")]
    pub(super) _message_type: String,
    pub(super) id: Option<String>,
    pub(super) function_id: String,
    pub(super) target_visibility: String,
    #[serde(default)]
    pub(super) workspace_id: Option<String>,
    pub(super) idempotency_key: String,
    #[serde(default)]
    pub(super) context: Option<WireContext>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct SubscribeMessage {
    #[serde(rename = "type")]
    pub(super) _message_type: String,
    pub(super) id: Option<String>,
    pub(super) topic: String,
    #[serde(default)]
    pub(super) cursor: Option<u64>,
    #[serde(default)]
    pub(super) filters: Option<Value>,
    #[serde(default)]
    pub(super) limit: Option<usize>,
    #[serde(default)]
    pub(super) context: Option<WireContext>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct PollMessage {
    #[serde(rename = "type")]
    pub(super) _message_type: String,
    pub(super) id: Option<String>,
    #[serde(default)]
    pub(super) subscription_id: Option<String>,
    #[serde(default)]
    pub(super) topic: Option<String>,
    #[serde(default)]
    pub(super) cursor: Option<u64>,
    #[serde(default)]
    pub(super) filters: Option<Value>,
    #[serde(default)]
    pub(super) limit: Option<usize>,
    #[serde(default)]
    pub(super) context: Option<WireContext>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct AckMessage {
    #[serde(rename = "type")]
    pub(super) _message_type: String,
    pub(super) id: Option<String>,
    pub(super) subscription_id: String,
    pub(super) cursor: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct HeartbeatMessage {
    #[serde(rename = "type")]
    pub(super) _message_type: String,
    pub(super) id: Option<String>,
    #[serde(default)]
    pub(super) timestamp: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ProtocolEvent {
    #[serde(rename = "type")]
    pub(super) message_type: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) subscription_id: Option<String>,
    pub(super) topic: String,
    pub(super) cursor: u64,
    pub(super) event: ServerEventPayload,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct RequestMessage {
    #[serde(rename = "type")]
    pub(super) _message_type: String,
    #[serde(default)]
    pub(super) id: Option<String>,
    pub(super) request: Value,
    #[serde(default)]
    pub(super) context: Option<WireContext>,
}

pub(super) fn optional_id(object: &Map<String, Value>) -> Result<Option<String>, CapabilityError> {
    match object.get("id") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => {
            if value.trim().is_empty() {
                Err(protocol_error(
                    INVALID_PARAMS,
                    "engine message id must be a non-empty string when present",
                    None,
                ))
            } else {
                Ok(Some(value.clone()))
            }
        }
        Some(_) => Err(protocol_error(
            INVALID_PARAMS,
            "engine message id must be a non-empty string when present",
            None,
        )),
    }
}

pub(super) fn checked_limit(limit: Option<usize>) -> Result<usize, CapabilityError> {
    let limit = limit.unwrap_or(STREAM_DEFAULT_LIMIT);
    if limit == 0 {
        return Err(protocol_error(
            INVALID_PARAMS,
            "stream limit must be greater than zero",
            None,
        ));
    }
    Ok(limit.min(STREAM_MAX_LIMIT))
}

pub(super) fn protocol_error(
    code: impl Into<String>,
    message: impl Into<String>,
    details: Option<Value>,
) -> CapabilityError {
    CapabilityError::Custom {
        code: code.into(),
        message: message.into(),
        details,
    }
}

pub(super) fn now_timestamp() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
