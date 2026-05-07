use std::collections::BTreeMap;

use super::*;

use crate::server::rpc::handlers::system as rpc_system;
use crate::server::rpc::registry::MethodRegistry;
use crate::server::updater::{UpdaterState, read_update_state};

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
    allow_rpc_context: bool,
) -> Result<Value, RpcError> {
    let payload = &invocation.payload;
    match method {
        "system.ping" => ping_value(Some(payload)),
        "system.getInfo" => Ok(system_info_value(payload, deps, allow_rpc_context)),
        "system.getDiagnostics" => system_diagnostics_value(deps),
        "system.getUpdateStatus" => system_update_status_value(deps).await,
        _ => Err(RpcError::Internal {
            message: format!("system method {method} is not engine-owned"),
        }),
    }
}

fn system_diagnostics_value(deps: &RpcEngineDeps) -> Result<Value, RpcError> {
    let uptime = deps.server_start_time.elapsed().as_secs();
    let active_sessions = deps.orchestrator.active_session_count();
    let active_runs = deps.orchestrator.active_run_count();
    let mut registry = MethodRegistry::new();
    crate::server::rpc::handlers::register_all(&mut registry);
    let all_methods = registry.methods();
    let total_methods = all_methods.len();
    let mut by_group: BTreeMap<String, usize> = BTreeMap::new();
    for method in &all_methods {
        let prefix = method.split('.').next().unwrap_or(method).to_owned();
        *by_group.entry(prefix).or_insert(0) += 1;
    }
    Ok(json!({
        "server": {
            "version": env!("CARGO_PKG_VERSION"),
            "protocolVersion": rpc_system::CURRENT_PROTOCOL_VERSION,
            "minClientProtocolVersion": rpc_system::MIN_CLIENT_PROTOCOL_VERSION,
            "platform": std::env::consts::OS,
            "arch": std::env::consts::ARCH,
            "pid": std::process::id(),
            "uptimeSeconds": uptime,
            "origin": deps.rpc_context.origin.clone(),
        },
        "sessions": {
            "active": active_sessions,
            "activeRuns": active_runs,
        },
        "rpc": {
            "totalMethods": total_methods,
            "methodsByGroup": by_group,
            "methods": all_methods,
        },
        "timestamp": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
    }))
}

async fn system_update_status_value(deps: &RpcEngineDeps) -> Result<Value, RpcError> {
    let settings = deps.profile_runtime.current().settings.clone();
    let state_path = deps.updater_state_path.clone();
    let state = deps
        .rpc_context
        .run_blocking("system.getUpdateStatus.read_state", move || {
            read_update_state(&state_path).map_err(|error| RpcError::Internal {
                message: format!("read updater state: {error}"),
            })
        })
        .await?;
    Ok(build_status_value(
        env!("CARGO_PKG_VERSION"),
        &settings.server.update,
        &state,
    ))
}

fn build_status_value(
    current_version: &str,
    settings_update: &crate::settings::types::UpdateSettings,
    state: &UpdaterState,
) -> Value {
    json!({
        "currentVersion": current_version,
        "channel": settings_update.channel.as_str(),
        "frequency": settings_update.frequency.as_str(),
        "action": settings_update.action.as_str(),
        "enabled": settings_update.enabled,
        "lastCheckAt": state.last_check_at,
        "lastInstalledVersion": state.last_installed_version,
        "latestAvailableVersion": state.latest_available_version,
        "latestDownloadUrl": state.latest_download_url,
    })
}

fn ping_value(params: Option<&Value>) -> Result<Value, RpcError> {
    let client_protocol_raw = params
        .and_then(|p| p.get("protocolVersion"))
        .and_then(Value::as_u64)
        .ok_or_else(|| RpcError::InvalidParams {
            message: "system.ping requires numeric protocolVersion".into(),
        })?;
    let client_protocol =
        u32::try_from(client_protocol_raw).map_err(|_| RpcError::InvalidParams {
            message: "system.ping protocolVersion is too large".into(),
        })?;
    let client_version = params
        .and_then(|p| p.get("clientVersion"))
        .and_then(Value::as_str)
        .map(String::from);

    if client_protocol < rpc_system::MIN_CLIENT_PROTOCOL_VERSION {
        return Err(RpcError::Custom {
            code: CLIENT_VERSION_UNSUPPORTED.to_string(),
            message: format!(
                "Client protocol version {client_protocol} is below the minimum supported version \
                 {}. Please upgrade the Tron client.",
                rpc_system::MIN_CLIENT_PROTOCOL_VERSION
            ),
            details: Some(json!({
                "clientProtocolVersion": client_protocol,
                "minClientProtocolVersion": rpc_system::MIN_CLIENT_PROTOCOL_VERSION,
                "serverProtocolVersion": rpc_system::CURRENT_PROTOCOL_VERSION,
                "serverVersion": env!("CARGO_PKG_VERSION"),
                "clientVersion": client_version,
            })),
        });
    }

    Ok(json!({
        "pong": true,
        "timestamp": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        "serverVersion": env!("CARGO_PKG_VERSION"),
        "serverProtocolVersion": rpc_system::CURRENT_PROTOCOL_VERSION,
        "minClientProtocolVersion": rpc_system::MIN_CLIENT_PROTOCOL_VERSION,
        "compatible": true,
    }))
}

fn system_info_value(payload: &Value, deps: &RpcEngineDeps, allow_rpc_context: bool) -> Value {
    let marker_path = allow_rpc_context
        .then(|| {
            payload
                .pointer("/__rpcContext/onboardedMarkerPath")
                .and_then(Value::as_str)
                .map(PathBuf::from)
        })
        .flatten()
        .unwrap_or_else(|| deps.onboarded_marker_path.clone());
    json!({
        "version": env!("CARGO_PKG_VERSION"),
        "uptime": deps.server_start_time.elapsed().as_secs(),
        "activeSessions": deps.orchestrator.active_session_count(),
        "platform": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "runtime": "agent",
        "port": deps.ws_port.load(Ordering::SeqCst),
        "tailscaleIp": deps.profile_runtime.current().settings.server.tailscale_ip,
        "paired": crate::server::onboarding::is_onboarded(&marker_path),
    })
}
