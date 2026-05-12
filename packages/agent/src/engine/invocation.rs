//! In-process invocation contracts.

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::discovery::ActorKind;
use super::errors::{EngineError, Result};
use super::ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, TriggerId, WorkerId,
};
use super::types::{CatalogRevision, DeliveryMode, FunctionRevision, IdempotencyScope};

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
    /// Engine-internal runtime metadata. This is not model-supplied payload and
    /// is used to carry profile/policy context into primitive workers.
    #[serde(default)]
    pub runtime_metadata: BTreeMap<String, String>,
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
            runtime_metadata: BTreeMap::new(),
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

    /// Set the parent invocation id.
    #[must_use]
    pub fn with_parent_invocation(mut self, parent: InvocationId) -> Self {
        self.parent_invocation_id = Some(parent);
        self
    }

    /// Set the trigger id.
    #[must_use]
    pub fn with_trigger_id(mut self, trigger_id: TriggerId) -> Self {
        self.trigger_id = Some(trigger_id);
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

    /// Attach engine-internal runtime metadata.
    #[must_use]
    pub fn with_runtime_metadata(
        mut self,
        key: impl Into<String>,
        value: impl Into<String>,
    ) -> Self {
        let _ = self.runtime_metadata.insert(key.into(), value.into());
        self
    }

    /// Read engine-internal runtime metadata.
    #[must_use]
    pub fn runtime_metadata(&self, key: &str) -> Option<&str> {
        self.runtime_metadata.get(key).map(String::as_str)
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
    /// Invocation whose idempotent result was reused.
    pub replayed_from: Option<InvocationId>,
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
            replayed_from: None,
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
            replayed_from: None,
        }
    }

    /// Build a result by replaying a previous idempotent result.
    #[must_use]
    pub fn replay_previous(invocation: &Invocation, previous: &Self) -> Self {
        Self {
            invocation_id: invocation.id.clone(),
            function_id: invocation.function_id.clone(),
            worker_id: previous.worker_id.clone(),
            function_revision: previous.function_revision,
            catalog_revision: previous.catalog_revision,
            trace_id: invocation.causal_context.trace_id.clone(),
            value: previous.value.clone(),
            error: previous.error.clone(),
            replayed_from: Some(previous.invocation_id.clone()),
        }
    }

    /// Build a duplicate no-op result.
    #[must_use]
    pub fn noop_replay(
        invocation: &Invocation,
        worker_id: WorkerId,
        function_revision: FunctionRevision,
        catalog_revision: CatalogRevision,
        replayed_from: InvocationId,
    ) -> Self {
        Self {
            invocation_id: invocation.id.clone(),
            function_id: invocation.function_id.clone(),
            worker_id,
            function_revision,
            catalog_revision,
            trace_id: invocation.causal_context.trace_id.clone(),
            value: Some(Value::Null),
            error: None,
            replayed_from: Some(replayed_from),
        }
    }
}

/// Durable shape of an invocation attempt in the Phase 1 in-memory ledger.
#[derive(Clone, Debug, PartialEq)]
pub struct InvocationRecord {
    /// Invocation id.
    pub invocation_id: InvocationId,
    /// Function id.
    pub function_id: FunctionId,
    /// Worker that handled or owned the function.
    pub worker_id: WorkerId,
    /// Function revision used.
    pub function_revision: FunctionRevision,
    /// Catalog revision observed.
    pub catalog_revision: CatalogRevision,
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
    /// Trigger id.
    pub trigger_id: Option<TriggerId>,
    /// Session scope active when the invocation completed.
    pub session_id: Option<String>,
    /// Workspace scope active when the invocation completed.
    pub workspace_id: Option<String>,
    /// Delivery mode.
    pub delivery_mode: DeliveryMode,
    /// Idempotency key.
    pub idempotency_key: Option<String>,
    /// Concrete idempotency scope.
    pub idempotency_scope: Option<IdempotencyScope>,
    /// Resource leases acquired by the engine for this invocation.
    pub resource_lease_ids: Vec<String>,
    /// Durable compensation record status for this invocation.
    pub compensation_status: Option<String>,
    /// Replayed invocation, when this was an idempotency replay/no-op.
    pub replayed_from: Option<InvocationId>,
    /// Whether the result was successful.
    pub succeeded: bool,
    /// Successful result value.
    pub result_value: Option<Value>,
    /// Structured error.
    pub error: Option<EngineError>,
    /// Completion timestamp.
    pub timestamp: DateTime<Utc>,
}

impl InvocationRecord {
    /// Create a record from the invocation and result.
    #[must_use]
    pub fn from_result(
        invocation: &Invocation,
        result: &InvocationResult,
        idempotency_scope: Option<IdempotencyScope>,
    ) -> Self {
        Self {
            invocation_id: invocation.id.clone(),
            function_id: invocation.function_id.clone(),
            worker_id: result.worker_id.clone(),
            function_revision: result.function_revision,
            catalog_revision: result.catalog_revision,
            actor_id: invocation.causal_context.actor_id.clone(),
            actor_kind: invocation.causal_context.actor_kind.clone(),
            authority_grant_id: invocation.causal_context.authority_grant_id.clone(),
            authority_scopes: invocation.causal_context.authority_scopes.clone(),
            trace_id: invocation.causal_context.trace_id.clone(),
            parent_invocation_id: invocation.causal_context.parent_invocation_id.clone(),
            trigger_id: invocation.causal_context.trigger_id.clone(),
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            delivery_mode: invocation.delivery_mode,
            idempotency_key: invocation.causal_context.idempotency_key.clone(),
            idempotency_scope,
            resource_lease_ids: Vec::new(),
            compensation_status: None,
            replayed_from: result.replayed_from.clone(),
            succeeded: result.error.is_none(),
            result_value: result.value.clone(),
            error: result.error.clone(),
            timestamp: Utc::now(),
        }
    }

    /// Attach host-enforced contract bookkeeping.
    #[must_use]
    pub fn with_contracts(
        mut self,
        resource_lease_ids: Vec<String>,
        compensation_status: Option<String>,
    ) -> Self {
        self.resource_lease_ids = resource_lease_ids;
        self.compensation_status = compensation_status;
        self
    }
}

/// Async handler for an in-process function.
#[async_trait]
pub trait InProcessFunctionHandler: Send + Sync {
    /// Handle an invocation.
    async fn invoke(&self, invocation: Invocation) -> Result<Value>;
}
