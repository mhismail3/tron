//! In-process invocation contracts.

use async_trait::async_trait;
use chrono::{DateTime, Utc};

use serde_json::Value;
use tokio_util::sync::CancellationToken;

use crate::engine::catalog::discovery::ActorKind;
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{ActorId, FunctionId, InvocationId, TraceId, WorkerId};
use crate::engine::kernel::types::{CatalogRevision, FunctionRevision, IdempotencyScope};

/// Causal context carried by every invocation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CausalContext {
    /// Actor id.
    pub actor_id: ActorId,
    /// Actor kind.
    pub actor_kind: ActorKind,
    /// Trace id.
    pub trace_id: TraceId,
    /// Parent invocation.
    pub parent_invocation_id: Option<InvocationId>,
    /// Optional session id.
    pub session_id: Option<String>,
    /// Optional workspace id.
    pub workspace_id: Option<String>,
    /// Idempotency key.
    pub idempotency_key: Option<String>,
    /// Trusted session directory used to resolve relative host paths.
    working_directory: Option<String>,
    /// Persistent worker that owns an agent execution crossing engine-owned
    /// internal transport hops.
    origin_worker_id: Option<String>,
    /// Durable worker invocation that owns this delegated agent execution.
    ///
    /// This is causal identity for run-tree reconstruction and generic
    /// child-invocation ceilings. It is not authority or routing input.
    origin_worker_invocation_id: Option<String>,
    /// Zero-based occurrence of this tool within the owning worker run.
    ///
    /// Agent-runner recovery resets this counter and deterministically replays
    /// already admitted nested worker calls through their durable call slot.
    /// It is trusted engine metadata, never provider input or authority.
    origin_worker_tool_ordinal: Option<u32>,
    /// Generic agent-turn ceiling selected by the owning immutable worker.
    /// The agent runtime may only tighten its global ceiling with this value.
    worker_max_agent_turns: Option<u32>,
    /// Provider/model tool-call id that originated this engine invocation.
    ///
    /// This is transient observation metadata used to correlate live progress
    /// with the exact conversation chip. It is never an authorization,
    /// routing, persistence, or idempotency input.
    model_tool_invocation_id: Option<String>,
    /// Function revision advertised to the model that produced this call.
    advertised_function_revision: Option<FunctionRevision>,
    /// Immutable worker version advertised with the projected worker tool.
    advertised_worker_version: Option<String>,
    /// Current worker-trigger cascade depth.
    trigger_depth: u32,
}

impl CausalContext {
    /// Create a causal context.
    #[must_use]
    pub fn new(actor_id: ActorId, actor_kind: ActorKind, trace_id: TraceId) -> Self {
        Self {
            actor_id,
            actor_kind,
            trace_id,
            parent_invocation_id: None,
            session_id: None,
            workspace_id: None,
            idempotency_key: None,
            working_directory: None,
            origin_worker_id: None,
            origin_worker_invocation_id: None,
            origin_worker_tool_ordinal: None,
            worker_max_agent_turns: None,
            model_tool_invocation_id: None,
            advertised_function_revision: None,
            advertised_worker_version: None,
            trigger_depth: 0,
        }
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

    /// Add an idempotency key.
    #[must_use]
    pub fn with_idempotency_key(mut self, key: impl Into<String>) -> Self {
        self.idempotency_key = Some(key.into());
        self
    }

    /// Set the trusted session directory used by host path primitives.
    #[must_use]
    pub fn with_working_directory(mut self, working_directory: impl Into<String>) -> Self {
        self.working_directory = Some(working_directory.into());
        self
    }

    /// Read the trusted session directory used by host path primitives.
    #[must_use]
    pub fn working_directory(&self) -> Option<&str> {
        self.working_directory.as_deref()
    }

    /// Preserve the persistent worker that owns a delegated agent execution.
    #[must_use]
    pub fn with_origin_worker_id(mut self, worker_id: impl Into<String>) -> Self {
        self.origin_worker_id = Some(worker_id.into());
        self
    }

    /// Resolve the persistent worker that owns this causal chain.
    #[must_use]
    pub fn origin_worker_id(&self) -> Option<&str> {
        self.origin_worker_id.as_deref().or_else(|| {
            (self.actor_kind == ActorKind::Worker)
                .then(|| self.actor_id.as_str().strip_prefix("worker:"))
                .flatten()
        })
    }

    /// Preserve the durable invocation that owns a delegated agent execution.
    #[must_use]
    pub fn with_origin_worker_invocation_id(mut self, invocation_id: impl Into<String>) -> Self {
        self.origin_worker_invocation_id = Some(invocation_id.into());
        self
    }

    /// Resolve the durable parent worker invocation for a child tool call.
    #[must_use]
    pub fn origin_worker_invocation_id(&self) -> Option<&str> {
        self.origin_worker_invocation_id.as_deref()
    }

    /// Preserve the deterministic nested-tool occurrence within a worker run.
    #[must_use]
    pub fn with_origin_worker_tool_ordinal(mut self, ordinal: u32) -> Self {
        self.origin_worker_tool_ordinal = Some(ordinal);
        self
    }

    /// Resolve the deterministic nested-tool occurrence within a worker run.
    #[must_use]
    pub fn origin_worker_tool_ordinal(&self) -> Option<u32> {
        self.origin_worker_tool_ordinal
    }

    /// Tighten the delegated agent run to a worker-selected turn ceiling.
    #[must_use]
    pub fn with_worker_max_agent_turns(mut self, max_turns: u32) -> Self {
        self.worker_max_agent_turns = Some(max_turns);
        self
    }

    /// Read the worker-selected agent-turn ceiling.
    #[must_use]
    pub fn worker_max_agent_turns(&self) -> Option<u32> {
        self.worker_max_agent_turns
    }

    /// Preserve the originating provider/model tool-call id for live
    /// presentation correlation.
    #[must_use]
    pub fn with_model_tool_invocation_id(mut self, invocation_id: impl Into<String>) -> Self {
        self.model_tool_invocation_id = Some(invocation_id.into());
        self
    }

    /// Read the originating provider/model tool-call id.
    #[must_use]
    pub fn model_tool_invocation_id(&self) -> Option<&str> {
        self.model_tool_invocation_id.as_deref()
    }

    /// Pin execution to the exact function and worker versions advertised to
    /// the model that produced the call.
    #[must_use]
    pub fn with_advertised_function(
        mut self,
        function_revision: FunctionRevision,
        worker_version: Option<String>,
    ) -> Self {
        self.advertised_function_revision = Some(function_revision);
        self.advertised_worker_version = worker_version;
        self
    }

    /// Read the advertised function revision pin.
    #[must_use]
    pub fn advertised_function_revision(&self) -> Option<FunctionRevision> {
        self.advertised_function_revision
    }

    /// Read the advertised immutable worker version pin.
    #[must_use]
    pub fn advertised_worker_version(&self) -> Option<&str> {
        self.advertised_worker_version.as_deref()
    }

    /// Set the worker-trigger cascade depth.
    #[must_use]
    pub fn with_trigger_depth(mut self, trigger_depth: u32) -> Self {
        self.trigger_depth = trigger_depth;
        self
    }

    /// Read the worker-trigger cascade depth.
    #[must_use]
    pub fn trigger_depth(&self) -> u32 {
        self.trigger_depth
    }
}

/// Invocation request.
#[derive(Clone, Debug, PartialEq)]
pub struct Invocation {
    /// Invocation id.
    pub id: InvocationId,
    /// Target function id.
    pub function_id: FunctionId,
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
            payload,
            causal_context,
        }
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
}

/// Durable shape of an invocation attempt.
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
    /// Trace id.
    pub trace_id: TraceId,
    /// Parent invocation.
    pub parent_invocation_id: Option<InvocationId>,
    /// Session scope active when the invocation completed.
    pub session_id: Option<String>,
    /// Workspace scope active when the invocation completed.
    pub workspace_id: Option<String>,
    /// Idempotency key.
    pub idempotency_key: Option<String>,
    /// Concrete idempotency scope.
    pub idempotency_scope: Option<IdempotencyScope>,
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
        Self::from_result_at(invocation, result, idempotency_scope, Utc::now())
    }

    /// Create a record from the invocation and result with an explicit timestamp.
    #[must_use]
    pub fn from_result_at(
        invocation: &Invocation,
        result: &InvocationResult,
        idempotency_scope: Option<IdempotencyScope>,
        timestamp: DateTime<Utc>,
    ) -> Self {
        Self {
            invocation_id: invocation.id.clone(),
            function_id: invocation.function_id.clone(),
            worker_id: result.worker_id.clone(),
            function_revision: result.function_revision,
            catalog_revision: result.catalog_revision,
            actor_id: invocation.causal_context.actor_id.clone(),
            actor_kind: invocation.causal_context.actor_kind.clone(),
            trace_id: invocation.causal_context.trace_id.clone(),
            parent_invocation_id: invocation.causal_context.parent_invocation_id.clone(),
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            idempotency_key: invocation.causal_context.idempotency_key.clone(),
            idempotency_scope,
            replayed_from: result.replayed_from.clone(),
            succeeded: result.error.is_none(),
            result_value: result
                .value
                .as_ref()
                .map(crate::shared::foundation::redaction::redact_sensitive_json),
            error: result.error.clone(),
            timestamp,
        }
    }

    /// Return the audit-safe projection accepted by any ledger implementation.
    ///
    /// Callers normally construct records through [`Self::from_result_at`],
    /// which already applies this policy. Stores call it again as a boundary
    /// backstop for manually constructed records.
    #[must_use]
    pub(crate) fn redacted_for_storage(&self) -> Self {
        let mut record = self.clone();
        record.result_value = record
            .result_value
            .as_ref()
            .map(crate::shared::foundation::redaction::redact_sensitive_json);
        record
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn causal_context_owns_explicit_runtime_inputs() {
        let context = CausalContext::new(
            ActorId::new("agent:runtime-context-test").unwrap(),
            ActorKind::Agent,
            TraceId::new("runtime-context-test").unwrap(),
        )
        .with_working_directory("/tmp/runtime-context-test")
        .with_advertised_function(FunctionRevision(3), Some("worker-version".to_owned()))
        .with_trigger_depth(4);

        assert_eq!(
            context.working_directory(),
            Some("/tmp/runtime-context-test")
        );
        assert_eq!(
            context.advertised_function_revision(),
            Some(FunctionRevision(3))
        );
        assert_eq!(context.advertised_worker_version(), Some("worker-version"));
        assert_eq!(context.trigger_depth(), 4);
    }

    #[test]
    fn invocation_record_from_result_at_pins_timestamp() {
        let trace_id = TraceId::new("trace-fixed").unwrap();
        let causal_context = CausalContext::new(
            ActorId::new("actor-fixed").unwrap(),
            ActorKind::Agent,
            trace_id,
        )
        .with_session_id("sess-fixed")
        .with_workspace_id("ws-fixed");
        let invocation = Invocation {
            id: InvocationId::new("inv-fixed").unwrap(),
            function_id: FunctionId::new("demo::echo").unwrap(),
            payload: serde_json::json!({"input": "hello"}),
            causal_context,
        };
        let result = InvocationResult::success(
            &invocation,
            WorkerId::new("worker-fixed").unwrap(),
            FunctionRevision(7),
            CatalogRevision(9),
            serde_json::json!({"ok": true}),
        );
        let timestamp = "2026-06-09T14:00:00Z".parse::<DateTime<Utc>>().unwrap();

        let record = InvocationRecord::from_result_at(&invocation, &result, None, timestamp);

        assert_eq!(record.invocation_id.as_str(), "inv-fixed");
        assert_eq!(record.session_id.as_deref(), Some("sess-fixed"));
        assert_eq!(record.workspace_id.as_deref(), Some("ws-fixed"));
        assert_eq!(record.timestamp, timestamp);
    }

    #[test]
    fn invocation_record_redacts_credentials_without_mutating_live_result() {
        let invocation = Invocation::new_sync(
            FunctionId::new("worker_kernel::webhook_rotate").unwrap(),
            serde_json::json!({}),
            CausalContext::new(
                ActorId::new("agent-secret").unwrap(),
                ActorKind::Agent,
                TraceId::new("trace-secret").unwrap(),
            ),
        );
        let token = "trwh_0123456789abcdef0123456789abcdef";
        let result = InvocationResult::success(
            &invocation,
            WorkerId::new("worker-kernel").unwrap(),
            FunctionRevision(1),
            CatalogRevision(1),
            serde_json::json!({"token":token,"path":"/hooks/research"}),
        );

        let record = InvocationRecord::from_result(&invocation, &result, None);

        assert_eq!(record.result_value.as_ref().unwrap()["token"], "****");
        assert!(!record.result_value.unwrap().to_string().contains(token));
        assert_eq!(result.value.as_ref().unwrap()["token"], token);
    }
}

/// Async handler for an in-process function.
#[async_trait]
pub trait InProcessFunctionHandler: Send + Sync {
    /// Handle an invocation.
    async fn invoke(&self, invocation: Invocation) -> Result<Value>;

    /// Handle a regular in-process invocation with cooperative cancellation.
    ///
    /// The default implementation cancels by dropping the handler future. A
    /// handler that owns durable work around its dispatch must override this
    /// method and finish that bookkeeping before returning cancellation.
    async fn invoke_cancellable(
        &self,
        invocation: Invocation,
        cancellation: &CancellationToken,
    ) -> Result<Value> {
        if cancellation.is_cancelled() {
            return Err(EngineError::InvocationCancelled);
        }
        tokio::select! {
            biased;
            result = self.invoke(invocation) => result,
            () = cancellation.cancelled() => Err(EngineError::InvocationCancelled),
        }
    }
}
