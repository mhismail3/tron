//! Notification and device delivery module-pack manifest seed.
//!
//! This keeps the Slice 24G notification delivery module-pack evidence beside
//! the existing server-owned device and notification resource substrate without
//! adding APNs transport, native inbox UI, entitlements, credential mutation, or
//! executable module code.

use serde_json::{Value, json};

use super::module_registry_definitions::{MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION, redaction_proof};
use super::types::{
    DEVICE_REGISTRATION_KIND, DEVICE_REGISTRATION_SCHEMA_ID, NOTIFICATION_DELIVERY_KIND,
    NOTIFICATION_DELIVERY_SCHEMA_ID, NOTIFICATION_KIND, NOTIFICATION_SCHEMA_ID,
};
use crate::domains::{device::contract as device_contract, notifications::contract};

pub(super) fn notification_delivery_module_manifest() -> Value {
    json!({
        "schemaVersion": MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION,
        "identity": {
            "moduleId": "notification_delivery_module",
            "name": "Notifications And Device Delivery Module Pack",
            "kind": "module_pack",
            "owner": "domains::device+domains::notifications",
            "summary": "Metadata-only notification inbox, device registration, and delivery-evidence manifest for existing server-owned resources",
            "version": "phase3-slice24g"
        },
        "capabilityDeclarations": [
            {"operation": "device_list", "effect": "read", "providerVisible": true, "description": "List redacted server-owned device registration projections"},
            {"operation": "device_inspect", "effect": "read", "providerVisible": true, "description": "Inspect one redacted device registration projection"},
            {"operation": "device_register", "effect": "write", "providerVisible": false, "description": "Trusted system/admin registration with explicit APNs environment label and hash-only token custody"},
            {"operation": "device_unregister", "effect": "write", "providerVisible": false, "description": "Trusted system/admin unregister workflow with exact device registration selector"},
            {"operation": "notification_send", "effect": "write", "providerVisible": true, "description": "Record durable notification inbox and delivery evidence while live APNs transport remains disabled"},
            {"operation": "notification_list", "effect": "read", "providerVisible": true, "description": "List bounded notification inbox projections"},
            {"operation": "notification_inspect", "effect": "read", "providerVisible": true, "description": "Inspect one notification with redacted delivery summaries"},
            {"operation": "notification_mark_read", "effect": "write", "providerVisible": true, "description": "Mark one notification read with badge evidence and exact notification selector"},
            {"operation": "notification_mark_all_read", "effect": "write", "providerVisible": true, "description": "Mark current-scope notifications read with badge evidence"}
        ],
        "resourceDeclarations": [
            {"kind": DEVICE_REGISTRATION_KIND, "schemaId": DEVICE_REGISTRATION_SCHEMA_ID, "payloadSchemaVersion": device_contract::SCHEMA_VERSION, "scope": "session_or_workspace"},
            {"kind": NOTIFICATION_KIND, "schemaId": NOTIFICATION_SCHEMA_ID, "payloadSchemaVersion": contract::NOTIFICATION_SCHEMA_VERSION, "scope": "session_or_workspace"},
            {"kind": NOTIFICATION_DELIVERY_KIND, "schemaId": NOTIFICATION_DELIVERY_SCHEMA_ID, "payloadSchemaVersion": contract::DELIVERY_SCHEMA_VERSION, "scope": "session_or_workspace"}
        ],
        "authorityNeeds": [
            {"scope": contract::DEVICE_READ_SCOPE, "purpose": "inspect redacted device registration projections", "resourceKinds": [DEVICE_REGISTRATION_KIND], "selectors": [format!("kind:{DEVICE_REGISTRATION_KIND}")]},
            {"scope": device_contract::WRITE_SCOPE, "purpose": "trusted system/admin device register and unregister authority", "resourceKinds": [DEVICE_REGISTRATION_KIND], "selectors": [format!("kind:{DEVICE_REGISTRATION_KIND}"), "resource:<device_registration_id>"]},
            {"scope": contract::READ_SCOPE, "purpose": "inspect notification inbox and delivery evidence projections", "resourceKinds": [NOTIFICATION_KIND, NOTIFICATION_DELIVERY_KIND], "selectors": [format!("kind:{NOTIFICATION_KIND}"), format!("kind:{NOTIFICATION_DELIVERY_KIND}")]},
            {"scope": contract::WRITE_SCOPE, "purpose": "record notification read state, badge, inbox, and delivery evidence", "resourceKinds": [NOTIFICATION_KIND, NOTIFICATION_DELIVERY_KIND], "selectors": [format!("kind:{NOTIFICATION_KIND}"), format!("kind:{NOTIFICATION_DELIVERY_KIND}"), "resource:<notification_id>"]},
            {"scope": contract::RESOURCE_READ_SCOPE, "purpose": "inspect device registration, notification, and notification delivery resource versions under kind selectors", "resourceKinds": [DEVICE_REGISTRATION_KIND, NOTIFICATION_KIND, NOTIFICATION_DELIVERY_KIND], "selectors": [format!("kind:{DEVICE_REGISTRATION_KIND}"), format!("kind:{NOTIFICATION_KIND}"), format!("kind:{NOTIFICATION_DELIVERY_KIND}")]},
            {"scope": contract::RESOURCE_WRITE_SCOPE, "purpose": "append server-owned device, notification, and delivery evidence under kind selectors", "resourceKinds": [DEVICE_REGISTRATION_KIND, NOTIFICATION_KIND, NOTIFICATION_DELIVERY_KIND], "selectors": [format!("kind:{DEVICE_REGISTRATION_KIND}"), format!("kind:{NOTIFICATION_KIND}"), format!("kind:{NOTIFICATION_DELIVERY_KIND}")]}
        ],
        "settingsDeclarations": [],
        "dependencyIntents": [],
        "validation": {
            "status": "pending_review",
            "checks": [
                {
                    "id": "apns_custody_gate",
                    "status": "implementation-candidate",
                    "summary": "APNs credential custody and raw device-token handling remain pending gates; stored registration resources keep hash-only token custody"
                },
                {
                    "id": "environment_entitlement_device_gate",
                    "status": "implementation-candidate",
                    "summary": "APNs environment labels, entitlement proof, and physical-device validation evidence are required before live delivery acceptance"
                },
                {
                    "id": "delivery_failure_evidence",
                    "status": "implementation-candidate",
                    "summary": "Delivery records keep inbox-only, skipped, disabled, and failure evidence while live APNs transport remains deferred"
                },
                {
                    "id": "native_inbox_decision",
                    "status": "implementation-candidate",
                    "summary": "Native inbox and deep-link behavior remain pending product decisions backed by server notification resources"
                },
                {
                    "id": "provider_redaction",
                    "status": "implementation-candidate",
                    "summary": "Provider projections omit raw APNs tokens, raw device tokens, credentials, device secrets, raw provider payloads, full token hashes, grant ids, authority ids, and local material"
                }
            ],
            "evidenceRefs": [
                {
                    "kind": "phase3_inventory",
                    "ref": "P3MSA-INV-015"
                }
            ]
        },
        "provenance": {
            "source": "source_backed_first_party",
            "sourceRefs": [
                {
                    "kind": "crate_module",
                    "ref": "domains::device"
                },
                {
                    "kind": "crate_module",
                    "ref": "domains::notifications"
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
