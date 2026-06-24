//! Capability contracts owned by the capability domain worker.
//!
//! This worker is the model-facing harness collapse point: providers see one
//! `execute` primitive that can observe, touch agent-owned state, use hardened
//! filesystem package operations, inspect Git state, stage Git index changes,
//! commit already-staged Git changes under freshness guards, start a local Git
//! branch without checkout or file updates, inventory local Git branches, run
//! bounded local commands, manage durable non-interactive jobs, manage durable
//! goal/question lifecycle records, fetch explicit URLs as web source
//! provenance, inspect stored web sources for citations, and archive stored web
//! sources without deleting citation evidence.

use serde_json::{Map, Value, json};

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{
    EffectClass, IdempotencyContract, Result as EngineResult, RiskLevel, VisibilityScope,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["capability.runtime"];

pub(crate) const EXECUTE_FUNCTION_ID: &str = "capability::execute";

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
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
        .response_schema(primitive_result_schema())
        .idempotency(IdempotencyContract::caller_session_engine_ledger())
        .build()?,
    ])
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
                        "description": concat!(
                            "Primitive host operation for the bare Tron loop. ",
                            "Use execute to observe, read/write agent-owned state, read and mutate files only through bounded filesystem package operations under the current working directory, inspect Git repository status/diff/branch-inventory evidence, stage or unstage explicit Git index paths with expected HEAD checks, create one commit from the already-staged Git index with expected HEAD and expected index tree checks, start one new local Git branch at the expected HEAD without checkout/file updates, run a bounded local command, start/status/list/log/cancel durable non-interactive jobs, create/list/inspect/cancel durable goals, create/list/inspect/answer durable user questions, fetch one explicit URL as bounded source provenance, list/inspect stored web sources for citation fields, archive stored web sources without deleting citation evidence, inspect agent trace/log records, and inspect catalog discovery evidence. ",
                    "It can also export the current session replay manifest without side effects and inspect redacted memory status/record audit evidence. ",
                    "Choose one operation per call. Catalog discovery operations inspect metadata and conformance only; they do not execute discovered capabilities. Keep mutation reasons and idempotency keys in this payload when they matter for evidence."
                ),
                "parameters": execute_model_request_schema()
            }
        }),
        _ => serde_json::Value::Null,
    }
}

fn execute_request_schema() -> serde_json::Value {
    execute_model_request_schema()
}

fn execute_model_request_schema() -> serde_json::Value {
    let mut properties = Map::new();
    properties.insert(
        "operation".to_owned(),
        json!({
            "type": "string",
            "description": "One primitive operation: observe, state_get, state_set, state_list, filesystem_read, filesystem_list, filesystem_find, filesystem_glob, filesystem_search_text, filesystem_diff, filesystem_write, filesystem_edit, filesystem_apply_patch, git_status, git_diff, git_branch_inventory, git_stage, git_unstage, git_commit, git_branch_start, process_run, job_start, job_status, job_list, job_log, job_cancel, goal_create, goal_list, goal_inspect, goal_cancel, question_create, question_list, question_inspect, question_answer, web_fetch, web_source_list, web_source_inspect, web_source_archive, trace_list, trace_get, log_recent, replay_manifest, catalog_search, catalog_inspect, catalog_conformance, memory_status, memory_list, or memory_inspect."
        }),
    );
    insert_string(
        &mut properties,
        "url",
        "Explicit URL for web_fetch. HTTPS is required except local HTTP test loopback.",
    );
    insert_string(&mut properties, "input", "Text to record for observe.");
    insert_string(
        &mut properties,
        "scope",
        "State scope: session, workspace, or system.",
    );
    insert_string(&mut properties, "namespace", "Agent-owned state namespace.");
    insert_string(&mut properties, "key", "Agent-owned state key.");
    properties.insert(
        "value".to_owned(),
        json!({"description": "JSON value for state_set."}),
    );
    insert_string(
        &mut properties,
        "path",
        "Relative file path under the current working directory.",
    );
    insert_string(
        &mut properties,
        "content",
        "UTF-8 file content for filesystem_write.",
    );
    insert_string(
        &mut properties,
        "oldText",
        "Exact text to replace for filesystem_edit or filesystem_apply_patch.",
    );
    insert_string(
        &mut properties,
        "newText",
        "Replacement text for filesystem_edit or filesystem_apply_patch.",
    );
    insert_string(
        &mut properties,
        "expectedHash",
        "Expected SHA-256 content hash before a filesystem commit.",
    );
    insert_string(
        &mut properties,
        "expectedHead",
        "Expected Git HEAD OID before git_stage, git_unstage, git_commit, or git_branch_start.",
    );
    insert_string(
        &mut properties,
        "expectedIndexTree",
        "Expected staged Git index tree OID before git_commit.",
    );
    insert_string(
        &mut properties,
        "message",
        "Bounded commit message for git_commit.",
    );
    insert_string(
        &mut properties,
        "branchName",
        "New local branch name for git_branch_start.",
    );
    properties.insert(
        "commit".to_owned(),
        json!({"type": "boolean", "description": "When true, commit filesystem_write/edit/apply_patch. Default is preview only."}),
    );
    insert_string(
        &mut properties,
        "glob",
        "Filesystem glob pattern for filesystem_glob/search_text.",
    );
    properties.insert(
        "showHidden".to_owned(),
        json!({"type": "boolean", "description": "Include hidden filesystem entries."}),
    );
    insert_integer(&mut properties, "maxBytes", 1, Some(262_144), None);
    insert_integer(&mut properties, "maxFileBytes", 1, Some(262_144), None);
    insert_integer(&mut properties, "maxDiffBytes", 1, Some(131_072), None);
    insert_integer(&mut properties, "maxStatusBytes", 1, Some(200_000), None);
    insert_integer(&mut properties, "maxBranches", 1, Some(500), None);
    insert_integer(&mut properties, "maxBranchBytes", 1, Some(200_000), None);
    insert_string(
        &mut properties,
        "command",
        "Shell command for process_run or job_start.",
    );
    insert_string(
        &mut properties,
        "jobResourceId",
        "Durable job_process resource id for job_status, job_log, or job_cancel.",
    );
    insert_string(
        &mut properties,
        "goalResourceId",
        "Durable goal resource id for goal_inspect, goal_cancel, or question_create.",
    );
    insert_string(
        &mut properties,
        "questionResourceId",
        "Durable user_question resource id for question_inspect or question_answer.",
    );
    insert_string(
        &mut properties,
        "objective",
        "Bounded objective text for goal_create.",
    );
    insert_string(
        &mut properties,
        "prompt",
        "Bounded prompt text for question_create.",
    );
    insert_string(
        &mut properties,
        "answerText",
        "Bounded user answer text for question_answer.",
    );
    insert_string(
        &mut properties,
        "expectedQuestionVersionId",
        "Expected current user_question version id for question_answer.",
    );
    insert_string(
        &mut properties,
        "expiresAt",
        "Optional RFC3339 expiry timestamp for question_create.",
    );
    properties.insert(
        "allowFreeForm".to_owned(),
        json!({"type": "boolean", "description": "Whether question_create accepts free-form answers when options are also supplied."}),
    );
    properties.insert(
        "successCriteria".to_owned(),
        json!({"type": "array", "description": "Bounded success criteria strings for goal_create."}),
    );
    properties.insert(
        "constraints".to_owned(),
        json!({"type": "object", "description": "Bounded structured constraints for goal_create."}),
    );
    properties.insert(
        "options".to_owned(),
        json!({"type": "array", "description": "Bounded answer options for question_create."}),
    );
    properties.insert(
        "queueRefs".to_owned(),
        json!({"type": "array", "description": "Explicit bounded queue receipt refs to persist as evidence."}),
    );
    properties.insert(
        "planRefs".to_owned(),
        json!({"type": "array", "description": "Explicit bounded goal plan refs to persist as evidence."}),
    );
    properties.insert(
        "evidenceRefs".to_owned(),
        json!({"type": "array", "description": "Explicit bounded evidence refs to persist with goals, questions, or answers."}),
    );
    insert_string(
        &mut properties,
        "state",
        "Durable job lifecycle state filter for job_list.",
    );
    insert_integer(
        &mut properties,
        "cleanupAfterSeconds",
        0,
        None,
        Some("Optional retention hint recorded on a job_start resource."),
    );
    insert_string(
        &mut properties,
        "traceId",
        "Optional trace id filter for trace_list and log_recent.",
    );
    insert_string(
        &mut properties,
        "traceRecordId",
        "Trace record id for trace_get.",
    );
    insert_string(
        &mut properties,
        "kind",
        "Catalog item kind for catalog_inspect: function, worker, trigger_type, or trigger.",
    );
    insert_string(
        &mut properties,
        "id",
        "Catalog item id for catalog_inspect.",
    );
    insert_string(
        &mut properties,
        "recordResourceId",
        "Memory record resource id for memory_inspect.",
    );
    insert_string(
        &mut properties,
        "webSourceResourceId",
        "Durable web_source resource id for web_source_inspect or web_source_archive.",
    );
    insert_string(
        &mut properties,
        "webSourceVersionId",
        "Optional current web_source version id for stale citation guards.",
    );
    insert_string(
        &mut properties,
        "expectedWebSourceVersionId",
        "Expected current web_source version id for web_source_archive freshness.",
    );
    properties.insert(
        "includeArchived".to_owned(),
        json!({"type": "boolean", "description": "Explicitly include archived web_source records in web_source_list."}),
    );
    insert_string(
        &mut properties,
        "text",
        "Catalog search text for catalog_search or catalog_conformance.",
    );
    insert_string(
        &mut properties,
        "namespacePrefix",
        "Catalog namespace prefix filter.",
    );
    insert_string(&mut properties, "visibility", "Catalog visibility filter.");
    insert_string(
        &mut properties,
        "effectClass",
        "Catalog effect-class filter.",
    );
    insert_string(&mut properties, "maxRisk", "Catalog maximum risk filter.");
    insert_string(&mut properties, "health", "Catalog health filter.");
    properties.insert(
        "includeProtectedCounts".to_owned(),
        json!({"type": "boolean", "description": "Include aggregate protected omission counts without protected ids."}),
    );
    insert_integer(&mut properties, "limit", 1, Some(500), None);
    insert_integer(
        &mut properties,
        "maxPreviewBytes",
        1,
        Some(2_000),
        Some("Maximum redacted preview bytes per source for web_source_list."),
    );
    insert_integer(
        &mut properties,
        "maxSnippetBytes",
        1,
        Some(20_000),
        Some("Maximum redacted snippet bytes for web_source_inspect."),
    );
    insert_integer(&mut properties, "timeoutMs", 1, Some(120_000), None);
    insert_integer(&mut properties, "maxOutputBytes", 1, Some(200_000), None);
    insert_integer(
        &mut properties,
        "maxResponseBytes",
        1,
        Some(1_048_576),
        Some("Maximum captured response bytes for web_fetch source evidence."),
    );
    insert_integer(
        &mut properties,
        "maxRedirects",
        0,
        Some(10),
        Some("Maximum redirects followed by web_fetch."),
    );
    insert_string(
        &mut properties,
        "idempotencyKey",
        "Stable caller key for writes or command side effects.",
    );
    insert_string(
        &mut properties,
        "reason",
        "Short evidence reason for the operation.",
    );

    json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["operation"],
        "properties": Value::Object(properties)
    })
}

fn insert_string(properties: &mut Map<String, Value>, name: &str, description: &str) {
    properties.insert(
        name.to_owned(),
        json!({"type": "string", "description": description}),
    );
}

fn insert_integer(
    properties: &mut Map<String, Value>,
    name: &str,
    minimum: u64,
    maximum: Option<u64>,
    description: Option<&str>,
) {
    let mut property = Map::new();
    property.insert("type".to_owned(), json!("integer"));
    property.insert("minimum".to_owned(), json!(minimum));
    if let Some(maximum) = maximum {
        property.insert("maximum".to_owned(), json!(maximum));
    }
    if let Some(description) = description {
        property.insert("description".to_owned(), json!(description));
    }
    properties.insert(name.to_owned(), Value::Object(property));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_execute_is_registered_and_model_facing() {
        let capabilities = capabilities().expect("contracts");
        let ids = capabilities
            .iter()
            .map(|spec| spec.function_id.as_str())
            .collect::<Vec<_>>();
        assert_eq!(ids, [EXECUTE_FUNCTION_ID]);
        assert!(!model_metadata(EXECUTE_FUNCTION_ID).is_null());
        assert!(model_metadata("not_execute").is_null());
    }

    #[test]
    fn execute_schema_exposes_primitive_operations_not_catalog_targets() {
        let metadata = model_metadata(EXECUTE_FUNCTION_ID);
        let description = metadata["capabilitySchema"]["description"]
            .as_str()
            .expect("execute description");
        assert!(description.contains("Primitive host operation"));
        assert!(description.contains("Choose one operation per call"));
        assert!(!description.contains("file_read"));
        assert!(!description.contains("file_write"));

        let schema = execute_model_request_schema();
        assert_eq!(schema["required"], json!(["operation"]));
        assert_eq!(
            schema["additionalProperties"],
            json!(false),
            "primitive execute should accept only its direct request shape"
        );
        assert_eq!(schema["properties"]["operation"]["type"], json!("string"));
        let operations = schema["properties"]["operation"]["description"]
            .as_str()
            .expect("operation description");
        assert!(operations.contains("filesystem_read"));
        assert!(operations.contains("filesystem_write"));
        assert!(operations.contains("git_status"));
        assert!(operations.contains("git_diff"));
        assert!(operations.contains("git_branch_inventory"));
        assert!(operations.contains("git_stage"));
        assert!(operations.contains("git_unstage"));
        assert!(operations.contains("git_commit"));
        assert!(operations.contains("git_branch_start"));
        assert!(operations.contains("goal_create"));
        assert!(operations.contains("goal_list"));
        assert!(operations.contains("goal_inspect"));
        assert!(operations.contains("goal_cancel"));
        assert!(operations.contains("question_create"));
        assert!(operations.contains("question_list"));
        assert!(operations.contains("question_inspect"));
        assert!(operations.contains("question_answer"));
        assert!(operations.contains("web_fetch"));
        assert!(operations.contains("web_source_list"));
        assert!(operations.contains("web_source_inspect"));
        assert!(operations.contains("web_source_archive"));
        assert!(
            !operations.contains("file_read") && !operations.contains("file_write"),
            "legacy file operations must not be model-reachable"
        );
        for non_goal in [
            "web_search",
            "browser_open",
            "browser_click",
            "web_crawl",
            "web_login",
            "job_fetch",
            "job_http",
            "job_network",
        ] {
            assert!(
                !operations.contains(non_goal),
                "non-goal operation {non_goal} must not be model-reachable"
            );
        }
        assert!(!operations.contains("git_checkout"));
        assert!(!operations.contains("git_push"));
        assert!(!operations.contains("git_reset"));
        assert!(!operations.contains("planner"));
        assert!(!operations.contains("reminder"));
        assert!(!operations.contains("notification"));
        assert!(!operations.contains("subagent"));
        assert!(schema["properties"].get("branchName").is_some());
        assert!(schema["properties"].get("maxBranches").is_some());
        assert!(schema["properties"].get("maxBranchBytes").is_some());
        assert!(schema["properties"].get("goalResourceId").is_some());
        assert!(schema["properties"].get("questionResourceId").is_some());
        assert!(
            schema["properties"]
                .get("expectedQuestionVersionId")
                .is_some()
        );
        assert!(
            schema["properties"]
                .get("expectedWebSourceVersionId")
                .is_some()
        );
        assert!(schema["properties"].get("includeArchived").is_some());
        assert!(schema["properties"].get("answerText").is_some());
        assert!(schema["properties"].get("url").is_some());
        assert!(schema["properties"].get("webSourceResourceId").is_some());
        assert!(schema["properties"].get("webSourceVersionId").is_some());
        assert!(schema["properties"].get("maxPreviewBytes").is_some());
        assert!(schema["properties"].get("maxSnippetBytes").is_some());
        assert!(schema["properties"].get("maxResponseBytes").is_some());
        assert!(schema["properties"].get("maxRedirects").is_some());
        assert!(schema["properties"].get("target").is_none());
        assert!(schema["properties"].get("contractId").is_none());
        assert!(schema["properties"].get("functionId").is_none());
        assert!(schema["properties"].get("autonomy").is_none());
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
}

fn primitive_result_schema() -> serde_json::Value {
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
