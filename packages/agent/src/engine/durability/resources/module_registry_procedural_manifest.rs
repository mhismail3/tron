//! Procedural skills/rules/hooks module-pack manifest seed.
//!
//! This keeps the Slice 24E procedural module-pack evidence separate from the
//! generic module-registry definition and does not introduce repo-managed
//! skills, prompt injection, trigger firing, or executable module code.

use serde_json::{Value, json};

use super::module_registry_definitions::{MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION, redaction_proof};

pub(super) fn procedural_module_manifest() -> Value {
    json!({
        "schemaVersion": MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION,
        "identity": {
            "moduleId": "procedural_module",
            "name": "Procedural Skills Rules And Hooks Module Pack",
            "kind": "module_pack",
            "owner": "domains::procedural",
            "summary": "Metadata-only procedural skill, rule, hook, and procedure authoring, review, activation decision, and rollback evidence",
            "version": "phase3-slice24e"
        },
        "capabilityDeclarations": [
            {"operation": "procedural_definition_record", "effect": "write", "providerVisible": true, "description": "Record metadata-only procedural definitions with validation, trigger, conflict, ordering, authority, replay, and idempotency evidence"},
            {"operation": "procedural_state_list", "effect": "read", "providerVisible": true, "description": "List bounded redacted procedural definition records"},
            {"operation": "procedural_state_inspect", "effect": "read", "providerVisible": true, "description": "Inspect one bounded redacted procedural definition record"},
            {"operation": "procedural_activation_request_record", "effect": "write", "providerVisible": true, "description": "Record pending-review activation, deactivation, or rollback requests without firing triggers or executing code"},
            {"operation": "procedural_activation_request_list", "effect": "read", "providerVisible": true, "description": "List pending-review procedural activation request evidence"},
            {"operation": "procedural_activation_request_inspect", "effect": "read", "providerVisible": true, "description": "Inspect one redacted procedural activation request"},
            {"operation": "procedural_activation_decision_record", "effect": "write", "providerVisible": true, "description": "Record approval, denial, deactivation, or rollback decisions and proof refs without performing activation"},
            {"operation": "procedural_activation_decision_list", "effect": "read", "providerVisible": true, "description": "List procedural activation decision evidence"},
            {"operation": "procedural_activation_decision_inspect", "effect": "read", "providerVisible": true, "description": "Inspect one redacted procedural activation decision"}
        ],
        "resourceDeclarations": [
            {"kind": "procedural_record", "schemaId": "tron.resource.procedural_record.v1", "payloadSchemaVersion": "tron.procedural_record.v1", "scope": "session_or_workspace"},
            {"kind": "procedural_activation_request", "schemaId": "tron.resource.procedural_activation_request.v1", "payloadSchemaVersion": "tron.procedural_activation_request.v1", "scope": "session_or_workspace"},
            {"kind": "procedural_activation_decision", "schemaId": "tron.resource.procedural_activation_decision.v1", "payloadSchemaVersion": "tron.procedural_activation_decision.v1", "scope": "session_or_workspace"}
        ],
        "authorityNeeds": [
            {"scope": "procedural.read", "purpose": "inspect provider-safe procedural metadata and activation evidence"},
            {"scope": "procedural.write", "purpose": "record metadata-only procedural definitions, review requests, and decisions"},
            {"scope": "resource.read", "purpose": "inspect exact procedural resource versions"},
            {"scope": "resource.write", "purpose": "append procedural metadata resources under exact selectors"}
        ],
        "settingsDeclarations": [],
        "dependencyIntents": [],
        "validation": {
            "status": "pending_review",
            "checks": [
                {
                    "id": "metadata_only_definitions",
                    "status": "implementation-candidate",
                    "summary": "Definitions store bounded metadata, refs, hashes, trigger declarations, conflict ordering, and provider-safe projections only"
                },
                {
                    "id": "review_before_activation",
                    "status": "implementation-candidate",
                    "summary": "Activation, deactivation, and rollback are represented as request and decision records without automatic behavior changes"
                },
                {
                    "id": "authority_and_network_bounds",
                    "status": "implementation-candidate",
                    "summary": "Operations require exact procedural/resource scopes, exact selectors, networkPolicy none, and no wildcard grants"
                },
                {
                    "id": "provider_redaction",
                    "status": "passed",
                    "summary": "Provider projections omit raw procedure bodies, commands, file contents, paths, secrets, grants, authority ids, and debug payloads"
                }
            ],
            "evidenceRefs": [
                {
                    "kind": "phase3_inventory",
                    "ref": "P3MSA-INV-013"
                }
            ]
        },
        "provenance": {
            "source": "source_backed_first_party",
            "sourceRefs": [
                {
                    "kind": "crate_module",
                    "ref": "domains::procedural"
                },
                {
                    "kind": "crate_module",
                    "ref": "domains::capability"
                }
            ]
        },
        "lifecycle": {
            "state": "pending_review",
            "activation": "review_decision_metadata_only",
            "installable": false,
            "executable": false,
            "networkPolicy": "none"
        },
        "redactionProof": redaction_proof()
    })
}
