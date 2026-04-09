//! Shared helpers for push notification delegates.
//!
//! Extracted from [`ApnsNotifyDelegate`](super::delegate::ApnsNotifyDelegate) so both
//! the direct and relay delegates share identical token-query, notification-conversion,
//! and result-processing logic.

use std::collections::HashMap;

use tracing::debug;

use crate::events::ConnectionPool;
use crate::events::sqlite::repositories::device_token::DeviceTokenRepo;
use crate::tools::errors::ToolError;
use crate::tools::traits::{Notification, NotifyResult};

use super::types::{ApnsNotification, ApnsSendResult};

/// Return the first 8 bytes of a token for logging (UTF-8–safe).
pub(crate) fn token_prefix(token: &str) -> &str {
    crate::core::text::truncate_str(token, 8)
}

/// A device token with its APNs environment.
pub(crate) struct DeviceToken {
    pub token: String,
    pub environment: String,
}

/// Query all active device tokens from the database.
pub(crate) fn active_tokens(pool: &ConnectionPool) -> Result<Vec<DeviceToken>, ToolError> {
    let conn = pool
        .get()
        .map_err(|e| ToolError::internal(format!("Failed to get DB connection: {e}")))?;
    let tokens = DeviceTokenRepo::get_all_active(&conn)
        .map_err(|e| ToolError::internal(format!("Failed to query device tokens: {e}")))?;
    Ok(tokens
        .into_iter()
        .map(|t| DeviceToken {
            token: t.device_token,
            environment: t.environment,
        })
        .collect())
}

/// Group device tokens by environment.
pub(crate) fn group_by_environment(tokens: &[DeviceToken]) -> HashMap<&str, Vec<&str>> {
    let mut groups: HashMap<&str, Vec<&str>> = HashMap::new();
    for dt in tokens {
        groups.entry(&dt.environment).or_default().push(&dt.token);
    }
    groups
}

/// Convert a tool-level [`Notification`] to a platform-level [`ApnsNotification`].
pub(crate) fn to_apns_notification(notification: &Notification) -> ApnsNotification {
    let mut data = HashMap::new();

    if let Some(ref extra) = notification.data
        && let Some(obj) = extra.as_object()
    {
        for (k, v) in obj {
            let s = if let Some(s) = v.as_str() {
                s.to_string()
            } else {
                v.to_string()
            };
            let _ = data.insert(k.clone(), s);
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

/// Process send results: mark 410 tokens invalid, collect errors, build summary.
pub(crate) fn process_send_results(
    results: &[ApnsSendResult],
    pool: &ConnectionPool,
) -> NotifyResult {
    let total = results.len();
    let mut success_count = 0;
    let mut errors = Vec::new();

    for result in results {
        debug!(
            token_prefix = token_prefix(&result.device_token),
            token_len = result.device_token.len(),
            success = result.success,
            status = ?result.status_code,
            reason = ?result.reason,
            error = ?result.error,
            apns_id = ?result.apns_id,
            "push per-device result"
        );

        if result.success {
            success_count += 1;
        } else {
            if result.status_code == Some(410) {
                debug!(
                    device_token = token_prefix(&result.device_token),
                    "Marking expired token as invalid"
                );
                if let Ok(conn) = pool.get() {
                    let _ = DeviceTokenRepo::mark_invalid(&conn, &result.device_token);
                }
            }
            if let Some(ref err) = result.error {
                errors.push(format!(
                    "{}...(len={}): {}",
                    token_prefix(&result.device_token),
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

    debug!(
        success_count,
        error_count = errors.len(),
        total,
        message = %message,
        "push delivery summary"
    );

    #[allow(clippy::cast_possible_truncation)]
    NotifyResult {
        success: success_count > 0,
        message: Some(message),
        success_count: u32::try_from(success_count).unwrap_or(u32::MAX),
        total_count: u32::try_from(total).unwrap_or(u32::MAX),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::traits::Notification;

    #[test]
    fn to_apns_notification_maps_all_fields() {
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
    fn to_apns_notification_handles_missing_data() {
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
    fn to_apns_notification_converts_non_string_data_values() {
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

    #[test]
    fn process_results_all_success() {
        // Use a pool we can't actually connect to — process_send_results only
        // touches the pool for 410 cleanup, so all-success skips it.
        let manager = r2d2_sqlite::SqliteConnectionManager::memory();
        let pool = r2d2::Pool::new(manager).unwrap();

        let results = vec![
            ApnsSendResult {
                success: true,
                device_token: "aabb".into(),
                apns_id: Some("id1".into()),
                status_code: Some(200),
                reason: None,
                error: None,
            },
            ApnsSendResult {
                success: true,
                device_token: "ccdd".into(),
                apns_id: Some("id2".into()),
                status_code: Some(200),
                reason: None,
                error: None,
            },
        ];

        let result = process_send_results(&results, &pool);
        assert!(result.success);
        assert!(result.message.as_ref().unwrap().contains("2 of 2"));
        assert_eq!(result.success_count, 2);
        assert_eq!(result.total_count, 2);
    }

    #[test]
    fn process_results_all_failure() {
        let manager = r2d2_sqlite::SqliteConnectionManager::memory();
        let pool = r2d2::Pool::new(manager).unwrap();

        let results = vec![ApnsSendResult {
            success: false,
            device_token: "aabb".into(),
            apns_id: None,
            status_code: Some(400),
            reason: Some("BadDeviceToken".into()),
            error: Some("bad token".into()),
        }];

        let result = process_send_results(&results, &pool);
        assert!(!result.success);
        assert!(result.message.as_ref().unwrap().contains("0 of 1"));
        assert!(result.message.as_ref().unwrap().contains("bad token"));
        assert_eq!(result.success_count, 0);
        assert_eq!(result.total_count, 1);
    }

    #[test]
    fn process_results_mixed() {
        let manager = r2d2_sqlite::SqliteConnectionManager::memory();
        let pool = r2d2::Pool::new(manager).unwrap();

        let results = vec![
            ApnsSendResult {
                success: true,
                device_token: "aabb".into(),
                apns_id: Some("id1".into()),
                status_code: Some(200),
                reason: None,
                error: None,
            },
            ApnsSendResult {
                success: false,
                device_token: "ccdd".into(),
                apns_id: None,
                status_code: Some(500),
                reason: None,
                error: Some("server error".into()),
            },
        ];

        let result = process_send_results(&results, &pool);
        assert!(result.success); // at least one succeeded
        assert!(result.message.as_ref().unwrap().contains("1 of 2"));
        assert_eq!(result.success_count, 1);
        assert_eq!(result.total_count, 2);
    }
}
