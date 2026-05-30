//! Source trust input and response schemas.

use super::*;

pub(in crate::engine::primitives::module) fn verify_source_schema() -> Value {
    json!({
        "type": "object",
        "required": ["packageResourceId", "packageVersionId"],
        "additionalProperties": false,
        "properties": {
            "packageResourceId": {"type": "string"},
            "packageVersionId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "mode": {"type": "string", "enum": ["on_demand", "scheduled", "registration"]}
        }
    })
}
pub(in crate::engine::primitives::module) fn approve_source_schema() -> Value {
    json!({
        "type": "object",
        "required": [
            "packageResourceId",
            "packageVersionId",
            "packageDigest",
            "packageId",
            "scope",
            "trustTierCeiling",
            "grantCeiling",
            "expiresAt",
            "reason"
        ],
        "additionalProperties": false,
        "properties": {
            "packageResourceId": {"type": "string"},
            "packageVersionId": {"type": "string"},
            "packageDigest": {"type": "string"},
            "packageId": {"type": "string"},
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "trustTierCeiling": {"type": "string"},
            "grantCeiling": {"type": "object"},
            "expiresAt": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}
pub(in crate::engine::primitives::module) fn revoke_source_approval_schema() -> Value {
    json!({
        "type": "object",
        "required": ["decisionResourceId", "reason"],
        "additionalProperties": false,
        "properties": {
            "decisionResourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}
pub(in crate::engine::primitives::module) fn policy_decide_schema() -> Value {
    json!({
        "type": "object",
        "required": ["packageResourceId", "packageVersionId", "scope"],
        "additionalProperties": false,
        "properties": {
            "packageResourceId": {"type": "string"},
            "packageVersionId": {"type": "string"},
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "childGrantRequest": {"type": "object"}
        }
    })
}
pub(in crate::engine::primitives::module) fn register_source_schema() -> Value {
    json!({
        "type": "object",
        "required": ["sourceKind", "scope", "reason"],
        "additionalProperties": false,
        "properties": {
            "sourceKind": {
                "type": "string",
                "enum": ["local_digest_source", "ed25519_trust_root", "source_revocation"]
            },
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "sourceDigest": {"type": "string"},
            "sourceRef": {"type": "object"},
            "publicKey": {"type": "string"},
            "publicKeyEncoding": {"type": "string", "enum": ["base64"]},
            "keyId": {"type": "string"},
            "algorithm": {"type": "string", "enum": ["ed25519"]},
            "allowedPackageSelectors": {"type": "array", "items": {"type": "string"}},
            "trustTierCeiling": {"type": "string"},
            "grantCeiling": {"type": "object"},
            "expiresAt": {"type": "string"},
            "revokedDecisionResourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}
pub(in crate::engine::primitives::module) fn verify_signature_schema() -> Value {
    json!({
        "type": "object",
        "required": ["packageResourceId", "packageVersionId", "scope"],
        "additionalProperties": false,
        "properties": {
            "packageResourceId": {"type": "string"},
            "packageVersionId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"}
        }
    })
}
pub(in crate::engine::primitives::module) fn audit_policy_schema() -> Value {
    json!({
        "type": "object",
        "required": ["packageResourceId", "packageVersionId", "scope"],
        "additionalProperties": false,
        "properties": {
            "packageResourceId": {"type": "string"},
            "packageVersionId": {"type": "string"},
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "childGrantRequest": {"type": "object"},
            "includeActivations": {"type": "boolean"}
        }
    })
}
pub(in crate::engine::primitives::module) fn reconcile_trust_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "packageResourceId": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}
pub(in crate::engine::primitives::module) fn inspect_trust_schema() -> Value {
    json!({
        "type": "object",
        "required": ["targetType", "targetResourceId"],
        "additionalProperties": false,
        "properties": {
            "targetType": {
                "type": "string",
                "enum": [
                    "trust_root",
                    "source_registration",
                    "source_approval",
                    "source_revocation",
                    "decision",
                    "package",
                    "activation"
                ]
            },
            "targetResourceId": {"type": "string"},
            "targetVersionId": {"type": "string"},
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "includeEvidence": {"type": "boolean"},
            "limit": {"type": "integer", "minimum": 1, "maximum": 200}
        }
    })
}
pub(in crate::engine::primitives::module) fn renew_trust_root_schema() -> Value {
    json!({
        "type": "object",
        "required": [
            "trustRootDecisionResourceId",
            "trustRootDecisionVersionId",
            "expectedCurrentVersionId",
            "expiresAt",
            "allowedPackageSelectors",
            "grantCeiling",
            "trustTierCeiling",
            "reason"
        ],
        "additionalProperties": false,
        "properties": {
            "trustRootDecisionResourceId": {"type": "string"},
            "trustRootDecisionVersionId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "expiresAt": {"type": "string"},
            "allowedPackageSelectors": {"type": "array", "items": {"type": "string"}},
            "grantCeiling": {"type": "object"},
            "trustTierCeiling": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}
pub(in crate::engine::primitives::module) fn rotate_signature_key_schema() -> Value {
    json!({
        "type": "object",
        "required": [
            "oldTrustRootDecisionResourceId",
            "oldTrustRootDecisionVersionId",
            "newTrustRootDecisionResourceId",
            "newTrustRootDecisionVersionId",
            "reason"
        ],
        "additionalProperties": false,
        "properties": {
            "oldTrustRootDecisionResourceId": {"type": "string"},
            "oldTrustRootDecisionVersionId": {"type": "string"},
            "newTrustRootDecisionResourceId": {"type": "string"},
            "newTrustRootDecisionVersionId": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}
pub(in crate::engine::primitives::module) fn expire_trust_decision_schema() -> Value {
    json!({
        "type": "object",
        "required": ["decisionResourceId", "decisionVersionId", "expectedCurrentVersionId", "reason"],
        "additionalProperties": false,
        "properties": {
            "decisionResourceId": {"type": "string"},
            "decisionVersionId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}
pub(in crate::engine::primitives::module) fn enforce_revocation_schema() -> Value {
    json!({
        "type": "object",
        "required": ["mode", "activationResourceIds", "reason"],
        "additionalProperties": false,
        "properties": {
            "trustDecisionResourceId": {"type": "string"},
            "revocationDecisionResourceId": {"type": "string"},
            "expectedDecisionVersionId": {"type": "string"},
            "mode": {"type": "string", "enum": ["disable", "quarantine"]},
            "activationResourceIds": {"type": "array", "items": {"type": "string"}},
            "reason": {"type": "string"}
        }
    })
}
pub(in crate::engine::primitives::module) fn policy_audit_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["audit"],
        "additionalProperties": true,
        "properties": {
            "audit": {"type": "object"}
        }
    })
}
