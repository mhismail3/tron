use std::collections::BTreeMap;

use super::*;

use crate::server::transport::protocol as engine_transport_protocol;
use crate::server::updater::{UpdateDecision, UpdaterState, check_for_update, read_update_state};

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
    allow_capability_context: bool,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "system::ping" => ping_value(Some(payload)),
        "system::get_info" => Ok(system_info_value(payload, deps, allow_capability_context)),
        "system::get_diagnostics" => system_diagnostics_value(deps),
        "system::get_update_status" => system_update_status_value(deps).await,
        "system::check_for_updates" => system_check_for_updates_value(deps).await,
        "system::shutdown" => system_shutdown_value(deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("system method {method} is not engine-owned"),
        }),
    }
}

async fn system_shutdown_value(deps: &EngineCapabilityDeps) -> Result<Value, CapabilityError> {
    deps.orchestrator
        .shutdown()
        .await
        .map_err(|error| CapabilityError::Internal {
            message: error.to_string(),
        })?;
    Ok(json!({ "acknowledged": true }))
}

async fn system_check_for_updates_value(
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    let settings = deps.profile_runtime.current().settings.clone();
    let update_cfg = &settings.server.update;

    if !update_cfg.enabled {
        return Ok(json!({
            "available": false,
            "disabled": true,
            "channel": update_cfg.channel.as_str(),
            "currentVersion": env!("CARGO_PKG_VERSION"),
        }));
    }

    let Some(fetcher) = deps.capability_context.release_fetcher.as_ref() else {
        tracing::warn!(
            "system.checkForUpdates called but ServerCapabilityContext::release_fetcher is None; \
             responding as if no release was found"
        );
        return Ok(json!({
            "available": false,
            "disabled": false,
            "channel": update_cfg.channel.as_str(),
            "currentVersion": env!("CARGO_PKG_VERSION"),
            "unavailableReason": "fetcher-unwired",
        }));
    };

    let outcome = check_for_update(
        env!("CARGO_PKG_VERSION"),
        update_cfg.channel,
        fetcher.as_ref(),
    )
    .await
    .map_err(|error| CapabilityError::Internal {
        message: format!("release check failed: {error}"),
    })?;

    let available = matches!(outcome.decision, UpdateDecision::Available);
    Ok(json!({
        "available": available,
        "disabled": false,
        "channel": update_cfg.channel.as_str(),
        "currentVersion": outcome.current_version,
        "latestVersion": outcome.latest.as_ref().map(|release| release.version.clone()),
        "downloadUrl": outcome.latest.as_ref().and_then(|release| release.download_url.clone()),
        "releaseNotes": outcome.latest.as_ref().and_then(|release| release.release_notes.clone()),
        "isPrerelease": outcome.latest.as_ref().map(|release| release.is_prerelease),
    }))
}

fn system_diagnostics_value(deps: &EngineCapabilityDeps) -> Result<Value, CapabilityError> {
    let uptime = deps.server_start_time.elapsed().as_secs();
    let active_sessions = deps.orchestrator.active_session_count();
    let active_runs = deps.orchestrator.active_run_count();
    let transport_messages = super::catalog::public_engine_transport_methods()
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
    let domain_workers = super::catalog::domain_workers()
        .map(|workers| workers.len())
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
            "origin": deps.capability_context.origin.clone(),
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

async fn system_update_status_value(deps: &EngineCapabilityDeps) -> Result<Value, CapabilityError> {
    let settings = deps.profile_runtime.current().settings.clone();
    let state_path = deps.updater_state_path.clone();
    let state = deps
        .capability_context
        .run_blocking("system.getUpdateStatus.read_state", move || {
            read_update_state(&state_path).map_err(|error| CapabilityError::Internal {
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

fn system_info_value(
    payload: &Value,
    deps: &EngineCapabilityDeps,
    allow_capability_context: bool,
) -> Value {
    let marker_path = allow_capability_context
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
        "paired": crate::server::onboarding::is_onboarded(&marker_path),
    })
}
