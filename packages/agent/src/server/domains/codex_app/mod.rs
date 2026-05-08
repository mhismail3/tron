//! codex app domain worker.
//!
//! This module owns canonical function execution for the codex app namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;
pub(super) use handlers::handle;

use super::*;

pub(crate) fn worker_module(
    deps: &DomainSetupContext,
) -> crate::engine::Result<DomainWorkerModule> {
    super::domain_worker_module(
        "codex_app",
        contract::STREAM_TOPICS,
        contract::capabilities()?,
        Deps::from_engine(deps),
        super::codex_app_handler,
    )
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
