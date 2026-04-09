//! Relay-backed [`NotifyDelegate`] — sends push notifications via the Cloudflare
//! Worker relay instead of direct APNs.
//!
//! Structurally identical to [`ApnsNotifyDelegate`](super::delegate::ApnsNotifyDelegate),
//! but uses [`RelayClient`](super::relay::RelayClient) as the transport.

use std::sync::Arc;

use async_trait::async_trait;
use tracing::debug;

use crate::events::ConnectionPool;
use crate::tools::errors::ToolError;
use crate::tools::traits::{NotifyDelegate, NotifyResult};

use super::push_helpers;
use super::sender::PushSender;

/// Relay-backed notification delegate.
pub struct RelayNotifyDelegate {
    sender: Arc<dyn PushSender>,
    pool: ConnectionPool,
}

impl RelayNotifyDelegate {
    /// Create a new delegate with the given push sender and DB pool.
    pub fn new(sender: Arc<dyn PushSender>, pool: ConnectionPool) -> Self {
        Self { sender, pool }
    }
}

#[async_trait]
impl NotifyDelegate for RelayNotifyDelegate {
    async fn send_notification(
        &self,
        notification: &crate::tools::traits::Notification,
    ) -> Result<NotifyResult, ToolError> {
        let device_tokens = push_helpers::active_tokens(&self.pool)?;

        if device_tokens.is_empty() {
            debug!("No active device tokens — skipping relay send");
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
            "Sending notification via relay"
        );

        let mut all_results = Vec::with_capacity(total);
        for (env, tokens) in &groups {
            let owned: Vec<String> = tokens.iter().map(|t| t.to_string()).collect();
            let results = self.sender.send_to_many(&owned, &apns_notif, env).await;
            all_results.extend(results);
        }
        Ok(push_helpers::process_send_results(&all_results, &self.pool))
    }
}
