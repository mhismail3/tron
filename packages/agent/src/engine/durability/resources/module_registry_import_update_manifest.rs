//! Import, repository tree, and update module-pack manifest seed.
//!
//! This keeps Slice 24H as a metadata-only module-pack declaration over the
//! existing import-history, repository-tree, import-preview, and
//! update-diagnostics resource foundations. It does not add import execution,
//! repository mutation, installer/restart/update behavior, deployment,
//! package-manager access, network access, native panels, or executable module
//! code.

use serde_json::{Value, json};

use super::module_registry_definitions::{MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION, redaction_proof};
use super::types::{
    IMPORT_HISTORY_RECORD_KIND, IMPORT_HISTORY_RECORD_SCHEMA_ID, IMPORT_PREVIEW_KIND,
    IMPORT_PREVIEW_SCHEMA_ID, REPOSITORY_TREE_SNAPSHOT_KIND, REPOSITORY_TREE_SNAPSHOT_SCHEMA_ID,
    UPDATE_DIAGNOSTIC_RECORD_KIND, UPDATE_DIAGNOSTIC_RECORD_SCHEMA_ID,
};
use crate::domains::{
    import_history::contract as import_history_contract,
    import_preview::contract as import_preview_contract,
    repository_tree::contract as repository_tree_contract,
    update_diagnostics::contract as update_diagnostics_contract,
};

pub(super) fn import_update_module_manifest() -> Value {
    json!({
        "schemaVersion": MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION,
        "identity": {
            "moduleId": "import_update_module",
            "name": "Import Repository And Update Module Pack",
            "kind": "module_pack",
            "owner": "domains::import_history+domains::repository_tree+domains::import_preview+domains::update_diagnostics",
            "summary": "Metadata-only manifest for existing import lineage, repository tree, import preview, and update diagnostic resources",
            "version": "phase3-slice24h"
        },
        "capabilityDeclarations": [
            {"operation": "import_history_record", "effect": "write", "providerVisible": true, "description": "Record bounded import/session-resource lineage metadata without raw import payloads"},
            {"operation": "import_history_list", "effect": "read", "providerVisible": true, "description": "List bounded provider-safe import/session-resource lineage summaries"},
            {"operation": "import_history_inspect", "effect": "read", "providerVisible": true, "description": "Inspect one redacted import/session-resource lineage record"},
            {"operation": "repository_tree_snapshot", "effect": "write", "providerVisible": true, "description": "Record content-free repository tree snapshot metadata without file contents or git mutation"},
            {"operation": "repository_tree_list", "effect": "read", "providerVisible": true, "description": "List bounded repository tree snapshot metadata projections"},
            {"operation": "repository_tree_inspect", "effect": "read", "providerVisible": true, "description": "Inspect one content-free repository tree snapshot projection"},
            {"operation": "import_preview_record", "effect": "write", "providerVisible": true, "description": "Record content-free import preview metadata linked to import-history and repository-tree refs"},
            {"operation": "import_preview_list", "effect": "read", "providerVisible": true, "description": "List bounded provider-safe import preview metadata projections"},
            {"operation": "import_preview_inspect", "effect": "read", "providerVisible": true, "description": "Inspect one content-free import preview projection"},
            {"operation": "update_diagnostic_record", "effect": "write", "providerVisible": true, "description": "Record signed-release/update-check diagnostic metadata without updater material"},
            {"operation": "update_diagnostic_list", "effect": "read", "providerVisible": true, "description": "List bounded provider-safe update diagnostic metadata projections"},
            {"operation": "update_diagnostic_inspect", "effect": "read", "providerVisible": true, "description": "Inspect one redacted update diagnostic metadata record"}
        ],
        "resourceDeclarations": [
            {"kind": IMPORT_HISTORY_RECORD_KIND, "schemaId": IMPORT_HISTORY_RECORD_SCHEMA_ID, "payloadSchemaVersion": import_history_contract::IMPORT_HISTORY_SCHEMA_VERSION, "scope": "session_or_workspace"},
            {"kind": REPOSITORY_TREE_SNAPSHOT_KIND, "schemaId": REPOSITORY_TREE_SNAPSHOT_SCHEMA_ID, "payloadSchemaVersion": repository_tree_contract::REPOSITORY_TREE_SCHEMA_VERSION, "scope": "session_or_workspace"},
            {"kind": IMPORT_PREVIEW_KIND, "schemaId": IMPORT_PREVIEW_SCHEMA_ID, "payloadSchemaVersion": import_preview_contract::IMPORT_PREVIEW_SCHEMA_VERSION, "scope": "session_or_workspace"},
            {"kind": UPDATE_DIAGNOSTIC_RECORD_KIND, "schemaId": UPDATE_DIAGNOSTIC_RECORD_SCHEMA_ID, "payloadSchemaVersion": update_diagnostics_contract::UPDATE_DIAGNOSTICS_SCHEMA_VERSION, "scope": "session_or_workspace"}
        ],
        "authorityNeeds": [
            {"scope": import_history_contract::READ_SCOPE, "purpose": "inspect bounded import-history lineage metadata", "resourceKinds": [IMPORT_HISTORY_RECORD_KIND], "selectors": [format!("kind:{IMPORT_HISTORY_RECORD_KIND}")]},
            {"scope": import_history_contract::WRITE_SCOPE, "purpose": "record bounded import-history lineage metadata", "resourceKinds": [IMPORT_HISTORY_RECORD_KIND], "selectors": [format!("kind:{IMPORT_HISTORY_RECORD_KIND}")]},
            {"scope": repository_tree_contract::READ_SCOPE, "purpose": "inspect content-free repository tree snapshot metadata", "resourceKinds": [REPOSITORY_TREE_SNAPSHOT_KIND], "selectors": [format!("kind:{REPOSITORY_TREE_SNAPSHOT_KIND}")]},
            {"scope": repository_tree_contract::WRITE_SCOPE, "purpose": "record content-free repository tree snapshot metadata", "resourceKinds": [REPOSITORY_TREE_SNAPSHOT_KIND], "selectors": [format!("kind:{REPOSITORY_TREE_SNAPSHOT_KIND}")]},
            {"scope": import_preview_contract::READ_SCOPE, "purpose": "inspect content-free import preview metadata", "resourceKinds": [IMPORT_PREVIEW_KIND], "selectors": [format!("kind:{IMPORT_PREVIEW_KIND}")]},
            {"scope": import_preview_contract::WRITE_SCOPE, "purpose": "record content-free import preview metadata", "resourceKinds": [IMPORT_PREVIEW_KIND], "selectors": [format!("kind:{IMPORT_PREVIEW_KIND}")]},
            {"scope": update_diagnostics_contract::READ_SCOPE, "purpose": "inspect signed-release/update-check diagnostic metadata", "resourceKinds": [UPDATE_DIAGNOSTIC_RECORD_KIND], "selectors": [format!("kind:{UPDATE_DIAGNOSTIC_RECORD_KIND}")]},
            {"scope": update_diagnostics_contract::WRITE_SCOPE, "purpose": "record signed-release/update-check diagnostic metadata", "resourceKinds": [UPDATE_DIAGNOSTIC_RECORD_KIND], "selectors": [format!("kind:{UPDATE_DIAGNOSTIC_RECORD_KIND}")]},
            {"scope": "resource.read", "purpose": "inspect exact import, repository tree, preview, and update diagnostic resource refs under kind selectors", "resourceKinds": [IMPORT_HISTORY_RECORD_KIND, REPOSITORY_TREE_SNAPSHOT_KIND, IMPORT_PREVIEW_KIND, UPDATE_DIAGNOSTIC_RECORD_KIND], "selectors": [format!("kind:{IMPORT_HISTORY_RECORD_KIND}"), format!("kind:{REPOSITORY_TREE_SNAPSHOT_KIND}"), format!("kind:{IMPORT_PREVIEW_KIND}"), format!("kind:{UPDATE_DIAGNOSTIC_RECORD_KIND}")]},
            {"scope": "resource.write", "purpose": "append import, repository tree, preview, and update diagnostic metadata under kind selectors", "resourceKinds": [IMPORT_HISTORY_RECORD_KIND, REPOSITORY_TREE_SNAPSHOT_KIND, IMPORT_PREVIEW_KIND, UPDATE_DIAGNOSTIC_RECORD_KIND], "selectors": [format!("kind:{IMPORT_HISTORY_RECORD_KIND}"), format!("kind:{REPOSITORY_TREE_SNAPSHOT_KIND}"), format!("kind:{IMPORT_PREVIEW_KIND}"), format!("kind:{UPDATE_DIAGNOSTIC_RECORD_KIND}")]}
        ],
        "settingsDeclarations": [],
        "dependencyIntents": [],
        "validation": {
            "status": "pending_review",
            "checks": [
                {
                    "id": "approval_gate",
                    "status": "implementation-candidate",
                    "summary": "Import execution, repository mutation, update actions, and native UI require later approval-backed contracts before activation"
                },
                {
                    "id": "rollback_gate",
                    "status": "implementation-candidate",
                    "summary": "Rollback policy remains metadata-only here; no repository, installer, restart, update, or deployment rollback action is performed"
                },
                {
                    "id": "action_contract_gate",
                    "status": "implementation-candidate",
                    "summary": "Future import execution proposals, repository tree actions, and update diagnostic actions must add separate action contracts before behavior changes"
                },
                {
                    "id": "bounded_payload_custody",
                    "status": "passed",
                    "summary": "Declared resources store bounded refs, counts, lifecycle, trace/replay, idempotency, and diagnostic metadata only"
                },
                {
                    "id": "provider_redaction",
                    "status": "implementation-candidate",
                    "summary": "Provider projections omit raw import payloads, raw repository trees, raw file contents, unsafe paths, raw diagnostics payloads, endpoints, commands, packages, grants, authority ids, and token-like material"
                }
            ],
            "evidenceRefs": [
                {
                    "kind": "phase3_inventory",
                    "ref": "P3MSA-INV-016"
                }
            ]
        },
        "provenance": {
            "source": "source_backed_first_party",
            "sourceRefs": [
                {
                    "kind": "crate_module",
                    "ref": "domains::import_history"
                },
                {
                    "kind": "crate_module",
                    "ref": "domains::repository_tree"
                },
                {
                    "kind": "crate_module",
                    "ref": "domains::import_preview"
                },
                {
                    "kind": "crate_module",
                    "ref": "domains::update_diagnostics"
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
