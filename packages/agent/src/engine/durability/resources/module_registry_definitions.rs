//! Built-in module manifest resource definitions and first-party seeds.
//!
//! Module manifests are inspect-only registry records. The seed records here
//! prove the registry contract without converting existing domains into
//! executable modules or adding install/activation behavior.

use serde_json::{Value, json};

use super::types::{
    CreateResource, EngineResourceScope, EngineResourceVersioningMode, MODULE_MANIFEST_KIND,
    MODULE_MANIFEST_SCHEMA_ID, RegisterResourceType,
};
use crate::engine::kernel::ids::{ActorId, TraceId, WorkerId};

pub(crate) const MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION: &str = "tron.module_manifest.v1";

pub(super) fn module_registry_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![RegisterResourceType {
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
            "read": ["module_registry.read", "resource.read"]
        }),
        owner_worker_id: WorkerId::new("module_registry").expect("valid static worker id"),
    }]
}

pub(in crate::engine) fn builtin_module_manifest_resources() -> Vec<CreateResource> {
    [module_registry_manifest(), capability_manifest()]
        .into_iter()
        .map(seed_resource)
        .collect()
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
            "schemaVersion": {"type": "string", "const": MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION},
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

fn module_registry_manifest() -> Value {
    json!({
        "schemaVersion": MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION,
        "identity": {
            "moduleId": "module_registry",
            "name": "Module Registry",
            "kind": "first_party_domain",
            "owner": "domains::module_registry",
            "summary": "Inspect-only module identity and declaration registry",
            "version": "phase3-slice23a"
        },
        "capabilityDeclarations": [
            {
                "operation": "module_list",
                "effect": "read",
                "providerVisible": true,
                "description": "List bounded provider-safe module manifest summaries"
            },
            {
                "operation": "module_inspect",
                "effect": "read",
                "providerVisible": true,
                "description": "Inspect one provider-safe module manifest projection"
            }
        ],
        "resourceDeclarations": [
            {
                "kind": MODULE_MANIFEST_KIND,
                "schemaId": MODULE_MANIFEST_SCHEMA_ID,
                "payloadSchemaVersion": MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION,
                "scope": "system"
            }
        ],
        "authorityNeeds": [
            {
                "scope": "module_registry.read",
                "purpose": "read module manifest projections"
            },
            {
                "scope": "resource.read",
                "purpose": "inspect system module_manifest resources"
            }
        ],
        "settingsDeclarations": [],
        "dependencyIntents": [],
        "validation": {
            "status": "validated",
            "checks": [
                {
                    "id": "manifest_schema",
                    "status": "passed",
                    "summary": "Schema-bound inspect-only manifest payload"
                },
                {
                    "id": "no_side_effects",
                    "status": "passed",
                    "summary": "List and inspect do not install, activate, execute, or access networks"
                }
            ],
            "evidenceRefs": [
                {
                    "kind": "phase3_inventory",
                    "ref": "P3MSA-INV-001"
                }
            ]
        },
        "provenance": {
            "source": "source_backed_first_party",
            "sourceRefs": [
                {
                    "kind": "crate_module",
                    "ref": "domains::module_registry"
                }
            ]
        },
        "lifecycle": {
            "state": "validated",
            "activation": "inspect_only",
            "installable": false,
            "executable": false,
            "networkPolicy": "none"
        },
        "redactionProof": redaction_proof()
    })
}

fn capability_manifest() -> Value {
    json!({
        "schemaVersion": MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION,
        "identity": {
            "moduleId": "capability",
            "name": "Capability Execute Primitive",
            "kind": "first_party_domain",
            "owner": "domains::capability",
            "summary": "Single model-facing primitive execute surface",
            "version": "phase3-slice23a"
        },
        "capabilityDeclarations": [
            {
                "operation": "execute",
                "effect": "delegated_invocation",
                "providerVisible": true,
                "description": "Runs one authorized primitive operation through capability::execute"
            }
        ],
        "resourceDeclarations": [
            {
                "kind": "trace_record",
                "schemaId": "session_event_store",
                "payloadSchemaVersion": "session.trace",
                "scope": "session"
            }
        ],
        "authorityNeeds": [
            {
                "scope": "capability.execute",
                "purpose": "execute one delegated primitive operation"
            }
        ],
        "settingsDeclarations": [],
        "dependencyIntents": [],
        "validation": {
            "status": "validated",
            "checks": [
                {
                    "id": "single_model_surface",
                    "status": "passed",
                    "summary": "Providers see only the execute primitive"
                }
            ],
            "evidenceRefs": [
                {
                    "kind": "phase3_inventory",
                    "ref": "P3MSA-INV-001"
                }
            ]
        },
        "provenance": {
            "source": "source_backed_first_party",
            "sourceRefs": [
                {
                    "kind": "crate_module",
                    "ref": "domains::capability"
                }
            ]
        },
        "lifecycle": {
            "state": "validated",
            "activation": "core_primitive",
            "installable": false,
            "executable": true,
            "networkPolicy": "none"
        },
        "redactionProof": redaction_proof()
    })
}

fn redaction_proof() -> Value {
    json!({
        "localPaths": "absent",
        "environmentValues": "absent",
        "commands": "absent",
        "sensitiveValues": "absent",
        "grantIdentifiers": "absent",
        "authorityIdentifiers": "absent",
        "tokenLikeMaterial": "absent",
        "personalInfoLiterals": "absent"
    })
}

fn seed_resource(payload: Value) -> CreateResource {
    let module_id = payload["identity"]["moduleId"]
        .as_str()
        .expect("seed module id");
    CreateResource {
        resource_id: Some(format!("{MODULE_MANIFEST_KIND}:{module_id}")),
        kind: MODULE_MANIFEST_KIND.to_owned(),
        schema_id: Some(MODULE_MANIFEST_SCHEMA_ID.to_owned()),
        scope: EngineResourceScope::System,
        owner_worker_id: WorkerId::new("module_registry").expect("valid static worker id"),
        owner_actor_id: ActorId::new("system:module_registry").expect("valid static actor id"),
        lifecycle: Some("validated".to_owned()),
        policy: json!({
            "owner": "module_registry",
            "authority": "module_registry.read",
            "activation": "forbidden",
            "networkPolicy": "none"
        }),
        initial_payload: Some(payload),
        locations: Vec::new(),
        trace_id: TraceId::new("bootstrap").expect("valid static trace id"),
        invocation_id: None,
    }
}
