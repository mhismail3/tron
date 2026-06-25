use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use crate::engine::{CreateResource, Invocation, ListResources, UpdateResource};
use crate::shared::server::errors::CapabilityError;

use super::contract::SCHEMA_VERSION;
use super::projection::{device_summary, inspected_device};
use super::support::*;
use super::validation::*;
use super::{DEVICE_REGISTRATION_KIND, DEVICE_REGISTRATION_SCHEMA_ID, Deps};

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
    let apns_token = validate_apns_token(&required_string(payload, "apnsToken")?)?;
    let token_hash = sha256_hex(apns_token.as_bytes());
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
    let resource_id = device_resource_id(&scope, &platform, &environment, &device_id);

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
        if current
            .get("idempotency")
            .and_then(|value| value.get("key"))
            .and_then(Value::as_str)
            == Some(idempotency_key.as_str())
        {
            return Ok(json!({
                "schemaVersion": SCHEMA_VERSION,
                "operation": "device_register",
                "status": existing.resource.lifecycle,
                "idempotentReplay": true,
                "deviceRegistrationResourceId": resource_id,
                "deviceRegistrationVersionId": current_version.version_id,
                "apnsEnvironment": environment,
                "apnsTokenRedacted": true,
                "tokenStorage": "hash_only",
                "liveApnsEnabled": false,
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
            token_hash: &token_hash,
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
                "liveApnsEnabled": false
            }),
        )
        .await?;
        return Ok(json!({
            "schemaVersion": SCHEMA_VERSION,
            "operation": "device_register",
            "status": "active",
            "idempotentReplay": false,
            "deviceRegistrationResourceId": resource_id,
            "deviceRegistrationVersionId": version.version_id,
            "apnsEnvironment": environment,
            "apnsTokenRedacted": true,
            "tokenStorage": "hash_only",
            "liveApnsEnabled": false,
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
        token_hash: &token_hash,
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
            "liveApnsEnabled": false
        }),
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
        "tokenStorage": "hash_only",
        "liveApnsEnabled": false,
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

pub(crate) async fn list_devices_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let grant = inspect_read_grant(deps, invocation, "device_list").await?;
    require_kind_selector(&grant, "device_list")?;
    let scope = resource_scope(invocation)?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(LIST_LIMIT_DEFAULT)
        .clamp(1, LIST_LIMIT_MAX);
    let include_unregistered = optional_bool(payload, "includeUnregistered")?.unwrap_or(false);
    let state = optional_string(payload, "state")?;
    if let Some(state) = state.as_deref()
        && !matches!(state, "active" | "unregistered")
    {
        return Err(invalid("state must be active or unregistered"));
    }
    let lifecycle = match (include_unregistered, state) {
        (_, Some(state)) => Some(state),
        (false, None) => Some("active".to_owned()),
        (true, None) => None,
    };
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(DEVICE_REGISTRATION_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle,
            limit: limit.saturating_add(1),
        })
        .await
        .map_err(engine_error)?;
    let truncated = resources.len() > limit;
    let mut devices = Vec::new();
    for resource in resources.into_iter().take(limit) {
        let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        ensure_device_registration(&inspection, "device_list")?;
        ensure_scope(&inspection, &scope, "device_list")?;
        let (version, payload) = current_payload(&inspection, "device_list")?;
        devices.push(device_summary(&inspection.resource, version, payload));
    }
    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "device_list",
        "scope": scope_ref(&scope),
        "devices": devices,
        "limits": {
            "requestedLimit": limit,
            "returned": devices.len(),
            "truncated": truncated,
            "includeUnregistered": include_unregistered
        },
        "apnsTokenReturned": false
    }))
}

pub(crate) async fn inspect_device_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let grant = inspect_read_grant(deps, invocation, "device_inspect").await?;
    require_kind_selector(&grant, "device_inspect")?;
    let resource_id = required_string(payload, "deviceRegistrationResourceId")?;
    validate_device_resource_id(&resource_id)?;
    let scope = resource_scope(invocation)?;
    let inspection = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid(format!("missing device registration {resource_id}")))?;
    ensure_device_registration(&inspection, "device_inspect")?;
    ensure_scope(&inspection, &scope, "device_inspect")?;
    let (version, payload) = current_payload(&inspection, "device_inspect")?;
    Ok(json!({
        "schemaVersion": SCHEMA_VERSION,
        "operation": "device_inspect",
        "scope": scope_ref(&scope),
        "device": inspected_device(&inspection.resource, version, payload),
        "apnsTokenReturned": false
    }))
}
