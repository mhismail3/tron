//! Built-in resource definitions for retained agent records and output.

use serde_json::json;

use super::definitions::builtin_type;
use super::types::RegisterResourceType;

pub(super) fn agent_record_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![
        builtin_type(
            "execution_output",
            "tron.resource.execution_output.v1",
            json!({
                "type": "object",
                "required": ["exitCode", "durationMs", "timedOut", "outputTruncated"],
                "additionalProperties": true,
                "properties": {
                    "stdoutPreview": {"type": "string"},
                    "stderrPreview": {"type": "string"},
                    "logPreview": {"type": "string"},
                    "exitCode": {"type": "integer"},
                    "durationMs": {"type": "integer"},
                    "timedOut": {"type": "boolean"},
                    "outputTruncated": {"type": "boolean"},
                    "redactionPolicy": {"type": "object"},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["retained", "discarded", "archived"],
            vec!["produced_by", "produced", "derived_from"],
            json!({"read": ["resource.read"], "write": ["resource.write"]}),
        ),
        builtin_type(
            "agent_memory",
            "tron.resource.agent_memory.v1",
            json!({
                "type": "object",
                "required": ["statement", "status", "scope", "provenance", "evidenceRefs"],
                "additionalProperties": false,
                "properties": {
                    "statement": {"type": "string"},
                    "status": {"type": "string"},
                    "scope": {"type": "object"},
                    "confidence": {"type": "number"},
                    "provenance": {"type": "object"},
                    "evidenceRefs": {"type": "array", "items": {"type": "string"}},
                    "supersedesResourceId": {"type": "string"},
                    "supersededByResourceId": {"type": "string"},
                    "revokedByResourceId": {"type": "string"},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["draft", "active", "superseded", "revoked", "archived"],
            vec![
                "supported_by",
                "contradicted_by",
                "evidence_for",
                "derived_from",
                "supersedes",
                "superseded_by",
                "revoked_by",
                "decided_by",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"], "delete": ["resource.write"]}),
        ),
        builtin_type(
            "agent_rule",
            "tron.resource.agent_rule.v1",
            json!({
                "type": "object",
                "required": ["rule", "status", "scope", "provenance", "evidenceRefs"],
                "additionalProperties": false,
                "properties": {
                    "rule": {"type": "string"},
                    "status": {"type": "string"},
                    "scope": {"type": "object"},
                    "rationale": {"type": "string"},
                    "provenance": {"type": "object"},
                    "evidenceRefs": {"type": "array", "items": {"type": "string"}},
                    "decisionRefs": {"type": "array", "items": {"type": "string"}},
                    "supersedesResourceId": {"type": "string"},
                    "supersededByResourceId": {"type": "string"},
                    "revokedByResourceId": {"type": "string"},
                    "metadata": {"type": "object"}
                }
            }),
            vec![
                "draft",
                "proposed",
                "active",
                "superseded",
                "revoked",
                "archived",
            ],
            vec![
                "supported_by",
                "contradicted_by",
                "evidence_for",
                "derived_from",
                "supersedes",
                "superseded_by",
                "revoked_by",
                "decided_by",
                "promoted_by",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"], "delete": ["resource.write"]}),
        ),
        builtin_type(
            "agent_result",
            "tron.resource.agent_result.v1",
            json!({
                "type": "object",
                "required": ["message", "stopReason"],
                "additionalProperties": true,
                "properties": {
                    "message": {"type": "string"},
                    "promotedRefs": {"type": "array"},
                    "decisionRefs": {"type": "array"},
                    "subgoalRefs": {"type": "array"},
                    "stopReason": {"type": "string"},
                    "tokenUsage": {"type": "object"},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["final", "interrupted", "discarded", "archived"],
            vec![
                "answers",
                "decides",
                "promotes",
                "supports",
                "produced",
                "derived_from",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"]}),
        ),
    ]
}
