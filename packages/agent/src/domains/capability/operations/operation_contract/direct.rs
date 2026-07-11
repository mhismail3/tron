//! Closed structural contracts for direct engine and adapter operations.
//!
//! These schemas own only the provider-visible top-level payload shape. Domain
//! services retain semantic checks such as path containment, Git freshness,
//! robots-policy linkage, resource scope, and cross-field requirements.

use serde_json::{Value, json};

use super::{closed_schema, idempotency_schema};

#[cfg(test)]
const ASSIGNED_OPERATIONS: &[&str] = &[
    "observe",
    "state_get",
    "state_set",
    "state_list",
    "filesystem_read",
    "filesystem_list",
    "filesystem_find",
    "filesystem_glob",
    "filesystem_search_text",
    "filesystem_diff",
    "filesystem_write",
    "filesystem_edit",
    "filesystem_apply_patch",
    "git_status",
    "git_diff",
    "git_branch_inventory",
    "git_stage",
    "git_unstage",
    "git_commit",
    "git_branch_start",
    "process_run",
    "job_start",
    "job_status",
    "job_list",
    "job_log",
    "job_cancel",
    "trace_list",
    "trace_get",
    "log_recent",
    "replay_manifest",
    "catalog_search",
    "catalog_inspect",
    "catalog_conformance",
    "repository_tree_snapshot",
    "repository_tree_list",
    "repository_tree_inspect",
    "web_fetch",
    "web_robots_check",
    "web_source_list",
    "web_source_inspect",
    "web_source_archive",
];

pub(super) fn input_schema(operation: &str) -> Option<Value> {
    let (required, fields) = match operation {
        "observe" => (vec!["operation"], vec![("input", string_schema())]),
        "state_get" => (vec!["operation", "namespace", "key"], state_key_fields()),
        "state_set" => (
            vec!["operation", "namespace", "key", "value", "idempotencyKey"],
            state_set_fields(),
        ),
        "state_list" => (
            vec!["operation", "namespace"],
            vec![
                ("scope", state_scope_schema()),
                ("namespace", nonempty_string_schema()),
                ("keyPrefix", string_schema()),
            ],
        ),
        "filesystem_read" => (
            vec!["operation", "path"],
            vec![
                ("path", nonempty_string_schema()),
                ("maxBytes", bounded_integer(1, 262_144)),
            ],
        ),
        "filesystem_list" => (
            vec!["operation"],
            vec![
                ("path", nonempty_string_schema()),
                ("showHidden", boolean_schema()),
                ("maxResults", bounded_integer(1, 2_000)),
            ],
        ),
        "filesystem_find" => (vec!["operation"], filesystem_find_fields()),
        "filesystem_glob" => (vec!["operation", "glob"], filesystem_find_fields()),
        "filesystem_search_text" => (
            vec!["operation", "query"],
            vec![
                ("path", nonempty_string_schema()),
                ("query", string_schema()),
                ("glob", string_schema()),
                ("showHidden", boolean_schema()),
                ("maxResults", bounded_integer(1, 1_000)),
                ("maxFileBytes", bounded_integer(1, 262_144)),
            ],
        ),
        "filesystem_diff" => (
            vec!["operation", "path", "content"],
            filesystem_full_write_fields(false),
        ),
        "filesystem_write" => (
            vec!["operation", "path", "content", "idempotencyKey"],
            filesystem_full_write_fields(true),
        ),
        "filesystem_edit" | "filesystem_apply_patch" => (
            vec!["operation", "path", "oldText", "newText", "idempotencyKey"],
            filesystem_edit_fields(),
        ),
        "git_status" => (
            vec!["operation"],
            vec![
                ("path", nonempty_string_schema()),
                ("maxStatusBytes", bounded_integer(1, 204_800)),
            ],
        ),
        "git_diff" => (
            vec!["operation"],
            vec![
                ("path", nonempty_string_schema()),
                ("maxDiffBytes", bounded_integer(1, 131_072)),
            ],
        ),
        "git_branch_inventory" => (
            vec!["operation"],
            vec![
                ("path", nonempty_string_schema()),
                ("maxBranches", bounded_integer(1, 500)),
                ("maxBranchBytes", bounded_integer(1, 204_800)),
            ],
        ),
        "git_stage" | "git_unstage" => (
            vec![
                "operation",
                "path",
                "expectedHead",
                "reason",
                "idempotencyKey",
            ],
            git_index_mutation_fields(),
        ),
        "git_commit" => (
            vec![
                "operation",
                "expectedHead",
                "expectedIndexTree",
                "message",
                "reason",
                "idempotencyKey",
            ],
            git_commit_fields(),
        ),
        "git_branch_start" => (
            vec![
                "operation",
                "branchName",
                "expectedHead",
                "reason",
                "idempotencyKey",
            ],
            git_branch_start_fields(),
        ),
        "process_run" => (
            vec!["operation", "command", "idempotencyKey"],
            process_fields(true),
        ),
        "job_start" => (
            vec!["operation", "command", "idempotencyKey"],
            job_start_fields(),
        ),
        "job_status" | "job_log" => (
            vec!["operation", "jobResourceId"],
            vec![(
                "jobResourceId",
                described_nonempty_string_schema(
                    "Exact durable job_process resource id returned by job_start or job_list for the current session scope.",
                ),
            )],
        ),
        "job_list" => (
            vec!["operation"],
            vec![
                (
                    "state",
                    enum_schema(&[
                        "running",
                        "completed",
                        "failed",
                        "timed_out",
                        "cancelled",
                        "archived",
                    ]),
                ),
                ("limit", bounded_integer(1, 500)),
            ],
        ),
        "job_cancel" => (
            vec!["operation", "jobResourceId", "idempotencyKey"],
            vec![
                ("jobResourceId", nonempty_string_schema()),
                ("reason", string_schema()),
                ("idempotencyKey", idempotency_schema()),
            ],
        ),
        "trace_list" => (vec!["operation"], trace_filter_fields()),
        "trace_get" => (
            vec!["operation", "traceRecordId"],
            vec![(
                "traceRecordId",
                described_nonempty_string_schema(
                    "Exact provider-safe trace record id returned by trace_list.",
                ),
            )],
        ),
        "log_recent" => (vec!["operation"], trace_filter_fields()),
        "replay_manifest" => (vec!["operation"], Vec::new()),
        "catalog_search" => (vec!["operation"], catalog_search_fields()),
        "catalog_inspect" => (
            vec!["operation", "kind", "id"],
            vec![
                (
                    "kind",
                    enum_schema(&["function", "worker", "trigger_type", "trigger"]),
                ),
                ("id", nonempty_string_schema()),
                ("includeOutputSchema", boolean_schema()),
            ],
        ),
        "catalog_conformance" => (
            vec!["operation", "idempotencyKey"],
            catalog_conformance_fields(),
        ),
        "repository_tree_snapshot" => (
            vec![
                "operation",
                "repositoryRef",
                "rootRef",
                "treeObjectRef",
                "idempotencyKey",
            ],
            repository_tree_snapshot_fields(),
        ),
        "repository_tree_list" => (
            vec!["operation"],
            vec![
                ("limit", bounded_integer(1, 100)),
                ("includeArchived", boolean_schema()),
                (
                    "repositoryRefId",
                    described_nonempty_string_schema(
                        "Optional bounded repository ref id filter; unsupported aliases are rejected.",
                    ),
                ),
            ],
        ),
        "repository_tree_inspect" => (
            vec!["operation", "repositoryTreeResourceId"],
            vec![("repositoryTreeResourceId", nonempty_string_schema())],
        ),
        "web_fetch" => (
            vec!["operation", "url", "idempotencyKey"],
            web_fetch_fields(),
        ),
        "web_robots_check" => (
            vec!["operation", "url", "idempotencyKey"],
            web_robots_fields(),
        ),
        "web_source_list" => (
            vec!["operation"],
            vec![
                ("includeArchived", boolean_schema()),
                ("limit", bounded_integer(1, 100)),
                ("maxPreviewBytes", bounded_integer(1, 2_000)),
            ],
        ),
        "web_source_inspect" => (
            vec!["operation", "webSourceResourceId"],
            vec![
                ("webSourceResourceId", resource_id_schema("web_source")),
                ("webSourceVersionId", nullable_string_schema()),
                ("maxSnippetBytes", bounded_integer(1, 20_000)),
            ],
        ),
        "web_source_archive" => (
            vec![
                "operation",
                "webSourceResourceId",
                "expectedWebSourceVersionId",
                "reason",
                "idempotencyKey",
            ],
            vec![
                ("webSourceResourceId", resource_id_schema("web_source")),
                ("expectedWebSourceVersionId", nonempty_string_schema()),
                ("reason", nonempty_string_schema()),
                ("idempotencyKey", idempotency_schema()),
            ],
        ),
        _ => return None,
    };
    let mut schema = closed_schema(operation, &required, fields);
    let object = schema
        .as_object_mut()
        .expect("closed operation schema is an object");
    match operation {
        "filesystem_find" => {
            object.insert(
                "anyOf".to_owned(),
                json!([
                    {"required": ["query"]},
                    {"required": ["glob"]}
                ]),
            );
        }
        "web_fetch" => {
            object.insert(
                "oneOf".to_owned(),
                json!([
                    {
                        "not": {
                            "anyOf": [
                                {"required": ["webRobotsPolicyResourceId"]},
                                {"required": ["expectedWebRobotsPolicyVersionId"]}
                            ]
                        }
                    },
                    {
                        "required": [
                            "webRobotsPolicyResourceId",
                            "expectedWebRobotsPolicyVersionId"
                        ],
                        "properties": {
                            "webRobotsPolicyResourceId": {"type": "string", "minLength": 1},
                            "expectedWebRobotsPolicyVersionId": {"type": "string", "minLength": 1}
                        }
                    },
                    {
                        "required": [
                            "webRobotsPolicyResourceId",
                            "expectedWebRobotsPolicyVersionId"
                        ],
                        "properties": {
                            "webRobotsPolicyResourceId": {"type": "null"},
                            "expectedWebRobotsPolicyVersionId": {"type": "null"}
                        }
                    }
                ]),
            );
        }
        _ => {}
    }
    Some(schema)
}

fn state_key_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("scope", state_scope_schema()),
        ("namespace", nonempty_string_schema()),
        ("key", nonempty_string_schema()),
    ]
}

fn state_set_fields() -> Vec<(&'static str, Value)> {
    let mut fields = state_key_fields();
    fields.extend([
        ("value", json!({})),
        ("idempotencyKey", idempotency_schema()),
    ]);
    fields
}

fn state_scope_schema() -> Value {
    enum_schema(&["session", "workspace"])
}

fn filesystem_find_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("path", nonempty_string_schema()),
        ("query", string_schema()),
        ("glob", string_schema()),
        ("showHidden", boolean_schema()),
        ("maxResults", bounded_integer(1, 1_000)),
    ]
}

fn filesystem_full_write_fields(durable: bool) -> Vec<(&'static str, Value)> {
    let mut fields = vec![
        ("path", nonempty_string_schema()),
        ("content", string_schema()),
        ("expectedHash", string_schema()),
        ("reason", string_schema()),
        ("maxDiffBytes", bounded_integer(1, 131_072)),
    ];
    if durable {
        fields.extend([
            ("commit", boolean_schema()),
            ("idempotencyKey", idempotency_schema()),
        ]);
    }
    fields
}

fn filesystem_edit_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("path", nonempty_string_schema()),
        ("oldText", nonempty_string_schema()),
        ("newText", string_schema()),
        ("expectedHash", string_schema()),
        ("commit", boolean_schema()),
        ("reason", string_schema()),
        ("maxDiffBytes", bounded_integer(1, 131_072)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn git_index_mutation_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("path", nonempty_string_schema()),
        ("expectedHead", nonempty_string_schema()),
        ("reason", nonempty_string_schema()),
        ("maxStatusBytes", bounded_integer(1, 204_800)),
        ("maxDiffBytes", bounded_integer(1, 131_072)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn git_commit_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("path", nonempty_string_schema()),
        ("expectedHead", nonempty_string_schema()),
        ("expectedIndexTree", nonempty_string_schema()),
        ("message", nonempty_string_schema()),
        ("reason", nonempty_string_schema()),
        ("maxStatusBytes", bounded_integer(1, 204_800)),
        ("maxDiffBytes", bounded_integer(1, 131_072)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn git_branch_start_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("path", nonempty_string_schema()),
        ("branchName", nonempty_string_schema()),
        ("expectedHead", nonempty_string_schema()),
        ("reason", nonempty_string_schema()),
        ("maxStatusBytes", bounded_integer(1, 204_800)),
        ("maxDiffBytes", bounded_integer(1, 131_072)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn process_fields(include_idempotency: bool) -> Vec<(&'static str, Value)> {
    let mut fields = vec![
        ("command", nonempty_string_schema()),
        ("timeoutMs", bounded_integer(1, 120_000)),
        ("maxOutputBytes", bounded_integer(1, 200_000)),
    ];
    if include_idempotency {
        fields.push(("idempotencyKey", idempotency_schema()));
    }
    fields
}

fn job_start_fields() -> Vec<(&'static str, Value)> {
    let mut fields = process_fields(true);
    fields.push((
        "cleanupAfterSeconds",
        json!({"type": "integer", "minimum": 0}),
    ));
    fields
}

fn trace_filter_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("limit", bounded_integer(1, 500)),
        ("traceId", nonempty_string_schema()),
    ]
}

fn catalog_search_fields() -> Vec<(&'static str, Value)> {
    let mut fields = catalog_query_fields();
    fields.extend([
        ("includeProtectedCounts", boolean_schema()),
        ("limit", bounded_integer(1, 500)),
    ]);
    fields
}

fn catalog_conformance_fields() -> Vec<(&'static str, Value)> {
    let mut fields = catalog_query_fields();
    fields.extend([
        ("reason", string_schema()),
        ("includeProtectedCounts", boolean_schema()),
        ("idempotencyKey", idempotency_schema()),
    ]);
    fields
}

fn catalog_query_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("text", string_schema()),
        ("namespacePrefix", string_schema()),
        (
            "visibility",
            enum_schema(&[
                "internal",
                "session",
                "workspace",
                "system",
                "client",
                "worker",
                "agent",
                "admin",
            ]),
        ),
        (
            "effectClass",
            enum_schema(&[
                "pure_read",
                "read",
                "read_only",
                "inspect",
                "deterministic_compute",
                "delegated_invocation",
                "idempotent_write",
                "append_only_event",
                "reversible_side_effect",
                "external_side_effect",
                "irreversible_side_effect",
            ]),
        ),
        (
            "maxRisk",
            enum_schema(&["low", "medium", "high", "critical"]),
        ),
        (
            "health",
            enum_schema(&["healthy", "degraded", "unhealthy", "unknown"]),
        ),
        ("includeInternal", boolean_schema()),
    ]
}

fn repository_tree_snapshot_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("snapshotId", nonempty_string_schema()),
        (
            "repositoryRef",
            reference_schema("Complete repository reference including kind and id or resourceId."),
        ),
        (
            "rootRef",
            reference_schema(
                "Complete workspace-root reference including kind and id or resourceId. Passing only .id is invalid.",
            ),
        ),
        (
            "treeObjectRef",
            described_nonempty_string_schema(
                "Content-free repositoryTreeSnapshotInput.treeObjectRef identity.",
            ),
        ),
        (
            "headRef",
            reference_schema(
                "Optional complete HEAD reference including kind and id or resourceId.",
            ),
        ),
        ("snapshotLabel", nonempty_string_schema()),
        ("snapshotSummary", nonempty_string_schema()),
        (
            "pathEntries",
            json!({
                "type": "array",
                "maxItems": 100,
                "description": "Bounded content-free path metadata; never raw file contents.",
                "items": path_entry_schema()
            }),
        ),
        ("totalEntries", bounded_integer(0, 100_000)),
        ("fileCount", bounded_integer(0, 100_000)),
        ("directoryCount", bounded_integer(0, 100_000)),
        ("symlinkCount", bounded_integer(0, 100_000)),
        ("submoduleCount", bounded_integer(0, 100_000)),
        ("maxDepth", bounded_integer(0, 64)),
        (
            "sourceRefs",
            json!({"type": "array", "maxItems": 25, "items": reference_schema("Source evidence reference.")}),
        ),
        (
            "evidenceRefs",
            json!({"type": "array", "maxItems": 25, "items": reference_schema("Validation evidence reference.")}),
        ),
        ("maxAgeDays", bounded_integer(1, 366)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn reference_schema(description: &str) -> Value {
    json!({
        "type": "object",
        "description": description,
        "required": ["kind"],
        "anyOf": [
            {"required": ["id"]},
            {"required": ["resourceId"]}
        ],
        "additionalProperties": false,
        "properties": {
            "kind": nonempty_string_schema(),
            "id": nonempty_string_schema(),
            "resourceId": nonempty_string_schema(),
            "role": nonempty_string_schema(),
            "versionId": nonempty_string_schema()
        }
    })
}

fn path_entry_schema() -> Value {
    json!({
        "type": "object",
        "required": ["path"],
        "additionalProperties": false,
        "properties": {
            "path": nonempty_string_schema(),
            "kind": enum_schema(&["file", "directory", "symlink", "submodule", "unknown"]),
            "mode": nonempty_string_schema(),
            "objectRef": nonempty_string_schema(),
            "contentHash": nonempty_string_schema(),
            "sizeBytes": {"type": "integer", "minimum": 0}
        }
    })
}

fn web_fetch_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("url", url_schema()),
        ("timeoutMs", bounded_integer(1, 30_000)),
        ("maxResponseBytes", bounded_integer(1, 1_048_576)),
        ("maxOutputBytes", bounded_integer(1, 100_000)),
        ("maxRedirects", bounded_integer(0, 10)),
        ("idempotencyKey", idempotency_schema()),
        (
            "webRobotsPolicyResourceId",
            nullable_string_schema_with_description(
                "Optional current-session web_robots_policy resource id returned by web_robots_check. Supply it together with expectedWebRobotsPolicyVersionId.",
            ),
        ),
        (
            "expectedWebRobotsPolicyVersionId",
            nullable_string_schema_with_description(
                "Expected current web_robots_policy version returned as webRobotsPolicyVersionId by web_robots_check. Supply it together with webRobotsPolicyResourceId.",
            ),
        ),
    ]
}

fn web_robots_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("url", url_schema()),
        (
            "userAgent",
            described_nonempty_string_schema(
                "Optional bounded user-agent token used only for robots.txt matching; omit this field for the default Tron robots user agent.",
            ),
        ),
        ("timeoutMs", bounded_integer(1, 30_000)),
        ("maxRobotsBytes", bounded_integer(1, 262_144)),
        ("maxOutputBytes", bounded_integer(1, 20_000)),
        ("maxRedirects", bounded_integer(0, 5)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn string_schema() -> Value {
    json!({"type": "string"})
}

fn nonempty_string_schema() -> Value {
    json!({"type": "string", "minLength": 1})
}

fn described_nonempty_string_schema(description: &str) -> Value {
    json!({"type": "string", "minLength": 1, "description": description})
}

fn resource_id_schema(kind: &str) -> Value {
    json!({
        "type": "string",
        "minLength": kind.len() + 2,
        "pattern": format!("^{kind}:.+$"),
        "description": format!("Exact {kind} resource id returned by a prior operation.")
    })
}

fn url_schema() -> Value {
    json!({
        "type": "string",
        "minLength": 1,
        "format": "uri",
        "description": "Explicit target URL for this web operation."
    })
}

fn nullable_string_schema() -> Value {
    json!({"type": ["string", "null"]})
}

fn nullable_string_schema_with_description(description: &str) -> Value {
    json!({"type": ["string", "null"], "description": description})
}

fn boolean_schema() -> Value {
    json!({"type": "boolean"})
}

fn bounded_integer(minimum: u64, maximum: u64) -> Value {
    json!({"type": "integer", "minimum": minimum, "maximum": maximum})
}

fn enum_schema(values: &[&str]) -> Value {
    json!({"type": "string", "enum": values})
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use serde_json::json;

    use super::*;
    use crate::engine::FunctionId;
    use crate::engine::kernel::schema;

    fn function_id() -> FunctionId {
        FunctionId::new("capability::execute").expect("canonical function id")
    }

    #[test]
    fn assigned_operation_set_is_exact_and_unique() {
        assert_eq!(ASSIGNED_OPERATIONS.len(), 41);
        assert_eq!(
            ASSIGNED_OPERATIONS
                .iter()
                .copied()
                .collect::<BTreeSet<_>>()
                .len(),
            ASSIGNED_OPERATIONS.len()
        );
        for operation in ASSIGNED_OPERATIONS {
            assert!(input_schema(operation).is_some(), "missing {operation}");
        }
        assert!(input_schema("job_cleanup").is_none());
        assert!(input_schema("filesystem_create_dir").is_none());
    }

    #[test]
    fn assigned_schemas_are_closed_valid_exact_contracts() {
        for operation in ASSIGNED_OPERATIONS {
            let contract = input_schema(operation).expect("assigned schema");
            assert_eq!(contract["additionalProperties"], false, "{operation}");
            assert_eq!(
                contract["schemaCompleteness"], "exact_structural_contract",
                "{operation}"
            );
            assert_eq!(
                contract["properties"]["operation"]["const"], *operation,
                "{operation}"
            );
            assert!(
                contract["required"]
                    .as_array()
                    .is_some_and(|required| required.contains(&json!("operation"))),
                "{operation} must require its selector"
            );
            schema::validate_schema_definition(&function_id(), "operation request", &contract)
                .unwrap_or_else(|error| panic!("invalid {operation} schema: {error}"));
        }
    }

    #[test]
    fn representative_payloads_validate_and_unused_fields_fail_closed() {
        let valid = [
            json!({"operation": "state_set", "scope": "session", "namespace": "agent", "key": "draft", "value": {"ready": true}, "idempotencyKey": "state-set-1"}),
            json!({"operation": "filesystem_find", "query": "contract", "maxResults": 25}),
            json!({"operation": "git_commit", "expectedHead": "head", "expectedIndexTree": "tree", "message": "test: exact contract", "reason": "verified", "idempotencyKey": "commit-1"}),
            json!({"operation": "job_start", "command": "printf test", "idempotencyKey": "job-1", "timeoutMs": 1000}),
            json!({"operation": "catalog_inspect", "kind": "function", "id": "execute::git_status", "includeOutputSchema": true}),
            json!({"operation": "repository_tree_snapshot", "repositoryRef": {"kind": "repository", "id": "repo"}, "rootRef": {"kind": "workspace_root", "id": "root"}, "treeObjectRef": "tree", "idempotencyKey": "tree-1"}),
            json!({"operation": "web_fetch", "url": "https://example.com", "maxRedirects": 3, "idempotencyKey": "fetch-1"}),
            json!({"operation": "web_robots_check", "url": "https://example.com/page", "idempotencyKey": "robots-1"}),
        ];
        for payload in valid {
            let operation = payload["operation"].as_str().expect("operation");
            schema::validate_payload(
                &function_id(),
                "operation request",
                &input_schema(operation).expect("schema"),
                &payload,
            )
            .unwrap_or_else(|error| panic!("valid {operation} payload rejected: {error}"));
        }

        for payload in [
            json!({"operation": "state_list", "namespace": "agent", "limit": 10}),
            json!({"operation": "filesystem_read", "path": "README.md", "command": "ignored"}),
            json!({"operation": "git_status", "maxStatusBytes": 204_801}),
            json!({"operation": "catalog_conformance", "idempotencyKey": "report", "limit": 5}),
            json!({"operation": "web_source_list", "idempotencyKey": "unused"}),
            json!({"operation": "filesystem_find"}),
            json!({"operation": "repository_tree_snapshot", "repositoryRef": {"kind": "repository"}, "rootRef": {"kind": "workspace_root", "id": "root"}, "treeObjectRef": "tree", "idempotencyKey": "tree-1"}),
            json!({"operation": "repository_tree_snapshot", "repositoryRef": {"kind": "repository", "id": "repo"}, "rootRef": {"kind": "workspace_root", "id": "root"}, "treeObjectRef": "tree", "idempotencyKey": "tree-1", "networkPolicy": "none"}),
            json!({"operation": "web_fetch", "url": "https://example.com", "webRobotsPolicyResourceId": "web_robots_policy:test"}),
            json!({"operation": "web_fetch", "url": "https://example.com", "expectedWebRobotsPolicyVersionId": "version-1"}),
        ] {
            let operation = payload["operation"].as_str().expect("operation");
            assert!(
                schema::validate_payload(
                    &function_id(),
                    "operation request",
                    &input_schema(operation).expect("schema"),
                    &payload,
                )
                .is_err(),
                "unused or out-of-bounds field accepted for {operation}"
            );
        }
    }
}
