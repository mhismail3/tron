//! Closed provider-visible contracts for governance and supervised-runtime operations.
//!
//! Domain services remain responsible for semantic, authority, lifecycle,
//! prerequisite, and resource validation. This module owns only the exact
//! top-level payload shape exposed through `capability::execute`.

use serde_json::{Value, json};

use super::{
    bounded_integer_schema, idempotency_schema, network_policy_none_schema, string_schema,
};

const MAX_LIST_ITEMS: u64 = 100;
const MAX_REFS: u64 = 25;
const MAX_TIMEOUT_MS: u64 = 120_000;
const MAX_OUTPUT_BYTES: u64 = 200_000;

#[cfg(test)]
const GOVERNANCE_OPERATIONS: &[&str] = &[
    "procedural_definition_record",
    "procedural_state_list",
    "procedural_state_inspect",
    "procedural_activation_request_record",
    "procedural_activation_request_list",
    "procedural_activation_request_inspect",
    "procedural_activation_decision_record",
    "procedural_activation_decision_list",
    "procedural_activation_decision_inspect",
    "schedule_create",
    "schedule_list",
    "schedule_inspect",
    "schedule_cancel",
    "schedule_fire_due",
    "tool_source_list",
    "tool_source_inspect",
    "subagent_launch",
    "subagent_status",
    "subagent_result",
    "subagent_cancel",
    "subagent_task_list",
    "subagent_task_inspect",
    "worker_package_list",
    "worker_package_inspect",
    "module_list",
    "module_inspect",
    "module_proposal_record",
    "module_proposal_list",
    "module_proposal_inspect",
    "module_validation_record",
    "module_validation_list",
    "module_validation_inspect",
    "module_install_request_record",
    "module_install_request_list",
    "module_install_request_inspect",
    "module_install_decision_record",
    "module_install_decision_list",
    "module_install_decision_inspect",
    "module_dependency_request_record",
    "module_dependency_request_list",
    "module_dependency_request_inspect",
    "module_dependency_decision_record",
    "module_dependency_decision_list",
    "module_dependency_decision_inspect",
    "module_dependency_policy_activate",
    "module_dependency_policy_list",
    "module_dependency_policy_inspect",
    "module_lifecycle_request",
    "module_lifecycle_decision",
    "module_lifecycle_list",
    "module_lifecycle_inspect",
    "module_program_execution_start",
    "module_program_execution_status",
    "module_program_execution_cancel",
    "module_program_execution_cleanup",
    "module_runtime_request",
    "module_runtime_list",
    "module_runtime_inspect",
    "module_runtime_cancel",
];

pub(super) fn input_schema(operation: &str) -> Option<Value> {
    let (required, fields) = match operation {
        "procedural_definition_record" => (
            vec!["operation", "proceduralKind", "summary"],
            procedural_definition_fields(),
        ),
        "procedural_state_list" => (
            vec!["operation", "proceduralKind"],
            procedural_list_fields(false),
        ),
        "procedural_state_inspect" => (
            vec!["operation", "proceduralKind", "proceduralRecordResourceId"],
            procedural_inspect_fields("proceduralRecordResourceId"),
        ),
        "procedural_activation_request_record" => (
            vec!["operation", "proceduralKind", "proceduralRecordResourceId"],
            procedural_activation_request_fields(),
        ),
        "procedural_activation_request_list" => (
            vec!["operation", "proceduralKind"],
            procedural_list_fields(true),
        ),
        "procedural_activation_request_inspect" => (
            vec![
                "operation",
                "proceduralKind",
                "proceduralActivationRequestResourceId",
            ],
            procedural_inspect_fields("proceduralActivationRequestResourceId"),
        ),
        "procedural_activation_decision_record" => (
            vec![
                "operation",
                "proceduralKind",
                "proceduralActivationRequestResourceId",
                "decision",
                "reason",
            ],
            procedural_activation_decision_fields(),
        ),
        "procedural_activation_decision_list" => (
            vec!["operation", "proceduralKind"],
            procedural_list_fields(true),
        ),
        "procedural_activation_decision_inspect" => (
            vec![
                "operation",
                "proceduralKind",
                "proceduralActivationDecisionResourceId",
            ],
            procedural_inspect_fields("proceduralActivationDecisionResourceId"),
        ),
        "schedule_create" => (
            vec!["operation", "title", "startAt", "target", "idempotencyKey"],
            schedule_create_fields(),
        ),
        "schedule_list" => (vec!["operation"], schedule_list_fields()),
        "schedule_inspect" => (
            vec!["operation", "scheduleResourceId"],
            vec![
                ("scheduleResourceId", resource_id_schema("schedule")),
                (
                    "limit",
                    limit_schema("Maximum recent run summaries returned."),
                ),
            ],
        ),
        "schedule_cancel" => (
            vec![
                "operation",
                "scheduleResourceId",
                "reason",
                "idempotencyKey",
            ],
            vec![
                ("scheduleResourceId", resource_id_schema("schedule")),
                ("reason", bounded_string(1_000, "Cancellation reason.")),
                (
                    "cancelledAt",
                    rfc3339_schema("Explicit cancellation audit instant."),
                ),
                ("idempotencyKey", idempotency_schema()),
            ],
        ),
        "schedule_fire_due" => (
            vec!["operation", "evaluationAt", "idempotencyKey"],
            vec![
                (
                    "evaluationAt",
                    rfc3339_schema("Explicit due-schedule evaluation instant."),
                ),
                (
                    "limit",
                    bounded_integer_schema(1, 50, "Maximum due schedules evaluated."),
                ),
                ("idempotencyKey", idempotency_schema()),
            ],
        ),
        "tool_source_list" => (vec!["operation"], bounded_list_fields(false)),
        "tool_source_inspect" => (
            vec!["operation", "toolSourceResourceId"],
            vec![
                ("toolSourceResourceId", resource_id_schema("tool source")),
                (
                    "maxSchemaBytes",
                    bounded_integer_schema(1, 32_000, "Maximum schema preview bytes."),
                ),
            ],
        ),
        "subagent_launch" => (
            vec![
                "operation",
                "objectiveSummary",
                "promptSummary",
                "modelPolicy",
                "workerKind",
                "modulePackId",
                "moduleLifecycleResourceId",
                "runtimeRequestId",
                "command",
                "runtimeId",
                "languageId",
                "programFingerprint",
                "networkPolicy",
                "idempotencyKey",
            ],
            subagent_launch_fields(),
        ),
        "subagent_status" | "subagent_result" => (
            vec!["operation", "subagentTaskResourceId"],
            vec![(
                "subagentTaskResourceId",
                resource_id_schema("subagent task"),
            )],
        ),
        "subagent_cancel" => (
            vec!["operation", "subagentTaskResourceId", "idempotencyKey"],
            vec![
                (
                    "subagentTaskResourceId",
                    resource_id_schema("subagent task"),
                ),
                (
                    "expectedSubagentTaskVersionId",
                    version_id_schema("subagent task"),
                ),
                ("reason", bounded_string(2_048, "Cancellation reason.")),
                ("idempotencyKey", idempotency_schema()),
            ],
        ),
        "subagent_task_list" => (vec!["operation"], subagent_task_list_fields()),
        "subagent_task_inspect" => (
            vec!["operation", "subagentTaskResourceId"],
            vec![(
                "subagentTaskResourceId",
                resource_id_schema("subagent task"),
            )],
        ),
        "worker_package_list" => (vec!["operation"], worker_package_list_fields()),
        "worker_package_inspect" => (
            vec!["operation", "workerPackageResourceId"],
            vec![
                (
                    "workerPackageResourceId",
                    resource_id_schema("worker lifecycle"),
                ),
                (
                    "maxLifecycleItems",
                    bounded_integer_schema(1, MAX_LIST_ITEMS, "Maximum lifecycle evidence items."),
                ),
            ],
        ),
        "module_list" => (vec!["operation"], module_manifest_list_fields()),
        "module_inspect" => (
            vec!["operation", "moduleManifestResourceId"],
            vec![
                (
                    "moduleManifestResourceId",
                    resource_id_schema("module manifest"),
                ),
                (
                    "maxItems",
                    bounded_integer_schema(1, MAX_LIST_ITEMS, "Maximum projected manifest items."),
                ),
            ],
        ),
        "module_proposal_record" => (
            vec!["operation", "title", "summary", "idempotencyKey"],
            module_proposal_record_fields(),
        ),
        "module_proposal_list" => (vec!["operation"], governance_list_fields()),
        "module_proposal_inspect" => (
            vec!["operation", "moduleProposalResourceId"],
            inspect_fields("moduleProposalResourceId", "module proposal"),
        ),
        "module_validation_record" => (
            vec![
                "operation",
                "title",
                "summary",
                "moduleRefs",
                "docEvidence",
                "testEvidence",
                "idempotencyKey",
            ],
            module_validation_record_fields(),
        ),
        "module_validation_list" => (vec!["operation"], governance_list_fields()),
        "module_validation_inspect" => (
            vec!["operation", "moduleValidationReportResourceId"],
            inspect_fields(
                "moduleValidationReportResourceId",
                "module validation report",
            ),
        ),
        "module_install_request_record" => (
            vec![
                "operation",
                "title",
                "summary",
                "moduleValidationReportResourceId",
                "idempotencyKey",
            ],
            module_install_request_fields(),
        ),
        "module_install_request_list" | "module_install_decision_list" => {
            (vec!["operation"], governance_list_fields())
        }
        "module_install_request_inspect" => (
            vec!["operation", "moduleInstallRequestResourceId"],
            inspect_fields("moduleInstallRequestResourceId", "module install request"),
        ),
        "module_install_decision_record" => (
            vec![
                "operation",
                "moduleInstallRequestResourceId",
                "decision",
                "reason",
                "approvalRequestResourceId",
                "idempotencyKey",
            ],
            module_install_decision_fields(),
        ),
        "module_install_decision_inspect" => (
            vec!["operation", "moduleInstallDecisionResourceId"],
            inspect_fields("moduleInstallDecisionResourceId", "module install decision"),
        ),
        "module_dependency_request_record" => (
            vec![
                "operation",
                "title",
                "moduleRef",
                "dependencyName",
                "dependencyEcosystem",
                "rationale",
                "securityNeed",
                "licenseNeed",
                "runtimeNeed",
                "removalPlan",
                "riskClass",
                "cargoTomlEvidence",
                "cargoLockEvidence",
                "idempotencyKey",
            ],
            module_dependency_request_fields(),
        ),
        "module_dependency_request_list"
        | "module_dependency_decision_list"
        | "module_dependency_policy_list" => (vec!["operation"], governance_list_fields()),
        "module_dependency_request_inspect" => (
            vec!["operation", "moduleDependencyRequestResourceId"],
            inspect_fields(
                "moduleDependencyRequestResourceId",
                "module dependency request",
            ),
        ),
        "module_dependency_decision_record" => (
            vec![
                "operation",
                "moduleDependencyRequestResourceId",
                "decision",
                "reason",
                "idempotencyKey",
            ],
            module_dependency_decision_fields(),
        ),
        "module_dependency_decision_inspect" => (
            vec!["operation", "moduleDependencyDecisionResourceId"],
            inspect_fields(
                "moduleDependencyDecisionResourceId",
                "module dependency decision",
            ),
        ),
        "module_dependency_policy_activate" => (
            vec![
                "operation",
                "moduleDependencyDecisionResourceId",
                "reason",
                "idempotencyKey",
            ],
            module_dependency_policy_fields(),
        ),
        "module_dependency_policy_inspect" => (
            vec!["operation", "moduleDependencyPolicyResourceId"],
            inspect_fields(
                "moduleDependencyPolicyResourceId",
                "module dependency policy",
            ),
        ),
        "module_lifecycle_request" => (
            vec![
                "operation",
                "moduleInstallDecisionResourceId",
                "lifecycleAction",
                "reason",
                "idempotencyKey",
            ],
            module_lifecycle_request_fields(),
        ),
        "module_lifecycle_decision" => (
            vec![
                "operation",
                "moduleLifecycleResourceId",
                "expectedModuleLifecycleVersionId",
                "decision",
                "approvalRequestResourceId",
                "reason",
                "idempotencyKey",
            ],
            module_lifecycle_decision_fields(),
        ),
        "module_lifecycle_list" => (vec!["operation"], governance_list_fields()),
        "module_lifecycle_inspect" => (
            vec!["operation", "moduleLifecycleResourceId"],
            inspect_fields("moduleLifecycleResourceId", "module lifecycle state"),
        ),
        "module_program_execution_start" => (
            vec![
                "operation",
                "moduleLifecycleResourceId",
                "runtimeRequestId",
                "command",
                "runtimeId",
                "languageId",
                "programFingerprint",
                "reason",
                "idempotencyKey",
            ],
            module_program_start_fields(),
        ),
        "module_program_execution_status" => (
            vec!["operation", "moduleRuntimeResourceId", "jobResourceId"],
            module_program_followup_fields(false, false),
        ),
        "module_program_execution_cancel" => (
            vec![
                "operation",
                "moduleRuntimeResourceId",
                "expectedModuleRuntimeVersionId",
                "jobResourceId",
                "reason",
                "idempotencyKey",
            ],
            module_program_followup_fields(true, false),
        ),
        "module_program_execution_cleanup" => (
            vec![
                "operation",
                "moduleRuntimeResourceId",
                "expectedModuleRuntimeVersionId",
                "jobResourceId",
                "expectedJobVersionId",
                "reason",
                "idempotencyKey",
            ],
            module_program_followup_fields(true, true),
        ),
        "module_runtime_request" => (
            vec![
                "operation",
                "moduleLifecycleResourceId",
                "runtimeRequestId",
                "runtimeKind",
                "runtimeLabel",
                "reason",
                "idempotencyKey",
            ],
            module_runtime_request_fields(),
        ),
        "module_runtime_list" => (vec!["operation"], governance_list_fields()),
        "module_runtime_inspect" => (
            vec!["operation", "moduleRuntimeResourceId"],
            inspect_fields("moduleRuntimeResourceId", "module runtime state"),
        ),
        "module_runtime_cancel" => (
            vec![
                "operation",
                "moduleRuntimeResourceId",
                "expectedModuleRuntimeVersionId",
                "reason",
                "idempotencyKey",
            ],
            module_runtime_cancel_fields(),
        ),
        _ => return None,
    };
    let mut schema = super::closed_schema(operation, &required, fields);
    if operation == "schedule_create" {
        schema["allOf"] = json!([{
            "if": {
                "required": ["triggerType"],
                "properties": {
                    "triggerType": {"const": "interval"}
                }
            },
            "then": {
                "required": ["intervalSeconds"]
            }
        }]);
    }
    Some(schema)
}

fn procedural_definition_fields() -> Vec<(&'static str, Value)> {
    let mut fields = procedural_identity_fields();
    fields.extend([
        (
            "definitionId",
            bounded_token_schema(256, "Optional definition id."),
        ),
        ("status", enum_string(&["draft", "candidate", "validated"])),
        (
            "summary",
            bounded_string(512, "Provider-safe procedural summary."),
        ),
        ("name", bounded_string(256, "Optional display name.")),
        (
            "definitionVersion",
            bounded_string(256, "Optional definition version."),
        ),
        (
            "namespace",
            bounded_string(256, "Optional definition namespace."),
        ),
        (
            "provenance",
            object_schema("Provider-safe provenance metadata."),
        ),
        (
            "evalStatus",
            bounded_token_schema(256, "Evaluation status."),
        ),
        ("evalProfile", bounded_string(256, "Evaluation profile.")),
        ("evalLastRunAt", rfc3339_schema("Last evaluation instant.")),
        ("sourceRefs", refs_schema()),
        ("traceRefs", refs_schema()),
        ("replayRefs", refs_schema()),
        (
            "validationStatus",
            bounded_token_schema(256, "Validation status."),
        ),
        ("validationEvidenceRefs", refs_schema()),
        ("reviewRefs", refs_schema()),
        ("triggerDeclarations", refs_schema()),
        ("conflictMetadata", object_schema("Conflict metadata.")),
        ("orderingMetadata", object_schema("Ordering metadata.")),
        (
            "scopedAuthorityProof",
            object_schema("Scoped authority proof."),
        ),
        ("boundedRefs", refs_schema()),
        (
            "contentHash",
            json!({
                "type": "string",
                "pattern": "^sha256:[0-9A-Fa-f]{64}$",
                "description": "Optional SHA-256 content fingerprint."
            }),
        ),
        ("idempotencyKey", idempotency_schema()),
    ]);
    fields
}

fn procedural_identity_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "proceduralKind",
            enum_string(&["skill", "rule", "hook", "procedure"]),
        ),
        ("scope", enum_string(&["session", "workspace"])),
    ]
}

fn procedural_list_fields(include_archived: bool) -> Vec<(&'static str, Value)> {
    let mut fields = procedural_identity_fields();
    fields.extend([
        (
            "lifecycle",
            bounded_token_schema(256, "Exact lifecycle filter."),
        ),
        (
            "limit",
            limit_schema("Maximum procedural records returned."),
        ),
    ]);
    if include_archived {
        fields.push(("includeArchived", json!({"type": "boolean"})));
    }
    fields
}

fn procedural_inspect_fields(resource_field: &'static str) -> Vec<(&'static str, Value)> {
    let mut fields = procedural_identity_fields();
    fields.extend([
        (resource_field, resource_id_schema("procedural")),
        (
            "maxEvidenceItems",
            bounded_integer_schema(1, MAX_LIST_ITEMS, "Maximum projected evidence items."),
        ),
    ]);
    fields
}

fn procedural_activation_request_fields() -> Vec<(&'static str, Value)> {
    let mut fields = procedural_identity_fields();
    fields.extend([
        (
            "proceduralRecordResourceId",
            resource_id_schema("procedural record"),
        ),
        (
            "activationRequestId",
            bounded_token_schema(256, "Optional request id."),
        ),
        (
            "requestedAction",
            enum_string(&["activate", "deactivate", "rollback"]),
        ),
        ("reviewRefs", refs_schema()),
        ("validationEvidenceRefs", refs_schema()),
        ("triggerDeclarations", refs_schema()),
        ("conflictMetadata", object_schema("Conflict metadata.")),
        ("orderingMetadata", object_schema("Ordering metadata.")),
        (
            "scopedAuthorityProof",
            object_schema("Scoped authority proof."),
        ),
        ("rollbackProofRefs", refs_schema()),
        ("traceRefs", refs_schema()),
        ("replayRefs", refs_schema()),
        ("boundedRefs", refs_schema()),
        ("idempotencyKey", idempotency_schema()),
    ]);
    fields
}

fn procedural_activation_decision_fields() -> Vec<(&'static str, Value)> {
    let mut fields = procedural_identity_fields();
    fields.extend([
        (
            "proceduralActivationRequestResourceId",
            resource_id_schema("procedural activation request"),
        ),
        (
            "activationDecisionId",
            bounded_token_schema(256, "Optional decision id."),
        ),
        (
            "decision",
            enum_string(&[
                "approve_activation",
                "deny_activation",
                "approve_deactivation",
                "approve_rollback",
            ]),
        ),
        ("reason", bounded_string(512, "Decision reason.")),
        ("rollbackProofRefs", refs_schema()),
        ("deactivationProofRefs", refs_schema()),
        ("traceRefs", refs_schema()),
        ("replayRefs", refs_schema()),
        ("boundedRefs", refs_schema()),
        ("idempotencyKey", idempotency_schema()),
    ]);
    fields
}

fn schedule_create_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("title", bounded_string(240, "Schedule title.")),
        (
            "scheduleKind",
            enum_string(&["reminder", "monitor", "automation"]),
        ),
        ("triggerType", enum_string(&["once", "interval"])),
        ("startAt", rfc3339_schema("First fire instant.")),
        (
            "createdAt",
            rfc3339_schema("Optional creation audit instant."),
        ),
        (
            "intervalSeconds",
            bounded_integer_schema(60, 31_622_400, "Interval cadence in seconds."),
        ),
        ("timezone", bounded_string(64, "Timezone policy label.")),
        (
            "missedRunPolicy",
            enum_string(&["skip", "fire_once", "catch_up"]),
        ),
        (
            "maxCatchUpRuns",
            bounded_integer_schema(1, 100, "Maximum catch-up run records."),
        ),
        ("target", schedule_target_schema()),
        (
            "maxRunRecords",
            bounded_integer_schema(1, 10_000, "Maximum retained run records."),
        ),
        (
            "maxAgeDays",
            bounded_integer_schema(1, 366, "Maximum retained age in days."),
        ),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn schedule_target_schema() -> Value {
    json!({
        "type": "object",
        "required": ["resourceKind"],
        "properties": {
            "resourceKind": {"type": "string", "maxLength": 96},
            "action": {"type": "string", "maxLength": 96},
            "resourceIds": {"type": "array", "maxItems": 20, "items": {"type": "string", "maxLength": 96}}
        },
        "additionalProperties": false,
        "description": "Record-only non-wildcard schedule target."
    })
}

fn schedule_list_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("limit", limit_schema("Maximum schedules returned.")),
        (
            "state",
            enum_string(&["active", "paused", "completed", "cancelled"]),
        ),
    ]
}

fn bounded_list_fields(with_state: bool) -> Vec<(&'static str, Value)> {
    let mut fields = vec![
        ("limit", limit_schema("Maximum records returned.")),
        ("includeArchived", json!({"type": "boolean"})),
    ];
    if with_state {
        fields.push(("state", string_schema("Exact lifecycle state filter.")));
    }
    fields
}

fn subagent_launch_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("taskId", bounded_string(128, "Optional stable task id.")),
        (
            "objectiveSummary",
            bounded_string(2_048, "Bounded objective summary."),
        ),
        (
            "promptSummary",
            bounded_string(2_048, "Bounded prompt summary."),
        ),
        (
            "modelPolicy",
            const_string("accepted_jobs_program_execution_v1"),
        ),
        ("workerKind", const_string("module_program_execution")),
        ("modulePackId", const_string("jobs_program_execution")),
        (
            "moduleLifecycleResourceId",
            resource_id_schema("enabled module lifecycle state"),
        ),
        (
            "runtimeRequestId",
            bounded_token_schema(256, "Runtime request id."),
        ),
        (
            "runtimeKind",
            bounded_token_schema(256, "Runtime kind label."),
        ),
        (
            "runtimeLabel",
            bounded_string(1_000, "Runtime display label."),
        ),
        (
            "command",
            string_schema("Delegated non-interactive command."),
        ),
        ("runtimeId", bounded_token_schema(256, "Runtime identity.")),
        (
            "languageId",
            bounded_token_schema(256, "Language identity."),
        ),
        (
            "programFingerprint",
            bounded_token_schema(256, "Program fingerprint."),
        ),
        (
            "programId",
            bounded_token_schema(256, "Optional program id."),
        ),
        (
            "programLabel",
            bounded_string(1_000, "Optional program label."),
        ),
        (
            "programSummary",
            bounded_string(1_000, "Optional program summary."),
        ),
        (
            "inputFingerprint",
            bounded_token_schema(256, "Optional input fingerprint."),
        ),
        ("sourceRef", object_schema("Optional source ref.")),
        ("inputRef", object_schema("Optional input ref.")),
        ("inputRefs", refs_schema()),
        ("sourceRefs", refs_schema()),
        ("evidenceRefs", refs_schema()),
        ("outputRefs", refs_schema()),
        ("handoffRefs", refs_schema()),
        ("traceRefs", refs_schema()),
        ("replayRefs", refs_schema()),
        (
            "timeoutMs",
            bounded_integer_schema(1, MAX_TIMEOUT_MS, "Maximum delegated runtime."),
        ),
        (
            "maxOutputBytes",
            bounded_integer_schema(1, MAX_OUTPUT_BYTES, "Maximum captured output bytes."),
        ),
        (
            "cleanupAfterSeconds",
            json!({"type": "integer", "minimum": 0}),
        ),
        ("networkPolicy", network_policy_none_schema()),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn subagent_task_list_fields() -> Vec<(&'static str, Value)> {
    let mut fields = bounded_list_fields(true);
    let state = fields
        .iter_mut()
        .find(|(name, _)| *name == "state")
        .expect("state field exists");
    state.1 = enum_string(&[
        "requested",
        "queued",
        "running",
        "succeeded",
        "failed",
        "cancelled",
        "archived",
    ]);
    fields
}

fn worker_package_list_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "workerPackageKind",
            enum_string(&[
                "worker_package",
                "worker_package_installation",
                "worker_package_proposal",
                "worker_package_conformance_report",
                "worker_launch_attempt",
            ]),
        ),
        (
            "lifecycle",
            bounded_token_schema(256, "Exact non-archived lifecycle filter."),
        ),
        (
            "limit",
            limit_schema("Maximum worker lifecycle records returned."),
        ),
    ]
}

fn module_manifest_list_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("limit", limit_schema("Maximum module manifests returned.")),
        ("includeArchived", json!({"type": "boolean"})),
        (
            "lifecycle",
            enum_string(&["candidate", "validated", "stale", "archived"]),
        ),
    ]
}

fn governance_list_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "limit",
            limit_schema("Maximum governance records returned."),
        ),
        ("includeArchived", json!({"type": "boolean"})),
        (
            "lifecycle",
            bounded_token_schema(256, "Exact lifecycle filter."),
        ),
    ]
}

fn module_proposal_record_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "proposalId",
            bounded_token_schema(160, "Optional proposal id."),
        ),
        (
            "lifecycleState",
            enum_string(&["draft", "submitted", "superseded", "archived"]),
        ),
        ("title", bounded_string(160, "Proposal title.")),
        ("summary", bounded_string(2_000, "Proposal summary.")),
        ("intendedModuleRefs", refs_schema()),
        ("sourceRefs", refs_schema()),
        ("docRefs", refs_schema()),
        ("testRefs", refs_schema()),
        ("traceRefs", refs_schema()),
        ("replayRefs", refs_schema()),
        (
            "validationStatus",
            bounded_token_schema(256, "Validation placeholder status."),
        ),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn module_validation_record_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("reportId", bounded_token_schema(160, "Optional report id.")),
        (
            "lifecycleState",
            enum_string(&["pending", "passed", "failed", "superseded", "archived"]),
        ),
        ("title", bounded_string(160, "Validation title.")),
        ("summary", bounded_string(2_000, "Validation summary.")),
        ("moduleRefs", nonempty_refs_schema()),
        ("proposalRefs", refs_schema()),
        ("manifestProjectionParity", checks_schema()),
        ("resourceProjectionParity", checks_schema()),
        ("providerProjectionParity", checks_schema()),
        ("docEvidence", nonempty_refs_schema()),
        ("testEvidence", nonempty_refs_schema()),
        ("commandRefs", refs_schema()),
        ("resultRefs", refs_schema()),
        ("failureEvidence", refs_schema()),
        ("traceRefs", refs_schema()),
        ("replayRefs", refs_schema()),
        (
            "validationStatus",
            enum_string(&[
                "pending_review",
                "passed",
                "failed",
                "blocked",
                "superseded",
            ]),
        ),
        ("validationChecks", checks_schema()),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn module_install_request_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "installRequestId",
            bounded_token_schema(160, "Optional request id."),
        ),
        (
            "lifecycleState",
            enum_string(&["pending_review", "superseded", "archived"]),
        ),
        ("title", bounded_string(160, "Install review title.")),
        ("summary", bounded_string(2_000, "Install review summary.")),
        (
            "moduleValidationReportResourceId",
            resource_id_schema("module validation report"),
        ),
        ("dependencyPolicyRefs", refs_schema()),
        (
            "dependencyPolicyStatus",
            enum_string(&["not_required", "linked", "satisfied", "blocked"]),
        ),
        ("rollbackProofRefs", refs_schema()),
        (
            "rollbackReadiness",
            enum_string(&["not_proven", "ready", "blocked"]),
        ),
        ("evidenceRefs", refs_schema()),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn module_install_decision_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "installDecisionId",
            bounded_token_schema(160, "Optional decision id."),
        ),
        (
            "moduleInstallRequestResourceId",
            resource_id_schema("module install request"),
        ),
        ("decision", enum_string(&["approved", "rejected", "denied"])),
        ("reason", bounded_string(2_000, "Decision reason.")),
        ("denialEvidence", refs_schema()),
        (
            "approvalRequestResourceId",
            resource_id_schema("approval request"),
        ),
        (
            "approvalDecisionResourceId",
            resource_id_schema("approval decision"),
        ),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn module_dependency_request_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "dependencyRequestId",
            bounded_token_schema(160, "Optional request id."),
        ),
        (
            "lifecycleState",
            enum_string(&["pending_review", "superseded", "archived"]),
        ),
        ("title", bounded_string(160, "Dependency request title.")),
        ("moduleRef", object_schema("Required owning module ref.")),
        ("proposalRef", object_schema("Optional proposal ref.")),
        ("validationRef", object_schema("Optional validation ref.")),
        ("installRef", object_schema("Optional install ref.")),
        ("runtimeRef", object_schema("Optional runtime ref.")),
        (
            "dependencyName",
            bounded_token_schema(256, "Dependency name."),
        ),
        (
            "dependencyVersionReq",
            bounded_string(256, "Optional version requirement."),
        ),
        (
            "dependencyEcosystem",
            bounded_token_schema(256, "Dependency ecosystem."),
        ),
        ("rationale", bounded_string(2_000, "Owner rationale.")),
        ("securityNeed", bounded_string(2_000, "Security need.")),
        ("licenseNeed", bounded_string(2_000, "License need.")),
        ("runtimeNeed", bounded_string(2_000, "Runtime need.")),
        ("removalPlan", bounded_string(2_000, "Removal plan.")),
        (
            "riskClass",
            enum_string(&["low", "medium", "high", "critical"]),
        ),
        (
            "reviewStatus",
            enum_string(&["pending_review", "approved", "rejected", "denied", "active"]),
        ),
        ("cargoTomlEvidence", parity_evidence_schema()),
        ("cargoLockEvidence", parity_evidence_schema()),
        ("evidenceRefs", refs_schema()),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn module_dependency_decision_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "dependencyDecisionId",
            bounded_token_schema(160, "Optional decision id."),
        ),
        (
            "moduleDependencyRequestResourceId",
            resource_id_schema("module dependency request"),
        ),
        ("decision", enum_string(&["approved", "rejected", "denied"])),
        ("reason", bounded_string(2_000, "Decision reason.")),
        ("denialEvidence", refs_schema()),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn module_dependency_policy_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "dependencyPolicyId",
            bounded_token_schema(160, "Optional policy id."),
        ),
        (
            "moduleDependencyDecisionResourceId",
            resource_id_schema("module dependency decision"),
        ),
        (
            "lifecycleState",
            enum_string(&["active", "superseded", "archived"]),
        ),
        ("reason", bounded_string(2_000, "Activation reason.")),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn module_lifecycle_request_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "moduleInstallDecisionResourceId",
            resource_id_schema("module install decision"),
        ),
        (
            "lifecycleAction",
            enum_string(&["enable", "disable", "quarantine", "rollback"]),
        ),
        (
            "lifecycleTransitionId",
            bounded_token_schema(160, "Optional transition id."),
        ),
        ("reason", bounded_string(2_000, "Transition reason.")),
        ("rollbackProofRefs", refs_schema()),
        (
            "rollbackReadiness",
            enum_string(&["not_proven", "ready", "blocked"]),
        ),
        ("evidenceRefs", refs_schema()),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn module_lifecycle_decision_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "moduleLifecycleResourceId",
            resource_id_schema("module lifecycle state"),
        ),
        (
            "expectedModuleLifecycleVersionId",
            version_id_schema("module lifecycle state"),
        ),
        ("decision", const_string("approved")),
        (
            "approvalRequestResourceId",
            resource_id_schema("approval request"),
        ),
        (
            "approvalDecisionResourceId",
            resource_id_schema("approval decision"),
        ),
        ("reason", bounded_string(2_000, "Decision reason.")),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn module_program_start_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "moduleLifecycleResourceId",
            resource_id_schema("enabled module lifecycle state"),
        ),
        (
            "runtimeRequestId",
            bounded_token_schema(256, "Runtime request id."),
        ),
        (
            "runtimeKind",
            bounded_token_schema(256, "Optional runtime kind."),
        ),
        (
            "runtimeLabel",
            bounded_string(1_000, "Optional runtime label."),
        ),
        (
            "command",
            string_schema("Delegated non-interactive command."),
        ),
        ("runtimeId", bounded_token_schema(256, "Runtime id.")),
        ("languageId", bounded_token_schema(256, "Language id.")),
        (
            "programFingerprint",
            bounded_token_schema(256, "Program fingerprint."),
        ),
        ("reason", bounded_string(1_000, "Execution reason.")),
        ("networkPolicy", const_string("none")),
        (
            "programId",
            bounded_token_schema(256, "Optional program id."),
        ),
        (
            "programLabel",
            bounded_string(1_000, "Optional program label."),
        ),
        (
            "programSummary",
            bounded_string(1_000, "Optional program summary."),
        ),
        (
            "inputFingerprint",
            bounded_token_schema(256, "Optional input fingerprint."),
        ),
        ("sourceRef", object_schema("Optional source ref.")),
        ("inputRef", object_schema("Optional input ref.")),
        ("inputRefs", refs_schema()),
        ("sourceRefs", refs_schema()),
        ("evidenceRefs", refs_schema()),
        (
            "timeoutMs",
            bounded_integer_schema(1, MAX_TIMEOUT_MS, "Maximum wall-clock runtime."),
        ),
        (
            "maxOutputBytes",
            bounded_integer_schema(1, MAX_OUTPUT_BYTES, "Maximum captured output bytes."),
        ),
        (
            "cleanupAfterSeconds",
            json!({"type": "integer", "minimum": 0}),
        ),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn module_program_followup_fields(write: bool, cleanup: bool) -> Vec<(&'static str, Value)> {
    let mut fields = vec![
        (
            "moduleRuntimeResourceId",
            resource_id_schema("module runtime state"),
        ),
        ("jobResourceId", resource_id_schema("job process")),
    ];
    if write {
        fields.extend([
            (
                "expectedModuleRuntimeVersionId",
                version_id_schema("module runtime state"),
            ),
            ("reason", bounded_string(1_000, "Follow-up reason.")),
            ("idempotencyKey", idempotency_schema()),
        ]);
    }
    if cleanup {
        fields.push(("expectedJobVersionId", version_id_schema("job process")));
    }
    fields
}

fn module_runtime_request_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "moduleLifecycleResourceId",
            resource_id_schema("enabled module lifecycle state"),
        ),
        (
            "runtimeRequestId",
            bounded_token_schema(256, "Runtime request id."),
        ),
        ("runtimeKind", bounded_token_schema(256, "Runtime kind.")),
        ("runtimeLabel", bounded_string(1_000, "Runtime label.")),
        (
            "runtimeState",
            enum_string(&["requested", "running", "completed", "failed"]),
        ),
        ("reason", bounded_string(1_000, "Runtime request reason.")),
        ("inputRefs", refs_schema()),
        ("outputArtifactRefs", refs_schema()),
        ("evidenceRefs", refs_schema()),
        (
            "timeoutMs",
            bounded_integer_schema(1, MAX_TIMEOUT_MS, "Supervision timeout."),
        ),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn module_runtime_cancel_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "moduleRuntimeResourceId",
            resource_id_schema("module runtime state"),
        ),
        (
            "expectedModuleRuntimeVersionId",
            version_id_schema("module runtime state"),
        ),
        ("reason", bounded_string(1_000, "Cancellation reason.")),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn inspect_fields(field: &'static str, description: &'static str) -> Vec<(&'static str, Value)> {
    vec![(field, resource_id_schema(description))]
}

fn limit_schema(description: &str) -> Value {
    bounded_integer_schema(1, MAX_LIST_ITEMS, description)
}

fn refs_schema() -> Value {
    json!({"type": "array", "maxItems": MAX_REFS})
}

fn nonempty_refs_schema() -> Value {
    json!({"type": "array", "minItems": 1, "maxItems": MAX_REFS})
}

fn checks_schema() -> Value {
    json!({"type": "array", "maxItems": MAX_REFS})
}

fn object_schema(description: &str) -> Value {
    json!({"type": "object", "description": description})
}

fn resource_id_schema(resource: &str) -> Value {
    bounded_string(256, &format!("Exact {resource} resource id."))
}

fn version_id_schema(resource: &str) -> Value {
    bounded_string(256, &format!("Expected current {resource} version id."))
}

fn bounded_string(max_length: u64, description: &str) -> Value {
    json!({
        "type": "string",
        "minLength": 1,
        "maxLength": max_length,
        "description": description
    })
}

fn bounded_token_schema(max_length: u64, description: &str) -> Value {
    json!({
        "type": "string",
        "minLength": 1,
        "maxLength": max_length,
        "pattern": "^[A-Za-z0-9:._-]+$",
        "description": description
    })
}

fn enum_string(values: &[&str]) -> Value {
    json!({"type": "string", "enum": values})
}

fn const_string(value: &str) -> Value {
    json!({"type": "string", "const": value})
}

fn rfc3339_schema(description: &str) -> Value {
    json!({"type": "string", "format": "date-time", "description": description})
}

fn parity_evidence_schema() -> Value {
    json!({
        "type": "object",
        "required": ["status"],
        "properties": {
            "status": {
                "type": "string",
                "enum": ["not_applicable", "present", "missing", "drift_detected", "unchanged"]
            },
            "summary": {"type": "string", "minLength": 1, "maxLength": 2000},
            "evidenceRefs": {"type": "array", "maxItems": MAX_REFS},
            "packageManagerExecuted": {"type": "boolean", "const": false},
            "fileMutated": {"type": "boolean", "const": false}
        },
        "additionalProperties": false
    })
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::*;

    #[test]
    fn governance_operation_set_is_exact_and_unique() {
        let operations = GOVERNANCE_OPERATIONS
            .iter()
            .copied()
            .collect::<BTreeSet<_>>();
        assert_eq!(GOVERNANCE_OPERATIONS.len(), 59);
        assert_eq!(operations.len(), GOVERNANCE_OPERATIONS.len());
        assert!(
            GOVERNANCE_OPERATIONS
                .iter()
                .all(|operation| input_schema(operation).is_some())
        );
        assert!(input_schema("not_a_governance_operation").is_none());
    }

    #[test]
    fn every_governance_schema_is_closed_and_operation_constant_is_exact() {
        for operation in GOVERNANCE_OPERATIONS {
            let schema = input_schema(operation).expect("governance schema");
            assert_eq!(schema["type"], json!("object"), "{operation}");
            assert_eq!(schema["additionalProperties"], json!(false), "{operation}");
            assert_eq!(
                schema["payloadPlacement"],
                json!("top_level_capability_execute_payload"),
                "{operation}"
            );
            assert_eq!(
                schema["schemaCompleteness"],
                json!("exact_structural_contract"),
                "{operation}"
            );
            assert_eq!(schema["properties"]["operation"]["const"], json!(operation));
            assert!(required(&schema).contains("operation"), "{operation}");
        }
    }

    #[test]
    fn representative_property_sets_reject_union_schema_fields() {
        assert_eq!(
            properties("tool_source_list"),
            set(&["operation", "limit", "includeArchived"])
        );
        assert_eq!(
            properties("module_runtime_cancel"),
            set(&[
                "operation",
                "moduleRuntimeResourceId",
                "expectedModuleRuntimeVersionId",
                "reason",
                "idempotencyKey",
            ])
        );
        assert_eq!(
            properties("module_program_execution_status"),
            set(&["operation", "moduleRuntimeResourceId", "jobResourceId"])
        );
        assert!(!properties("module_list").contains("moduleManifestResourceId"));
        assert!(!properties("subagent_status").contains("promptSummary"));
    }

    #[test]
    fn representative_enums_bounds_and_nested_closure_match_domain_validators() {
        let schedule = input_schema("schedule_create").expect("schedule schema");
        assert_eq!(
            schedule["properties"]["intervalSeconds"],
            bounded_integer_schema(60, 31_622_400, "Interval cadence in seconds.")
        );
        assert_eq!(
            schedule["properties"]["target"]["additionalProperties"],
            json!(false)
        );

        let subagent = input_schema("subagent_launch").expect("subagent schema");
        assert_eq!(
            subagent["properties"]["modelPolicy"]["const"],
            json!("accepted_jobs_program_execution_v1")
        );
        assert_eq!(
            subagent["properties"]["modulePackId"]["const"],
            json!("jobs_program_execution")
        );

        let dependency =
            input_schema("module_dependency_request_record").expect("dependency schema");
        assert_eq!(
            dependency["properties"]["riskClass"]["enum"],
            json!(["low", "medium", "high", "critical"])
        );
        assert_eq!(
            dependency["properties"]["cargoTomlEvidence"]["additionalProperties"],
            json!(false)
        );

        let runtime = input_schema("module_runtime_request").expect("runtime schema");
        assert_eq!(
            runtime["properties"]["timeoutMs"]["maximum"],
            json!(120_000)
        );
    }

    #[test]
    fn schedule_create_requires_interval_seconds_for_interval_trigger() {
        let schedule = input_schema("schedule_create").expect("schedule schema");
        assert_eq!(
            schedule["allOf"],
            json!([{
                "if": {
                    "required": ["triggerType"],
                    "properties": {
                        "triggerType": {"const": "interval"}
                    }
                },
                "then": {
                    "required": ["intervalSeconds"]
                }
            }])
        );
    }

    #[test]
    fn representative_required_sets_are_operation_specific() {
        assert_eq!(
            required(&input_schema("procedural_state_inspect").expect("procedural schema")),
            set(&["operation", "proceduralKind", "proceduralRecordResourceId",])
        );
        assert_eq!(
            required(&input_schema("module_validation_record").expect("validation schema")),
            set(&[
                "operation",
                "title",
                "summary",
                "moduleRefs",
                "docEvidence",
                "testEvidence",
                "idempotencyKey",
            ])
        );
        assert_eq!(
            required(&input_schema("module_program_execution_cleanup").expect("cleanup schema")),
            set(&[
                "operation",
                "moduleRuntimeResourceId",
                "expectedModuleRuntimeVersionId",
                "jobResourceId",
                "expectedJobVersionId",
                "reason",
                "idempotencyKey",
            ])
        );
    }

    fn properties(operation: &str) -> BTreeSet<String> {
        let schema = input_schema(operation).expect("operation schema");
        schema["properties"]
            .as_object()
            .expect("properties")
            .keys()
            .cloned()
            .collect()
    }

    fn required(schema: &Value) -> BTreeSet<String> {
        schema["required"]
            .as_array()
            .expect("required")
            .iter()
            .map(|field| field.as_str().expect("required string").to_owned())
            .collect()
    }

    fn set(values: &[&str]) -> BTreeSet<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }
}
