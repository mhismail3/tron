//! Capability contracts owned by the capability domain worker.
//!
//! This worker is the model-facing harness collapse point: providers see one
//! `execute` primitive, while search, inspection, preparation, approval, and
//! target execution remain engine-owned phases over live domain/plugin workers.

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
        EXECUTE_FUNCTION_ID => json!({
            "capabilityPrimitive": true,
            "modelPrimitiveName": "execute",
            "capabilityOrder": 10,
            "capabilityExecutionMode": {"kind": "serialized", "group": "capability-execute"},
            "capabilitySchema": {
                "name": "execute",
                "description": "Intent-first portal for all Tron capabilities: resolve, prepare, approve when needed, run, and observe one capability per call. Start with natural-language intent alone when the target is not already known; provide target only when the user supplied an exact capability id, a prior execute result selected it, or a primed recipe makes it unambiguous. Put target capability arguments inside arguments when possible, keep wrapper fields top-level, and never invent targets to satisfy a discovery or shape test. Use operation=discover, or a clear discovery-only intent, when you need capability ids, required fields, schemas, examples, or a safe sequence without executing the target. If you accidentally place target argument fields at the execute root, execute may move them into arguments and select the target by schema fit, but arguments is the canonical shape. If you accidentally set target to capability::execute itself, execute removes that self-target and resolves the real target from intent; do not intentionally wrap execute inside execute. Do not call separate search or inspect tools; this execute primitive owns discovery, freshness, approval, correction, and child execution. A needs_input result means retry the same selected target with the missing arguments. A needs_decomposition result means the request spans multiple target invocations; call execute once per suggested call only when the user still wants the underlying work performed, and report the decomposition result without running suggestions when the user only asked to test or inspect decomposition. Harmless shape mistakes may be corrected, but mutating or elevated-risk work still pauses for freshness and approval before child execution. Do not invent constraints such as riskMax for ordinary work; use constraints only when the user explicitly gives a hard bound. Network reads such as web::search and web::fetch are medium-risk pure reads, so riskMax=low intentionally rejects them.",
                "parameters": execute_model_request_schema()
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
            "queries": {
                "type": "array",
                "items": {"type": "string"},
                "maxItems": 8,
                "description": "Optional batch of related capability searches. Use this instead of several separate search calls when looking up multiple first-party or plugin capabilities."
            },
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
            "targets": {
                "type": "array",
                "maxItems": 8,
                "items": {
                    "oneOf": [
                        {"type": "string", "description": "Capability, contract, implementation, or function id."},
                        {
                            "type": "object",
                            "additionalProperties": false,
                            "properties": {
                                "capabilityId": {"type": "string"},
                                "contractId": {"type": "string"},
                                "implementationId": {"type": "string"},
                                "functionId": {"type": "string"}
                            }
                        }
                    ]
                },
                "description": "Optional batch of capability targets to inspect under one catalog snapshot."
            },
            "includeExamples": {"type": "boolean"},
            "includeDocs": {"type": "boolean"},
            "includePolicy": {"type": "boolean"}
        }
    })
}

fn execute_request_schema() -> serde_json::Value {
    let mut schema = execute_model_request_schema();
    if let Some(object) = schema.as_object_mut() {
        object.remove("anyOf");
    }
    let properties = schema
        .get_mut("properties")
        .and_then(serde_json::Value::as_object_mut)
        .expect("execute schema properties");
    properties.insert(
        "mode".to_owned(),
        json!({"type": "string", "enum": ["invoke", "program"], "description": "Internal/operator direct shape. Model callers should omit this and use intent/target/arguments."}),
    );
    properties.insert(
        "capabilityId".to_owned(),
        json!({"type": "string", "description": "Internal/operator target capability id. Model callers should use target instead."}),
    );
    properties.insert(
        "contractId".to_owned(),
        json!({"type": "string", "description": "Internal/operator target contract id. Model callers should use target instead."}),
    );
    properties.insert(
        "implementationId".to_owned(),
        json!({"type": "string", "description": "Internal/operator target implementation id. Model callers should use target instead."}),
    );
    properties.insert(
        "functionId".to_owned(),
        json!({"type": "string", "description": "Internal/operator target function id. Model callers should use target instead."}),
    );
    properties.insert(
        "language".to_owned(),
        json!({"type": "string", "enum": ["javascript"], "description": "Internal/operator program mode only."}),
    );
    properties.insert(
        "code".to_owned(),
        json!({"type": "string", "description": "Internal/operator JavaScript program body used only with mode='program'."}),
    );
    properties.insert(
        "args".to_owned(),
        json!({"type": "object", "description": "Internal/operator program arguments used only with mode='program'."}),
    );
    properties.insert(
        "allowedContracts".to_owned(),
        json!({"type": "array", "items": {"type": "string"}}),
    );
    properties.insert(
        "allowedImplementations".to_owned(),
        json!({"type": "array", "items": {"type": "string"}}),
    );
    properties.insert(
        "timeoutMs".to_owned(),
        json!({"type": "integer", "minimum": 10, "maximum": 30000}),
    );
    properties.insert("budget".to_owned(), json!({"type": "object"}));
    properties.insert(
        "expectedRevision".to_owned(),
        json!({"type": "integer", "minimum": 1, "description": "Internal/operator freshness revision. Model callers should let execute prepare freshness."}),
    );
    properties.insert(
        "expectedSchemaDigest".to_owned(),
        json!({"type": "string", "description": "Internal/operator schema digest. Model callers should let execute prepare freshness."}),
    );
    properties.insert(
        "inspectionHandle".to_owned(),
        json!({"type": "string", "description": "Internal/operator inspection handle. Model callers should let execute prepare freshness."}),
    );
    schema
}

fn execute_model_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": true,
        "properties": {
            "intent": {"type": "string", "description": "Natural-language goal. Use intent by itself for discovery, unfamiliar tasks, or capability matching; the engine resolves and ranks visible capabilities when target is omitted or ambiguous."},
            "operation": {"type": "string", "description": "Optional high-level operation. Use exactly discover when asking what capabilities exist, what fields are required, what schema/examples apply, or what sequence is safe; discover never creates a target child invocation. Use exactly run only when you intend to execute the selected target. Omit for auto."},
            "target": {"type": "string", "description": "Optional target hint such as process::run or filesystem::read_file. Omit when discovering or comparing capabilities; use only when the user supplied an exact id, a prior execute result selected it, or a primed recipe makes it unambiguous."},
            "contractId": {"type": "string", "description": "Correctable target alias only for callers that already know the contract id from the user, a prior execute result, or a primed recipe. Prefer target when possible."},
            "capabilityId": {"type": "string", "description": "Correctable target alias only for callers that already know the capability id from the user, a prior execute result, or a primed recipe. Prefer target when possible."},
            "functionId": {"type": "string", "description": "Correctable target alias only for callers that already know the registered function id from the user, a prior execute result, or a primed recipe. Prefer target when possible."},
            "implementationId": {"type": "string", "description": "Correctable target alias only for callers that already know the implementation id from the user, a prior execute result, or a primed recipe. Prefer target when possible."},
            "arguments": {"type": "object", "description": "Arguments for the resolved target capability only. Example for process::run: {\"command\":\"date\",\"executionMode\":\"read_only\"}. Omit arguments for pure discovery if required fields are not known yet. If execute returns needs_input, retry the same selected target with the missing fields. If execute returns needs_decomposition, make one execute call per suggested call instead of packing multiple target invocations into one arguments object. Do not include wrapper fields such as target, contractId, capabilityId, functionId, implementationId, payload, mode, inspectionHandle, reason, or expectedRevision here. Keep idempotencyKey top-level; when the selected target schema itself requires idempotencyKey, execute copies the top-level key into the target arguments safely. Harmless target argument key casing/separator mistakes are corrected only when they uniquely match the selected target schema; conflicting aliases still fail validation. Unknown top-level fields are accepted only so execute can correct flattened target arguments into arguments and audit that correction."},
            "constraints": {
                "type": "object",
                "additionalProperties": true,
                "properties": {
                    "riskMax": {"type": "string", "description": "Optional maximum risk: low, medium, high, or critical. Use only when the user explicitly asks for a hard risk bound; ordinary web searches/fetches are medium-risk pure reads and will be rejected by riskMax=low."},
                    "effect": {"type": "string", "description": "Optional exact effect-class constraint, such as pure_read or external_side_effect."},
                    "allowedContracts": {"type": "array", "items": {"type": "string"}},
                    "allowedNamespaces": {"type": "array", "items": {"type": "string"}}
                },
                "description": "Optional v1 bounds for resolution and preparation. Supported fields are riskMax, effect, allowedContracts, and allowedNamespaces. The schema accepts an object so execute can return structured constraints_rejected guidance for unsupported fields instead of failing at provider/schema validation. Constraints never broaden authority; unsupported constraint fields are rejected instead of ignored. Do not set constraints by default; omit riskMax/effect unless the user specifically asks for that bound."
            },
            "payload": {"type": "object", "description": "Accepted only as a correctable alias for arguments. Prefer arguments; if supplied, the engine records a payload_to_arguments correction."},
            "idempotencyKey": {"type": "string", "description": "Stable caller-chosen key for mutating or resource-producing work. Safe read-only calls may omit it. Keep this top-level; execute forwards it into the prepared child invocation and, for targets whose own schema requires idempotencyKey, safely copies it into target arguments."},
            "reason": {"type": "string", "description": "Short reason for the requested action, used in audit records and approval prompts."}
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
            "orchestrationStatus": {"type": "string", "description": "Optional capability::execute orchestration status filter, such as needs_input, needs_decomposition, needs_selection, needs_capability, target_payload_invalid, or executed."},
            "correctionKind": {"type": "string", "description": "Optional correction kind filter, such as payload_to_arguments or process_expected_outputs_shape."},
            "phase": {"type": "string", "description": "Optional orchestration phase filter, such as resolve, prepare, run, or observe."},
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
    fn only_execute_has_model_metadata() {
        assert!(model_metadata(SEARCH_FUNCTION_ID).is_null());
        assert!(model_metadata(INSPECT_FUNCTION_ID).is_null());
        assert!(!model_metadata(EXECUTE_FUNCTION_ID).is_null());
        assert!(model_metadata(STATUS_FUNCTION_ID).is_null());
        assert!(model_metadata(PLUGIN_INSTALL_FUNCTION_ID).is_null());
        assert!(model_metadata(POLICY_UPDATE_FUNCTION_ID).is_null());
    }

    #[test]
    fn execute_schema_teaches_target_call_shape_and_complete_payloads() {
        let metadata = model_metadata(EXECUTE_FUNCTION_ID);
        let description = metadata["capabilitySchema"]["description"]
            .as_str()
            .expect("execute description");
        assert!(description.contains("natural-language intent"));
        assert!(description.contains("Intent-first portal"));
        assert!(description.contains("Start with natural-language intent alone"));
        assert!(description.contains("never invent targets"));
        assert!(description.contains("Do not call separate search or inspect tools"));
        assert!(description.contains("needs_input"));
        assert!(description.contains("needs_decomposition"));
        assert!(description.contains("mutating or elevated-risk work still pauses"));
        assert!(description.contains("Do not invent constraints"));
        assert!(description.contains("web::search and web::fetch are medium-risk pure reads"));

        let schema = execute_model_request_schema();
        assert!(schema["required"].is_null());
        assert_eq!(
            schema["additionalProperties"],
            json!(true),
            "execute intentionally accepts flattened target arguments so the orchestrator can correct them before target validation"
        );
        assert_eq!(schema["properties"]["target"]["type"], json!("string"));
        assert_eq!(schema["properties"]["contractId"]["type"], json!("string"));
        assert_eq!(schema["properties"]["functionId"]["type"], json!("string"));

        let target_description = schema["properties"]["target"]["description"]
            .as_str()
            .expect("target description");
        assert!(target_description.contains("Omit when discovering"));
        assert!(target_description.contains("prior execute result selected it"));

        let arguments_description = schema["properties"]["arguments"]["description"]
            .as_str()
            .expect("arguments description");
        assert!(arguments_description.contains(r#""executionMode":"read_only""#));
        assert!(arguments_description.contains("retry the same selected target"));
        assert!(arguments_description.contains("one execute call per suggested call"));
        assert!(arguments_description.contains("Do not include wrapper fields"));
        assert!(arguments_description.contains("idempotencyKey"));
        assert!(arguments_description.contains("Unknown top-level fields"));

        let payload_description = schema["properties"]["payload"]["description"]
            .as_str()
            .expect("payload alias description");
        assert!(payload_description.contains("correctable alias"));

        assert_eq!(
            schema["properties"]["constraints"]["additionalProperties"],
            json!(true),
            "model-facing execute must route unsupported constraint fields through orchestration guidance"
        );
        let constraints_description = schema["properties"]["constraints"]["description"]
            .as_str()
            .expect("constraints description");
        assert!(constraints_description.contains("constraints_rejected"));
        assert!(constraints_description.contains("Do not set constraints by default"));

        let risk_max_description =
            schema["properties"]["constraints"]["properties"]["riskMax"]["description"]
                .as_str()
                .expect("riskMax description");
        assert!(risk_max_description.contains("ordinary web searches/fetches"));
        assert!(risk_max_description.contains("riskMax=low"));

        let idempotency_description = schema["properties"]["idempotencyKey"]["description"]
            .as_str()
            .expect("idempotency description");
        assert!(idempotency_description.contains("Keep this top-level"));
        assert!(idempotency_description.contains("safely copies it into target arguments"));
    }

    #[test]
    fn execute_model_schema_stays_provider_portable() {
        let metadata = model_metadata(EXECUTE_FUNCTION_ID);
        let schema = &metadata["capabilitySchema"]["parameters"];
        assert_eq!(schema["type"], json!("object"));
        assert_provider_schema_has_no_unsupported_keywords(schema, "$");
    }

    fn assert_provider_schema_has_no_unsupported_keywords(value: &serde_json::Value, path: &str) {
        match value {
            serde_json::Value::Object(object) => {
                for key in ["oneOf", "anyOf", "allOf", "enum", "not"] {
                    assert!(
                        !object.contains_key(key),
                        "provider schema contains unsupported {key} at {path}"
                    );
                }
                for (key, child) in object {
                    assert_provider_schema_has_no_unsupported_keywords(
                        child,
                        &format!("{path}.{key}"),
                    );
                }
            }
            serde_json::Value::Array(values) => {
                for (index, child) in values.iter().enumerate() {
                    assert_provider_schema_has_no_unsupported_keywords(
                        child,
                        &format!("{path}[{index}]"),
                    );
                }
            }
            _ => {}
        }
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
