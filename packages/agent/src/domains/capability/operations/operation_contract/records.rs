//! Closed structural contracts for record-plane and session-governance operations.
//!
//! Domain services remain the semantic owners for scope, authority, lifecycle,
//! conditional linkage, secret/path rejection, and replay. These schemas own
//! the exact provider-visible top-level payload shape shared by catalog
//! inspection and the pre-authority structural gate.

use serde_json::{Value, json};

use crate::domains::notifications::contract::EVENT_FAMILIES;

use super::closed_schema;

#[cfg(test)]
const OPERATIONS: &[&str] = &[
    "goal_create",
    "goal_list",
    "goal_inspect",
    "goal_cancel",
    "question_create",
    "question_list",
    "question_inspect",
    "question_answer",
    "memory_status",
    "memory_list",
    "memory_inspect",
    "memory_query_list",
    "memory_query_inspect",
    "memory_decision_list",
    "memory_decision_inspect",
    "context_control_status",
    "context_control_snapshot",
    "context_control_compact",
    "context_control_clear",
    "context_control_action_list",
    "context_control_action_inspect",
    "context_survivor_record",
    "context_survivor_list",
    "context_survivor_disable",
    "context_exclusion_record",
    "context_exclusion_list",
    "context_exclusion_disable",
    "context_policy_snapshot",
    "media_create",
    "media_list",
    "media_inspect",
    "media_archive",
    "import_history_record",
    "import_history_list",
    "import_history_inspect",
    "import_preview_record",
    "import_preview_list",
    "import_preview_inspect",
    "program_execution_record",
    "program_execution_list",
    "program_execution_inspect",
    "prompt_artifact_record",
    "prompt_artifact_list",
    "prompt_artifact_inspect",
    "update_diagnostic_record",
    "update_diagnostic_list",
    "update_diagnostic_inspect",
    "device_list",
    "device_inspect",
    "notification_send",
    "notification_list",
    "notification_inspect",
    "notification_mark_read",
    "notification_mark_all_read",
    "web_research_request_record",
    "web_research_request_list",
    "web_research_request_inspect",
    "web_research_review_record",
    "web_research_review_list",
    "web_research_review_inspect",
    "web_research_source_record",
    "web_research_source_list",
    "web_research_source_inspect",
];

pub(super) fn input_schema(operation: &str) -> Option<Value> {
    let (required, fields) = match operation {
        "goal_create" => (
            vec!["operation", "objective", "idempotencyKey"],
            goal_create_fields(),
        ),
        "goal_list" => (vec!["operation"], goal_list_fields()),
        "goal_inspect" => (
            vec!["operation", "goalResourceId"],
            inspect_fields("goalResourceId"),
        ),
        "goal_cancel" => (
            vec!["operation", "goalResourceId", "reason", "idempotencyKey"],
            goal_cancel_fields(),
        ),
        "question_create" => (
            vec!["operation", "prompt", "idempotencyKey"],
            question_create_fields(),
        ),
        "question_list" => (vec!["operation"], question_list_fields()),
        "question_inspect" => (
            vec!["operation", "questionResourceId"],
            inspect_fields("questionResourceId"),
        ),
        "question_answer" => (
            vec![
                "operation",
                "questionResourceId",
                "expectedQuestionVersionId",
                "answerText",
                "reason",
                "idempotencyKey",
            ],
            question_answer_fields(),
        ),
        "memory_status" => (vec!["operation"], vec![]),
        "memory_list" | "memory_query_list" | "memory_decision_list" => {
            (vec!["operation"], memory_list_fields())
        }
        "memory_inspect" => (
            vec!["operation", "recordResourceId"],
            inspect_fields("recordResourceId"),
        ),
        "memory_query_inspect" => (
            vec!["operation", "queryResourceId"],
            inspect_fields("queryResourceId"),
        ),
        "memory_decision_inspect" => (
            vec!["operation", "decisionResourceId"],
            inspect_fields("decisionResourceId"),
        ),
        "context_control_status" => (vec!["operation"], vec![]),
        "context_control_snapshot" | "context_policy_snapshot" => (
            vec!["operation", "idempotencyKey"],
            context_snapshot_fields(),
        ),
        "context_control_compact" | "context_control_clear" => {
            (vec!["operation", "idempotencyKey"], context_action_fields())
        }
        "context_control_action_list" | "context_survivor_list" | "context_exclusion_list" => {
            (vec!["operation"], context_list_fields())
        }
        "context_control_action_inspect" => (
            vec!["operation", "contextControlActionResourceId"],
            context_action_inspect_fields(),
        ),
        "context_survivor_record" | "context_exclusion_record" => (
            vec![
                "operation",
                "targetKind",
                "targetRef",
                "label",
                "reason",
                "idempotencyKey",
            ],
            context_policy_record_fields(),
        ),
        "context_survivor_disable" => (
            vec![
                "operation",
                "contextSurvivorResourceId",
                "reason",
                "idempotencyKey",
            ],
            context_policy_disable_fields("contextSurvivorResourceId"),
        ),
        "context_exclusion_disable" => (
            vec![
                "operation",
                "contextExclusionResourceId",
                "reason",
                "idempotencyKey",
            ],
            context_policy_disable_fields("contextExclusionResourceId"),
        ),
        "media_create" => (
            vec![
                "operation",
                "mimeType",
                "sizeBytes",
                "blobRef",
                "idempotencyKey",
            ],
            media_create_fields(),
        ),
        "media_list" => (vec!["operation"], media_list_fields()),
        "media_inspect" => (
            vec!["operation", "mediaResourceId"],
            inspect_fields("mediaResourceId"),
        ),
        "media_archive" => (
            vec!["operation", "mediaResourceId", "idempotencyKey"],
            media_archive_fields(),
        ),
        "import_history_record" => (
            vec!["operation", "subjectId", "idempotencyKey"],
            import_history_record_fields(),
        ),
        "import_history_list" => (vec!["operation"], import_history_list_fields()),
        "import_history_inspect" => (
            vec!["operation", "importHistoryResourceId"],
            inspect_fields("importHistoryResourceId"),
        ),
        "import_preview_record" => (
            vec![
                "operation",
                "importHistoryRef",
                "repositoryTreeRef",
                "previewFingerprint",
                "idempotencyKey",
            ],
            import_preview_record_fields(),
        ),
        "import_preview_list" => (vec!["operation"], import_preview_list_fields()),
        "import_preview_inspect" => (
            vec!["operation", "importPreviewResourceId"],
            inspect_fields("importPreviewResourceId"),
        ),
        "program_execution_record" => (
            vec![
                "operation",
                "runtimeId",
                "languageId",
                "programFingerprint",
                "idempotencyKey",
            ],
            program_execution_record_fields(),
        ),
        "program_execution_list" => (vec!["operation"], program_execution_list_fields()),
        "program_execution_inspect" => (
            vec!["operation", "programExecutionResourceId"],
            inspect_fields("programExecutionResourceId"),
        ),
        "prompt_artifact_record" => (
            vec![
                "operation",
                "artifactKind",
                "title",
                "contentFingerprint",
                "idempotencyKey",
            ],
            prompt_artifact_record_fields(),
        ),
        "prompt_artifact_list" => (vec!["operation"], prompt_artifact_list_fields()),
        "prompt_artifact_inspect" => (
            vec!["operation", "promptArtifactResourceId"],
            inspect_fields("promptArtifactResourceId"),
        ),
        "update_diagnostic_record" => (
            vec!["operation", "releaseVersion", "idempotencyKey"],
            update_diagnostic_record_fields(),
        ),
        "update_diagnostic_list" => (vec!["operation"], update_diagnostic_list_fields()),
        "update_diagnostic_inspect" => (
            vec!["operation", "updateDiagnosticResourceId"],
            inspect_fields("updateDiagnosticResourceId"),
        ),
        "device_list" => (vec!["operation"], device_list_fields()),
        "device_inspect" => (
            vec!["operation", "deviceRegistrationResourceId"],
            inspect_fields("deviceRegistrationResourceId"),
        ),
        "notification_send" => (
            vec!["operation", "title", "body", "idempotencyKey"],
            notification_send_fields(),
        ),
        "notification_list" => (vec!["operation"], notification_list_fields()),
        "notification_inspect" => (
            vec!["operation", "notificationResourceId"],
            inspect_fields("notificationResourceId"),
        ),
        "notification_mark_read" => (
            vec!["operation", "notificationResourceId", "idempotencyKey"],
            notification_mark_read_fields(),
        ),
        "notification_mark_all_read" => (
            vec!["operation", "idempotencyKey"],
            notification_mark_all_read_fields(),
        ),
        "web_research_request_record" => (
            vec!["operation", "title", "questionSummary", "idempotencyKey"],
            web_research_request_record_fields(),
        ),
        "web_research_request_list" => (
            vec!["operation"],
            web_research_list_fields(&["pending_review", "superseded", "archived"]),
        ),
        "web_research_request_inspect" => (
            vec!["operation", "webResearchRequestResourceId"],
            inspect_fields("webResearchRequestResourceId"),
        ),
        "web_research_review_record" => (
            vec![
                "operation",
                "webResearchRequestResourceId",
                "reviewSummary",
                "idempotencyKey",
            ],
            web_research_review_record_fields(),
        ),
        "web_research_review_list" => (
            vec!["operation"],
            web_research_list_fields(&["pending_review", "accepted", "rejected", "archived"]),
        ),
        "web_research_review_inspect" => (
            vec!["operation", "webResearchReviewResourceId"],
            inspect_fields("webResearchReviewResourceId"),
        ),
        "web_research_source_record" => (
            vec![
                "operation",
                "artifactKind",
                "title",
                "summary",
                "idempotencyKey",
            ],
            web_research_source_record_fields(),
        ),
        "web_research_source_list" => (
            vec!["operation"],
            web_research_list_fields(&["available", "superseded", "archived"]),
        ),
        "web_research_source_inspect" => (
            vec!["operation", "webResearchSourceResourceId"],
            inspect_fields("webResearchSourceResourceId"),
        ),
        _ => return None,
    };
    let mut schema = closed_schema(operation, &required, fields);
    match operation {
        "question_create" => {
            schema["allOf"] = json!([{
                "if": {
                    "required": ["allowFreeForm"],
                    "properties": {
                        "allowFreeForm": {"const": false}
                    }
                },
                "then": {
                    "required": ["options"],
                    "properties": {
                        "options": {"minItems": 1}
                    }
                }
            }]);
        }
        "media_create" => {
            schema["allOf"] = json!([
                {
                    "if": {
                        "required": ["mediaKind"],
                        "properties": {
                            "mediaKind": {"const": "image"}
                        }
                    },
                    "then": {
                        "properties": {
                            "sizeBytes": {"maximum": 25 * 1024 * 1024}
                        }
                    }
                },
                {
                    "if": {
                        "required": ["mediaKind"],
                        "properties": {
                            "mediaKind": {"const": "document"}
                        }
                    },
                    "then": {
                        "properties": {
                            "sizeBytes": {"maximum": 50 * 1024 * 1024}
                        }
                    }
                }
            ]);
        }
        "web_research_source_record" => {
            schema["anyOf"] = json!([
                {"required": ["webResearchRequestResourceId"]},
                {"required": ["webResearchReviewResourceId"]}
            ]);
        }
        _ => {}
    }
    Some(schema)
}

fn goal_create_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("objective", bounded_string(2_000)),
        ("successCriteria", string_array(20, 500)),
        ("constraints", object_schema()),
        ("queueRefs", array_schema(None, None)),
        ("planRefs", array_schema(None, None)),
        ("evidenceRefs", array_schema(None, None)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn goal_list_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("state", enum_string(&["open", "cancelled"])),
        ("limit", bounded_integer(1, 100)),
    ]
}

fn goal_cancel_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("goalResourceId", resource_id_schema()),
        ("reason", bounded_string(1_000)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn question_create_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("prompt", bounded_string(4_000)),
        ("goalResourceId", resource_id_schema()),
        ("options", string_array(20, 500)),
        ("allowFreeForm", boolean_schema()),
        ("expiresAt", date_time_schema()),
        ("queueRefs", array_schema(None, None)),
        ("evidenceRefs", array_schema(None, None)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn question_list_fields() -> Vec<(&'static str, Value)> {
    vec![
        (
            "state",
            enum_string(&["pending", "answered", "expired", "cancelled"]),
        ),
        ("limit", bounded_integer(1, 100)),
    ]
}

fn question_answer_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("questionResourceId", resource_id_schema()),
        ("expectedQuestionVersionId", version_id_schema()),
        ("answerText", bounded_string(8_000)),
        ("reason", bounded_string(1_000)),
        ("evidenceRefs", array_schema(None, None)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn memory_list_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("lifecycle", non_empty_string()),
        ("limit", bounded_integer(1, 500)),
    ]
}

fn context_snapshot_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("sessionId", non_empty_string()),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn context_action_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("sessionId", non_empty_string()),
        ("reason", bounded_string(500)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn context_list_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("sessionId", non_empty_string()),
        ("limit", bounded_integer(1, 50)),
    ]
}

fn context_action_inspect_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("sessionId", non_empty_string()),
        ("contextControlActionResourceId", resource_id_schema()),
    ]
}

fn context_policy_record_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("sessionId", non_empty_string()),
        (
            "targetKind",
            enum_string(&[
                "message",
                "turn",
                "resource",
                "trace",
                "goal",
                "decision",
                "execution",
                "memory_ref",
                "context_action",
            ]),
        ),
        ("targetRef", bounded_string(256)),
        ("label", bounded_string(200)),
        ("reason", bounded_string(500)),
        ("priority", bounded_integer(0, 100)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn context_policy_disable_fields(resource_field: &'static str) -> Vec<(&'static str, Value)> {
    vec![
        ("sessionId", non_empty_string()),
        (resource_field, resource_id_schema()),
        ("expectedVersionId", version_id_schema()),
        ("reason", bounded_string(500)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn media_create_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("mediaId", bounded_string(160)),
        (
            "mediaKind",
            enum_string(&["voice_note", "audio", "image", "document"]),
        ),
        (
            "mimeType",
            enum_string(&[
                "audio/wav",
                "audio/x-wav",
                "audio/mpeg",
                "audio/mp4",
                "audio/aac",
                "audio/x-m4a",
                "audio/webm",
                "image/jpeg",
                "image/png",
                "image/heic",
                "image/webp",
                "application/pdf",
            ]),
        ),
        ("sizeBytes", bounded_integer(1, 150 * 1024 * 1024)),
        ("blobRef", bounded_string(512)),
        ("contentHash", bounded_string(160)),
        ("title", bounded_string(160)),
        ("summary", bounded_string(2_000)),
        ("durationMs", non_negative_integer()),
        (
            "transcriptionState",
            enum_string(&["not_requested", "local_completed", "local_failed"]),
        ),
        ("transcriptionText", bounded_string(8_000)),
        ("transcriptionLanguage", bounded_string(32)),
        ("transcriptionModel", bounded_string(128)),
        ("sourceRefs", array_schema(Some(25), None)),
        ("evidenceRefs", array_schema(Some(25), None)),
        ("maxAgeDays", bounded_integer(1, 366)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn media_list_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("limit", bounded_integer(1, 100)),
        ("includeArchived", boolean_schema()),
        (
            "mediaKind",
            enum_string(&["voice_note", "audio", "image", "document"]),
        ),
    ]
}

fn media_archive_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("mediaResourceId", resource_id_schema()),
        ("expectedMediaVersionId", version_id_schema()),
        ("reason", bounded_string(1_000)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn import_history_record_fields() -> Vec<(&'static str, Value)> {
    let reference = custody_ref_schema(true);
    vec![
        ("recordId", bounded_string(160)),
        ("graphKind", const_string("session_resource")),
        ("subjectKind", enum_string(&["session", "resource"])),
        ("subjectId", bounded_string(256)),
        (
            "parentRefs",
            array_schema(Some(16), Some(reference.clone())),
        ),
        ("childRefs", array_schema(Some(16), Some(reference.clone()))),
        (
            "sourceRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        ("evidenceRefs", array_schema(Some(25), Some(reference))),
        ("lineageLabel", bounded_string(160)),
        ("lineageSummary", bounded_string(2_000)),
        ("renderHint", const_string("generic_graph")),
        ("importSourceKind", bounded_string(256)),
        ("maxAgeDays", bounded_integer(1, 366)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn import_history_list_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("limit", bounded_integer(1, 100)),
        ("includeArchived", boolean_schema()),
        ("graphKind", const_string("session_resource")),
        ("subjectKind", enum_string(&["session", "resource"])),
        ("subjectId", bounded_string(256)),
    ]
}

fn import_preview_record_fields() -> Vec<(&'static str, Value)> {
    let reference = custody_ref_schema(false);
    vec![
        ("previewId", bounded_string(160)),
        (
            "importHistoryRef",
            typed_custody_ref_schema("import_history_record"),
        ),
        (
            "repositoryTreeRef",
            typed_custody_ref_schema("repository_tree_snapshot"),
        ),
        ("repositoryRef", reference.clone()),
        ("rootRef", reference.clone()),
        ("headRef", reference.clone()),
        ("previewFingerprint", bounded_string(256)),
        (
            "pathEntries",
            array_schema(Some(100), Some(import_preview_path_entry_schema())),
        ),
        ("totalEntries", bounded_integer(0, 100_000)),
        ("addedEntries", bounded_integer(0, 100_000)),
        ("modifiedEntries", bounded_integer(0, 100_000)),
        ("removedEntries", bounded_integer(0, 100_000)),
        ("renamedEntries", bounded_integer(0, 100_000)),
        ("maxDepth", bounded_integer(0, 64)),
        ("previewLabel", bounded_string(160)),
        ("previewSummary", bounded_string(2_000)),
        ("changeSummary", bounded_string(2_000)),
        (
            "sourceRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        ("evidenceRefs", array_schema(Some(25), Some(reference))),
        ("maxAgeDays", bounded_integer(1, 366)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn import_preview_list_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("limit", bounded_integer(1, 100)),
        ("includeArchived", boolean_schema()),
        ("repositoryRefId", resource_id_schema()),
        ("importHistoryRefId", resource_id_schema()),
        ("repositoryTreeRefId", resource_id_schema()),
    ]
}

fn program_execution_record_fields() -> Vec<(&'static str, Value)> {
    let reference = custody_ref_schema(false);
    vec![
        ("programId", bounded_string(160)),
        ("runtimeId", bounded_string(256)),
        ("languageId", bounded_string(256)),
        ("programFingerprint", bounded_string(256)),
        ("sourceRef", reference.clone()),
        ("inputRef", reference.clone()),
        ("outputRef", reference.clone()),
        ("inputFingerprint", bounded_string(256)),
        ("outputFingerprint", bounded_string(256)),
        ("maxWallClockMs", bounded_integer(0, 3_600_000)),
        ("maxMemoryMb", bounded_integer(0, 1_048_576)),
        ("maxOutputBytes", bounded_integer(0, 100_000_000)),
        ("programLabel", bounded_string(160)),
        ("programSummary", bounded_string(2_000)),
        (
            "sourceRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        ("evidenceRefs", array_schema(Some(25), Some(reference))),
        ("maxAgeDays", bounded_integer(1, 366)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn program_execution_list_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("limit", bounded_integer(1, 100)),
        ("includeArchived", boolean_schema()),
        ("runtimeId", bounded_string(256)),
        ("languageId", bounded_string(256)),
    ]
}

fn prompt_artifact_record_fields() -> Vec<(&'static str, Value)> {
    let reference = custody_ref_schema(false);
    vec![
        ("artifactId", bounded_string(160)),
        (
            "artifactKind",
            enum_string(&["history_entry", "snippet", "template", "prompt_reference"]),
        ),
        ("title", bounded_string(160)),
        ("summary", bounded_string(2_000)),
        ("preview", bounded_string(1_000)),
        ("contentFingerprint", bounded_string(256)),
        ("contentRef", reference.clone()),
        (
            "sourceRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        ("evidenceRefs", array_schema(Some(25), Some(reference))),
        (
            "retentionState",
            enum_string(&["active", "archival_candidate", "retained"]),
        ),
        ("maxAgeDays", bounded_integer(1, 366)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn prompt_artifact_list_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("limit", bounded_integer(1, 100)),
        ("includeArchived", boolean_schema()),
        (
            "artifactKind",
            enum_string(&["history_entry", "snippet", "template", "prompt_reference"]),
        ),
    ]
}

fn update_diagnostic_record_fields() -> Vec<(&'static str, Value)> {
    let reference = custody_ref_schema(true);
    vec![
        ("diagnosticId", bounded_string(160)),
        ("checkKind", const_string("metadata_snapshot")),
        ("releaseChannel", bounded_string(256)),
        ("releaseVersion", bounded_string(256)),
        ("releaseBuild", bounded_string(256)),
        (
            "diagnosticStatus",
            enum_string(&["current", "update_available", "unknown"]),
        ),
        (
            "signatureStatus",
            enum_string(&["verified", "not_checked", "unavailable"]),
        ),
        ("diagnosticLabel", bounded_string(160)),
        ("diagnosticSummary", bounded_string(2_000)),
        ("provenanceSummary", bounded_string(2_000)),
        (
            "sourceRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        (
            "evidenceRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        (
            "provenanceRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        ("signatureRefs", array_schema(Some(25), Some(reference))),
        ("maxAgeDays", bounded_integer(1, 366)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn update_diagnostic_list_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("limit", bounded_integer(1, 100)),
        ("includeArchived", boolean_schema()),
        ("releaseChannel", bounded_string(256)),
        (
            "diagnosticStatus",
            enum_string(&["current", "update_available", "unknown"]),
        ),
        (
            "signatureStatus",
            enum_string(&["verified", "not_checked", "unavailable"]),
        ),
    ]
}

fn device_list_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("limit", bounded_integer(1, 100)),
        ("includeUnregistered", boolean_schema()),
        ("state", enum_string(&["active", "unregistered"])),
    ]
}

fn notification_send_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("notificationId", bounded_string(160)),
        ("family", enum_string(EVENT_FAMILIES)),
        (
            "severity",
            enum_string(&["info", "warning", "action_required"]),
        ),
        ("title", bounded_string(160)),
        ("body", bounded_string(2_000)),
        ("pushRequested", boolean_schema()),
        ("sourceRefs", array_schema(Some(25), None)),
        ("evidenceRefs", array_schema(Some(25), None)),
        ("maxAgeDays", bounded_integer(1, 366)),
        ("maxInboxRecords", bounded_integer(1, 5_000)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn notification_list_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("limit", bounded_integer(1, 100)),
        ("includeRead", boolean_schema()),
        ("state", enum_string(&["unread", "read", "archived"])),
    ]
}

fn notification_mark_read_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("notificationResourceId", resource_id_schema()),
        ("expectedNotificationVersionId", version_id_schema()),
        ("reason", bounded_string(1_000)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn notification_mark_all_read_fields() -> Vec<(&'static str, Value)> {
    vec![
        ("reason", bounded_string(1_000)),
        ("limit", bounded_integer(1, 500)),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn web_research_request_record_fields() -> Vec<(&'static str, Value)> {
    let reference = web_research_ref_schema();
    vec![
        ("webResearchRequestId", bounded_string(160)),
        (
            "lifecycleState",
            enum_string(&["pending_review", "superseded", "archived"]),
        ),
        ("title", bounded_string(160)),
        ("questionSummary", bounded_string(2_000)),
        ("scopeSummary", bounded_string(2_000)),
        ("policyLabels", string_array(16, 256)),
        (
            "sourceRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        (
            "citationRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        (
            "robotsEvidenceRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        (
            "dependencyRequestRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        (
            "currentScopeRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        ("evidenceRefs", array_schema(Some(25), Some(reference))),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn web_research_review_record_fields() -> Vec<(&'static str, Value)> {
    let reference = web_research_ref_schema();
    vec![
        ("webResearchReviewId", bounded_string(160)),
        ("webResearchRequestResourceId", resource_id_schema()),
        (
            "lifecycleState",
            enum_string(&["pending_review", "accepted", "rejected", "archived"]),
        ),
        ("reviewOutcome", bounded_string(256)),
        ("reviewSummary", bounded_string(2_000)),
        ("policyLabels", string_array(16, 256)),
        (
            "sourceRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        (
            "citationRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        (
            "robotsEvidenceRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        (
            "dependencyRequestRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        ("evidenceRefs", array_schema(Some(25), Some(reference))),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn web_research_source_record_fields() -> Vec<(&'static str, Value)> {
    let reference = web_research_ref_schema();
    vec![
        ("webResearchSourceId", bounded_string(160)),
        ("webResearchRequestResourceId", resource_id_schema()),
        ("webResearchReviewResourceId", resource_id_schema()),
        (
            "lifecycleState",
            enum_string(&["available", "superseded", "archived"]),
        ),
        ("artifactKind", bounded_string(256)),
        ("title", bounded_string(160)),
        ("summary", bounded_string(2_000)),
        ("policyLabels", string_array(16, 256)),
        (
            "sourceRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        (
            "citationRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        (
            "robotsEvidenceRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        (
            "dependencyRequestRefs",
            array_schema(Some(25), Some(reference.clone())),
        ),
        ("evidenceRefs", array_schema(Some(25), Some(reference))),
        ("idempotencyKey", idempotency_schema()),
    ]
}

fn web_research_list_fields(states: &[&str]) -> Vec<(&'static str, Value)> {
    vec![
        ("limit", bounded_integer(1, 100)),
        ("lifecycleState", enum_string(states)),
    ]
}

fn inspect_fields(field: &'static str) -> Vec<(&'static str, Value)> {
    vec![(field, resource_id_schema())]
}

fn non_empty_string() -> Value {
    json!({"type": "string", "minLength": 1})
}

fn bounded_string(max_length: u64) -> Value {
    json!({"type": "string", "minLength": 1, "maxLength": max_length})
}

fn date_time_schema() -> Value {
    json!({"type": "string", "minLength": 1, "format": "date-time"})
}

fn const_string(value: &str) -> Value {
    json!({"type": "string", "const": value})
}

fn enum_string(values: &[&str]) -> Value {
    json!({"type": "string", "enum": values})
}

fn boolean_schema() -> Value {
    json!({"type": "boolean"})
}

fn bounded_integer(minimum: u64, maximum: u64) -> Value {
    json!({"type": "integer", "minimum": minimum, "maximum": maximum})
}

fn non_negative_integer() -> Value {
    json!({"type": "integer", "minimum": 0})
}

fn object_schema() -> Value {
    json!({"type": "object"})
}

fn idempotency_schema() -> Value {
    bounded_string(256)
}

fn resource_id_schema() -> Value {
    bounded_string(256)
}

fn version_id_schema() -> Value {
    bounded_string(256)
}

fn string_array(max_items: u64, item_max_length: u64) -> Value {
    array_schema(Some(max_items), Some(bounded_string(item_max_length)))
}

fn array_schema(max_items: Option<u64>, items: Option<Value>) -> Value {
    let mut schema = json!({"type": "array"});
    if let Some(max_items) = max_items {
        schema["maxItems"] = json!(max_items);
    }
    if let Some(items) = items {
        schema["items"] = items;
    }
    schema
}

fn custody_ref_schema(allow_metadata: bool) -> Value {
    let mut properties = serde_json::Map::new();
    for field in ["kind", "id", "resourceId", "role", "versionId"] {
        properties.insert(field.to_owned(), bounded_string(256));
    }
    if allow_metadata {
        properties.insert("metadata".to_owned(), json!({}));
    }
    json!({
        "type": "object",
        "required": ["kind"],
        "properties": properties,
        "additionalProperties": false,
        "anyOf": [
            {"required": ["id"]},
            {"required": ["resourceId"]}
        ]
    })
}

fn typed_custody_ref_schema(kind: &str) -> Value {
    let mut schema = custody_ref_schema(false);
    schema["properties"]["kind"] = const_string(kind);
    schema
}

fn import_preview_path_entry_schema() -> Value {
    json!({
        "type": "object",
        "required": ["path"],
        "properties": {
            "path": bounded_string(240),
            "kind": enum_string(&["file", "directory", "symlink", "submodule", "unknown"]),
            "mode": bounded_string(256),
            "objectRef": bounded_string(256),
            "contentHash": bounded_string(256),
            "changeKind": bounded_string(256),
            "sizeBytes": {"type": "integer", "minimum": 0}
        },
        "additionalProperties": false
    })
}

fn web_research_ref_schema() -> Value {
    json!({
        "type": "object",
        "required": ["kind", "resourceId"],
        "properties": {
            "kind": bounded_string(256),
            "resourceId": bounded_string(256),
            "role": bounded_string(256),
            "summary": bounded_string(2_000)
        },
        "additionalProperties": false
    })
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use crate::engine::FunctionId;
    use crate::engine::kernel::schema;

    use super::*;

    #[test]
    fn operation_set_is_exact_unique_and_complete() {
        let actual = OPERATIONS.iter().copied().collect::<BTreeSet<_>>();
        assert_eq!(OPERATIONS.len(), 63);
        assert_eq!(
            actual.len(),
            OPERATIONS.len(),
            "duplicate operation contract"
        );
        for operation in OPERATIONS {
            assert!(
                input_schema(operation).is_some(),
                "missing schema for {operation}"
            );
        }
        assert!(input_schema("records_unknown").is_none());
    }

    #[test]
    fn every_contract_is_a_closed_exact_top_level_schema() {
        let function_id = FunctionId::new("capability::execute").expect("function id");
        for operation in OPERATIONS {
            let contract = input_schema(operation).expect("operation contract");
            let properties = contract["properties"]
                .as_object()
                .expect("properties object");
            assert_eq!(contract["type"], "object", "{operation}");
            assert_eq!(contract["additionalProperties"], false, "{operation}");
            assert_eq!(
                contract["payloadPlacement"], "top_level_capability_execute_payload",
                "{operation}"
            );
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
                    .expect("required array")
                    .iter()
                    .any(|field| field.as_str() == Some("operation")),
                "{operation}"
            );
            for required in contract["required"].as_array().expect("required array") {
                let required = required.as_str().expect("required field name");
                assert!(
                    properties.contains_key(required),
                    "{operation} requires undeclared field {required}"
                );
            }
            schema::validate_schema_definition(&function_id, "operation request", &contract)
                .unwrap_or_else(|error| panic!("invalid schema for {operation}: {error}"));
        }
    }

    #[test]
    fn representative_property_sets_are_exact() {
        assert_property_set(
            "goal_create",
            &[
                "constraints",
                "evidenceRefs",
                "idempotencyKey",
                "objective",
                "operation",
                "planRefs",
                "queueRefs",
                "successCriteria",
            ],
        );
        assert_property_set(
            "context_survivor_record",
            &[
                "idempotencyKey",
                "label",
                "operation",
                "priority",
                "reason",
                "sessionId",
                "targetKind",
                "targetRef",
            ],
        );
        assert_property_set(
            "notification_send",
            &[
                "body",
                "evidenceRefs",
                "family",
                "idempotencyKey",
                "maxAgeDays",
                "maxInboxRecords",
                "notificationId",
                "operation",
                "pushRequested",
                "severity",
                "sourceRefs",
                "title",
            ],
        );
        assert_property_set(
            "web_research_source_record",
            &[
                "artifactKind",
                "citationRefs",
                "dependencyRequestRefs",
                "evidenceRefs",
                "idempotencyKey",
                "lifecycleState",
                "operation",
                "policyLabels",
                "robotsEvidenceRefs",
                "sourceRefs",
                "summary",
                "title",
                "webResearchRequestResourceId",
                "webResearchReviewResourceId",
                "webResearchSourceId",
            ],
        );
    }

    #[test]
    fn representative_contracts_reject_unknown_fields_and_invalid_values() {
        validate(
            "goal_create",
            &json!({
                "operation": "goal_create",
                "objective": "Audit the capability catalog",
                "idempotencyKey": "goal-1"
            }),
        )
        .expect("valid goal payload");
        let unknown = validate(
            "goal_create",
            &json!({
                "operation": "goal_create",
                "objective": "Audit the capability catalog",
                "idempotencyKey": "goal-1",
                "hiddenFallback": true
            }),
        )
        .expect_err("unknown fields must fail closed");
        assert!(unknown.to_string().contains("additional property"));

        let target_kind = validate(
            "context_survivor_record",
            &json!({
                "operation": "context_survivor_record",
                "targetKind": "raw_prompt",
                "targetRef": "message-1",
                "label": "Keep decision",
                "reason": "Required for the next turn",
                "idempotencyKey": "survivor-1"
            }),
        )
        .expect_err("unsupported survivor target kind must fail");
        assert!(target_kind.to_string().contains("enum"));

        let family = validate(
            "notification_send",
            &json!({
                "operation": "notification_send",
                "family": "arbitrary",
                "title": "Review needed",
                "body": "Inspect the bounded evidence.",
                "idempotencyKey": "notification-1"
            }),
        )
        .expect_err("unsupported notification family must fail");
        assert!(family.to_string().contains("enum"));

        let oversized_media = validate(
            "media_create",
            &json!({
                "operation": "media_create",
                "mimeType": "audio/wav",
                "sizeBytes": 157_286_401_u64,
                "blobRef": "blob:media-1",
                "idempotencyKey": "media-1"
            }),
        )
        .expect_err("media envelope must reject oversize payloads");
        assert!(oversized_media.to_string().contains("exceeds maximum"));
    }

    #[test]
    fn web_research_source_requires_request_or_review_linkage() {
        let contract = input_schema("web_research_source_record").expect("source contract");
        assert_eq!(
            contract["anyOf"],
            json!([
                {"required": ["webResearchRequestResourceId"]},
                {"required": ["webResearchReviewResourceId"]}
            ])
        );
    }

    #[test]
    fn question_create_requires_nonempty_options_when_free_form_is_disabled() {
        let contract = input_schema("question_create").expect("question contract");
        assert_eq!(
            contract["allOf"],
            json!([{
                "if": {
                    "required": ["allowFreeForm"],
                    "properties": {
                        "allowFreeForm": {"const": false}
                    }
                },
                "then": {
                    "required": ["options"],
                    "properties": {
                        "options": {"minItems": 1}
                    }
                }
            }])
        );
    }

    #[test]
    fn media_create_size_bounds_match_each_runtime_media_kind() {
        let contract = input_schema("media_create").expect("media contract");
        assert_eq!(
            contract["properties"]["sizeBytes"],
            bounded_integer(1, 150 * 1024 * 1024)
        );
        assert_eq!(
            contract["allOf"],
            json!([
                {
                    "if": {
                        "required": ["mediaKind"],
                        "properties": {
                            "mediaKind": {"const": "image"}
                        }
                    },
                    "then": {
                        "properties": {
                            "sizeBytes": {"maximum": 25 * 1024 * 1024}
                        }
                    }
                },
                {
                    "if": {
                        "required": ["mediaKind"],
                        "properties": {
                            "mediaKind": {"const": "document"}
                        }
                    },
                    "then": {
                        "properties": {
                            "sizeBytes": {"maximum": 50 * 1024 * 1024}
                        }
                    }
                }
            ])
        );
    }

    fn assert_property_set(operation: &str, expected: &[&str]) {
        let contract = input_schema(operation).expect("operation contract");
        let actual = contract["properties"]
            .as_object()
            .expect("properties object")
            .keys()
            .map(String::as_str)
            .collect::<BTreeSet<_>>();
        assert_eq!(actual, expected.iter().copied().collect());
    }

    fn validate(operation: &str, payload: &Value) -> crate::engine::Result<()> {
        let function_id = FunctionId::new("capability::execute").expect("function id");
        schema::validate_payload(
            &function_id,
            "operation request",
            &input_schema(operation).expect("operation contract"),
            payload,
        )
    }
}
