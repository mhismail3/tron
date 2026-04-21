//! Device-token lifecycle event payloads.

use serde::{Deserialize, Serialize};

/// Payload for `device.token_invalidated` events.
///
/// Emitted when APNS rejects a device token with a terminal error
/// (HTTP 410 `Unregistered`, HTTP 400 `BadDeviceToken`, HTTP 400
/// `DeviceTokenNotForTopic`). The row is atomically deactivated in
/// `device_tokens` so the next `NotifyApp` call skips it; this event
/// is the audit trail + broadcast hook so iOS can see that its token
/// was rejected without polling the DB.
///
/// Attributed to the `session_id` recorded on the token row at
/// registration time. If that session no longer exists the event is
/// dropped (no session to attribute it to); operator visibility falls
/// back to the `info` log line at the deactivation site.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceTokenInvalidatedPayload {
    /// Session ID this device token was registered to.
    pub session_id: String,
    /// First 8 chars of the device token — enough to cross-reference with
    /// `device_tokens` rows in the DB without leaking the full token.
    pub token_prefix: String,
    /// APNS `apns-topic` the token was issued against (e.g.,
    /// `com.tron.mobile.beta`). `None` for legacy pre-v006 tokens.
    pub bundle_id: Option<String>,
    /// HTTP status code returned by APNS (or relay-equivalent).
    /// Always present for terminal errors; `None` is reserved for
    /// transport-level failures that somehow classified as terminal.
    pub status_code: Option<u16>,
    /// APNS "reason" string from the response body (e.g.,
    /// `Unregistered`, `BadDeviceToken`, `DeviceTokenNotForTopic`).
    /// `None` when APNS returned a status with no reason payload.
    pub reason: Option<String>,
    /// ISO 8601 timestamp when the invalidation was observed.
    pub timestamp: String,
}
