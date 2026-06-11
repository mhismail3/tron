//! Worker schedule service.

use std::time::Duration;

use chrono::Utc;
use tokio_util::sync::CancellationToken;

use crate::engine::{EngineHostHandle, EngineWorkerScheduleRuntime};

const WORKER_SCHEDULE_POLL_CADENCE: Duration = Duration::from_secs(30);

pub(super) struct EngineWorkerScheduleService {
    runtime: EngineWorkerScheduleRuntime,
    cancel: CancellationToken,
}

impl EngineWorkerScheduleService {
    pub(super) fn new(host: EngineHostHandle, cancel: CancellationToken) -> Self {
        Self {
            runtime: EngineWorkerScheduleRuntime::new(host),
            cancel,
        }
    }

    pub(super) async fn run(self) {
        loop {
            tokio::select! {
                () = self.cancel.cancelled() => break,
                () = async {
                    if let Err(error) = self.runtime.dispatch_due_once(Utc::now()).await {
                        tracing::warn!(error = %error, "worker schedule dispatch poll failed");
                    }
                    tokio::time::sleep(WORKER_SCHEDULE_POLL_CADENCE).await;
                } => {}
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(start_paused = true)]
    async fn worker_schedule_dispatch_service_cancels_cleanly() {
        let host = EngineHostHandle::new_in_memory().expect("host should initialize");
        let cancel = CancellationToken::new();
        let service = EngineWorkerScheduleService::new(host, cancel.clone());
        let task = tokio::spawn(service.run());

        cancel.cancel();

        tokio::time::timeout(Duration::from_secs(1), task)
            .await
            .expect("scheduler task should observe cancellation")
            .expect("scheduler task should not panic");
    }
}
