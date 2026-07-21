//! Engine client protocol contracts.
//!
//! Public `/engine` message types are worker/client transport bindings over
//! engine-owned functions. They are not model-facing primitives; domain workers do
//! not own these message contracts.

use serde_json::json;

use crate::domains::registration::catalog::{CapabilitySpec, TransportIdempotencyMode};
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{
    EffectClass, EngineError, IdempotencyContract, Result as EngineResult, RiskLevel,
};

const PUBLIC_ENGINE_TRANSPORT_METHODS: &[&str] =
    &["discover", "inspect", "watch", "invoke", "promote"];

/// Public `/engine` client protocol methods.
pub fn public_engine_transport_methods() -> impl Iterator<Item = &'static str> {
    PUBLIC_ENGINE_TRANSPORT_METHODS.iter().copied()
}

/// Build and validate the public `/engine` client protocol method set.
pub fn public_engine_transport_specs() -> EngineResult<Vec<CapabilitySpec>> {
    let specs = vec![
        public_spec("discover", "engine::discover", EffectClass::PureRead, RiskLevel::Low)
            .request_schema(json!({"additionalProperties":false,"properties":{"effectClass":{"type":"string"},"health":{"type":"string"},"maxRisk":{"type":"string"},"namespacePrefix":{"type":"string"},"text":{"type":"string"},"visibility":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"functions":{"items":{"type":"object"},"type":"array"}},"required":["functions"],"type":"object"}))
            .build()?,
        public_spec("inspect", "engine::inspect", EffectClass::PureRead, RiskLevel::Low)
            .request_schema(json!({"additionalProperties":false,"properties":{"id":{"type":"string"},"kind":{"enum":["function","worker"],"type":"string"}},"required":["kind","id"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"definition":{"type":"object"},"kind":{"type":"string"}},"required":["kind","definition"],"type":"object"}))
            .build()?,
        public_spec("watch", "engine::watch", EffectClass::PureRead, RiskLevel::Low)
            .request_schema(json!({"additionalProperties":false,"properties":{"cursor":{"type":"integer"},"topic":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"events":{"items":{"type":"object"},"type":"array"},"nextCursor":{"type":"integer"}},"required":["events","nextCursor"],"type":"object"}))
            .build()?,
        public_spec(
            "invoke",
            "engine::invoke",
            EffectClass::DelegatedInvocation,
            RiskLevel::Low,
        )
        .request_schema(json!({"additionalProperties":false,"properties":{"context":{"additionalProperties":false,"properties":{"parentInvocationId":{"type":"string"},"sessionId":{"type":"string"},"traceId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"},"functionId":{"type":"string"},"idempotencyKey":{"type":"string"},"payload":{"additionalProperties":true,"type":"object"}},"required":["functionId"],"type":"object"}))
        .response_schema(json!({"additionalProperties":false,"properties":{"child":{"additionalProperties":false,"properties":{"error":{"type":"object"},"functionId":{"type":"string"},"invocationId":{"type":"string"},"replayedFrom":{"type":"string"},"traceId":{"type":"string"},"value":{}},"type":"object"}},"required":["child"],"type":"object"}))
        .build()?,
        public_spec(
            "promote",
            "engine::promote",
            EffectClass::IdempotentWrite,
            RiskLevel::Medium,
        )
        .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
        .request_schema(json!({"additionalProperties":false,"properties":{"functionId":{"type":"string"},"idempotencyKey":{"type":"string"},"targetVisibility":{"type":"string"},"workspaceId":{"type":"string"}},"required":["functionId","targetVisibility","idempotencyKey"],"type":"object"}))
        .response_schema(json!({"additionalProperties":false,"properties":{"functionId":{"type":"string"},"revision":{"type":"integer"},"visibility":{"enum":["workspace","system"],"type":"string"}},"required":["functionId","revision","visibility"],"type":"object"}))
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .compensation(crate::engine::CompensationContract::new(
            crate::engine::CompensationKind::InverseCommandAvailable,
            "domain-specific tests preserve current rollback, no-op, or replay behavior",
        ))
        .build()?,
    ];
    for spec in &specs {
        if spec.visibility.is_agent_visible()
            && spec.effect_class.is_mutating()
            && spec.idempotency_mode == TransportIdempotencyMode::NotRequired
        {
            return Err(EngineError::PolicyViolation(format!(
                "agent-visible public engine transport method {} lacks idempotency",
                spec.operation_key.as_str()
            )));
        }
        if spec.request_schema.is_none() || spec.response_schema.is_none() {
            return Err(EngineError::PolicyViolation(format!(
                "public engine transport method {} must declare strict request/response schemas",
                spec.operation_key.as_str()
            )));
        }
        if spec.effect_class.is_mutating() && spec.authority_scope.is_none() {
            return Err(EngineError::PolicyViolation(format!(
                "mutating public engine transport method {} must require an authority scope",
                spec.operation_key.as_str()
            )));
        }
    }
    Ok(specs)
}

/// Find a public engine transport contract by message type.
pub(crate) fn public_engine_transport_spec_for_method(
    method: &str,
) -> EngineResult<Option<CapabilitySpec>> {
    public_engine_transport_specs().map(|specs| {
        specs
            .into_iter()
            .find(|candidate| candidate.operation_key.as_str() == method)
    })
}

fn public_spec(
    method: &'static str,
    function_id: &'static str,
    effect: EffectClass,
    risk: RiskLevel,
) -> CapabilityContract {
    CapabilityContract::new(method, "engine", effect, risk, Some(authority_for(effect)))
        .function_id(function_id)
        .domain_worker("engine")
        .domain_module("transport::engine::socket")
}

fn authority_for(effect: EffectClass) -> &'static str {
    if effect.is_mutating() {
        "engine.promote.workspace"
    } else {
        "engine.read"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn promote_transport_response_schema_matches_engine_promote_result() {
        let promote = public_engine_transport_specs()
            .expect("public specs")
            .into_iter()
            .find(|spec| spec.operation_key.as_str() == "promote")
            .expect("promote spec");
        let schema = promote.response_schema.expect("promote response schema");

        assert_eq!(
            schema["required"],
            json!(["functionId", "revision", "visibility"])
        );
        assert!(schema["properties"]["newVisibility"].is_null());
        assert!(schema["properties"]["promoted"].is_null());
    }

    #[test]
    fn invoke_transport_request_schema_matches_public_wire_context() {
        let invoke = public_engine_transport_specs()
            .expect("public specs")
            .into_iter()
            .find(|spec| spec.operation_key.as_str() == "invoke")
            .expect("invoke spec");
        let schema = invoke.request_schema.expect("invoke request schema");

        assert_eq!(schema["additionalProperties"], false);
        assert_eq!(
            schema["properties"]["context"]["additionalProperties"],
            false
        );
        assert_eq!(
            schema["properties"]["context"]["properties"],
            json!({
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"},
                "traceId": {"type": "string"},
                "parentInvocationId": {"type": "string"}
            })
        );
        for forbidden in [
            "authorityScopes",
            "runtimeMetadata",
            "actorKind",
            "actorId",
            "grantId",
            "workerId",
        ] {
            assert!(
                schema["properties"]["context"]["properties"][forbidden].is_null(),
                "public invoke context schema must not expose {forbidden}"
            );
        }
        assert_eq!(
            schema["properties"]["payload"]["additionalProperties"], true,
            "function payload remains target-defined while transport context is closed"
        );
    }

    #[test]
    fn invoke_transport_response_schema_excludes_child_runtime_metadata() {
        let invoke = public_engine_transport_specs()
            .expect("public specs")
            .into_iter()
            .find(|spec| spec.operation_key.as_str() == "invoke")
            .expect("invoke spec");
        let schema = invoke.response_schema.expect("invoke response schema");
        let child = &schema["properties"]["child"];

        assert_eq!(schema["additionalProperties"], false);
        assert_eq!(schema["required"], json!(["child"]));
        assert_eq!(child["additionalProperties"], false);
        for allowed in [
            "invocationId",
            "functionId",
            "traceId",
            "value",
            "error",
            "replayedFrom",
        ] {
            assert!(
                !child["properties"][allowed].is_null(),
                "public child schema missing {allowed}"
            );
        }
        for forbidden in ["workerId", "functionRevision", "catalogRevision"] {
            assert!(
                child["properties"][forbidden].is_null(),
                "public child schema must not expose {forbidden}"
            );
        }
    }
}
