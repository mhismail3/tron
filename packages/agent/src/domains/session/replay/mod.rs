//! Canonical replay manifest builder for session-owned replay exports.
//!
//! Replay v1 is an audit/reconstruction snapshot. It reads durable session and
//! engine records, including idempotency entries, resolves stored JSON payload
//! references, computes byte-stable hashes with sorted object keys, and never
//! invokes providers, tools, queues, streams, files, processes, or resource
//! mutations. The sibling roundtrip harness accepts only a manifest value and
//! recomputes hashes/cross-record references offline.

use std::collections::BTreeMap;
use std::sync::Arc;

use serde::Serialize;
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::domains::session::event_store::types::EventType;
use crate::domains::session::event_store::{
    AgentTraceRecord, EventRow, EventStore, ListEventsOptions, SessionRow,
};
use crate::engine::EngineHostHandle;
use crate::engine::durability::ledger::{
    IdempotencyEntry, IdempotencyStatus, StoredInvocationOutcome,
};
use crate::engine::durability::queue::EngineQueueItem;
use crate::engine::durability::replay::EngineReplaySnapshot;
use crate::engine::durability::streams::EngineStreamEvent;
use crate::engine::invocation::model::InvocationRecord;
use crate::engine::kernel::types::ReplayBehavior;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::{self, CapabilityError};

#[cfg(test)]
mod roundtrip;

/// Canonical replay manifest wire format.
pub(crate) const REPLAY_MANIFEST_FORMAT: &str = "tron.replay.v1";

/// Dependencies required to build a replay manifest.
#[derive(Clone)]
pub(crate) struct ReplayDeps {
    event_store: Arc<EventStore>,
    engine_host: EngineHostHandle,
}

impl ReplayDeps {
    /// Build dependencies from session-owned runtime handles.
    pub(crate) fn new(event_store: Arc<EventStore>, engine_host: EngineHostHandle) -> Self {
        Self {
            event_store,
            engine_host,
        }
    }
}

#[derive(Debug)]
struct SessionReplaySnapshot {
    session: SessionRow,
    events: Vec<ReplaySessionEvent>,
    provider_audits: Vec<ReplayProviderAudit>,
    trace_records: Vec<AgentTraceRecord>,
}

/// Build the canonical replay manifest for one session.
pub(crate) async fn replay_manifest_value(
    deps: ReplayDeps,
    session_id: String,
) -> Result<Value, CapabilityError> {
    let session_snapshot =
        read_session_snapshot(deps.event_store.clone(), session_id.clone()).await?;
    let engine_snapshot = deps
        .engine_host
        .replay_snapshot(&session_id)
        .await
        .map_err(|error| CapabilityError::Internal {
            message: format!("engine replay snapshot failed: {error}"),
        })?;
    build_manifest_value(session_id, session_snapshot, engine_snapshot)
}

async fn read_session_snapshot(
    event_store: Arc<EventStore>,
    session_id: String,
) -> Result<SessionReplaySnapshot, CapabilityError> {
    run_blocking_task("session.replay_manifest", move || {
        let session = event_store
            .get_session(&session_id)
            .map_err(|error| CapabilityError::Internal {
                message: error.to_string(),
            })?
            .ok_or_else(|| CapabilityError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;

        let event_rows = event_store
            .get_events_by_session(&session_id, &ListEventsOptions::default())
            .map_err(|error| CapabilityError::Internal {
                message: error.to_string(),
            })?;
        let payloads = event_store
            .resolve_event_payloads(&event_rows)
            .map_err(|error| CapabilityError::Internal {
                message: error.to_string(),
            })?;
        let events = event_rows
            .into_iter()
            .zip(payloads)
            .map(|(row, payload)| ReplaySessionEvent::from_row(row, payload))
            .collect::<Vec<_>>();
        let provider_audits = events
            .iter()
            .filter(|event| event.event_type == EventType::ModelProviderRequest.as_str())
            .map(ReplayProviderAudit::from_event)
            .collect::<Vec<_>>();
        let trace_records = event_store
            .list_trace_records_for_replay(&session_id)
            .map_err(|error| CapabilityError::Internal {
                message: error.to_string(),
            })?;

        Ok(SessionReplaySnapshot {
            session,
            events,
            provider_audits,
            trace_records,
        })
    })
    .await
}

fn build_manifest_value(
    session_id: String,
    session_snapshot: SessionReplaySnapshot,
    engine_snapshot: EngineReplaySnapshot,
) -> Result<Value, CapabilityError> {
    let engine_invocations = engine_snapshot
        .invocations
        .iter()
        .map(ReplayInvocationRecord::from_record)
        .collect::<Result<Vec<_>, _>>()?;
    let engine_idempotency_entries = engine_snapshot
        .idempotency_entries
        .iter()
        .map(ReplayIdempotencyEntry::from_entry)
        .collect::<Result<Vec<_>, _>>()?;
    let engine_streams = engine_snapshot
        .streams
        .into_iter()
        .map(ReplayStreamEvent::from_event)
        .collect::<Result<Vec<_>, _>>()?;
    let engine_queue_items = engine_snapshot
        .queue_items
        .into_iter()
        .map(ReplayQueueItem::from_item)
        .collect::<Result<Vec<_>, _>>()?;
    let sections = ReplaySections {
        session: session_snapshot.session,
        session_events: session_snapshot.events,
        provider_audits: session_snapshot.provider_audits,
        trace_records: session_snapshot.trace_records,
        engine_idempotency_entries,
        engine_invocations,
        engine_streams,
        engine_queue_items,
    };
    let section_hashes = ReplaySectionHashes::from_sections(&sections)?;
    let manifest_without_hash = ReplayManifestWithoutHash {
        format: REPLAY_MANIFEST_FORMAT,
        session_id,
        sections,
        section_hashes,
    };
    let replay_hash = canonical_hash(&manifest_without_hash)?;
    let manifest = ReplayManifest {
        format: manifest_without_hash.format,
        session_id: manifest_without_hash.session_id,
        sections: manifest_without_hash.sections,
        section_hashes: manifest_without_hash.section_hashes,
        replay_hash,
    };
    canonical_value_from_serialize(&manifest)
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReplayManifestWithoutHash {
    format: &'static str,
    session_id: String,
    sections: ReplaySections,
    section_hashes: ReplaySectionHashes,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReplayManifest {
    format: &'static str,
    session_id: String,
    sections: ReplaySections,
    section_hashes: ReplaySectionHashes,
    replay_hash: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReplaySections {
    session: SessionRow,
    session_events: Vec<ReplaySessionEvent>,
    provider_audits: Vec<ReplayProviderAudit>,
    trace_records: Vec<AgentTraceRecord>,
    engine_idempotency_entries: Vec<ReplayIdempotencyEntry>,
    engine_invocations: Vec<ReplayInvocationRecord>,
    engine_streams: Vec<ReplayStreamEvent>,
    engine_queue_items: Vec<ReplayQueueItem>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReplaySectionHashes {
    session: String,
    session_events: String,
    provider_audits: String,
    trace_records: String,
    engine_idempotency_entries: String,
    engine_invocations: String,
    engine_streams: String,
    engine_queue_items: String,
}

impl ReplaySectionHashes {
    fn from_sections(sections: &ReplaySections) -> Result<Self, CapabilityError> {
        Ok(Self {
            session: canonical_hash(&sections.session)?,
            session_events: canonical_hash(&sections.session_events)?,
            provider_audits: canonical_hash(&sections.provider_audits)?,
            trace_records: canonical_hash(&sections.trace_records)?,
            engine_idempotency_entries: canonical_hash(&sections.engine_idempotency_entries)?,
            engine_invocations: canonical_hash(&sections.engine_invocations)?,
            engine_streams: canonical_hash(&sections.engine_streams)?,
            engine_queue_items: canonical_hash(&sections.engine_queue_items)?,
        })
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReplaySessionEvent {
    id: String,
    session_id: String,
    parent_id: Option<String>,
    sequence: i64,
    depth: i64,
    #[serde(rename = "type")]
    event_type: String,
    timestamp: String,
    payload: Value,
    content_blob_id: Option<String>,
    workspace_id: String,
    role: Option<String>,
    model_primitive_name: Option<String>,
    invocation_id: Option<String>,
    turn: Option<i64>,
    input_tokens: Option<i64>,
    output_tokens: Option<i64>,
    cache_read_tokens: Option<i64>,
    cache_creation_tokens: Option<i64>,
    checksum: Option<String>,
    model: Option<String>,
    latency_ms: Option<i64>,
    stop_reason: Option<String>,
    has_thinking: Option<i64>,
    provider_type: Option<String>,
    cost: Option<f64>,
}

impl ReplaySessionEvent {
    fn from_row(row: EventRow, payload: Value) -> Self {
        Self {
            id: row.id,
            session_id: row.session_id,
            parent_id: row.parent_id,
            sequence: row.sequence,
            depth: row.depth,
            event_type: row.event_type,
            timestamp: row.timestamp,
            payload,
            content_blob_id: row.content_blob_id,
            workspace_id: row.workspace_id,
            role: row.role,
            model_primitive_name: row.model_primitive_name,
            invocation_id: row.invocation_id,
            turn: row.turn,
            input_tokens: row.input_tokens,
            output_tokens: row.output_tokens,
            cache_read_tokens: row.cache_read_tokens,
            cache_creation_tokens: row.cache_creation_tokens,
            checksum: row.checksum,
            model: row.model,
            latency_ms: row.latency_ms,
            stop_reason: row.stop_reason,
            has_thinking: row.has_thinking,
            provider_type: row.provider_type,
            cost: row.cost,
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReplayProviderAudit {
    event_id: String,
    sequence: i64,
    audit: Value,
}

impl ReplayProviderAudit {
    fn from_event(event: &ReplaySessionEvent) -> Self {
        Self {
            event_id: event.id.clone(),
            sequence: event.sequence,
            audit: event.payload.clone(),
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReplayIdempotencyEntry {
    function_id: String,
    scope: ReplayIdempotencyScope,
    key: String,
    payload_fingerprint: String,
    request_hash: String,
    function_revision: u64,
    replay_behavior: String,
    status: String,
    first_invocation_id: String,
    latest_invocation_id: String,
    outcome: Option<StoredInvocationOutcome>,
    outcome_hash: Option<String>,
    created_at: String,
    updated_at: String,
}

impl ReplayIdempotencyEntry {
    fn from_entry(entry: &IdempotencyEntry) -> Result<Self, CapabilityError> {
        Ok(Self {
            function_id: entry.key.function_id.to_string(),
            scope: ReplayIdempotencyScope::from_scope(&entry.key.scope),
            key: entry.key.key.clone(),
            payload_fingerprint: entry.payload_fingerprint.clone(),
            request_hash: entry.payload_fingerprint.clone(),
            function_revision: entry.function_revision.0,
            replay_behavior: replay_behavior_name(&entry.replay_behavior).to_owned(),
            status: idempotency_status_name(entry.status).to_owned(),
            first_invocation_id: entry.first_invocation_id.to_string(),
            latest_invocation_id: entry.latest_invocation_id.to_string(),
            outcome: entry.outcome.clone(),
            outcome_hash: entry.outcome.as_ref().map(canonical_hash).transpose()?,
            created_at: entry.created_at.to_rfc3339(),
            updated_at: entry.updated_at.to_rfc3339(),
        })
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReplayInvocationRecord {
    invocation_id: String,
    function_id: String,
    worker_id: String,
    function_revision: u64,
    catalog_revision: u64,
    actor_id: String,
    actor_kind: Value,
    authority_grant_id: String,
    authority_scopes: Vec<String>,
    trace_id: String,
    parent_invocation_id: Option<String>,
    trigger_id: Option<String>,
    session_id: Option<String>,
    workspace_id: Option<String>,
    delivery_mode: Value,
    idempotency_key: Option<String>,
    idempotency_scope: Option<ReplayIdempotencyScope>,
    resource_lease_ids: Vec<String>,
    compensation_status: Option<String>,
    produced_resource_refs: Vec<Value>,
    replayed_from: Option<String>,
    succeeded: bool,
    result_value: Option<Value>,
    error: Option<Value>,
    result_hash: Option<String>,
    timestamp: String,
}

impl ReplayInvocationRecord {
    fn from_record(record: &InvocationRecord) -> Result<Self, CapabilityError> {
        let error = record.error.as_ref().map(engine_error_value);
        let result_hash = invocation_result_hash(record.result_value.as_ref(), error.as_ref())?;
        Ok(Self {
            invocation_id: record.invocation_id.to_string(),
            function_id: record.function_id.to_string(),
            worker_id: record.worker_id.to_string(),
            function_revision: record.function_revision.0,
            catalog_revision: record.catalog_revision.0,
            actor_id: record.actor_id.to_string(),
            actor_kind: serde_json::to_value(&record.actor_kind).unwrap_or(Value::Null),
            authority_grant_id: record.authority_grant_id.to_string(),
            authority_scopes: record.authority_scopes.clone(),
            trace_id: record.trace_id.to_string(),
            parent_invocation_id: record
                .parent_invocation_id
                .as_ref()
                .map(ToString::to_string),
            trigger_id: record.trigger_id.as_ref().map(ToString::to_string),
            session_id: record.session_id.clone(),
            workspace_id: record.workspace_id.clone(),
            delivery_mode: serde_json::to_value(&record.delivery_mode).unwrap_or(Value::Null),
            idempotency_key: record.idempotency_key.clone(),
            idempotency_scope: record
                .idempotency_scope
                .as_ref()
                .map(ReplayIdempotencyScope::from_scope),
            resource_lease_ids: record.resource_lease_ids.clone(),
            compensation_status: record.compensation_status.clone(),
            produced_resource_refs: record.produced_resource_refs.clone(),
            replayed_from: record.replayed_from.as_ref().map(ToString::to_string),
            succeeded: record.succeeded,
            result_value: record.result_value.clone(),
            error,
            result_hash,
            timestamp: record.timestamp.to_rfc3339(),
        })
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReplayStreamEvent {
    #[serde(flatten)]
    event: EngineStreamEvent,
    payload_hash: String,
}

impl ReplayStreamEvent {
    fn from_event(event: EngineStreamEvent) -> Result<Self, CapabilityError> {
        let payload_hash = canonical_hash(&event.payload)?;
        Ok(Self {
            event,
            payload_hash,
        })
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReplayQueueItem {
    #[serde(flatten)]
    item: EngineQueueItem,
    payload_hash: String,
}

impl ReplayQueueItem {
    fn from_item(item: EngineQueueItem) -> Result<Self, CapabilityError> {
        let payload_hash = canonical_hash(&item.payload)?;
        Ok(Self { item, payload_hash })
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReplayIdempotencyScope {
    kind: String,
    value: String,
}

impl ReplayIdempotencyScope {
    fn from_scope(scope: &crate::engine::kernel::types::IdempotencyScope) -> Self {
        Self {
            kind: scope.kind.clone(),
            value: scope.value.clone(),
        }
    }
}

fn idempotency_status_name(status: IdempotencyStatus) -> &'static str {
    match status {
        IdempotencyStatus::InProgress => "in_progress",
        IdempotencyStatus::Completed => "completed",
        IdempotencyStatus::Unknown => "unknown",
    }
}

fn replay_behavior_name(behavior: &ReplayBehavior) -> &'static str {
    match behavior {
        ReplayBehavior::ReturnPrevious => "return_previous",
        ReplayBehavior::NoOp => "no_op",
        ReplayBehavior::Reject => "reject",
        ReplayBehavior::Compensate => "compensate",
    }
}

fn invocation_result_hash(
    result_value: Option<&Value>,
    error: Option<&Value>,
) -> Result<Option<String>, CapabilityError> {
    match (result_value, error) {
        (Some(value), None) => canonical_hash(value).map(Some),
        (_, Some(error)) => canonical_hash(error).map(Some),
        (None, None) => Ok(None),
    }
}

fn engine_error_value(error: &crate::engine::EngineError) -> Value {
    match error {
        crate::engine::EngineError::InvalidId { kind, value } => {
            json!({"kind": "invalid_id", "idKind": kind, "value": value})
        }
        crate::engine::EngineError::InvalidFunctionId(value) => {
            json!({"kind": "invalid_function_id", "value": value})
        }
        crate::engine::EngineError::NotFound { kind, id } => {
            json!({"kind": "not_found", "itemKind": kind, "id": id})
        }
        crate::engine::EngineError::OwnerMismatch {
            kind,
            id,
            owner,
            attempted_owner,
        } => json!({
            "kind": "owner_mismatch",
            "itemKind": kind,
            "id": id,
            "owner": owner,
            "attemptedOwner": attempted_owner
        }),
        crate::engine::EngineError::NamespaceDenied {
            worker_id,
            function_id,
        } => json!({
            "kind": "namespace_denied",
            "workerId": worker_id,
            "functionId": function_id
        }),
        crate::engine::EngineError::UnsupportedDeliveryMode { mode } => {
            json!({"kind": "unsupported_delivery_mode", "mode": mode})
        }
        crate::engine::EngineError::DeliveryModeNotAllowed { function_id, mode } => {
            json!({"kind": "delivery_mode_not_allowed", "functionId": function_id, "mode": mode})
        }
        crate::engine::EngineError::IdempotencyConflict {
            function_id,
            key,
            reason,
        } => json!({
            "kind": "idempotency_conflict",
            "functionId": function_id,
            "key": key,
            "reason": reason
        }),
        crate::engine::EngineError::LedgerFailure { operation, message } => {
            json!({"kind": "ledger_failure", "operation": operation, "message": message})
        }
        crate::engine::EngineError::StoredInvocationError { kind, message } => {
            json!({"kind": "stored_invocation_error", "storedKind": kind, "message": message})
        }
        crate::engine::EngineError::InvalidSchema {
            function_id,
            direction,
            message,
        } => json!({
            "kind": "invalid_schema",
            "functionId": function_id,
            "direction": direction,
            "message": message
        }),
        crate::engine::EngineError::SchemaViolation {
            function_id,
            direction,
            path,
            message,
        } => json!({
            "kind": "schema_violation",
            "functionId": function_id,
            "direction": direction,
            "path": path,
            "message": message
        }),
        crate::engine::EngineError::InvalidVisibilityPromotion {
            function_id,
            target,
            reason,
        } => json!({
            "kind": "invalid_visibility_promotion",
            "functionId": function_id,
            "target": target,
            "reason": reason
        }),
        crate::engine::EngineError::PolicyViolation(message) => {
            json!({"kind": "policy_violation", "message": message})
        }
        crate::engine::EngineError::NotRoutable {
            function_id,
            reason,
        } => json!({"kind": "not_routable", "functionId": function_id, "reason": reason}),
        crate::engine::EngineError::DomainFailure {
            domain,
            code,
            message,
            details,
        } => json!({
            "kind": "domain_failure",
            "domain": domain,
            "code": code,
            "message": message,
            "details": details
        }),
        crate::engine::EngineError::WorkerTransportFailure { code, message } => {
            json!({"kind": "worker_transport_failure", "code": code, "message": message})
        }
        crate::engine::EngineError::HandlerFailed(message) => {
            json!({"kind": "handler_failed", "message": message})
        }
    }
}

fn canonical_hash<T: Serialize>(value: &T) -> Result<String, CapabilityError> {
    let canonical = canonical_value_from_serialize(value)?;
    let bytes = serde_json::to_vec(&canonical).map_err(|error| CapabilityError::Internal {
        message: format!("canonical JSON serialization failed: {error}"),
    })?;
    let digest = Sha256::digest(&bytes);
    Ok(hex::encode(digest))
}

fn canonical_value_from_serialize<T: Serialize>(value: &T) -> Result<Value, CapabilityError> {
    serde_json::to_value(value)
        .map(canonicalize_value)
        .map_err(|error| CapabilityError::Internal {
            message: format!("replay manifest serialization failed: {error}"),
        })
}

fn canonicalize_value(value: Value) -> Value {
    match value {
        Value::Object(object) => {
            let sorted = object
                .into_iter()
                .map(|(key, value)| (key, canonicalize_value(value)))
                .collect::<BTreeMap<_, _>>();
            let mut canonical = Map::new();
            for (key, value) in sorted {
                canonical.insert(key, value);
            }
            Value::Object(canonical)
        }
        Value::Array(values) => Value::Array(
            values
                .into_iter()
                .map(canonicalize_value)
                .collect::<Vec<_>>(),
        ),
        other => other,
    }
}

#[cfg(test)]
mod tests;
