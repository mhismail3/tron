//! Notification and device delivery module-pack manifest seed.
//!
//! This keeps the Slice 24G notification delivery module-pack evidence beside
//! the existing server-owned device and notification resource substrate without
//! adding APNs transport, native inbox UI, entitlements, credential mutation, or
//! executable module code.

use serde_json::{Value, json};

use super::module_registry_definitions::{MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION, redaction_proof};

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
            {"kind": "device_registration", "schemaId": "tron.resource.device_registration.v1", "payloadSchemaVersion": "tron.device.registration.v1", "scope": "session_or_workspace"},
            {"kind": "notification", "schemaId": "tron.resource.notification.v1", "payloadSchemaVersion": "tron.notification.v1", "scope": "session_or_workspace"},
            {"kind": "notification_delivery", "schemaId": "tron.resource.notification_delivery.v1", "payloadSchemaVersion": "tron.notification.delivery.v1", "scope": "session_or_workspace"}
        ],
        "authorityNeeds": [
            {"scope": "device.read", "purpose": "inspect redacted device registration projections", "resourceKinds": ["device_registration"], "selectors": ["kind:device_registration"]},
            {"scope": "device.write", "purpose": "trusted system/admin device register and unregister authority", "resourceKinds": ["device_registration"], "selectors": ["kind:device_registration", "resource:<device_registration_id>"]},
            {"scope": "notifications.read", "purpose": "inspect notification inbox and delivery evidence projections", "resourceKinds": ["notification", "notification_delivery"], "selectors": ["kind:notification", "kind:notification_delivery"]},
            {"scope": "notifications.write", "purpose": "record notification read state, badge, inbox, and delivery evidence", "resourceKinds": ["notification", "notification_delivery"], "selectors": ["kind:notification", "kind:notification_delivery", "resource:<notification_id>"]},
            {"scope": "resource.read", "purpose": "inspect exact device registration, notification, and notification delivery resource versions", "resourceKinds": ["device_registration", "notification", "notification_delivery"]},
            {"scope": "resource.write", "purpose": "append server-owned device, notification, and delivery evidence under exact selectors", "resourceKinds": ["device_registration", "notification", "notification_delivery"]}
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
