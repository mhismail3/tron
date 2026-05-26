//! Server-owned cron callbacks.
//!
//! The cron scheduler owns automation semantics. This module projects cron
//! domain callbacks onto engine stream events and APNS pushes, keeping `cron`
//! independent of client transports.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::json;

use crate::domains::cron::errors::CronError;
use crate::domains::cron::types::{CronJob, CronRun};
use crate::engine::{EngineHostHandle, PublishStreamEvent, VisibilityScope};
use crate::shared::server::events::ServerEventPayload;

#[cfg(feature = "apns")]
use crate::domains::session::event_store::ConnectionPool;
#[cfg(feature = "apns")]
use crate::platform::apns::{ApnsBatch, ApnsNotification};
#[cfg(feature = "apns")]
use std::collections::HashMap;

/// Sends push notifications for cron job results via any APNS transport.
#[cfg(feature = "apns")]
pub struct CronPushNotifier {
    sender: Arc<dyn crate::platform::apns::PushSender>,
    pool: ConnectionPool,
}

#[cfg(feature = "apns")]
impl CronPushNotifier {
    /// Create a new notifier with a push sender and DB pool for device tokens.
    pub fn new(sender: Arc<dyn crate::platform::apns::PushSender>, pool: ConnectionPool) -> Self {
        Self { sender, pool }
    }

    fn active_tokens(
        &self,
    ) -> Result<
        Vec<crate::domains::session::event_store::sqlite::row_types::DeviceTokenRow>,
        CronError,
    > {
        let conn = self
            .pool
            .get()
            .map_err(|e| CronError::Execution(format!("DB connection: {e}")))?;
        crate::domains::session::event_store::sqlite::repositories::device_token::DeviceTokenRepo::get_all_active(&conn)
            .map_err(|e| CronError::Execution(format!("query device tokens: {e}")))
    }
}

#[cfg(feature = "apns")]
#[async_trait]
impl crate::domains::cron::executor::PushNotifier for CronPushNotifier {
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

/// Publishes cron lifecycle events to engine streams.
pub struct CronEventPublisher {
    engine_host: EngineHostHandle,
}

impl CronEventPublisher {
    /// Create a new stream-backed cron event publisher.
    pub fn new(engine_host: EngineHostHandle) -> Self {
        Self { engine_host }
    }

    async fn publish(&self, event: ServerEventPayload) {
        if let Err(error) = self
            .engine_host
            .publish_stream_event(PublishStreamEvent {
                topic: crate::domains::cron::contract::STREAM_TOPICS[0].to_owned(),
                payload: json!({
                    "serverEvent": event.clone(),
                    "sourceEventType": event.event_type.clone(),
                }),
                visibility: VisibilityScope::System,
                session_id: None,
                workspace_id: None,
                producer: "cron".to_owned(),
                trace_id: None,
                parent_invocation_id: None,
            })
            .await
        {
            tracing::warn!(error = %error, "cron stream publication failed");
        }
    }
}

#[async_trait]
impl crate::domains::cron::executor::EventPublisher for CronEventPublisher {
    async fn publish_cron_result(&self, job: &CronJob, run: &CronRun) {
        if let Err(error) =
            crate::domains::cron::truth::attach_run_evidence(&self.engine_host, job, run).await
        {
            tracing::warn!(job_id = %job.id, run_id = %run.id, error = %error, "cron run evidence attachment failed");
        }
        let event = ServerEventPayload {
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
            workspace_id: None,
            trace_id: None,
            parent_invocation_id: None,
            source_event_id: None,
            source_sequence: None,
            stream_cursor: None,
        };
        self.publish(event).await;
    }

    async fn publish_cron_event(&self, event_type: &str, payload: serde_json::Value) {
        if event_type == "cron.jobAutoDisabled"
            && let Some(job_id) = payload.get("jobId").and_then(serde_json::Value::as_str)
            && let Err(error) = crate::domains::cron::truth::set_schedule_enabled(
                &self.engine_host,
                job_id,
                false,
                "auto-disabled after consecutive cron failures",
            )
            .await
        {
            tracing::error!(
                job_id,
                error = %error,
                "failed to disable auto-disabled cron schedule decision"
            );
        }
        let event = ServerEventPayload {
            event_type: event_type.to_owned(),
            session_id: None,
            timestamp: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            data: Some(payload),
            run_id: None,
            sequence: None,
            workspace_id: None,
            trace_id: None,
            parent_invocation_id: None,
            source_event_id: None,
            source_sequence: None,
            stream_cursor: None,
        };
        self.publish(event).await;
    }
}
