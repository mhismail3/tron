//! Local external-worker heartbeat cleanup.

use std::time::Duration;

use tokio_util::sync::CancellationToken;

use super::external_workers::SharedExternalWorkerRuntime;

const EXTERNAL_WORKER_HEARTBEAT_SCAN_INTERVAL: Duration = Duration::from_secs(10);

pub(super) struct ExternalWorkerHeartbeatService {
    runtime: SharedExternalWorkerRuntime,
    cancel: CancellationToken,
    timeout: Duration,
}

impl ExternalWorkerHeartbeatService {
    pub(super) fn new(
        runtime: SharedExternalWorkerRuntime,
        cancel: CancellationToken,
        timeout: Duration,
    ) -> Self {
        Self {
            runtime,
            cancel,
            timeout,
        }
    }

    pub(super) async fn run(self) {
        loop {
            tokio::select! {
                () = self.cancel.cancelled() => break,
                () = tokio::time::sleep(EXTERNAL_WORKER_HEARTBEAT_SCAN_INTERVAL) => {
                    let result = self
                        .runtime
                        .lock()
                        .await
                        .disconnect_timed_out(self.timeout)
                        .await;
                    match result {
                        Ok(expired) if !expired.is_empty() => {
                            tracing::warn!(count = expired.len(), "external engine workers timed out");
                        }
                        Ok(_) => {}
                        Err(error) => tracing::warn!(error = %error, "external worker heartbeat cleanup failed"),
                    }
                }
            }
        }
    }
}
