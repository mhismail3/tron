//! APNS-backed [`NotifyDelegate`] — sends real push notifications via Apple's
//! APNs HTTP/2 service.
//!
//! Maps the tool-level [`Notification`] to platform-level [`ApnsNotification`],
//! queries active device tokens from `SQLite`, and marks 410-expired tokens.

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use tracing::{debug, info};
use tron_events::sqlite::repositories::device_token::DeviceTokenRepo;
use tron_events::ConnectionPool;
use tron_platform::apns::{ApnsNotification, ApnsService};
use tron_tools::errors::ToolError;
use tron_tools::traits::{Notification, NotifyDelegate, NotifyResult};

/// Real APNS notification delegate.
pub struct ApnsNotifyDelegate {
    apns: Arc<ApnsService>,
    pool: ConnectionPool,
}

impl ApnsNotifyDelegate {
    /// Create a new delegate with the given APNS service and DB pool.
    pub fn new(apns: Arc<ApnsService>, pool: ConnectionPool) -> Self {
        Self { apns, pool }
    }

    /// Convert a tool-level [`Notification`] to a platform-level [`ApnsNotification`].
    fn to_apns_notification(notification: &Notification) -> ApnsNotification {
        let mut data = HashMap::new();

        // Forward custom data (convert Value map to String map)
        if let Some(ref extra) = notification.data {
            if let Some(obj) = extra.as_object() {
                for (k, v) in obj {
                    let s = if let Some(s) = v.as_str() {
                        s.to_string()
                    } else {
                        v.to_string()
                    };
                    let _ = data.insert(k.clone(), s);
                }
            }
        }

        ApnsNotification {
            title: notification.title.clone(),
            body: notification.body.clone(),
            data,
            priority: notification.priority.clone(),
            sound: Some("default".to_string()),
            badge: notification.badge,
            thread_id: None,
        }
    }
}

#[async_trait]
impl NotifyDelegate for ApnsNotifyDelegate {
    async fn send_notification(
        &self,
        notification: &Notification,
    ) -> Result<NotifyResult, ToolError> {
        let conn = self.pool.get().map_err(|e| ToolError::Internal {
            message: format!("Failed to get DB connection: {e}"),
        })?;

        let tokens = DeviceTokenRepo::get_all_active(&conn).map_err(|e| ToolError::Internal {
            message: format!("Failed to query device tokens: {e}"),
        })?;

        if tokens.is_empty() {
            info!("No active device tokens — skipping APNS send");
            return Ok(NotifyResult { success: true, message: None });
        }

        let token_strings: Vec<String> = tokens.iter().map(|t| t.device_token.clone()).collect();
        let apns_notif = Self::to_apns_notification(notification);
        let total = token_strings.len();

        info!(
            device_count = total,
            title = %notification.title,
            tokens = ?token_strings.iter().map(|t| format!("{}...({})", &t[..8.min(t.len())], t.len())).collect::<Vec<_>>(),
            "Sending APNS notification"
        );

        let results = self.apns.send_to_many(&token_strings, &apns_notif).await;

        // Mark 410 (Unregistered) tokens as invalid
        let mut success_count = 0;
        let mut errors = Vec::new();

        for result in &results {
            info!(
                token_prefix = &result.device_token[..8.min(result.device_token.len())],
                token_len = result.device_token.len(),
                success = result.success,
                status = ?result.status_code,
                reason = ?result.reason,
                error = ?result.error,
                apns_id = ?result.apns_id,
                "APNS per-device result"
            );

            if result.success {
                success_count += 1;
            } else {
                if result.status_code == Some(410) {
                    debug!(
                        device_token = &result.device_token[..8.min(result.device_token.len())],
                        "Marking expired token as invalid"
                    );
                    let _ = DeviceTokenRepo::mark_invalid(&conn, &result.device_token);
                }
                if let Some(ref err) = result.error {
                    errors.push(format!(
                        "{}...(len={}): {}",
                        &result.device_token[..8.min(result.device_token.len())],
                        result.device_token.len(),
                        err
                    ));
                }
            }
        }

        let message = if errors.is_empty() {
            format!("Sent to {success_count} of {total} devices.")
        } else {
            format!(
                "Sent to {success_count} of {total} devices. Errors: {}",
                errors.join("; ")
            )
        };

        info!(
            success_count,
            error_count = errors.len(),
            total,
            message = %message,
            "APNS delivery summary"
        );

        Ok(NotifyResult {
            success: success_count > 0,
            message: Some(message),
        })
    }

    async fn open_url_in_app(&self, url: &str) -> Result<(), ToolError> {
        let conn = self.pool.get().map_err(|e| ToolError::Internal {
            message: format!("Failed to get DB connection: {e}"),
        })?;

        let tokens = DeviceTokenRepo::get_all_active(&conn).map_err(|e| ToolError::Internal {
            message: format!("Failed to query device tokens: {e}"),
        })?;

        if tokens.is_empty() {
            return Ok(());
        }

        let token_strings: Vec<String> = tokens.iter().map(|t| t.device_token.clone()).collect();

        // Send silent push with URL data
        let mut data = HashMap::new();
        let _ = data.insert("url".to_string(), url.to_string());

        let notif = ApnsNotification {
            title: String::new(),
            body: String::new(),
            data,
            priority: "normal".to_string(),
            sound: None,
            badge: None,
            thread_id: None,
        };

        let _ = self.apns.send_to_many(&token_strings, &notif).await;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_tools::traits::Notification;

    #[test]
    fn maps_notification_fields() {
        let notification = Notification {
            title: "Task Done".into(),
            body: "Your build completed".into(),
            priority: "high".into(),
            badge: Some(3),
            data: Some(serde_json::json!({"sessionId": "sess_1"})),
            sheet_content: None,
        };

        let apns = ApnsNotifyDelegate::to_apns_notification(&notification);
        assert_eq!(apns.title, "Task Done");
        assert_eq!(apns.body, "Your build completed");
        assert_eq!(apns.priority, "high");
        assert_eq!(apns.badge, Some(3));
        assert_eq!(apns.sound, Some("default".to_string()));
        assert_eq!(apns.data.get("sessionId").unwrap(), "sess_1");
    }

    #[test]
    fn maps_minimal_notification() {
        let notification = Notification {
            title: "T".into(),
            body: "B".into(),
            priority: "normal".into(),
            badge: None,
            data: None,
            sheet_content: None,
        };

        let apns = ApnsNotifyDelegate::to_apns_notification(&notification);
        assert_eq!(apns.title, "T");
        assert_eq!(apns.body, "B");
        assert!(apns.data.is_empty());
        assert_eq!(apns.badge, None);
    }

    #[test]
    fn maps_data_with_non_string_values() {
        let notification = Notification {
            title: "T".into(),
            body: "B".into(),
            priority: "normal".into(),
            badge: None,
            data: Some(serde_json::json!({"count": 42, "flag": true})),
            sheet_content: None,
        };

        let apns = ApnsNotifyDelegate::to_apns_notification(&notification);
        assert_eq!(apns.data.get("count").unwrap(), "42");
        assert_eq!(apns.data.get("flag").unwrap(), "true");
    }
}
