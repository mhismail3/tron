//! Module runtime maintenance services.

use std::time::Duration;

use crate::engine::EngineHostHandle;
use tokio_util::sync::CancellationToken;

pub(super) struct ModuleHealthMonitorService {
    host: EngineHostHandle,
    cancel: CancellationToken,
    interval: Duration,
}

impl ModuleHealthMonitorService {
    pub(super) fn new(
        host: EngineHostHandle,
        cancel: CancellationToken,
        interval: Duration,
    ) -> Self {
        Self {
            host,
            cancel,
            interval,
        }
    }

    pub(super) async fn run(self) {
        let mut interval = tokio::time::interval(self.interval);
        let _ = interval.tick().await;
        loop {
            tokio::select! {
                () = self.cancel.cancelled() => break,
                _ = interval.tick() => {
                    match self.host.enqueue_due_module_health_checks(chrono::Utc::now()).await {
                        Ok(count) if count > 0 => {
                            tracing::debug!(count, "enqueued module health checks");
                        }
                        Ok(_) => {}
                        Err(error) => {
                            tracing::warn!(error = %error, "module health monitor failed");
                        }
                    }
                    match self.host.enqueue_due_module_trust_audits(chrono::Utc::now()).await {
                        Ok(count) if count > 0 => {
                            tracing::debug!(count, "enqueued module trust audits");
                        }
                        Ok(_) => {}
                        Err(error) => {
                            tracing::warn!(error = %error, "module trust audit monitor failed");
                        }
                    }
                }
            }
        }
    }
}
