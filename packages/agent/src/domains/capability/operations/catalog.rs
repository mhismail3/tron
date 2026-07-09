use std::collections::BTreeSet;

use serde_json::{Value, json};

use super::ok_result;
use super::registry::{is_supported_operation, supported_operation_names};
use crate::domains::capability::Deps;
use crate::domains::capability::pool::{
    catalog_function_agent_usage_projection, catalog_function_pool_metadata,
    operation_agent_usage_projection, operation_pool_metadata,
};
use crate::domains::catalog_discovery::service;
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn catalog_search(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let mut discovery =
        service::search_catalog_value(&deps.engine_host, invocation, &invocation.payload).await?;
    annotate_model_facing_invocation(&mut discovery, &invocation.payload);
    annotate_execute_operation_matches(&mut discovery, &invocation.payload);
    let content = catalog_search_content(&discovery);
    Ok(ok_result(
        content,
        json!({
            "primitiveOperation": "catalog_search",
            "status": "ok",
            "catalogDiscovery": discovery
        }),
    ))
}

fn catalog_search_content(discovery: &Value) -> String {
    let visible = discovery
        .pointer("/summary/functions/visible")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let operation_matches = discovery
        .get("executeOperationMatches")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    let operation_search_total = discovery
        .get("executeOperationSearch")
        .and_then(|search| search.get("totalMatches"))
        .and_then(Value::as_u64);
    let mut content = if operation_matches > 0 {
        format!(
            "Catalog search returned {operation_matches} provider-visible execute operation match(es) and {visible} diagnostic catalog function match(es)."
        )
    } else if operation_search_total == Some(0) {
        format!(
            "Catalog search found 0 provider-visible execute operation matches and {visible} diagnostic catalog function match(es)."
        )
    } else {
        format!("Catalog search returned {visible} diagnostic catalog function match(es).")
    };
    if let Some(search) = discovery.get("executeOperationSearch") {
        let total = search
            .get("totalMatches")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let omitted = search.get("omitted").and_then(Value::as_u64).unwrap_or(0);
        let truncated = search
            .get("truncated")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let excluded = search
            .get("effectClassExcludedMatches")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        if truncated {
            content.push_str(&format!(
                " Search truncated: {omitted} additional execute operation match(es) omitted."
            ));
        } else {
            content.push_str(&format!(
                " Search complete: all {total} matching execute operation(s) returned."
            ));
        }
        if excluded > 0 {
            content.push_str(&format!(
                " {excluded} supported operation(s) were excluded by the requested effect class because they are not safe for that discovery mode."
            ));
        }
    }
    content
}

pub(super) async fn catalog_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    if let Some((operation, alias)) = execute_operation_inspect_target(&invocation.payload) {
        let discovery = execute_operation_inspect_projection(&operation, &alias);
        let kind = discovery["kind"].as_str().unwrap_or("execute_operation");
        let id = discovery["id"].as_str().unwrap_or("unknown");
        let required_fields = discovery
            .pointer("/schema/requiredPayloadFields")
            .and_then(Value::as_array)
            .map(|fields| {
                fields
                    .iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join(", ")
            })
            .filter(|fields| !fields.is_empty())
            .unwrap_or_else(|| "operation".to_owned());
        return Ok(ok_result(
            format!(
                "Catalog {kind} inspected: {id}. Required top-level payload fields: {required_fields}.{}",
                execute_operation_invocation_guidance(&operation)
            ),
            json!({
                "primitiveOperation": "catalog_inspect",
                "status": "ok",
                "catalogDiscovery": discovery
            }),
        ));
    }

    let (payload, alias) = normalize_catalog_inspect_payload(&invocation.payload);
    let normalized_invocation = Invocation {
        payload,
        ..invocation.clone()
    };
    let mut discovery = service::inspect_catalog_value(
        &deps.engine_host,
        &normalized_invocation,
        &normalized_invocation.payload,
    )
    .await?;
    if let Some(alias) = alias {
        if let Some(object) = discovery.as_object_mut() {
            object.insert("aliasResolvedFrom".to_owned(), Value::String(alias));
        }
    }
    annotate_model_facing_invocation(&mut discovery, &json!({}));
    let kind = discovery["kind"].as_str().unwrap_or("item");
    let id = discovery["id"].as_str().unwrap_or("unknown");
    Ok(ok_result(
        format!("Catalog {kind} inspected: {id}."),
        json!({
            "primitiveOperation": "catalog_inspect",
            "status": "ok",
            "catalogDiscovery": discovery
        }),
    ))
}

fn execute_operation_inspect_target(payload: &Value) -> Option<(String, String)> {
    let kind = payload.get("kind").and_then(Value::as_str)?;
    if kind != "function" {
        return None;
    }
    let id = payload.get("id").and_then(Value::as_str)?;
    let operation = id.strip_prefix("execute::").unwrap_or(id);
    if is_supported_operation(operation) {
        Some((operation.to_owned(), id.to_owned()))
    } else {
        None
    }
}

fn execute_operation_inspect_projection(operation: &str, alias: &str) -> Value {
    let id = format!("execute::{operation}");
    let agent_usage = operation_agent_usage_projection(operation).unwrap_or_else(|| {
        json!({
            "callable": true,
            "tool": "capability::execute",
            "operation": operation,
            "arguments": {"operation": operation}
        })
    });
    let operation_required_payload_fields = operation_required_payload_fields(operation);
    let required_payload_fields = if operation_required_payload_fields.len() > 1 {
        operation_required_payload_fields
    } else {
        agent_usage
            .pointer("/preflight/requiredPayloadFields")
            .and_then(Value::as_array)
            .filter(|fields| !fields.is_empty())
            .cloned()
            .unwrap_or(operation_required_payload_fields)
    };
    let required_payload_field_names = required_payload_fields
        .iter()
        .filter_map(Value::as_str)
        .collect::<Vec<_>>();
    let effect = agent_usage.get("effect").cloned();
    let preflight = agent_usage.get("preflight").cloned();
    let input_schema = execute_operation_input_schema(operation, &required_payload_field_names);
    let output_schema = execute_operation_output_schema(operation);
    let capability_pool = operation_pool_metadata(operation).map(|metadata| {
        operation_contextual_pool_projection(
            operation,
            serde_json::to_value(metadata.provider_projection())
                .expect("capability pool projection serializes"),
        )
    });
    let model_facing_invocation = json!({
        "tool": "capability::execute",
        "operation": operation,
        "arguments": {"operation": operation},
        "catalogInspectId": id,
        "capabilityPool": capability_pool.clone(),
        "agentUsage": agent_usage.clone()
    });

    let mut projection = json!({
        "kind": "execute_operation",
        "id": id,
        "operation": operation,
        "summary": format!("Provider-visible capability::execute operation {operation}."),
        "providerCallable": true,
        "providerCallableReason": "Invoke through the single provider-visible capability::execute tool with this operation value.",
        "inputSchema": input_schema.clone(),
        "outputSchema": output_schema.clone(),
        "modelFacingInvocation": model_facing_invocation,
        "capabilityPool": capability_pool,
        "agentUsage": agent_usage,
        "schema": {
            "tool": "capability::execute",
            "operation": operation,
            "arguments": {"operation": operation},
            "requiredPayloadFields": required_payload_fields,
            "inputSchema": input_schema,
            "outputSchema": output_schema,
            "payloadPlacement": "Put operation-specific fields at the top level of the capability::execute payload.",
            "schemaCompleteness": "operation_specific_contract",
            "effect": effect,
            "preflight": preflight
        }
    });
    if alias != projection["id"].as_str().unwrap_or_default() {
        if let Some(object) = projection.as_object_mut() {
            object.insert(
                "aliasResolvedFrom".to_owned(),
                Value::String(alias.to_owned()),
            );
        }
    }
    projection
}

fn execute_operation_invocation_guidance(operation: &str) -> &'static str {
    match operation {
        "repository_tree_snapshot" => {
            " Copy complete repositoryRef/rootRef/headRef objects, including kind, from git_status details.git.repository.repositoryTreeSnapshotInput; passing only .id values is invalid."
        }
        "trace_list" => {
            " Current-session scope is supplied by trusted runtime context; do not invent selector or scope fields. Optional top-level fields are limit and traceId only. When using trace_list as whole-session evidence, call it after the operations being audited; otherwise say it only covers records visible at its projection time. Provider transcript tool-call ids may exist for protocol threading and are distinct from raw trace providerInvocationId fields, which trace projections exclude."
        }
        "trace_get" => {
            " Current-session scope is supplied by trusted runtime context; pass only operation and the traceRecordId returned by trace_list."
        }
        "context_control_status" => {
            " Current-session scope is supplied by trusted runtime context; pass only operation. Do not include sessionId or selector fields. The result content summarizes epoch, token budget, composition blocks, and freshness proof without recording a snapshot or action."
        }
        "web_robots_check" => {
            " Pass the explicit target url. On success, pass webRobotsPolicyResourceId unchanged to a robots-gated web_fetch, and copy webRobotsPolicyVersionId into web_fetch.expectedWebRobotsPolicyVersionId."
        }
        "web_fetch" => {
            " Pass the explicit target url. When using robots evidence, pass webRobotsPolicyResourceId unchanged from web_robots_check and copy webRobotsPolicyVersionId into expectedWebRobotsPolicyVersionId; missing or stale versions fail closed before target network I/O."
        }
        _ => "",
    }
}

fn operation_contextual_pool_projection(operation: &str, mut projection: Value) -> Value {
    let usage = operation_agent_usage_projection(operation);
    if let Some(object) = projection.as_object_mut() {
        object.insert(
            "currentInvocation".to_owned(),
            json!({
                "operation": operation,
                "tool": "capability::execute",
                "effect": usage.as_ref().and_then(|usage| usage.get("effect")).cloned(),
                "preflight": usage.as_ref().and_then(|usage| usage.get("preflight")).cloned(),
                "guidance": "For this operation-specific invocation, follow the input schema and preflight fields. Replacement/routing classification is informational unless the user task explicitly asks to replace, shadow, activate, disable, or roll back this operation."
            }),
        );
        if matches!(
            object.get("replacementClass").and_then(Value::as_str),
            Some("runtime_routable")
        ) {
            object.insert(
                "replacementWorkflowBoundary".to_owned(),
                json!({
                    "appliesOnlyWhen": "explicit_replacement_shadow_route_or_rollback_workflow",
                    "notRequiredFor": "normal_read_only_or_session_work_invocation",
                    "safeDefault": "invoke_builtin_operation_with_exact_schema_until_a_governed_route_is_active"
                }),
            );
        }
    }
    projection
}

fn execute_operation_input_schema(operation: &str, required_fields: &[&str]) -> Value {
    let mut properties = serde_json::Map::new();
    properties.insert(
        "operation".to_owned(),
        json!({
            "type": "string",
            "const": operation,
            "description": "Exact capability::execute operation selector."
        }),
    );
    for field in required_fields {
        if *field == "operation" {
            continue;
        }
        properties.insert(
            (*field).to_owned(),
            execute_operation_field_schema(operation, field),
        );
    }

    add_operation_specific_optional_fields(operation, &mut properties);
    let additional_properties = !matches!(
        operation,
        "repository_tree_snapshot" | "repository_tree_list" | "repository_tree_inspect"
    );
    json!({
        "type": "object",
        "required": required_fields,
        "properties": properties,
        "additionalProperties": additional_properties,
        "payloadPlacement": "top_level_capability_execute_payload",
        "schemaCompleteness": "operation_specific_contract"
    })
}

fn execute_operation_field_schema(operation: &str, field: &str) -> Value {
    match (operation, field) {
        ("capability_shadow_trial_decision_record", "capabilityShadowTrialRequestResourceId") => {
            json!({
                "type": "string",
                "description": "Exact capability_shadow_trial_request resource id returned by capability_shadow_trial_request_record."
            })
        }
        (
            "capability_shadow_trial_decision_record",
            "expectedCapabilityShadowTrialRequestVersionId",
        ) => json!({
            "type": "string",
            "description": "Exact current request version id returned with the capability shadow trial request; stale versions are rejected."
        }),
        ("capability_shadow_trial_decision_record", "decision") => json!({
            "type": "string",
            "enum": ["approved", "rejected", "denied", "disabled", "aborted"],
            "description": "Governance decision for the metadata-only shadow trial. Approved becomes approved_trial; rejected/denied require denialEvidence."
        }),
        ("capability_shadow_trial_decision_record", "reason") => json!({
            "type": "string",
            "description": "Bounded provider-safe decision rationale. Secrets, commands, paths, prompts, grant ids, and authority ids are rejected."
        }),
        ("capability_shadow_trial_run_record", "capabilityShadowTrialDecisionResourceId") => {
            json!({
                "type": "string",
                "description": "Exact capability_shadow_trial_decision resource id returned by capability_shadow_trial_decision_record."
            })
        }
        (
            "capability_shadow_trial_run_record",
            "expectedCapabilityShadowTrialDecisionVersionId",
        ) => json!({
            "type": "string",
            "description": "Exact current decision version id returned with the approved shadow trial decision; stale versions are rejected."
        }),
        ("capability_shadow_trial_run_record", "builtInProjection")
        | ("capability_shadow_trial_run_record", "candidateProjection") => {
            shadow_git_status_projection_schema(field)
        }
        ("repository_tree_snapshot", "repositoryRef") => json!({
            "type": "object",
            "description": "Required bounded repository reference; copy the complete repositoryTreeSnapshotInput.repositoryRef object from git_status when available, including kind. Passing only .id is invalid."
        }),
        ("repository_tree_snapshot", "rootRef") => json!({
            "type": "object",
            "description": "Required bounded workspace/repository-root reference; copy the complete repositoryTreeSnapshotInput.rootRef object from git_status when available, including kind. Passing only .id is invalid."
        }),
        ("repository_tree_snapshot", "treeObjectRef") => json!({
            "type": "string",
            "description": "Required bounded tree object token; copy repositoryTreeSnapshotInput.treeObjectRef from git_status when available. Never pass raw tree contents."
        }),
        ("repository_tree_snapshot", "idempotencyKey") => json!({
            "type": "string",
            "description": "Required stable bounded idempotency key for this metadata-only snapshot write."
        }),
        ("repository_tree_inspect", "repositoryTreeResourceId") => json!({
            "type": "string",
            "description": "Exact repository_tree_snapshot resource id returned by repository_tree_snapshot or repository_tree_list."
        }),
        ("repository_tree_list", "repositoryRefId") => json!({
            "type": "string",
            "description": "Optional bounded repository ref id filter; unsupported aliases are rejected."
        }),
        ("trace_get", "traceRecordId") => json!({
            "type": "string",
            "description": "Exact provider-safe trace record id returned in details.records[].id by trace_list for the current session."
        }),
        (_, "sessionId") => json!({
            "type": "string",
            "description": "Current trusted session id. If supplied, it must match the invocation session context."
        }),
        (_, "url") => json!({
            "type": "string",
            "format": "uri",
            "description": "Explicit target URL for this web operation. web_robots_check fetches only the target origin robots.txt; web_fetch fetches exactly this target URL after authority and optional robots checks."
        }),
        (_, field) => json!({
            "type": "string",
            "description": format!(
                "Operation-specific top-level payload field `{field}` required before invoking this capability."
            )
        }),
    }
}

fn shadow_git_status_projection_schema(field: &str) -> Value {
    json!({
        "type": "object",
        "description": format!(
            "{field} is a bounded provider-safe git_status projection for a metadata-only shadow comparison; never include raw commands, raw paths, logs, file contents, grants, or authority ids."
        ),
        "required": [
            "operation",
            "status",
            "headState",
            "indexState",
            "worktreeState",
            "evidenceRef"
        ],
        "properties": {
            "operation": {"const": "git_status"},
            "status": {"type": "string", "enum": ["clean", "dirty", "unavailable", "unknown"]},
            "headState": {"type": "string", "enum": ["known", "unknown"]},
            "indexState": {"type": "string", "enum": ["known", "unknown"]},
            "worktreeState": {"type": "string", "enum": ["clean", "dirty", "unknown"]},
            "truncation": {"type": "string", "enum": ["none", "bounded", "truncated", "unknown"]},
            "evidenceRef": {
                "type": "object",
                "description": "Concrete bounded evidence ref for this shadow projection; placeholder evidence:none is rejected.",
                "required": ["kind", "resourceId", "role"],
                "properties": {
                    "kind": {"type": "string"},
                    "resourceId": {"type": "string"},
                    "role": {"type": "string"}
                }
            }
        }
    })
}

fn add_operation_specific_optional_fields(
    operation: &str,
    properties: &mut serde_json::Map<String, Value>,
) {
    let optional_fields: Vec<(&str, Value)> = match operation {
        "capability_binding_cockpit_overview" => vec![(
            "targetOperation",
            json!({
                "type": "string",
                "description": "Optional exact provider-visible operation name. When set, returns one compact cockpit row with role, replacement, binding, shadow, route, rollback, and scoped evidence facts for that operation."
            }),
        )],
        "web_robots_check" => vec![
            (
                "userAgent",
                json!({"type": "string", "description": "Optional bounded user-agent token used only for robots.txt matching. Browser-like wildcard strings such as `*` are invalid; omit this field for the default Tron robots user agent."}),
            ),
            (
                "maxRobotsBytes",
                json!({"type": "integer", "minimum": 1, "maximum": 262144, "description": "Maximum captured robots.txt bytes for bounded policy evidence."}),
            ),
            (
                "maxOutputBytes",
                json!({"type": "integer", "minimum": 1, "maximum": 100000, "description": "Maximum provider-visible redacted robots preview bytes."}),
            ),
            (
                "maxRedirects",
                json!({"type": "integer", "minimum": 0, "maximum": 10, "description": "Maximum robots.txt redirects. Redirect targets are validated before follow."}),
            ),
            (
                "timeoutMs",
                json!({"type": "integer", "minimum": 1, "maximum": 30000, "description": "Request timeout in milliseconds."}),
            ),
        ],
        "web_fetch" => vec![
            (
                "webRobotsPolicyResourceId",
                json!({"type": ["string", "null"], "description": "Optional current-session web_robots_policy resource id returned by web_robots_check. Required together with expectedWebRobotsPolicyVersionId when the task requires robots-gated fetch proof."}),
            ),
            (
                "expectedWebRobotsPolicyVersionId",
                json!({"type": ["string", "null"], "description": "Expected current web_robots_policy version id returned as webRobotsPolicyVersionId by web_robots_check. Stale or missing versions fail closed before target network I/O when a robots policy ref is supplied."}),
            ),
            (
                "maxResponseBytes",
                json!({"type": "integer", "minimum": 1, "maximum": 1048576, "description": "Maximum captured response bytes for source evidence."}),
            ),
            (
                "maxOutputBytes",
                json!({"type": "integer", "minimum": 1, "maximum": 100000, "description": "Maximum provider-visible redacted extracted text bytes."}),
            ),
            (
                "maxRedirects",
                json!({"type": "integer", "minimum": 0, "maximum": 10, "description": "Maximum target fetch redirects. Redirect targets are validated before follow."}),
            ),
            (
                "timeoutMs",
                json!({"type": "integer", "minimum": 1, "maximum": 30000, "description": "Request timeout in milliseconds."}),
            ),
        ],
        "capability_shadow_trial_decision_record" => vec![
            (
                "capabilityShadowTrialDecisionId",
                json!({"type": "string", "description": "Optional bounded caller-visible decision id for idempotent resource identity."}),
            ),
            (
                "decisionEvidence",
                json!({"type": "array", "description": "Optional bounded refs supporting the decision. Use concrete provider-safe evidence refs only."}),
            ),
            (
                "denialEvidence",
                json!({"type": "array", "description": "Required when decision is rejected or denied; bounded provider-safe denial evidence refs."}),
            ),
            (
                "idempotencyKey",
                json!({"type": "string", "description": "Optional stable bounded idempotency key when not supplied by invocation context."}),
            ),
        ],
        "capability_shadow_trial_run_record" => vec![
            (
                "capabilityShadowTrialRunId",
                json!({"type": "string", "description": "Optional bounded caller-visible run id for idempotent resource identity."}),
            ),
            (
                "capabilityShadowTrialEvidenceId",
                json!({"type": "string", "description": "Optional bounded caller-visible evidence id for the shadow evidence resource."}),
            ),
            (
                "trialRunOutcome",
                json!({"type": "string", "enum": ["completed", "aborted", "disabled"], "description": "Optional run outcome; omitted defaults to completed. Completed runs require builtInProjection and candidateProjection."}),
            ),
            (
                "auditRefs",
                json!({"type": "array", "description": "Optional bounded audit refs for the metadata-only run."}),
            ),
            (
                "idempotencyKey",
                json!({"type": "string", "description": "Optional stable bounded idempotency key when not supplied by invocation context."}),
            ),
        ],
        "repository_tree_snapshot" => vec![
            (
                "snapshotId",
                json!({"type": "string", "description": "Optional caller-visible snapshot id for idempotent resource identity."}),
            ),
            (
                "headRef",
                json!({"type": "object", "description": "Optional bounded commit/head reference; copy the complete repositoryTreeSnapshotInput.headRef object from git_status when available, including kind."}),
            ),
            (
                "snapshotLabel",
                json!({"type": "string", "description": "Optional bounded short label for the repository tree snapshot."}),
            ),
            (
                "snapshotSummary",
                json!({"type": "string", "description": "Optional bounded summary for the repository tree snapshot."}),
            ),
            (
                "pathEntries",
                json!({"type": "array", "description": "Optional bounded normalized relative path metadata only; never raw file contents."}),
            ),
            (
                "sourceRefs",
                json!({"type": "array", "description": "Optional bounded source refs for provider-safe custody evidence."}),
            ),
            (
                "evidenceRefs",
                json!({"type": "array", "description": "Optional bounded evidence refs for trace/resource proof."}),
            ),
            (
                "reason",
                json!({"type": "string", "description": "Optional bounded reason for the custody snapshot."}),
            ),
            ("networkPolicy", network_policy_none_schema()),
            (
                "maxAgeDays",
                json!({"type": "integer", "description": "Optional retention limit in days."}),
            ),
            (
                "totalEntries",
                json!({"type": "integer", "description": "Optional bounded aggregate tree entry count."}),
            ),
            (
                "fileCount",
                json!({"type": "integer", "description": "Optional bounded aggregate file count."}),
            ),
            (
                "directoryCount",
                json!({"type": "integer", "description": "Optional bounded aggregate directory count."}),
            ),
            (
                "symlinkCount",
                json!({"type": "integer", "description": "Optional bounded aggregate symlink count."}),
            ),
            (
                "submoduleCount",
                json!({"type": "integer", "description": "Optional bounded aggregate submodule count."}),
            ),
            (
                "maxDepth",
                json!({"type": "integer", "description": "Optional bounded maximum path depth."}),
            ),
        ],
        "repository_tree_list" => vec![
            (
                "limit",
                json!({"type": "integer", "description": "Optional bounded result limit."}),
            ),
            (
                "includeArchived",
                json!({"type": "boolean", "description": "Optional archived snapshot inclusion flag."}),
            ),
            (
                "repositoryRefId",
                json!({"type": "string", "description": "Optional bounded repository ref id filter; unsupported aliases are rejected."}),
            ),
            ("networkPolicy", network_policy_none_schema()),
        ],
        "repository_tree_inspect" => vec![("networkPolicy", network_policy_none_schema())],
        _ => Vec::new(),
    };
    for (field, schema) in optional_fields {
        properties.entry(field.to_owned()).or_insert(schema);
    }
}

fn network_policy_none_schema() -> Value {
    json!({
        "const": "none",
        "description": "Optional explicit no-network policy proof; only `none` is accepted."
    })
}

fn execute_operation_output_schema(operation: &str) -> Value {
    if operation == "git_status" {
        return json!({
            "type": "object",
            "required": ["content", "details"],
            "properties": {
                "content": {
                    "description": "Provider-safe text summary of repository status."
                },
                "details": {
                    "type": "object",
                    "description": "Bounded provider-safe git status evidence. Absolute paths, raw commands, raw logs, grants, and authority ids are excluded.",
                    "required": ["primitiveOperation", "status", "git"],
                    "properties": {
                        "primitiveOperation": {"const": "git_status"},
                        "status": {"type": "string"},
                        "git": {
                            "type": "object",
                            "required": ["schemaVersion", "status", "operation", "summary", "repository", "evidence"],
                            "properties": {
                                "schemaVersion": {"const": "tron.git_readonly.v1"},
                                "status": {"type": "string"},
                                "operation": {"const": "status"},
                                "summary": {
                                    "type": "object",
                                    "properties": {
                                        "stagedCount": {"type": "integer"},
                                        "unstagedCount": {"type": "integer"},
                                        "untrackedCount": {"type": "integer"},
                                        "conflictedCount": {"type": "integer"}
                                    }
                                },
                                "repository": {
                                    "type": "object",
                                    "description": "Provider-safe repository facts using workspace-relative path refs.",
                                    "properties": {
                                        "branch": {"type": ["string", "null"]},
                                        "detachedHead": {"type": "boolean"},
                                        "headOid": {"type": ["string", "null"]},
                                        "headTreeOid": {"type": ["string", "null"]},
                                        "treeObjectRef": {"type": ["string", "null"], "description": "Provider-safe bounded tree object token for repository_tree_snapshot."},
                                        "repositoryTreeSnapshotInput": {"type": "object", "description": "Copyable provider-safe refs for repository_tree_snapshot."},
                                        "hasUpstream": {"type": "boolean"},
                                        "ahead": {"type": ["integer", "null"]},
                                        "behind": {"type": ["integer", "null"]},
                                        "pathspec": {"type": "string"},
                                        "repositoryRoot": {"description": "Workspace-relative repository root ref."},
                                        "worktreeRoot": {"description": "Workspace-relative worktree root ref."},
                                        "requestedPath": {"description": "Workspace-relative requested path ref."}
                                    }
                                },
                                "evidence": {
                                    "type": "object",
                                    "properties": {
                                        "resourceRefs": {"type": "array"},
                                        "statusLimitBytes": {"type": "integer"},
                                        "statusTruncated": {"type": "boolean"},
                                        "statusPorcelainV1Z": {"type": "string"}
                                    }
                                },
                                "staged": {"type": "array"},
                                "unstaged": {"type": "array"},
                                "untracked": {"type": "array"},
                                "conflicted": {"type": "array"}
                            }
                        }
                    }
                }
            },
            "schemaCompleteness": "operation_specific_contract"
        });
    }
    if operation == "web_robots_check" {
        return json!({
            "type": "object",
            "required": ["content", "details"],
            "properties": {
                "content": {
                    "description": "Provider-safe robots-policy summary including copy-ready robots evidence refs for a later robots-gated web_fetch."
                },
                "details": {
                    "type": "object",
                    "required": ["primitiveOperation", "status", "web"],
                    "properties": {
                        "primitiveOperation": {"const": "web_robots_check"},
                        "status": {"const": "ok"},
                        "web": {
                            "type": "object",
                            "required": [
                                "schemaVersion",
                                "status",
                                "operation",
                                "webRobotsPolicyResourceId",
                                "webRobotsPolicyVersionId",
                                "resourceRefs"
                            ],
                            "properties": {
                                "schemaVersion": {"const": "tron.web_robots_policy.v1"},
                                "status": {"const": "checked"},
                                "operation": {"const": "web_robots_check"},
                                "webRobotsPolicyResourceId": {"type": "string", "description": "Copy this into web_fetch.webRobotsPolicyResourceId when a subsequent fetch must be robots-gated."},
                                "webRobotsPolicyVersionId": {"type": "string", "description": "Copy this into web_fetch.expectedWebRobotsPolicyVersionId for freshness."},
                                "resourceRefs": {"type": "array", "description": "Bounded robots-policy resource refs; resourceRefs[0].versionId equals webRobotsPolicyVersionId."}
                            }
                        }
                    }
                }
            },
            "schemaCompleteness": "operation_specific_contract"
        });
    }
    if operation == "web_fetch" {
        return json!({
            "type": "object",
            "required": ["content", "details"],
            "properties": {
                "content": {
                    "description": "Provider-safe fetch/source summary; raw HTML and raw bytes are not returned directly."
                },
                "details": {
                    "type": "object",
                    "required": ["primitiveOperation", "status", "web"],
                    "properties": {
                        "primitiveOperation": {"const": "web_fetch"},
                        "status": {"const": "ok"},
                        "web": {
                            "type": "object",
                            "required": [
                                "schemaVersion",
                                "status",
                                "operation",
                                "webSourceResourceId",
                                "webSourceVersionId",
                                "resourceRefs"
                            ],
                            "properties": {
                                "schemaVersion": {"const": "tron.web_source.v1"},
                                "status": {"const": "fetched"},
                                "operation": {"const": "web_fetch"},
                                "webSourceResourceId": {"type": "string"},
                                "webSourceVersionId": {"type": "string"},
                                "robotsPolicyRefs": {"type": "array", "description": "Present when fetch was linked to current robots evidence; contains bounded resource/version refs only."},
                                "resourceRefs": {"type": "array", "description": "Bounded source resource refs for later web_source_list/inspect/archive operations."}
                            }
                        }
                    }
                }
            },
            "schemaCompleteness": "operation_specific_contract"
        });
    }
    if operation == "trace_list" {
        return json!({
            "type": "object",
            "required": ["content", "details"],
            "properties": {
                "content": {
                    "description": "Provider-safe trace summary with completed/in-progress counts and projection-boundary guidance."
                },
                "details": {
                    "type": "object",
                    "description": "Provider-safe current-session trace list. Raw provider invocation ids, grant ids, idempotency keys, raw requests/results, paths, commands, logs, and file contents are excluded from records[].",
                    "required": ["primitiveOperation", "status", "projectionBoundary", "statusSummary", "records"],
                    "properties": {
                        "primitiveOperation": {"const": "trace_list"},
                        "status": {"const": "ok"},
                        "projectionBoundary": trace_projection_boundary_output_schema(),
                        "statusSummary": {
                            "type": "object",
                            "required": ["totalRecords", "completedStatusCounts", "inProgressCount", "currentTraceListMayAppearRunning", "currentInvocationStatus"],
                            "properties": {
                                "totalRecords": {"type": "integer"},
                                "completedStatusCounts": {
                                    "type": "object",
                                    "description": "Counts by completed trace status, normally ok/failed."
                                },
                                "completedStatusValuesOnlyOkFailed": {"type": "boolean"},
                                "inProgressCount": {"type": "integer"},
                                "currentTraceListMayAppearRunning": {"const": true},
                                "currentInvocationStatus": {
                                    "const": "pending_at_projection_time",
                                    "description": "The current trace_list invocation is projected before its own completion is recorded."
                                },
                                "inProgressInterpretation": {"type": "string"},
                                "completedStatusGuidance": {"type": "string"},
                                "answerGuidance": {"type": "string"}
                            }
                        },
                        "records": {
                            "type": "array",
                            "description": "Bounded provider-safe trace records for the current session.",
                            "items": provider_safe_trace_record_output_schema()
                        }
                    }
                }
            },
            "schemaCompleteness": "operation_specific_contract"
        });
    }
    if operation == "trace_get" {
        return json!({
            "type": "object",
            "required": ["content", "details"],
            "properties": {
                "content": {
                    "description": "Provider-safe trace-record summary for one current-session trace record."
                },
                "details": {
                    "type": "object",
                    "description": "Provider-safe focused trace record. Raw provider invocation ids, grant ids, idempotency keys, raw requests/results, paths, commands, logs, and file contents are excluded.",
                    "required": ["primitiveOperation", "status", "projectionBoundary", "record"],
                    "properties": {
                        "primitiveOperation": {"const": "trace_get"},
                        "status": {"const": "ok"},
                        "projectionBoundary": trace_projection_boundary_output_schema(),
                        "record": provider_safe_trace_record_output_schema()
                    }
                }
            },
            "schemaCompleteness": "operation_specific_contract"
        });
    }
    json!({
        "type": "object",
        "required": ["content", "details"],
        "properties": {
            "content": {
                "description": "Provider-safe text summary of the operation result."
            },
            "details": {
                "type": "object",
                "description": "Bounded provider-safe evidence for the operation result.",
                "properties": {
                    "primitiveOperation": {"const": operation},
                    "status": {"type": "string"}
                }
            }
        },
        "schemaCompleteness": "operation_specific_contract"
    })
}

fn trace_projection_boundary_output_schema() -> Value {
    json!({
        "type": "object",
        "description": "Explains that traceId, invocationId, parentInvocationId, runId, sessionRef, and workspaceRef are provider-safe engine refs, not raw provider invocation ids.",
        "properties": {
            "providerVisibleProjection": {"type": "string"},
            "providerVisibleMeaning": {"type": "string"},
            "internalAuditStorage": {"type": "string"},
            "safeRefSemantics": {"type": "string"},
            "recordProof": {"type": "string"},
            "transcriptToolCallBoundary": {"type": "string"},
            "operationBoundary": {"type": "string"},
            "rawCommandEvidenceGuidance": {"type": "string"},
            "answerGuidance": {"type": "string"},
            "traceGetUse": {"type": "string"}
        }
    })
}

fn provider_safe_trace_record_output_schema() -> Value {
    json!({
        "type": "object",
        "required": [
            "schemaVersion",
            "id",
            "traceId",
            "invocationId",
            "modelPrimitiveName",
            "operation",
            "status",
            "request",
            "result",
            "projectionBoundary",
            "authority",
            "redaction"
        ],
        "properties": {
            "schemaVersion": {"const": "tron.trace.provider_safe.v1"},
            "id": {"type": ["string", "null"], "description": "Provider-safe trace record ref."},
            "version": {"type": ["string", "null"]},
            "timestamp": {"type": ["string", "null"]},
            "traceId": {"type": ["string", "null"], "description": "Provider-safe engine trace ref, not a raw provider invocation id."},
            "invocationId": {"type": ["string", "null"], "description": "Provider-safe engine invocation ref, not a raw provider tool-call id."},
            "parentInvocationId": {"type": ["string", "null"]},
            "runId": {"type": ["string", "null"]},
            "sessionRef": {"type": ["string", "null"]},
            "workspaceRef": {"type": ["string", "null"]},
            "turn": {"type": ["integer", "null"]},
            "modelPrimitiveName": {"type": ["string", "null"]},
            "operation": {"type": ["string", "null"]},
            "status": {"type": ["string", "null"]},
            "startedAt": {"type": ["string", "null"]},
            "completedAt": {"type": ["string", "null"]},
            "durationMs": {"type": ["integer", "null"]},
            "request": {
                "type": "object",
                "required": ["hash", "rawStoredInProjection"],
                "properties": {
                    "hash": {"type": ["string", "null"]},
                    "rawStoredInProjection": {"const": false}
                }
            },
            "result": {
                "type": "object",
                "required": ["hash", "rawStoredInProjection"],
                "properties": {
                    "hash": {"type": ["string", "null"]},
                    "rawStoredInProjection": {"const": false}
                }
            },
            "projectionBoundary": {
                "type": "object",
                "required": [
                    "providerVisibleProjection",
                    "safeEngineRefsOnly",
                    "rawAuditFieldsProjected",
                    "internalAuditStorageMayRetainRawAuditFields"
                ],
                "properties": {
                    "providerVisibleProjection": {"const": true},
                    "safeEngineRefsOnly": {"const": true},
                    "rawAuditFieldsProjected": {"const": false},
                    "internalAuditStorageMayRetainRawAuditFields": {"const": true}
                }
            },
            "authority": {
                "type": "object",
                "required": [
                    "actorKind",
                    "scopeCount",
                    "rawActorIdStored",
                    "rawAuthorityGrantIdStored",
                    "rawIdempotencyKeyStored"
                ],
                "properties": {
                    "actorKind": {"type": ["string", "null"]},
                    "scopeCount": {"type": "integer"},
                    "rawActorIdStored": {"const": false},
                    "rawAuthorityGrantIdStored": {"const": false},
                    "rawIdempotencyKeyStored": {"const": false}
                }
            },
            "error": {
                "type": ["object", "null"],
                "description": "Provider-safe error summary. Raw error details are not stored in the projection."
            },
            "redaction": {
                "type": "object",
                "required": [
                    "rawProviderInvocationIdsExcluded",
                    "rawGrantIdsExcluded",
                    "rawAuthorityIdsExcluded",
                    "rawIdempotencyKeysExcluded",
                    "rawWorkingDirectoryExcluded",
                    "rawRequestExcluded",
                    "rawResultExcluded",
                    "rawFilesExcluded",
                    "rawVcsExcluded"
                ],
                "properties": {
                    "rawProviderInvocationIdsExcluded": {"const": true},
                    "rawGrantIdsExcluded": {"const": true},
                    "rawAuthorityIdsExcluded": {"const": true},
                    "rawIdempotencyKeysExcluded": {"const": true},
                    "rawWorkingDirectoryExcluded": {"const": true},
                    "rawRequestExcluded": {"const": true},
                    "rawResultExcluded": {"const": true},
                    "rawFilesExcluded": {"const": true},
                    "rawVcsExcluded": {"const": true}
                }
            }
        },
        "notProjectedFields": [
            "providerInvocationId",
            "authorityGrantId",
            "actorId",
            "idempotencyKey",
            "workingDirectory",
            "rawRequest",
            "rawResult",
            "rawCommand",
            "rawLog",
            "rawPath",
            "fileContents"
        ]
    })
}

fn normalize_catalog_inspect_payload(payload: &Value) -> (Value, Option<String>) {
    let Some(kind) = payload.get("kind").and_then(Value::as_str) else {
        return (payload.clone(), None);
    };
    if kind != "function" {
        return (payload.clone(), None);
    }
    let Some(id) = payload.get("id").and_then(Value::as_str) else {
        return (payload.clone(), None);
    };
    let Some(canonical) = catalog_function_id_for_model_alias(id) else {
        return (payload.clone(), None);
    };
    let mut normalized = payload.clone();
    if let Some(object) = normalized.as_object_mut() {
        object.insert("id".to_owned(), Value::String(canonical.to_owned()));
    }
    (normalized, Some(id.to_owned()))
}

fn operation_required_payload_fields(operation: &str) -> Vec<Value> {
    let fields = match operation {
        "repository_tree_snapshot" => vec![
            "operation",
            "repositoryRef",
            "rootRef",
            "treeObjectRef",
            "idempotencyKey",
        ],
        "trace_get" => vec!["operation", "traceRecordId"],
        "goal_create" => vec!["operation", "objective", "idempotencyKey"],
        "goal_inspect" => vec!["operation", "goalResourceId"],
        "goal_cancel" => vec!["operation", "goalResourceId", "reason", "idempotencyKey"],
        "question_create" => vec!["operation", "prompt", "idempotencyKey"],
        "question_inspect" => vec!["operation", "questionResourceId"],
        "question_answer" => vec![
            "operation",
            "questionResourceId",
            "expectedQuestionVersionId",
            "answerText",
            "reason",
            "idempotencyKey",
        ],
        "memory_inspect" => vec!["operation", "recordResourceId"],
        "memory_query_inspect" => vec!["operation", "queryResourceId"],
        "memory_decision_inspect" => vec!["operation", "decisionResourceId"],
        "context_control_status" => vec!["operation"],
        "context_control_action_inspect" => vec!["operation", "contextControlActionResourceId"],
        "media_inspect" => vec!["operation", "mediaResourceId"],
        "import_history_inspect" => vec!["operation", "importHistoryResourceId"],
        "repository_tree_inspect" => vec!["operation", "repositoryTreeResourceId"],
        "import_preview_inspect" => vec!["operation", "importPreviewResourceId"],
        "program_execution_inspect" => vec!["operation", "programExecutionResourceId"],
        "prompt_artifact_inspect" => vec!["operation", "promptArtifactResourceId"],
        "update_diagnostic_inspect" => vec!["operation", "updateDiagnosticResourceId"],
        "device_inspect" => vec!["operation", "deviceRegistrationResourceId"],
        "notification_inspect" => vec!["operation", "notificationResourceId"],
        "procedural_state_inspect" => vec!["operation", "proceduralRecordResourceId"],
        "procedural_activation_request_inspect" => {
            vec!["operation", "proceduralActivationRequestResourceId"]
        }
        "procedural_activation_decision_inspect" => {
            vec!["operation", "proceduralActivationDecisionResourceId"]
        }
        "schedule_inspect" => vec!["operation", "scheduleResourceId"],
        "tool_source_inspect" => vec!["operation", "toolSourceResourceId"],
        "subagent_task_inspect" => vec!["operation", "subagentTaskResourceId"],
        "worker_package_inspect" => vec!["operation", "workerPackageResourceId"],
        "module_inspect" => vec!["operation", "moduleManifestResourceId"],
        "module_proposal_inspect" => vec!["operation", "moduleProposalResourceId"],
        "module_validation_inspect" => vec!["operation", "moduleValidationReportResourceId"],
        "module_install_request_inspect" => vec!["operation", "moduleInstallRequestResourceId"],
        "module_install_decision_inspect" => vec!["operation", "moduleInstallDecisionResourceId"],
        "module_dependency_request_inspect" => {
            vec!["operation", "moduleDependencyRequestResourceId"]
        }
        "module_dependency_decision_inspect" => {
            vec!["operation", "moduleDependencyDecisionResourceId"]
        }
        "module_dependency_policy_inspect" => vec!["operation", "moduleDependencyPolicyResourceId"],
        "capability_binding_request_inspect" => {
            vec!["operation", "capabilityBindingRequestResourceId"]
        }
        "capability_binding_decision_inspect" => {
            vec!["operation", "capabilityBindingDecisionResourceId"]
        }
        "capability_binding_policy_inspect" => {
            vec!["operation", "capabilityBindingPolicyResourceId"]
        }
        "capability_shadow_trial_request_record" => vec![
            "operation",
            "title",
            "targetOperation",
            "currentBuiltInOwner",
            "ownershipClass",
            "bindingMode",
            "candidateAdapter",
            "authorityConstraints",
            "contractEvidenceRefs",
            "evidenceRefs",
            "staleVersionGuard",
            "rollbackRef",
            "disableRef",
            "abortRef",
            "rationale",
            "idempotencyKey",
        ],
        "capability_shadow_trial_decision_record" => vec![
            "operation",
            "capabilityShadowTrialRequestResourceId",
            "expectedCapabilityShadowTrialRequestVersionId",
            "decision",
            "reason",
        ],
        "capability_shadow_trial_run_record" => vec![
            "operation",
            "capabilityShadowTrialDecisionResourceId",
            "expectedCapabilityShadowTrialDecisionVersionId",
            "builtInProjection",
            "candidateProjection",
        ],
        "capability_shadow_trial_evidence_inspect" => {
            vec!["operation", "capabilityShadowTrialEvidenceResourceId"]
        }
        "capability_replacement_candidate_inspect" => {
            vec!["operation", "capabilityReplacementCandidateResourceId"]
        }
        "capability_route_binding_inspect" => {
            vec!["operation", "capabilityRouteBindingResourceId"]
        }
        "capability_route_event_inspect" => vec!["operation", "capabilityRouteEventResourceId"],
        "module_lifecycle_inspect" => vec!["operation", "moduleLifecycleResourceId"],
        "module_runtime_inspect" => vec!["operation", "moduleRuntimeResourceId"],
        "web_fetch" => vec!["operation", "url"],
        "web_robots_check" => vec!["operation", "url"],
        "web_source_inspect" => vec!["operation", "webSourceResourceId"],
        "web_research_request_inspect" => vec!["operation", "webResearchRequestResourceId"],
        "web_research_review_inspect" => vec!["operation", "webResearchReviewResourceId"],
        "web_research_source_inspect" => vec!["operation", "webResearchSourceResourceId"],
        _ => vec!["operation"],
    };
    fields
        .iter()
        .map(|field| Value::String((*field).to_owned()))
        .collect()
}

fn annotate_model_facing_invocation(discovery: &mut Value, payload: &Value) {
    let supported_execute_operations = supported_operation_names_for_guidance(payload);
    let supported_execute_operation_filter = supported_operation_guidance_filter(payload);
    if let Some(object) = discovery.as_object_mut() {
        object.insert(
            "modelFacingGuidance".to_owned(),
            json!({
                "catalogInspect": "Use functions[].id exactly as catalog_inspect kind=function id when inspecting engine substrate.",
                "capabilityExecute": "For normal session work, invoke capability::execute operations. Catalog functions are engine substrate unless modelFacingInvocation points at an execute operation.",
                "operationSearch": "If executeOperationMatches is present, use those operation names directly with capability::execute. They are provider-visible operations, not separate catalog functions.",
                "executeSchemaInspection": "Before invoking a provider-visible operation, inspect execute::<operation> with catalog_inspect to get exact top-level payload fields. Backing catalog function ids are secondary diagnostics.",
                "internalDiscovery": "Internal catalog functions are inspect-only by default. Request diagnostics or kernel-evolution context before using them to reason about engine internals.",
                "supportedExecuteOperations": supported_execute_operations,
                "supportedExecuteOperationsFilter": supported_execute_operation_filter
            }),
        );
    }

    if let Some(functions) = discovery.get_mut("functions").and_then(Value::as_array_mut) {
        for function in functions {
            let Some(id) = function.get("id").and_then(Value::as_str) else {
                continue;
            };
            let catalog_id = id.to_owned();
            if let Some(object) = function.as_object_mut() {
                annotate_catalog_function_pool(object, &catalog_id);
                if let Some(operation) = model_execute_operation_for_function_id(&catalog_id) {
                    object.insert(
                        "modelFacingInvocation".to_owned(),
                        json!({
                            "tool": "capability::execute",
                            "operation": operation,
                            "arguments": {"operation": operation},
                            "catalogInspectId": catalog_id,
                            "providerSchemaInspectId": format!("execute::{operation}"),
                            "preferredSchemaInspection": execute_schema_inspection_step(&operation),
                            "schemaInspectionOrder": "Inspect providerSchemaInspectId before invoking the provider-visible operation; inspect catalogInspectId only when engine-substrate diagnostics are explicitly needed.",
                            "capabilityPool": operation_pool_metadata(&operation).map(|metadata| metadata.provider_projection()),
                            "agentUsage": operation_agent_usage_projection(&operation)
                        }),
                    );
                    object.insert(
                        "agentUsage".to_owned(),
                        catalog_function_agent_usage_projection(&catalog_id, Some(&operation)),
                    );
                } else {
                    mark_catalog_target_non_callable(object);
                    object.insert(
                        "agentUsage".to_owned(),
                        catalog_function_agent_usage_projection(&catalog_id, None),
                    );
                }
            }
        }
    }

    if discovery.get("kind").and_then(Value::as_str) == Some("function") {
        let Some(id) = discovery.get("id").and_then(Value::as_str) else {
            return;
        };
        let catalog_id = id.to_owned();
        if let Some(object) = discovery.as_object_mut() {
            annotate_catalog_function_pool(object, &catalog_id);
            if let Some(operation) = model_execute_operation_for_function_id(&catalog_id) {
                object.insert(
                    "modelFacingInvocation".to_owned(),
                    json!({
                        "tool": "capability::execute",
                        "operation": operation,
                        "arguments": {"operation": operation},
                        "catalogInspectId": catalog_id,
                        "providerSchemaInspectId": format!("execute::{operation}"),
                        "preferredSchemaInspection": execute_schema_inspection_step(&operation),
                        "schemaInspectionOrder": "Inspect providerSchemaInspectId before invoking the provider-visible operation; inspect catalogInspectId only when engine-substrate diagnostics are explicitly needed.",
                        "capabilityPool": operation_pool_metadata(&operation).map(|metadata| metadata.provider_projection()),
                        "agentUsage": operation_agent_usage_projection(&operation)
                    }),
                );
                object.insert(
                    "agentUsage".to_owned(),
                    catalog_function_agent_usage_projection(&catalog_id, Some(&operation)),
                );
            } else {
                mark_catalog_target_non_callable(object);
                object.insert(
                    "agentUsage".to_owned(),
                    catalog_function_agent_usage_projection(&catalog_id, None),
                );
            }
        }
    }
}

fn supported_operation_names_for_guidance(payload: &Value) -> Vec<&'static str> {
    if catalog_search_requests_read_only(payload) {
        return supported_operation_names()
            .iter()
            .copied()
            .filter(|operation| operation_is_read_only_inspection_safe(operation))
            .collect();
    }
    supported_operation_names().iter().copied().collect()
}

fn supported_operation_guidance_filter(payload: &Value) -> Value {
    if catalog_search_requests_read_only(payload) {
        return json!({
            "effectClass": "pure_read",
            "mode": "read_only_inspection_safe",
            "reason": "Filtered by the active read-only discovery request so generic fallback guidance does not suggest mutating operations."
        });
    }
    json!({"effectClass": "all", "mode": "unfiltered"})
}

fn annotate_execute_operation_matches(discovery: &mut Value, payload: &Value) {
    let namespace_prefix = catalog_search_namespace_prefix(payload);
    let query = payload
        .get("text")
        .and_then(Value::as_str)
        .and_then(OperationSearchQuery::from_text)
        .or_else(|| {
            namespace_prefix
                .as_deref()
                .and_then(OperationSearchQuery::from_text)
        });
    let Some(query) = query else {
        return;
    };
    let limit = payload
        .get("limit")
        .and_then(Value::as_u64)
        .map(|limit| limit as usize)
        .unwrap_or(20)
        .clamp(1, 50);
    let mut matches = supported_operation_names()
        .iter()
        .filter_map(|operation| operation_match_projection(operation, &query))
        .collect::<Vec<_>>();
    let plan_operations = operation_search_plan_supported_operations(&query);
    let trace_operations = trace_evidence_plan_supported_operations(&query);
    let module_governance_operations = module_governance_plan_supported_operations(&query);
    for operation in &plan_operations {
        promote_or_insert_planned_operation_match(&mut matches, operation);
    }
    for operation in &trace_operations {
        promote_or_insert_trace_operation_match(&mut matches, operation);
    }
    for operation in &module_governance_operations {
        promote_or_insert_planned_operation_match(&mut matches, operation);
    }
    if let Some(namespace_prefix) = namespace_prefix {
        for operation in supported_operation_names()
            .iter()
            .filter(|operation| operation_matches_namespace_prefix(operation, &namespace_prefix))
        {
            promote_or_insert_namespace_operation_match(&mut matches, operation);
        }
    }
    if !plan_operations.is_empty()
        || !trace_operations.is_empty()
        || !module_governance_operations.is_empty()
    {
        let allowed = plan_operations
            .iter()
            .chain(trace_operations.iter())
            .chain(module_governance_operations.iter())
            .copied()
            .collect::<BTreeSet<_>>();
        matches.retain(|entry| {
            entry
                .get("operation")
                .and_then(Value::as_str)
                .is_some_and(|operation| allowed.contains(operation))
        });
    }
    let mut effect_excluded_matches = Vec::new();
    if catalog_search_requests_read_only(payload) {
        let (included, excluded): (Vec<_>, Vec<_>) = matches.into_iter().partition(|entry| {
            entry
                .get("operation")
                .and_then(Value::as_str)
                .is_some_and(operation_is_read_only_inspection_safe)
        });
        matches = included;
        effect_excluded_matches = excluded
            .into_iter()
            .map(effect_class_exclusion_projection)
            .collect::<Vec<_>>();
    }
    matches.sort_by(|left, right| {
        match_rank(left["matchKind"].as_str().unwrap_or_default())
            .cmp(&match_rank(right["matchKind"].as_str().unwrap_or_default()))
            .then_with(|| {
                right["score"]
                    .as_u64()
                    .unwrap_or(0)
                    .cmp(&left["score"].as_u64().unwrap_or(0))
            })
            .then_with(|| {
                left["operation"]
                    .as_str()
                    .unwrap_or_default()
                    .cmp(right["operation"].as_str().unwrap_or_default())
            })
    });
    let total = matches.len();
    matches.truncate(limit);
    let effect_excluded_total = effect_excluded_matches.len();
    effect_excluded_matches.truncate(20);
    let all_discovered_inspect_targets =
        discovered_inspect_targets_projection(&matches, &effect_excluded_matches);
    if let Some(object) = discovery.as_object_mut() {
        object.insert(
            "executeOperationSearch".to_owned(),
            json!({
                "query": query.display,
                "canonicalQuery": query.canonical,
                "terms": query.terms,
                "totalMatches": total,
                "returnedMatches": matches.len(),
                "truncated": total > matches.len(),
                "omitted": total.saturating_sub(matches.len()),
                "effectClassExcludedMatches": effect_excluded_total,
            }),
        );
        if !all_discovered_inspect_targets.is_empty() {
            object.insert(
                "allDiscoveredInspectTargets".to_owned(),
                Value::Array(all_discovered_inspect_targets),
            );
        }
        if !effect_excluded_matches.is_empty() {
            object.insert(
                "effectClassExcludedOperationMatches".to_owned(),
                Value::Array(effect_excluded_matches),
            );
        }
        if let Some(plan) = operation_search_plan_projection(&query) {
            object.insert("agentNextStep".to_owned(), readiness_plan_next_step(&plan));
            object.insert("agentSearchPlan".to_owned(), plan);
        } else if let Some(plan) = trace_evidence_plan_projection(&query) {
            object.insert("agentSearchPlan".to_owned(), plan);
            if let Some(next_step) = preferred_execute_schema_next_step(&matches) {
                object.insert("agentNextStep".to_owned(), next_step);
            }
        } else if let Some(plan) = module_governance_plan_projection(&query) {
            object.insert(
                "agentNextStep".to_owned(),
                module_governance_plan_next_step(&plan),
            );
            object.insert("agentSearchPlan".to_owned(), plan);
        } else if let Some(next_step) = preferred_execute_schema_next_step(&matches) {
            object.insert("agentNextStep".to_owned(), next_step);
        }
        object.insert("executeOperationMatches".to_owned(), Value::Array(matches));
        if total == 0
            && effect_excluded_total == 0
            && looks_like_unsupported_operation_candidate(&query)
        {
            object.insert(
                "unsupportedOperationCandidate".to_owned(),
                Value::Bool(true),
            );
            object.insert(
                "unsupportedOperationRecovery".to_owned(),
                unsupported_operation_recovery_projection(&query),
            );
        }
    }
}

fn discovered_inspect_targets_projection(
    included_matches: &[Value],
    effect_excluded_matches: &[Value],
) -> Vec<Value> {
    included_matches
        .iter()
        .map(|entry| discovered_inspect_target_projection(entry, false))
        .chain(
            effect_excluded_matches
                .iter()
                .map(|entry| discovered_inspect_target_projection(entry, true)),
        )
        .collect()
}

fn discovered_inspect_target_projection(
    entry: &Value,
    excluded_from_immediate_invocation: bool,
) -> Value {
    let operation = entry
        .get("operation")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let catalog_inspect_id = entry
        .get("catalogInspectId")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| format!("execute::{operation}"));
    let read_only_inspection_safe = entry
        .pointer("/agentUsage/effect/readOnlyInspectionSafe")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let mut target = json!({
        "operation": operation,
        "tool": "capability::execute",
        "catalogInspectId": catalog_inspect_id.clone(),
        "inspectOperation": "catalog_inspect",
        "inspectArguments": {
            "operation": "catalog_inspect",
            "kind": "function",
            "id": catalog_inspect_id,
            "maxSchemaBytes": 8000
        },
        "invokeArguments": {"operation": operation},
        "readOnlyInspectionSafe": read_only_inspection_safe,
        "excludedFromImmediateInvocation": excluded_from_immediate_invocation,
        "agentGuidance": if excluded_from_immediate_invocation {
            "Supported operation found but excluded from immediate invocation by the requested effect class. Inspect the schema only; do not invoke unless the task explicitly allows its effect."
        } else {
            "Inspect the schema before invoking the operation."
        }
    });
    if let Some(reason) = entry.get("exclusionReason").and_then(Value::as_str) {
        if let Some(object) = target.as_object_mut() {
            object.insert(
                "exclusionReason".to_owned(),
                Value::String(reason.to_owned()),
            );
        }
    }
    target
}

fn effect_class_exclusion_projection(mut entry: Value) -> Value {
    if let Some(object) = entry.as_object_mut() {
        object.insert(
            "excludedByEffectClass".to_owned(),
            Value::String("pure_read".to_owned()),
        );
        object.insert(
            "exclusionReason".to_owned(),
            Value::String(
                "Supported operation exists but is not read-only inspection safe; inspect its schema only when the task explicitly allows write-like evidence or state changes, and do not invoke it during pure-read discovery.".to_owned(),
            ),
        );
    }
    entry
}

fn catalog_search_namespace_prefix(payload: &Value) -> Option<String> {
    let prefix = payload.get("namespacePrefix")?.as_str()?;
    let prefix = canonical_operation_search_text(prefix);
    if prefix.len() >= 3 {
        Some(prefix)
    } else {
        None
    }
}

fn catalog_search_requests_read_only(payload: &Value) -> bool {
    payload
        .get("effectClass")
        .and_then(Value::as_str)
        .map(|effect_class| {
            matches!(
                effect_class.trim().to_ascii_lowercase().as_str(),
                "pure_read" | "read" | "read_only" | "inspect"
            )
        })
        .unwrap_or(false)
}

fn readiness_plan_next_step(plan: &Value) -> Value {
    json!({
        "priority": "follow_agent_search_plan_primary_inspection",
        "reason": "For replacement or shadow readiness, first inspect the exact targeted cockpit row. It is read-only and tells whether evidence exists; do not infer unsupported shadow list operations.",
        "primaryInspection": plan["primaryInspection"],
        "thenFollow": "agentSearchPlan.readOnlySequence",
        "completionRule": plan["completionRule"]
    })
}

fn module_governance_plan_next_step(plan: &Value) -> Value {
    json!({
        "priority": "follow_module_governance_read_only_plan",
        "reason": "For broad module-governance readiness checks, use the listed read-only overview/list operations directly. Their default payload is complete: operation plus optional limit/includeArchived only. Inspect individual schemas only when you need non-default fields or a concrete resource id from list output.",
        "thenFollow": "agentSearchPlan.readOnlySequence",
        "schemaPolicy": plan["schemaPolicy"],
        "completionRule": plan["completionRule"]
    })
}

fn looks_like_unsupported_operation_candidate(query: &OperationSearchQuery) -> bool {
    let canonical = query.canonical.as_str();
    canonical.contains('_')
        && (canonical.starts_with("capability_")
            || canonical.starts_with("catalog_")
            || canonical.starts_with("context_")
            || canonical.starts_with("git_")
            || canonical.starts_with("module_")
            || canonical.starts_with("trace_")
            || canonical.starts_with("log_")
            || canonical.ends_with("_list")
            || canonical.ends_with("_inspect")
            || canonical.ends_with("_record")
            || canonical.ends_with("_activate")
            || canonical.ends_with("_rollback")
            || canonical.ends_with("_disable"))
}

fn unsupported_operation_recovery_projection(query: &OperationSearchQuery) -> Value {
    let mut alternatives = vec![
        recovery_alternative(
            "catalog_search",
            json!({"operation": "catalog_search", "text": query.display}),
            "Search the exact supported provider-visible operation pool before invoking.",
        ),
        recovery_alternative(
            "catalog_inspect",
            json!({"operation": "catalog_inspect", "kind": "function", "id": "execute::<supported_operation>"}),
            "Inspect the exact schema for a supported operation returned by catalog_search.",
        ),
        recovery_alternative(
            "capability_binding_cockpit_overview",
            json!({"operation": "capability_binding_cockpit_overview", "targetOperation": "<supported_operation>"}),
            "Inspect replacement, binding, shadow, route, rollback, role, and preflight readiness for one exact operation.",
        ),
    ];

    let canonical = query.canonical.as_str();
    if canonical.contains("replacement") {
        alternatives.push(recovery_alternative(
            "capability_replacement_candidate_list",
            json!({"operation": "capability_replacement_candidate_list"}),
            "List recorded replacement candidates; this is read-only metadata and may be empty.",
        ));
    }
    if canonical.contains("route") {
        alternatives.extend([
            recovery_alternative(
                "capability_route_binding_list",
                json!({"operation": "capability_route_binding_list"}),
                "List recorded route bindings; this does not activate or change routing.",
            ),
            recovery_alternative(
                "capability_route_event_list",
                json!({"operation": "capability_route_event_list"}),
                "List route events for activation, disable, rollback, and failed-closed history.",
            ),
        ]);
    }
    if canonical.contains("binding") {
        alternatives.extend([
            recovery_alternative(
                "capability_binding_request_list",
                json!({"operation": "capability_binding_request_list"}),
                "List recorded binding requests; this does not create or approve a request.",
            ),
            recovery_alternative(
                "capability_binding_decision_list",
                json!({"operation": "capability_binding_decision_list"}),
                "List recorded binding decisions; this is the read-only decision history.",
            ),
            recovery_alternative(
                "capability_binding_policy_list",
                json!({"operation": "capability_binding_policy_list"}),
                "List recorded binding policies; active policy metadata does not imply runtime routing.",
            ),
        ]);
    }
    if canonical.contains("shadow") {
        alternatives.push(recovery_alternative(
            "capability_shadow_trial_evidence_inspect",
            json!({"operation": "capability_shadow_trial_evidence_inspect", "capabilityShadowTrialEvidenceResourceId": "<exact evidence resource id>"}),
            "Inspect shadow evidence only when an exact evidence resource id is already known; use cockpit overview for availability and counts.",
        ));
    }

    json!({
        "query": query.display,
        "canonicalQuery": query.canonical,
        "supportedOperation": false,
        "guidance": "No supported capability::execute operation matched this operation-like query. Do not call the queried name. Use the listed alternatives or inspect the exact supported operation returned by catalog_search.",
        "closestReadOnlyAlternatives": alternatives,
    })
}

fn recovery_alternative(operation: &str, payload: Value, reason: &str) -> Value {
    json!({
        "operation": operation,
        "tool": "capability::execute",
        "arguments": payload,
        "readOnlyInspectionSafe": true,
        "reason": reason,
        "agentUsage": operation_agent_usage_projection(operation)
    })
}

fn preferred_execute_schema_next_step(matches: &[Value]) -> Option<Value> {
    let operation = matches
        .first()
        .and_then(|entry| entry.get("operation"))
        .and_then(Value::as_str)?;
    let mut next_step = json!({
        "priority": "inspect_execute_operation_schema_first",
        "reason": "Before invoking a provider-visible capability::execute operation, inspect the execute::<operation> schema for exact top-level payload fields. Backing catalog function ids are engine substrate and are secondary unless the task is diagnostics or kernel evolution.",
        "schemaInspection": execute_schema_inspection_step(operation)
    });
    if matches
        .first()
        .is_some_and(operation_match_is_read_only_inspection_safe)
    {
        next_step["thenInvoke"] = json!({
            "tool": "capability::execute",
            "operation": operation,
            "arguments": {"operation": operation}
        });
    } else {
        next_step["priority"] = json!("inspect_write_like_operation_before_use");
        next_step["reason"] = json!(
            "This supported operation is not read-only inspection safe. Inspect the execute::<operation> schema and only invoke it when the task explicitly allows the documented state change, resource write, approval, or policy effect."
        );
        next_step["thenInvokeBlocked"] = json!({
            "operation": operation,
            "reason": "Operation metadata is not read-only inspection safe; do not invoke directly from discovery.",
            "requiresSchemaInspection": true
        });
    }
    Some(next_step)
}

fn operation_match_is_read_only_inspection_safe(entry: &Value) -> bool {
    entry
        .pointer("/agentUsage/effect/readOnlyInspectionSafe")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        && !entry
            .pointer("/agentUsage/effect/mutatesState")
            .and_then(Value::as_bool)
            .unwrap_or(true)
}

#[derive(Clone, Debug)]
struct OperationSearchQuery {
    display: String,
    canonical: String,
    terms: Vec<String>,
}

impl OperationSearchQuery {
    fn from_text(query: &str) -> Option<Self> {
        let display = query.trim().to_owned();
        let canonical = canonical_operation_search_text(&display);
        if canonical.len() < 3 || canonical == "capability_execute" {
            return None;
        }
        let terms = canonical
            .split('_')
            .filter_map(search_term)
            .collect::<Vec<_>>();
        Some(Self {
            display,
            canonical,
            terms,
        })
    }
}

fn canonical_operation_search_text(query: &str) -> String {
    let query = query
        .trim()
        .strip_prefix("execute::")
        .unwrap_or_else(|| query.trim())
        .replace("::", "_")
        .to_ascii_lowercase();
    let mut canonical = String::with_capacity(query.len());
    let mut previous_separator = false;
    for ch in query.chars() {
        if ch.is_ascii_alphanumeric() || ch == '_' {
            canonical.push(ch);
            previous_separator = false;
        } else if !previous_separator {
            canonical.push('_');
            previous_separator = true;
        }
    }
    canonical.trim_matches('_').to_owned()
}

fn operation_match_projection(operation: &str, query: &OperationSearchQuery) -> Option<Value> {
    let operation_key = operation.to_ascii_lowercase();
    let catalog_key = direct_catalog_function_id_for_execute_operation(operation)
        .map(str::to_owned)
        .unwrap_or_default()
        .replace("::", "_")
        .to_ascii_lowercase();
    let has_direct_catalog_key = !catalog_key.is_empty();
    let (match_kind, score) = if operation_key == query.canonical
        || (has_direct_catalog_key && catalog_key == query.canonical)
        || query.canonical.contains(&operation_key)
        || (has_direct_catalog_key && query.canonical.contains(&catalog_key))
    {
        ("exact", 400)
    } else if operation_key.starts_with(&query.canonical)
        || (has_direct_catalog_key && catalog_key.starts_with(&query.canonical))
    {
        ("prefix", 300)
    } else if query.canonical.len() >= 5
        && (operation_key.contains(&query.canonical)
            || (has_direct_catalog_key && catalog_key.contains(&query.canonical)))
    {
        ("contains", 200)
    } else if allows_term_matches(query)
        && terms_match_operation(&query.terms, &operation_key, &catalog_key)
    {
        ("terms", 150)
    } else if allows_intent_matches(query) {
        let score = intent_match_score(operation, query)?;
        ("intent", score)
    } else {
        return None;
    };
    Some(json!({
        "operation": operation,
        "tool": "capability::execute",
        "arguments": {"operation": operation},
        "catalogInspectId": format!("execute::{operation}"),
        "schemaInspection": execute_schema_inspection_step(operation),
        "matchKind": match_kind,
        "score": score,
        "capabilityPool": operation_pool_metadata(operation).map(|metadata| metadata.provider_projection()),
        "agentUsage": operation_agent_usage_projection(operation)
    }))
}

fn planned_operation_match_projection(operation: &str) -> Value {
    json!({
        "operation": operation,
        "tool": "capability::execute",
        "arguments": {"operation": operation},
        "catalogInspectId": format!("execute::{operation}"),
        "schemaInspection": execute_schema_inspection_step(operation),
        "matchKind": "plan",
        "score": 260,
        "capabilityPool": operation_pool_metadata(operation).map(|metadata| metadata.provider_projection()),
        "agentUsage": operation_agent_usage_projection(operation)
    })
}

fn trace_operation_match_projection(operation: &str) -> Value {
    let score = match operation {
        "trace_list" => 285,
        "trace_get" => 275,
        "catalog_inspect" => 265,
        _ => 260,
    };
    json!({
        "operation": operation,
        "tool": "capability::execute",
        "arguments": {"operation": operation},
        "catalogInspectId": format!("execute::{operation}"),
        "schemaInspection": execute_schema_inspection_step(operation),
        "matchKind": "trace_plan",
        "score": score,
        "capabilityPool": operation_pool_metadata(operation).map(|metadata| metadata.provider_projection()),
        "agentUsage": operation_agent_usage_projection(operation)
    })
}

fn namespace_operation_match_projection(operation: &str) -> Value {
    json!({
        "operation": operation,
        "tool": "capability::execute",
        "arguments": {"operation": operation},
        "catalogInspectId": format!("execute::{operation}"),
        "schemaInspection": execute_schema_inspection_step(operation),
        "matchKind": "namespace",
        "score": 240,
        "capabilityPool": operation_pool_metadata(operation).map(|metadata| metadata.provider_projection()),
        "agentUsage": operation_agent_usage_projection(operation)
    })
}

fn execute_schema_inspection_step(operation: &str) -> Value {
    json!({
        "operation": "catalog_inspect",
        "tool": "capability::execute",
        "arguments": {
            "operation": "catalog_inspect",
            "kind": "function",
            "id": format!("execute::{operation}"),
            "maxSchemaBytes": 8000
        },
        "readOnlyInspectionSafe": true,
        "reason": "Inspect the provider-visible execute-operation schema and required top-level payload fields before invoking."
    })
}

fn promote_or_insert_planned_operation_match(matches: &mut Vec<Value>, operation: &str) {
    let planned = planned_operation_match_projection(operation);
    if let Some(existing) = matches
        .iter_mut()
        .find(|entry| entry["operation"] == operation)
    {
        *existing = planned;
    } else {
        matches.push(planned);
    }
}

fn promote_or_insert_trace_operation_match(matches: &mut Vec<Value>, operation: &str) {
    let planned = trace_operation_match_projection(operation);
    if let Some(existing) = matches
        .iter_mut()
        .find(|entry| entry["operation"] == operation)
    {
        if existing["matchKind"] == "exact" {
            return;
        }
        *existing = planned;
    } else {
        matches.push(planned);
    }
}

fn promote_or_insert_namespace_operation_match(matches: &mut Vec<Value>, operation: &str) {
    if matches
        .iter()
        .any(|entry| entry["operation"].as_str() == Some(operation))
    {
        return;
    }
    matches.push(namespace_operation_match_projection(operation));
}

fn match_rank(match_kind: &str) -> usize {
    match match_kind {
        "exact" => 0,
        "prefix" => 1,
        "namespace" => 2,
        "trace_plan" => 3,
        "plan" => 4,
        "contains" => 5,
        "terms" => 6,
        "intent" => 7,
        _ => 5,
    }
}

fn operation_matches_namespace_prefix(operation: &str, namespace_prefix: &str) -> bool {
    let operation_key = operation.to_ascii_lowercase();
    operation_key.starts_with(namespace_prefix)
        || operation_pool_metadata(operation).is_some_and(|metadata| {
            canonical_operation_search_text(metadata.family.as_ref()) == namespace_prefix
                || canonical_operation_search_text(metadata.owner.as_ref()) == namespace_prefix
        })
}

fn terms_match_operation(terms: &[String], operation_key: &str, catalog_key: &str) -> bool {
    if terms.len() < 2 {
        return false;
    }
    terms
        .iter()
        .all(|term| operation_key.split('_').any(|part| part == term) || catalog_key.contains(term))
}

fn allows_term_matches(query: &OperationSearchQuery) -> bool {
    query.display.chars().any(char::is_whitespace)
        || !looks_like_unsupported_operation_candidate(query)
}

fn intent_match_score(operation: &str, query: &OperationSearchQuery) -> Option<u64> {
    if query.terms.len() < 2 {
        return None;
    }
    let query_terms = query_terms(query);
    let (direct_terms, context_terms) = operation_search_terms(operation);
    let direct_hits = query_terms
        .iter()
        .filter(|term| direct_terms.contains(*term))
        .count();
    let context_hits = query_terms
        .iter()
        .filter(|term| context_terms.contains(*term))
        .count();
    if direct_hits == 0 || direct_hits + context_hits < 2 {
        return None;
    }
    Some((direct_hits as u64 * 25) + (context_hits as u64 * 5))
}

fn query_terms(query: &OperationSearchQuery) -> BTreeSet<String> {
    query.terms.iter().cloned().collect()
}

fn allows_intent_matches(query: &OperationSearchQuery) -> bool {
    if !query.display.chars().any(char::is_whitespace) {
        return false;
    }
    supported_operations_in_query(query).len() <= 1
}

fn supported_operations_in_query(query: &OperationSearchQuery) -> Vec<&'static str> {
    supported_operation_names()
        .iter()
        .copied()
        .filter(|operation| query.canonical.contains(operation))
        .collect()
}

fn operation_search_terms(operation: &str) -> (BTreeSet<String>, BTreeSet<String>) {
    let mut direct = token_set(operation);
    if let Some(catalog_key) = direct_catalog_function_id_for_execute_operation(operation) {
        direct.extend(token_set(catalog_key));
    }

    let mut context = BTreeSet::new();
    if let Some(metadata) = operation_pool_metadata(operation) {
        context.extend(token_set(metadata.family.as_ref()));
        context.extend(token_set(metadata.owner.as_ref()));
        context.extend(token_set(metadata.audience.as_str()));
        context.extend(token_set(metadata.replacement_class.as_str()));
        context.extend(token_set(metadata.agent_default_visibility.as_str()));
        context.extend(token_set(metadata.purpose));
        context.extend(token_set(metadata.effect));
        context.extend(token_set(metadata.risk));
        context.extend(token_set(metadata.authority_boundary));
        context.extend(token_set(metadata.evidence_boundary));
        context.extend(token_set(metadata.minimality_decision.as_str()));
        context.extend(token_set(metadata.evolution_path));
        context.extend(token_set(metadata.next_action));
    }
    context.extend(direct.iter().cloned());
    (direct, context)
}

fn token_set(text: &str) -> BTreeSet<String> {
    canonical_operation_search_text(text)
        .split('_')
        .filter_map(search_term)
        .collect()
}

fn search_term(term: &str) -> Option<String> {
    if term.len() < 3 {
        return None;
    }
    if matches!(
        term,
        "capability"
            | "capabilities"
            | "execute"
            | "function"
            | "functions"
            | "operation"
            | "operations"
            | "list"
            | "lists"
            | "inspect"
            | "inspects"
            | "inspection"
            | "record"
            | "records"
            | "read"
            | "only"
            | "safe"
            | "none"
    ) {
        return None;
    }
    Some(term.to_owned())
}

fn operation_search_plan_projection(query: &OperationSearchQuery) -> Option<Value> {
    let (target, query_terms) = operation_search_plan_target(query)?;
    if query_terms.is_empty() {
        return None;
    }

    let mut followups = vec![recovery_alternative(
        "capability_binding_cockpit_overview",
        json!({"operation": "capability_binding_cockpit_overview", "targetOperation": target}),
        "Inspect this operation's role, replacement class, binding, shadow, route, rollback, and scoped evidence counts without invoking the adapter.",
    )];
    if query_terms.contains("replacement") || query_terms.contains("candidate") {
        followups.push(recovery_alternative(
            "capability_replacement_candidate_list",
            json!({"operation": "capability_replacement_candidate_list", "limit": 25}),
            "List recorded replacement candidates; an empty list means no candidate exists in scope.",
        ));
    }
    if query_terms.contains("route") || query_terms.contains("routing") {
        followups.extend([
            recovery_alternative(
                "capability_route_binding_list",
                json!({"operation": "capability_route_binding_list", "limit": 25}),
                "List explicit route bindings without activating, disabling, or rolling back routing.",
            ),
            recovery_alternative(
                "capability_route_event_list",
                json!({"operation": "capability_route_event_list", "limit": 25}),
                "List activation, routed invocation, disable, rollback, and failed-closed route events.",
            ),
        ]);
    }
    if query_terms.contains("binding") {
        followups.extend([
            recovery_alternative(
                "capability_binding_request_list",
                json!({"operation": "capability_binding_request_list", "limit": 25}),
                "List recorded binding requests; this is read-only and may be empty.",
            ),
            recovery_alternative(
                "capability_binding_decision_list",
                json!({"operation": "capability_binding_decision_list", "limit": 25}),
                "List approval or rejection history for binding requests.",
            ),
            recovery_alternative(
                "capability_binding_policy_list",
                json!({"operation": "capability_binding_policy_list", "limit": 25}),
                "List active or historical binding policies; this does not activate routing.",
            ),
        ]);
    }
    let contextual_write_operations = if query_terms.contains("shadow")
        || query_terms.contains("trial")
        || query_terms.contains("evidence")
    {
        vec![
            contextual_write_operation(
                "capability_shadow_trial_request_record",
                "recording a governed metadata-only shadow request after explicit task, approval, and candidate evidence",
            ),
            contextual_write_operation(
                "capability_shadow_trial_decision_record",
                "recording a governance decision for an exact shadow request resource and version",
            ),
            contextual_write_operation(
                "capability_shadow_trial_run_record",
                "recording a metadata-only shadow run for an approved decision with bounded built-in and candidate projections",
            ),
        ]
    } else {
        Vec::new()
    };

    Some(json!({
        "purpose": "Deterministic read-only plan for a capability readiness query with one exact target operation.",
        "targetOperation": target,
        "primaryInspection": {
            "tool": "capability::execute",
            "operation": "capability_binding_cockpit_overview",
            "arguments": {"operation": "capability_binding_cockpit_overview", "targetOperation": target},
            "readOnlyInspectionSafe": true,
            "reason": "Returns one exact operation row with readiness, route, binding, shadow, rollback, and evidence facts."
        },
        "readOnlySequence": followups,
        "adapterInvocationSchemaInspection": {
            "tool": "capability::execute",
            "operation": "catalog_inspect",
            "arguments": {"operation": "catalog_inspect", "kind": "function", "id": format!("execute::{target}"), "maxSchemaBytes": 8000},
            "readOnlyInspectionSafe": true,
            "useOnlyWhen": "Only inspect the target adapter schema when the task explicitly needs to invoke the adapter effect. Do not use this as replacement, shadow, route, or evidence proof.",
            "notPartOfReadinessCompletion": true
        },
        "doNotCall": [
            {"operation": target, "reason": "Do not invoke the adapter just to inspect replacement readiness; call it only when the task needs the adapter effect."},
            {"operation": "capability_shadow_trial_request_list", "reason": "No provider-visible list operation exists for shadow trial requests; use targeted cockpit counts and exact evidence inspect only when an evidence ref exists."},
            {"operation": "capability_shadow_trial_run_list", "reason": "No provider-visible list operation exists for shadow trial runs; use route events and exact evidence refs instead."}
        ],
        "completionRule": "If the targeted cockpit row has zero shadowTrial.evidenceRefs, zero shadowTrial.runs, zero route.bindings, and zero route.routeEvents, stop and report that no current-scope shadow or route evidence is recorded.",
        "finalAnswerWhen": "After the targeted cockpit overview shows no exact shadow evidence refs and the listed read-only operations show no candidates, routes, bindings, or events, stop and answer from those facts.",
        "terminalZeroEvidencePath": {
            "state": "answer_now_no_current_scope_evidence",
            "afterOperation": "capability_binding_cockpit_overview",
            "condition": "targeted cockpit row returns zero shadowTrial.evidenceRefs, shadowTrial.runs, route.bindings, active routes, and route.routeEvents",
            "answerGuidance": "Say no scoped shadow or route evidence is recorded for the target operation. Do not inspect evidence schemas without an exact evidence resource id."
        },
        "contextualWriteOperations": contextual_write_operations,
        "evidenceInspectAvailability": {
            "callableNow": false,
            "becomesCallableWhen": "targeted cockpit, route-event, or resource output returns an exact provider-safe evidence inspect payload",
            "notActionableReason": "No exact capabilityShadowTrialEvidenceResourceId is known from search alone; targeted cockpit returns exact inspect payloads only when evidence exists.",
            "doNotInspectSchemasFromSearch": true
        },
        "doNotInspect": [
            {"operation": "evidence inspection", "reason": "Do not call until evidenceInspectAvailability.callableNow is true because targeted cockpit returned an exact inspect payload."},
            {"operation": "evidence schema inspection", "reason": "Do not inspect evidence schemas in the zero-evidence path; schema inspection does not create evidence."}
        ]
    }))
}

fn contextual_write_operation(operation: &str, use_only_when: &str) -> Value {
    let required_payload_fields = operation_required_payload_fields(operation);
    let mut agent_usage = operation_agent_usage_projection(operation).unwrap_or_else(|| {
        json!({
            "callable": true,
            "tool": "capability::execute",
            "operation": operation,
            "arguments": {"operation": operation}
        })
    });
    if let Some(preflight) = agent_usage
        .get_mut("preflight")
        .and_then(Value::as_object_mut)
    {
        preflight.insert(
            "requiredPayloadFields".to_owned(),
            Value::Array(required_payload_fields.clone()),
        );
    }
    json!({
        "operation": operation,
        "tool": "capability::execute",
        "schemaInspection": execute_schema_inspection_step(operation),
        "requiredPayloadFields": required_payload_fields,
        "readOnlyInspectionSafe": false,
        "useOnlyWhen": use_only_when,
        "agentUsage": agent_usage
    })
}

fn trace_evidence_plan_projection(query: &OperationSearchQuery) -> Option<Value> {
    let (target, query_terms) = trace_evidence_plan_target(query)?;
    let mut read_only_sequence = vec![recovery_alternative(
        "catalog_inspect",
        json!({"operation": "catalog_inspect", "kind": "function", "id": format!("execute::{target}"), "maxSchemaBytes": 8000}),
        "Inspect the exact provider-visible request schema for the target operation before invoking it.",
    )];

    if target != "trace_list" {
        read_only_sequence.push(recovery_alternative(
            "trace_list",
            json!({"operation": "trace_list", "limit": 25}),
            "After invoking the target operation, list current-session trace evidence through the provider-safe trace projection.",
        ));
    }
    Some(json!({
        "purpose": "Deterministic read-only plan for schema inspection and provider-safe trace evidence.",
        "targetOperation": target,
        "traceIntentTerms": query_terms,
        "primaryInspection": {
            "tool": "capability::execute",
            "operation": "catalog_inspect",
            "arguments": {"operation": "catalog_inspect", "kind": "function", "id": format!("execute::{target}"), "maxSchemaBytes": 8000},
            "readOnlyInspectionSafe": true,
            "reason": "Returns the exact provider-visible schema and top-level payload fields for the target operation."
        },
        "readOnlySequence": read_only_sequence,
        "afterTargetInvocation": {
            "tool": "capability::execute",
            "operation": "trace_list",
            "arguments": {"operation": "trace_list", "limit": 25},
            "readOnlyInspectionSafe": true,
            "reason": "Use trace_list after the target operation to verify provider-safe trace evidence."
        },
        "optionalDetailInspection": {
            "tool": "capability::execute",
            "operation": "trace_get",
            "arguments": {"operation": "trace_get", "traceRecordId": "<trace record id from trace_list>"},
            "readOnlyInspectionSafe": true,
            "reason": "Call trace_get only when the task explicitly needs one focused trace record; trace_list is the default proof path."
        },
        "completionRule": "After schema inspection, one target invocation, and trace_list, answer from provider-safe trace fields only. State that provider-visible trace projections exclude raw internals while internal audit storage may retain raw fields for replay and policy.",
        "doNotInspect": [
            {"field": "raw trace database rows", "reason": "Use provider-safe trace_list/trace_get projections instead of raw internal persistence."}
        ]
    }))
}

fn operation_search_plan_supported_operations(query: &OperationSearchQuery) -> Vec<&'static str> {
    let Some((_target, query_terms)) = operation_search_plan_target(query) else {
        return Vec::new();
    };
    let mut operations = vec!["capability_binding_cockpit_overview"];
    if query_terms.contains("replacement") || query_terms.contains("candidate") {
        operations.push("capability_replacement_candidate_list");
    }
    if query_terms.contains("route") || query_terms.contains("routing") {
        operations.extend([
            "capability_route_binding_list",
            "capability_route_event_list",
        ]);
    }
    if query_terms.contains("binding") {
        operations.extend([
            "capability_binding_request_list",
            "capability_binding_decision_list",
            "capability_binding_policy_list",
        ]);
    }
    operations
}

fn trace_evidence_plan_supported_operations(query: &OperationSearchQuery) -> Vec<&'static str> {
    let Some((target, _)) = trace_evidence_plan_target(query) else {
        return Vec::new();
    };
    vec![target, "catalog_inspect", "trace_list"]
}

fn module_governance_plan_supported_operations(query: &OperationSearchQuery) -> Vec<&'static str> {
    if !module_governance_plan_query(query) {
        return Vec::new();
    }

    let terms = query_terms(query);
    let broad_governance = terms.contains("governance");
    let mut operations = Vec::new();

    if broad_governance || terms.contains("module") || terms.contains("registry") {
        operations.push("module_list");
    }
    if broad_governance || terms.contains("lifecycle") {
        operations.push("module_lifecycle_list");
    }
    if broad_governance || terms.contains("runtime") {
        operations.push("module_runtime_list");
    }
    if broad_governance
        || terms.contains("dependency")
        || terms.contains("request")
        || terms.contains("decision")
        || terms.contains("policy")
    {
        operations.extend([
            "module_dependency_request_list",
            "module_dependency_decision_list",
            "module_dependency_policy_list",
        ]);
    }
    if broad_governance
        || terms.contains("binding")
        || terms.contains("replacement")
        || terms.contains("route")
        || terms.contains("routing")
    {
        operations.extend([
            "capability_binding_cockpit_overview",
            "capability_binding_request_list",
            "capability_binding_decision_list",
            "capability_binding_policy_list",
            "capability_replacement_candidate_list",
            "capability_route_binding_list",
            "capability_route_event_list",
        ]);
    }

    operations.sort_unstable();
    operations.dedup();
    operations
}

fn operation_search_plan_target(
    query: &OperationSearchQuery,
) -> Option<(&'static str, BTreeSet<String>)> {
    let mut supported = supported_operations_in_query(query);
    if supported.len() != 1 {
        return None;
    }
    let target = supported.pop()?;
    let metadata = operation_pool_metadata(target)?;
    if metadata.replacement_class.as_str() != "runtime_routable" {
        return None;
    }
    let query_terms = query_terms(query);
    let asks_binding_or_route_readiness = query_terms.iter().any(|term| {
        matches!(
            term.as_str(),
            "replacement"
                | "replace"
                | "replacing"
                | "route"
                | "routing"
                | "binding"
                | "readiness"
                | "rollback"
                | "candidate"
                | "shadow"
                | "trial"
        )
    }) && !query_terms.contains("trace");
    asks_binding_or_route_readiness.then_some((target, query_terms))
}

fn trace_evidence_plan_target(
    query: &OperationSearchQuery,
) -> Option<(&'static str, BTreeSet<String>)> {
    if operation_search_plan_target(query).is_some() {
        return None;
    }
    let mut supported = supported_operations_in_query(query)
        .into_iter()
        .filter(|operation| !trace_evidence_helper_operation(operation))
        .collect::<Vec<_>>();
    supported.sort_unstable();
    supported.dedup();
    if supported.len() != 1 {
        return None;
    }
    let target = supported.pop()?;
    if !operation_is_read_only_inspection_safe(target) {
        return None;
    }
    let query_terms = query_terms(query);
    let asks_trace_evidence = query_terms
        .iter()
        .any(|term| matches!(term.as_str(), "trace" | "evidence" | "provider" | "safe"));
    let asks_schema_or_trace = query_terms.iter().any(|term| {
        matches!(
            term.as_str(),
            "schema" | "trace" | "evidence" | "projection" | "provider"
        )
    });
    (asks_trace_evidence && asks_schema_or_trace).then_some((target, query_terms))
}

fn module_governance_plan_projection(query: &OperationSearchQuery) -> Option<Value> {
    let operations = module_governance_plan_supported_operations(query);
    if operations.is_empty() {
        return None;
    }

    let read_only_sequence = operations
        .iter()
        .map(|operation| {
            recovery_alternative(
                operation,
                default_list_payload(operation),
                read_only_module_governance_reason(operation),
            )
        })
        .collect::<Vec<_>>();

    Some(json!({
        "purpose": "Deterministic read-only plan for broad module-governance discovery and readiness checks.",
        "query": query.display,
        "readOnlySequence": read_only_sequence,
        "schemaPolicy": {
            "defaultPayloadComplete": true,
            "defaultPayload": "operation-only unless the listed operation documents optional limit/includeArchived filters",
            "inspectWhen": "Inspect execute::<operation> only when you need non-default fields, a concrete resource id from list output, or a focused inspect operation.",
            "doNotInspectEverySibling": true,
            "reason": "The read-only sequence is already constrained to provider-visible overview/list operations whose required payload is operation. Per-operation schema fan-out is unnecessary for a broad governance readiness check."
        },
        "resourceInspectPolicy": {
            "callInspectOperationsOnlyWithExactResourceIds": true,
            "sourceOfResourceIds": "list operation output or cockpit evidence refs",
            "emptyListMeansNoScopedRecords": true
        },
        "doNotCall": [
            {"operationFamily": "module_*_record/request/decision mutators", "reason": "This plan is read-only. Do not create proposals, install requests, lifecycle requests, runtime requests, dependency requests, or decisions."},
            {"operationFamily": "capability_route_activate/disable/rollback", "reason": "Activation, disable, and rollback are governed state changes outside a read-only readiness check."},
            {"operationFamily": "module_program_execution_*", "reason": "Runtime execution is not needed to inspect governance surfaces."}
        ],
        "completionRule": "After the listed overview/list operations, call trace_list last when the task asks for whole-session trace proof, then answer from exact operation results. Empty lists are valid evidence of no current-scope records; do not invent resource ids or call inspect operations without ids.",
        "traceEvidenceBoundary": "trace_list is a point-in-time projection. If more operations run after trace_list, do not claim trace_list evidenced those later operations; call trace_list again at the end or qualify the coverage.",
        "finalAnswerGuidance": "Name the surfaces that were discoverable, the read-only operations used, any empty record planes, any confusing or missing guidance, and whether provider-safe trace evidence excludes raw internals. Distinguish provider transcript tool-call ids used for protocol threading from raw trace providerInvocationId fields, which trace projections exclude."
    }))
}

fn module_governance_plan_query(query: &OperationSearchQuery) -> bool {
    if operation_search_plan_target(query).is_some() || trace_evidence_plan_target(query).is_some()
    {
        return false;
    }
    let terms = query_terms(query);
    let asks_module_governance = terms.contains("governance")
        || terms.contains("module")
        || terms.contains("registry")
        || terms.contains("lifecycle")
        || terms.contains("runtime")
        || terms.contains("dependency");
    let asks_capability_governance = terms.contains("binding")
        || terms.contains("replacement")
        || terms.contains("route")
        || terms.contains("routing");
    let asks_read_only_overview = query.canonical.contains("read_only")
        || query.canonical.contains("read")
        || query.canonical.contains("inspect")
        || query.canonical.contains("list")
        || query.canonical.contains("readiness")
        || terms.contains("policy")
        || terms.contains("request")
        || terms.contains("decision");
    (asks_module_governance || asks_capability_governance) && asks_read_only_overview
}

fn default_list_payload(operation: &str) -> Value {
    if operation == "capability_binding_cockpit_overview" {
        json!({"operation": operation})
    } else {
        json!({
            "operation": operation,
            "limit": 25
        })
    }
}

fn read_only_module_governance_reason(operation: &str) -> &'static str {
    match operation {
        "module_list" => {
            "List module manifest records without installing, enabling, or executing modules."
        }
        "module_lifecycle_list" => {
            "List lifecycle records; empty output means no lifecycle state is currently recorded in scope."
        }
        "module_runtime_list" => {
            "List runtime supervisor envelope records; empty output means no runtime envelope is recorded in scope."
        }
        "module_dependency_request_list" => {
            "List dependency requests; this does not request, approve, restore, or install dependencies."
        }
        "module_dependency_decision_list" => {
            "List dependency decisions; this does not create a decision."
        }
        "module_dependency_policy_list" => {
            "List dependency policy records; this does not activate dependency restoration."
        }
        "capability_binding_cockpit_overview" => {
            "Inspect operation ownership, replacement class, route state, and scoped evidence without changing routing."
        }
        "capability_binding_request_list" => {
            "List binding requests; this does not create a replacement or extension request."
        }
        "capability_binding_decision_list" => {
            "List binding decisions; this does not approve or reject anything."
        }
        "capability_binding_policy_list" => {
            "List binding policies; this does not activate routing."
        }
        "capability_replacement_candidate_list" => {
            "List replacement candidates; empty output means no candidate is recorded in scope."
        }
        "capability_route_binding_list" => {
            "List route bindings; this does not activate, disable, or roll back routing."
        }
        "capability_route_event_list" => {
            "List route events for activation, routed invocation, disable, rollback, and failed-closed history."
        }
        _ => "Read-only governance overview/list operation.",
    }
}

fn trace_evidence_helper_operation(operation: &str) -> bool {
    matches!(operation, "catalog_inspect" | "trace_list" | "trace_get")
}

fn operation_is_read_only_inspection_safe(operation: &str) -> bool {
    operation_agent_usage_projection(operation)
        .and_then(|usage| {
            usage
                .pointer("/effect/readOnlyInspectionSafe")
                .and_then(Value::as_bool)
        })
        .unwrap_or(false)
}

fn annotate_catalog_function_pool(object: &mut serde_json::Map<String, Value>, catalog_id: &str) {
    if let Some(metadata) = catalog_function_pool_metadata(catalog_id) {
        object.insert(
            "capabilityPool".to_owned(),
            serde_json::to_value(metadata.provider_projection())
                .expect("capability pool projection serializes"),
        );
    }
}

fn mark_catalog_target_non_callable(object: &mut serde_json::Map<String, Value>) {
    object.insert("providerCallable".to_owned(), Value::Bool(false));
    object.insert(
        "providerCallableReason".to_owned(),
        Value::String(
            "Catalog target is metadata only for model context; invoke capability::execute with a supported operation instead."
                .to_owned(),
        ),
    );
}

fn model_execute_operation_for_function_id(id: &str) -> Option<String> {
    if let Some(operation) = direct_model_execute_operation_for_function_id(id) {
        return Some(operation.to_owned());
    }
    let (namespace, name) = id.split_once("::")?;
    let candidate = format!("{namespace}_{name}");
    if is_supported_operation(&candidate) {
        Some(candidate)
    } else {
        None
    }
}

fn direct_model_execute_operation_for_function_id(id: &str) -> Option<&'static str> {
    match id {
        "logs::recent" => Some("log_recent"),
        "catalog_discovery::search" => Some("catalog_search"),
        "catalog_discovery::inspect" => Some("catalog_inspect"),
        "catalog_discovery::conformance_report" => Some("catalog_conformance"),
        "jobs::log" => Some("job_log"),
        _ => None,
    }
}

fn catalog_function_id_for_model_alias(id: &str) -> Option<String> {
    let alias = id.strip_prefix("execute::").unwrap_or(id);
    match alias {
        "log_recent" => Some("logs::recent".to_owned()),
        "catalog_search" => Some("catalog_discovery::search".to_owned()),
        "catalog_inspect" => Some("catalog_discovery::inspect".to_owned()),
        "catalog_conformance" => Some("catalog_discovery::conformance_report".to_owned()),
        "job_log" => Some("jobs::log".to_owned()),
        operation if is_supported_operation(operation) => {
            Some(catalog_function_id_for_execute_operation(operation))
        }
        _ => None,
    }
}

fn catalog_function_id_for_execute_operation(operation: &str) -> String {
    direct_catalog_function_id_for_execute_operation(operation)
        .unwrap_or("capability::execute")
        .to_owned()
}

fn direct_catalog_function_id_for_execute_operation(operation: &str) -> Option<&'static str> {
    match operation {
        "log_recent" => Some("logs::recent"),
        "catalog_search" => Some("catalog_discovery::search"),
        "catalog_inspect" => Some("catalog_discovery::inspect"),
        "catalog_conformance" => Some("catalog_discovery::conformance_report"),
        "job_log" => Some("jobs::log"),
        "git_status" => Some("git::status"),
        "git_diff" => Some("git::diff"),
        "git_stage" => Some("git::stage"),
        "git_unstage" => Some("git::unstage"),
        "git_commit" => Some("git::commit"),
        "git_branch_start" => Some("git::branch_start"),
        "git_branch_inventory" => Some("git::branch_inventory"),
        "capability_binding_cockpit_overview" => Some("capability_binding::cockpit_overview"),
        _ => None,
    }
}

pub(super) async fn catalog_conformance(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let report =
        service::conformance_report_value(&deps.engine_host, invocation, &invocation.payload)
            .await?;
    let status = report["status"].as_str().unwrap_or("failed");
    let resource_id = report["reportResourceId"].as_str().unwrap_or("unknown");
    Ok(ok_result(
        format!("Catalog conformance {status}; report resource {resource_id}."),
        json!({
            "primitiveOperation": "catalog_conformance",
            "status": status,
            "catalogDiscovery": report
        }),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_inspect_normalizes_model_facing_log_alias() {
        let (payload, alias) = normalize_catalog_inspect_payload(&json!({
            "kind": "function",
            "id": "execute::log_recent"
        }));

        assert_eq!(payload["id"], "logs::recent");
        assert_eq!(alias.as_deref(), Some("execute::log_recent"));
    }

    #[test]
    fn catalog_inspect_normalizes_direct_catalog_operation_aliases() {
        let (payload, alias) = normalize_catalog_inspect_payload(&json!({
            "kind": "function",
            "id": "git_status"
        }));

        assert_eq!(payload["id"], "git::status");
        assert_eq!(alias.as_deref(), Some("git_status"));
    }

    #[test]
    fn catalog_inspect_detects_execute_operation_aliases_before_generic_schema() {
        let (operation, alias) = execute_operation_inspect_target(&json!({
            "kind": "function",
            "id": "execute::capability_shadow_trial_evidence_inspect"
        }))
        .expect("execute operation alias");

        assert_eq!(operation, "capability_shadow_trial_evidence_inspect");
        assert_eq!(alias, "execute::capability_shadow_trial_evidence_inspect");

        let discovery = execute_operation_inspect_projection(&operation, &alias);
        assert_eq!(discovery["kind"], "execute_operation");
        assert_eq!(
            discovery["id"],
            "execute::capability_shadow_trial_evidence_inspect"
        );
        assert_eq!(
            discovery["operation"],
            "capability_shadow_trial_evidence_inspect"
        );
        assert_eq!(discovery["providerCallable"], true);
        assert_eq!(
            discovery["modelFacingInvocation"]["arguments"]["operation"],
            "capability_shadow_trial_evidence_inspect"
        );
        assert_eq!(
            discovery["schema"]["requiredPayloadFields"],
            json!(["operation", "capabilityShadowTrialEvidenceResourceId"])
        );
        assert_eq!(
            discovery["inputSchema"]["required"],
            json!(["operation", "capabilityShadowTrialEvidenceResourceId"])
        );
        assert_eq!(
            discovery["inputSchema"]["properties"]["operation"]["const"],
            "capability_shadow_trial_evidence_inspect"
        );
        assert_eq!(discovery["inputSchema"]["additionalProperties"], true);
        assert_eq!(
            discovery["inputSchema"]["properties"]["capabilityShadowTrialEvidenceResourceId"]["type"],
            "string"
        );
        assert_eq!(
            discovery["schema"]["inputSchema"]["required"],
            json!(["operation", "capabilityShadowTrialEvidenceResourceId"])
        );
        assert_eq!(
            discovery["outputSchema"]["properties"]["details"]["properties"]["primitiveOperation"]
                ["const"],
            "capability_shadow_trial_evidence_inspect"
        );
        assert_eq!(
            discovery["agentUsage"]["effect"]["readOnlyInspectionSafe"],
            true
        );
    }

    #[test]
    fn catalog_inspect_projects_cockpit_target_operation_optional_field() {
        let discovery = execute_operation_inspect_projection(
            "capability_binding_cockpit_overview",
            "execute::capability_binding_cockpit_overview",
        );

        assert_eq!(
            discovery["schema"]["requiredPayloadFields"],
            json!(["operation"])
        );
        assert_eq!(discovery["inputSchema"]["required"], json!(["operation"]));
        assert_eq!(
            discovery["inputSchema"]["properties"]["targetOperation"]["type"],
            "string"
        );
        assert!(
            discovery["inputSchema"]["properties"]["targetOperation"]["description"]
                .as_str()
                .expect("targetOperation description")
                .contains("one compact cockpit row")
        );
        assert_eq!(
            discovery["modelFacingInvocation"]["arguments"]["operation"],
            "capability_binding_cockpit_overview"
        );
    }

    #[test]
    fn catalog_inspect_projects_web_operation_contracts() {
        let robots =
            execute_operation_inspect_projection("web_robots_check", "execute::web_robots_check");
        assert_eq!(
            robots["schema"]["requiredPayloadFields"],
            json!(["operation", "url"])
        );
        assert_eq!(
            robots["inputSchema"]["required"],
            json!(["operation", "url"])
        );
        assert_eq!(
            robots["inputSchema"]["properties"]["operation"]["const"],
            "web_robots_check"
        );
        assert_eq!(robots["inputSchema"]["properties"]["url"]["format"], "uri");
        assert!(
            robots["inputSchema"]["properties"]["userAgent"]["description"]
                .as_str()
                .expect("userAgent description")
                .contains("omit this field")
        );
        assert!(
            execute_operation_invocation_guidance("web_robots_check")
                .contains("copy webRobotsPolicyVersionId")
        );
        assert!(
            robots["inputSchema"]["properties"]
                .as_object()
                .expect("robots properties")
                .get("idempotencyKey")
                .is_none(),
            "trusted runtime context owns web robots idempotency keys"
        );
        assert_eq!(
            robots["outputSchema"]["properties"]["details"]["properties"]["web"]["required"],
            json!([
                "schemaVersion",
                "status",
                "operation",
                "webRobotsPolicyResourceId",
                "webRobotsPolicyVersionId",
                "resourceRefs"
            ])
        );

        let fetch = execute_operation_inspect_projection("web_fetch", "execute::web_fetch");
        assert_eq!(
            fetch["schema"]["requiredPayloadFields"],
            json!(["operation", "url"])
        );
        assert_eq!(
            fetch["inputSchema"]["required"],
            json!(["operation", "url"])
        );
        assert_eq!(
            fetch["inputSchema"]["properties"]["operation"]["const"],
            "web_fetch"
        );
        assert_eq!(
            fetch["inputSchema"]["properties"]["webRobotsPolicyResourceId"]["type"],
            json!(["string", "null"])
        );
        assert!(
            fetch["inputSchema"]["properties"]["expectedWebRobotsPolicyVersionId"]["description"]
                .as_str()
                .expect("expected version description")
                .contains("webRobotsPolicyVersionId")
        );
        assert!(
            fetch["inputSchema"]["properties"]
                .as_object()
                .expect("fetch properties")
                .get("idempotencyKey")
                .is_none(),
            "trusted runtime context owns web fetch idempotency keys"
        );
        assert!(execute_operation_invocation_guidance("web_fetch").contains("copy"));
        assert!(execute_operation_invocation_guidance("web_fetch").contains("fail closed"));
        assert_eq!(
            fetch["outputSchema"]["properties"]["details"]["properties"]["web"]["required"],
            json!([
                "schemaVersion",
                "status",
                "operation",
                "webSourceResourceId",
                "webSourceVersionId",
                "resourceRefs"
            ])
        );
    }

    #[test]
    fn catalog_search_advertises_conditional_web_fetch_evidence_linkage() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({"text": "web fetch robots evidence", "limit": 10}),
        );

        let matches = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches");
        let web_fetch = matches
            .iter()
            .find(|value| value["operation"] == "web_fetch")
            .expect("web_fetch match");
        assert_eq!(
            web_fetch["agentUsage"]["effect"]["priorEvidence"]["mode"],
            "conditional"
        );
        assert_eq!(
            web_fetch["agentUsage"]["effect"]["priorEvidence"]["sourceOperation"],
            "web_robots_check"
        );
        assert_eq!(
            web_fetch["agentUsage"]["effect"]["priorEvidence"]["copyFields"]["webRobotsPolicyVersionId"],
            "web_fetch.expectedWebRobotsPolicyVersionId"
        );
        assert!(
            web_fetch["agentUsage"]["effect"]["priorEvidence"]["failClosed"]
                .as_str()
                .expect("fail closed guidance")
                .contains("before target network I/O")
        );
    }

    #[test]
    fn catalog_inspect_projects_trace_output_record_schema() {
        let trace_list = execute_operation_inspect_projection("trace_list", "execute::trace_list");

        assert_eq!(
            trace_list["outputSchema"]["properties"]["details"]["properties"]["primitiveOperation"]
                ["const"],
            "trace_list"
        );
        assert_eq!(
            trace_list["outputSchema"]["properties"]["details"]["required"],
            json!([
                "primitiveOperation",
                "status",
                "projectionBoundary",
                "statusSummary",
                "records"
            ])
        );
        let record_schema =
            &trace_list["outputSchema"]["properties"]["details"]["properties"]["records"]["items"];
        assert_eq!(
            record_schema["properties"]["schemaVersion"]["const"],
            "tron.trace.provider_safe.v1"
        );
        assert_eq!(
            trace_list["outputSchema"]["properties"]["details"]["properties"]["statusSummary"]["properties"]
                ["currentInvocationStatus"]["const"],
            "pending_at_projection_time"
        );
        assert_eq!(
            record_schema["properties"]["projectionBoundary"]["properties"]["safeEngineRefsOnly"]["const"],
            true
        );
        assert_eq!(
            record_schema["properties"]["redaction"]["properties"]["rawProviderInvocationIdsExcluded"]
                ["const"],
            true
        );
        assert_eq!(
            record_schema["properties"]["authority"]["properties"]["rawAuthorityGrantIdStored"]["const"],
            false
        );
        assert!(
            trace_list["outputSchema"]["properties"]["details"]["properties"]["projectionBoundary"]
                ["properties"]["recordProof"]
                .is_object()
        );
        assert!(
            execute_operation_invocation_guidance("trace_list").contains("trusted runtime context")
        );
        assert!(
            execute_operation_invocation_guidance("trace_list")
                .contains("call it after the operations being audited")
        );
        assert!(
            execute_operation_invocation_guidance("trace_list")
                .contains("distinct from raw trace providerInvocationId fields")
        );
        assert!(
            trace_list["outputSchema"]["properties"]["details"]["description"]
                .as_str()
                .expect("trace_list description")
                .contains("Raw provider invocation ids")
        );
        assert!(
            !record_schema["properties"]
                .as_object()
                .expect("record properties")
                .contains_key("providerInvocationId")
        );
        assert!(
            record_schema["notProjectedFields"]
                .as_array()
                .expect("not projected fields")
                .iter()
                .any(|field| field == "providerInvocationId")
        );

        let trace_get = execute_operation_inspect_projection("trace_get", "execute::trace_get");
        assert_eq!(
            trace_get["schema"]["requiredPayloadFields"],
            json!(["operation", "traceRecordId"])
        );
        assert_eq!(
            trace_get["inputSchema"]["required"],
            json!(["operation", "traceRecordId"])
        );
        assert!(
            trace_get["inputSchema"]["properties"]["traceRecordId"]["description"]
                .as_str()
                .expect("traceRecordId description")
                .contains("trace record id")
        );
        assert_eq!(
            trace_get["outputSchema"]["properties"]["details"]["properties"]["record"]["properties"]
                ["redaction"]["properties"]["rawRequestExcluded"]["const"],
            true
        );
    }

    #[test]
    fn catalog_inspect_projects_shadow_trial_request_required_fields() {
        let request = execute_operation_inspect_projection(
            "capability_shadow_trial_request_record",
            "execute::capability_shadow_trial_request_record",
        );

        assert_eq!(
            request["schema"]["requiredPayloadFields"],
            json!([
                "operation",
                "title",
                "targetOperation",
                "currentBuiltInOwner",
                "ownershipClass",
                "bindingMode",
                "candidateAdapter",
                "authorityConstraints",
                "contractEvidenceRefs",
                "evidenceRefs",
                "staleVersionGuard",
                "rollbackRef",
                "disableRef",
                "abortRef",
                "rationale",
                "idempotencyKey"
            ])
        );
        assert_eq!(
            request["inputSchema"]["required"],
            request["schema"]["requiredPayloadFields"]
        );
        assert_eq!(
            request["inputSchema"]["properties"]["currentBuiltInOwner"]["type"],
            "string"
        );
    }

    #[test]
    fn catalog_inspect_projects_shadow_trial_record_required_fields() {
        let decision = execute_operation_inspect_projection(
            "capability_shadow_trial_decision_record",
            "execute::capability_shadow_trial_decision_record",
        );
        assert_eq!(decision["kind"], "execute_operation");
        assert_eq!(
            decision["schema"]["requiredPayloadFields"],
            json!([
                "operation",
                "capabilityShadowTrialRequestResourceId",
                "expectedCapabilityShadowTrialRequestVersionId",
                "decision",
                "reason"
            ])
        );
        assert_eq!(
            decision["inputSchema"]["required"],
            json!([
                "operation",
                "capabilityShadowTrialRequestResourceId",
                "expectedCapabilityShadowTrialRequestVersionId",
                "decision",
                "reason"
            ])
        );
        assert_eq!(
            decision["inputSchema"]["properties"]["capabilityShadowTrialRequestResourceId"]["type"],
            "string"
        );
        assert_eq!(
            decision["inputSchema"]["properties"]["expectedCapabilityShadowTrialRequestVersionId"]
                ["type"],
            "string"
        );

        let run = execute_operation_inspect_projection(
            "capability_shadow_trial_run_record",
            "execute::capability_shadow_trial_run_record",
        );
        assert_eq!(run["kind"], "execute_operation");
        assert_eq!(
            run["schema"]["requiredPayloadFields"],
            json!([
                "operation",
                "capabilityShadowTrialDecisionResourceId",
                "expectedCapabilityShadowTrialDecisionVersionId",
                "builtInProjection",
                "candidateProjection"
            ])
        );
        assert_eq!(
            run["inputSchema"]["required"],
            json!([
                "operation",
                "capabilityShadowTrialDecisionResourceId",
                "expectedCapabilityShadowTrialDecisionVersionId",
                "builtInProjection",
                "candidateProjection"
            ])
        );
        assert_eq!(
            run["inputSchema"]["properties"]["capabilityShadowTrialDecisionResourceId"]["type"],
            "string"
        );
        assert_eq!(
            run["inputSchema"]["properties"]["expectedCapabilityShadowTrialDecisionVersionId"]["type"],
            "string"
        );
        assert_eq!(
            run["inputSchema"]["properties"]["builtInProjection"]["type"],
            "object"
        );
        assert_eq!(
            run["inputSchema"]["properties"]["builtInProjection"]["required"],
            json!([
                "operation",
                "status",
                "headState",
                "indexState",
                "worktreeState",
                "evidenceRef"
            ])
        );
        assert_eq!(
            run["inputSchema"]["properties"]["builtInProjection"]["properties"]["operation"]["const"],
            "git_status"
        );
        assert_eq!(
            run["inputSchema"]["properties"]["candidateProjection"]["type"],
            "object"
        );
        assert_eq!(
            run["inputSchema"]["properties"]["trialRunOutcome"]["enum"],
            json!(["completed", "aborted", "disabled"])
        );
    }

    #[test]
    fn catalog_inspect_uses_exact_repository_tree_inspect_resource_field() {
        let discovery = execute_operation_inspect_projection(
            "repository_tree_inspect",
            "execute::repository_tree_inspect",
        );

        assert_eq!(
            discovery["schema"]["requiredPayloadFields"],
            json!(["operation", "repositoryTreeResourceId"])
        );
        assert_eq!(
            discovery["inputSchema"]["required"],
            json!(["operation", "repositoryTreeResourceId"])
        );
        assert_eq!(
            discovery["inputSchema"]["properties"]["repositoryTreeResourceId"]["type"],
            "string"
        );
        assert!(
            !discovery.to_string().contains("<exactResourceIdField>"),
            "model-facing schema must never require the agent to infer inspect resource field names"
        );
    }

    #[test]
    fn catalog_inspect_exposes_exact_repository_tree_snapshot_contract() {
        let discovery = execute_operation_inspect_projection(
            "repository_tree_snapshot",
            "execute::repository_tree_snapshot",
        );

        assert_eq!(
            discovery["schema"]["requiredPayloadFields"],
            json!([
                "operation",
                "repositoryRef",
                "rootRef",
                "treeObjectRef",
                "idempotencyKey"
            ])
        );
        assert_eq!(
            discovery["inputSchema"]["additionalProperties"],
            json!(false)
        );
        assert_eq!(
            discovery["inputSchema"]["properties"]["repositoryRef"]["type"],
            "object"
        );
        assert!(
            discovery["inputSchema"]["properties"]["repositoryRef"]["description"]
                .as_str()
                .expect("repository ref description")
                .contains("including kind")
        );
        assert_eq!(
            discovery["inputSchema"]["properties"]["rootRef"]["type"],
            "object"
        );
        assert!(
            discovery["inputSchema"]["properties"]["rootRef"]["description"]
                .as_str()
                .expect("root ref description")
                .contains("Passing only .id is invalid")
        );
        assert!(
            discovery["inputSchema"]["properties"]["headRef"]["description"]
                .as_str()
                .expect("head ref description")
                .contains("including kind")
        );
        assert!(
            discovery["inputSchema"]["properties"]["treeObjectRef"]["description"]
                .as_str()
                .expect("tree object description")
                .contains("repositoryTreeSnapshotInput.treeObjectRef")
        );
        assert!(
            discovery["inputSchema"]["properties"]["pathEntries"]["description"]
                .as_str()
                .expect("path entry description")
                .contains("never raw file contents")
        );
        let guidance = execute_operation_invocation_guidance("repository_tree_snapshot");
        assert!(guidance.contains("Copy complete repositoryRef/rootRef/headRef objects"));
        assert!(guidance.contains("including kind"));
        assert!(guidance.contains("passing only .id values is invalid"));
    }

    #[test]
    fn catalog_inspect_exposes_exact_repository_tree_list_contract() {
        let discovery = execute_operation_inspect_projection(
            "repository_tree_list",
            "execute::repository_tree_list",
        );

        assert_eq!(
            discovery["schema"]["requiredPayloadFields"],
            json!(["operation"])
        );
        assert_eq!(
            discovery["inputSchema"]["additionalProperties"],
            json!(false)
        );
        assert_eq!(
            discovery["inputSchema"]["properties"]["repositoryRefId"]["description"],
            "Optional bounded repository ref id filter; unsupported aliases are rejected."
        );
        assert_eq!(
            discovery["inputSchema"]["properties"]["networkPolicy"]["const"],
            "none"
        );
        assert!(
            !discovery.to_string().contains("repositoryTreeRefId"),
            "catalog must not suggest unsupported repository tree aliases"
        );
    }

    #[test]
    fn catalog_inspect_projects_goal_question_required_fields() {
        let goal_create =
            execute_operation_inspect_projection("goal_create", "execute::goal_create");
        assert_eq!(
            goal_create["schema"]["requiredPayloadFields"],
            json!(["operation", "objective", "idempotencyKey"])
        );
        assert_eq!(
            goal_create["inputSchema"]["required"],
            json!(["operation", "objective", "idempotencyKey"])
        );

        let goal_cancel =
            execute_operation_inspect_projection("goal_cancel", "execute::goal_cancel");
        assert_eq!(
            goal_cancel["schema"]["requiredPayloadFields"],
            json!(["operation", "goalResourceId", "reason", "idempotencyKey"])
        );
        assert_eq!(
            goal_cancel["inputSchema"]["required"],
            json!(["operation", "goalResourceId", "reason", "idempotencyKey"])
        );

        let question_create =
            execute_operation_inspect_projection("question_create", "execute::question_create");
        assert_eq!(
            question_create["schema"]["requiredPayloadFields"],
            json!(["operation", "prompt", "idempotencyKey"])
        );
        assert_eq!(
            question_create["inputSchema"]["required"],
            json!(["operation", "prompt", "idempotencyKey"])
        );

        let question_answer =
            execute_operation_inspect_projection("question_answer", "execute::question_answer");
        assert_eq!(
            question_answer["schema"]["requiredPayloadFields"],
            json!([
                "operation",
                "questionResourceId",
                "expectedQuestionVersionId",
                "answerText",
                "reason",
                "idempotencyKey"
            ])
        );
        assert_eq!(
            question_answer["inputSchema"]["required"],
            json!([
                "operation",
                "questionResourceId",
                "expectedQuestionVersionId",
                "answerText",
                "reason",
                "idempotencyKey"
            ])
        );
    }

    #[test]
    fn catalog_inspect_has_no_placeholder_fields_for_supported_inspect_operations() {
        for operation in supported_operation_names()
            .iter()
            .copied()
            .filter(|operation| operation.ends_with("_inspect"))
        {
            let discovery =
                execute_operation_inspect_projection(operation, &format!("execute::{operation}"));
            let rendered = discovery.to_string();
            assert!(
                !rendered.contains("<exactResourceIdField>"),
                "{operation} exposed a placeholder resource id field"
            );

            let required = discovery["schema"]["requiredPayloadFields"]
                .as_array()
                .expect("required payload fields");
            if operation != "catalog_inspect" {
                assert!(
                    required.iter().any(|field| {
                        field.as_str().is_some_and(|field| {
                            field != "operation" && field.ends_with("ResourceId")
                        })
                    }),
                    "{operation} should advertise its exact resource id field"
                );
            }
        }
    }

    #[test]
    fn catalog_inspect_documents_git_status_evidence_contract() {
        let discovery = execute_operation_inspect_projection("git_status", "execute::git_status");

        assert_eq!(discovery["inputSchema"]["additionalProperties"], true);
        assert_eq!(discovery["inputSchema"]["required"], json!(["operation"]));
        assert_eq!(
            discovery["outputSchema"]["properties"]["details"]["properties"]["git"]["required"],
            json!([
                "schemaVersion",
                "status",
                "operation",
                "summary",
                "repository",
                "evidence"
            ])
        );
        assert_eq!(
            discovery["outputSchema"]["properties"]["details"]["properties"]["git"]["properties"]["repository"]
                ["description"],
            "Provider-safe repository facts using workspace-relative path refs."
        );
        assert_eq!(
            discovery["outputSchema"]["properties"]["details"]["description"],
            "Bounded provider-safe git status evidence. Absolute paths, raw commands, raw logs, grants, and authority ids are excluded."
        );
        assert_eq!(
            discovery["agentUsage"]["preflight"]["authority"],
            "derived_read_only_adapter_authority_for_exact_operation"
        );
        assert_eq!(
            discovery["agentUsage"]["preflight"]["networkPolicy"],
            "none"
        );
    }

    #[test]
    fn catalog_inspect_qualifies_runtime_routing_metadata_for_read_only_invocation() {
        let discovery = execute_operation_inspect_projection("git_status", "execute::git_status");

        assert_eq!(
            discovery["capabilityPool"]["currentInvocation"]["guidance"],
            "For this operation-specific invocation, follow the input schema and preflight fields. Replacement/routing classification is informational unless the user task explicitly asks to replace, shadow, activate, disable, or roll back this operation."
        );
        assert_eq!(
            discovery["capabilityPool"]["currentInvocation"]["effect"]["mode"],
            "read_only"
        );
        assert_eq!(
            discovery["capabilityPool"]["replacementWorkflowBoundary"]["appliesOnlyWhen"],
            "explicit_replacement_shadow_route_or_rollback_workflow"
        );
        assert_eq!(
            discovery["capabilityPool"]["replacementWorkflowBoundary"]["notRequiredFor"],
            "normal_read_only_or_session_work_invocation"
        );
        assert_eq!(
            discovery["capabilityPool"]["purpose"],
            "agent_inspects_or_changes_scoped_git_state_by_operation_effect"
        );
    }

    #[test]
    fn catalog_search_annotations_bridge_catalog_ids_to_execute_operations() {
        let mut discovery = json!({
            "functions": [
                {"id": "logs::recent"},
                {"id": "git::status"},
                {"id": "capability_binding::cockpit_overview"},
                {"id": "capability::execute"}
            ]
        });

        annotate_model_facing_invocation(&mut discovery, &json!({}));

        assert_eq!(
            discovery["functions"][0]["modelFacingInvocation"]["operation"],
            "log_recent"
        );
        assert_eq!(
            discovery["functions"][1]["modelFacingInvocation"]["operation"],
            "git_status"
        );
        assert_eq!(
            discovery["functions"][1]["modelFacingInvocation"]["providerSchemaInspectId"],
            "execute::git_status"
        );
        assert_eq!(
            discovery["functions"][1]["modelFacingInvocation"]["preferredSchemaInspection"]["arguments"]
                ["id"],
            "execute::git_status"
        );
        assert_eq!(discovery["functions"][1]["agentUsage"]["callable"], true);
        assert_eq!(
            discovery["functions"][2]["modelFacingInvocation"]["operation"],
            "capability_binding_cockpit_overview"
        );
        assert_eq!(
            discovery["functions"][2]["agentUsage"]["preflight"]["resourceSelectors"][0],
            "kind:capability_binding_request"
        );
        assert_eq!(
            discovery["functions"][0]["capabilityPool"]["surface"],
            "catalog_function"
        );
        assert_eq!(
            discovery["functions"][0]["modelFacingInvocation"]["capabilityPool"]["surface"],
            "agent_operation"
        );
        assert_eq!(
            discovery["functions"][0]["modelFacingInvocation"]["capabilityPool"]["audience"],
            "agent_diagnostics"
        );
        assert!(
            discovery["functions"][3]
                .get("modelFacingInvocation")
                .is_none()
        );
        assert_eq!(
            discovery["functions"][3]["capabilityPool"]["audience"],
            "session_work"
        );
        assert_eq!(
            discovery["functions"][3]["capabilityPool"]["agentDefaultVisibility"],
            "search_visible"
        );
        assert_eq!(discovery["functions"][3]["providerCallable"], false);
        assert!(
            discovery["functions"][3]["providerCallableReason"]
                .as_str()
                .unwrap_or_default()
                .contains("capability::execute")
        );
        assert_eq!(
            discovery["functions"][3]["agentUsage"]["defaultUse"],
            "inspect_only"
        );
        assert_eq!(
            discovery["modelFacingGuidance"]["supportedExecuteOperations"]
                .as_array()
                .expect("operations")
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>(),
            supported_operation_names().to_vec()
        );
    }

    #[test]
    fn catalog_search_read_only_guidance_filters_generic_supported_operations() {
        let mut discovery = json!({"functions": []});

        annotate_model_facing_invocation(&mut discovery, &json!({"effectClass": "pure_read"}));

        let operations = discovery["modelFacingGuidance"]["supportedExecuteOperations"]
            .as_array()
            .expect("operations")
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>();
        assert!(operations.contains(&"catalog_search"));
        assert!(operations.contains(&"catalog_inspect"));
        assert!(operations.contains(&"git_status"));
        assert!(operations.contains(&"capability_binding_cockpit_overview"));
        for mutating in [
            "state_set",
            "filesystem_write",
            "filesystem_edit",
            "filesystem_apply_patch",
            "git_stage",
            "git_commit",
            "capability_route_activate",
        ] {
            assert!(
                !operations.contains(&mutating),
                "pure-read supported-operation guidance must not include {mutating}"
            );
        }
        assert_eq!(
            discovery["modelFacingGuidance"]["supportedExecuteOperationsFilter"]["mode"],
            "read_only_inspection_safe"
        );
    }

    #[test]
    fn catalog_search_adds_exact_execute_operation_matches() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({"text": "trace_list", "limit": 10}),
        );

        let matches = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches");
        assert_eq!(matches[0]["operation"], "trace_list");
        assert_eq!(matches[0]["matchKind"], "exact");
        assert_eq!(matches[0]["tool"], "capability::execute");
        assert_eq!(matches[0]["arguments"]["operation"], "trace_list");
        assert_eq!(matches[0]["catalogInspectId"], "execute::trace_list");
        assert_eq!(
            matches[0]["schemaInspection"]["arguments"]["id"],
            "execute::trace_list"
        );
        assert_eq!(
            discovery["agentNextStep"]["schemaInspection"]["arguments"]["id"],
            "execute::trace_list"
        );
        assert_eq!(
            discovery["agentNextStep"]["priority"],
            "inspect_execute_operation_schema_first"
        );
        assert_eq!(
            matches[0]["capabilityPool"]["audience"],
            "agent_diagnostics"
        );
        assert_eq!(
            matches[0]["capabilityPool"]["replacementClass"],
            "kernel_evolution_only"
        );
        assert_eq!(matches[0]["agentUsage"]["callable"], true);
        assert_eq!(
            discovery["executeOperationSearch"]["totalMatches"],
            matches.len()
        );
    }

    #[test]
    fn catalog_search_adds_multiple_exact_execute_operation_matches() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({"text": "capability_binding_request_list capability_binding_decision_list capability_binding_policy_list", "limit": 10}),
        );

        let operations = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches")
            .iter()
            .filter_map(|value| value["operation"].as_str())
            .collect::<Vec<_>>();
        assert_eq!(
            operations,
            vec![
                "capability_binding_decision_list",
                "capability_binding_policy_list",
                "capability_binding_request_list",
            ]
        );
        assert!(
            discovery["executeOperationMatches"]
                .as_array()
                .expect("operation matches")
                .iter()
                .all(|value| value["matchKind"] == "exact")
        );
        assert_eq!(
            discovery["executeOperationSearch"]["canonicalQuery"]
                .as_str()
                .expect("canonical query"),
            "capability_binding_request_list_capability_binding_decision_list_capability_binding_policy_list"
        );
        assert!(
            discovery["executeOperationSearch"]["terms"]
                .as_array()
                .expect("terms")
                .iter()
                .any(|term| term == "request")
        );
    }

    #[test]
    fn catalog_search_advertises_write_operations_as_not_read_only_safe() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({"text": "capability_shadow_trial_request_record", "limit": 10}),
        );

        let matches = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches");
        assert_eq!(
            matches[0]["operation"],
            "capability_shadow_trial_request_record"
        );
        assert_eq!(matches[0]["matchKind"], "exact");
        assert_eq!(matches[0]["agentUsage"]["effect"]["mode"], "metadata_write");
        assert_eq!(
            matches[0]["agentUsage"]["effect"]["readOnlyInspectionSafe"],
            false
        );
        assert_eq!(matches[0]["agentUsage"]["effect"]["mutatesState"], true);
        assert!(
            matches[0]["agentUsage"]["effect"]["readOnlyInstruction"]
                .as_str()
                .expect("effect instruction")
                .contains("do not call during read-only inspection")
        );
        assert!(
            matches[0]["agentUsage"]["preflight"]["readOnlyInstruction"]
                .as_str()
                .expect("preflight instruction")
                .contains("Do not call during read-only inspection")
        );
    }

    #[test]
    fn catalog_search_pure_read_filter_excludes_mutating_operation_matches() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({
                "effectClass": "pure_read",
                "limit": 20,
                "text": "resource list inspect current workspace session media import preview repository tree program execution prompt artifact module validation install dependency notification schedule question goal web source"
            }),
        );

        let matches = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches");
        assert!(!matches.is_empty());
        assert!(
            matches.iter().all(|value| {
                value["agentUsage"]["effect"]["readOnlyInspectionSafe"] == true
                    && value["agentUsage"]["effect"]["mutatesState"] == false
            }),
            "pure_read searches must not return mutating execute operations: {matches:#?}"
        );
        let operations = matches
            .iter()
            .filter_map(|value| value["operation"].as_str())
            .collect::<Vec<_>>();
        assert!(!operations.contains(&"module_program_execution_start"));
        assert!(!operations.contains(&"repository_tree_snapshot"));
        assert!(operations.contains(&"import_preview_list"));
        assert!(operations.contains(&"repository_tree_list"));
    }

    #[test]
    fn catalog_search_namespace_prefix_uses_capability_pool_family() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({
                "effectClass": "pure_read",
                "limit": 50,
                "namespacePrefix": "context_control"
            }),
        );

        assert_eq!(
            discovery["executeOperationSearch"]["query"],
            "context_control"
        );
        let matches = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches");
        let operations = matches
            .iter()
            .filter_map(|value| value["operation"].as_str())
            .collect::<Vec<_>>();
        for expected in [
            "context_control_status",
            "context_control_action_list",
            "context_control_action_inspect",
            "context_survivor_list",
            "context_exclusion_list",
        ] {
            assert!(
                operations.contains(&expected),
                "namespace family search should include {expected}: {operations:?}"
            );
        }
        for mutating in [
            "context_control_snapshot",
            "context_control_compact",
            "context_control_clear",
            "context_policy_snapshot",
            "context_survivor_record",
            "context_exclusion_record",
        ] {
            assert!(
                !operations.contains(&mutating),
                "pure_read namespace search must exclude mutating operation {mutating}: {operations:?}"
            );
        }
        assert!(matches.iter().all(|value| {
            value["agentUsage"]["effect"]["readOnlyInspectionSafe"] == true
                && value["agentUsage"]["effect"]["mutatesState"] == false
        }));
        assert!(
            matches
                .iter()
                .any(|value| value["matchKind"] == "namespace"),
            "family-owned operations without the context_control prefix should be namespace matches"
        );
        let excluded_operations = discovery["effectClassExcludedOperationMatches"]
            .as_array()
            .expect("effect-class exclusions")
            .iter()
            .filter_map(|value| value["operation"].as_str())
            .collect::<Vec<_>>();
        assert!(excluded_operations.contains(&"context_policy_snapshot"));
        assert!(excluded_operations.contains(&"context_control_snapshot"));
        assert_eq!(
            discovery["executeOperationSearch"]["effectClassExcludedMatches"],
            json!(excluded_operations.len())
        );
    }

    #[test]
    fn catalog_search_advertises_conformance_as_report_write() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({"text": "catalog_conformance", "limit": 10}),
        );

        let matches = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches");
        assert_eq!(matches[0]["operation"], "catalog_conformance");
        assert_eq!(matches[0]["matchKind"], "exact");
        assert_eq!(matches[0]["agentUsage"]["effect"]["mode"], "metadata_write");
        assert_eq!(
            matches[0]["agentUsage"]["effect"]["readOnlyInspectionSafe"],
            false
        );
        assert_eq!(matches[0]["agentUsage"]["effect"]["writesResource"], true);
        assert!(
            matches[0]["agentUsage"]["effect"]["readOnlyInstruction"]
                .as_str()
                .expect("effect instruction")
                .contains("do not call during read-only inspection")
        );
    }

    #[test]
    fn catalog_search_read_only_reports_supported_mutating_matches_as_excluded() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({
                "effectClass": "read_only",
                "limit": 10,
                "text": "context_policy_snapshot"
            }),
        );

        assert_eq!(
            discovery["executeOperationSearch"]["totalMatches"],
            json!(0)
        );
        assert_eq!(
            discovery["executeOperationSearch"]["effectClassExcludedMatches"],
            json!(1)
        );
        assert!(discovery.get("unsupportedOperationCandidate").is_none());
        let excluded = discovery["effectClassExcludedOperationMatches"]
            .as_array()
            .expect("excluded operations");
        assert_eq!(excluded[0]["operation"], "context_policy_snapshot");
        assert_eq!(
            excluded[0]["agentUsage"]["effect"]["readOnlyInspectionSafe"],
            false
        );
        assert!(
            excluded[0]["exclusionReason"]
                .as_str()
                .expect("exclusion reason")
                .contains("Supported operation exists")
        );
    }

    #[test]
    fn catalog_search_returns_flat_inspect_targets_for_included_and_effect_excluded_matches() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({
                "effectClass": "read_only",
                "limit": 10,
                "text": "question"
            }),
        );

        let targets = discovery["allDiscoveredInspectTargets"]
            .as_array()
            .expect("flat inspect targets");
        let operations = targets
            .iter()
            .filter_map(|target| target["operation"].as_str())
            .collect::<BTreeSet<_>>();
        assert!(operations.contains("question_inspect"));
        assert!(operations.contains("question_create"));
        assert!(operations.contains("question_answer"));

        let inspect = targets
            .iter()
            .find(|target| target["operation"] == "question_inspect")
            .expect("question inspect target");
        assert_eq!(inspect["catalogInspectId"], "execute::question_inspect");
        assert_eq!(
            inspect["inspectArguments"]["id"],
            "execute::question_inspect"
        );
        assert_eq!(inspect["excludedFromImmediateInvocation"], false);
        assert_eq!(inspect["readOnlyInspectionSafe"], true);

        let create = targets
            .iter()
            .find(|target| target["operation"] == "question_create")
            .expect("question create target");
        assert_eq!(create["catalogInspectId"], "execute::question_create");
        assert_eq!(create["inspectArguments"]["id"], "execute::question_create");
        assert_eq!(create["excludedFromImmediateInvocation"], true);
        assert_eq!(create["readOnlyInspectionSafe"], false);
        assert!(
            create["agentGuidance"]
                .as_str()
                .expect("agent guidance")
                .contains("Inspect the schema only")
        );
    }

    #[test]
    fn catalog_search_does_not_suggest_then_invoke_for_write_like_matches() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({
                "limit": 10,
                "text": "context_control_snapshot"
            }),
        );

        let matches = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches");
        assert_eq!(matches[0]["operation"], "context_control_snapshot");
        assert_eq!(
            matches[0]["agentUsage"]["effect"]["readOnlyInspectionSafe"],
            false
        );
        assert_eq!(
            discovery["agentNextStep"]["schemaInspection"]["arguments"]["id"],
            "execute::context_control_snapshot"
        );
        assert!(
            discovery["agentNextStep"].get("thenInvoke").is_none(),
            "write-like discovery must not emit immediate invoke guidance"
        );
        assert_eq!(
            discovery["agentNextStep"]["thenInvokeBlocked"]["operation"],
            "context_control_snapshot"
        );
    }

    #[test]
    fn catalog_inspect_advertises_context_status_as_read_only_session_state() {
        let discovery = execute_operation_inspect_projection(
            "context_control_status",
            "execute::context_control_status",
        );

        assert_eq!(
            discovery["schema"]["requiredPayloadFields"],
            json!(["operation"])
        );
        assert_eq!(discovery["inputSchema"]["required"], json!(["operation"]));
        assert!(
            discovery["inputSchema"]["properties"]
                .as_object()
                .expect("input schema properties")
                .get("sessionId")
                .is_none(),
            "model-facing context status schema must rely on trusted current-session scope"
        );
        assert!(
            discovery["modelFacingInvocation"]["arguments"]
                .as_object()
                .expect("model invocation arguments")
                .get("sessionId")
                .is_none()
        );
        assert_eq!(
            discovery["agentUsage"]["effect"]["readOnlyInspectionSafe"],
            true
        );
        assert_eq!(discovery["agentUsage"]["effect"]["mutatesState"], false);
        assert_eq!(
            discovery["agentUsage"]["preflight"]["networkPolicy"],
            "none"
        );
        let guidance = execute_operation_invocation_guidance("context_control_status");
        assert!(guidance.contains("pass only operation"));
        assert!(guidance.contains("Do not include sessionId"));
    }

    #[test]
    fn catalog_search_content_reports_complete_and_effect_excluded_matches() {
        let mut discovery = json!({
            "functions": [],
            "summary": {
                "functions": {
                    "visible": 0
                }
            }
        });

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({
                "effectClass": "read_only",
                "limit": 10,
                "text": "context_policy_snapshot"
            }),
        );

        let content = catalog_search_content(&discovery);
        assert!(
            content.contains("Search complete: all 0 matching execute operation(s) returned"),
            "catalog_search content should not leave completeness implicit: {content}"
        );
        assert!(
            content
                .contains("1 supported operation(s) were excluded by the requested effect class"),
            "catalog_search content should summarize effect-class exclusions: {content}"
        );
        assert!(
            !content.contains("truncated"),
            "complete searches must not be described as truncated: {content}"
        );
    }

    #[test]
    fn catalog_search_adds_prefix_execute_operation_matches() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({"text": "capability_binding_request", "limit": 20}),
        );

        let operations = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches")
            .iter()
            .filter_map(|value| value["operation"].as_str())
            .collect::<Vec<_>>();
        assert!(operations.contains(&"capability_binding_request_record"));
        assert!(operations.contains(&"capability_binding_request_list"));
        assert!(operations.contains(&"capability_binding_request_inspect"));
        assert!(
            discovery["executeOperationMatches"]
                .as_array()
                .expect("operation matches")
                .iter()
                .all(|value| value["matchKind"] == "prefix")
        );
    }

    #[test]
    fn catalog_search_explicitly_recovers_unsupported_operation_like_queries() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({"text": "capability_shadow_trial_request_list", "limit": 10}),
        );

        assert_eq!(
            discovery["executeOperationSearch"]["canonicalQuery"],
            "capability_shadow_trial_request_list"
        );
        assert_eq!(
            discovery["executeOperationSearch"]["totalMatches"],
            json!(0)
        );
        assert_eq!(
            discovery["executeOperationMatches"]
                .as_array()
                .expect("empty operation matches")
                .len(),
            0
        );
        assert_eq!(discovery["unsupportedOperationCandidate"], json!(true));
        assert!(
            discovery["unsupportedOperationRecovery"]["guidance"]
                .as_str()
                .expect("guidance")
                .contains("Do not call the queried name")
        );
        let alternatives = discovery["unsupportedOperationRecovery"]["closestReadOnlyAlternatives"]
            .as_array()
            .expect("alternatives");
        assert!(alternatives.iter().any(|alternative| {
            alternative["operation"] == "capability_binding_cockpit_overview"
                && alternative["arguments"]["targetOperation"] == "<supported_operation>"
        }));
        assert!(alternatives.iter().any(|alternative| {
            alternative["operation"] == "capability_shadow_trial_evidence_inspect"
        }));
    }

    #[test]
    fn catalog_search_maps_catalog_style_text_to_execute_operation_match() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(&mut discovery, &json!({"text": "git::status"}));

        let matches = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches");
        assert_eq!(matches[0]["operation"], "git_status");
        assert_eq!(matches[0]["matchKind"], "exact");
        assert_eq!(matches[0]["catalogInspectId"], "execute::git_status");
        assert_eq!(
            matches[0]["schemaInspection"]["arguments"]["id"],
            "execute::git_status"
        );
        assert_eq!(matches[0]["capabilityPool"]["audience"], "session_work");
        assert_eq!(
            matches[0]["capabilityPool"]["replacementClass"],
            "runtime_routable"
        );
        assert_eq!(
            discovery["agentNextStep"]["schemaInspection"]["arguments"]["id"],
            "execute::git_status"
        );
    }

    #[test]
    fn catalog_search_prioritizes_trace_evidence_plan_for_schema_and_trace_queries() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({
                "text": "git_status trace evidence provider-visible schema",
                "limit": 10
            }),
        );

        let operations = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches")
            .iter()
            .filter_map(|value| value["operation"].as_str())
            .collect::<Vec<_>>();
        assert_eq!(
            operations,
            vec!["git_status", "trace_list", "catalog_inspect"]
        );
        assert_eq!(
            discovery["agentSearchPlan"]["purpose"],
            "Deterministic read-only plan for schema inspection and provider-safe trace evidence."
        );
        assert_eq!(
            discovery["agentSearchPlan"]["primaryInspection"]["arguments"]["id"],
            "execute::git_status"
        );
        assert_eq!(
            discovery["agentSearchPlan"]["afterTargetInvocation"]["operation"],
            "trace_list"
        );
        assert_eq!(
            discovery["agentNextStep"]["schemaInspection"]["arguments"]["id"],
            "execute::git_status"
        );
        assert_eq!(
            discovery["agentNextStep"]["thenInvoke"]["operation"],
            "git_status"
        );
    }

    #[test]
    fn catalog_search_keeps_trace_plan_when_query_names_trace_helpers() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({
                "text": "execute git_status schema read-only current session trace evidence trace_list",
                "limit": 10
            }),
        );

        assert_eq!(
            discovery["agentSearchPlan"]["targetOperation"],
            "git_status"
        );
        assert_eq!(
            discovery["agentSearchPlan"]["primaryInspection"]["arguments"]["id"],
            "execute::git_status"
        );
        assert_eq!(
            discovery["agentSearchPlan"]["afterTargetInvocation"]["arguments"]["operation"],
            "trace_list"
        );
        assert_eq!(
            discovery["agentSearchPlan"]["optionalDetailInspection"]["operation"],
            "trace_get"
        );
        assert!(
            discovery["agentSearchPlan"]["completionRule"]
                .as_str()
                .expect("completion rule")
                .contains("internal audit storage may retain raw fields")
        );
        let operations = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches")
            .iter()
            .filter_map(|value| value["operation"].as_str())
            .collect::<Vec<_>>();
        assert!(!operations.contains(&"trace_get"));
    }

    #[test]
    fn catalog_search_keeps_git_status_primary_for_shadow_trial_recovery_trace_queries() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({
                "text": "supported read-only operations list capability shadow trial request schema git status trace evidence provider safe",
                "limit": 10
            }),
        );

        assert_eq!(
            discovery["agentSearchPlan"]["purpose"],
            "Deterministic read-only plan for schema inspection and provider-safe trace evidence."
        );
        assert_eq!(
            discovery["agentSearchPlan"]["targetOperation"],
            "git_status"
        );
        assert_eq!(
            discovery["agentNextStep"]["schemaInspection"]["arguments"]["id"],
            "execute::git_status"
        );
        let operations = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches")
            .iter()
            .filter_map(|value| value["operation"].as_str())
            .collect::<Vec<_>>();
        assert_eq!(
            operations,
            vec!["git_status", "trace_list", "catalog_inspect"]
        );
    }

    #[test]
    fn catalog_search_does_not_create_trace_plan_for_mutating_targets() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({
                "text": "capability_shadow_trial_request_record trace evidence schema",
                "limit": 10
            }),
        );

        assert!(
            discovery.get("agentSearchPlan").is_none(),
            "mutating operations must not be recommended as read-only trace evidence targets: {discovery}"
        );
    }

    #[test]
    fn catalog_search_returns_agent_readiness_plan_for_multi_intent_queries() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({
                "text": "git_status replacement readiness shadow trial route binding evidence",
                "limit": 25
            }),
        );

        let operations = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches")
            .iter()
            .filter_map(|value| value["operation"].as_str())
            .collect::<Vec<_>>();
        for expected in [
            "capability_binding_cockpit_overview",
            "capability_replacement_candidate_list",
            "capability_route_binding_list",
            "capability_route_event_list",
        ] {
            assert!(
                operations.contains(&expected),
                "multi-intent search should include {expected}: {operations:?}"
            );
        }
        assert!(
            !operations.contains(&"git_status"),
            "target adapter invocation is not readiness evidence and must stay conditional"
        );
        assert!(
            !operations.contains(&"catalog_inspect"),
            "schema inspection is not readiness evidence and must stay conditional"
        );
        assert!(
            !operations.contains(&"capability_shadow_trial_evidence_inspect"),
            "evidence inspect needs an exact evidence id and must not appear as an immediately actionable match"
        );
        assert!(
            discovery["executeOperationMatches"]
                .as_array()
                .expect("operation matches")
                .iter()
                .all(|value| value["matchKind"] == "plan")
        );
        assert!(!operations.contains(&"git_commit"));
        assert!(!operations.contains(&"capability_shadow_trial_request_record"));
        assert_eq!(
            discovery["agentSearchPlan"]["targetOperation"],
            json!("git_status")
        );
        assert_eq!(
            discovery["agentSearchPlan"]["primaryInspection"]["arguments"]["targetOperation"],
            json!("git_status")
        );
        let readiness_sequence = discovery["agentSearchPlan"]["readOnlySequence"]
            .as_array()
            .expect("read-only readiness sequence");
        assert!(
            readiness_sequence
                .iter()
                .all(|entry| entry["operation"] != "catalog_inspect"),
            "replacement readiness must not treat adapter schema inspection as evidence"
        );
        assert_eq!(
            discovery["agentSearchPlan"]["adapterInvocationSchemaInspection"]["arguments"]["id"],
            "execute::git_status"
        );
        assert_eq!(
            discovery["agentSearchPlan"]["adapterInvocationSchemaInspection"]["notPartOfReadinessCompletion"],
            json!(true)
        );
        assert!(
            discovery["agentSearchPlan"]["adapterInvocationSchemaInspection"]["useOnlyWhen"]
                .as_str()
                .expect("adapter schema guidance")
                .contains("explicitly needs to invoke")
        );
        assert!(
            discovery["agentSearchPlan"]["completionRule"]
                .as_str()
                .expect("completion rule")
                .contains("stop and report")
        );
        assert_eq!(
            discovery["agentSearchPlan"]["terminalZeroEvidencePath"]["state"],
            "answer_now_no_current_scope_evidence"
        );
        assert!(
            discovery["agentSearchPlan"]["terminalZeroEvidencePath"]["answerGuidance"]
                .as_str()
                .expect("zero evidence answer guidance")
                .contains("Do not inspect evidence schemas")
        );
        assert!(
            discovery["agentSearchPlan"]["finalAnswerWhen"]
                .as_str()
                .expect("final answer")
                .contains("stop and answer")
        );
        assert_eq!(
            discovery["agentSearchPlan"]["evidenceInspectAvailability"]["callableNow"],
            json!(false)
        );
        assert_eq!(
            discovery["agentSearchPlan"]["evidenceInspectAvailability"]["doNotInspectSchemasFromSearch"],
            json!(true)
        );
        assert_eq!(
            discovery["agentSearchPlan"]["doNotInspect"][0]["operation"],
            "evidence inspection"
        );
        assert_eq!(
            discovery["agentSearchPlan"]["doNotInspect"][1]["operation"],
            "evidence schema inspection"
        );
        let do_not_call = discovery["agentSearchPlan"]["doNotCall"]
            .as_array()
            .expect("do not call");
        assert!(
            do_not_call
                .iter()
                .any(|entry| entry["operation"] == "git_status")
        );
        assert!(
            do_not_call
                .iter()
                .any(|entry| entry["operation"] == "capability_shadow_trial_request_list")
        );
        assert_eq!(
            discovery["agentNextStep"]["priority"],
            "follow_agent_search_plan_primary_inspection"
        );
        assert_eq!(
            discovery["agentNextStep"]["primaryInspection"]["operation"],
            "capability_binding_cockpit_overview"
        );
        let contextual_write_operations = discovery["agentSearchPlan"]["contextualWriteOperations"]
            .as_array()
            .expect("contextual write operations");
        let contextual_names = contextual_write_operations
            .iter()
            .filter_map(|value| value["operation"].as_str())
            .collect::<Vec<_>>();
        assert_eq!(
            contextual_names,
            vec![
                "capability_shadow_trial_request_record",
                "capability_shadow_trial_decision_record",
                "capability_shadow_trial_run_record",
            ]
        );
        assert!(
            contextual_write_operations
                .iter()
                .all(|value| value["readOnlyInspectionSafe"] == false)
        );
        assert!(
            contextual_write_operations[0]["requiredPayloadFields"]
                .as_array()
                .expect("shadow request required fields")
                .iter()
                .any(|field| field.as_str() == Some("currentBuiltInOwner"))
        );
        assert!(
            contextual_write_operations[0]["agentUsage"]["preflight"]["requiredPayloadFields"]
                .as_array()
                .expect("shadow request preflight fields")
                .iter()
                .any(|field| field.as_str() == Some("currentBuiltInOwner"))
        );
        assert!(contextual_write_operations.iter().all(|value| {
            value["schemaInspection"]["arguments"]["id"]
                .as_str()
                .expect("schema inspection id")
                .starts_with("execute::capability_shadow_trial_")
        }));
    }

    #[test]
    fn catalog_search_returns_module_governance_read_only_plan_for_broad_queries() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({
                "text": "module governance registry lifecycle runtime dependency request decision policy replacement binding route read-only list inspect",
                "effectClass": "pure_read",
                "limit": 50
            }),
        );

        assert_eq!(
            discovery["agentSearchPlan"]["purpose"],
            "Deterministic read-only plan for broad module-governance discovery and readiness checks."
        );
        assert_eq!(
            discovery["agentNextStep"]["priority"],
            "follow_module_governance_read_only_plan"
        );
        assert_eq!(
            discovery["agentSearchPlan"]["schemaPolicy"]["doNotInspectEverySibling"],
            json!(true)
        );
        assert!(
            discovery["agentSearchPlan"]["schemaPolicy"]["reason"]
                .as_str()
                .expect("schema policy reason")
                .contains("Per-operation schema fan-out is unnecessary")
        );
        let operations = discovery["executeOperationMatches"]
            .as_array()
            .expect("operation matches")
            .iter()
            .filter_map(|value| value["operation"].as_str())
            .collect::<Vec<_>>();
        for expected in [
            "module_list",
            "module_lifecycle_list",
            "module_runtime_list",
            "module_dependency_request_list",
            "module_dependency_decision_list",
            "module_dependency_policy_list",
            "capability_binding_cockpit_overview",
            "capability_binding_request_list",
            "capability_binding_decision_list",
            "capability_binding_policy_list",
            "capability_replacement_candidate_list",
            "capability_route_binding_list",
            "capability_route_event_list",
        ] {
            assert!(
                operations.contains(&expected),
                "broad governance plan should include {expected}: {operations:?}"
            );
        }
        assert!(
            operations
                .iter()
                .all(|operation| operation.ends_with("_list")
                    || *operation == "capability_binding_cockpit_overview"),
            "broad governance plan must expose only overview/list operations: {operations:?}"
        );
        assert!(!operations.contains(&"module_lifecycle_request"));
        assert!(!operations.contains(&"module_runtime_request"));
        assert!(!operations.contains(&"module_dependency_request_record"));
        assert!(!operations.contains(&"capability_route_activate"));
        assert!(
            discovery["executeOperationMatches"]
                .as_array()
                .expect("operation matches")
                .iter()
                .all(|value| value["agentUsage"]["effect"]["readOnlyInspectionSafe"] == true)
        );
        let sequence = discovery["agentSearchPlan"]["readOnlySequence"]
            .as_array()
            .expect("read-only sequence");
        assert_eq!(sequence.len(), operations.len());
        assert!(sequence.iter().all(|entry| {
            entry["arguments"]["operation"]
                .as_str()
                .is_some_and(|operation| operations.contains(&operation))
        }));
        assert_eq!(
            sequence
                .iter()
                .find(|entry| entry["operation"] == "capability_binding_cockpit_overview")
                .expect("cockpit overview step")["arguments"],
            json!({"operation": "capability_binding_cockpit_overview"})
        );
        assert!(
            discovery["agentSearchPlan"]["completionRule"]
                .as_str()
                .expect("completion rule")
                .contains("call trace_list last")
        );
        assert!(
            discovery["agentSearchPlan"]["traceEvidenceBoundary"]
                .as_str()
                .expect("trace evidence boundary")
                .contains("point-in-time projection")
        );
        assert!(
            discovery["agentSearchPlan"]["traceEvidenceBoundary"]
                .as_str()
                .expect("trace evidence boundary")
                .contains("call trace_list again at the end")
        );
        assert!(
            discovery["agentSearchPlan"]["finalAnswerGuidance"]
                .as_str()
                .expect("final answer guidance")
                .contains("provider transcript tool-call ids")
        );
        assert!(
            discovery["agentSearchPlan"]["completionRule"]
                .as_str()
                .expect("completion rule")
                .contains("Empty lists are valid evidence")
        );
    }

    #[test]
    fn catalog_search_does_not_expand_generic_execute_catalog_function() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({"text": "capability::execute", "limit": 50}),
        );

        assert!(
            discovery.get("executeOperationMatches").is_none(),
            "generic capability::execute schema must not become operation matches"
        );
        assert!(discovery.get("executeOperationSearch").is_none());
    }

    #[test]
    fn catalog_search_does_not_expand_normalized_generic_execute_query() {
        let mut discovery = json!({"functions": []});

        annotate_execute_operation_matches(
            &mut discovery,
            &json!({"text": "capability_execute", "limit": 50}),
        );

        assert!(
            discovery.get("executeOperationMatches").is_none(),
            "normalized generic execute query must not become operation matches"
        );
        assert!(discovery.get("executeOperationSearch").is_none());
    }
}
