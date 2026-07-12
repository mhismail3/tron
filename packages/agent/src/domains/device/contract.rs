//! Trusted device-registration contracts and resource policy constants.

use serde_json::json;

use crate::domains::notifications::contract::EVENT_FAMILIES;
use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
};

pub(crate) const WORKER: &str = "device";
pub(crate) const DEVICE_LIFECYCLE_TOPIC: &str = "device.lifecycle";
pub(crate) const READ_SCOPE: &str = "device.read";
pub(crate) const WRITE_SCOPE: &str = "device.write";
pub(crate) const RESOURCE_READ_SCOPE: &str = "resource.read";
pub(crate) const RESOURCE_WRITE_SCOPE: &str = "resource.write";
pub(crate) const SCHEMA_VERSION: &str = "tron.device.registration.v1";

pub(crate) const STREAM_TOPICS: &[&str] = &[DEVICE_LIFECYCLE_TOPIC];

/// iOS invokes this transport-only function after APNs issues a token. It is
/// deliberately not exposed as a `capability::execute` operation.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            "device::register",
            WORKER,
            EffectClass::ExternalSideEffect,
            RiskLevel::Medium,
            Some(WRITE_SCOPE),
        )
        .request_schema(json!({
            "type": "object",
            "additionalProperties": false,
            "required": ["deviceId", "platform", "apnsEnvironment", "apnsToken", "bundleId"],
            "properties": {
                "deviceId": {"type": "string"},
                "platform": {"type": "string", "enum": ["ios"]},
                "apnsEnvironment": {"type": "string", "enum": ["development", "production"]},
                "apnsToken": {"type": "string"},
                "bundleId": {"type": "string"},
                "label": {"type": "string"},
                "pushOptIn": {"type": "boolean"},
                "pushEnabled": {"type": "boolean"},
                "eventFamilies": {
                    "type": "array",
                    "items": {"type": "string", "enum": EVENT_FAMILIES}
                },
                "maxAgeDays": {"type": "integer"},
                "maxInboxRecords": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }))
        .response_schema(json!({
            "type": "object",
            "additionalProperties": false,
            "required": [
                "schemaVersion", "operation", "status", "idempotentReplay",
                "deviceRegistrationResourceId", "deviceRegistrationVersionId",
                "apnsEnvironment", "apnsTokenRedacted", "tokenStorage",
                "liveApnsEnabled", "resourceRefs"
            ],
            "properties": {
                "schemaVersion": {"type": "string"},
                "operation": {"const": "device_register"},
                "status": {"type": "string"},
                "idempotentReplay": {"type": "boolean"},
                "deviceRegistrationResourceId": {"type": "string"},
                "deviceRegistrationVersionId": {"type": "string"},
                "apnsEnvironment": {"type": "string"},
                "apnsTokenRedacted": {"const": true},
                "tokenStorage": {"const": "private_transport_store"},
                "liveApnsEnabled": {"type": "boolean"},
                "resourceRefs": {"type": "array"}
            }
        }))
        .description("Register one iOS APNs token in private server custody")
        .tags(vec!["internal", "device", "apns", "registration"])
        .idempotency(IdempotencyContract::caller_system_engine_ledger())
        .resource_lease(ResourceLeaseRequirement::exclusive_template(
            "device",
            "device-registration:{deviceId}",
            60_000,
        ))
        .compensation(CompensationContract::new(
            CompensationKind::ManualOnly,
            "a later token registration supersedes the private token; terminal APNs rejection removes it",
        ))
        .stream_topics(STREAM_TOPICS.to_vec())
        .build()?,
        CapabilityContract::new(
            "device::unregister",
            WORKER,
            EffectClass::ExternalSideEffect,
            RiskLevel::Medium,
            Some(WRITE_SCOPE),
        )
        .request_schema(json!({
            "type": "object",
            "additionalProperties": false,
            "required": ["deviceRegistrationResourceId", "reason"],
            "properties": {
                "deviceRegistrationResourceId": {"type": "string"},
                "expectedDeviceRegistrationVersionId": {"type": "string"},
                "reason": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }))
        .response_schema(json!({
            "type": "object",
            "additionalProperties": false,
            "required": [
                "schemaVersion", "operation", "status", "idempotentReplay",
                "deviceRegistrationResourceId", "deviceRegistrationVersionId",
                "apnsTokenRedacted", "resourceRefs"
            ],
            "properties": {
                "schemaVersion": {"type": "string"},
                "operation": {"const": "device_unregister"},
                "status": {"type": "string"},
                "idempotentReplay": {"type": "boolean"},
                "deviceRegistrationResourceId": {"type": "string"},
                "deviceRegistrationVersionId": {"type": "string"},
                "apnsTokenRedacted": {"const": true},
                "resourceRefs": {"type": "array"}
            }
        }))
        .description("Unregister one privately held iOS APNs token")
        .tags(vec!["internal", "device", "apns", "registration"])
        .idempotency(IdempotencyContract::caller_system_engine_ledger())
        .resource_lease(ResourceLeaseRequirement::exclusive_template(
            "device",
            "device-registration:{deviceRegistrationResourceId}",
            60_000,
        ))
        .compensation(CompensationContract::new(
            CompensationKind::ManualOnly,
            "a later APNs registration creates a new active version",
        ))
        .stream_topics(STREAM_TOPICS.to_vec())
        .build()?,
    ])
}
