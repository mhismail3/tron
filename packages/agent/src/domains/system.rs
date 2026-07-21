//! system domain worker.
//!
//! This module owns the small system namespace end-to-end: contract metadata,
//! registration dependencies, handler binding, and operation execution.

use crate::domains::agent::r#loop::orchestrator::core::Orchestrator;
use crate::domains::registration::bindings::operation_bindings;
use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::domains::registration::worker::DomainRegistrationContext;
use crate::domains::registration::worker::DomainWorkerModule;
use crate::engine::{EffectClass, Result as EngineResult, RiskLevel};
use crate::shared::server::errors::CLIENT_VERSION_UNSUPPORTED;
use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;
use std::time::Instant;

#[derive(Clone)]
pub(crate) struct Deps {
    orchestrator: Arc<Orchestrator>,
    server_start_time: Instant,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            orchestrator: deps.orchestrator.clone(),
            server_start_time: deps.server_start_time,
        }
    }
}

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::registration::worker::domain_worker_module(
            "system",
            &[],
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
            RiskLevel::Low)
        .request_schema(json!({"additionalProperties":false,"properties":{"clientVersion":{"type":"string"},"protocolVersion":{"type":"integer"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["protocolVersion"],"type":"object"}))
        .response_schema(json!({"additionalProperties":false,"properties":{"compatible":{"type":"boolean"},"minClientProtocolVersion":{"type":"integer"},"pong":{"type":"boolean"},"serverProtocolVersion":{"type":"integer"},"serverVersion":{"type":"string"},"timestamp":{"type":"string"}},"required":["pong","timestamp","serverVersion","serverProtocolVersion","minClientProtocolVersion","compatible"],"type":"object"}))
        .build()?,
        CapabilityContract::new(
            "system::get_info",
            "system",
            EffectClass::PureRead,
            RiskLevel::Low)
        .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
        .response_schema(json!({"additionalProperties":false,"properties":{"activeSessions":{"type":"integer"},"uptime":{"type":"integer"},"version":{"type":"string"}},"required":["version","uptime","activeSessions"],"type":"object"}))
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
            let _ = invocation;
            Ok(system_info_value(deps))
        },
    ];
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

fn system_info_value(deps: &Deps) -> Value {
    json!({
        "version": env!("CARGO_PKG_VERSION"),
        "uptime": deps.server_start_time.elapsed().as_secs(),
        // A session is active while its projection remains in the orchestrator cache.
        "activeSessions": deps.orchestrator.cached_session_count(),
    })
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::*;

    #[test]
    fn get_info_contract_matches_the_production_projection() {
        let context = crate::shared::server::test_support::make_test_context();
        let registration = DomainRegistrationContext::from_context(&context);
        let value = system_info_value(&Deps::from_engine(&registration));
        let actual = value
            .as_object()
            .expect("system info object")
            .keys()
            .map(String::as_str)
            .collect::<BTreeSet<_>>();
        let expected = BTreeSet::from(["activeSessions", "uptime", "version"]);
        assert_eq!(actual, expected);

        let contract = capabilities()
            .expect("system contracts")
            .into_iter()
            .find(|spec| spec.operation_key == "get_info")
            .expect("system info contract");
        let schema = contract.response_schema.expect("response schema");
        let properties = schema["properties"]
            .as_object()
            .expect("response properties")
            .keys()
            .map(String::as_str)
            .collect::<BTreeSet<_>>();
        assert_eq!(properties, expected);
        assert_eq!(
            schema["required"],
            json!(["version", "uptime", "activeSessions"])
        );

        let function_ids = capabilities()
            .expect("system contracts")
            .into_iter()
            .map(|spec| spec.function_id.to_string())
            .collect::<BTreeSet<_>>();
        assert_eq!(
            function_ids,
            BTreeSet::from(["system::get_info".to_owned(), "system::ping".to_owned()])
        );
    }
}
