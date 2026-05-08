//! Long-running services that make engine primitives part of server runtime.
//!
//! Queue draining lives here so the engine's durable queue primitive is the
//! source of truth for delayed work. Client event delivery is handled directly
//! by `/engine` subscriptions over the stream primitive.
//! The `agent` queue drains hidden prompt apply/drain functions so startup and
//! queued follow-up prompts run through canonical engine functions. The stream pump now owns the migrated
//! broadcast topics for approvals, auth/settings/MCP/device/cron/update/memory
//! status, jobs, agent queue, session events, sandbox/display lifecycle, and
//! catalog changes. The heartbeat service unregisters stale volatile local
//! external-worker capabilities so the live catalog reflects what can actually
//! run.

use std::time::Duration;

use crate::engine::{EngineHostHandle, EngineQueueDrainer};
use crate::server::server::TronServer;
use tokio_util::sync::CancellationToken;

const QUEUE_DRAIN_INTERVAL: Duration = Duration::from_millis(100);
const EXTERNAL_WORKER_HEARTBEAT_SCAN_INTERVAL: Duration = Duration::from_secs(10);
const EXTERNAL_WORKER_HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(90);

/// Runtime-owned engine services.
pub struct EngineRuntimeServices;

impl EngineRuntimeServices {
    /// Start engine services and register them with server shutdown.
    pub fn start(server: &TronServer) {
        let host = server.capability_context().engine_host.clone();
        let shutdown = server.shutdown().clone();
        for queue in ["default", "jobs", "agent"] {
            let service = EngineQueueDrainerService::new(
                host.clone(),
                queue.to_owned(),
                "tron-server".to_owned(),
                shutdown.token(),
            );
            shutdown.register_task(tokio::spawn(service.run()));
        }

        let heartbeat = ExternalWorkerHeartbeatService::new(
            server.external_workers().clone(),
            shutdown.token(),
            EXTERNAL_WORKER_HEARTBEAT_TIMEOUT,
        );
        shutdown.register_task(tokio::spawn(heartbeat.run()));
    }
}

struct EngineQueueDrainerService {
    host: EngineHostHandle,
    queue: String,
    lease_owner: String,
    cancel: CancellationToken,
}

struct ExternalWorkerHeartbeatService {
    runtime: crate::server::external_workers::SharedExternalWorkerRuntime,
    cancel: CancellationToken,
    timeout: Duration,
}

impl ExternalWorkerHeartbeatService {
    fn new(
        runtime: crate::server::external_workers::SharedExternalWorkerRuntime,
        cancel: CancellationToken,
        timeout: Duration,
    ) -> Self {
        Self {
            runtime,
            cancel,
            timeout,
        }
    }

    async fn run(self) {
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

impl EngineQueueDrainerService {
    fn new(
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

    async fn run(self) {
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
