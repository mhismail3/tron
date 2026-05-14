//! Capability contracts owned by the capability domain worker.
//!
//! This worker is the model-facing harness collapse point: providers see only
//! `search`, `inspect`, and `execute`, while actual behavior remains owned by
//! live domain/plugin workers in the engine catalog.

use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel, VisibilityScope,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["capability.runtime"];

pub(crate) const SEARCH_FUNCTION_ID: &str = "capability::search";
pub(crate) const INSPECT_FUNCTION_ID: &str = "capability::inspect";
pub(crate) const EXECUTE_FUNCTION_ID: &str = "capability::execute";
pub(crate) const STATUS_FUNCTION_ID: &str = "capability::status";
pub(crate) const REGISTRY_SNAPSHOT_FUNCTION_ID: &str = "capability::registry_snapshot";
pub(crate) const AUDIT_QUERY_FUNCTION_ID: &str = "capability::audit_query";
pub(crate) const BINDING_LIST_FUNCTION_ID: &str = "capability::binding_list";
pub(crate) const BINDING_SET_FUNCTION_ID: &str = "capability::binding_set";
pub(crate) const PLUGIN_LIST_FUNCTION_ID: &str = "capability::plugin_list";
pub(crate) const PLUGIN_INSPECT_FUNCTION_ID: &str = "capability::plugin_inspect";
pub(crate) const PLUGIN_INSTALL_FUNCTION_ID: &str = "capability::plugin_install";
pub(crate) const PLUGIN_UPDATE_FUNCTION_ID: &str = "capability::plugin_update";
pub(crate) const PLUGIN_SET_STATE_FUNCTION_ID: &str = "capability::plugin_set_state";
pub(crate) const PLUGIN_PROMOTE_FUNCTION_ID: &str = "capability::plugin_promote";
pub(crate) const CONFORMANCE_RUN_FUNCTION_ID: &str = "capability::conformance_run";
pub(crate) const IMPLEMENTATION_SET_STATE_FUNCTION_ID: &str =
    "capability::implementation_set_state";
pub(crate) const POLICY_GET_FUNCTION_ID: &str = "capability::policy_get";
pub(crate) const POLICY_VALIDATE_FUNCTION_ID: &str = "capability::policy_validate";
pub(crate) const POLICY_UPDATE_FUNCTION_ID: &str = "capability::policy_update";
pub(crate) const PROGRAM_RUN_LIST_FUNCTION_ID: &str = "capability::program_run_list";

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            SEARCH_FUNCTION_ID,
            "capability",
            EffectClass::PureRead,
            RiskLevel::Low,
            Some("capability.search"),
        )
        .visibility(VisibilityScope::System)
        .domain_module("capability")
        .request_schema(search_request_schema())
        .response_schema(capability_result_schema())
        .build()?,
        CapabilityContract::new(
            INSPECT_FUNCTION_ID,
            "capability",
            EffectClass::PureRead,
            RiskLevel::Low,
            Some("capability.inspect"),
        )
        .visibility(VisibilityScope::System)
        .domain_module("capability")
        .request_schema(inspect_request_schema())
        .response_schema(capability_result_schema())
        .build()?,
        CapabilityContract::new(
            EXECUTE_FUNCTION_ID,
            "capability",
            EffectClass::DelegatedInvocation,
            RiskLevel::Medium,
            Some("capability.execute"),
        )
        .visibility(VisibilityScope::System)
        .domain_module("capability")
        .request_schema(execute_request_schema())
        .response_schema(capability_result_schema())
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .build()?,
        admin_read_contract(
            STATUS_FUNCTION_ID,
            "capability.admin.read",
            status_request_schema(),
            admin_result_schema(),
        )?,
        admin_read_contract(
            REGISTRY_SNAPSHOT_FUNCTION_ID,
            "capability.admin.read",
            snapshot_request_schema(),
            admin_result_schema(),
        )?,
        admin_read_contract(
            AUDIT_QUERY_FUNCTION_ID,
            "capability.audit.read",
            audit_query_request_schema(),
            admin_result_schema(),
        )?,
        admin_read_contract(
            BINDING_LIST_FUNCTION_ID,
            "capability.admin.read",
            empty_request_schema(),
            admin_result_schema(),
        )?,
        admin_write_contract(
            BINDING_SET_FUNCTION_ID,
            "capability.admin.write",
            binding_set_request_schema(),
            admin_result_schema(),
        )?,
        admin_read_contract(
            PLUGIN_LIST_FUNCTION_ID,
            "capability.admin.read",
            empty_request_schema(),
            admin_result_schema(),
        )?,
        admin_read_contract(
            PLUGIN_INSPECT_FUNCTION_ID,
            "capability.admin.read",
            plugin_inspect_request_schema(),
            admin_result_schema(),
        )?,
        admin_write_contract(
            PLUGIN_INSTALL_FUNCTION_ID,
            "capability.plugin.write",
            plugin_manifest_request_schema(),
            admin_result_schema(),
        )?,
        admin_write_contract(
            PLUGIN_UPDATE_FUNCTION_ID,
            "capability.plugin.write",
            plugin_manifest_request_schema(),
            admin_result_schema(),
        )?,
        admin_write_contract(
            PLUGIN_SET_STATE_FUNCTION_ID,
            "capability.plugin.write",
            plugin_state_request_schema(),
            admin_result_schema(),
        )?,
        admin_write_contract(
            PLUGIN_PROMOTE_FUNCTION_ID,
            "capability.plugin.write",
            plugin_promote_request_schema(),
            admin_result_schema(),
        )?,
        admin_write_contract(
            CONFORMANCE_RUN_FUNCTION_ID,
            "capability.plugin.write",
            conformance_run_request_schema(),
            admin_result_schema(),
        )?,
        admin_write_contract(
            IMPLEMENTATION_SET_STATE_FUNCTION_ID,
            "capability.plugin.write",
            implementation_state_request_schema(),
            admin_result_schema(),
        )?,
        admin_read_contract(
            POLICY_GET_FUNCTION_ID,
            "capability.policy.read",
            policy_get_request_schema(),
            admin_result_schema(),
        )?,
        admin_read_contract(
            POLICY_VALIDATE_FUNCTION_ID,
            "capability.policy.read",
            policy_validate_request_schema(),
            admin_result_schema(),
        )?,
        admin_write_contract(
            POLICY_UPDATE_FUNCTION_ID,
            "capability.policy.write",
            policy_update_request_schema(),
            admin_result_schema(),
        )?,
        admin_read_contract(
            PROGRAM_RUN_LIST_FUNCTION_ID,
            "capability.admin.read",
            program_run_list_request_schema(),
            admin_result_schema(),
        )?,
    ])
}

fn admin_read_contract(
    function_id: &'static str,
    authority_scope: &'static str,
    request_schema: serde_json::Value,
    response_schema: serde_json::Value,
) -> EngineResult<CapabilitySpec> {
    CapabilityContract::new(
        function_id,
        "capability",
        EffectClass::PureRead,
        RiskLevel::Low,
        Some(authority_scope),
    )
    .visibility(VisibilityScope::System)
    .domain_module("capability")
    .request_schema(request_schema)
    .response_schema(response_schema)
    .build()
}

fn admin_write_contract(
    function_id: &'static str,
    authority_scope: &'static str,
    request_schema: serde_json::Value,
    response_schema: serde_json::Value,
) -> EngineResult<CapabilitySpec> {
    CapabilityContract::new(
        function_id,
        "capability",
        EffectClass::ReversibleSideEffect,
        RiskLevel::High,
        Some(authority_scope),
    )
    .visibility(VisibilityScope::System)
    .domain_module("capability")
    .request_schema(request_schema)
    .response_schema(response_schema)
    .idempotency(IdempotencyContract::caller_system_engine_ledger())
    .compensation(CompensationContract::new(
        CompensationKind::InverseCommandAvailable,
        "capability admin mutations are audited and can be reversed by setting the previous binding, plugin state, implementation state, or profile policy value",
    ))
    .approval_required(true)
    .build()
}

pub(crate) fn model_metadata(function_id: &str) -> serde_json::Value {
    match function_id {
        SEARCH_FUNCTION_ID => json!({
            "capabilityPrimitive": true,
            "modelPrimitiveName": "search",
            "capabilityOrder": 10,
            "capabilityExecutionMode": {"kind": "serialized", "group": "capability-read"},
            "capabilitySchema": {
                "name": "search",
                "description": "Search the live Tron capability catalog for contracts, implementations, workers, plugins, examples, and docs visible to this session.",
                "parameters": search_request_schema()
            }
        }),
        INSPECT_FUNCTION_ID => json!({
            "capabilityPrimitive": true,
            "modelPrimitiveName": "inspect",
            "capabilityOrder": 20,
            "capabilityExecutionMode": {"kind": "serialized", "group": "capability-read"},
            "capabilitySchema": {
                "name": "inspect",
                "description": "Inspect one capability contract or implementation, including schemas, authority, risk, provenance, idempotency, and copyable execute freshness fields.",
                "parameters": inspect_request_schema()
            }
        }),
        EXECUTE_FUNCTION_ID => json!({
            "capabilityPrimitive": true,
            "modelPrimitiveName": "execute",
            "capabilityOrder": 30,
            "capabilityExecutionMode": {"kind": "serialized", "group": "capability-execute"},
            "capabilitySchema": {
                "name": "execute",
                "description": "Execute a live capability by contract, implementation, capability, or function id. Mutating or elevated-risk work requires the inspectionHandle, expectedRevision, and expectedSchemaDigest returned by inspect.",
                "parameters": execute_request_schema()
            }
        }),
        _ => serde_json::Value::Null,
    }
}

fn search_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "query": {"type": "string", "description": "Natural language or identifier search over live capabilities."},
            "limit": {"type": "integer", "minimum": 1, "maximum": 50},
            "cursor": {"type": "string"},
            "kind": {"type": "string", "enum": ["contract", "implementation", "plugin", "worker", "function"]},
            "contractId": {"type": "string"},
            "namespace": {"type": "string"},
            "pluginId": {"type": "string"},
            "effect": {"type": "string"},
            "riskMax": {"type": "string", "enum": ["low", "medium", "high", "critical"]},
            "trustTierMin": {"type": "string"},
            "includeUnavailable": {"type": "boolean"},
            "scope": {"type": "string"}
        }
    })
}

fn inspect_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "capabilityId": {"type": "string"},
            "contractId": {"type": "string"},
            "implementationId": {"type": "string"},
            "functionId": {"type": "string"},
            "includeExamples": {"type": "boolean"},
            "includeDocs": {"type": "boolean"},
            "includePolicy": {"type": "boolean"}
        }
    })
}

fn execute_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["mode"],
        "additionalProperties": false,
        "properties": {
            "mode": {"type": "string", "enum": ["invoke", "program"], "description": "Use 'invoke' for one selected capability and put that capability's arguments inside payload. Use 'program' only for JavaScript composition."},
            "capabilityId": {"type": "string", "description": "Target contract/capability id for mode='invoke', such as process::run."},
            "contractId": {"type": "string", "description": "Target contract id for mode='invoke'."},
            "implementationId": {"type": "string", "description": "Target concrete implementation id for mode='invoke'."},
            "functionId": {"type": "string", "description": "Target engine function id for mode='invoke'."},
            "payload": {"type": "object", "description": "Arguments for the selected capability when mode='invoke'. Example: {\"command\":\"date\"} for process::run. Do not put target capability arguments at the top level."},
            "language": {"type": "string", "enum": ["javascript"]},
            "code": {"type": "string", "description": "JavaScript function body used only with mode='program'. Leave unset for mode='invoke'."},
            "args": {"type": "object", "description": "Program arguments used only with mode='program'."},
            "allowedContracts": {"type": "array", "items": {"type": "string"}},
            "allowedImplementations": {"type": "array", "items": {"type": "string"}},
            "timeoutMs": {"type": "integer", "minimum": 10, "maximum": 30000},
            "budget": {"type": "object"},
            "expectedRevision": {"type": "integer", "minimum": 1, "description": "Freshness revision copied from inspect.executionRequirements for mutating or elevated-risk work."},
            "expectedSchemaDigest": {"type": "string", "description": "Schema digest copied from inspect.executionRequirements for mutating or elevated-risk work."},
            "inspectionHandle": {"type": "string", "description": "Fresh inspection handle copied from inspect.executionRequirements for mutating or elevated-risk work."},
            "idempotencyKey": {"type": "string", "description": "Stable caller-chosen key required for mutating child work."},
            "reason": {"type": "string"}
        }
    })
}

fn empty_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {}
    })
}

fn status_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "includeSnapshot": {"type": "boolean"}
        }
    })
}

fn snapshot_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "includeDocuments": {"type": "boolean"},
            "includeBindings": {"type": "boolean"}
        }
    })
}

fn audit_query_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "eventType": {"type": "string"},
            "traceId": {"type": "string"},
            "limit": {"type": "integer", "minimum": 1, "maximum": 200},
            "revealPayloads": {"type": "boolean"}
        }
    })
}

fn program_run_list_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "traceId": {"type": "string"},
            "status": {"type": "string", "enum": ["ok", "error", "approval_required", "paused", "failed"]},
            "limit": {"type": "integer", "minimum": 1, "maximum": 200},
            "revealPayloads": {"type": "boolean"}
        }
    })
}

fn binding_set_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["contractId", "selectedImplementation"],
        "properties": {
            "contractId": {"type": "string"},
            "scopeKind": {"type": "string", "enum": ["session", "workspace", "profile", "system"]},
            "scopeValue": {"type": "string"},
            "selectedImplementation": {"type": "string"},
            "selectionPolicy": {"type": "string"},
            "secondaryImplementations": {"type": "array", "items": {"type": "string"}},
            "priority": {"type": "integer"},
            "enabled": {"type": "boolean"},
            "reason": {"type": "string"}
        }
    })
}

fn plugin_inspect_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["pluginId"],
        "properties": {
            "pluginId": {"type": "string"}
        }
    })
}

fn plugin_manifest_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["manifest"],
        "properties": {
            "manifest": {"type": "object"},
            "reason": {"type": "string"}
        }
    })
}

fn plugin_state_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["pluginId", "state"],
        "properties": {
            "pluginId": {"type": "string"},
            "state": {"type": "string", "enum": ["candidate", "healthy", "degraded", "quarantined", "disabled"]},
            "reason": {"type": "string"}
        }
    })
}

fn plugin_promote_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["pluginId", "targetVisibility"],
        "properties": {
            "pluginId": {"type": "string"},
            "targetVisibility": {"type": "string", "enum": ["workspace", "system"]},
            "reason": {"type": "string"}
        }
    })
}

fn conformance_run_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["pluginId"],
        "properties": {
            "pluginId": {"type": "string"},
            "implementationId": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}

fn implementation_state_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["implementationId", "state"],
        "properties": {
            "implementationId": {"type": "string"},
            "state": {"type": "string", "enum": ["candidate", "healthy", "degraded", "quarantined", "disabled"]},
            "reason": {"type": "string"}
        }
    })
}

fn policy_get_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "policyId": {"type": "string"}
        }
    })
}

fn policy_validate_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["policy"],
        "properties": {
            "policyId": {"type": "string"},
            "policy": {"type": "object"}
        }
    })
}

fn policy_update_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["policyId", "policy"],
        "properties": {
            "policyId": {"type": "string"},
            "policy": {"type": "object"},
            "reason": {"type": "string"}
        }
    })
}

fn admin_result_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": true
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_search_inspect_execute_have_model_metadata() {
        assert!(!model_metadata(SEARCH_FUNCTION_ID).is_null());
        assert!(!model_metadata(INSPECT_FUNCTION_ID).is_null());
        assert!(!model_metadata(EXECUTE_FUNCTION_ID).is_null());
        assert!(model_metadata(STATUS_FUNCTION_ID).is_null());
        assert!(model_metadata(PLUGIN_INSTALL_FUNCTION_ID).is_null());
        assert!(model_metadata(POLICY_UPDATE_FUNCTION_ID).is_null());
    }

    #[test]
    fn console_admin_capabilities_are_registered_as_catalog_functions() {
        let capabilities = capabilities().expect("contracts");
        let ids = capabilities
            .iter()
            .map(|spec| spec.function_id.as_str())
            .collect::<std::collections::BTreeSet<_>>();
        for expected in [
            STATUS_FUNCTION_ID,
            REGISTRY_SNAPSHOT_FUNCTION_ID,
            AUDIT_QUERY_FUNCTION_ID,
            BINDING_LIST_FUNCTION_ID,
            BINDING_SET_FUNCTION_ID,
            PLUGIN_LIST_FUNCTION_ID,
            PLUGIN_INSPECT_FUNCTION_ID,
            PLUGIN_INSTALL_FUNCTION_ID,
            PLUGIN_UPDATE_FUNCTION_ID,
            PLUGIN_SET_STATE_FUNCTION_ID,
            PLUGIN_PROMOTE_FUNCTION_ID,
            CONFORMANCE_RUN_FUNCTION_ID,
            IMPLEMENTATION_SET_STATE_FUNCTION_ID,
            POLICY_GET_FUNCTION_ID,
            POLICY_VALIDATE_FUNCTION_ID,
            POLICY_UPDATE_FUNCTION_ID,
        ] {
            assert!(ids.contains(expected), "{expected} missing");
        }
    }

    #[test]
    fn console_admin_mutations_are_system_idempotent() {
        let capabilities = capabilities().expect("contracts");
        for function_id in [
            BINDING_SET_FUNCTION_ID,
            PLUGIN_INSTALL_FUNCTION_ID,
            PLUGIN_UPDATE_FUNCTION_ID,
            PLUGIN_SET_STATE_FUNCTION_ID,
            PLUGIN_PROMOTE_FUNCTION_ID,
            CONFORMANCE_RUN_FUNCTION_ID,
            IMPLEMENTATION_SET_STATE_FUNCTION_ID,
            POLICY_UPDATE_FUNCTION_ID,
        ] {
            let spec = capabilities
                .iter()
                .find(|spec| spec.function_id.as_str() == function_id)
                .unwrap_or_else(|| panic!("{function_id} missing"));
            assert_eq!(
                spec.idempotency
                    .as_ref()
                    .map(|contract| &contract.dedupe_scope),
                Some(&VisibilityScope::System),
                "{function_id} should not require a session id when invoked from Engine Console"
            );
        }
    }
}

fn capability_result_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": true,
        "properties": {
            "content": {},
            "details": {},
            "isError": {"type": "boolean"},
            "stopTurn": {"type": "boolean"}
        },
        "required": ["content"]
    })
}
