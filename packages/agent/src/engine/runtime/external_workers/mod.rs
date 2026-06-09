//! Local external-worker runtime.
//!
//! This is deliberately loopback-only and protocol-bound. Local workers register
//! scoped functions/triggers, receive catalog snapshots, publish stream events
//! through the engine stream primitive, and are cleaned up by heartbeat and
//! disconnect policy. Volatile registrations disappear on disconnect or missed
//! heartbeat. Durable local registrations stay in the catalog but are marked
//! unhealthy until the worker reconnects and re-registers, so agents never
//! discover stale capabilities as runnable. Submodules own lifecycle state,
//! registration/stream publication, validation, and invocation proxying.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde_json::Value;

use crate::engine::catalog::discovery::{ActorContext, ActorKind, FunctionQuery};
use crate::engine::invocation::host::EngineHostHandle;
use crate::engine::invocation::model::{CausalContext, InProcessFunctionHandler, Invocation};
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, WorkerId,
};
use crate::engine::kernel::policy::ENGINE_INTERNAL_INVOKE_SCOPE;
use crate::engine::kernel::types::{
    DeliveryMode, FunctionDefinition, FunctionHealth, VisibilityScope, WorkerLifecycleState,
};
use crate::engine::runtime::worker_protocol::{
    CatalogSnapshot, RegisterFunction, RegisterTrigger, ScopedWorkerToken, WORKER_PROTOCOL_VERSION,
    WorkerCatalogChange, WorkerDisconnect, WorkerHealth, WorkerHeartbeat, WorkerHello,
    WorkerInvocationResult, WorkerInvoke, WorkerLifecycleEvent, WorkerProtocolMessage,
    WorkerRegistrationMode, WorkerStreamPublish, WorkerVisibility,
};

mod lifecycle;
mod proxy;
mod registration;
mod validation;

const WORKER_LIFECYCLE_TOPIC: &str = "worker.lifecycle";

/// Transport client used to invoke a connected local external worker.
#[async_trait]
pub trait ExternalWorkerInvoker: Send + Sync {
    /// Send one invocation to the worker and wait for its result.
    async fn invoke(&self, invoke: WorkerInvoke) -> Result<WorkerInvocationResult>;
}

/// Runtime state for one connected local external worker.
#[derive(Clone, Debug, PartialEq)]
pub struct ExternalWorkerConnection {
    /// Worker id.
    pub worker_id: WorkerId,
    /// Owner actor allowed to unregister the worker.
    pub owner_actor: ActorId,
    /// Last heartbeat sequence.
    pub heartbeat_sequence: u64,
    /// Last accepted heartbeat/hello timestamp.
    pub last_heartbeat_at: DateTime<Utc>,
    /// Protocol is loopback/local only.
    pub loopback_only: bool,
    /// Registration durability.
    pub registration_mode: WorkerRegistrationMode,
    /// Default visibility for registered entries.
    pub default_visibility: WorkerVisibility,
    /// Optional session scope.
    pub session_id: Option<String>,
    /// Optional workspace scope.
    pub workspace_id: Option<String>,
    /// Scoped token policy accepted at hello time.
    pub worker_token: ScopedWorkerToken,
    /// Current runtime health.
    pub health: WorkerHealth,
    /// Registered function ids.
    pub functions: BTreeSet<String>,
    /// Registered trigger ids.
    pub triggers: BTreeSet<String>,
}

/// In-process local external-worker runtime.
pub struct EngineExternalWorkerRuntime {
    host: EngineHostHandle,
    connections: BTreeMap<WorkerId, ExternalWorkerConnection>,
    invokers: BTreeMap<WorkerId, Arc<dyn ExternalWorkerInvoker>>,
}

impl EngineExternalWorkerRuntime {
    /// Create a runtime over an engine host.
    #[must_use]
    pub fn new(host: EngineHostHandle) -> Self {
        Self {
            host,
            connections: BTreeMap::new(),
            invokers: BTreeMap::new(),
        }
    }

    /// Handle a protocol message.
    pub async fn handle_message(
        &mut self,
        message: WorkerProtocolMessage,
    ) -> Result<Option<WorkerProtocolMessage>> {
        match message {
            WorkerProtocolMessage::Hello(hello) => {
                let snapshot = self.hello(*hello).await?;
                Ok(Some(WorkerProtocolMessage::CatalogSnapshot(snapshot)))
            }
            WorkerProtocolMessage::RegisterFunction(message) => {
                let change = self.register_function(*message).await?;
                Ok(Some(WorkerProtocolMessage::CatalogChange(change)))
            }
            WorkerProtocolMessage::RegisterTrigger(message) => {
                let change = self.register_trigger(message).await?;
                Ok(Some(WorkerProtocolMessage::CatalogChange(change)))
            }
            WorkerProtocolMessage::PublishStream(message) => {
                let change = self.publish_stream(message).await?;
                Ok(Some(WorkerProtocolMessage::CatalogChange(change)))
            }
            WorkerProtocolMessage::Heartbeat(message) => {
                self.heartbeat(message)?;
                Ok(None)
            }
            WorkerProtocolMessage::Disconnect(message) => {
                self.disconnect(message).await?;
                Ok(None)
            }
            WorkerProtocolMessage::Result(_)
            | WorkerProtocolMessage::Invoke(_)
            | WorkerProtocolMessage::CatalogSnapshot(_)
            | WorkerProtocolMessage::CatalogChange(_) => Ok(None),
        }
    }

    /// Convert a worker result message to an invocation result envelope.
    #[must_use]
    pub fn invocation_result_from_worker(
        invocation_id: InvocationId,
        result: WorkerInvocationResult,
    ) -> Value {
        serde_json::json!({
            "invocationId": invocation_id,
            "workerInvocationId": result.invocation_id,
            "result": result.result,
            "error": result.error,
        })
    }
}
