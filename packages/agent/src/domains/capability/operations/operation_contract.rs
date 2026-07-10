//! Provider-visible structural contracts for `capability::execute` operations.
//!
//! Every supported operation has one [`OperationContract`] here. Catalog
//! projection and runtime validation consume the same closed schema. Domain
//! services retain semantic, lifecycle, and runtime resource validation after
//! this structural gate.

use serde_json::{Map, Value, json};

use super::registry::is_supported_operation;
#[cfg(test)]
use super::registry::supported_operation_names;
use crate::engine::FunctionId;
use crate::engine::kernel::schema;
use crate::shared::server::errors::CapabilityError;

mod authority;
mod capability_binding;
mod direct;
mod governance;
mod metadata;
mod output;
mod policy;
mod records;

pub(crate) use authority::{
    AuthorityPolicy, CapabilityBindingResourceSet, ConditionalAuthority,
    ModuleProgramExecutionResourceSet, ModuleRuntimeResourceSet, NetworkPolicy,
    ProceduralResourceSet, ResourceKindPolicy, SelectorAddition, SubagentResourceSet,
    WorkerPackageKindSource,
};
pub(super) use policy::InvocationScope;
pub(crate) use policy::OperationEffect;

/// One authoritative provider-visible structural contract.
#[derive(Clone, Debug)]
pub(super) struct OperationContract {
    /// Closed top-level payload schema consumed by catalog and runtime.
    pub(super) input_schema: Value,
}

pub(super) fn binding_metadata(
    operation: &str,
) -> Option<(&'static str, &'static str, &'static str, &'static str)> {
    metadata::metadata(operation).map(|metadata| {
        (
            metadata.family,
            metadata.current_owner,
            metadata.ownership_class,
            metadata.replacement_target,
        )
    })
}

pub(super) fn invocation_scope(operation: &str) -> policy::InvocationScope {
    policy::invocation_scope(operation)
}

pub(super) fn requires_idempotency(operation: &str) -> bool {
    policy::requires_idempotency(operation)
}

pub(crate) fn effect(operation: &str) -> Option<OperationEffect> {
    policy::effect(operation)
}

pub(crate) fn authority_policy(operation: &str) -> Option<AuthorityPolicy> {
    authority::policy(operation)
}

/// Return the complete provider-visible contract for one supported operation.
pub(super) fn contract(operation: &str) -> Option<OperationContract> {
    let input_schema = capability_binding::input_schema(operation)
        .or_else(|| governance::input_schema(operation))
        .or_else(|| records::input_schema(operation))
        .or_else(|| direct::input_schema(operation))?;
    Some(OperationContract { input_schema })
}

/// Return the exact schema for catalog projection or runtime validation.
pub(super) fn exact_input_schema(operation: &str) -> Option<Value> {
    contract(operation).map(|contract| contract.input_schema)
}

pub(super) fn exact_output_schema(operation: &str) -> Option<Value> {
    output::output_schema(operation)
}

/// Validate membership and the operation's closed payload shape.
pub(crate) fn validate_payload(payload: &Value) -> Result<(), CapabilityError> {
    let operation = payload
        .get("operation")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|operation| !operation.is_empty())
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: "Missing required parameter: operation".to_owned(),
        })?;
    if !is_supported_operation(operation) {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "Unsupported capability::execute operation '{operation}'. Use catalog_search to discover an exact supported operation name."
            ),
        });
    }
    let contract = contract(operation)
        .expect("supported capability operation must have one canonical structural contract");
    let function_id =
        FunctionId::new("capability::execute").expect("canonical capability function id is valid");
    schema::validate_payload(
        &function_id,
        "operation request",
        &contract.input_schema,
        payload,
    )
    .map_err(|error| CapabilityError::InvalidParams {
        message: format!("Invalid {operation} payload: {error}"),
    })
}

fn closed_schema(operation: &str, required: &[&str], fields: Vec<(&str, Value)>) -> Value {
    let mut properties = Map::new();
    properties.insert(
        "operation".to_owned(),
        json!({
            "type": "string",
            "const": operation,
            "description": "Exact capability::execute operation selector."
        }),
    );
    for (field, schema) in fields {
        properties.insert(field.to_owned(), schema);
    }
    json!({
        "type": "object",
        "required": required,
        "properties": properties,
        "additionalProperties": false,
        "payloadPlacement": "top_level_capability_execute_payload",
        "schemaCompleteness": "exact_structural_contract"
    })
}

fn string_schema(description: &str) -> Value {
    json!({"type": "string", "description": description})
}

fn bounded_integer_schema(minimum: u64, maximum: u64, description: &str) -> Value {
    json!({
        "type": "integer",
        "minimum": minimum,
        "maximum": maximum,
        "description": description
    })
}

fn network_policy_none_schema() -> Value {
    json!({
        "type": "string",
        "const": "none",
        "description": "Optional explicit no-network policy proof; only none is accepted."
    })
}

fn idempotency_schema() -> Value {
    string_schema(
        "Stable bounded caller idempotency key for this durable write. This value is provider-visible in the tool-call payload because the caller supplies it, but provider-safe result, status, log, and trace projections redact it.",
    )
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn every_contract_is_a_single_source_closed_schema() {
        let contracts = supported_operation_names()
            .iter()
            .filter_map(|operation| contract(operation).map(|contract| (*operation, contract)))
            .collect::<Vec<_>>();
        assert_eq!(contracts.len(), supported_operation_names().len());
        for (operation, contract) in contracts {
            assert_eq!(contract.input_schema["additionalProperties"], false);
            assert_eq!(
                contract.input_schema["schemaCompleteness"],
                "exact_structural_contract"
            );
            assert_eq!(
                contract.input_schema["properties"]["operation"]["const"],
                operation
            );
            schema::validate_schema_definition(
                &FunctionId::new("capability::execute").expect("function id"),
                "operation request",
                &contract.input_schema,
            )
            .expect("canonical schema uses only enforced structural keywords");
        }
    }

    #[test]
    fn every_supported_operation_has_exactly_one_contract_family_owner() {
        for operation in supported_operation_names() {
            let owners = [
                capability_binding::input_schema(operation).is_some(),
                governance::input_schema(operation).is_some(),
                records::input_schema(operation).is_some(),
                direct::input_schema(operation).is_some(),
            ]
            .into_iter()
            .filter(|owned| *owned)
            .count();
            assert_eq!(owners, 1, "{operation} has {owners} contract family owners");
        }
    }

    #[test]
    fn every_idempotent_operation_requires_the_caller_key_in_its_schema() {
        for operation in supported_operation_names() {
            if !requires_idempotency(operation) {
                continue;
            }
            let schema = exact_input_schema(operation).expect("supported operation contract");
            assert!(
                schema["required"]
                    .as_array()
                    .is_some_and(|required| required.contains(&json!("idempotencyKey"))),
                "{operation} requires idempotency but does not require the caller key structurally"
            );
        }
    }

    #[test]
    fn catalog_and_runtime_schemas_are_identical() {
        for operation in supported_operation_names() {
            let Some(contract) = contract(operation) else {
                continue;
            };
            assert_eq!(
                super::super::catalog::execute_operation_input_schema(operation),
                contract.input_schema,
                "catalog and pre-authority runtime schema drifted for {operation}"
            );
        }
    }

    #[test]
    fn exact_catalog_inspect_contract_requires_kind_and_id() {
        let error = validate_payload(&json!({"operation": "catalog_inspect"}))
            .expect_err("catalog_inspect without kind/id must fail structurally");
        assert!(error.to_string().contains("$.kind"));
        assert!(error.to_string().contains("required field is missing"));
    }

    #[test]
    fn catalog_conformance_contract_requires_explicit_idempotency() {
        let schema = exact_input_schema("catalog_conformance").expect("exact contract");
        assert_eq!(schema["required"], json!(["operation", "idempotencyKey"]));
        let error = validate_payload(&json!({"operation": "catalog_conformance"}))
            .expect_err("durable conformance report requires caller idempotency");
        assert!(error.to_string().contains("$.idempotencyKey"));
    }

    #[test]
    fn exact_contract_rejects_cross_operation_fields() {
        let error = validate_payload(&json!({
            "operation": "catalog_search",
            "text": "git status",
            "command": "ignored by catalog search"
        }))
        .expect_err("exact operation contracts reject unrelated host-union fields");
        assert!(error.to_string().contains("$.command"));
        assert!(
            error
                .to_string()
                .contains("additional property is not allowed")
        );
    }

    #[test]
    fn exact_contract_enforces_const_and_bounds() {
        let inert_policy = validate_payload(&json!({
            "operation": "repository_tree_list",
            "networkPolicy": "none"
        }))
        .expect_err("authority-owned network policy is not a payload parameter");
        assert!(
            inert_policy
                .to_string()
                .contains("additional property is not allowed")
        );

        let excessive_limit = validate_payload(&json!({
            "operation": "capability_binding_cockpit_overview",
            "limit": 201
        }))
        .expect_err("cockpit bound must match its domain contract");
        assert!(excessive_limit.to_string().contains("exceeds maximum 200"));
    }

    #[test]
    fn direct_operation_uses_its_canonical_closed_contract() {
        validate_payload(&json!({
            "operation": "filesystem_read",
            "path": "README.md"
        }))
        .expect("direct operation validates through the canonical contract owner");
    }
}
