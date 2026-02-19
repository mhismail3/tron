//! APNS type definitions.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Notification to send via APNS.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApnsNotification {
    /// Alert title.
    pub title: String,
    /// Alert body.
    pub body: String,
    /// Custom data fields.
    #[serde(default)]
    pub data: HashMap<String, String>,
    /// Priority: "high" (10) or "normal" (5).
    #[serde(default = "default_priority")]
    pub priority: String,
    /// Sound name (e.g., "default").
    pub sound: Option<String>,
    /// Badge count.
    pub badge: Option<u32>,
    /// Thread ID for notification grouping.
    pub thread_id: Option<String>,
}

fn default_priority() -> String {
    "high".to_string()
}

/// Result of sending a single notification.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ApnsSendResult {
    /// Whether the send succeeded.
    pub success: bool,
    /// The device token targeted.
    pub device_token: String,
    /// APNS-assigned notification ID (on success).
    pub apns_id: Option<String>,
    /// HTTP status code.
    pub status_code: Option<u16>,
    /// Error reason from APNS.
    pub reason: Option<String>,
    /// Error message.
    pub error: Option<String>,
}
