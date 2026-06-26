//! Capability contracts owned by the capability domain worker.
//!
//! This worker is the model-facing harness collapse point: providers see one
//! `execute` primitive that can observe, touch agent-owned state, use hardened
//! filesystem package operations, inspect Git state, stage Git index changes,
//! commit already-staged Git changes under freshness guards, start a local Git
//! branch without checkout or file updates, inventory local Git branches, run
//! bounded local commands, manage durable non-interactive jobs, manage durable
//! goal/question lifecycle records, fetch explicit URLs as web source
//! provenance, check one origin robots policy as evidence, inspect stored web
//! sources for citations, archive stored web sources without deleting citation
//! evidence, manage durable media/voice-note blob-ref resources, manage
//! controlled subagent task launch/status/result/cancel records, inspect
//! bounded/redacted worker package lifecycle resources without package
//! activation, inspect inert procedural state provenance resources without
//! procedural activation, and manage the Slice 13 server-owned notification
//! inbox/device-registration foundation without live APNs delivery, plus
//! bounded import/session-resource graph lineage records without raw import
//! payloads or native tree UI, and bounded system update diagnostic metadata
//! records without live update checks, package bytes, install/restart, or
//! deploy automation.

use serde_json::{Map, Value, json};

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{
    EffectClass, IdempotencyContract, Result as EngineResult, RiskLevel, VisibilityScope,
};

use super::{
    import_history_contract, import_preview_contract, media_contract, program_execution_contract,
    prompt_artifacts_contract, repository_tree_contract, scheduler_contract,
    update_diagnostics_contract,
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
        .request_schema(execute_model_request_schema())
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
                            "Use execute to observe, read/write agent-owned state, read and mutate files only through bounded filesystem package operations under the current working directory, inspect Git repository status/diff/branch-inventory evidence, stage or unstage explicit Git index paths with expected HEAD checks, create one commit from the already-staged Git index with expected HEAD and expected index tree checks, start one new local Git branch at the expected HEAD without checkout/file updates, run a bounded local command, start/status/list/log/cancel durable non-interactive jobs, create/list/inspect/cancel durable goals, create/list/inspect/answer durable user questions, create/list/inspect/cancel/fire due durable schedules and schedule-run records, fetch one explicit URL as bounded source provenance, check one origin robots policy as bounded evidence, list/inspect stored web sources for citation fields, archive stored web sources without deleting citation evidence, create/list/inspect/archive durable media and voice-note blob-ref resources, record/list/inspect bounded import/session-resource graph lineage records, record/list/inspect content-free import preview records, record/list/inspect content-free program-execution metadata records, record/list/inspect explicit prompt artifact metadata records, record/list/inspect bounded system update diagnostic metadata records, inspect inert external tool-source proposal provenance, record controlled subagent launch/status/result/cancel lifecycle evidence, inspect bounded/redacted worker package lifecycle records, inspect inert procedural state provenance records, inspect agent trace/log records, and inspect catalog discovery evidence. ",
                            "It can also export the current session replay manifest without side effects and inspect redacted memory status/record audit evidence. Scheduler operations create explicit durable records and never execute feature work directly; media operations store blob refs and bounded metadata only, never raw audio bytes, and never send raw audio to providers without an explicit future resource authorization; import-history operations store bounded generic graph lineage refs only, keep render hints generic, and never store raw import payloads, repository trees, or native tree UI state; notification operations create durable inbox/read/badge/delivery evidence with live APNs transport disabled, while device token registration is trusted internal-only and never returns raw APNs tokens or full token hashes. Tool-source, worker-package, and procedural-state inspection operations are read-only and never install, activate, trigger, inject prompts, learn behavior, launch, register, or execute proposed external tools, packages, skills, rules, hooks, or procedures; subagent lifecycle operations record bounded placeholder worker/job evidence without starting workers, jobs, tools, network, packages, or result merges. ",
                    "Choose one operation per call. Catalog discovery operations inspect metadata and conformance only; they do not execute discovered capabilities. Import-preview operations store refs, path metadata, counts, summaries, and fingerprints only; they never execute/apply imports, mutate Git, visualize repositories, or store raw import payloads, preview payloads, file contents, or blob bytes. Program-execution operations store runtime/language metadata, I/O refs or fingerprints, resource-limit policy, lifecycle evidence, and idempotency fingerprints only; they never store raw code, command strings, shell snippets, raw stdin/stdout/stderr, launch processes, install runtimes, perform network behavior, write files, or execute programs. Prompt-artifact operations store explicit opt-in artifact metadata, content refs/fingerprints, retention state, lifecycle evidence, and idempotency fingerprints only; they never store raw prompt bodies, provider-visible raw prompt payloads, automatic prompt history, prompt injection, learned behavior, native snippet UI, or prompt-context inclusion. Update diagnostic operations store signed-release/provenance metadata only; they never perform live network checks, install, restart, deploy, register packages, or store production endpoint details/package bytes. Keep mutation reasons and idempotency keys in this payload when they matter for evidence."
                ),
                "parameters": execute_model_request_schema()
            }
        }),
        _ => serde_json::Value::Null,
    }
}

fn execute_model_request_schema() -> serde_json::Value {
    let mut properties = Map::new();
    properties.insert(
        "operation".to_owned(),
        json!({
            "type": "string",
            "description": "One primitive operation: observe, state_get, state_set, state_list, filesystem_read, filesystem_list, filesystem_find, filesystem_glob, filesystem_search_text, filesystem_diff, filesystem_write, filesystem_edit, filesystem_apply_patch, git_status, git_diff, git_branch_inventory, git_stage, git_unstage, git_commit, git_branch_start, process_run, job_start, job_status, job_list, job_log, job_cancel, goal_create, goal_list, goal_inspect, goal_cancel, question_create, question_list, question_inspect, question_answer, schedule_create, schedule_list, schedule_inspect, schedule_cancel, schedule_fire_due, web_fetch, web_robots_check, web_source_list, web_source_inspect, web_source_archive, media_create, media_list, media_inspect, media_archive, import_history_record, import_history_list, import_history_inspect, repository_tree_snapshot, repository_tree_list, repository_tree_inspect, import_preview_record, import_preview_list, import_preview_inspect, program_execution_record, program_execution_list, program_execution_inspect, prompt_artifact_record, prompt_artifact_list, prompt_artifact_inspect, update_diagnostic_record, update_diagnostic_list, update_diagnostic_inspect, device_register, device_unregister, device_list, device_inspect, notification_send, notification_list, notification_inspect, notification_mark_read, notification_mark_all_read, tool_source_list, tool_source_inspect, subagent_launch, subagent_status, subagent_result, subagent_cancel, subagent_task_list, subagent_task_inspect, worker_package_list, worker_package_inspect, procedural_state_list, procedural_state_inspect, trace_list, trace_get, log_recent, replay_manifest, catalog_search, catalog_inspect, catalog_conformance, memory_status, memory_list, or memory_inspect."
        }),
    );
    insert_string(
        &mut properties,
        "url",
        "Explicit URL for web_fetch or web_robots_check. HTTPS is required for web_robots_check; web_fetch also permits local HTTP loopback in deterministic tests.",
    );
    insert_string(
        &mut properties,
        "userAgent",
        "Optional user agent token for web_robots_check robots.txt matching.",
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
        "scheduleResourceId",
        "Durable schedule resource id for schedule_inspect or schedule_cancel.",
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
    scheduler_contract::insert_scheduler_request_fields(&mut properties);
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
        "toolSourceResourceId",
        "Durable tool_source_proposal or tool_source_conformance_report resource id for tool_source_inspect.",
    );
    insert_string(
        &mut properties,
        "subagentTaskResourceId",
        "Durable subagent_task resource id for subagent_status, subagent_result, subagent_cancel, or subagent_task_inspect.",
    );
    insert_string(
        &mut properties,
        "deviceRegistrationResourceId",
        "Durable device_registration resource id for device_inspect, device_unregister, or push delivery evidence.",
    );
    insert_string(
        &mut properties,
        "expectedDeviceRegistrationVersionId",
        "Expected current device_registration version id for device_unregister freshness.",
    );
    insert_string(
        &mut properties,
        "deviceId",
        "Trusted caller device identifier for device_register.",
    );
    insert_string(
        &mut properties,
        "platform",
        "Device platform for device_register; currently ios.",
    );
    insert_string(
        &mut properties,
        "apnsEnvironment",
        "Explicit APNs environment for device_register: development or production.",
    );
    insert_string(
        &mut properties,
        "apnsToken",
        "Trusted internal APNs token input for device_register; never returned by provider-visible projections.",
    );
    insert_string(
        &mut properties,
        "label",
        "Optional bounded human label for device_register.",
    );
    properties.insert(
        "pushOptIn".to_owned(),
        json!({"type": "boolean", "description": "Explicit user opt-in flag for device_register; defaults false."}),
    );
    properties.insert(
        "pushEnabled".to_owned(),
        json!({"type": "boolean", "description": "Explicit push enable flag for device_register; requires pushOptIn true and live transport still stays disabled."}),
    );
    properties.insert(
        "eventFamilies".to_owned(),
        json!({"type": "array", "description": "Bounded notification event-family tokens for device registration policy."}),
    );
    insert_string(
        &mut properties,
        "notificationResourceId",
        "Durable notification resource id for notification_inspect or notification_mark_read.",
    );
    insert_string(
        &mut properties,
        "expectedNotificationVersionId",
        "Expected current notification version id for notification_mark_read freshness.",
    );
    insert_string(
        &mut properties,
        "notificationId",
        "Optional caller-visible notification id for notification_send idempotent resource identity.",
    );
    insert_string(
        &mut properties,
        "family",
        "Notification event family token for notification_send.",
    );
    insert_string(
        &mut properties,
        "severity",
        "Notification severity for notification_send: info, warning, or action_required.",
    );
    insert_string(
        &mut properties,
        "title",
        "Bounded title for notification_send.",
    );
    insert_string(
        &mut properties,
        "body",
        "Bounded body for notification_send.",
    );
    properties.insert(
        "pushRequested".to_owned(),
        json!({"type": "boolean", "description": "Request push delivery evidence for notification_send; live APNs transport remains disabled."}),
    );
    properties.insert(
        "includeRead".to_owned(),
        json!({"type": "boolean", "description": "Include read notification records in notification_list."}),
    );
    properties.insert(
        "includeUnregistered".to_owned(),
        json!({"type": "boolean", "description": "Include unregistered device records in device_list."}),
    );
    properties.insert(
        "sourceRefs".to_owned(),
        json!({"type": "array", "description": "Bounded non-secret source refs for notification_send, media_create, import_history_record, repository_tree_snapshot, import_preview_record, program_execution_record, prompt_artifact_record, or update_diagnostic_record replay evidence."}),
    );
    media_contract::insert_media_request_fields(&mut properties);
    import_history_contract::insert_import_history_request_fields(&mut properties);
    repository_tree_contract::insert_repository_tree_request_fields(&mut properties);
    import_preview_contract::insert_import_preview_request_fields(&mut properties);
    program_execution_contract::insert_program_execution_request_fields(&mut properties);
    prompt_artifacts_contract::insert_prompt_artifacts_request_fields(&mut properties);
    update_diagnostics_contract::insert_update_diagnostics_request_fields(&mut properties);
    insert_string(
        &mut properties,
        "taskId",
        "Optional caller-visible subagent task id for subagent_launch.",
    );
    insert_string(
        &mut properties,
        "objectiveSummary",
        "Bounded objective summary for subagent_launch.",
    );
    insert_string(
        &mut properties,
        "promptSummary",
        "Bounded prompt summary for subagent_launch.",
    );
    insert_string(
        &mut properties,
        "modelPolicy",
        "Required explicit subagent_launch policy; currently only bounded_placeholder_v1 is accepted.",
    );
    insert_string(
        &mut properties,
        "expectedSubagentTaskVersionId",
        "Expected current subagent_task version id for subagent_cancel freshness.",
    );
    insert_string(
        &mut properties,
        "workerPackageResourceId",
        "Durable worker_package, worker_package_installation, worker_package_proposal, worker_package_conformance_report, or worker_launch_attempt resource id for worker_package_inspect.",
    );
    insert_string(
        &mut properties,
        "workerPackageKind",
        "Worker lifecycle resource kind for worker_package_list: worker_package, worker_package_installation, worker_package_proposal, worker_package_conformance_report, or worker_launch_attempt.",
    );
    insert_string(
        &mut properties,
        "proceduralKind",
        "Procedural state kind for procedural_state_list or procedural_state_inspect: skill, rule, hook, or procedure.",
    );
    insert_string(
        &mut properties,
        "proceduralRecordResourceId",
        "Durable procedural_record resource id for procedural_state_inspect.",
    );
    insert_integer(
        &mut properties,
        "maxEvidenceItems",
        1,
        Some(100),
        Some("Maximum projected evidence/provenance array items for procedural_state_inspect."),
    );
    insert_nullable_string(
        &mut properties,
        "webRobotsPolicyResourceId",
        "Optional current-session web_robots_policy resource id for web_fetch robots evidence validation before target network I/O.",
    );
    insert_nullable_string(
        &mut properties,
        "expectedWebRobotsPolicyVersionId",
        "Expected current web_robots_policy version id paired with webRobotsPolicyResourceId for web_fetch freshness and compatibility.",
    );
    insert_string(
        &mut properties,
        "expectedWebSourceVersionId",
        "Expected current web_source version id for web_source_archive freshness.",
    );
    properties.insert(
        "includeArchived".to_owned(),
        json!({"type": "boolean", "description": "Explicitly include archived web_source or media_artifact records in list operations."}),
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
        "maxAgeDays",
        1,
        Some(366),
        Some("Retention bound in days for device registrations or notifications."),
    );
    insert_integer(
        &mut properties,
        "maxInboxRecords",
        1,
        Some(5_000),
        Some("Retention bound for per-scope inbox records."),
    );
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
    insert_integer(
        &mut properties,
        "maxSchemaBytes",
        1,
        Some(32_000),
        Some("Maximum serialized schema preview bytes for tool_source_inspect."),
    );
    insert_integer(
        &mut properties,
        "maxLifecycleItems",
        1,
        Some(100),
        Some("Maximum worker package lifecycle array items for worker_package_inspect."),
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
        "maxRobotsBytes",
        1,
        Some(262_144),
        Some("Maximum captured robots.txt bytes for web_robots_check policy evidence."),
    );
    insert_integer(
        &mut properties,
        "maxRedirects",
        0,
        Some(10),
        Some("Maximum redirects followed by web_fetch or web_robots_check."),
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

fn insert_nullable_string(properties: &mut Map<String, Value>, name: &str, description: &str) {
    properties.insert(
        name.to_owned(),
        json!({"type": ["string", "null"], "description": description}),
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
        for operation in concat!(
            "filesystem_read filesystem_write git_status git_diff git_branch_inventory git_stage ",
            "git_unstage git_commit git_branch_start goal_create goal_list goal_inspect goal_cancel ",
            "question_create question_list question_inspect question_answer schedule_create schedule_list ",
            "schedule_inspect schedule_cancel schedule_fire_due web_fetch web_robots_check web_source_list ",
            "web_source_inspect web_source_archive media_create media_list media_inspect media_archive ",
            "import_history_record import_history_list import_history_inspect ",
            "repository_tree_snapshot repository_tree_list repository_tree_inspect ",
            "import_preview_record import_preview_list import_preview_inspect ",
            "program_execution_record program_execution_list program_execution_inspect ",
            "prompt_artifact_record prompt_artifact_list prompt_artifact_inspect ",
            "device_register device_unregister device_list device_inspect notification_send notification_list ",
            "notification_inspect notification_mark_read notification_mark_all_read tool_source_list ",
            "tool_source_inspect subagent_launch subagent_status subagent_result subagent_cancel ",
            "subagent_task_list subagent_task_inspect worker_package_list worker_package_inspect",
        )
        .split_whitespace()
        {
            assert!(operations.contains(operation), "missing {operation}");
        }
        assert!(
            !operations.contains("file_read") && !operations.contains("file_write"),
            "legacy file operations must not be model-reachable"
        );
        for non_goal in [
            "web_search",
            "web_sitemap_traverse",
            "browser_open",
            "browser_click",
            "web_crawl",
            "web_login",
            "import_execute",
            "session_tree_get",
            "session_graph_render",
            "resource_graph_render",
            "job_fetch",
            "job_http",
            "job_network",
            "tool_source_propose",
            "tool_source_execute",
            "subagent_task_create",
            "subagent_task_update",
            "subagent_task_cancel",
            "subagent_task_result",
            "subagent_task_status",
            "subagent_delegate",
            "spawn_subagent",
            "subagent_spawn",
            "worker_package_install",
            "worker_package_enable",
            "worker_package_launch",
            "worker_launch",
            "mcp_start",
            "mcp_register",
            concat!("notifications", "::send"),
            concat!("notifications", "::list"),
            concat!("notifications", "::mark_read"),
            concat!("notifications", "::mark_all_read"),
            concat!("device", "::register"),
            concat!("device", "::unregister"),
            concat!("apns", "_send"),
            concat!("apns", "_deliver"),
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
        assert!(!operations.contains(concat!("Notification", "Client")));
        assert!(schema["properties"].get("branchName").is_some());
        assert!(schema["properties"].get("scheduleResourceId").is_some());
        assert!(schema["properties"].get("target").is_some());
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
        assert!(schema["properties"].get("userAgent").is_some());
        assert!(schema["properties"].get("webSourceResourceId").is_some());
        assert!(schema["properties"].get("webSourceVersionId").is_some());
        assert!(schema["properties"].get("toolSourceResourceId").is_some());
        assert!(
            schema["properties"]
                .get("importHistoryResourceId")
                .is_some()
        );
        assert!(schema["properties"].get("subjectKind").is_some());
        assert!(schema["properties"].get("subjectId").is_some());
        assert!(schema["properties"].get("parentRefs").is_some());
        assert!(schema["properties"].get("childRefs").is_some());
        assert!(schema["properties"].get("renderHint").is_some());
        assert!(schema["properties"].get("subagentTaskResourceId").is_some());
        for property in [
            "deviceRegistrationResourceId",
            "expectedDeviceRegistrationVersionId",
            "deviceId",
            "apnsEnvironment",
            "apnsToken",
            "pushOptIn",
            "pushEnabled",
            "eventFamilies",
            "notificationResourceId",
            "expectedNotificationVersionId",
            "notificationId",
            "family",
            "severity",
            "title",
            "body",
            "pushRequested",
            "includeRead",
            "includeUnregistered",
            "sourceRefs",
            "maxAgeDays",
            "maxInboxRecords",
            "mediaResourceId",
            "expectedMediaVersionId",
            "mediaId",
            "mediaKind",
            "mimeType",
            "sizeBytes",
            "blobRef",
            "contentHash",
            "durationMs",
            "summary",
            "transcriptionState",
            "transcriptionText",
            "transcriptionLanguage",
            "transcriptionModel",
        ] {
            assert!(schema["properties"].get(property).is_some());
        }
        assert!(schema["properties"].get("objectiveSummary").is_some());
        assert!(schema["properties"].get("promptSummary").is_some());
        assert!(schema["properties"].get("modelPolicy").is_some());
        assert!(
            schema["properties"]
                .get("expectedSubagentTaskVersionId")
                .is_some()
        );
        assert!(
            schema["properties"]
                .get("webRobotsPolicyResourceId")
                .is_some()
        );
        assert_eq!(
            schema["properties"]["webRobotsPolicyResourceId"]["type"],
            json!(["string", "null"])
        );
        assert!(
            schema["properties"]
                .get("expectedWebRobotsPolicyVersionId")
                .is_some()
        );
        assert_eq!(
            schema["properties"]["expectedWebRobotsPolicyVersionId"]["type"],
            json!(["string", "null"])
        );
        assert!(schema["properties"].get("maxPreviewBytes").is_some());
        assert!(schema["properties"].get("maxSnippetBytes").is_some());
        assert!(schema["properties"].get("maxSchemaBytes").is_some());
        assert!(
            schema["properties"]
                .get("workerPackageResourceId")
                .is_some()
        );
        assert!(schema["properties"].get("workerPackageKind").is_some());
        assert!(schema["properties"].get("maxLifecycleItems").is_some());
        assert!(schema["properties"].get("maxResponseBytes").is_some());
        assert!(schema["properties"].get("maxRobotsBytes").is_some());
        assert!(schema["properties"].get("maxRedirects").is_some());
        assert!(
            schema["properties"]["target"]["description"]
                .as_str()
                .expect("target description")
                .contains("scheduler records runs only")
        );
        assert!(schema["properties"].get("contractId").is_none());
        assert!(schema["properties"].get("functionId").is_none());
        assert!(schema["properties"].get("autonomy").is_none());
    }

    #[test]
    fn execute_model_schema_stays_provider_portable() {
        let metadata = model_metadata(EXECUTE_FUNCTION_ID);
        let schema = &metadata["capabilitySchema"]["parameters"];
        assert_eq!(schema["type"], json!("object"));
        // DESI static guard marker for successor-runtime fields:
        // schema["properties"].get("constraints").is_none()
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
