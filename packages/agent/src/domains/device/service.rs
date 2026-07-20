use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use crate::engine::{CreateResource, UpdateResource};
use crate::engine::{Invocation, ListResources};
use crate::shared::server::errors::CapabilityError;

use super::DEVICE_REGISTRATION_SCHEMA_ID;
use super::contract::SCHEMA_VERSION;
use super::support::*;
use super::validation::*;
use super::{DEVICE_REGISTRATION_KIND, Deps};

pub(crate) async fn register_device_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    ensure_internal_write_authority(deps, invocation, "device_register").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let scope = resource_scope(invocation)?;
    let device_id = bounded_token(
        "deviceId",
        &required_string(payload, "deviceId")?,
        DEVICE_ID_MAX_BYTES,
    )?;
    let platform = parse_platform(optional_string(payload, "platform")?)?;
    let environment = parse_apns_environment(&required_string(payload, "apnsEnvironment")?)?;
    let bundle_id = bounded_token(
        "bundleId",
        &required_string(payload, "bundleId")?,
        BUNDLE_ID_MAX_BYTES,
    )?;
    let apns_token = validate_apns_token(&required_string(payload, "apnsToken")?)?;
    let token_hash = sha256_hex(apns_token.as_bytes());
    let transport_enabled = deps.apns_runtime.transport_enabled();
    let label = optional_string(payload, "label")?
        .map(|value| bounded_text("label", &value, LABEL_MAX_BYTES))
        .transpose()?;
    let push_opt_in = optional_bool(payload, "pushOptIn")?.unwrap_or(false);
    let push_enabled = optional_bool(payload, "pushEnabled")?.unwrap_or(false);
    if push_enabled && !push_opt_in {
        return Err(invalid(
            "pushEnabled requires explicit pushOptIn true for device registration",
        ));
    }
    let event_families = event_families(payload)?;
    let retention = retention_policy(payload)?;
    let now = operation_at.to_rfc3339();
    let resource_id = device_resource_id(&scope, &platform, &environment, &bundle_id, &device_id);

    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_device_registration(&existing, "device_register replay/update")?;
        ensure_scope(&existing, &scope, "device_register replay/update")?;
        let (current_version, current) =
            current_payload(&existing, "device_register replay/update")?;
        let previous_token_hash = current
            .get("apns")
            .and_then(|apns| apns.get("tokenHash"))
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
        if current
            .get("idempotency")
            .and_then(|value| value.get("key"))
            .and_then(Value::as_str)
            == Some(idempotency_key.as_str())
        {
            store_private_token(
                deps,
                &token_hash,
                &apns_token,
                &environment,
                &bundle_id,
                &now,
            )?;
            supersede_duplicate_token_registrations(
                deps,
                invocation,
                &resource_id,
                &token_hash,
                &environment,
                &bundle_id,
                &now,
            )
            .await?;
            return Ok(json!({
                "schemaVersion": SCHEMA_VERSION,
                "operation": "device_register",
                "status": existing.resource.lifecycle,
                "idempotentReplay": true,
                "deviceRegistrationResourceId": resource_id,
                "deviceRegistrationVersionId": current_version.version_id,
                "apnsEnvironment": environment,
                "apnsTokenRedacted": true,
                "tokenStorage": "private_transport_store",
                "liveApnsEnabled": transport_enabled,
                "resourceRefs": [version_ref(&existing.resource, current_version, "device_registration")]
            }));
        }

        let record = registration_record(RegistrationRecordInput {
            state: "active",
            device_id: &device_id,
            platform: &platform,
            label: label.as_deref(),
            scope: &scope,
            environment: &environment,
            bundle_id: &bundle_id,
            token_hash: &token_hash,
            transport_enabled,
            push_opt_in,
            push_enabled,
            event_families,
            retention,
            created_at: current
                .get("createdAt")
                .and_then(Value::as_str)
                .unwrap_or(now.as_str()),
            updated_at: &now,
            invocation,
            idempotency_key: &idempotency_key,
            revision: current
                .get("revision")
                .and_then(Value::as_u64)
                .unwrap_or(1)
                .saturating_add(1),
        });
        assert_no_raw_token(&record, &apns_token)?;
        let version = deps
            .engine_host
            .update_resource(UpdateResource {
                resource_id: resource_id.clone(),
                expected_current_version_id: Some(current_version.version_id.clone()),
                lifecycle: Some("active".to_owned()),
                payload: record,
                state: None,
                locations: Vec::new(),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })
            .await
            .map_err(engine_error)?;
        publish_lifecycle_event(
            deps,
            invocation,
            "device.registered",
            &existing.resource,
            json!({
                "state": "active",
                "apnsEnvironment": environment,
                "apnsTokenRedacted": true,
                "liveApnsEnabled": transport_enabled
            }),
        )
        .await?;
        store_private_token(
            deps,
            &token_hash,
            &apns_token,
            &environment,
            &bundle_id,
            &now,
        )?;
        supersede_duplicate_token_registrations(
            deps,
            invocation,
            &resource_id,
            &token_hash,
            &environment,
            &bundle_id,
            &now,
        )
        .await?;
        remove_rotated_token(deps, previous_token_hash.as_deref(), &token_hash)?;
        return Ok(json!({
            "schemaVersion": SCHEMA_VERSION,
            "operation": "device_register",
            "status": "active",
            "idempotentReplay": false,
            "deviceRegistrationResourceId": resource_id,
            "deviceRegistrationVersionId": version.version_id,
            "apnsEnvironment": environment,
            "apnsTokenRedacted": true,
            "tokenStorage": "private_transport_store",
            "liveApnsEnabled": transport_enabled,
            "resourceRefs": [version_ref(&existing.resource, &version, "device_registration")]
        }));
    }

    let record = registration_record(RegistrationRecordInput {
        state: "active",
        device_id: &device_id,
        platform: &platform,
        label: label.as_deref(),
        scope: &scope,
        environment: &environment,
        bundle_id: &bundle_id,
        token_hash: &token_hash,
        transport_enabled,
        push_opt_in,
        push_enabled,
        event_families,
        retention,
        created_at: &now,
        updated_at: &now,
        invocation,
        idempotency_key: &idempotency_key,
        revision: 1,
    });
    assert_no_raw_token(&record, &apns_token)?;
    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.clone()),
            kind: DEVICE_REGISTRATION_KIND.to_owned(),
            schema_id: Some(DEVICE_REGISTRATION_SCHEMA_ID.to_owned()),
            scope,
            owner_worker_id: worker_id()?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("active".to_owned()),
            policy: resource_policy(),
            initial_payload: Some(record),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    publish_lifecycle_event(
        deps,
        invocation,
        "device.registered",
        &resource,
        json!({
            "state": "active",
            "apnsEnvironment": environment,
            "apnsTokenRedacted": true,
            "liveApnsEnabled": transport_enabled
        }),
    )
    .await?;
    store_private_token(
        deps,
        &token_hash,
        &apns_token,
        &environment,
        &bundle_id,
        &now,
    )?;
    supersede_duplicate_token_registrations(
        deps,
        invocation,
        &resource_id,
        &token_hash,
        &environment,
        &bundle_id,
        &now,
    )
    .await?;
    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "device_register",
        "status": "active",
        "idempotentReplay": false,
        "deviceRegistrationResourceId": resource.resource_id,
        "deviceRegistrationVersionId": resource.current_version_id,
        "apnsEnvironment": environment,
        "apnsTokenRedacted": true,
        "tokenStorage": "private_transport_store",
        "liveApnsEnabled": transport_enabled,
        "resourceRefs": [resource_ref(&resource, "device_registration")]
    }))
}

pub(crate) async fn unregister_device_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    ensure_internal_write_authority(deps, invocation, "device_unregister").await?;
    let idempotency_key = idempotency_key(invocation, payload)?;
    let resource_id = required_string(payload, "deviceRegistrationResourceId")?;
    validate_device_resource_id(&resource_id)?;
    let reason = bounded_text(
        "reason",
        &required_string(payload, "reason")?,
        REASON_MAX_BYTES,
    )?;
    let scope = resource_scope(invocation)?;
    let mut inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing device registration {resource_id}")))?;
    ensure_device_registration(&inspection, "device_unregister")?;
    ensure_scope(&inspection, &scope, "device_unregister")?;
    let (current_version, current) = current_payload(&inspection, "device_unregister")?;
    let token_hash = current
        .get("apns")
        .and_then(|apns| apns.get("tokenHash"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    if optional_string(payload, "expectedDeviceRegistrationVersionId")?
        .is_some_and(|expected| expected != current_version.version_id)
    {
        return Err(invalid("device registration version is stale"));
    }
    if inspection.resource.lifecycle == "unregistered" {
        return Ok(json!({
            "schemaVersion": SCHEMA_VERSION,
            "operation": "device_unregister",
            "status": "already_unregistered",
            "idempotentReplay": true,
            "deviceRegistrationResourceId": resource_id,
            "deviceRegistrationVersionId": current_version.version_id,
            "apnsTokenRedacted": true,
            "resourceRefs": [version_ref(&inspection.resource, current_version, "device_registration")]
        }));
    }
    let now = operation_at.to_rfc3339();
    let mut record = current.clone();
    record["state"] = json!("unregistered");
    record["updatedAt"] = json!(now);
    record["unregistered"] = json!({
        "at": record["updatedAt"],
        "actorId": invocation.causal_context.actor_id.as_str(),
        "reason": reason,
        "idempotency": {
            "key": idempotency_key,
            "invocationId": invocation.id.as_str()
        }
    });
    record["revision"] = json!(record["revision"].as_u64().unwrap_or(1).saturating_add(1));
    let version = deps
        .engine_host
        .update_resource(UpdateResource {
            resource_id: resource_id.clone(),
            expected_current_version_id: Some(current_version.version_id.clone()),
            lifecycle: Some("unregistered".to_owned()),
            payload: record,
            state: None,
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    inspection.resource.lifecycle = "unregistered".to_owned();
    inspection.resource.current_version_id = Some(version.version_id.clone());
    publish_lifecycle_event(
        deps,
        invocation,
        "device.unregistered",
        &inspection.resource,
        json!({"state": "unregistered", "apnsTokenRedacted": true}),
    )
    .await?;
    if let Some(token_hash) = token_hash {
        let _ = deps.apns_runtime.token_store.remove(&token_hash)?;
    }
    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "device_unregister",
        "status": "unregistered",
        "idempotentReplay": false,
        "deviceRegistrationResourceId": resource_id,
        "deviceRegistrationVersionId": version.version_id,
        "apnsTokenRedacted": true,
        "resourceRefs": [version_ref(&inspection.resource, &version, "device_registration")]
    }))
}

fn store_private_token(
    deps: &Deps,
    token_hash: &str,
    token: &str,
    environment: &str,
    bundle_id: &str,
    updated_at: &str,
) -> Result<(), CapabilityError> {
    let _ = deps
        .apns_runtime
        .token_store
        .upsert(crate::platform::apns::DeviceTokenRecord {
            token_hash: token_hash.to_owned(),
            token: token.to_owned(),
            environment: environment.to_owned(),
            bundle_id: bundle_id.to_owned(),
            updated_at: updated_at.to_owned(),
        })?;
    Ok(())
}

fn remove_rotated_token(
    deps: &Deps,
    previous_token_hash: Option<&str>,
    current_token_hash: &str,
) -> Result<(), CapabilityError> {
    if let Some(previous_token_hash) = previous_token_hash
        && previous_token_hash != current_token_hash
    {
        let _ = deps.apns_runtime.token_store.remove(previous_token_hash)?;
    }
    Ok(())
}

async fn supersede_duplicate_token_registrations(
    deps: &Deps,
    invocation: &Invocation,
    current_resource_id: &str,
    token_hash: &str,
    environment: &str,
    bundle_id: &str,
    updated_at: &str,
) -> Result<(), CapabilityError> {
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(DEVICE_REGISTRATION_KIND.to_owned()),
            scope: Some(crate::engine::EngineResourceScope::System),
            lifecycle: Some("active".to_owned()),
            limit: LIST_LIMIT_MAX,
        })
        .await
        .map_err(engine_error)?;

    for resource in resources {
        if resource.resource_id == current_resource_id {
            continue;
        }
        let Some(mut inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        ensure_device_registration(&inspection, "device_register supersession")?;
        let (version, payload) = current_payload(&inspection, "device_register supersession")?;
        let matches_route = payload.pointer("/apns/tokenHash").and_then(Value::as_str)
            == Some(token_hash)
            && payload.pointer("/apns/environment").and_then(Value::as_str) == Some(environment)
            && payload.pointer("/apns/bundleId").and_then(Value::as_str) == Some(bundle_id);
        if !matches_route {
            continue;
        }

        let mut superseded = payload.clone();
        superseded["state"] = json!("unregistered");
        superseded["updatedAt"] = json!(updated_at);
        superseded["unregistered"] = json!({
            "at": updated_at,
            "actorId": invocation.causal_context.actor_id.as_str(),
            "reason": "superseded_by_current_registration",
            "replacementResourceId": current_resource_id,
            "idempotency": {
                "key": invocation.causal_context.idempotency_key,
                "invocationId": invocation.id.as_str()
            }
        });
        superseded["revision"] = json!(
            superseded["revision"]
                .as_u64()
                .unwrap_or(1)
                .saturating_add(1)
        );
        let replacement_version = deps
            .engine_host
            .update_resource(UpdateResource {
                resource_id: resource.resource_id.clone(),
                expected_current_version_id: Some(version.version_id.clone()),
                lifecycle: Some("unregistered".to_owned()),
                payload: superseded,
                state: None,
                locations: Vec::new(),
                trace_id: invocation.causal_context.trace_id.clone(),
                invocation_id: Some(invocation.id.clone()),
            })
            .await
            .map_err(engine_error)?;
        inspection.resource.lifecycle = "unregistered".to_owned();
        inspection.resource.current_version_id = Some(replacement_version.version_id);
        publish_lifecycle_event(
            deps,
            invocation,
            "device.unregistered",
            &inspection.resource,
            json!({
                "state": "unregistered",
                "reason": "superseded_by_current_registration",
                "replacementResourceId": current_resource_id,
                "apnsTokenRedacted": true
            }),
        )
        .await?;
    }
    Ok(())
}
