//! Engine queue drainer service.

use std::time::Duration;

use crate::engine::{EngineHostHandle, EngineQueueDrainer};
use tokio_util::sync::CancellationToken;

const QUEUE_DRAIN_INTERVAL: Duration = Duration::from_millis(100);

pub(super) struct EngineQueueDrainerService {
    host: EngineHostHandle,
    queue: String,
    lease_owner: String,
    cancel: CancellationToken,
}

impl EngineQueueDrainerService {
    pub(super) fn new(
        host: EngineHostHandle,
        queue: String,
        lease_owner: String,
        cancel: CancellationToken,
    ) -> Self {
        Self {
            host,
            queue,
            lease_owner,
            cancel,
        }
    }

    pub(super) async fn run(self) {
        loop {
            tokio::select! {
                () = self.cancel.cancelled() => break,
                () = async {
                    match EngineQueueDrainer::drain_once(&self.host, &self.queue, &self.lease_owner).await {
                        Ok(Some(result)) => {
                            if let Some(error) = result.error {
                                tracing::warn!(queue = %self.queue, error = %error, "engine queue item failed");
                            }
                        }
                        Ok(None) => tokio::time::sleep(QUEUE_DRAIN_INTERVAL).await,
                        Err(error) => {
                            tracing::warn!(queue = %self.queue, error = %error, "engine queue drainer failed");
                            tokio::time::sleep(QUEUE_DRAIN_INTERVAL).await;
                        }
                    }
                } => {}
            }
        }
    }
}
