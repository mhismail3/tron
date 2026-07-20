//! In-process invocation contracts.

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio_util::sync::CancellationToken;

use crate::engine::catalog::discovery::ActorKind;
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{
    ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, TriggerId, WorkerId,
};
use crate::engine::kernel::types::{
    CatalogRevision, DeliveryMode, FunctionRevision, IdempotencyScope,
};

/// Runtime metadata key carrying the trusted session working directory.
///
/// This is engine-owned context, not model-supplied payload. Domain workers use it
/// when a relative path needs to resolve against the active session workspace.
pub const RUNTIME_METADATA_WORKING_DIRECTORY: &str = "agent.workingDirectory";
/// Runtime metadata key carrying the provider/model tool-call id that caused an
/// engine invocation.
pub const RUNTIME_METADATA_PROVIDER_INVOCATION_ID: &str = "agent.providerInvocationId";
/// Runtime metadata key carrying the resolved model provider type.
pub const RUNTIME_METADATA_PROVIDER_TYPE: &str = "agent.providerType";
/// Runtime metadata key carrying the current agent run id.
pub const RUNTIME_METADATA_RUN_ID: &str = "agent.runId";
/// Runtime metadata key carrying the model-facing primitive name.
pub const RUNTIME_METADATA_MODEL_PRIMITIVE_NAME: &str = "agent.modelPrimitiveName";
/// Runtime metadata key pinning a model tool call to the function revision
/// advertised in the provider request that produced it.
pub const RUNTIME_METADATA_EXPECTED_FUNCTION_REVISION: &str = "agent.expectedFunctionRevision";
/// Runtime metadata key pinning a projected worker call to the immutable worker
/// version advertised in the provider request that produced it.
pub const RUNTIME_METADATA_EXPECTED_WORKER_VERSION: &str = "agent.expectedWorkerVersion";
/// Runtime metadata key recording the exact provider surface hash that exposed
/// a model tool. This is audit evidence; the per-function revision/version
/// pins are the routing guard.
pub const RUNTIME_METADATA_SURFACE_HASH: &str = "agent.surfaceHash";
/// Runtime metadata key recording the catalog revision observed when a model
/// tool surface was resolved.
pub const RUNTIME_METADATA_ADVERTISED_CATALOG_REVISION: &str = "agent.advertisedCatalogRevision";
/// Runtime metadata key carrying the current model turn number.
pub const RUNTIME_METADATA_TURN: &str = "agent.turn";
/// Runtime metadata key carrying the current trigger cascade depth.
pub const RUNTIME_METADATA_TRIGGER_DEPTH: &str = "engine.triggerDepth";
/// Runtime metadata key carrying the JSON trigger-id path for loop detection.
pub const RUNTIME_METADATA_TRIGGER_PATH: &str = "engine.triggerPath";
/// Runtime-owned marker for an accepted local agent or worker invocation.
///
/// This is deliberately not an authority grant. The host uses it to bypass the
/// legacy grant lookup and budget path while retaining actor and causal
/// observations during the worker-first POC.
pub const RUNTIME_METADATA_TRUSTED_LOCAL: &str = "engine.trustedLocal";

/// Causal context carried by every invocation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CausalContext {
    /// Actor id.
    pub actor_id: ActorId,
    /// Actor kind.
    pub actor_kind: ActorKind,
    /// Authority grant id for grant-backed boundaries. Trusted-local
    /// invocations deliberately carry no grant.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub authority_grant_id: Option<AuthorityGrantId>,
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
    /// is used to carry trusted run context into primitive workers.
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
        Self::new_with_authority(actor_id, actor_kind, Some(authority_grant_id), trace_id)
    }

    fn new_with_authority(
        actor_id: ActorId,
        actor_kind: ActorKind,
        authority_grant_id: Option<AuthorityGrantId>,
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

    /// Create an observational context with no authority grant and no trusted
    /// execution marker. Rejected work can therefore retain honest causal
    /// evidence without gaining a local-authority bypass.
    #[must_use]
    pub fn observed(actor_id: ActorId, actor_kind: ActorKind, trace_id: TraceId) -> Self {
        Self::new_with_authority(actor_id, actor_kind, None, trace_id)
    }

    /// Create a trusted-local causal context that is not backed by an authority
    /// grant.
    #[must_use]
    pub fn trusted_local(actor_id: ActorId, actor_kind: ActorKind, trace_id: TraceId) -> Self {
        Self::observed(actor_id, actor_kind, trace_id)
            .with_runtime_metadata(RUNTIME_METADATA_TRUSTED_LOCAL, "true")
    }

    /// Whether the engine admitted this invocation through the trusted-local
    /// worker-first path.
    #[must_use]
    pub fn is_trusted_local(&self) -> bool {
        self.runtime_metadata
            .get(RUNTIME_METADATA_TRUSTED_LOCAL)
            .is_some_and(|value| value == "true")
    }

    /// Return the grant required by a grant-backed boundary.
    ///
    /// Trusted-local calls must never be converted into a synthetic grant just
    /// to satisfy a legacy field. Callers that truly require a grant fail
    /// closed through this accessor instead.
    pub fn require_authority_grant_id(&self, operation: &str) -> Result<&AuthorityGrantId> {
        self.authority_grant_id.as_ref().ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "{operation} requires a grant-backed causal context"
            ))
        })
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
            delivery_mode: DeliveryMode::Sync,
            payload,
            causal_context,
        }
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
    /// Authority grant id when a grant-backed boundary authorized the call.
    /// Trusted-local invocations persist `None`/SQL `NULL`.
    pub authority_grant_id: Option<AuthorityGrantId>,
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
    /// Resource references produced by the capability result.
    pub produced_resource_refs: Vec<Value>,
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
            produced_resource_refs: produced_resource_refs_from_result(&result.value),
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
        record.produced_resource_refs = record
            .produced_resource_refs
            .iter()
            .map(crate::shared::foundation::redaction::redact_sensitive_json)
            .collect();
        record
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

fn produced_resource_refs_from_result(value: &Option<Value>) -> Vec<Value> {
    value
        .as_ref()
        .and_then(|value| value.get("resourceRefs"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trusted_local_context_has_no_synthetic_authority_id() {
        let context = CausalContext::trusted_local(
            ActorId::new("agent:trusted-local-test").unwrap(),
            ActorKind::Agent,
            TraceId::new("trusted-local-test").unwrap(),
        );

        assert!(context.is_trusted_local());
        assert_eq!(context.authority_grant_id, None);
        let encoded = serde_json::to_value(&context).unwrap();
        assert!(encoded.get("authority_grant_id").is_none());
        let decoded: CausalContext = serde_json::from_value(encoded).unwrap();
        assert_eq!(decoded.authority_grant_id, None);
        assert!(decoded.is_trusted_local());
    }

    #[test]
    fn invocation_record_from_result_at_pins_timestamp() {
        let trace_id = TraceId::new("trace-fixed").unwrap();
        let causal_context = CausalContext::new(
            ActorId::new("actor-fixed").unwrap(),
            ActorKind::Agent,
            AuthorityGrantId::new("grant-fixed").unwrap(),
            trace_id,
        )
        .with_session_id("sess-fixed")
        .with_workspace_id("ws-fixed");
        let invocation = Invocation {
            id: InvocationId::new("inv-fixed").unwrap(),
            function_id: FunctionId::new("demo::echo").unwrap(),
            delivery_mode: DeliveryMode::Sync,
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
                AuthorityGrantId::new("grant-secret").unwrap(),
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
