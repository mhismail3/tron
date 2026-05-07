//! Server-owned cron callbacks.
//!
//! The cron scheduler owns automation semantics. This module projects cron
//! domain callbacks onto server surfaces such as WebSocket events and APNS
//! pushes, keeping `cron` independent of `server`.

use std::sync::Arc;

use async_trait::async_trait;

use crate::cron::errors::CronError;
use crate::cron::types::{CronJob, CronRun};
use crate::server::transport::json_rpc::types::JsonRpcEvent;
use crate::server::websocket::broadcast::BroadcastManager;

#[cfg(feature = "apns")]
use crate::events::ConnectionPool;
#[cfg(feature = "apns")]
use crate::server::platform::apns::{ApnsBatch, ApnsNotification};
#[cfg(feature = "apns")]
use std::collections::HashMap;

/// Sends push notifications for cron job results via any APNS transport.
#[cfg(feature = "apns")]
pub struct CronPushNotifier {
    sender: Arc<dyn crate::server::platform::apns::PushSender>,
    pool: ConnectionPool,
}

#[cfg(feature = "apns")]
impl CronPushNotifier {
    /// Create a new notifier with a push sender and DB pool for device tokens.
    pub fn new(
        sender: Arc<dyn crate::server::platform::apns::PushSender>,
        pool: ConnectionPool,
    ) -> Self {
        Self { sender, pool }
    }

    fn active_tokens(
        &self,
    ) -> Result<Vec<crate::events::sqlite::row_types::DeviceTokenRow>, CronError> {
        let conn = self
            .pool
            .get()
            .map_err(|e| CronError::Execution(format!("DB connection: {e}")))?;
        crate::events::sqlite::repositories::device_token::DeviceTokenRepo::get_all_active(&conn)
            .map_err(|e| CronError::Execution(format!("query device tokens: {e}")))
    }
}

#[cfg(feature = "apns")]
#[async_trait]
impl crate::cron::executor::PushNotifier for CronPushNotifier {
    async fn notify(&self, title: &str, body: &str) -> Result<(), CronError> {
        let rows = self.active_tokens()?;
        if rows.is_empty() {
            tracing::debug!("cron push: no active device tokens");
            return Ok(());
        }

        let notification = ApnsNotification {
            title: title.to_owned(),
            body: body.to_owned(),
            data: HashMap::new(),
            priority: "normal".to_owned(),
            sound: Some("default".to_owned()),
            badge: None,
            thread_id: Some("cron".to_owned()),
        };

        let mut groups: HashMap<(String, String), Vec<String>> = HashMap::new();
        for row in &rows {
            groups
                .entry((row.environment.clone(), row.bundle_id.clone()))
                .or_default()
                .push(row.device_token.clone());
        }

        let mut total_failed = 0;
        let mut total_sent = 0;
        for ((env, bundle_id), tokens) in &groups {
            let batch = ApnsBatch {
                device_tokens: tokens,
                environment: env,
                bundle_id,
            };
            let results = self.sender.send_to_many(&batch, &notification).await;
            total_sent += results.len();
            total_failed += results.iter().filter(|r| !r.success).count();
        }
        if total_failed > 0 {
            tracing::warn!(
                total = total_sent,
                failed = total_failed,
                "cron push: some notifications failed"
            );
        }
        Ok(())
    }
}

/// Broadcasts cron events to all connected WebSocket clients.
pub struct CronEventBroadcaster {
    broadcast: Arc<BroadcastManager>,
}

impl CronEventBroadcaster {
    /// Create a new broadcaster.
    pub fn new(broadcast: Arc<BroadcastManager>) -> Self {
        Self { broadcast }
    }
}

#[async_trait]
impl crate::cron::executor::EventBroadcaster for CronEventBroadcaster {
    async fn broadcast_cron_result(&self, job: &CronJob, run: &CronRun) {
        let event = JsonRpcEvent {
            event_type: "cron.runComplete".to_owned(),
            session_id: None,
            timestamp: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            data: Some(serde_json::json!({
                "jobId": job.id,
                "jobName": job.name,
                "runId": run.id,
                "status": serde_json::to_value(&run.status).unwrap_or_default(),
                "durationMs": run.duration_ms,
                "error": run.error,
            })),
            run_id: Some(run.id.clone()),
            sequence: None,
        };
        self.broadcast.broadcast_all(&event).await;
    }

    async fn broadcast_cron_event(&self, event_type: &str, payload: serde_json::Value) {
        let event = JsonRpcEvent {
            event_type: event_type.to_owned(),
            session_id: None,
            timestamp: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            data: Some(payload),
            run_id: None,
            sequence: None,
        };
        self.broadcast.broadcast_all(&event).await;
    }
}
