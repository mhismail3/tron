use super::*;

pub(super) async fn handle(
    method: &str,
    _invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    match method {
        "codexApp.status" => codex_app_status_value(deps).await,
        _ => Err(RpcError::Internal {
            message: format!("codex app method {method} is not engine-owned"),
        }),
    }
}

async fn codex_app_status_value(deps: &RpcEngineDeps) -> Result<Value, RpcError> {
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
    serde_json::to_value(manager.status().await).map_err(|error| RpcError::Internal {
        message: format!("Failed to encode Codex App Server status: {error}"),
    })
}
