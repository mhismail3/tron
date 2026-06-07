//! system domain worker.
//!
//! This module owns canonical function execution for the system namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use std::collections::BTreeMap;

use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::shared::server::errors::CLIENT_VERSION_UNSUPPORTED;
use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use serde_json::json;
use std::path::PathBuf;
use std::sync::atomic::Ordering;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "system",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

use crate::shared::server::protocol as engine_transport_protocol;

async fn system_shutdown_value(deps: &Deps) -> Result<Value, CapabilityError> {
    deps.orchestrator
        .shutdown()
        .await
        .map_err(|error| CapabilityError::Internal {
            message: error.to_string(),
        })?;
    Ok(json!({ "acknowledged": true }))
}

fn system_diagnostics_value(deps: &Deps) -> Result<Value, CapabilityError> {
    let uptime = deps.server_start_time.elapsed().as_secs();
    let active_sessions = deps.orchestrator.active_session_count();
    let active_runs = deps.orchestrator.active_run_count();
    let transport_messages = ["discover", "inspect", "watch", "invoke", "promote"]
        .into_iter()
        .map(ToOwned::to_owned)
        .collect::<Vec<_>>();
    let total_messages = transport_messages.len();
    let mut by_group: BTreeMap<String, usize> = BTreeMap::new();
    for method in &transport_messages {
        let prefix = method.split('.').next().unwrap_or(method).to_owned();
        *by_group.entry(prefix).or_insert(0) += 1;
    }
    let canonical_functions = super::catalog::canonical_capability_specs()
        .map(|specs| specs.len())
        .unwrap_or_default();
    let domain_workers = super::catalog::canonical_capability_specs()
        .map(|specs| {
            specs
                .into_iter()
                .map(|spec| spec.owner_worker.as_str().to_owned())
                .collect::<std::collections::BTreeSet<_>>()
                .len()
        })
        .unwrap_or_default();
    Ok(json!({
        "server": {
            "version": env!("CARGO_PKG_VERSION"),
            "protocolVersion": engine_transport_protocol::CURRENT_PROTOCOL_VERSION,
            "minClientProtocolVersion": engine_transport_protocol::MIN_CLIENT_PROTOCOL_VERSION,
            "platform": std::env::consts::OS,
            "arch": std::env::consts::ARCH,
            "pid": std::process::id(),
            "uptimeSeconds": uptime,
            "origin": deps.origin.clone(),
        },
        "sessions": {
            "active": active_sessions,
            "activeRuns": active_runs,
        },
        "engine": {
            "canonicalFunctions": canonical_functions,
            "workers": domain_workers,
        },
        "transport": {
            "totalMessages": total_messages,
            "messagesByGroup": by_group,
            "messages": transport_messages,
        },
        "timestamp": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
    }))
}

fn ping_value(params: Option<&Value>) -> Result<Value, CapabilityError> {
    let client_protocol_raw = params
        .and_then(|p| p.get("protocolVersion"))
        .and_then(Value::as_u64)
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: "system::ping requires numeric protocolVersion".into(),
        })?;
    let client_protocol =
        u32::try_from(client_protocol_raw).map_err(|_| CapabilityError::InvalidParams {
            message: "system::ping protocolVersion is too large".into(),
        })?;
    let client_version = params
        .and_then(|p| p.get("clientVersion"))
        .and_then(Value::as_str)
        .map(String::from);

    if client_protocol < engine_transport_protocol::MIN_CLIENT_PROTOCOL_VERSION {
        return Err(CapabilityError::Custom {
            code: CLIENT_VERSION_UNSUPPORTED.to_string(),
            message: format!(
                "Client protocol version {client_protocol} is below the minimum supported version \
                 {}. Please upgrade the Tron client.",
                engine_transport_protocol::MIN_CLIENT_PROTOCOL_VERSION
            ),
            details: Some(json!({
                "clientProtocolVersion": client_protocol,
                "minClientProtocolVersion": engine_transport_protocol::MIN_CLIENT_PROTOCOL_VERSION,
                "serverProtocolVersion": engine_transport_protocol::CURRENT_PROTOCOL_VERSION,
                "serverVersion": env!("CARGO_PKG_VERSION"),
                "clientVersion": client_version,
            })),
        });
    }

    Ok(json!({
        "pong": true,
        "timestamp": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        "serverVersion": env!("CARGO_PKG_VERSION"),
        "serverProtocolVersion": engine_transport_protocol::CURRENT_PROTOCOL_VERSION,
        "minClientProtocolVersion": engine_transport_protocol::MIN_CLIENT_PROTOCOL_VERSION,
        "compatible": true,
    }))
}

fn system_info_value(payload: &Value, deps: &Deps, allow_server_context: bool) -> Value {
    let marker_path = allow_server_context
        .then(|| {
            payload
                .pointer("/__capabilityContext/onboardedMarkerPath")
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
        "paired": crate::app::onboarding::is_onboarded(&marker_path),
    })
}
