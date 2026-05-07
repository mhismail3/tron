//! Local external-worker runtime foundation.
//!
//! This is deliberately loopback-only and protocol-bound. It gives tests and
//! future local worker processes a small runtime for registering volatile
//! session-scoped functions/triggers, receiving catalog snapshots, heartbeat
//! liveness, and disconnect cleanup without opening remote execution or
//! sandboxing yet.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use async_trait::async_trait;
use serde_json::Value;

use super::discovery::{ActorContext, ActorKind, FunctionQuery};
use super::errors::{EngineError, Result};
use super::host::EngineHostHandle;
use super::ids::{ActorId, InvocationId, WorkerId};
use super::invocation::{InProcessFunctionHandler, Invocation};
use super::protocol::{
    CatalogSnapshot, RegisterFunction, RegisterTrigger, WORKER_PROTOCOL_VERSION,
    WorkerCatalogChange, WorkerDisconnect, WorkerHeartbeat, WorkerHello, WorkerInvocationResult,
    WorkerInvoke, WorkerProtocolMessage,
};
use super::types::VisibilityScope;

/// Transport adapter used to invoke a connected local external worker.
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
    /// Protocol is loopback/local only.
    pub loopback_only: bool,
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

    /// Attach an executable transport proxy for a connected worker.
    pub fn attach_invoker(
        &mut self,
        worker_id: WorkerId,
        invoker: Arc<dyn ExternalWorkerInvoker>,
    ) -> Result<()> {
        if !self.connections.contains_key(&worker_id) {
            return Err(EngineError::NotFound {
                kind: "external worker connection",
                id: worker_id.to_string(),
            });
        }
        self.invokers.insert(worker_id, invoker);
        Ok(())
    }

    /// Accept a worker hello and return a catalog snapshot visible to the
    /// worker. Non-loopback workers are rejected until the sandbox/runtime
    /// security model exists.
    pub async fn hello(&mut self, hello: WorkerHello) -> Result<CatalogSnapshot> {
        if hello.protocol_version != WORKER_PROTOCOL_VERSION {
            return Err(EngineError::PolicyViolation(format!(
                "unsupported worker protocol version {}",
                hello.protocol_version
            )));
        }
        if !hello.loopback_only {
            return Err(EngineError::PolicyViolation(
                "external workers are loopback-only in this package".to_owned(),
            ));
        }
        let worker_id = hello.worker.id.clone();
        let owner_actor = hello.worker.owner_actor.clone();
        self.host.register_worker(hello.worker, true).await?;
        self.connections.insert(
            worker_id.clone(),
            ExternalWorkerConnection {
                worker_id: worker_id.clone(),
                owner_actor,
                heartbeat_sequence: 0,
                loopback_only: true,
                functions: BTreeSet::new(),
                triggers: BTreeSet::new(),
            },
        );
        Ok(self.catalog_snapshot_for(&worker_id).await)
    }

    /// Handle a protocol message.
    pub async fn handle_message(
        &mut self,
        message: WorkerProtocolMessage,
    ) -> Result<Option<WorkerProtocolMessage>> {
        match message {
            WorkerProtocolMessage::Hello(hello) => {
                let snapshot = self.hello(hello).await?;
                Ok(Some(WorkerProtocolMessage::CatalogSnapshot(snapshot)))
            }
            WorkerProtocolMessage::RegisterFunction(message) => {
                self.register_function(message).await?;
                Ok(None)
            }
            WorkerProtocolMessage::RegisterTrigger(message) => {
                self.register_trigger(message).await?;
                Ok(None)
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

    /// Register a function from a local worker. External functions default to
    /// session visibility unless they are explicitly promoted later.
    pub async fn register_function(
        &mut self,
        message: RegisterFunction,
    ) -> Result<WorkerCatalogChange> {
        let worker_id = message.definition.owner_worker.clone();
        if !self.connections.contains_key(&worker_id) {
            return Err(EngineError::NotFound {
                kind: "external worker connection",
                id: worker_id.to_string(),
            });
        }
        if message.default_visibility != VisibilityScope::Session
            || message.definition.visibility != VisibilityScope::Session
        {
            return Err(EngineError::PolicyViolation(
                "external worker functions must start session-visible".to_owned(),
            ));
        }
        let id = message.definition.id.to_string();
        let handler = self.invokers.get(&worker_id).map(|invoker| {
            Arc::new(ExternalFunctionProxyHandler {
                invoker: invoker.clone(),
            }) as Arc<dyn InProcessFunctionHandler>
        });
        self.host
            .register_function(message.definition, handler, true)
            .await?;
        self.connection_mut(&worker_id)?
            .functions
            .insert(id.clone());
        Ok(WorkerCatalogChange {
            subject_id: id,
            owner_worker: worker_id,
            kind: "function_registered".to_owned(),
        })
    }

    /// Register a trigger from a local worker.
    pub async fn register_trigger(
        &mut self,
        message: RegisterTrigger,
    ) -> Result<WorkerCatalogChange> {
        let worker_id = message.definition.owner_worker.clone();
        if !self.connections.contains_key(&worker_id) {
            return Err(EngineError::NotFound {
                kind: "external worker connection",
                id: worker_id.to_string(),
            });
        }
        let id = message.definition.id.to_string();
        self.host.register_trigger(message.definition, true).await?;
        self.connection_mut(&worker_id)?.triggers.insert(id.clone());
        Ok(WorkerCatalogChange {
            subject_id: id,
            owner_worker: worker_id,
            kind: "trigger_registered".to_owned(),
        })
    }

    /// Record worker heartbeat.
    pub fn heartbeat(&mut self, heartbeat: WorkerHeartbeat) -> Result<()> {
        let connection = self.connection_mut(&heartbeat.worker_id)?;
        if heartbeat.sequence <= connection.heartbeat_sequence {
            return Err(EngineError::PolicyViolation(format!(
                "stale heartbeat {} for worker {}",
                heartbeat.sequence, heartbeat.worker_id
            )));
        }
        connection.heartbeat_sequence = heartbeat.sequence;
        Ok(())
    }

    /// Disconnect a worker and unregister its volatile registrations.
    pub async fn disconnect(&mut self, disconnect: WorkerDisconnect) -> Result<()> {
        let Some(connection) = self.connections.remove(&disconnect.worker_id) else {
            return Ok(());
        };
        self.invokers.remove(&disconnect.worker_id);
        self.host
            .unregister_worker(&connection.worker_id, connection.owner_actor.as_str())
            .await?;
        Ok(())
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

    /// Return current connection ids.
    #[must_use]
    pub fn connections(&self) -> Vec<WorkerId> {
        self.connections.keys().cloned().collect()
    }

    async fn catalog_snapshot_for(&self, worker_id: &WorkerId) -> CatalogSnapshot {
        let actor = ActorContext::new(
            ActorId::new(format!("worker:{worker_id}")).expect("valid worker actor id"),
            ActorKind::Worker,
            super::ids::AuthorityGrantId::new(format!("worker-grant:{worker_id}"))
                .expect("valid worker grant id"),
        );
        let functions = self
            .host
            .discover(&FunctionQuery {
                actor: Some(actor),
                ..FunctionQuery::default()
            })
            .await;
        CatalogSnapshot {
            functions,
            triggers: Vec::new(),
        }
    }

    fn connection_mut(&mut self, worker_id: &WorkerId) -> Result<&mut ExternalWorkerConnection> {
        self.connections
            .get_mut(worker_id)
            .ok_or_else(|| EngineError::NotFound {
                kind: "external worker connection",
                id: worker_id.to_string(),
            })
    }
}

struct ExternalFunctionProxyHandler {
    invoker: Arc<dyn ExternalWorkerInvoker>,
}

#[async_trait]
impl InProcessFunctionHandler for ExternalFunctionProxyHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        let result = self
            .invoker
            .invoke(WorkerInvoke {
                invocation_id: invocation.id.clone(),
                function_id: invocation.function_id.clone(),
                payload: invocation.payload.clone(),
                actor_kind: invocation.causal_context.actor_kind.clone(),
                trace_id: invocation.causal_context.trace_id.clone(),
                trigger_id: invocation.causal_context.trigger_id.clone(),
            })
            .await?;
        if let Some(error) = result.error {
            return Err(EngineError::HandlerFailed(error.to_string()));
        }
        Ok(result.result.unwrap_or(Value::Null))
    }
}
