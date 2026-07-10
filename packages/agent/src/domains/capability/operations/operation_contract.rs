//! Provider-visible structural contracts for `capability::execute` operations.
//!
//! Each promoted operation has one [`OperationContract`] here. Catalog
//! projection and runtime validation consume the same schema; no second exact
//! field list is maintained in the catalog. Domain services still own semantic,
//! authority, lifecycle, and resource validation after this structural gate.

use serde_json::{Map, Value, json};

use super::registry::is_supported_operation;
#[cfg(test)]
use super::registry::supported_operation_names;
use crate::engine::FunctionId;
use crate::engine::kernel::schema;
use crate::shared::server::errors::CapabilityError;

mod capability_binding;

/// One authoritative provider-visible structural contract.
#[derive(Clone, Debug)]
pub(super) struct OperationContract {
    /// Closed top-level payload schema consumed by catalog and runtime.
    pub(super) input_schema: Value,
}

/// Return the promoted contract for one operation.
///
/// Absence means the operation still relies on its domain-owned structural
/// validator and must be projected as `domain_validated_contract`.
pub(super) fn contract(operation: &str) -> Option<OperationContract> {
    if let Some(input_schema) = capability_binding::input_schema(operation) {
        return Some(OperationContract { input_schema });
    }
    let (required, properties) = match operation {
        "catalog_search" => (vec!["operation"], catalog_query_properties(false)),
        "catalog_conformance" => (
            vec!["operation", "idempotencyKey"],
            catalog_query_properties(true),
        ),
        "catalog_inspect" => (
            vec!["operation", "kind", "id"],
            vec![
                (
                    "kind",
                    json!({"type": "string", "enum": ["function", "worker", "trigger_type", "trigger"]}),
                ),
                (
                    "id",
                    string_schema("Exact catalog or execute-operation id to inspect."),
                ),
                (
                    "includeOutputSchema",
                    json!({"type": "boolean", "description": "Include the output contract only when it is needed."}),
                ),
            ],
        ),
        "repository_tree_snapshot" => (
            vec![
                "operation",
                "repositoryRef",
                "rootRef",
                "treeObjectRef",
                "idempotencyKey",
            ],
            repository_tree_snapshot_properties(),
        ),
        "repository_tree_list" => (
            vec!["operation"],
            vec![
                (
                    "limit",
                    bounded_integer_schema(1, 100, "Maximum snapshots returned."),
                ),
                ("includeArchived", json!({"type": "boolean"})),
                (
                    "repositoryRefId",
                    string_schema(
                        "Optional bounded repository ref id filter; unsupported aliases are rejected.",
                    ),
                ),
                ("networkPolicy", network_policy_none_schema()),
            ],
        ),
        "repository_tree_inspect" => (
            vec!["operation", "repositoryTreeResourceId"],
            vec![
                (
                    "repositoryTreeResourceId",
                    string_schema("Exact repository_tree_snapshot resource id."),
                ),
                ("networkPolicy", network_policy_none_schema()),
            ],
        ),
        "job_start" => (
            vec!["operation", "command", "idempotencyKey"],
            vec![
                ("command", command_schema()),
                ("idempotencyKey", idempotency_schema()),
                (
                    "timeoutMs",
                    bounded_integer_schema(1, 120_000, "Maximum job runtime."),
                ),
                (
                    "maxOutputBytes",
                    bounded_integer_schema(1, 200_000, "Maximum captured output bytes."),
                ),
                (
                    "cleanupAfterSeconds",
                    json!({"type": "integer", "minimum": 0}),
                ),
            ],
        ),
        "job_status" | "job_log" => (
            vec!["operation", "jobResourceId"],
            vec![("jobResourceId", job_resource_id_schema())],
        ),
        "job_list" => (
            vec!["operation"],
            vec![
                (
                    "state",
                    json!({"type": "string", "enum": ["running", "completed", "failed", "timed_out", "cancelled", "archived"]}),
                ),
                (
                    "limit",
                    bounded_integer_schema(1, 500, "Maximum jobs returned."),
                ),
            ],
        ),
        "job_cancel" => (
            vec!["operation", "jobResourceId", "idempotencyKey"],
            vec![
                ("jobResourceId", job_resource_id_schema()),
                ("idempotencyKey", idempotency_schema()),
                (
                    "reason",
                    string_schema("Optional bounded cancellation reason."),
                ),
            ],
        ),
        "process_run" => (
            vec!["operation", "command"],
            vec![
                ("command", command_schema()),
                (
                    "timeoutMs",
                    bounded_integer_schema(1, 120_000, "Maximum synchronous process runtime."),
                ),
                (
                    "maxOutputBytes",
                    bounded_integer_schema(1, 200_000, "Maximum provider-visible output bytes."),
                ),
            ],
        ),
        "trace_list" => (
            vec!["operation"],
            vec![
                (
                    "limit",
                    bounded_integer_schema(1, 500, "Maximum trace records returned."),
                ),
                (
                    "traceId",
                    string_schema("Optional exact engine trace filter."),
                ),
            ],
        ),
        "trace_get" => (
            vec!["operation", "traceRecordId"],
            vec![(
                "traceRecordId",
                string_schema("Exact provider-safe trace record id returned by trace_list."),
            )],
        ),
        _ => return None,
    };
    is_supported_operation(operation).then(|| OperationContract {
        input_schema: closed_schema(operation, &required, properties),
    })
}

/// Return the exact schema for catalog projection or runtime validation.
pub(super) fn exact_input_schema(operation: &str) -> Option<Value> {
    contract(operation).map(|contract| contract.input_schema)
}

/// Validate membership and, once promoted, the closed payload shape.
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
    let Some(contract) = contract(operation) else {
        return Ok(());
    };
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

fn catalog_query_properties(include_reason: bool) -> Vec<(&'static str, Value)> {
    let mut fields = vec![
        (
            "text",
            string_schema("Optional natural-language or exact operation query."),
        ),
        (
            "namespacePrefix",
            string_schema("Optional exact namespace or capability-family prefix."),
        ),
        (
            "visibility",
            string_schema("Optional catalog visibility filter."),
        ),
        (
            "effectClass",
            json!({
                "type": "string",
                "enum": [
                    "pure_read", "read", "read_only", "inspect", "deterministic_compute",
                    "delegated_invocation", "idempotent_write", "append_only_event",
                    "reversible_side_effect", "external_side_effect", "irreversible_side_effect"
                ]
            }),
        ),
        ("maxRisk", string_schema("Optional maximum risk filter.")),
        ("health", string_schema("Optional catalog health filter.")),
        ("includeInternal", json!({"type": "boolean"})),
        ("includeProtectedCounts", json!({"type": "boolean"})),
        (
            "limit",
            bounded_integer_schema(1, 500, "Maximum catalog matches returned."),
        ),
    ];
    if include_reason {
        fields.push((
            "reason",
            string_schema("Reason for the durable conformance report."),
        ));
        fields.push(("idempotencyKey", idempotency_schema()));
    }
    fields
}

fn repository_tree_snapshot_properties() -> Vec<(&'static str, Value)> {
    vec![
        ("snapshotId", string_schema("Optional stable snapshot id.")),
        (
            "repositoryRef",
            json!({"type": "object", "description": "Required bounded repository reference; copy the complete repositoryTreeSnapshotInput.repositoryRef object from git_status when available, including kind. Passing only .id is invalid."}),
        ),
        (
            "rootRef",
            json!({"type": "object", "description": "Required bounded workspace/repository-root reference; copy the complete repositoryTreeSnapshotInput.rootRef object from git_status when available, including kind. Passing only .id is invalid."}),
        ),
        (
            "treeObjectRef",
            string_schema(
                "Required bounded tree object token; copy repositoryTreeSnapshotInput.treeObjectRef from git_status when available. Never pass raw tree contents.",
            ),
        ),
        (
            "headRef",
            json!({"type": "object", "description": "Optional bounded commit/head reference; copy the complete repositoryTreeSnapshotInput.headRef object from git_status when available, including kind."}),
        ),
        (
            "snapshotLabel",
            string_schema("Optional short snapshot label."),
        ),
        (
            "snapshotSummary",
            string_schema("Optional provider-safe snapshot summary."),
        ),
        (
            "pathEntries",
            json!({"type": "array", "maxItems": 100, "description": "Optional bounded normalized relative path metadata only; never raw file contents."}),
        ),
        (
            "totalEntries",
            bounded_integer_schema(0, 100_000, "Aggregate tree entry count."),
        ),
        (
            "fileCount",
            bounded_integer_schema(0, 100_000, "Aggregate file count."),
        ),
        (
            "directoryCount",
            bounded_integer_schema(0, 100_000, "Aggregate directory count."),
        ),
        (
            "symlinkCount",
            bounded_integer_schema(0, 100_000, "Aggregate symlink count."),
        ),
        (
            "submoduleCount",
            bounded_integer_schema(0, 100_000, "Aggregate submodule count."),
        ),
        (
            "maxDepth",
            bounded_integer_schema(0, 64, "Maximum path depth."),
        ),
        ("sourceRefs", json!({"type": "array", "maxItems": 25})),
        ("evidenceRefs", json!({"type": "array", "maxItems": 25})),
        (
            "maxAgeDays",
            bounded_integer_schema(1, 366, "Retention limit in days."),
        ),
        ("idempotencyKey", idempotency_schema()),
        ("networkPolicy", network_policy_none_schema()),
        (
            "reason",
            string_schema("Optional provider-safe custody reason."),
        ),
    ]
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

fn command_schema() -> Value {
    string_schema("Shell command executed from trusted runtime working-directory context.")
}

fn idempotency_schema() -> Value {
    string_schema(
        "Stable bounded caller idempotency key for this durable write. This value is provider-visible in the tool-call payload because the caller supplies it, but provider-safe result, status, log, and trace projections redact it.",
    )
}

fn job_resource_id_schema() -> Value {
    string_schema(
        "Exact durable job_process resource id returned by job_start or job_list for the current session scope.",
    )
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn promoted_contracts_are_single_source_closed_schemas() {
        let promoted = supported_operation_names()
            .iter()
            .filter_map(|operation| contract(operation).map(|contract| (*operation, contract)))
            .collect::<Vec<_>>();
        assert_eq!(promoted.len(), 39);
        for (operation, contract) in promoted {
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
            .expect("promoted schema uses only enforced structural keywords");
        }
    }

    #[test]
    fn promoted_catalog_and_runtime_schemas_are_identical() {
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
        let wrong_policy = validate_payload(&json!({
            "operation": "repository_tree_list",
            "networkPolicy": "declared"
        }))
        .expect_err("network policy const must be enforced");
        assert!(wrong_policy.to_string().contains("does not match const"));

        let excessive_limit = validate_payload(&json!({
            "operation": "capability_binding_cockpit_overview",
            "limit": 201
        }))
        .expect_err("cockpit bound must match its domain contract");
        assert!(excessive_limit.to_string().contains("exceeds maximum 200"));
    }

    #[test]
    fn domain_validated_operation_is_not_prematurely_closed() {
        validate_payload(&json!({
            "operation": "filesystem_read",
            "path": "README.md"
        }))
        .expect("unmigrated domain service retains structural ownership");
    }
}
