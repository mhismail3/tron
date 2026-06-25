//! Scheduler-owned built-in resource definitions.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, RegisterResourceType, SCHEDULE_KIND, SCHEDULE_RUN_KIND,
    SCHEDULE_RUN_SCHEMA_ID, SCHEDULE_SCHEMA_ID,
};
use crate::engine::kernel::ids::WorkerId;

pub(super) fn scheduler_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![
        RegisterResourceType {
            kind: SCHEDULE_KIND.to_owned(),
            schema_id: SCHEDULE_SCHEMA_ID.to_owned(),
            schema: json!({
                "type": "object",
                "required": [
                    "schemaVersion",
                    "state",
                    "title",
                    "scheduleKind",
                    "trigger",
                    "timezonePolicy",
                    "missedRunPolicy",
                    "target",
                    "authority",
                    "retention",
                    "createdAt",
                    "updatedAt",
                    "nextFireAt",
                    "traceRefs",
                    "replayRefs",
                    "revision"
                ],
                "additionalProperties": true,
                "properties": {
                    "schemaVersion": {"type": "string"},
                    "state": {"type": "string", "enum": ["active", "paused", "completed", "cancelled", "archived"]},
                    "title": {"type": "string"},
                    "scheduleKind": {"type": "string", "enum": ["reminder", "monitor", "automation"]},
                    "trigger": {"type": "object"},
                    "timezonePolicy": {"type": "object"},
                    "missedRunPolicy": {"type": "object"},
                    "target": {"type": "object"},
                    "authority": {"type": "object"},
                    "retention": {"type": "object"},
                    "createdAt": {"type": "string"},
                    "updatedAt": {"type": "string"},
                    "nextFireAt": {"type": ["string", "null"]},
                    "lastEvaluatedAt": {"type": ["string", "null"]},
                    "lastRunAt": {"type": ["string", "null"]},
                    "cancellation": {"type": ["object", "null"]},
                    "traceRefs": {"type": "array"},
                    "replayRefs": {"type": "array"},
                    "revision": {"type": "integer"}
                }
            }),
            lifecycle_states: ["active", "paused", "completed", "cancelled", "archived"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            versioning_mode: EngineResourceVersioningMode::AppendOnly,
            allowed_link_relations: [
                "produced_run",
                "derived_from",
                "evidence_for",
                "supersedes",
                "cancelled_by",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect(),
            default_retention: json!({"class": "project", "maxRunRecordsPerSchedule": 1000}),
            redaction_rules: json!({"preview": "bounded_schedule_summary"}),
            materialization_rules: json!({"durableRunsRequireResourceVersion": true}),
            required_capabilities: json!({
                "read": ["scheduler.read", "resource.read"],
                "write": ["scheduler.write", "resource.write"],
                "cancel": ["scheduler.write", "resource.write"],
                "fire": ["scheduler.fire", "scheduler.write", "resource.write"]
            }),
            owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
        },
        RegisterResourceType {
            kind: SCHEDULE_RUN_KIND.to_owned(),
            schema_id: SCHEDULE_RUN_SCHEMA_ID.to_owned(),
            schema: json!({
                "type": "object",
                "required": [
                    "schemaVersion",
                    "state",
                    "scheduleResourceId",
                    "scheduleVersionId",
                    "scheduleKind",
                    "scheduledFor",
                    "evaluatedAt",
                    "trigger",
                    "target",
                    "authority",
                    "idempotency",
                    "retention",
                    "traceRefs",
                    "replayRefs",
                    "revision"
                ],
                "additionalProperties": true,
                "properties": {
                    "schemaVersion": {"type": "string"},
                    "state": {"type": "string", "enum": ["recorded", "skipped_missed", "cancelled", "stale", "archived"]},
                    "scheduleResourceId": {"type": "string"},
                    "scheduleVersionId": {"type": "string"},
                    "scheduleKind": {"type": "string"},
                    "scheduledFor": {"type": "string"},
                    "evaluatedAt": {"type": "string"},
                    "trigger": {"type": "object"},
                    "target": {"type": "object"},
                    "authority": {"type": "object"},
                    "missed": {"type": "object"},
                    "backgroundResult": {"type": "object"},
                    "idempotency": {"type": "object"},
                    "retention": {"type": "object"},
                    "traceRefs": {"type": "array"},
                    "replayRefs": {"type": "array"},
                    "revision": {"type": "integer"}
                }
            }),
            lifecycle_states: [
                "recorded",
                "skipped_missed",
                "cancelled",
                "stale",
                "archived",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect(),
            versioning_mode: EngineResourceVersioningMode::AppendOnly,
            allowed_link_relations: ["run_of", "derived_from", "evidence_for", "supersedes"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            default_retention: json!({"class": "project", "maxAgeDays": 90}),
            redaction_rules: json!({"preview": "bounded_run_summary"}),
            materialization_rules: json!({"resultPayload": "bounded_inline_only"}),
            required_capabilities: json!({
                "read": ["scheduler.read", "resource.read"],
                "write": ["scheduler.write", "resource.write"]
            }),
            owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
        },
    ]
}
