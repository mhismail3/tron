//! Durable resource contract for module manifest records.
//!
//! The module-registry domain owns the kind, schema, retention, redaction, and
//! materialization rules. Domain registration installs this definition before
//! reconciling source-owned manifest payloads into the generic engine store.

use serde_json::{Value, json};

use super::{
    MODULE_MANIFEST_KIND, MODULE_MANIFEST_SCHEMA_ID, READ_SCOPE, RESOURCE_READ_SCOPE,
    SCHEMA_VERSION, WORKER,
};
use crate::engine::{EngineResourceVersioningMode, RegisterResourceType, WorkerId};

pub(in crate::domains) fn resource_type_definition() -> RegisterResourceType {
    RegisterResourceType {
        kind: MODULE_MANIFEST_KIND.to_owned(),
        schema_id: MODULE_MANIFEST_SCHEMA_ID.to_owned(),
        schema: module_manifest_schema(),
        lifecycle_states: ["candidate", "validated", "stale", "archived"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: ["derived_from", "evidence_for", "supersedes"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        default_retention: json!({"class": "module_registry_manifest"}),
        redaction_rules: json!({
            "projection": "provider_safe",
            "rawManifest": "not_provider_visible",
            "localPaths": "forbidden",
            "secrets": "forbidden",
            "commands": "forbidden",
            "grantIds": "forbidden"
        }),
        materialization_rules: json!({
            "durableOutputsRequireResourceVersion": true,
            "activation": "forbidden"
        }),
        required_capabilities: json!({
            "read": [READ_SCOPE, RESOURCE_READ_SCOPE]
        }),
        owner_worker_id: WorkerId::new(WORKER).expect("valid static worker id"),
    }
}

fn module_manifest_schema() -> Value {
    json!({
        "type": "object",
        "required": [
            "schemaVersion",
            "identity",
            "capabilityDeclarations",
            "resourceDeclarations",
            "authorityNeeds",
            "settingsDeclarations",
            "dependencyIntents",
            "validation",
            "provenance",
            "lifecycle",
            "redactionProof"
        ],
        "additionalProperties": false,
        "properties": {
            "schemaVersion": {"type": "string", "const": SCHEMA_VERSION},
            "identity": {
                "type": "object",
                "required": ["moduleId", "name", "kind", "owner", "summary", "version"],
                "additionalProperties": false,
                "properties": {
                    "moduleId": {"type": "string"},
                    "name": {"type": "string"},
                    "kind": {"type": "string"},
                    "owner": {"type": "string"},
                    "summary": {"type": "string"},
                    "version": {"type": "string"}
                }
            },
            "capabilityDeclarations": {
                "type": "array",
                "maxItems": 16,
                "items": {"type": "object"}
            },
            "resourceDeclarations": {
                "type": "array",
                "maxItems": 16,
                "items": {"type": "object"}
            },
            "authorityNeeds": {
                "type": "array",
                "maxItems": 16,
                "items": {"type": "object"}
            },
            "settingsDeclarations": {
                "type": "array",
                "maxItems": 16,
                "items": {"type": "object"}
            },
            "dependencyIntents": {
                "type": "array",
                "maxItems": 16,
                "items": {"type": "object"}
            },
            "validation": {
                "type": "object",
                "required": ["status", "checks", "evidenceRefs"],
                "additionalProperties": false,
                "properties": {
                    "status": {"type": "string"},
                    "checks": {"type": "array", "maxItems": 16},
                    "evidenceRefs": {"type": "array", "maxItems": 16}
                }
            },
            "provenance": {
                "type": "object",
                "required": ["source", "sourceRefs"],
                "additionalProperties": false,
                "properties": {
                    "source": {"type": "string"},
                    "sourceRefs": {"type": "array", "maxItems": 16}
                }
            },
            "lifecycle": {
                "type": "object",
                "required": [
                    "state",
                    "activation",
                    "installable",
                    "executable",
                    "networkPolicy"
                ],
                "additionalProperties": false,
                "properties": {
                    "state": {"type": "string"},
                    "activation": {"type": "string"},
                    "installable": {"type": "boolean"},
                    "executable": {"type": "boolean"},
                    "networkPolicy": {"type": "string"}
                }
            },
            "redactionProof": {
                "type": "object",
                "required": [
                    "localPaths",
                    "environmentValues",
                    "commands",
                    "sensitiveValues",
                    "grantIdentifiers",
                    "authorityIdentifiers",
                    "tokenLikeMaterial",
                    "personalInfoLiterals"
                ],
                "additionalProperties": false,
                "properties": {
                    "localPaths": {"type": "string"},
                    "environmentValues": {"type": "string"},
                    "commands": {"type": "string"},
                    "sensitiveValues": {"type": "string"},
                    "grantIdentifiers": {"type": "string"},
                    "authorityIdentifiers": {"type": "string"},
                    "tokenLikeMaterial": {"type": "string"},
                    "personalInfoLiterals": {"type": "string"}
                }
            }
        }
    })
}
