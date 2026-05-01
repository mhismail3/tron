//! In-process invocation contracts.

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::discovery::ActorKind;
use super::errors::{EngineError, Result};
use super::ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, TriggerId, WorkerId,
};
use super::types::{CatalogRevision, DeliveryMode, FunctionRevision};

/// Causal context carried by every invocation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CausalContext {
    /// Actor id.
    pub actor_id: ActorId,
    /// Actor kind.
    pub actor_kind: ActorKind,
    /// Authority grant id.
    pub authority_grant_id: AuthorityGrantId,
    /// Granted authority scopes.
    pub authority_scopes: Vec<String>,
    /// Trace id.
    pub trace_id: TraceId,
    /// Parent invocation.
    pub parent_invocation_id: Option<InvocationId>,
    /// Optional session id.
    pub session_id: Option<String>,
    /// Optional workspace id.
    pub workspace_id: Option<String>,
    /// Catalog revision observed at dispatch.
    pub catalog_revision: CatalogRevision,
    /// Trigger id, if trigger-caused.
    pub trigger_id: Option<TriggerId>,
    /// Delivery mode.
    pub delivery_mode: DeliveryMode,
    /// Idempotency key.
    pub idempotency_key: Option<String>,
}

impl CausalContext {
    /// Create a causal context.
    #[must_use]
    pub fn new(
        actor_id: ActorId,
        actor_kind: ActorKind,
        authority_grant_id: AuthorityGrantId,
        trace_id: TraceId,
    ) -> Self {
        Self {
            actor_id,
            actor_kind,
            authority_grant_id,
            authority_scopes: Vec::new(),
            trace_id,
            parent_invocation_id: None,
            session_id: None,
            workspace_id: None,
            catalog_revision: CatalogRevision(0),
            trigger_id: None,
            delivery_mode: DeliveryMode::Sync,
            idempotency_key: None,
        }
    }

    /// Add an authority scope.
    #[must_use]
    pub fn with_scope(mut self, scope: impl Into<String>) -> Self {
        self.authority_scopes.push(scope.into());
        self
    }

    /// Set the session id.
    #[must_use]
    pub fn with_session_id(mut self, session_id: impl Into<String>) -> Self {
        self.session_id = Some(session_id.into());
        self
    }

    /// Set the workspace id.
    #[must_use]
    pub fn with_workspace_id(mut self, workspace_id: impl Into<String>) -> Self {
        self.workspace_id = Some(workspace_id.into());
        self
    }

    /// Add an idempotency key.
    #[must_use]
    pub fn with_idempotency_key(mut self, key: impl Into<String>) -> Self {
        self.idempotency_key = Some(key.into());
        self
    }

    /// Whether this context has a scope.
    #[must_use]
    pub fn has_scope(&self, scope: &str) -> bool {
        self.authority_scopes.iter().any(|s| s == scope)
    }
}

/// Invocation request.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Invocation {
    /// Invocation id.
    pub id: InvocationId,
    /// Target function id.
    pub function_id: FunctionId,
    /// Optional expected function revision.
    pub expected_function_revision: Option<FunctionRevision>,
    /// Delivery mode.
    pub delivery_mode: DeliveryMode,
    /// Payload.
    pub payload: Value,
    /// Causal context.
    pub causal_context: CausalContext,
}

impl Invocation {
    /// Create a sync invocation.
    #[must_use]
    pub fn new_sync(
        function_id: FunctionId,
        payload: Value,
        causal_context: CausalContext,
    ) -> Self {
        Self {
            id: InvocationId::generate(),
            function_id,
            expected_function_revision: None,
            delivery_mode: DeliveryMode::Sync,
            payload,
            causal_context,
        }
    }

    /// Set an expected function revision.
    #[must_use]
    pub fn expecting_revision(mut self, revision: FunctionRevision) -> Self {
        self.expected_function_revision = Some(revision);
        self
    }

    /// Set delivery mode.
    #[must_use]
    pub fn with_delivery_mode(mut self, mode: DeliveryMode) -> Self {
        self.delivery_mode = mode;
        self.causal_context.delivery_mode = mode;
        self
    }
}

/// Invocation result wrapper.
#[derive(Clone, Debug, PartialEq)]
pub struct InvocationResult {
    /// Invocation id.
    pub invocation_id: InvocationId,
    /// Function id.
    pub function_id: FunctionId,
    /// Worker that handled the function.
    pub worker_id: WorkerId,
    /// Function revision used.
    pub function_revision: FunctionRevision,
    /// Catalog revision observed.
    pub catalog_revision: CatalogRevision,
    /// Trace id.
    pub trace_id: TraceId,
    /// Successful payload.
    pub value: Option<Value>,
    /// Structured error.
    pub error: Option<EngineError>,
}

impl InvocationResult {
    /// Build a successful result.
    #[must_use]
    pub fn success(
        invocation: &Invocation,
        worker_id: WorkerId,
        function_revision: FunctionRevision,
        catalog_revision: CatalogRevision,
        value: Value,
    ) -> Self {
        Self {
            invocation_id: invocation.id.clone(),
            function_id: invocation.function_id.clone(),
            worker_id,
            function_revision,
            catalog_revision,
            trace_id: invocation.causal_context.trace_id.clone(),
            value: Some(value),
            error: None,
        }
    }

    /// Build an error result.
    #[must_use]
    pub fn error(
        invocation: &Invocation,
        worker_id: WorkerId,
        function_revision: FunctionRevision,
        catalog_revision: CatalogRevision,
        error: EngineError,
    ) -> Self {
        Self {
            invocation_id: invocation.id.clone(),
            function_id: invocation.function_id.clone(),
            worker_id,
            function_revision,
            catalog_revision,
            trace_id: invocation.causal_context.trace_id.clone(),
            value: None,
            error: Some(error),
        }
    }
}

/// Async handler for an in-process function.
#[async_trait]
pub trait InProcessFunctionHandler: Send + Sync {
    /// Handle an invocation.
    async fn invoke(&self, invocation: Invocation) -> Result<Value>;
}
