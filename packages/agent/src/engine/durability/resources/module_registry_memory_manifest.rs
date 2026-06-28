//! Memory module-pack manifest seed.
//!
//! This keeps the Slice 24D memory module-pack evidence out of the generic
//! module-registry resource definition owner.

use serde_json::{Value, json};

use super::module_registry_definitions::{MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION, redaction_proof};

pub(super) fn memory_engine_module_manifest() -> Value {
    json!({
        "schemaVersion": MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION,
        "identity": {
            "moduleId": "memory_engine_module",
            "name": "Memory Retrieval And Retention Module Pack",
            "kind": "module_pack",
            "owner": "domains::memory",
            "summary": "Deterministic resource-backed memory retrieval, retention evidence, and prompt inclusion proof",
            "version": "phase3-slice24d"
        },
        "capabilityDeclarations": [
            {"operation": "memory_status", "effect": "read", "providerVisible": true, "description": "Inspect memory mode, engine identity, prompt policy, and retrieval contract"},
            {"operation": "memory_list", "effect": "read", "providerVisible": true, "description": "List redacted current-session memory records with previews only"},
            {"operation": "memory_inspect", "effect": "read", "providerVisible": true, "description": "Inspect one redacted memory record and version history"},
            {"operation": "memory_query_list", "effect": "read", "providerVisible": true, "description": "List deterministic memory query and retrieval result evidence"},
            {"operation": "memory_query_inspect", "effect": "read", "providerVisible": true, "description": "Inspect one memory query/result evidence resource"},
            {"operation": "memory_decision_list", "effect": "read", "providerVisible": true, "description": "List memory prompt-inclusion and retention decision evidence"},
            {"operation": "memory_decision_inspect", "effect": "read", "providerVisible": true, "description": "Inspect one memory decision evidence resource"}
        ],
        "resourceDeclarations": [
            {"kind": "memory_engine", "schemaId": "tron.resource.memory_engine.v1", "payloadSchemaVersion": "tron.memory.v1", "scope": "system"},
            {"kind": "memory_policy", "schemaId": "tron.resource.memory_policy.v1", "payloadSchemaVersion": "tron.memory.v1", "scope": "session_or_workspace_or_system"},
            {"kind": "memory_record", "schemaId": "tron.resource.memory_record.v1", "payloadSchemaVersion": "tron.memory.v1", "scope": "session_or_workspace"},
            {"kind": "memory_query", "schemaId": "tron.resource.memory_query.v1", "payloadSchemaVersion": "tron.memory.v1", "scope": "session_or_workspace"},
            {"kind": "memory_decision", "schemaId": "tron.resource.memory_decision.v1", "payloadSchemaVersion": "tron.memory.v1", "scope": "session_or_workspace"},
            {"kind": "memory_prompt_trace", "schemaId": "tron.resource.memory_prompt_trace.v1", "payloadSchemaVersion": "tron.memory.v1", "scope": "session_or_workspace"}
        ],
        "authorityNeeds": [
            {"scope": "memory.read", "purpose": "inspect redacted memory policy, record, query, and decision projections"},
            {"scope": "memory.write", "purpose": "record retention, retrieval, prompt trace, and decision evidence through memory-owned functions"},
            {"scope": "resource.read", "purpose": "inspect exact memory resources and versions"},
            {"scope": "resource.write", "purpose": "record memory query, decision, prompt trace, and record lifecycle evidence"}
        ],
        "settingsDeclarations": [],
        "dependencyIntents": [],
        "validation": {
            "status": "pending_review",
            "checks": [
                {
                    "id": "deterministic_retrieval",
                    "status": "implementation-candidate",
                    "summary": "Retrieval uses existing memory_record refs and previews only, with deterministic ranking and no embeddings"
                },
                {
                    "id": "prompt_inclusion_proof",
                    "status": "implementation-candidate",
                    "summary": "Prompt inclusion requires explicit bounded_snippets policy and records query, decision, and prompt trace evidence"
                },
                {
                    "id": "retention_audit",
                    "status": "implementation-candidate",
                    "summary": "Retain, edit, import, and tombstone record policy evidence while hard delete and automatic retention fail closed"
                },
                {
                    "id": "provider_redaction",
                    "status": "passed",
                    "summary": "Provider projections expose bounded refs and previews without raw bodies, generated summaries, paths, secrets, grants, or authority ids"
                }
            ],
            "evidenceRefs": [
                {
                    "kind": "phase3_inventory",
                    "ref": "P3MSA-INV-012"
                }
            ]
        },
        "provenance": {
            "source": "source_backed_first_party",
            "sourceRefs": [
                {
                    "kind": "crate_module",
                    "ref": "domains::memory"
                },
                {
                    "kind": "crate_module",
                    "ref": "domains::capability"
                }
            ]
        },
        "lifecycle": {
            "state": "pending_review",
            "activation": "authority_mapped_module_pack",
            "installable": false,
            "executable": false,
            "networkPolicy": "none"
        },
        "redactionProof": redaction_proof()
    })
}
