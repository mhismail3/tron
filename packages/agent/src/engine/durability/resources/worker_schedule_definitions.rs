//! Worker schedule resource type definition helpers.

use serde_json::json;

use super::definitions::builtin_type;
use super::types::RegisterResourceType;

pub(super) fn worker_schedule_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![
        builtin_type(
            "worker_schedule_plan",
            "tron.resource.worker_schedule_plan.v1",
            json!({
                "type": "object",
                "required": [
                    "status",
                    "scheduleId",
                    "triggerId",
                    "autostartPlanResourceId",
                    "anchorAtUtc",
                    "intervalMs",
                    "missedTickPolicy",
                    "overlapPolicy",
                    "duplicatePolicy"
                ],
                "additionalProperties": true,
                "properties": {
                    "status": {"type": "string", "enum": ["reviewed"]},
                    "scheduleId": {"type": "string"},
                    "triggerId": {"type": "string"},
                    "autostartPlanResourceId": {"type": "string"},
                    "anchorAtUtc": {"type": "string"},
                    "intervalMs": {"type": "integer", "minimum": 60000, "maximum": 86400000},
                    "missedTickPolicy": {"type": "string", "enum": ["skip_missed_ticks_v1"]},
                    "overlapPolicy": {"type": "string", "enum": ["single_active_tick_v1"]},
                    "duplicatePolicy": {"type": "string", "enum": ["tick_idempotency_replay_v1"]},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["draft", "reviewed", "disabled", "revoked", "archived"],
            vec![
                "schedules",
                "uses_trigger",
                "uses_plan",
                "caused_by",
                "decided_by",
                "supported_by",
                "evidence_for",
                "derived_from",
                "revokes",
                "supersedes",
            ],
            json!({"read": ["resource.read"], "write": ["worker.schedule", "resource.write"], "delete": ["worker.schedule", "resource.write"]}),
        ),
        builtin_type(
            "worker_schedule_tick",
            "tron.resource.worker_schedule_tick.v1",
            json!({
                "type": "object",
                "required": [
                    "status",
                    "tickId",
                    "scheduleId",
                    "triggerId",
                    "autostartPlanResourceId",
                    "nominalTickAtUtc",
                    "dispatch",
                    "idempotency",
                    "trace",
                    "metadata"
                ],
                "additionalProperties": false,
                "properties": {
                    "status": {"type": "string", "enum": [
                        "requested",
                        "enqueued",
                        "skipped_missed",
                        "skipped_overlap",
                        "failed"
                    ]},
                    "tickId": {"type": "string"},
                    "scheduleId": {"type": "string"},
                    "triggerId": {"type": "string"},
                    "autostartPlanResourceId": {"type": "string"},
                    "nominalTickAtUtc": {"type": "string"},
                    "dispatch": {"type": "object"},
                    "idempotency": {"type": "object"},
                    "trace": {"type": "object"},
                    "missed": {"type": ["object", "null"]},
                    "overlap": {"type": ["object", "null"]},
                    "error": {"type": ["object", "null"]},
                    "metadata": {"type": "object"}
                }
            }),
            vec![
                "requested",
                "enqueued",
                "skipped_missed",
                "skipped_overlap",
                "failed",
                "archived",
            ],
            vec![
                "caused_by",
                "dispatches",
                "uses_trigger",
                "uses_plan",
                "audits",
                "derived_from",
            ],
            json!({"read": ["resource.read"], "write": ["worker.schedule", "trigger.dispatch", "resource.write"], "delete": ["worker.schedule", "resource.write"]}),
        ),
    ]
}
