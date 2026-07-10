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
//! controlled subagent task launch/status/result/cancel records backed by the
//! accepted jobs/program-execution module pack, inspect
//! bounded/redacted worker package lifecycle resources without package
//! activation, inspect source-backed module manifest resources without module
//! activation, record/inspect inert procedural definition and activation-review
//! resources without procedural execution, and manage the Slice 13 server-owned notification
//! inbox/device-registration foundation without live APNs delivery, plus
//! bounded import/session-resource graph lineage records without raw import
//! payloads or native tree UI, and bounded system update diagnostic metadata
//! records without live update checks, package bytes, install/restart, or
//! deploy automation.

use serde_json::json;

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{
    EffectClass, IdempotencyContract, Result as EngineResult, RiskLevel, VisibilityScope,
};

use super::operation_host_request_schema;

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
        .request_schema(execute_host_request_schema())
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
                            "Use execute to observe, read/write agent-owned state, read and mutate files only through bounded filesystem package operations under the current working directory, inspect Git repository status/diff/branch-inventory evidence, stage or unstage explicit Git index paths with expected HEAD checks, create one commit from the already-staged Git index with expected HEAD and expected index tree checks, start one new local Git branch at the expected HEAD without checkout/file updates, run a bounded local command, start/status/list/log/cancel durable non-interactive jobs, start/status/cancel/cleanup module-owned jobs/program-execution runs with ref-only output custody, create/list/inspect/cancel durable goals, create/list/inspect/answer durable user questions, create/list/inspect/cancel/fire due durable schedules and schedule-run records, fetch one explicit URL as bounded source provenance, check one origin robots policy as bounded evidence, list/inspect stored web sources for citation fields, archive stored web sources without deleting citation evidence, create/list/inspect/archive durable media and voice-note blob-ref resources, record/list/inspect bounded import/session-resource graph lineage records, record/list/inspect content-free import preview records, record/list/inspect content-free program-execution metadata records, record/list/inspect explicit prompt artifact metadata records, record/list/inspect bounded system update diagnostic metadata records, inspect inert external tool-source proposal provenance, launch/status/result/cancel controlled subagent task evidence through the accepted jobs/program-execution module pack, inspect bounded/redacted worker package lifecycle records, inspect provider-safe module manifest records, record/list/inspect inert procedural definition and activation-review metadata resources, inspect agent trace/log records, and inspect catalog discovery evidence. ",
                            "It can also export the current session replay manifest without side effects and inspect redacted memory status, record, query, and decision audit evidence. Context-control operations record/list/inspect bounded context snapshots, compact/clear action records, and epochs for the current session with exact session/resource selectors, durable preflight, timeline events, provider-safe projections, and `networkPolicy: none`; they never expose raw prompt bodies, hidden system/soul prompt text, hidden chain-of-thought, secrets, local paths, commands, logs, grant ids, authority ids, or raw file contents. Scheduler operations create explicit durable records and never execute feature work directly; media operations store blob refs and bounded metadata only, never raw audio bytes, and never send raw audio to providers without an explicit future resource authorization; import-history operations store bounded generic graph lineage refs only, keep render hints generic, and never store raw import payloads, repository trees, or native tree UI state; notification operations create durable inbox/read/badge/delivery evidence with live APNs transport disabled, while device token registration is trusted internal-only and never returns raw APNs tokens or full token hashes. ",
                            "Memory query/decision execute operations are read-only inspection of metadata evidence and never perform retrieval, embeddings, ranking, summarization, prompt inclusion, automatic retention, or raw memory body exposure. Tool-source, worker-package, and module-manifest operations never install, activate, trigger, inject prompts, learn behavior, launch, register, resolve dependencies, access networks, or execute proposed external tools, packages, or modules; procedural operations record/list/inspect metadata-only skills, rules, hooks, procedures, activation requests, and activation decisions without firing hooks, registering triggers, injecting prompts, learning behavior, restoring dependencies, touching repo-managed skills, or executing code; module-authoring operations record/list/inspect inert module proposal metadata without installing, activating, executing, restoring dependencies, touching repo-managed skills, creating module workspace directories, or exposing raw prompt/proposal bodies; module-validation operations record/list/inspect bounded module contract validation reports without running commands or module code, storing raw logs/commands/env/code/file contents, installing, activating, resolving dependencies, touching repo-managed skills, or accessing networks; module-install operations record/list/inspect metadata-only review requests and install-candidate/rejected decisions linked to passed validation reports, current approval freshness evidence, dependency policy refs, and rollback proof refs without installing, enabling, executing, restoring dependencies, running package managers, touching repo-managed skills, or accessing networks. ",
                            "Capability-binding operations record/list/inspect metadata-only binding requests, decisions, and policies for future shadow/extend/replace proposals with exact selectors, no wildcard authority, `networkPolicy: none`, stale-version guards, rollback/disable refs, provider-safe projections, and no dispatch mutation, module activation, hot-swap, package-manager, dependency restore, network, agent_state inheritance, raw grant ids, or raw authority ids; `capability_binding_cockpit_overview` returns the same read-only capability-pool and route-state projection used by native Engine Cockpit clients, including agent usage and preflight guidance, without changing routing or autonomy behavior; capability-shadow-trial operations record the governed `git_status` request/decision/run/evidence path, compare built-in and deterministic candidate provider-safe projections, require exact selectors, rollback/disable/abort refs, stale evidence guards, and `networkPolicy: none`, and never execute candidate modules; capability route operations record/activate/disable/rollback explicit scoped `git_status` route resources after candidate, shadow, approval, authority, and rollback evidence, annotate routed invocations with route events, route active invocations through the supervised module-runtime provider-safe projection boundary using accepted shadow-trial evidence, and fail closed without built-in success substitution when route records, lifecycle/runtime refs, scope, or projections are unsafe. Subagent lifecycle operations require explicit workerKind/modulePackId selection, summary-only handoff refs, exact subagent and module runtime authority, networkPolicy none, runtime/job association validation, and return merge proposals instead of silently mutating parent conversation state. ",
                    "Choose one operation per call. For read-only capability discovery, use catalog_search, catalog_inspect, list, inspect, status, trace, log, or overview operations. catalog_conformance is not a read-only inspection operation: it creates an idempotent durable catalog_discovery_report resource and requires a stable idempotencyKey; call it only when the task explicitly asks for a verification/conformance report. Catalog discovery operations never execute discovered capabilities. Import-preview operations store refs, path metadata, counts, summaries, and fingerprints only; they never execute/apply imports, mutate Git, visualize repositories, or store raw import payloads, preview payloads, file contents, or blob bytes. Program-execution operations store runtime/language metadata, I/O refs or fingerprints, resource-limit policy, lifecycle evidence, and idempotency fingerprints only; they never store raw code, command strings, shell snippets, raw stdin/stdout/stderr, launch processes, install runtimes, perform network behavior, write files, or execute programs. Module program-execution operations require an enabled module lifecycle, delegate non-interactive process execution to the jobs domain under networkPolicy none, and return only bounded job/program/runtime/output refs, fingerprints, truncation, duration, exit, timeout, cancellation, and cleanup metadata; they never return raw commands, code, stdin/stdout/stderr, logs, paths, env, pids, grant ids, or raw job_process/execution_output payloads. Prompt-artifact operations store explicit opt-in artifact metadata, content refs/fingerprints, retention state, lifecycle evidence, and idempotency fingerprints only; they never store raw prompt bodies, provider-visible raw prompt payloads, automatic prompt history, prompt injection, learned behavior, native snippet UI, or prompt-context inclusion. Update diagnostic operations store signed-release/provenance metadata only; they never perform live network checks, install, restart, deploy, register packages, or store production endpoint details/package bytes. Keep mutation reasons and idempotency keys in this payload when they matter for evidence."
                ),
                "parameters": execute_provider_request_schema()
            }
        }),
        _ => serde_json::Value::Null,
    }
}

fn execute_provider_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["operation"],
        "properties": {
            "operation": {
                "type": "string",
                "description": "Exact capability::execute operation. Never guess operation names: use catalog_search, then catalog_inspect with kind=function and id=execute::<operation>."
            },
            "text": {
                "type": "string",
                "description": "Bounded natural-language query for catalog_search."
            },
            "kind": {
                "type": "string",
                "description": "Catalog item kind for catalog_inspect; use function for execute-operation contracts."
            },
            "id": {
                "type": "string",
                "description": "Exact catalog inspect id; use execute::<operation> for provider-visible operations."
            },
            "effectClass": {
                "type": "string",
                "description": "Optional catalog_search effect filter. Use pure_read for read-only discovery."
            },
            "namespacePrefix": {
                "type": "string",
                "description": "Optional catalog_search family or namespace filter."
            },
            "limit": {
                "type": "integer",
                "description": "Optional bounded catalog result limit."
            },
            "includeOutputSchema": {
                "type": "boolean",
                "description": "Set true on catalog_inspect only when the operation output contract is needed."
            }
        },
        "additionalProperties": true
    })
}

fn execute_host_request_schema() -> serde_json::Value {
    operation_host_request_schema()
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
        assert!(description.contains("For read-only capability discovery"));
        assert!(
            description.contains("catalog_conformance is not a read-only inspection operation")
        );
        assert!(description.contains("creates an idempotent durable catalog_discovery_report"));
        assert!(!description.contains("file_read"));
        assert!(!description.contains("file_write"));

        let schema = execute_host_request_schema();
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
        assert!(operations.contains("For read-only inspection prefer"));
        assert!(
            operations.contains("catalog_conformance creates a durable catalog_discovery_report")
        );
        assert!(operations.contains("is not read-only inspection"));
        let effect_description = schema["properties"]["effectClass"]["description"]
            .as_str()
            .expect("effect class description");
        assert!(effect_description.contains("pure_read"));
        assert!(effect_description.contains("read_only"));
        assert!(effect_description.contains("Accepted values"));
        for operation in crate::domains::capability::supported_operation_names() {
            assert!(operations.contains(operation), "missing {operation}");
        }
        for operation in concat!(
            "filesystem_read filesystem_write git_status git_diff git_branch_inventory git_stage ",
            "git_unstage git_commit git_branch_start goal_create goal_list goal_inspect goal_cancel ",
            "question_create question_list question_inspect question_answer schedule_create schedule_list ",
            "schedule_inspect schedule_cancel schedule_fire_due web_fetch web_robots_check web_source_list ",
            "web_source_inspect web_source_archive web_research_request_record web_research_request_list web_research_request_inspect web_research_review_record web_research_review_list web_research_review_inspect web_research_source_record web_research_source_list web_research_source_inspect media_create media_list media_inspect media_archive ",
            "import_history_record import_history_list import_history_inspect ",
            "repository_tree_snapshot repository_tree_list repository_tree_inspect ",
            "import_preview_record import_preview_list import_preview_inspect ",
            "program_execution_record program_execution_list program_execution_inspect ",
            "prompt_artifact_record prompt_artifact_list prompt_artifact_inspect ",
            "context_control_snapshot context_control_compact context_control_clear context_control_action_list context_control_action_inspect context_survivor_record context_survivor_list context_survivor_disable context_exclusion_record context_exclusion_list context_exclusion_disable context_policy_snapshot ",
            "module_proposal_record module_proposal_list module_proposal_inspect module_validation_record module_validation_list module_validation_inspect ",
            "module_dependency_request_record module_dependency_request_list module_dependency_request_inspect module_dependency_decision_record module_dependency_decision_list module_dependency_decision_inspect module_dependency_policy_activate module_dependency_policy_list module_dependency_policy_inspect ",
            "capability_binding_request_record capability_binding_request_list capability_binding_request_inspect capability_binding_decision_record capability_binding_decision_list capability_binding_decision_inspect capability_binding_policy_activate capability_binding_policy_list capability_binding_policy_inspect capability_binding_cockpit_overview ",
            "capability_shadow_trial_request_record capability_shadow_trial_decision_record capability_shadow_trial_run_record capability_shadow_trial_evidence_inspect ",
            "module_program_execution_start module_program_execution_status module_program_execution_cancel module_program_execution_cleanup ",
            "device_list device_inspect notification_send notification_list ",
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
            "retired file operations must not be model-reachable"
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
            "module_install_physical",
            "module_activate",
            "module_execute",
            "module_validation_execute",
            "module_dependency_resolve",
            "module_workspace_create",
            "module_proposal_execute",
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
        assert_eq!(
            schema["schemaCompleteness"],
            "mechanical_union_of_exact_operation_contracts"
        );
        assert!(description.contains("Capability-binding operations"));
        assert!(description.contains("capability route operations"));
        assert!(description.contains(
            "supervised module-runtime provider-safe projection boundary using accepted shadow-trial evidence"
        ));
        assert!(description.contains("agent_state inheritance"));
        assert!(schema["properties"].get("contractId").is_none());
        assert!(schema["properties"].get("functionId").is_none());
        assert!(schema["properties"].get("autonomy").is_none());
    }

    #[test]
    fn execute_model_schema_stays_provider_portable() {
        let metadata = model_metadata(EXECUTE_FUNCTION_ID);
        let schema = &metadata["capabilitySchema"]["parameters"];
        assert_eq!(schema["type"], json!("object"));
        assert_eq!(schema["required"], json!(["operation"]));
        assert_eq!(schema["additionalProperties"], json!(true));
        assert!(schema["properties"].get("operation").is_some());
        assert!(schema["properties"].get("text").is_some());
        assert!(schema["properties"].get("kind").is_some());
        assert!(schema["properties"].get("id").is_some());
        assert!(schema["properties"].get("effectClass").is_some());
        assert!(schema["properties"].get("namespacePrefix").is_some());
        assert!(schema["properties"].get("limit").is_some());
        assert!(schema["properties"].get("includeOutputSchema").is_some());
        assert!(schema["properties"].get("command").is_none());
        assert!(schema["properties"].get("authorityConstraints").is_none());
        assert!(
            serde_json::to_vec(schema)
                .expect("provider schema serializes")
                .len()
                < 2_000,
            "provider bootstrap schema must stay compact"
        );
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
