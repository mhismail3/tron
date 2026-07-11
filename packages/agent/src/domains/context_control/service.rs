use std::sync::Arc;
use std::sync::atomic::AtomicI64;

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::registration::bindings::operation_bindings;
use crate::domains::session::event_store::{AppendOptions, EventRow, EventType};
use crate::engine::{
    CreateResource, EngineResource, EngineResourceLocation, EngineResourceScope,
    EngineResourceVersion, Invocation, ListResources,
};
use crate::shared::server::errors::CapabilityError;

use super::authority::{AccessMode, ensure_authority, session_scope_for_invocation};
use super::contract::{ACTION_SCHEMA_VERSION, SNAPSHOT_SCHEMA_VERSION, WORKER};
use super::projection::{
    action_projection, action_response, action_summary, event_ref, policy_record_response,
    policy_snapshot_response, policy_summary, safe_compacted_token_estimate,
    safe_compaction_summary, snapshot_projection,
};
use super::records::{
    ActionInput, EpochInput, PolicyRecordInput, PolicySnapshotInput, action_record,
    action_resource_id, epoch_record, epoch_resource_id, exclusion_resource_id, policy_record,
    policy_snapshot_record, policy_snapshot_resource_id, resource_policy,
    schema_version_for_policy_kind, snapshot_resource_id, survivor_resource_id, version_ref,
};
use super::resource_store::{
    create_action_resource, create_epoch_resource, create_policy_resource, current_payload,
    ensure_context_action, ensure_context_exclusion, ensure_context_policy_snapshot,
    ensure_context_snapshot, ensure_context_survivor, ensure_scope, inspect_resource_required,
    publish_lifecycle_event, update_action_resource, update_policy_resource,
};
use super::snapshot::{build_snapshot_record, status_projection};
use super::validation::{
    actor_kind, bounded_text, engine_error, id_error, idempotency_key, optional_str, optional_u64,
    policy_target_kind, policy_target_ref, reason, required_reason, required_str, runtime_error,
    store_error, system_invocation, ui_system_invocation,
};
use super::{
    CONTEXT_CONTROL_ACTION_KIND, CONTEXT_CONTROL_SNAPSHOT_KIND, CONTEXT_CONTROL_SNAPSHOT_SCHEMA_ID,
    CONTEXT_EXCLUSION_KIND, CONTEXT_EXCLUSION_SCHEMA_ID, CONTEXT_POLICY_SNAPSHOT_KIND,
    CONTEXT_POLICY_SNAPSHOT_SCHEMA_ID, CONTEXT_SURVIVOR_KIND, CONTEXT_SURVIVOR_SCHEMA_ID, Deps,
};

const DEFAULT_LIST_LIMIT: usize = 20;
const MAX_LIST_LIMIT: usize = 50;
const MAX_REASON_BYTES: usize = 500;
const MAX_POLICY_LABEL_BYTES: usize = 200;

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
        "status" => |invocation, deps| {
            status_value_at(deps, invocation, &invocation.payload, Utc::now()).await
        },
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
        "survivor_record" => |invocation, deps| {
            survivor_record_value_at(deps, invocation, &invocation.payload, Utc::now()).await
        },
        "survivor_list" => |invocation, deps| {
            survivor_list_value(deps, invocation, &invocation.payload).await
        },
        "survivor_disable" => |invocation, deps| {
            survivor_disable_value_at(deps, invocation, &invocation.payload, Utc::now()).await
        },
        "exclusion_record" => |invocation, deps| {
            exclusion_record_value_at(deps, invocation, &invocation.payload, Utc::now()).await
        },
        "exclusion_list" => |invocation, deps| {
            exclusion_list_value(deps, invocation, &invocation.payload).await
        },
        "exclusion_disable" => |invocation, deps| {
            exclusion_disable_value_at(deps, invocation, &invocation.payload, Utc::now()).await
        },
        "policy_snapshot" => |invocation, deps| {
            policy_snapshot_value_at(deps, invocation, &invocation.payload, Utc::now()).await
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

pub(crate) async fn status_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    let (session_id, scope) = session_scope_for_invocation(
        invocation,
        optional_str(payload, "sessionId")?,
        "context_control_status",
    )?;
    ensure_authority(
        deps,
        invocation,
        "context_control_status",
        AccessMode::Read,
        &session_id,
        None,
    )
    .await?;
    let record = build_snapshot_record(
        deps,
        &session_id,
        &scope,
        "ephemeral-current-status",
        operation_at,
    )
    .await?;
    Ok(json!({
        "schemaVersion": SNAPSHOT_SCHEMA_VERSION,
        "operation": "context_control_status",
        "status": "ok",
        "sessionId": session_id,
        "projection": status_projection(&record)
    }))
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

fn action_is_requested(record: &Value) -> bool {
    record.get("state").and_then(Value::as_str) == Some("requested")
}

async fn find_boundary_event(
    deps: &Deps,
    session_id: &str,
    event_type: EventType,
    action_resource_id: &str,
) -> Result<Option<EventRow>, CapabilityError> {
    let rows = deps
        .event_store
        .get_events_by_type(session_id, &[event_type.as_str()], None)
        .map_err(store_error)?;
    let payloads = deps
        .event_store
        .resolve_event_payloads(&rows)
        .map_err(store_error)?;
    Ok(rows.into_iter().zip(payloads).find_map(|(row, payload)| {
        (payload
            .get("contextControlActionResourceId")
            .and_then(Value::as_str)
            == Some(action_resource_id))
        .then_some(row)
    }))
}

fn boundary_committed_pending_response(
    operation: &str,
    resource: &EngineResource,
    version: &EngineResourceVersion,
    record: &Value,
    event: &EventRow,
    relation: &str,
) -> Value {
    let mut response = action_response(operation, resource, version, record, false);
    response["status"] = json!("boundary_committed_finalization_pending");
    response["boundaryCommittedThisInvocation"] = json!(true);
    response["projection"]["result"] = json!({
        "status": "boundary_committed_finalization_pending",
        "timelineEventWritten": true,
        "timelineEvent": event_ref(&event.id, event.sequence, relation),
        "providerContextBoundaryCommitted": true,
        "providerContextAppliesOnNextAgentRun": true,
        "currentAgentRunMustStop": true,
        "auditFinalizationPending": true,
        "historyStillInspectable": true
    });
    response
}

async fn publish_action_lifecycle_best_effort(
    deps: &Deps,
    invocation: &Invocation,
    event_type: &str,
    resource: &EngineResource,
    payload: Value,
) {
    if let Err(error) =
        publish_lifecycle_event(deps, invocation, event_type, resource, payload).await
    {
        tracing::warn!(
            operation = event_type,
            resource_id = resource.resource_id,
            error = %error,
            "context-control action committed without secondary lifecycle publication"
        );
    }
}

async fn repair_pending_runtime_compaction_actions(
    deps: &Deps,
    invocation: &Invocation,
    session_id: &str,
) -> Result<(), CapabilityError> {
    let rows = deps
        .event_store
        .get_events_by_type(session_id, &[EventType::CompactBoundary.as_str()], None)
        .map_err(store_error)?;
    let payloads = deps
        .event_store
        .resolve_event_payloads(&rows)
        .map_err(store_error)?;
    for (event, boundary) in rows.into_iter().zip(payloads) {
        let Some(action_resource_id) = boundary
            .get("contextControlActionResourceId")
            .and_then(Value::as_str)
        else {
            continue;
        };
        let Some(action) = deps
            .engine_host
            .inspect_resource(action_resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        let (version, prepared) =
            current_payload(&action, "runtime compaction action reconciliation")?;
        if !action_is_requested(prepared)
            || prepared.get("actionId").and_then(Value::as_str) != Some("runtime-compact")
        {
            continue;
        }

        let mut finalized = prepared.clone();
        finalized["state"] = json!("succeeded");
        finalized["result"] = json!({
            "status": "succeeded",
            "tokensBefore": boundary.get("originalTokens").cloned().unwrap_or(Value::Null),
            "tokensAfter": boundary.get("compactedTokens").cloned().unwrap_or(Value::Null),
            "timelineEventWritten": true,
            "timelineEvent": event_ref(&event.id, event.sequence, "compact.boundary"),
            "providerContextReplacedBySafeSummary": true,
            "historyStillInspectable": true,
            "recoveredFinalization": true
        });
        if let Some(audit_refs) = finalized.get_mut("auditRefs").and_then(Value::as_array_mut) {
            audit_refs.push(event_ref(&event.id, event.sequence, "compact.boundary"));
        }
        finalized["updatedAt"] = json!(event.timestamp);
        finalized["revision"] = json!(
            prepared
                .get("revision")
                .and_then(Value::as_u64)
                .unwrap_or(1)
                .saturating_add(1)
        );
        let (resource, _, _) = update_action_resource(
            deps,
            invocation,
            action_resource_id,
            version.version_id.clone(),
            "succeeded",
            finalized,
        )
        .await?;
        publish_action_lifecycle_best_effort(
            deps,
            invocation,
            "context_control.runtime_compact_reconciled",
            &resource,
            json!({"metadataOnly": true, "networkPolicy": "none"}),
        )
        .await;
    }
    Ok(())
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
    repair_pending_runtime_compaction_actions(deps, &invocation, input.session_id).await?;
    let action_resource_id = action_resource_id(input.session_id, "compact", &idempotency_key);
    let existing = deps
        .engine_host
        .inspect_resource(&action_resource_id)
        .await
        .map_err(engine_error)?;
    let reason = bounded_text("reason", input.reason, MAX_REASON_BYTES)?;
    let now = operation_at.to_rfc3339();
    let (action_resource, action_version, snapshot_resource, snapshot_version) =
        if let Some(existing) = existing {
            let (version, record) =
                current_payload(&existing, "context_control runtime compact replay")?;
            if !action_is_requested(record) {
                return Ok(());
            }
            let snapshot_resource_id = record
                .pointer("/preflight/snapshot/resourceId")
                .and_then(Value::as_str)
                .ok_or_else(|| CapabilityError::InvalidParams {
                    message: "prepared runtime compaction is missing its snapshot ref".to_owned(),
                })?;
            let snapshot = inspect_resource_required(
                deps,
                snapshot_resource_id,
                "runtime compaction snapshot",
            )
            .await?;
            let (snapshot_version, _) =
                current_payload(&snapshot, "runtime compaction snapshot replay")?;
            (
                existing.resource.clone(),
                version.clone(),
                snapshot.resource.clone(),
                snapshot_version.clone(),
            )
        } else {
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
            let record = action_record(ActionInput {
                action_id: "runtime-compact",
                state: "requested",
                action_kind: "compact",
                reason: &reason,
                actor_kind: actor_kind(&invocation),
                scope: &scope,
                session_id: input.session_id,
                snapshot_resource: &snapshot_resource,
                snapshot_version: &snapshot_version,
                expected_effect: "replace provider context with a bounded safe summary boundary",
                result: json!({
                    "status": "requested",
                    "timelineEventWritten": false,
                    "boundaryPreparationDurable": true
                }),
                audit_refs: vec![version_ref(
                    &snapshot_resource,
                    &snapshot_version,
                    "preflight_snapshot",
                )],
                created_at: &now,
                updated_at: &now,
                invocation: &invocation,
                idempotency_key: &idempotency_key,
            });
            let (action_resource, action_version, _) = create_action_resource(
                deps,
                &invocation,
                &action_resource_id,
                "requested",
                record,
                "context-control-action:runtime-compact",
            )
            .await?;
            (
                action_resource,
                action_version,
                snapshot_resource,
                snapshot_version,
            )
        };
    let safe_summary = bounded_text("summary", input.summary, 4_000)?;
    let event = if let Some(event) = find_boundary_event(
        deps,
        input.session_id,
        EventType::CompactBoundary,
        &action_resource_id,
    )
    .await?
    {
        event
    } else {
        input
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
                    "contextControlActionVersionId": &action_version.version_id,
                    "contextControlSnapshotResourceId": &snapshot_resource.resource_id
                }),
                input.sequence_counter,
            )
            .await
            .map_err(runtime_error)?
    };
    deps.session_manager.invalidate_session(input.session_id);
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
    let finalized = update_action_resource(
        deps,
        &invocation,
        &action_resource_id,
        action_version.version_id,
        "succeeded",
        record,
    )
    .await;
    let Ok((resource, _, _)) = finalized else {
        tracing::warn!(
            resource_id = action_resource.resource_id,
            event_id = event.id,
            "runtime compaction boundary committed with requested action finalization pending"
        );
        return Ok(());
    };
    publish_action_lifecycle_best_effort(
        deps,
        &invocation,
        "context_control.runtime_compact_recorded",
        &resource,
        json!({"metadataOnly": true, "networkPolicy": "none"}),
    )
    .await;
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
    let existing = deps
        .engine_host
        .inspect_resource(&action_resource_id)
        .await
        .map_err(engine_error)?;
    let requested_reason = reason(
        payload,
        "Manual context compaction requested",
        MAX_REASON_BYTES,
    )?;
    let now = operation_at.to_rfc3339();
    let (
        action_resource,
        action_version,
        action_payload,
        snapshot_resource,
        snapshot_version,
        snapshot_payload,
        reason,
    ) = if let Some(existing) = existing {
        let (version, record) = current_payload(&existing, "context_control_compact replay")?;
        if !action_is_requested(record) {
            return Ok(action_response(
                "context_control_compact",
                &existing.resource,
                version,
                record,
                true,
            ));
        }
        let snapshot_resource_id = record
            .pointer("/preflight/snapshot/resourceId")
            .and_then(Value::as_str)
            .ok_or_else(|| CapabilityError::InvalidParams {
                message: "prepared context compaction is missing its snapshot ref".to_owned(),
            })?;
        let snapshot =
            inspect_resource_required(deps, snapshot_resource_id, "compact preflight snapshot")
                .await?;
        let (snapshot_version, snapshot_payload) =
            current_payload(&snapshot, "compact preflight snapshot replay")?;
        let stored_reason = record
            .pointer("/action/reason")
            .and_then(Value::as_str)
            .unwrap_or(&requested_reason)
            .to_owned();
        (
            existing.resource.clone(),
            version.clone(),
            record.clone(),
            snapshot.resource.clone(),
            snapshot_version.clone(),
            snapshot_payload.clone(),
            stored_reason,
        )
    } else {
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
        let record = action_record(ActionInput {
            action_id: &format!("compact-{idempotency_key}"),
            state: "requested",
            action_kind: "compact",
            reason: &requested_reason,
            actor_kind: actor_kind(invocation),
            scope: &scope,
            session_id: &session_id,
            snapshot_resource: &snapshot_resource,
            snapshot_version: &snapshot_version,
            expected_effect: "commit a bounded safe summary boundary for the next agent run",
            result: json!({
                "status": "requested",
                "timelineEventWritten": false,
                "boundaryPreparationDurable": true
            }),
            audit_refs: vec![version_ref(
                &snapshot_resource,
                &snapshot_version,
                "preflight_snapshot",
            )],
            created_at: &now,
            updated_at: &now,
            invocation,
            idempotency_key: &idempotency_key,
        });
        let (action_resource, action_version, action_payload) = create_action_resource(
            deps,
            invocation,
            &action_resource_id,
            "requested",
            record,
            "context-control-action:compact",
        )
        .await?;
        (
            action_resource,
            action_version,
            action_payload,
            snapshot_resource,
            snapshot_version,
            snapshot_payload,
            requested_reason,
        )
    };
    let estimated_tokens = snapshot_payload
        .pointer("/session/estimatedTokens")
        .and_then(Value::as_u64)
        .unwrap_or_default();
    let message_count = snapshot_payload
        .pointer("/session/messageCount")
        .and_then(Value::as_u64)
        .unwrap_or_default();

    let (state, result, audit_refs, boundary_event) = if message_count < 2 || estimated_tokens == 0
    {
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
            None,
        )
    } else {
        let tokens_after = safe_compacted_token_estimate(message_count);
        let summary = safe_compaction_summary(&session_id, message_count, estimated_tokens);
        let event = if let Some(event) = find_boundary_event(
            deps,
            &session_id,
            EventType::CompactBoundary,
            &action_resource_id,
        )
        .await?
        {
            event
        } else {
            deps.event_store
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
                        "contextControlActionVersionId": &action_version.version_id,
                        "contextControlSnapshotResourceId": &snapshot_resource.resource_id,
                        "boundaryInvocationId": invocation.id.as_str()
                    }),
                    parent_id: None,
                    sequence: None,
                })
                .map_err(store_error)?
        };
        deps.session_manager.invalidate_session(&session_id);
        (
            "succeeded",
            json!({
                "status": "succeeded",
                "tokensBefore": estimated_tokens,
                "tokensAfter": tokens_after,
                "timelineEventWritten": true,
                "timelineEvent": event_ref(&event.id, event.sequence, "compact.boundary"),
                "providerContextBoundaryCommitted": true,
                "providerContextAppliesOnNextAgentRun": true,
                "currentAgentRunMustStop": true,
                "historyStillInspectable": true
            }),
            vec![
                version_ref(&snapshot_resource, &snapshot_version, "preflight_snapshot"),
                event_ref(&event.id, event.sequence, "compact.boundary"),
            ],
            Some(event),
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
        expected_effect: "commit a bounded safe summary boundary for the next agent run",
        result,
        audit_refs,
        created_at: &now,
        updated_at: &now,
        invocation,
        idempotency_key: &idempotency_key,
    });
    let finalized = update_action_resource(
        deps,
        invocation,
        &action_resource_id,
        action_version.version_id.clone(),
        state,
        record,
    )
    .await;
    let (resource, version, payload) = match finalized {
        Ok(finalized) => finalized,
        Err(error) => {
            if let Some(event) = boundary_event {
                tracing::warn!(
                    resource_id = action_resource.resource_id,
                    event_id = event.id,
                    error = %error,
                    "manual compaction boundary committed with action finalization pending"
                );
                return Ok(boundary_committed_pending_response(
                    "context_control_compact",
                    &action_resource,
                    &action_version,
                    &action_payload,
                    &event,
                    "compact.boundary",
                ));
            }
            return Err(error);
        }
    };
    publish_action_lifecycle_best_effort(
        deps,
        invocation,
        "context_control.compact_recorded",
        &resource,
        json!({"metadataOnly": true, "networkPolicy": "none"}),
    )
    .await;
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
    let existing = deps
        .engine_host
        .inspect_resource(&action_resource_id)
        .await
        .map_err(engine_error)?;
    let requested_reason = reason(payload, "Manual context clear requested", MAX_REASON_BYTES)?;
    let now = operation_at.to_rfc3339();
    let (
        action_resource,
        action_version,
        action_payload,
        snapshot_resource,
        snapshot_version,
        snapshot_payload,
        reason,
    ) = if let Some(existing) = existing {
        let (version, record) = current_payload(&existing, "context_control_clear replay")?;
        if !action_is_requested(record) {
            return Ok(action_response(
                "context_control_clear",
                &existing.resource,
                version,
                record,
                true,
            ));
        }
        let snapshot_resource_id = record
            .pointer("/preflight/snapshot/resourceId")
            .and_then(Value::as_str)
            .ok_or_else(|| CapabilityError::InvalidParams {
                message: "prepared context clear is missing its snapshot ref".to_owned(),
            })?;
        let snapshot =
            inspect_resource_required(deps, snapshot_resource_id, "clear preflight snapshot")
                .await?;
        let (snapshot_version, snapshot_payload) =
            current_payload(&snapshot, "clear preflight snapshot replay")?;
        let stored_reason = record
            .pointer("/action/reason")
            .and_then(Value::as_str)
            .unwrap_or(&requested_reason)
            .to_owned();
        (
            existing.resource.clone(),
            version.clone(),
            record.clone(),
            snapshot.resource.clone(),
            snapshot_version.clone(),
            snapshot_payload.clone(),
            stored_reason,
        )
    } else {
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
        let record = action_record(ActionInput {
            action_id: &format!("clear-{idempotency_key}"),
            state: "requested",
            action_kind: "clear",
            reason: &requested_reason,
            actor_kind: actor_kind(invocation),
            scope: &scope,
            session_id: &session_id,
            snapshot_resource: &snapshot_resource,
            snapshot_version: &snapshot_version,
            expected_effect: "commit a new context epoch for the next agent run while keeping history/resources/traces inspectable",
            result: json!({
                "status": "requested",
                "timelineEventWritten": false,
                "boundaryPreparationDurable": true
            }),
            audit_refs: vec![version_ref(
                &snapshot_resource,
                &snapshot_version,
                "preflight_snapshot",
            )],
            created_at: &now,
            updated_at: &now,
            invocation,
            idempotency_key: &idempotency_key,
        });
        let (action_resource, action_version, action_payload) = create_action_resource(
            deps,
            invocation,
            &action_resource_id,
            "requested",
            record,
            "context-control-action:clear",
        )
        .await?;
        (
            action_resource,
            action_version,
            action_payload,
            snapshot_resource,
            snapshot_version,
            snapshot_payload,
            requested_reason,
        )
    };
    let estimated_tokens = snapshot_payload
        .pointer("/session/estimatedTokens")
        .and_then(Value::as_u64)
        .unwrap_or_default();
    let event = if let Some(event) = find_boundary_event(
        deps,
        &session_id,
        EventType::ContextCleared,
        &action_resource_id,
    )
    .await?
    {
        event
    } else {
        deps.event_store
            .append(&AppendOptions {
                session_id: &session_id,
                event_type: EventType::ContextCleared,
                payload: json!({
                    "tokensBefore": estimated_tokens,
                    "tokensAfter": 0,
                    "reason": reason.clone(),
                    "contextControlActionResourceId": &action_resource_id,
                    "contextControlActionVersionId": &action_version.version_id,
                    "contextControlSnapshotResourceId": &snapshot_resource.resource_id,
                    "boundaryInvocationId": invocation.id.as_str()
                }),
                parent_id: None,
                sequence: None,
            })
            .map_err(store_error)?
    };
    deps.session_manager.invalidate_session(&session_id);
    let epoch_id = format!("epoch-{}", event.sequence);
    let epoch_resource_id = epoch_resource_id(&session_id, &epoch_id);
    let epoch = if let Some(existing_epoch) = deps
        .engine_host
        .inspect_resource(&epoch_resource_id)
        .await
        .map_err(engine_error)?
    {
        let (version, _) = current_payload(&existing_epoch, "context clear epoch replay")?;
        (existing_epoch.resource.clone(), version.clone())
    } else {
        let epoch_payload = epoch_record(EpochInput {
            epoch_id: &epoch_id,
            scope: &scope,
            session_id: &session_id,
            boundary_event_id: &event.id,
            boundary_sequence: event.sequence,
            action_resource: &action_resource_id,
            created_at: &now,
        });
        match create_epoch_resource(
            deps,
            invocation,
            &epoch_resource_id,
            epoch_payload,
            &epoch_id,
        )
        .await
        {
            Ok((resource, version, _)) => (resource, version),
            Err(error) => {
                tracing::warn!(
                    resource_id = action_resource.resource_id,
                    event_id = event.id,
                    error = %error,
                    "context clear boundary committed with epoch finalization pending"
                );
                return Ok(boundary_committed_pending_response(
                    "context_control_clear",
                    &action_resource,
                    &action_version,
                    &action_payload,
                    &event,
                    "context.cleared",
                ));
            }
        }
    };
    let (epoch_resource, epoch_version) = epoch;
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
        expected_effect: "commit a new context epoch for the next agent run while keeping history/resources/traces inspectable",
        result: json!({
            "status": "succeeded",
            "tokensBefore": estimated_tokens,
            "tokensAfter": 0,
            "timelineEventWritten": true,
            "timelineEvent": event_ref(&event.id, event.sequence, "context.cleared"),
            "newEpoch": version_ref(&epoch_resource, &epoch_version, "created_epoch"),
            "historyStillInspectable": true,
            "priorTurnsExcludedFromProviderContext": true,
            "providerContextBoundaryCommitted": true,
            "providerContextAppliesOnNextAgentRun": true,
            "currentAgentRunMustStop": true
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
    let finalized = update_action_resource(
        deps,
        invocation,
        &action_resource_id,
        action_version.version_id.clone(),
        "succeeded",
        record,
    )
    .await;
    let (resource, version, payload) = match finalized {
        Ok(finalized) => finalized,
        Err(error) => {
            tracing::warn!(
                resource_id = action_resource.resource_id,
                event_id = event.id,
                error = %error,
                "context clear boundary committed with action finalization pending"
            );
            return Ok(boundary_committed_pending_response(
                "context_control_clear",
                &action_resource,
                &action_version,
                &action_payload,
                &event,
                "context.cleared",
            ));
        }
    };
    publish_action_lifecycle_best_effort(
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
    .await;
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

pub(crate) async fn survivor_record_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    policy_record_value_at(
        deps,
        invocation,
        payload,
        operation_at,
        PolicyRecordKind::Survivor,
    )
    .await
}

pub(crate) async fn exclusion_record_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    policy_record_value_at(
        deps,
        invocation,
        payload,
        operation_at,
        PolicyRecordKind::Exclusion,
    )
    .await
}

pub(crate) async fn survivor_list_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    policy_list_value(deps, invocation, payload, PolicyRecordKind::Survivor).await
}

pub(crate) async fn exclusion_list_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    policy_list_value(deps, invocation, payload, PolicyRecordKind::Exclusion).await
}

pub(crate) async fn survivor_disable_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    policy_disable_value_at(
        deps,
        invocation,
        payload,
        operation_at,
        PolicyRecordKind::Survivor,
        "contextSurvivorResourceId",
    )
    .await
}

pub(crate) async fn exclusion_disable_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    policy_disable_value_at(
        deps,
        invocation,
        payload,
        operation_at,
        PolicyRecordKind::Exclusion,
        "contextExclusionResourceId",
    )
    .await
}

pub(crate) async fn policy_snapshot_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    let (session_id, scope) = session_scope_for_invocation(
        invocation,
        optional_str(payload, "sessionId")?,
        "context_policy_snapshot",
    )?;
    ensure_authority(
        deps,
        invocation,
        "context_policy_snapshot",
        AccessMode::Write,
        &session_id,
        None,
    )
    .await?;
    let idempotency_key = idempotency_key(invocation, payload, "context_policy_snapshot")?;
    let resource_id = policy_snapshot_resource_id(&session_id, &idempotency_key);
    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_context_policy_snapshot(&existing, "context_policy_snapshot replay")?;
        ensure_scope(&existing, &scope, "context_policy_snapshot replay")?;
        let (version, record) = current_payload(&existing, "context_policy_snapshot replay")?;
        return Ok(policy_snapshot_response(
            &existing.resource,
            version,
            record,
            true,
        ));
    }

    let survivors = active_policy_summaries(deps, &scope, PolicyRecordKind::Survivor).await?;
    let exclusions = active_policy_summaries(deps, &scope, PolicyRecordKind::Exclusion).await?;
    let now = operation_at.to_rfc3339();
    let snapshot_id = format!("policy-snapshot-{idempotency_key}");
    let record = policy_snapshot_record(PolicySnapshotInput {
        policy_snapshot_id: &snapshot_id,
        scope: &scope,
        session_id: &session_id,
        survivor_refs: survivors,
        exclusion_refs: exclusions,
        created_at: &now,
        invocation,
        idempotency_key: &idempotency_key,
    });
    let (resource, version, payload) = create_policy_resource(
        deps,
        invocation,
        &resource_id,
        CONTEXT_POLICY_SNAPSHOT_KIND,
        CONTEXT_POLICY_SNAPSHOT_SCHEMA_ID,
        "available",
        record,
        "context-policy-snapshot",
    )
    .await?;
    publish_lifecycle_event(
        deps,
        invocation,
        "context_control.policy_snapshot_recorded",
        &resource,
        json!({"metadataOnly": true, "networkPolicy": "none"}),
    )
    .await?;
    Ok(policy_snapshot_response(
        &resource, &version, &payload, false,
    ))
}

#[derive(Clone, Copy)]
enum PolicyRecordKind {
    Survivor,
    Exclusion,
}

impl PolicyRecordKind {
    fn resource_kind(self) -> &'static str {
        match self {
            Self::Survivor => CONTEXT_SURVIVOR_KIND,
            Self::Exclusion => CONTEXT_EXCLUSION_KIND,
        }
    }

    fn schema_id(self) -> &'static str {
        match self {
            Self::Survivor => CONTEXT_SURVIVOR_SCHEMA_ID,
            Self::Exclusion => CONTEXT_EXCLUSION_SCHEMA_ID,
        }
    }

    fn operation_prefix(self) -> &'static str {
        match self {
            Self::Survivor => "context_survivor",
            Self::Exclusion => "context_exclusion",
        }
    }

    fn policy_kind(self) -> &'static str {
        match self {
            Self::Survivor => "survivor",
            Self::Exclusion => "exclusion",
        }
    }

    fn resource_id(self, session_id: &str, idempotency_key: &str) -> String {
        match self {
            Self::Survivor => survivor_resource_id(session_id, idempotency_key),
            Self::Exclusion => exclusion_resource_id(session_id, idempotency_key),
        }
    }
}

async fn policy_record_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
    kind: PolicyRecordKind,
) -> Result<Value, CapabilityError> {
    let operation = format!("{}_record", kind.operation_prefix());
    let (session_id, scope) =
        session_scope_for_invocation(invocation, optional_str(payload, "sessionId")?, &operation)?;
    ensure_authority(
        deps,
        invocation,
        &operation,
        AccessMode::Write,
        &session_id,
        None,
    )
    .await?;
    let idempotency_key = idempotency_key(invocation, payload, &operation)?;
    let resource_id = kind.resource_id(&session_id, &idempotency_key);
    if let Some(existing) = deps
        .engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_policy_kind(&existing, kind, &operation)?;
        ensure_scope(&existing, &scope, &operation)?;
        let (version, record) = current_payload(&existing, "context policy record replay")?;
        return Ok(policy_record_response(
            &operation,
            &existing.resource,
            version,
            record,
            true,
        ));
    }

    let target_kind = policy_target_kind(required_str(payload, "targetKind")?)?;
    let target_ref = policy_target_ref(&target_kind, required_str(payload, "targetRef")?)?;
    let label = bounded_text(
        "label",
        required_str(payload, "label")?,
        MAX_POLICY_LABEL_BYTES,
    )?;
    let reason = required_reason(payload, MAX_REASON_BYTES)?;
    let priority = optional_u64(payload, "priority")?.unwrap_or(50).min(100);
    let now = operation_at.to_rfc3339();
    let policy_id = format!("{}-{idempotency_key}", kind.policy_kind());
    let record = policy_record(PolicyRecordInput {
        policy_id: &policy_id,
        schema_version: schema_version_for_policy_kind(kind.resource_kind()),
        state: "active",
        policy_kind: kind.policy_kind(),
        scope: &scope,
        session_id: &session_id,
        target_kind: &target_kind,
        target_ref: &target_ref,
        label: &label,
        reason: &reason,
        priority,
        actor_kind: actor_kind(invocation),
        created_at: &now,
        updated_at: &now,
        invocation,
        idempotency_key: &idempotency_key,
        revision: 1,
    });
    let (resource, version, payload) = create_policy_resource(
        deps,
        invocation,
        &resource_id,
        kind.resource_kind(),
        kind.schema_id(),
        "active",
        record,
        &format!("context-policy-{}:{policy_id}", kind.policy_kind()),
    )
    .await?;
    publish_lifecycle_event(
        deps,
        invocation,
        &format!("context_control.{}_recorded", kind.policy_kind()),
        &resource,
        json!({"metadataOnly": true, "networkPolicy": "none"}),
    )
    .await?;
    Ok(policy_record_response(
        &operation, &resource, &version, &payload, false,
    ))
}

async fn policy_list_value(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    kind: PolicyRecordKind,
) -> Result<Value, CapabilityError> {
    let operation = format!("{}_list", kind.operation_prefix());
    let (session_id, scope) =
        session_scope_for_invocation(invocation, optional_str(payload, "sessionId")?, &operation)?;
    ensure_authority(
        deps,
        invocation,
        &operation,
        AccessMode::Read,
        &session_id,
        None,
    )
    .await?;
    let limit = optional_u64(payload, "limit")?
        .map(|value| value as usize)
        .unwrap_or(DEFAULT_LIST_LIMIT)
        .clamp(1, MAX_LIST_LIMIT);
    let records = active_policy_summaries(deps, &scope, kind).await?;
    if records.len() > limit {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "{} has {} active records, which exceeds requested limit {limit}; request a larger bounded limit or use context_policy_snapshot for a complete provider-safe policy packet",
                kind.resource_kind(),
                records.len()
            ),
        });
    }
    Ok(json!({
        "schemaVersion": schema_version_for_policy_kind(kind.resource_kind()),
        "operation": operation,
        "status": "ok",
        "sessionId": session_id,
        "projection": {
            "records": records,
            "limit": limit,
            "providerSafe": true
        }
    }))
}

async fn policy_disable_value_at(
    deps: &Deps,
    invocation: &Invocation,
    payload: &Value,
    operation_at: DateTime<Utc>,
    kind: PolicyRecordKind,
    resource_field: &str,
) -> Result<Value, CapabilityError> {
    let operation = format!("{}_disable", kind.operation_prefix());
    let (session_id, scope) =
        session_scope_for_invocation(invocation, optional_str(payload, "sessionId")?, &operation)?;
    let resource_id = required_str(payload, resource_field)?;
    ensure_authority(
        deps,
        invocation,
        &operation,
        AccessMode::Write,
        &session_id,
        Some(resource_id),
    )
    .await?;
    let reason = required_reason(payload, MAX_REASON_BYTES)?;
    let idempotency_key = idempotency_key(invocation, payload, &operation)?;
    let inspection = inspect_resource_required(deps, resource_id, "context policy").await?;
    ensure_policy_kind(&inspection, kind, &operation)?;
    ensure_scope(&inspection, &scope, &operation)?;
    let (version, payload_record) = current_payload(&inspection, &operation)?;
    if let Some(expected) = optional_str(payload, "expectedVersionId")?
        && expected != version.version_id
    {
        return Err(CapabilityError::InvalidParams {
            message: format!("{operation} expectedVersionId is stale"),
        });
    }
    if inspection.resource.lifecycle == "disabled" {
        let disabled_by = payload_record["idempotency"]["disabledBy"].as_str();
        if disabled_by == Some(idempotency_key.as_str()) {
            return Ok(policy_record_response(
                &operation,
                &inspection.resource,
                version,
                payload_record,
                true,
            ));
        }
        return Err(CapabilityError::InvalidParams {
            message: format!("{operation} already disabled by a different idempotencyKey"),
        });
    }
    let now = operation_at.to_rfc3339();
    let mut updated = payload_record.clone();
    updated["state"] = json!("disabled");
    updated["policy"]["disabledReason"] = json!(reason);
    updated["updatedAt"] = json!(now);
    updated["revision"] = json!(updated["revision"].as_u64().unwrap_or(1).saturating_add(1));
    updated["idempotency"] = json!({
        "disabledBy": idempotency_key,
        "previous": updated["idempotency"]
    });
    let new_version = update_policy_resource(
        deps,
        invocation,
        resource_id,
        version.version_id.clone(),
        updated.clone(),
    )
    .await?;
    let mut resource = inspection.resource.clone();
    resource.lifecycle = "disabled".to_owned();
    resource.current_version_id = Some(new_version.version_id.clone());
    publish_lifecycle_event(
        deps,
        invocation,
        &format!("context_control.{}_disabled", kind.policy_kind()),
        &resource,
        json!({"metadataOnly": true, "networkPolicy": "none"}),
    )
    .await?;
    Ok(policy_record_response(
        &operation,
        &resource,
        &new_version,
        &updated,
        false,
    ))
}

async fn active_policy_summaries(
    deps: &Deps,
    scope: &EngineResourceScope,
    kind: PolicyRecordKind,
) -> Result<Vec<Value>, CapabilityError> {
    let resources = deps
        .engine_host
        .scan_resources_internal(ListResources {
            kind: Some(kind.resource_kind().to_owned()),
            scope: Some(scope.clone()),
            lifecycle: Some("active".to_owned()),
            limit: MAX_LIST_LIMIT + 1,
        })
        .await
        .map_err(engine_error)?;
    if resources.len() > MAX_LIST_LIMIT {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "{} has more than {MAX_LIST_LIMIT} active records; disable stale context policy records before requesting a complete provider-safe projection",
                kind.resource_kind()
            ),
        });
    }
    let mut records = Vec::new();
    for resource in resources {
        if let Some(inspection) = deps
            .engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        {
            ensure_scope(&inspection, scope, "context_policy_snapshot")?;
            let (version, payload) = current_payload(&inspection, "context policy summary")?;
            records.push(policy_summary(&inspection.resource, version, payload));
        }
    }
    Ok(records)
}

fn ensure_policy_kind(
    inspection: &crate::engine::EngineResourceInspection,
    kind: PolicyRecordKind,
    operation: &str,
) -> Result<(), CapabilityError> {
    match kind {
        PolicyRecordKind::Survivor => ensure_context_survivor(inspection, operation),
        PolicyRecordKind::Exclusion => ensure_context_exclusion(inspection, operation),
    }
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
