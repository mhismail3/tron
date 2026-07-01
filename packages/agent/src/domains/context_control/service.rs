use std::sync::Arc;
use std::sync::atomic::AtomicI64;

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::registration::bindings::operation_bindings;
use crate::domains::session::event_store::{AppendOptions, EventType};
use crate::engine::{
    CreateResource, EngineResource, EngineResourceLocation, EngineResourceScope,
    EngineResourceVersion, Invocation, ListResources,
};
use crate::shared::server::errors::CapabilityError;

use super::authority::{AccessMode, ensure_authority, session_scope_for_invocation};
use super::contract::{ACTION_SCHEMA_VERSION, SNAPSHOT_SCHEMA_VERSION, WORKER};
use super::projection::{
    action_projection, action_response, action_summary, event_ref, safe_compacted_token_estimate,
    safe_compaction_summary, snapshot_projection,
};
use super::records::{
    ActionInput, EpochInput, action_record, action_resource_id, epoch_record, epoch_resource_id,
    resource_policy, snapshot_resource_id, version_ref,
};
use super::resource_store::{
    create_action_resource, create_epoch_resource, current_payload, ensure_context_action,
    ensure_context_snapshot, ensure_scope, inspect_resource_required, publish_lifecycle_event,
};
use super::snapshot::build_snapshot_record;
use super::validation::{
    actor_kind, bounded_text, engine_error, id_error, idempotency_key, optional_str, optional_u64,
    reason, required_str, runtime_error, store_error, system_invocation, ui_system_invocation,
};
use super::{
    CONTEXT_CONTROL_ACTION_KIND, CONTEXT_CONTROL_SNAPSHOT_KIND, CONTEXT_CONTROL_SNAPSHOT_SCHEMA_ID,
    Deps,
};

const DEFAULT_LIST_LIMIT: usize = 20;
const MAX_LIST_LIMIT: usize = 50;
const MAX_REASON_BYTES: usize = 500;

pub(crate) struct RuntimeCompactionInput<'a> {
    pub(crate) session_id: &'a str,
    pub(crate) reason: &'a str,
    pub(crate) summary: &'a str,
    pub(crate) tokens_before: u64,
    pub(crate) tokens_after: u64,
    pub(crate) compression_ratio: f64,
    pub(crate) persister: &'a Arc<EventPersister>,
    pub(crate) sequence_counter: Option<&'a AtomicI64>,
    pub(crate) operation_at: DateTime<Utc>,
}

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        "snapshot" => |invocation, deps| {
            snapshot_value_at(deps, invocation, &invocation.payload, Utc::now()).await
        },
        "compact" => |invocation, deps| {
            compact_value_at(deps, invocation, &invocation.payload, Utc::now()).await
        },
        "clear" => |invocation, deps| {
            clear_value_at(deps, invocation, &invocation.payload, Utc::now()).await
        },
        "action_list" => |invocation, deps| {
            action_list_value(deps, invocation, &invocation.payload).await
        },
        "action_inspect" => |invocation, deps| {
            action_inspect_value(deps, invocation, &invocation.payload).await
        },
        "ui_snapshot" => |invocation, deps| {
            ui_snapshot_value_at(deps, invocation, &invocation.payload, Utc::now()).await
        },
        "ui_compact" => |invocation, deps| {
            ui_compact_value_at(deps, invocation, &invocation.payload, Utc::now()).await
        },
        "ui_clear" => |invocation, deps| {
            ui_clear_value_at(deps, invocation, &invocation.payload, Utc::now()).await
        },
        "ui_action_list" => |invocation, deps| {
            ui_action_list_value(deps, invocation, &invocation.payload).await
        },
        "ui_action_inspect" => |invocation, deps| {
            ui_action_inspect_value(deps, invocation, &invocation.payload).await
        },
    ];
}

pub(crate) async fn ui_snapshot_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    let session_id = ui_session_id(invocation, payload, "context_control_ui_snapshot")?;
    let key = idempotency_key(invocation, payload, "context_control_ui_snapshot")?;
    let system = ui_system_invocation(
        "context_control::snapshot",
        &session_id,
        &key,
        payload.clone(),
        invocation,
    )?;
    snapshot_value_at(deps, &system, payload, operation_at).await
}

pub(crate) async fn ui_compact_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    let session_id = ui_session_id(invocation, payload, "context_control_ui_compact")?;
    let key = idempotency_key(invocation, payload, "context_control_ui_compact")?;
    let system = ui_system_invocation(
        "context_control::compact",
        &session_id,
        &key,
        payload.clone(),
        invocation,
    )?;
    compact_value_at(deps, &system, payload, operation_at).await
}

pub(crate) async fn ui_clear_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    let session_id = ui_session_id(invocation, payload, "context_control_ui_clear")?;
    let key = idempotency_key(invocation, payload, "context_control_ui_clear")?;
    let system = ui_system_invocation(
        "context_control::clear",
        &session_id,
        &key,
        payload.clone(),
        invocation,
    )?;
    clear_value_at(deps, &system, payload, operation_at).await
}

pub(crate) async fn ui_action_list_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let session_id = ui_session_id(invocation, payload, "context_control_ui_action_list")?;
    let system = ui_system_invocation(
        "context_control::action_list",
        &session_id,
        "ui-action-list",
        payload.clone(),
        invocation,
    )?;
    action_list_value(deps, &system, payload).await
}

pub(crate) async fn ui_action_inspect_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let session_id = ui_session_id(invocation, payload, "context_control_ui_action_inspect")?;
    let system = ui_system_invocation(
        "context_control::action_inspect",
        &session_id,
        "ui-action-inspect",
        payload.clone(),
        invocation,
    )?;
    action_inspect_value(deps, &system, payload).await
}

fn ui_session_id(
    invocation: &Invocation,
    payload: &Value,
    operation: &str,
) -> Result<String, CapabilityError> {
    if !matches!(
        invocation.causal_context.actor_kind,
        crate::engine::ActorKind::Client | crate::engine::ActorKind::System
    ) {
        return Err(CapabilityError::InvalidParams {
            message: format!("{operation} requires first-party client context"),
        });
    }
    let session_id = invocation
        .causal_context
        .session_id
        .as_deref()
        .or(optional_str(payload, "sessionId")?)
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: format!("{operation} requires sessionId"),
        })?;
    if let Some(payload_session_id) = optional_str(payload, "sessionId")?
        && payload_session_id != session_id
    {
        return Err(CapabilityError::InvalidParams {
            message: format!("{operation} sessionId must match current session"),
        });
    }
    Ok(session_id.to_owned())
}

pub(crate) async fn record_runtime_compaction_action(
    deps: &Deps,
    input: RuntimeCompactionInput<'_>,
) -> Result<(), CapabilityError> {
    let scope = EngineResourceScope::Session(input.session_id.to_owned());
    let operation_at = input.operation_at;
    let idempotency_key = format!(
        "runtime-compact-{}-{}-{}",
        operation_at.timestamp_millis(),
        input.tokens_before,
        input.tokens_after
    );
    let invocation = system_invocation(
        "context_control::compact",
        input.session_id,
        &idempotency_key,
        json!({
            "sessionId": input.session_id,
            "idempotencyKey": idempotency_key,
            "reason": input.reason
        }),
    )?;
    let action_resource_id = action_resource_id(input.session_id, "compact", &idempotency_key);
    if deps
        .engine_host
        .inspect_resource(&action_resource_id)
        .await
        .map_err(engine_error)?
        .is_some()
    {
        return Ok(());
    }

    let snapshot_id = format!("runtime-compact-preflight-{idempotency_key}");
    let (snapshot_resource, snapshot_version, _, _) = record_snapshot(
        deps,
        &invocation,
        input.session_id,
        &scope,
        &snapshot_id,
        operation_at,
    )
    .await?;
    let reason = bounded_text("reason", input.reason, MAX_REASON_BYTES)?;
    let safe_summary = bounded_text("summary", input.summary, 4_000)?;
    let event = input
        .persister
        .append_with_runtime_sequence(
            input.session_id,
            EventType::CompactBoundary,
            json!({
                "originalTokens": input.tokens_before,
                "compactedTokens": input.tokens_after,
                "compressionRatio": input.compression_ratio,
                "reason": reason,
                "summary": safe_summary,
                "estimatedContextTokens": input.tokens_after,
                "contextControlActionResourceId": &action_resource_id,
                "contextControlSnapshotResourceId": &snapshot_resource.resource_id
            }),
            input.sequence_counter,
        )
        .await
        .map_err(runtime_error)?;

    let now = operation_at.to_rfc3339();
    let record = action_record(ActionInput {
        action_id: "runtime-compact",
        state: "succeeded",
        action_kind: "compact",
        reason: &reason,
        actor_kind: actor_kind(&invocation),
        scope: &scope,
        session_id: input.session_id,
        snapshot_resource: &snapshot_resource,
        snapshot_version: &snapshot_version,
        expected_effect: "replace provider context with a bounded safe summary boundary",
        result: json!({
            "status": "succeeded",
            "tokensBefore": input.tokens_before,
            "tokensAfter": input.tokens_after,
            "timelineEventWritten": true,
            "timelineEvent": event_ref(&event.id, event.sequence, "compact.boundary"),
            "providerContextReplacedBySafeSummary": true,
            "historyStillInspectable": true
        }),
        audit_refs: vec![
            version_ref(&snapshot_resource, &snapshot_version, "preflight_snapshot"),
            event_ref(&event.id, event.sequence, "compact.boundary"),
        ],
        created_at: &now,
        updated_at: &now,
        invocation: &invocation,
        idempotency_key: &idempotency_key,
    });
    let (resource, _, _) = create_action_resource(
        deps,
        &invocation,
        &action_resource_id,
        "succeeded",
        record,
        "context-control-action:runtime-compact",
    )
    .await?;
    publish_lifecycle_event(
        deps,
        &invocation,
        "context_control.runtime_compact_recorded",
        &resource,
        json!({"metadataOnly": true, "networkPolicy": "none"}),
    )
    .await?;
    deps.session_manager.invalidate_session(input.session_id);
    Ok(())
}

pub(crate) async fn snapshot_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    let (session_id, scope) = session_scope_for_invocation(
        invocation,
        optional_str(payload, "sessionId")?,
        "context_control_snapshot",
    )?;
    ensure_authority(
        deps,
        invocation,
        "context_control_snapshot",
        AccessMode::Write,
        &session_id,
        None,
    )
    .await?;
    let idempotency_key = idempotency_key(invocation, payload, "context_control_snapshot")?;
    let snapshot_id = format!("snapshot-{idempotency_key}");
    let (resource, version, record, replay) = record_snapshot(
        deps,
        invocation,
        &session_id,
        &scope,
        &snapshot_id,
        operation_at,
    )
    .await?;
    Ok(json!({
        "schemaVersion": SNAPSHOT_SCHEMA_VERSION,
        "operation": "context_control_snapshot",
        "status": resource.lifecycle,
        "idempotentReplay": replay,
        "contextControlSnapshotResourceId": resource.resource_id,
        "contextControlSnapshotVersionId": version.version_id,
        "projection": snapshot_projection(&resource, &version, &record)
    }))
}

pub(crate) async fn compact_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    let (session_id, scope) = session_scope_for_invocation(
        invocation,
        optional_str(payload, "sessionId")?,
        "context_control_compact",
    )?;
    ensure_authority(
        deps,
        invocation,
        "context_control_compact",
        AccessMode::Write,
        &session_id,
        None,
    )
    .await?;
    let idempotency_key = idempotency_key(invocation, payload, "context_control_compact")?;
    let action_resource_id = action_resource_id(&session_id, "compact", &idempotency_key);
    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&action_resource_id)
        .await
        .map_err(engine_error)?
    {
        let (version, record) = current_payload(&existing, "context_control_compact replay")?;
        return Ok(action_response(
            "context_control_compact",
            &existing.resource,
            version,
            record,
            true,
        ));
    }

    let reason = reason(
        payload,
        "Manual context compaction requested",
        MAX_REASON_BYTES,
    )?;
    let snapshot_id = format!("compact-preflight-{idempotency_key}");
    let (snapshot_resource, snapshot_version, snapshot_payload, _) = record_snapshot(
        deps,
        invocation,
        &session_id,
        &scope,
        &snapshot_id,
        operation_at,
    )
    .await?;
    let estimated_tokens = snapshot_payload
        .pointer("/session/estimatedTokens")
        .and_then(Value::as_u64)
        .unwrap_or_default();
    let message_count = snapshot_payload
        .pointer("/session/messageCount")
        .and_then(Value::as_u64)
        .unwrap_or_default();

    let now = operation_at.to_rfc3339();
    let (state, result, audit_refs) = if message_count < 2 || estimated_tokens == 0 {
        (
            "skipped",
            json!({
                "status": "skipped",
                "reason": "no_summarizable_context",
                "tokensBefore": estimated_tokens,
                "tokensAfter": estimated_tokens,
                "timelineEventWritten": false
            }),
            vec![version_ref(
                &snapshot_resource,
                &snapshot_version,
                "preflight_snapshot",
            )],
        )
    } else {
        let tokens_after = safe_compacted_token_estimate(message_count);
        let summary = safe_compaction_summary(&session_id, message_count, estimated_tokens);
        let event = deps
            .event_store
            .append(&AppendOptions {
                session_id: &session_id,
                event_type: EventType::CompactBoundary,
                payload: json!({
                    "originalTokens": estimated_tokens,
                    "compactedTokens": tokens_after,
                    "compressionRatio": if estimated_tokens > 0 {
                        tokens_after as f64 / estimated_tokens as f64
                    } else {
                        1.0
                    },
                    "reason": "manual",
                    "summary": summary,
                    "estimatedContextTokens": tokens_after,
                    "preservedTurns": 0,
                    "summarizedTurns": message_count,
                    "preservedMessages": 0,
                    "contextControlActionResourceId": &action_resource_id,
                    "contextControlSnapshotResourceId": &snapshot_resource.resource_id
                }),
                parent_id: None,
                sequence: None,
            })
            .map_err(store_error)?;
        deps.session_manager.invalidate_session(&session_id);
        (
            "succeeded",
            json!({
                "status": "succeeded",
                "tokensBefore": estimated_tokens,
                "tokensAfter": tokens_after,
                "timelineEventWritten": true,
                "timelineEvent": event_ref(&event.id, event.sequence, "compact.boundary"),
                "providerContextReplacedBySafeSummary": true,
                "historyStillInspectable": true
            }),
            vec![
                version_ref(&snapshot_resource, &snapshot_version, "preflight_snapshot"),
                event_ref(&event.id, event.sequence, "compact.boundary"),
            ],
        )
    };

    let record = action_record(ActionInput {
        action_id: &format!("compact-{idempotency_key}"),
        state,
        action_kind: "compact",
        reason: &reason,
        actor_kind: actor_kind(invocation),
        scope: &scope,
        session_id: &session_id,
        snapshot_resource: &snapshot_resource,
        snapshot_version: &snapshot_version,
        expected_effect: "replace provider context with a bounded safe summary boundary",
        result,
        audit_refs,
        created_at: &now,
        updated_at: &now,
        invocation,
        idempotency_key: &idempotency_key,
    });
    let (resource, version, payload) = create_action_resource(
        deps,
        invocation,
        &action_resource_id,
        state,
        record,
        "context-control-action:compact",
    )
    .await?;
    publish_lifecycle_event(
        deps,
        invocation,
        "context_control.compact_recorded",
        &resource,
        json!({"metadataOnly": true, "networkPolicy": "none"}),
    )
    .await?;
    Ok(action_response(
        "context_control_compact",
        &resource,
        &version,
        &payload,
        false,
    ))
}

pub(crate) async fn clear_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    let (session_id, scope) = session_scope_for_invocation(
        invocation,
        optional_str(payload, "sessionId")?,
        "context_control_clear",
    )?;
    ensure_authority(
        deps,
        invocation,
        "context_control_clear",
        AccessMode::Write,
        &session_id,
        None,
    )
    .await?;
    let idempotency_key = idempotency_key(invocation, payload, "context_control_clear")?;
    let action_resource_id = action_resource_id(&session_id, "clear", &idempotency_key);
    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&action_resource_id)
        .await
        .map_err(engine_error)?
    {
        let (version, record) = current_payload(&existing, "context_control_clear replay")?;
        return Ok(action_response(
            "context_control_clear",
            &existing.resource,
            version,
            record,
            true,
        ));
    }

    let reason = reason(payload, "Manual context clear requested", MAX_REASON_BYTES)?;
    let snapshot_id = format!("clear-preflight-{idempotency_key}");
    let (snapshot_resource, snapshot_version, snapshot_payload, _) = record_snapshot(
        deps,
        invocation,
        &session_id,
        &scope,
        &snapshot_id,
        operation_at,
    )
    .await?;
    let estimated_tokens = snapshot_payload
        .pointer("/session/estimatedTokens")
        .and_then(Value::as_u64)
        .unwrap_or_default();
    let event = deps
        .event_store
        .append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::ContextCleared,
            payload: json!({
                "tokensBefore": estimated_tokens,
                "tokensAfter": 0,
                "reason": reason.clone(),
                "contextControlActionResourceId": &action_resource_id,
                "contextControlSnapshotResourceId": &snapshot_resource.resource_id
            }),
            parent_id: None,
            sequence: None,
        })
        .map_err(store_error)?;
    deps.session_manager.invalidate_session(&session_id);
    let now = operation_at.to_rfc3339();
    let epoch_id = format!("epoch-{}", event.sequence);
    let epoch_resource_id = epoch_resource_id(&session_id, &epoch_id);
    let epoch_payload = epoch_record(EpochInput {
        epoch_id: &epoch_id,
        scope: &scope,
        session_id: &session_id,
        boundary_event_id: &event.id,
        boundary_sequence: event.sequence,
        action_resource: &action_resource_id,
        created_at: &now,
    });
    let (epoch_resource, epoch_version, _) = create_epoch_resource(
        deps,
        invocation,
        &epoch_resource_id,
        epoch_payload,
        &epoch_id,
    )
    .await?;
    let record = action_record(ActionInput {
        action_id: &format!("clear-{idempotency_key}"),
        state: "succeeded",
        action_kind: "clear",
        reason: &reason,
        actor_kind: actor_kind(invocation),
        scope: &scope,
        session_id: &session_id,
        snapshot_resource: &snapshot_resource,
        snapshot_version: &snapshot_version,
        expected_effect: "create a new context epoch while keeping history/resources/traces inspectable",
        result: json!({
            "status": "succeeded",
            "tokensBefore": estimated_tokens,
            "tokensAfter": 0,
            "timelineEventWritten": true,
            "timelineEvent": event_ref(&event.id, event.sequence, "context.cleared"),
            "newEpoch": version_ref(&epoch_resource, &epoch_version, "created_epoch"),
            "historyStillInspectable": true,
            "priorTurnsExcludedFromProviderContext": true
        }),
        audit_refs: vec![
            version_ref(&snapshot_resource, &snapshot_version, "preflight_snapshot"),
            event_ref(&event.id, event.sequence, "context.cleared"),
            version_ref(&epoch_resource, &epoch_version, "created_epoch"),
        ],
        created_at: &now,
        updated_at: &now,
        invocation,
        idempotency_key: &idempotency_key,
    });
    let (resource, version, payload) = create_action_resource(
        deps,
        invocation,
        &action_resource_id,
        "succeeded",
        record,
        "context-control-action:clear",
    )
    .await?;
    publish_lifecycle_event(
        deps,
        invocation,
        "context_control.clear_recorded",
        &resource,
        json!({
            "metadataOnly": true,
            "networkPolicy": "none",
            "epoch": version_ref(&epoch_resource, &epoch_version, "created_epoch")
        }),
    )
    .await?;
    Ok(action_response(
        "context_control_clear",
        &resource,
        &version,
        &payload,
        false,
    ))
}

pub(crate) async fn action_list_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let (session_id, scope) = session_scope_for_invocation(
        invocation,
        optional_str(payload, "sessionId")?,
        "context_control_action_list",
    )?;
    ensure_authority(
        deps,
        invocation,
        "context_control_action_list",
        AccessMode::Read,
        &session_id,
        None,
    )
    .await?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(DEFAULT_LIST_LIMIT)
        .clamp(1, MAX_LIST_LIMIT);
    let resources = deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(CONTEXT_CONTROL_ACTION_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: None,
            limit,
        })
        .await
        .map_err(engine_error)?;
    let mut actions = Vec::new();
    for resource in resources {
        if let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        {
            ensure_scope(&inspection, &scope, "context_control_action_list")?;
            let (version, payload) =
                current_payload(&inspection, "context_control_action_list projection")?;
            actions.push(action_summary(&inspection.resource, version, payload));
        }
    }
    Ok(json!({
        "schemaVersion": ACTION_SCHEMA_VERSION,
        "operation": "context_control_action_list",
        "status": "ok",
        "sessionId": session_id,
        "projection": {
            "actions": actions,
            "limit": limit,
            "providerSafe": true
        }
    }))
}

pub(crate) async fn action_inspect_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let (session_id, scope) = session_scope_for_invocation(
        invocation,
        optional_str(payload, "sessionId")?,
        "context_control_action_inspect",
    )?;
    let resource_id = required_str(payload, "contextControlActionResourceId")?;
    ensure_authority(
        deps,
        invocation,
        "context_control_action_inspect",
        AccessMode::Read,
        &session_id,
        Some(resource_id),
    )
    .await?;
    let inspection = inspect_resource_required(deps, resource_id, "context control action").await?;
    ensure_context_action(&inspection, "context_control_action_inspect")?;
    ensure_scope(&inspection, &scope, "context_control_action_inspect")?;
    let (version, record) = current_payload(&inspection, "context_control_action_inspect")?;
    Ok(json!({
        "schemaVersion": ACTION_SCHEMA_VERSION,
        "operation": "context_control_action_inspect",
        "status": inspection.resource.lifecycle,
        "contextControlActionResourceId": inspection.resource.resource_id,
        "contextControlActionVersionId": version.version_id,
        "projection": action_projection(&inspection.resource, version, record)
    }))
}

async fn record_snapshot(
    deps: &Deps,
    invocation: &Invocation,
    session_id: &str,
    scope: &EngineResourceScope,
    snapshot_id: &str,
    operation_at: DateTime<Utc>,
) -> Result<(EngineResource, EngineResourceVersion, Value, bool), CapabilityError> {
    let resource_id = snapshot_resource_id(session_id, snapshot_id);
    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_context_snapshot(&existing, "context_control_snapshot replay")?;
        ensure_scope(&existing, scope, "context_control_snapshot replay")?;
        let (version, payload) = current_payload(&existing, "context_control_snapshot replay")?;
        return Ok((
            existing.resource.clone(),
            version.clone(),
            payload.clone(),
            true,
        ));
    }
    let record = build_snapshot_record(deps, session_id, scope, snapshot_id, operation_at).await?;
    let resource = deps
        .engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id),
            kind: CONTEXT_CONTROL_SNAPSHOT_KIND.to_owned(),
            schema_id: Some(CONTEXT_CONTROL_SNAPSHOT_SCHEMA_ID.to_owned()),
            scope: scope.clone(),
            owner_worker_id: crate::engine::WorkerId::new(WORKER).map_err(id_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("available".to_owned()),
            policy: resource_policy(CONTEXT_CONTROL_SNAPSHOT_KIND),
            initial_payload: Some(record),
            locations: vec![EngineResourceLocation {
                kind: "context_control_snapshot".to_owned(),
                uri: format!("context-control-snapshot:{snapshot_id}"),
                mime_type: Some("application/json".to_owned()),
                size_bytes: None,
            }],
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    publish_lifecycle_event(
        deps,
        invocation,
        "context_control.snapshot_recorded",
        &resource,
        json!({"metadataOnly": true, "networkPolicy": "none"}),
    )
    .await?;
    let inspection =
        inspect_resource_required(deps, &resource.resource_id, "context control snapshot").await?;
    let (version, payload) = current_payload(&inspection, "context_control_snapshot created")?;
    Ok((resource, version.clone(), payload.clone(), false))
}
