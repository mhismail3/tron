//! Long-running services that make engine primitives part of server runtime.
//!
//! Queue draining lives here so the engine's durable queue primitive is the
//! source of truth for delayed work. Client event delivery is handled directly
//! by `/engine` subscriptions over the stream primitive.
//! Runtime stream projection writes retained agent, auth/settings, session,
//! queue, and catalog changes into engine streams. The heartbeat service cleans
//! local external-worker capabilities so the live catalog reflects what can
//! actually run.

use std::time::Duration;

use crate::app::bootstrap::server::TronServer;
use queue_drainer::EngineQueueDrainerService;
use worker_heartbeat::ExternalWorkerHeartbeatService;

pub mod external_workers;
mod queue_drainer;
pub mod setup;
pub mod streams;
mod worker_heartbeat;

const EXTERNAL_WORKER_HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(90);

/// Runtime-owned engine services.
pub struct EngineRuntimeServices;

impl EngineRuntimeServices {
    /// Start engine services and register them with server shutdown.
    pub fn start(server: &TronServer) {
        let host = server.runtime_context().engine_host.clone();
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
