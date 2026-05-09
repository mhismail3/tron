//! codex app domain worker.
//!
//! This module owns canonical function execution for the codex app namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use serde_json::json;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "codex_app",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

async fn codex_app_status_value(deps: &Deps) -> Result<Value, CapabilityError> {
    let Some(manager) = &deps.codex_app_server else {
        return Ok(json!({
            "enabled": false,
            "state": "disabled",
            "endpoint": null,
            "defaults": {
                "preferredCwd": null,
                "preferredModel": null,
                "approvalPolicy": "onRequest",
                "sandboxMode": "workspaceWrite"
            },
            "listenUrl": "ws://0.0.0.0:4500",
            "pid": null,
            "lastError": "Codex App Server lifecycle manager is unavailable"
        }));
    };
    serde_json::to_value(manager.status().await).map_err(|error| CapabilityError::Internal {
        message: format!("Failed to encode Codex App Server status: {error}"),
    })
}
