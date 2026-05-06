use super::*;

use crate::server::rpc::handlers::system as rpc_system;

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
        _ => Err(RpcError::Internal {
            message: format!("system method {method} is not engine-owned"),
        }),
    }
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
