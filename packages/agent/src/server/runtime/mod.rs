//! Long-running services that make engine primitives part of server runtime.
//!
//! Queue draining lives here so the engine's durable queue primitive is the
//! source of truth for delayed work. Client event delivery is handled directly
//! by `/engine` subscriptions over the stream primitive.
//! The `agent` queue drains hidden prompt apply/drain functions so startup and
//! queued follow-up prompts run through canonical engine functions. The stream projection service owns the migrated
//! broadcast topics for approvals, auth/settings/MCP/device/cron/update/memory
//! status, jobs, agent queue, session events, sandbox/display lifecycle, and
//! catalog changes. The heartbeat service unregisters stale volatile local
//! external-worker capabilities so the live catalog reflects what can actually
//! run.

use std::time::Duration;

use crate::server::server::TronServer;
use queue_drainer::EngineQueueDrainerService;
use worker_heartbeat::ExternalWorkerHeartbeatService;

pub mod external_workers;
mod queue_drainer;
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
