//! codex app domain worker.
//!
//! This module owns canonical function execution for the codex app namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;

use super::*;

pub(crate) fn worker_module(
    deps: &EngineCapabilityDeps,
) -> crate::engine::Result<DomainWorkerModule> {
    super::domain_worker_module(
        "codex_app",
        contract::capabilities()?,
        Deps::from_engine(deps),
        super::codex_app_handler,
    )
}
#[derive(Clone)]
pub(crate) struct Deps {
    codex_app_server: Option<Arc<CodexAppServerManager>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &EngineCapabilityDeps) -> Self {
        Self {
            codex_app_server: deps.codex_app_server.clone(),
        }
    }
}

pub(super) async fn handle(
    method: &str,
    _invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    match method {
        "codex_app::status" => codex_app_status_value(deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("codex app method {method} is not engine-owned"),
        }),
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
