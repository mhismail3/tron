//! Narrow worker-to-iOS notification delivery.
//!
//! Workers opt into one closed output contract and own timing, content,
//! batching, deduplication, snooze, completion, and follow-up semantics.
//! [`WorkerStore`](super::persistence) owns logical delivery and target
//! evidence. The runtime dispatcher owns authenticated APNs transport.
//! Native clients may register an installation, synchronize the logical inbox,
//! and submit idempotent fixed responses; no general device-control primitive
//! exists.
//!
//! `transport` selects one engine-owned provider path. `apns` owns direct
//! provider-token signing while `relay` owns the closed HMAC client. Neither
//! owns delivery policy or durable state. The relay wire shape is an exact
//! lower-camel-case contract shared with `packages/relay`; request signatures
//! cover those serialized bytes, so field-name changes require boundary tests.

use std::collections::BTreeSet;

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::types::{WorkerBundle, WorkerClientDelivery};

pub(super) mod apns;
mod relay;
pub(super) mod transport;

pub(super) const MAX_DELIVERIES_PER_INVOCATION: usize = 32;
pub(super) const MAX_DELIVERY_AGE_DAYS: i64 = 30;
pub(super) const MAX_APNS_PAYLOAD_BYTES: usize = 4_096;

/// A validated logical notification emitted by one worker invocation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct NotificationIntent {
    pub(super) deduplication_key: String,
    pub(super) title: String,
    pub(super) body: String,
    pub(super) expires_at: DateTime<Utc>,
    pub(super) not_before: DateTime<Utc>,
    pub(super) thread_key: Option<String>,
    pub(super) source_record_id: Option<String>,
    pub(super) actions: Vec<NotificationResponseAction>,
    pub(super) on_open_complete: bool,
}

/// Fixed response actions supported by the native notification category.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum NotificationResponseAction {
    Snooze,
    Complete,
}

impl NotificationResponseAction {
    pub(super) const fn as_str(self) -> &'static str {
        match self {
            Self::Snooze => "snooze",
            Self::Complete => "complete",
        }
    }
}

/// APNs environment proven by the signed application entitlement.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum NotificationEnvironment {
    Sandbox,
    Production,
}

impl NotificationEnvironment {
    pub(super) const fn as_str(self) -> &'static str {
        match self {
            Self::Sandbox => "sandbox",
            Self::Production => "production",
        }
    }
}

/// iOS notification authorization state reported without exposing a token.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum NotificationAuthorizationStatus {
    NotDetermined,
    Denied,
    Authorized,
    Provisional,
    Ephemeral,
}

impl NotificationAuthorizationStatus {
    pub(super) const fn as_str(self) -> &'static str {
        match self {
            Self::NotDetermined => "not_determined",
            Self::Denied => "denied",
            Self::Authorized => "authorized",
            Self::Provisional => "provisional",
            Self::Ephemeral => "ephemeral",
        }
    }

    pub(super) const fn permits_delivery(self) -> bool {
        matches!(self, Self::Authorized | Self::Provisional | Self::Ephemeral)
    }
}

/// Authenticated installation registration request.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct NotificationDeviceUpsertRequest {
    pub(super) installation_id: String,
    pub(super) client_server_id: String,
    pub(super) topic: String,
    pub(super) environment: NotificationEnvironment,
    pub(super) authorization_status: NotificationAuthorizationStatus,
    #[serde(default)]
    pub(super) token: Option<String>,
}

/// Authenticated installation disable request.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct NotificationDeviceDisableRequest {
    pub(super) installation_id: String,
}

/// Cursor-bounded synchronized inbox request.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct NotificationDeliveriesRequest {
    #[serde(default)]
    pub(super) cursor: Option<String>,
    #[serde(default = "default_delivery_page_limit")]
    pub(super) limit: usize,
    #[serde(default)]
    pub(super) unread_only: bool,
}

fn default_delivery_page_limit() -> usize {
    100
}

/// Fixed native acknowledgement kinds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum NotificationAcknowledgementKind {
    Opened,
    Complete,
    Snooze,
    ClearUnread,
}

impl NotificationAcknowledgementKind {
    pub(super) const fn as_str(self) -> &'static str {
        match self {
            Self::Opened => "opened",
            Self::Complete => "complete",
            Self::Snooze => "snooze",
            Self::ClearUnread => "clear_unread",
        }
    }

    pub(super) const fn is_terminal_response(self) -> bool {
        !matches!(self, Self::ClearUnread)
    }
}

/// Idempotent native response request.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct NotificationAcknowledgeRequest {
    pub(super) delivery_id: String,
    pub(super) installation_id: String,
    pub(super) client_mutation_id: String,
    pub(super) acknowledgement: NotificationAcknowledgementKind,
    #[serde(default)]
    pub(super) occurred_at: Option<String>,
}

/// Exact delivery evidence read.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct NotificationDeliveryStatusRequest {
    pub(super) delivery_id: String,
}

pub(super) fn parse_notification_intents(
    output: &Value,
    now: DateTime<Utc>,
) -> Result<Vec<NotificationIntent>, String> {
    let Some(raw) = output.get("notificationDeliveries") else {
        return Ok(Vec::new());
    };
    let deliveries = raw
        .as_array()
        .ok_or_else(|| "notificationDeliveries must be an array".to_owned())?;
    if deliveries.len() > MAX_DELIVERIES_PER_INVOCATION {
        return Err(format!(
            "notificationDeliveries may contain at most {MAX_DELIVERIES_PER_INVOCATION} items"
        ));
    }
    deliveries
        .iter()
        .enumerate()
        .map(|(index, value)| parse_notification_intent(value, index, now))
        .collect()
}

pub(super) fn notification_intents_for_bundle(
    bundle: &WorkerBundle,
    output: &Value,
    now: DateTime<Utc>,
) -> Result<Vec<NotificationIntent>, String> {
    let declared = bundle
        .client_deliveries
        .contains(&WorkerClientDelivery::NotificationDelivery);
    if !declared {
        if output.get("notificationDeliveries").is_some() {
            return Err(
                "worker output uses reserved notificationDeliveries without declaring clientDeliveries notification_delivery"
                    .to_owned(),
            );
        }
        return Ok(Vec::new());
    }
    parse_notification_intents(output, now)
}

fn parse_notification_intent(
    value: &Value,
    index: usize,
    now: DateTime<Utc>,
) -> Result<NotificationIntent, String> {
    let object = value
        .as_object()
        .ok_or_else(|| format!("notificationDeliveries[{index}] must be an object"))?;
    const ALLOWED: &[&str] = &[
        "deduplicationKey",
        "title",
        "body",
        "expiresAt",
        "notBefore",
        "threadKey",
        "sourceRecordId",
        "actions",
        "onOpen",
    ];
    if let Some(field) = object.keys().find(|key| !ALLOWED.contains(&key.as_str())) {
        return Err(format!(
            "notificationDeliveries[{index}] contains unsupported field '{field}'"
        ));
    }
    let deduplication_key =
        required_bounded_string(value, "deduplicationKey", index, 64, BoundKind::Bytes)?;
    let title = required_bounded_string(value, "title", index, 120, BoundKind::Characters)?;
    let body = required_bounded_string(value, "body", index, 512, BoundKind::Characters)?;
    let expires_at_raw = required_bounded_string(value, "expiresAt", index, 64, BoundKind::Bytes)?;
    let expires_at = DateTime::parse_from_rfc3339(&expires_at_raw)
        .map_err(|error| {
            format!("notificationDeliveries[{index}].expiresAt must be RFC3339: {error}")
        })?
        .with_timezone(&Utc);
    if expires_at <= now {
        return Err(format!(
            "notificationDeliveries[{index}].expiresAt must be in the future"
        ));
    }
    if expires_at > now + Duration::days(MAX_DELIVERY_AGE_DAYS) {
        return Err(format!(
            "notificationDeliveries[{index}].expiresAt must be no later than {MAX_DELIVERY_AGE_DAYS} days"
        ));
    }
    let not_before = match value.get("notBefore") {
        None => now,
        Some(Value::String(value)) => DateTime::parse_from_rfc3339(value)
            .map_err(|error| {
                format!("notificationDeliveries[{index}].notBefore must be RFC3339: {error}")
            })?
            .with_timezone(&Utc)
            .max(now),
        Some(_) => {
            return Err(format!(
                "notificationDeliveries[{index}].notBefore must be an RFC3339 string"
            ));
        }
    };
    if not_before >= expires_at {
        return Err(format!(
            "notificationDeliveries[{index}].notBefore must be earlier than expiresAt"
        ));
    }
    let thread_key = optional_bounded_string(value, "threadKey", index, 64)?;
    let source_record_id = optional_bounded_string(value, "sourceRecordId", index, 128)?;
    let actions = parse_actions(value.get("actions"), index)?;
    let on_open_complete = match value.get("onOpen") {
        None => false,
        Some(Value::String(action)) if action == "complete" => true,
        Some(_) => {
            return Err(format!(
                "notificationDeliveries[{index}].onOpen must be 'complete'"
            ));
        }
    };
    Ok(NotificationIntent {
        deduplication_key,
        title,
        body,
        expires_at,
        not_before,
        thread_key,
        source_record_id,
        actions,
        on_open_complete,
    })
}

fn parse_actions(
    value: Option<&Value>,
    index: usize,
) -> Result<Vec<NotificationResponseAction>, String> {
    let Some(value) = value else {
        return Ok(Vec::new());
    };
    let values = value
        .as_array()
        .ok_or_else(|| format!("notificationDeliveries[{index}].actions must be an array"))?;
    let mut seen = BTreeSet::new();
    let mut actions = Vec::new();
    for value in values {
        let action = match value.as_str() {
            Some("snooze") => NotificationResponseAction::Snooze,
            Some("complete") => NotificationResponseAction::Complete,
            _ => {
                return Err(format!(
                    "notificationDeliveries[{index}].actions supports only snooze and complete"
                ));
            }
        };
        if !seen.insert(action.as_str()) {
            return Err(format!(
                "notificationDeliveries[{index}].actions must be unique"
            ));
        }
        actions.push(action);
    }
    Ok(actions)
}

#[derive(Clone, Copy)]
enum BoundKind {
    Bytes,
    Characters,
}

fn required_bounded_string(
    value: &Value,
    field: &str,
    index: usize,
    maximum: usize,
    kind: BoundKind,
) -> Result<String, String> {
    let string = value
        .get(field)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("notificationDeliveries[{index}].{field} is required"))?;
    let length = match kind {
        BoundKind::Bytes => string.len(),
        BoundKind::Characters => string.chars().count(),
    };
    if length > maximum {
        return Err(format!(
            "notificationDeliveries[{index}].{field} exceeds {maximum}"
        ));
    }
    Ok(string.to_owned())
}

fn optional_bounded_string(
    value: &Value,
    field: &str,
    index: usize,
    maximum_bytes: usize,
) -> Result<Option<String>, String> {
    let Some(raw) = value.get(field) else {
        return Ok(None);
    };
    let raw = raw
        .as_str()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            format!("notificationDeliveries[{index}].{field} must be a non-empty string")
        })?;
    if raw.len() > maximum_bytes {
        return Err(format!(
            "notificationDeliveries[{index}].{field} exceeds {maximum_bytes} UTF-8 bytes"
        ));
    }
    Ok(Some(raw.to_owned()))
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;
    use serde_json::json;

    use super::*;

    #[test]
    fn notification_contract_accepts_only_the_narrow_shape() {
        let now = Utc.with_ymd_and_hms(2026, 7, 25, 12, 0, 0).unwrap();
        let output = json!({
            "notificationDeliveries":[{
                "deduplicationKey":"reminder:1:2026-07-25T12:05:00Z",
                "title":"Take a break",
                "body":"Stand up and stretch.",
                "expiresAt":"2026-07-26T12:00:00Z",
                "threadKey":"wellbeing",
                "sourceRecordId":"reminder-1",
                "actions":["snooze","complete"],
                "onOpen":"complete"
            }]
        });
        let parsed = parse_notification_intents(&output, now).unwrap();
        assert_eq!(parsed.len(), 1);
        assert!(parsed[0].on_open_complete);
        assert_eq!(
            parsed[0].actions,
            vec![
                NotificationResponseAction::Snooze,
                NotificationResponseAction::Complete
            ]
        );
    }

    #[test]
    fn notification_contract_rejects_device_control_and_stale_delivery() {
        let now = Utc.with_ymd_and_hms(2026, 7, 25, 12, 0, 0).unwrap();
        let arbitrary = json!({
            "notificationDeliveries":[{
                "deduplicationKey":"one",
                "title":"Title",
                "body":"Body",
                "expiresAt":"2026-07-26T12:00:00Z",
                "deviceId":"phone"
            }]
        });
        assert!(
            parse_notification_intents(&arbitrary, now)
                .unwrap_err()
                .contains("unsupported field")
        );
        let stale = json!({
            "notificationDeliveries":[{
                "deduplicationKey":"one",
                "title":"Title",
                "body":"Body",
                "expiresAt":"2026-07-25T11:59:59Z"
            }]
        });
        assert!(
            parse_notification_intents(&stale, now)
                .unwrap_err()
                .contains("future")
        );
    }
}
