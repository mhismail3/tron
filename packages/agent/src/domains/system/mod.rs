//! system domain worker.
//!
//! This module owns the small system namespace end-to-end: contract metadata,
//! registration dependencies, handler binding, and operation execution.

use crate::domains::agent::runner::orchestrator::orchestrator::Orchestrator;
use crate::domains::agent::runner::profile_runtime::ProfileRuntime;
use crate::domains::bindings::operation_bindings;
use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
};
use crate::shared::server::errors::CLIENT_VERSION_UNSUPPORTED;
use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use serde_json::json;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::AtomicU16;
use std::sync::atomic::Ordering;
use std::time::Instant;

const STREAM_TOPICS: &[&str] = &["system.status"];

#[derive(Clone)]
pub(crate) struct Deps {
    onboarded_marker_path: PathBuf,
    orchestrator: Arc<Orchestrator>,
    profile_runtime: Arc<ProfileRuntime>,
    server_start_time: Instant,
    ws_port: Arc<AtomicU16>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            onboarded_marker_path: deps.onboarded_marker_path.clone(),
            orchestrator: deps.orchestrator.clone(),
            profile_runtime: deps.profile_runtime.clone(),
            server_start_time: deps.server_start_time,
            ws_port: deps.ws_port.clone(),
        }
    }
}

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "system",
            STREAM_TOPICS,
            function_registrations(capabilities()?, domain_deps)?,
        )
    }
}

use crate::shared::server::protocol as engine_transport_protocol;

pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            "system::ping",
            "system",
            EffectClass::PureRead,
            RiskLevel::Low,
            Some("system.read"),
        )
        .request_schema(json!({"additionalProperties":false,"properties":{"clientVersion":{"type":"string"},"protocolVersion":{"type":"integer"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["protocolVersion"],"type":"object"}))
        .response_schema(json!({"additionalProperties":false,"properties":{"compatible":{"type":"boolean"},"minClientProtocolVersion":{"type":"integer"},"pong":{"type":"boolean"},"serverProtocolVersion":{"type":"integer"},"serverVersion":{"type":"string"},"timestamp":{"type":"string"}},"required":["pong","timestamp","serverVersion","serverProtocolVersion","minClientProtocolVersion","compatible"],"type":"object"}))
        .build()?,
        CapabilityContract::new(
            "system::get_info",
            "system",
            EffectClass::PureRead,
            RiskLevel::Low,
            Some("system.read"),
        )
        .request_schema(json!({"additionalProperties":false,"properties":{"__capabilityContext":{"additionalProperties":false,"properties":{"onboardedMarkerPath":{"type":"string"}},"type":"object"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
        .response_schema(json!({"additionalProperties":false,"properties":{"activeSessions":{"type":"integer"},"arch":{"type":"string"},"paired":{"type":"boolean"},"platform":{"type":"string"},"port":{"type":"integer"},"runtime":{"type":"string"},"tailscaleIp":{"type":["string","null"]},"uptime":{"type":"integer"},"version":{"type":"string"}},"required":["version","uptime","activeSessions","platform","arch","runtime","port","tailscaleIp","paired"],"type":"object"}))
        .build()?,
        CapabilityContract::new(
            "system::shutdown",
            "system",
            EffectClass::IrreversibleSideEffect,
            RiskLevel::Critical,
            Some("system.write"),
        )
        .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
        .response_schema(json!({"additionalProperties":false,"properties":{"acknowledged":{"type":"boolean"}},"required":["acknowledged"],"type":"object"}))
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .resource_lease(ResourceLeaseRequirement::exclusive_template("system", "system:shutdown", 60000))
        .compensation(CompensationContract::new(
            CompensationKind::ExternalIrreversible,
            "shutdown is irreversible for the current process; restart Tron manually",
        ))
        .stream_topics(STREAM_TOPICS.to_vec())
        .build()?,
    ])
}

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "ping" => |invocation, _deps| {
            ping_value(Some(&invocation.payload))
        },
        "get_info" => |invocation, deps| {
            let allow_server_context = matches!(
                invocation.causal_context.actor_kind,
                crate::engine::ActorKind::Client
            );
            Ok(system_info_value(&invocation.payload, deps, allow_server_context))
        },
        "shutdown" => |_invocation, deps| {
            system_shutdown_value(deps).await
        },
    ];
}

async fn system_shutdown_value(deps: &Deps) -> Result<Value, CapabilityError> {
    deps.orchestrator
        .shutdown()
        .await
        .map_err(|error| CapabilityError::Internal {
            message: error.to_string(),
        })?;
    Ok(json!({ "acknowledged": true }))
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
        "paired": crate::app::lifecycle::onboarding::is_onboarded(&marker_path),
    })
}
