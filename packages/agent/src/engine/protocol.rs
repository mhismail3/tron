//! Loopback external-worker protocol types.
//!
//! This module is protocol-only in this package. It defines the local JSON
//! message envelope future external workers will use, without opening sockets
//! or executing untrusted code.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::discovery::ActorKind;
use super::ids::{FunctionId, InvocationId, TraceId, TriggerId, WorkerId};
use super::types::{FunctionDefinition, TriggerDefinition, VisibilityScope, WorkerDefinition};

/// Protocol version used by the first local worker wire contract.
pub const WORKER_PROTOCOL_VERSION: u16 = 1;

/// External worker message.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum WorkerProtocolMessage {
    /// Worker hello/handshake.
    Hello(WorkerHello),
    /// Engine catalog snapshot.
    CatalogSnapshot(CatalogSnapshot),
    /// Worker registers one function.
    RegisterFunction(RegisterFunction),
    /// Worker registers one trigger.
    RegisterTrigger(RegisterTrigger),
    /// Engine asks a worker to invoke a function.
    Invoke(WorkerInvoke),
    /// Worker returns an invocation result.
    Result(WorkerInvocationResult),
    /// Engine broadcasts a catalog change.
    CatalogChange(WorkerCatalogChange),
    /// Liveness heartbeat.
    Heartbeat(WorkerHeartbeat),
    /// Worker or engine disconnect notice.
    Disconnect(WorkerDisconnect),
}

/// Worker hello/handshake.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerHello {
    /// Protocol version.
    pub protocol_version: u16,
    /// Worker definition.
    pub worker: WorkerDefinition,
    /// Whether the connection is loopback/local-only.
    pub loopback_only: bool,
}

/// Catalog snapshot sent after connection.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogSnapshot {
    /// Visible functions.
    pub functions: Vec<FunctionDefinition>,
    /// Visible triggers.
    pub triggers: Vec<TriggerDefinition>,
}

/// Function registration message.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterFunction {
    /// Function definition.
    pub definition: FunctionDefinition,
    /// Default visibility for external workers.
    pub default_visibility: VisibilityScope,
}

/// Trigger registration message.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterTrigger {
    /// Trigger definition.
    pub definition: TriggerDefinition,
}

/// Invocation request sent to an external worker.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerInvoke {
    /// Invocation id.
    pub invocation_id: InvocationId,
    /// Target function id.
    pub function_id: FunctionId,
    /// Payload.
    pub payload: Value,
    /// Actor kind.
    pub actor_kind: ActorKind,
    /// Trace id.
    pub trace_id: TraceId,
    /// Optional trigger id.
    pub trigger_id: Option<TriggerId>,
}

/// Invocation result from an external worker.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerInvocationResult {
    /// Invocation id.
    pub invocation_id: InvocationId,
    /// JSON result, if successful.
    pub result: Option<Value>,
    /// Structured error, if failed.
    pub error: Option<Value>,
}

/// Catalog change notice.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerCatalogChange {
    /// Changed subject id.
    pub subject_id: String,
    /// Owner worker.
    pub owner_worker: WorkerId,
    /// Change kind string.
    pub kind: String,
}

/// Heartbeat message.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerHeartbeat {
    /// Worker id.
    pub worker_id: WorkerId,
    /// Monotonic sequence.
    pub sequence: u64,
}

/// Disconnect notice.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkerDisconnect {
    /// Worker id.
    pub worker_id: WorkerId,
    /// Human-readable reason.
    pub reason: String,
}
