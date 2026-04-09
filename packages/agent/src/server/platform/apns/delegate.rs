//! APNS-backed [`NotifyDelegate`] — sends real push notifications via Apple's
//! APNs HTTP/2 service.
//!
//! Maps the tool-level [`Notification`] to platform-level [`ApnsNotification`],
//! queries active device tokens from `SQLite`, and marks 410-expired tokens.

use std::sync::Arc;

use async_trait::async_trait;
use tracing::debug;
use crate::events::ConnectionPool;
use crate::server::platform::apns::{ApnsService, PushSender};
use crate::tools::errors::ToolError;
use crate::tools::traits::{Notification, NotifyDelegate, NotifyResult};

use super::push_helpers;

/// Real APNS notification delegate (direct .p8 signing + HTTP/2 to APNs).
pub struct ApnsNotifyDelegate {
    apns: Arc<ApnsService>,
    pool: ConnectionPool,
}

impl ApnsNotifyDelegate {
    /// Create a new delegate with the given APNS service and DB pool.
    pub fn new(apns: Arc<ApnsService>, pool: ConnectionPool) -> Self {
        Self { apns, pool }
    }
}

#[async_trait]
impl NotifyDelegate for ApnsNotifyDelegate {
    async fn send_notification(
        &self,
        notification: &Notification,
    ) -> Result<NotifyResult, ToolError> {
        let device_tokens = push_helpers::active_tokens(&self.pool)?;

        if device_tokens.is_empty() {
            debug!("No active device tokens — skipping APNS send");
            return Ok(NotifyResult {
                success: true,
                message: None,
                success_count: 0,
                total_count: 0,
            });
        }

        let apns_notif = push_helpers::to_apns_notification(notification);
        let total = device_tokens.len();
        let groups = push_helpers::group_by_environment(&device_tokens);

        debug!(
            device_count = total,
            environments = ?groups.keys().collect::<Vec<_>>(),
            title = %notification.title,
            "Sending APNS notification"
        );

        let mut all_results = Vec::with_capacity(total);
        for (env, tokens) in &groups {
            let owned: Vec<String> = tokens.iter().map(|t| t.to_string()).collect();
            let results = self.apns.send_to_many(&owned, &apns_notif, env).await;
            all_results.extend(results);
        }
        Ok(push_helpers::process_send_results(&all_results, &self.pool))
    }
}

#[cfg(test)]
mod tests {
    use crate::tools::traits::Notification;
    use crate::server::platform::apns::push_helpers::to_apns_notification;

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

        let apns = to_apns_notification(&notification);
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

        let apns = to_apns_notification(&notification);
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

        let apns = to_apns_notification(&notification);
        assert_eq!(apns.data.get("count").unwrap(), "42");
        assert_eq!(apns.data.get("flag").unwrap(), "true");
    }
}
