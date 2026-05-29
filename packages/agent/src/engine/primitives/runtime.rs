//! Privileged primitive query runtime.
//!
//! Catalog, worker, and observability primitives need access to host-owned
//! catalog and ledger state. The response contracts live here so `EngineHost`
//! stays a coordinator rather than a primitive response bucket.

use serde_json::{Value, json};

use super::{catalog, control, observability, storage, ui, worker};
use crate::engine::approval::EngineApprovalRecord;
use crate::engine::discovery::{ActorContext, FunctionQuery};
use crate::engine::errors::{EngineError, Result};
use crate::engine::grants::{EngineGrant, ListGrants};
use crate::engine::ids::{InvocationId, TriggerId, WorkerId};
use crate::engine::invocation::{CausalContext, Invocation, InvocationRecord};
use crate::engine::leases::EngineResourceLease;
use crate::engine::resources::{
    CreateResource, EngineResource, EngineResourceInspection, EngineResourceTypeDefinition,
    EngineResourceVersion, ListResources, UpdateResource,
};
use crate::engine::streams::EngineStreamEvent;
use crate::engine::types::{
    CatalogChange, CatalogRevision, FunctionDefinition, TriggerDefinition, TriggerTypeDefinition,
    VisibilityScope, WorkerDefinition,
};
use crate::shared::logging::{LogLevel, LogQueryOptions, SortOrder};

pub(in crate::engine::primitives) struct TraceComponents {
    pub invocations: Vec<InvocationRecord>,
    pub catalog_changes: Vec<CatalogChange>,
    pub approvals: Vec<EngineApprovalRecord>,
    pub streams: Vec<EngineStreamEvent>,
    pub leases: Vec<EngineResourceLease>,
    pub compensation: Vec<Value>,
}

#[derive(Default)]
struct TraceAccumulator {
    invocation_count: usize,
    failed_invocations: usize,
    first_timestamp: Option<String>,
    last_timestamp: Option<String>,
    root_invocation_id: Option<String>,
    session_id: Option<String>,
    workspace_id: Option<String>,
}

/// Narrow host interface required by host-dispatched primitive workers.
pub(in crate::engine) trait PrimitiveRuntimeHost {
    fn catalog_revision(&self) -> CatalogRevision;
    fn discover_functions(&self, query: &FunctionQuery) -> Vec<FunctionDefinition>;
    fn visible_workers(&self, actor: &ActorContext) -> Vec<WorkerDefinition>;
    fn visible_triggers(&self, actor: &ActorContext) -> Vec<TriggerDefinition>;
    fn visible_trigger_types(&self, actor: &ActorContext) -> Vec<TriggerTypeDefinition>;
    fn inspect_catalog_item(&self, invocation: &Invocation) -> Result<Value>;
    fn watch_catalog_snapshot_base(&self, invocation: &Invocation) -> Result<Value>;
    fn inspect_worker(&self, id: &WorkerId) -> Result<WorkerDefinition>;
    fn worker_is_volatile(&self, id: &WorkerId) -> Option<bool>;
    fn unregister_worker(&mut self, id: &WorkerId, owner_actor: &str) -> Result<()>;
    fn invocations(&self) -> Vec<InvocationRecord>;
    fn ledger_catalog_changes(&self) -> Result<Vec<CatalogChange>>;
    fn approval_records_for_trace(&self, trace_id: &str) -> Result<Vec<EngineApprovalRecord>>;
    fn stream_records_for_trace(&self, trace_id: &str) -> Result<Vec<EngineStreamEvent>>;
    fn resource_leases_for_trace(&self, trace_id: &str) -> Result<Vec<EngineResourceLease>>;
    fn resource_lease(&self, lease_id: &str) -> Result<Option<EngineResourceLease>>;
    fn compensation_records_for_trace(&self, trace_id: &str) -> Result<Vec<Value>>;
    fn resource_type_definitions(&self) -> Result<Vec<EngineResourceTypeDefinition>>;
    fn list_resources(&self, filter: ListResources) -> Result<Vec<EngineResource>>;
    fn inspect_resource(&self, resource_id: &str) -> Result<Option<EngineResourceInspection>>;
    fn create_resource(&mut self, request: CreateResource) -> Result<EngineResource>;
    fn update_resource(&mut self, request: UpdateResource) -> Result<EngineResourceVersion>;
    fn list_grants(&self, filter: ListGrants) -> Result<Vec<EngineGrant>>;
    fn inspect_grant(
        &self,
        grant_id: &crate::engine::ids::AuthorityGrantId,
    ) -> Result<Option<EngineGrant>>;
    fn queue_items(
        &self,
        queue: &str,
        limit: usize,
    ) -> Result<Vec<crate::engine::queue::EngineQueueItem>>;
    fn approval_records(
        &self,
        status: Option<crate::engine::approval::ApprovalStatus>,
        session_id: Option<&str>,
        limit: usize,
    ) -> Result<Vec<EngineApprovalRecord>>;
    fn worker_count(&self) -> usize;
    fn function_count(&self) -> usize;
    fn trigger_count(&self) -> usize;
    fn trigger_type_count(&self) -> usize;
    fn catalog_change_count(&self) -> usize;
    fn storage_stats(&self) -> Result<crate::shared::storage::StorageStatsReport>;
    fn storage_checkpoint(&self) -> Result<crate::shared::storage::StorageCheckpointReport>;
    fn storage_export_snapshot(
        &self,
        snapshot_path: &str,
    ) -> Result<crate::shared::storage::StorageExportReport>;
    fn storage_retention_run(
        &self,
        dry_run: bool,
        verbose_retention_days: u64,
    ) -> Result<crate::shared::storage::StorageRetentionReport>;
    fn stored_log_values(
        &self,
        query: &LogQueryOptions,
        include_full_payloads: bool,
    ) -> Result<Vec<Value>>;
}

pub(in crate::engine) fn dispatch(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &Invocation,
) -> Result<Value> {
    match invocation.function_id.as_str() {
        catalog::LIST_FUNCTION => catalog_list(host, invocation),
        catalog::INSPECT_FUNCTION => host.inspect_catalog_item(invocation),
        catalog::WATCH_SNAPSHOT_FUNCTION => catalog_watch_snapshot(host, invocation),
        worker::LIST_FUNCTION => worker_list(host, invocation),
        worker::GET_FUNCTION => worker_get(host, invocation),
        worker::HEALTH_FUNCTION => worker_health(host, invocation),
        worker::DISCONNECT_FUNCTION => worker_disconnect(host, invocation),
        worker::PROTOCOL_GUIDE_FUNCTION => worker_protocol_guide(invocation),
        control::SNAPSHOT_FUNCTION | control::INSPECT_FUNCTION => {
            control::dispatch(host, invocation)
        }
        ui::CATALOG_FUNCTION
        | ui::CREATE_SURFACE_FUNCTION
        | ui::SURFACE_FOR_TARGET_FUNCTION
        | ui::UPDATE_SURFACE_FUNCTION
        | ui::INSPECT_SURFACE_FUNCTION
        | ui::VALIDATE_SURFACE_FUNCTION
        | ui::REFRESH_SURFACE_FUNCTION
        | ui::EXPIRE_SURFACE_FUNCTION
        | ui::DISCARD_SURFACE_FUNCTION
        | ui::SUBMIT_ACTION_FUNCTION => ui::dispatch(host, invocation),
        observability::TRACE_GET_FUNCTION => trace_get(host, invocation),
        observability::TRACE_LIST_FUNCTION => trace_list(host, invocation),
        observability::SPAN_LIST_FUNCTION => span_list(host, invocation),
        observability::LOG_QUERY_FUNCTION => log_query(host, invocation),
        observability::METRICS_SNAPSHOT_FUNCTION => metrics_snapshot(host),
        storage::STATS_FUNCTION => storage_stats(host),
        storage::CHECKPOINT_FUNCTION => storage_checkpoint(host),
        storage::EXPORT_SNAPSHOT_FUNCTION => storage_export_snapshot(host, invocation),
        storage::RETENTION_RUN_FUNCTION => storage_retention_run(host, invocation),
        _ => Err(EngineError::NotFound {
            kind: "function",
            id: invocation.function_id.to_string(),
        }),
    }
}

fn catalog_list(host: &dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let actor = actor_context(&invocation.causal_context);
    let query = FunctionQuery {
        actor: Some(actor.clone()),
        visibility: optional_visibility(invocation.payload.get("visibility"))?,
        namespace_prefix: optional_string(invocation.payload.get("namespacePrefix"))?,
        text: None,
        effect_class: None,
        max_risk: None,
        health: None,
        include_internal: invocation
            .payload
            .get("includeInternal")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    };
    Ok(json!({
        "catalogRevision": host.catalog_revision().0,
        "functions": host.discover_functions(&query),
        "workers": host.visible_workers(&actor),
        "triggers": host.visible_triggers(&actor),
        "triggerTypes": host.visible_trigger_types(&actor),
    }))
}

fn catalog_watch_snapshot(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &Invocation,
) -> Result<Value> {
    let response = host.watch_catalog_snapshot_base(invocation)?;
    let actor = actor_context(&invocation.causal_context);
    let query = FunctionQuery {
        actor: Some(actor.clone()),
        visibility: None,
        namespace_prefix: None,
        text: None,
        effect_class: None,
        max_risk: None,
        health: None,
        include_internal: false,
    };
    Ok(json!({
        "changes": response.get("changes").cloned().unwrap_or_else(|| json!([])),
        "snapshot": {
            "functions": host.discover_functions(&query),
            "workers": host.visible_workers(&actor),
            "triggers": host.visible_triggers(&actor),
            "triggerTypes": host.visible_trigger_types(&actor),
        },
        "currentRevision": response.get("currentRevision").cloned().unwrap_or(Value::Null),
        "nextRevision": response.get("nextRevision").cloned().unwrap_or(Value::Null),
        "hasMore": response.get("hasMore").cloned().unwrap_or(Value::Bool(false)),
    }))
}

fn worker_list(host: &dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let actor = actor_context(&invocation.causal_context);
    Ok(json!({
        "catalogRevision": host.catalog_revision().0,
        "workers": host.visible_workers(&actor),
    }))
}

fn worker_get(host: &dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let id = worker_id(required_str(&invocation.payload, "workerId")?)?;
    let actor = actor_context(&invocation.causal_context);
    let worker = host.inspect_worker(&id)?;
    if !is_visibility_visible(
        &worker.visibility,
        worker.provenance.session_id.as_deref(),
        worker.provenance.workspace_id.as_deref(),
        &actor,
    ) {
        return Err(EngineError::PolicyViolation(format!(
            "worker {id} is not visible"
        )));
    }
    Ok(json!({ "worker": worker }))
}

fn worker_health(host: &dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let id = worker_id(required_str(&invocation.payload, "workerId")?)?;
    let actor = actor_context(&invocation.causal_context);
    let worker = host.inspect_worker(&id)?;
    let functions = host
        .discover_functions(&FunctionQuery {
            actor: Some(actor),
            visibility: None,
            namespace_prefix: None,
            text: None,
            effect_class: None,
            max_risk: None,
            health: None,
            include_internal: true,
        })
        .into_iter()
        .filter(|function| function.owner_worker == id)
        .collect::<Vec<_>>();
    let triggers = host
        .visible_triggers(&actor_context(&invocation.causal_context))
        .into_iter()
        .filter(|trigger| trigger.owner_worker == id)
        .collect::<Vec<_>>();
    let health = if functions
        .iter()
        .any(|function| !function.health.is_routable())
    {
        "unhealthy"
    } else {
        "healthy"
    };
    Ok(json!({
        "worker": worker,
        "functions": functions,
        "triggers": triggers,
        "health": health,
    }))
}

fn worker_disconnect(
    host: &mut dyn PrimitiveRuntimeHost,
    invocation: &Invocation,
) -> Result<Value> {
    let id = worker_id(required_str(&invocation.payload, "workerId")?)?;
    if host.worker_is_volatile(&id) != Some(true) {
        return Err(EngineError::PolicyViolation(format!(
            "worker::disconnect can only disconnect volatile workers ({id})"
        )));
    }
    let worker = host.inspect_worker(&id)?;
    host.unregister_worker(&id, worker.owner_actor.as_str())?;
    Ok(json!({ "disconnected": true }))
}

fn worker_protocol_guide(invocation: &Invocation) -> Result<Value> {
    let requested_language = optional_string(invocation.payload.get("language"))?
        .unwrap_or_else(|| "python".to_owned())
        .to_ascii_lowercase();
    if !matches!(
        requested_language.as_str(),
        "python"
            | "python3"
            | "node"
            | "nodejs"
            | "node.js"
            | "javascript"
            | "typescript"
            | "ts"
            | "js"
    ) {
        return Err(EngineError::PolicyViolation(
            "worker::protocol_guide supports python plus common JavaScript/TypeScript aliases; the returned executable template is python".to_owned(),
        ));
    }
    let function_id = optional_string(invocation.payload.get("functionId"))?
        .unwrap_or_else(|| "demo::echo".to_owned());
    let worker_id = optional_string(invocation.payload.get("workerId"))?
        .unwrap_or_else(|| "demo-echo-worker".to_owned());
    let namespace = function_id
        .split_once("::")
        .map(|(namespace, _)| namespace)
        .filter(|namespace| !namespace.is_empty())
        .unwrap_or("demo");
    let protocol_version = crate::engine::protocol::WORKER_PROTOCOL_VERSION;
    let environment = json!({
        "TRON_ENGINE_WORKER_ENDPOINT": "Absolute WebSocket endpoint injected by worker::spawn, for example ws://127.0.0.1:9847/engine/workers",
        "TRON_ENGINE_BEARER_TOKEN": "Bearer token injected by worker::spawn; send it as Authorization: Bearer <token>",
        "TRON_ENGINE_WORKER_ID": "Stable worker id injected by worker::spawn",
        "TRON_ENGINE_WORKER_VISIBILITY": "session, workspace, or system",
        "TRON_ENGINE_WORKER_PROTOCOL_VERSION": protocol_version.to_string(),
        "TRON_ENGINE_WORKER_TOKEN": "Scoped worker-token JSON injected by worker::spawn; bounds pluginId, namespaceClaims, authorityGrantId, authorityGrantRevision, authorityGrantHash, resourceSelectors, visibilityCeiling, trustTier, scope binding, expiry, and signatureStatus",
        "TRON_ENGINE_SESSION_ID": "Present for session-visible sandbox workers",
        "TRON_ENGINE_WORKSPACE_ID": "Present for workspace-visible sandbox workers"
    });
    let message_flow = json!([
        "Open TRON_ENGINE_WORKER_ENDPOINT as a WebSocket with Authorization: Bearer ${TRON_ENGINE_BEARER_TOKEN}.",
        "Send a hello message with type=hello, protocolVersion, worker definition, identity, loopbackOnly=true, authPolicy=loopback_bearer, registrationMode=volatile, defaultVisibility, sessionId/workspaceId, heartbeatIntervalMs, supportedCapabilities, and workerToken.",
        "Receive catalog_snapshot from the engine. This is the live catalog visible to the worker at connect time.",
        "Send register_function for every capability the worker owns. Function definition fields use snake_case; the wrapper fields use camelCase.",
        "Handle invoke messages by executing exactly the requested function id, then send result with the same invocationId.",
        "Send heartbeat messages before the heartbeat interval expires.",
        "Send disconnect before clean exit. Volatile functions/triggers are removed from the live catalog."
    ]);
    let read_only_echo_minimum = json!({
        "id": function_id,
        "revision": 1,
        "owner_worker": worker_id,
        "description": "Echo one payload through an external sandbox worker",
        "request_schema": {"type":"object","additionalProperties":true},
        "response_schema": {"type":"object","additionalProperties":true},
        "opaque_response": false,
        "tags": ["demo", "echo", "sandbox-worker"],
        "visibility": "Session",
        "effect_class": "PureRead",
        "risk_level": "Low",
        "idempotency": null,
        "resource_lease": null,
        "compensation": null,
        "required_authority": {"scopes": [], "approval_required": false},
        "allowed_delivery_modes": ["Sync"],
        "health": "Healthy",
        "provenance": {"created_by": "system", "source": "sandbox-worker", "session_id": null, "workspace_id": null},
        "metadata": {
            "contractId": function_id,
            "implementationId": format!("session_generated.{namespace}.demo_echo"),
            "pluginId": format!("session_generated.{worker_id}"),
            "trustTier": "session_generated",
            "contextPrimerLevel": "catalog",
            "runtimeRequirements": {"workerKind": "sandbox", "deliveryModes": ["Sync"]},
            "examples": [{"payload": {"hello": "world"}}],
            "modelPrimitiveName": "demo_echo",
            "streamTopics": []
        }
    });
    let function_definition_shape = json!({
        "definitionFieldCase": "snake_case",
        "wrapperFieldCase": "camelCase",
        "workerKinds": ["External", "Sandbox"],
        "visibility": ["Session", "Workspace", "System"],
        "effectClass": ["PureRead", "DeterministicCompute", "IdempotentWrite", "AppendOnlyEvent", "ReversibleSideEffect", "ExternalSideEffect", "IrreversibleSideEffect"],
        "riskLevel": ["Low", "Medium", "High", "Critical"],
        "functionHealth": ["Healthy", "Degraded", "Unhealthy", "Unknown"],
        "deliveryMode": ["Sync", "Void", "Enqueue"],
        "readOnlyEchoMinimum": read_only_echo_minimum
    });
    let rules = json!([
        "Use this guide instead of searching Tron source when asked to register a worker or create capabilities.",
        "Every executable unit is a canonical namespace::function registered by exactly one worker.",
        "Worker registrations appear in catalog::list and capability::search after catalog change propagation.",
        "Mutating functions must declare idempotency and require callers to provide stable idempotency keys.",
        "Streams must be published through the worker protocol publish_stream message or stream::publish, never by writing directly to client sockets.",
        "Use sandbox::stop_spawned_worker or worker::disconnect to remove volatile capabilities."
    ]);

    Ok(json!({
        "protocolVersion": protocol_version,
        "endpoint": "/engine/workers",
        "requestedLanguage": requested_language,
        "templateLanguage": "python",
        "templateLanguageReason": "The current local sandbox worker template is Python because it runs with the standard library only and needs no package install step. JavaScript/TypeScript requests receive this Python template intentionally.",
        "environment": environment,
        "messageFlow": message_flow,
        "functionDefinitionShape": function_definition_shape,
        "pythonTemplate": python_worker_template(&worker_id, &function_id, namespace),
        "spawnWorkerPayloadExample": {
            "workerId": worker_id,
            "command": "python3",
            "args": ["demo_worker.py"],
            "workingDirectory": "/absolute/path/to/worker-directory",
            "expectedFunctionIds": [function_id],
            "visibility": "session",
            "timeoutMs": 10000
        },
        "rules": rules
    }))
}

fn trace_get(host: &dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let trace_id = required_str(&invocation.payload, "traceId")?;
    let include_full_payloads = invocation
        .payload
        .get("includeFullPayloads")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let trace = trace_components(host, trace_id)?;
    Ok(json!({
        "traceId": trace_id,
        "summary": trace_summary(trace_id, &trace),
        "invocations": trace.invocations.iter().map(|record| invocation_record_value(record, include_full_payloads)).collect::<Vec<_>>(),
        "catalogChanges": trace.catalog_changes.iter().map(catalog_change_value).collect::<Vec<_>>(),
        "streams": trace.streams.iter().map(|record| json!(record)).collect::<Vec<_>>(),
        "approvals": trace.approvals.iter().map(|record| json!(record)).collect::<Vec<_>>(),
        "leases": trace.leases,
        "compensation": trace.compensation,
    }))
}

fn storage_stats(host: &dyn PrimitiveRuntimeHost) -> Result<Value> {
    Ok(json!({ "stats": host.storage_stats()? }))
}

fn storage_checkpoint(host: &dyn PrimitiveRuntimeHost) -> Result<Value> {
    Ok(json!({ "checkpoint": host.storage_checkpoint()? }))
}

fn storage_export_snapshot(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &Invocation,
) -> Result<Value> {
    let snapshot_path = required_str(&invocation.payload, "snapshotPath")?;
    Ok(json!({ "export": host.storage_export_snapshot(snapshot_path)? }))
}

fn storage_retention_run(
    host: &dyn PrimitiveRuntimeHost,
    invocation: &Invocation,
) -> Result<Value> {
    let dry_run = invocation
        .payload
        .get("dryRun")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let verbose_retention_days =
        optional_u64(invocation.payload.get("verboseRetentionDays"))?.unwrap_or(7);
    Ok(json!({
        "retention": host.storage_retention_run(dry_run, verbose_retention_days)?
    }))
}

fn trace_list(host: &dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let limit = optional_u64(invocation.payload.get("limit"))?.unwrap_or(100) as usize;
    let session_id = optional_string(invocation.payload.get("sessionId"))?;
    let workspace_id = optional_string(invocation.payload.get("workspaceId"))?;
    let mut traces = std::collections::BTreeMap::<String, TraceAccumulator>::new();
    for record in host.invocations() {
        if session_id
            .as_deref()
            .is_some_and(|wanted| record.session_id.as_deref() != Some(wanted))
        {
            continue;
        }
        if workspace_id
            .as_deref()
            .is_some_and(|wanted| record.workspace_id.as_deref() != Some(wanted))
        {
            continue;
        }
        let entry = traces.entry(record.trace_id.to_string()).or_default();
        entry.invocation_count += 1;
        if !record.succeeded {
            entry.failed_invocations += 1;
        }
        if entry.session_id.is_none() {
            entry.session_id.clone_from(&record.session_id);
        }
        if entry.workspace_id.is_none() {
            entry.workspace_id.clone_from(&record.workspace_id);
        }
        if record.parent_invocation_id.is_none() && entry.root_invocation_id.is_none() {
            entry.root_invocation_id = Some(record.invocation_id.to_string());
        }
        observe_timestamp(entry, record.timestamp.to_rfc3339());
    }
    let mut traces = traces
        .into_iter()
        .map(|(trace_id, summary)| {
            json!({
                "traceId": trace_id,
                "invocationCount": summary.invocation_count,
                "failedInvocations": summary.failed_invocations,
                "status": if summary.failed_invocations > 0 { "error" } else { "ok" },
                "rootInvocationId": summary.root_invocation_id,
                "sessionId": summary.session_id,
                "workspaceId": summary.workspace_id,
                "firstTimestamp": summary.first_timestamp,
                "lastTimestamp": summary.last_timestamp,
            })
        })
        .collect::<Vec<_>>();
    traces.sort_by(|left, right| {
        right["lastTimestamp"]
            .as_str()
            .cmp(&left["lastTimestamp"].as_str())
    });
    traces.truncate(limit.min(500));
    Ok(json!({ "traces": traces }))
}

fn python_worker_template(worker_id: &str, function_id: &str, namespace: &str) -> String {
    const TEMPLATE: &str = r#"#!/usr/bin/env python3
import base64
import hashlib
import json
import os
import select
import socket
import ssl
import struct
import time
import urllib.parse

WORKER_ID = os.environ.get("TRON_ENGINE_WORKER_ID", __WORKER_ID__)
FUNCTION_ID = __FUNCTION_ID__
NAMESPACE = __NAMESPACE__
ENDPOINT = os.environ["TRON_ENGINE_WORKER_ENDPOINT"]
TOKEN = os.environ["TRON_ENGINE_BEARER_TOKEN"]
VISIBILITY = os.environ.get("TRON_ENGINE_WORKER_VISIBILITY", "session")
SESSION_ID = os.environ.get("TRON_ENGINE_SESSION_ID")
WORKSPACE_ID = os.environ.get("TRON_ENGINE_WORKSPACE_ID")
PROTOCOL_VERSION = int(os.environ.get("TRON_ENGINE_WORKER_PROTOCOL_VERSION", "1"))
WORKER_TOKEN = json.loads(os.environ.get("TRON_ENGINE_WORKER_TOKEN", json.dumps({
    "pluginId": "session_generated." + WORKER_ID,
    "namespaceClaims": [NAMESPACE],
    "authorityGrantId": "worker-runtime",
    "authorityGrantRevision": 1,
    "authorityGrantHash": "loopback-bootstrap",
    "resourceSelectors": ["*"],
    "visibilityCeiling": VISIBILITY,
    "trustTier": "session_generated",
    "sessionId": SESSION_ID,
    "workspaceId": WORKSPACE_ID,
    "expiresAt": None,
    "signatureStatus": "session_scoped",
})))

ENGINE_VISIBILITY = {"session": "Session", "workspace": "Workspace", "system": "System"}[VISIBILITY]
WORKER_VISIBILITY = {"session": "session", "workspace": "workspace", "system": "system"}[VISIBILITY]


def connect_websocket():
    endpoint = ENDPOINT.strip()
    if "://" not in endpoint:
        endpoint = "ws://" + endpoint
    url = urllib.parse.urlparse(endpoint)
    if url.scheme not in ("ws", "wss"):
        raise RuntimeError("TRON_ENGINE_WORKER_ENDPOINT must use ws:// or wss://")
    host = url.hostname or "127.0.0.1"
    port = url.port or (443 if url.scheme == "wss" else 80)
    path = url.path or "/engine/workers"
    if path.rstrip("/") == "/engine":
        path = "/engine/workers"
    elif path.rstrip("/") != "/engine/workers":
        raise RuntimeError(f"TRON_ENGINE_WORKER_ENDPOINT must target /engine/workers, got {path}")
    if url.query:
        path += "?" + url.query
    raw = socket.create_connection((host, port), timeout=10)
    if url.scheme == "wss":
        raw = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        f"Authorization: Bearer {TOKEN}\r\n"
        "\r\n"
    ).encode("ascii")
    raw.sendall(request)
    response = b""
    while b"\r\n\r\n" not in response:
        chunk = raw.recv(4096)
        if not chunk:
            raise RuntimeError("worker websocket closed during handshake")
        response += chunk
    if b" 101 " not in response.split(b"\r\n", 1)[0]:
        raise RuntimeError(response.decode("utf-8", "replace"))
    return raw


def read_exact(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError("worker websocket closed")
        data += chunk
    return data


def send_json(sock, value):
    payload = json.dumps(value, separators=(",", ":")).encode("utf-8")
    header = bytearray([0x81])
    if len(payload) < 126:
        header.append(0x80 | len(payload))
    elif len(payload) < 65536:
        header.append(0x80 | 126)
        header.extend(struct.pack("!H", len(payload)))
    else:
        header.append(0x80 | 127)
        header.extend(struct.pack("!Q", len(payload)))
    mask = os.urandom(4)
    header.extend(mask)
    masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    sock.sendall(header + masked)


def recv_json(sock):
    first, second = read_exact(sock, 2)
    opcode = first & 0x0F
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", read_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(sock, 8))[0]
    masked = bool(second & 0x80)
    mask = read_exact(sock, 4) if masked else b""
    payload = read_exact(sock, length)
    if masked:
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    if opcode == 8:
        raise EOFError("worker websocket close frame")
    if opcode == 9:
        sock.sendall(bytes([0x8A, 0x00]))
        return recv_json(sock)
    if opcode != 1:
        return recv_json(sock)
    return json.loads(payload.decode("utf-8"))


def scoped_provenance():
    return {
        "created_by": "system",
        "source": "sandbox-worker",
        "session_id": SESSION_ID,
        "workspace_id": WORKSPACE_ID,
    }


def worker_definition():
    return {
        "id": WORKER_ID,
        "revision": 1,
        "kind": "Sandbox",
        "lifecycle": "Ready",
        "owner_actor": "system",
        "authority_grant": WORKER_TOKEN["authorityGrantId"],
        "namespace_claims": [NAMESPACE],
        "visibility": ENGINE_VISIBILITY,
        "provenance": scoped_provenance(),
    }


def function_definition():
    return {
        "id": FUNCTION_ID,
        "revision": 1,
        "owner_worker": WORKER_ID,
        "description": "Echo one payload through a sandbox-created worker",
        "request_schema": {"type": "object", "additionalProperties": True},
        "response_schema": {"type": "object", "additionalProperties": True},
        "opaque_response": False,
        "output_contract": {"kind": "none"},
        "tags": ["demo", "echo", "sandbox-worker"],
        "visibility": ENGINE_VISIBILITY,
        "effect_class": "PureRead",
        "risk_level": "Low",
        "idempotency": None,
        "resource_lease": None,
        "compensation": None,
        "required_authority": {"scopes": [], "approval_required": False},
        "allowed_delivery_modes": ["Sync"],
        "health": "Healthy",
        "provenance": scoped_provenance(),
        "metadata": {
            "contractId": FUNCTION_ID,
            "implementationId": "session_generated." + NAMESPACE + ".demo_echo",
            "pluginId": "session_generated." + WORKER_ID,
            "trustTier": "session_generated",
            "contextPrimerLevel": "catalog",
            "runtimeRequirements": {"workerKind": "sandbox", "deliveryModes": ["Sync"]},
            "examples": [{"payload": {"hello": "world"}}],
            "modelPrimitiveName": "demo_echo",
            "streamTopics": []
        },
    }


def main():
    sock = connect_websocket()
    send_json(sock, {
        "type": "hello",
        "protocolVersion": PROTOCOL_VERSION,
        "worker": worker_definition(),
        "loopbackOnly": True,
        "identity": {
            "workerId": WORKER_ID,
            "workerName": WORKER_ID,
            "workerVersion": "demo-1",
            "sandboxed": True,
        },
        "authPolicy": "loopback_bearer",
        "registrationMode": "volatile",
        "defaultVisibility": WORKER_VISIBILITY,
        "sessionId": SESSION_ID,
        "workspaceId": WORKSPACE_ID,
        "heartbeatIntervalMs": 5000,
        "supportedCapabilities": [FUNCTION_ID],
        "workerToken": WORKER_TOKEN,
    })
    send_json(sock, {
        "type": "register_function",
        "definition": function_definition(),
        "defaultVisibility": ENGINE_VISIBILITY,
    })
    last_heartbeat = 0
    heartbeat_sequence = 0
    while True:
        now = time.monotonic()
        if now - last_heartbeat > 2.5:
            heartbeat_sequence += 1
            send_json(sock, {"type": "heartbeat", "workerId": WORKER_ID, "sequence": heartbeat_sequence})
            last_heartbeat = now
        ready, _, _ = select.select([sock], [], [], 0.25)
        if not ready:
            continue
        message = recv_json(sock)
        if message.get("type") == "invoke":
            invocation_id = message["invocationId"]
            if message.get("functionId") != FUNCTION_ID:
                send_json(sock, {"type": "result", "invocationId": invocation_id, "result": None, "error": {"message": "unknown function"}})
                continue
            payload = message.get("payload", {})
            send_json(sock, {
                "type": "result",
                "invocationId": invocation_id,
                "result": {"echo": payload, "workerId": WORKER_ID},
                "error": None,
            })
        elif message.get("type") == "disconnect":
            return


if __name__ == "__main__":
    main()
"#;
    TEMPLATE
        .replace(
            "__WORKER_ID__",
            &serde_json::to_string(worker_id).unwrap_or_else(|_| "\"demo-echo-worker\"".into()),
        )
        .replace(
            "__FUNCTION_ID__",
            &serde_json::to_string(function_id).unwrap_or_else(|_| "\"demo::echo\"".into()),
        )
        .replace(
            "__NAMESPACE__",
            &serde_json::to_string(namespace).unwrap_or_else(|_| "\"demo\"".into()),
        )
}

fn span_list(host: &dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let trace_id = required_str(&invocation.payload, "traceId")?;
    let trace = trace_components(host, trace_id)?;
    let mut spans = trace
        .invocations
        .iter()
        .map(|record| {
            json!({
                "spanId": record.invocation_id.as_str(),
                "parentSpanId": record.parent_invocation_id.as_ref().map(InvocationId::as_str),
                "kind": "invocation",
                "functionId": record.function_id.as_str(),
                "workerId": record.worker_id.as_str(),
                "triggerId": record.trigger_id.as_ref().map(TriggerId::as_str),
                "sessionId": record.session_id.as_deref(),
                "workspaceId": record.workspace_id.as_deref(),
                "status": if record.succeeded { "ok" } else { "error" },
                "succeeded": record.succeeded,
                "timestamp": record.timestamp.to_rfc3339(),
            })
        })
        .collect::<Vec<_>>();
    spans.extend(trace.streams.iter().map(|record| {
        json!({
            "spanId": format!("stream:{}", record.cursor.0),
            "parentSpanId": record.parent_invocation_id.as_ref().map(InvocationId::as_str),
            "kind": "stream",
            "topic": record.topic,
            "producer": record.producer,
            "status": "published",
            "timestamp": record.created_at.to_rfc3339(),
        })
    }));
    spans.extend(trace.approvals.iter().map(|record| {
        json!({
            "spanId": format!("approval:{}", record.approval_id),
            "parentSpanId": record.parent_invocation_id.as_ref().map(InvocationId::as_str),
            "kind": "approval",
            "functionId": record.function_id.as_str(),
            "status": record.status.as_str(),
            "timestamp": record.updated_at.to_rfc3339(),
        })
    }));
    spans.extend(trace.leases.iter().map(|record| {
        json!({
            "spanId": format!("lease:{}", record.lease_id),
            "parentSpanId": record.parent_invocation_id.as_ref().map(InvocationId::as_str),
            "kind": "resource_lease",
            "functionId": record.function_id.as_str(),
            "resourceKind": record.resource_kind,
            "resourceId": record.resource_id,
            "status": serde_json::to_value(&record.status).unwrap_or(Value::Null),
            "timestamp": record.acquired_at.to_rfc3339(),
        })
    }));
    spans.extend(trace.compensation.iter().map(|record| {
        json!({
            "spanId": record.get("compensationId").and_then(Value::as_str).map(|id| format!("compensation:{id}")),
            "parentSpanId": record.get("parentInvocationId").and_then(Value::as_str),
            "kind": "compensation",
            "functionId": record.get("functionId").and_then(Value::as_str),
            "status": record.get("status"),
            "timestamp": record.get("createdAt").and_then(Value::as_str),
        })
    }));
    spans.sort_by(|left, right| left["timestamp"].as_str().cmp(&right["timestamp"].as_str()));
    Ok(json!({ "traceId": trace_id, "spans": spans }))
}

fn log_query(host: &dyn PrimitiveRuntimeHost, invocation: &Invocation) -> Result<Value> {
    let trace_id = optional_string(invocation.payload.get("traceId"))?;
    let limit = optional_u64(invocation.payload.get("limit"))?.unwrap_or(100) as usize;
    let text = optional_string(invocation.payload.get("text"))?;
    let session_id = optional_string(invocation.payload.get("sessionId"))?;
    let workspace_id = optional_string(invocation.payload.get("workspaceId"))?;
    let origin = optional_string(invocation.payload.get("origin"))?;
    let component = optional_string(invocation.payload.get("component"))?;
    let min_level = optional_string(invocation.payload.get("minLevel"))?
        .map(|level| LogLevel::from_str_lossy(&level).as_num());
    let include_full_payloads = invocation
        .payload
        .get("includeFullPayloads")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let mut logs = Vec::new();
    logs.extend(host.stored_log_values(
        &LogQueryOptions {
            session_id,
            workspace_id,
            min_level,
            components: component.map(|component| vec![component]),
            trace_id: trace_id.clone(),
            limit: Some(limit.min(500)),
            offset: None,
            order: Some(SortOrder::Asc),
            origin,
        },
        include_full_payloads,
    )?);
    match trace_id.as_deref() {
        Some(trace_id) => {
            let trace = trace_components(host, trace_id)?;
            logs.extend(trace.invocations.iter().map(invocation_log_value));
            logs.extend(trace.streams.iter().map(stream_log_value));
            logs.extend(trace.approvals.iter().map(approval_log_value));
            logs.extend(trace.leases.iter().map(lease_log_value));
            logs.extend(trace.compensation.iter().map(compensation_log_value));
        }
        None => {
            logs.extend(host.invocations().iter().map(invocation_log_value));
        }
    }
    if let Some(text) = text {
        let needle = text.to_lowercase();
        logs.retain(|log| log_matches(log, &needle));
    }
    logs.sort_by(|left, right| left["timestamp"].as_str().cmp(&right["timestamp"].as_str()));
    logs.truncate(limit.min(500));
    Ok(json!({ "logs": logs }))
}

fn metrics_snapshot(host: &dyn PrimitiveRuntimeHost) -> Result<Value> {
    let invocations = host.invocations();
    let failed_invocations = invocations
        .iter()
        .filter(|record| !record.succeeded)
        .count();
    let trace_count = invocations
        .iter()
        .map(|record| record.trace_id.to_string())
        .collect::<std::collections::BTreeSet<_>>()
        .len();
    Ok(json!({
        "metrics": {
            "catalogRevision": host.catalog_revision().0,
            "workers": host.worker_count(),
            "functions": host.function_count(),
            "triggers": host.trigger_count(),
            "triggerTypes": host.trigger_type_count(),
            "invocations": invocations.len(),
            "succeededInvocations": invocations.len().saturating_sub(failed_invocations),
            "failedInvocations": failed_invocations,
            "traces": trace_count,
            "catalogChanges": host.catalog_change_count(),
        }
    }))
}

pub(in crate::engine::primitives) fn trace_components(
    host: &dyn PrimitiveRuntimeHost,
    trace_id: &str,
) -> Result<TraceComponents> {
    Ok(TraceComponents {
        invocations: host
            .invocations()
            .into_iter()
            .filter(|record| record.trace_id.as_str() == trace_id)
            .collect(),
        catalog_changes: host
            .ledger_catalog_changes()?
            .into_iter()
            .filter(|change| change.id.contains(trace_id) || change.subject_id.as_str() == trace_id)
            .collect(),
        approvals: host.approval_records_for_trace(trace_id)?,
        streams: host.stream_records_for_trace(trace_id)?,
        leases: host.resource_leases_for_trace(trace_id)?,
        compensation: host.compensation_records_for_trace(trace_id)?,
    })
}

pub(in crate::engine::primitives) fn trace_summary(
    trace_id: &str,
    trace: &TraceComponents,
) -> Value {
    let failed_invocations = trace
        .invocations
        .iter()
        .filter(|record| !record.succeeded)
        .count();
    let pending_approvals = trace
        .approvals
        .iter()
        .filter(|record| matches!(record.status.as_str(), "pending" | "approved"))
        .count();
    let failed_approvals = trace
        .approvals
        .iter()
        .filter(|record| matches!(record.status.as_str(), "denied" | "failed"))
        .count();
    let mut timestamps = trace_timestamps(trace);
    timestamps.sort();
    let root_invocation_id = trace
        .invocations
        .iter()
        .find(|record| record.parent_invocation_id.is_none())
        .or_else(|| trace.invocations.first())
        .map(|record| record.invocation_id.as_str());
    json!({
        "traceId": trace_id,
        "status": if failed_invocations > 0 || failed_approvals > 0 {
            "error"
        } else if pending_approvals > 0 {
            "pending"
        } else {
            "ok"
        },
        "rootInvocationId": root_invocation_id,
        "invocationCount": trace.invocations.len(),
        "failedInvocations": failed_invocations,
        "catalogChangeCount": trace.catalog_changes.len(),
        "streamCount": trace.streams.len(),
        "approvalCount": trace.approvals.len(),
        "pendingApprovalCount": pending_approvals,
        "leaseCount": trace.leases.len(),
        "compensationCount": trace.compensation.len(),
        "firstTimestamp": timestamps.first(),
        "lastTimestamp": timestamps.last(),
    })
}

fn trace_timestamps(trace: &TraceComponents) -> Vec<String> {
    let mut timestamps = Vec::new();
    timestamps.extend(
        trace
            .invocations
            .iter()
            .map(|record| record.timestamp.to_rfc3339()),
    );
    timestamps.extend(
        trace
            .catalog_changes
            .iter()
            .map(|record| record.timestamp.to_rfc3339()),
    );
    timestamps.extend(
        trace
            .streams
            .iter()
            .map(|record| record.created_at.to_rfc3339()),
    );
    timestamps.extend(
        trace
            .approvals
            .iter()
            .map(|record| record.updated_at.to_rfc3339()),
    );
    timestamps.extend(
        trace
            .leases
            .iter()
            .map(|record| record.acquired_at.to_rfc3339()),
    );
    timestamps.extend(trace.compensation.iter().filter_map(|record| {
        record
            .get("createdAt")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
    }));
    timestamps
}

fn observe_timestamp(summary: &mut TraceAccumulator, timestamp: String) {
    match summary.first_timestamp.as_ref() {
        Some(existing) if existing <= &timestamp => {}
        _ => summary.first_timestamp = Some(timestamp.clone()),
    }
    match summary.last_timestamp.as_ref() {
        Some(existing) if existing >= &timestamp => {}
        _ => summary.last_timestamp = Some(timestamp),
    }
}

fn invocation_log_value(record: &InvocationRecord) -> Value {
    json!({
        "timestamp": record.timestamp.to_rfc3339(),
        "traceId": record.trace_id.as_str(),
        "invocationId": record.invocation_id.as_str(),
        "kind": "invocation",
        "functionId": record.function_id.as_str(),
        "workerId": record.worker_id.as_str(),
        "level": if record.succeeded { "info" } else { "error" },
        "message": if record.succeeded { "engine invocation succeeded" } else { "engine invocation failed" },
        "error": record.error.as_ref().map(error_value),
    })
}

fn stream_log_value(record: &EngineStreamEvent) -> Value {
    json!({
        "timestamp": record.created_at.to_rfc3339(),
        "traceId": record.trace_id.as_ref().map(|id| id.as_str()),
        "kind": "stream",
        "level": "info",
        "topic": record.topic,
        "producer": record.producer,
        "message": "engine stream event published",
        "cursor": record.cursor.0,
    })
}

fn approval_log_value(record: &EngineApprovalRecord) -> Value {
    json!({
        "timestamp": record.updated_at.to_rfc3339(),
        "traceId": record.trace_id.as_str(),
        "kind": "approval",
        "level": if matches!(record.status.as_str(), "failed" | "denied") { "error" } else { "info" },
        "approvalId": record.approval_id,
        "functionId": record.function_id.as_str(),
        "message": format!("engine approval {}", record.status.as_str()),
        "error": record.error.as_ref().map(|error| json!(error)),
    })
}

fn lease_log_value(record: &EngineResourceLease) -> Value {
    json!({
        "timestamp": record.acquired_at.to_rfc3339(),
        "traceId": record.trace_id.as_str(),
        "kind": "resource_lease",
        "level": "info",
        "leaseId": record.lease_id,
        "functionId": record.function_id.as_str(),
        "resourceKind": record.resource_kind,
        "resourceId": record.resource_id,
        "message": "engine resource lease recorded",
    })
}

fn compensation_log_value(record: &Value) -> Value {
    json!({
        "timestamp": record.get("createdAt").and_then(Value::as_str),
        "traceId": record.get("traceId").and_then(Value::as_str),
        "kind": "compensation",
        "level": if record.get("succeeded").and_then(Value::as_bool).unwrap_or(true) { "info" } else { "error" },
        "compensationId": record.get("compensationId").and_then(Value::as_str),
        "functionId": record.get("functionId").and_then(Value::as_str),
        "message": "engine compensation record written",
        "error": record.get("error"),
    })
}

fn log_matches(log: &Value, needle: &str) -> bool {
    fn contains(value: &Value, needle: &str) -> bool {
        match value {
            Value::String(value) => value.to_lowercase().contains(needle),
            Value::Array(values) => values.iter().any(|value| contains(value, needle)),
            Value::Object(values) => values.values().any(|value| contains(value, needle)),
            _ => false,
        }
    }
    contains(log, needle)
}

pub(in crate::engine::primitives) fn actor_context(context: &CausalContext) -> ActorContext {
    ActorContext {
        actor_id: context.actor_id.clone(),
        actor_kind: context.actor_kind.clone(),
        authority_grant_id: context.authority_grant_id.clone(),
        authority_scopes: context.authority_scopes.clone(),
        session_id: context.session_id.clone(),
        workspace_id: context.workspace_id.clone(),
    }
}

fn is_visibility_visible(
    visibility: &VisibilityScope,
    session_id: Option<&str>,
    workspace_id: Option<&str>,
    actor: &ActorContext,
) -> bool {
    match visibility {
        VisibilityScope::Internal => actor.actor_kind.is_admin_like(),
        VisibilityScope::Session => {
            actor.actor_kind.is_admin_like()
                || matches!((actor.session_id.as_deref(), session_id), (Some(a), Some(b)) if a == b)
        }
        VisibilityScope::Workspace => {
            actor.actor_kind.is_admin_like()
                || matches!((actor.workspace_id.as_deref(), workspace_id), (Some(a), Some(b)) if a == b)
        }
        VisibilityScope::System => true,
        VisibilityScope::Client => {
            matches!(
                actor.actor_kind,
                crate::engine::discovery::ActorKind::Client
            ) || actor.actor_kind.is_admin_like()
        }
        VisibilityScope::Worker => {
            matches!(
                actor.actor_kind,
                crate::engine::discovery::ActorKind::Worker
            ) || actor.actor_kind.is_admin_like()
        }
        VisibilityScope::Agent => {
            matches!(actor.actor_kind, crate::engine::discovery::ActorKind::Agent)
                || actor.actor_kind.is_admin_like()
        }
        VisibilityScope::Admin => actor.actor_kind.is_admin_like(),
    }
}

fn catalog_change_value(change: &CatalogChange) -> Value {
    json!({
        "id": change.id.as_str(),
        "beforeRevision": change.before.0,
        "afterRevision": change.after.0,
        "kind": change_kind_str(&change.kind),
        "subjectId": change.subject_id.as_str(),
        "subjectKind": change.subject_kind.as_str(),
        "class": change.class.as_str(),
        "visibility": change.visibility.as_str(),
        "sessionId": change.session_id.as_deref(),
        "workspaceId": change.workspace_id.as_deref(),
        "ownerWorker": change.owner_worker.as_ref().map(WorkerId::as_str),
        "timestamp": change.timestamp.to_rfc3339(),
    })
}

pub(in crate::engine::primitives) fn invocation_record_value(
    record: &InvocationRecord,
    include_full_payloads: bool,
) -> Value {
    let mut value = json!({
        "invocationId": record.invocation_id.as_str(),
        "functionId": record.function_id.as_str(),
        "workerId": record.worker_id.as_str(),
        "functionRevision": record.function_revision.0,
        "catalogRevision": record.catalog_revision.0,
        "actorId": record.actor_id.as_str(),
        "actorKind": &record.actor_kind,
        "authorityGrantId": record.authority_grant_id.as_str(),
        "authorityScopes": &record.authority_scopes,
        "traceId": record.trace_id.as_str(),
        "parentInvocationId": record.parent_invocation_id.as_ref().map(InvocationId::as_str),
        "triggerId": record.trigger_id.as_ref().map(TriggerId::as_str),
        "sessionId": record.session_id.as_deref(),
        "workspaceId": record.workspace_id.as_deref(),
        "deliveryMode": record.delivery_mode.as_str(),
        "idempotencyKey": record.idempotency_key.as_deref(),
        "idempotencyScope": record.idempotency_scope.as_ref().map(|scope| {
            json!({"kind": scope.kind.as_str(), "value": scope.value.as_str()})
        }),
        "resourceLeaseIds": &record.resource_lease_ids,
        "compensationStatus": record.compensation_status.as_deref(),
        "producedResourceRefs": &record.produced_resource_refs,
        "replayedFrom": record.replayed_from.as_ref().map(InvocationId::as_str),
        "succeeded": record.succeeded,
        "error": record.error.as_ref().map(error_value),
        "timestamp": record.timestamp.to_rfc3339(),
    });
    if include_full_payloads {
        value["result"] = record.result_value.as_ref().cloned().unwrap_or(Value::Null);
    } else if let Some(result) = &record.result_value {
        let serialized = serde_json::to_string(result).unwrap_or_default();
        value["resultPreview"] = Value::String(compact_preview(&serialized, 512));
        value["resultSizeBytes"] = Value::Number(serde_json::Number::from(serialized.len() as u64));
        value["resultOmitted"] = Value::Bool(true);
    }
    value
}

fn error_value(error: &EngineError) -> Value {
    json!({
        "message": error.to_string(),
        "kind": format!("{error:?}"),
    })
}

fn compact_preview(value: &str, max_chars: usize) -> String {
    let mut preview = value.chars().take(max_chars).collect::<String>();
    if value.chars().count() > max_chars {
        preview.push_str("...");
    }
    preview
}

fn change_kind_str(kind: &crate::engine::types::CatalogChangeKind) -> &'static str {
    match kind {
        crate::engine::types::CatalogChangeKind::WorkerRegistered => "worker_registered",
        crate::engine::types::CatalogChangeKind::WorkerUpdated => "worker_updated",
        crate::engine::types::CatalogChangeKind::WorkerUnregistered => "worker_unregistered",
        crate::engine::types::CatalogChangeKind::FunctionRegistered => "function_registered",
        crate::engine::types::CatalogChangeKind::FunctionUpdated => "function_updated",
        crate::engine::types::CatalogChangeKind::FunctionUnregistered => "function_unregistered",
        crate::engine::types::CatalogChangeKind::TriggerTypeRegistered => "trigger_type_registered",
        crate::engine::types::CatalogChangeKind::TriggerTypeUpdated => "trigger_type_updated",
        crate::engine::types::CatalogChangeKind::TriggerTypeUnregistered => {
            "trigger_type_unregistered"
        }
        crate::engine::types::CatalogChangeKind::TriggerRegistered => "trigger_registered",
        crate::engine::types::CatalogChangeKind::TriggerUpdated => "trigger_updated",
        crate::engine::types::CatalogChangeKind::TriggerUnregistered => "trigger_unregistered",
        crate::engine::types::CatalogChangeKind::VisibilityChanged => "visibility_changed",
        crate::engine::types::CatalogChangeKind::HealthChanged => "health_changed",
    }
}

pub(in crate::engine::primitives) fn required_str<'a>(
    payload: &'a Value,
    field: &str,
) -> Result<&'a str> {
    payload.get(field).and_then(Value::as_str).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be a string"))
    })
}

fn optional_string(value: Option<&Value>) -> Result<Option<String>> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(other) => Err(EngineError::PolicyViolation(format!(
            "expected string, got {other}"
        ))),
    }
}

pub(in crate::engine::primitives) fn optional_u64(value: Option<&Value>) -> Result<Option<u64>> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(number)) => number
            .as_u64()
            .map(Some)
            .ok_or_else(|| EngineError::PolicyViolation("expected unsigned integer".to_owned())),
        Some(other) => Err(EngineError::PolicyViolation(format!(
            "expected integer, got {other}"
        ))),
    }
}

fn optional_visibility(value: Option<&Value>) -> Result<Option<VisibilityScope>> {
    optional_string(value)?
        .map(|value| match value.as_str() {
            "internal" => Ok(VisibilityScope::Internal),
            "session" => Ok(VisibilityScope::Session),
            "workspace" => Ok(VisibilityScope::Workspace),
            "system" => Ok(VisibilityScope::System),
            "client" => Ok(VisibilityScope::Client),
            "worker" => Ok(VisibilityScope::Worker),
            "agent" => Ok(VisibilityScope::Agent),
            "admin" => Ok(VisibilityScope::Admin),
            other => Err(EngineError::PolicyViolation(format!(
                "unknown visibility {other}"
            ))),
        })
        .transpose()
}

fn worker_id(value: &str) -> Result<WorkerId> {
    WorkerId::new(value.to_owned())
}
