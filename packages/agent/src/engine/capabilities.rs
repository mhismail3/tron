//! Agent-facing capability client.
//!
//! The client is a thin, typed domain over [`EngineHostHandle`] for agents and
//! capabilities. It deliberately speaks canonical engine ids, not transport method ids.

use serde_json::Value;

use super::approval::EngineApprovalRequest;
use super::discovery::{ActorContext, ActorKind, FunctionQuery};
use super::errors::{EngineError, Result};
use super::host::{CatalogWatchRequest, CatalogWatchResponse, EngineHostHandle};
use super::ids::{ActorId, AuthorityGrantId, FunctionId, InvocationId, TraceId, TriggerId};
use super::invocation::{CausalContext, Invocation, InvocationResult};
use super::triggers::{EngineTriggerRuntime, TriggerDispatchRequest};
use super::types::{FunctionDefinition, RiskLevel};
use super::{policy, schema};

/// Agent-facing engine capability client.
#[derive(Clone)]
pub struct AgentCapabilityClient {
    handle: EngineHostHandle,
    actor_id: ActorId,
    authority_grant_id: AuthorityGrantId,
    authority_scopes: Vec<String>,
    session_id: Option<String>,
    workspace_id: Option<String>,
}

impl AgentCapabilityClient {
    /// Create a client for one agent/session.
    #[must_use]
    pub fn new(
        handle: EngineHostHandle,
        actor_id: ActorId,
        authority_grant_id: AuthorityGrantId,
    ) -> Self {
        Self {
            handle,
            actor_id,
            authority_grant_id,
            authority_scopes: Vec::new(),
            session_id: None,
            workspace_id: None,
        }
    }

    /// Add authority scopes.
    #[must_use]
    pub fn with_scopes(mut self, scopes: impl IntoIterator<Item = impl Into<String>>) -> Self {
        self.authority_scopes = scopes.into_iter().map(Into::into).collect();
        self
    }

    /// Add session scope.
    #[must_use]
    pub fn with_session_id(mut self, session_id: impl Into<String>) -> Self {
        self.session_id = Some(session_id.into());
        self
    }

    /// Add workspace scope.
    #[must_use]
    pub fn with_workspace_id(mut self, workspace_id: impl Into<String>) -> Self {
        self.workspace_id = Some(workspace_id.into());
        self
    }

    /// Discover visible canonical functions.
    pub async fn discover(&self, mut query: FunctionQuery) -> Vec<FunctionDefinition> {
        query.actor = Some(self.actor_context());
        self.handle
            .discover(&query)
            .await
            .into_iter()
            .filter(|function| {
                function.id.namespace() != "rpc" && !is_agent_blocked_function(&function.id)
            })
            .collect()
    }

    /// Inspect one canonical function.
    pub async fn inspect(&self, function_id: &FunctionId) -> Result<FunctionDefinition> {
        reject_noncanonical_namespace(function_id)?;
        reject_agent_blocked_function(function_id)?;
        self.handle
            .inspect_function(function_id, Some(&self.actor_context()))
            .await
    }

    /// Watch catalog changes visible to this agent.
    pub async fn watch(&self, request: CatalogWatchRequest) -> Result<CatalogWatchResponse> {
        self.handle.watch(&self.actor_context(), request).await
    }

    /// Invoke one canonical function.
    pub async fn invoke(
        &self,
        function_id: FunctionId,
        payload: Value,
        idempotency_key: Option<String>,
        parent_invocation_id: Option<InvocationId>,
    ) -> InvocationResult {
        if let Err(error) = reject_noncanonical_namespace(&function_id) {
            return InvocationResult::error(
                &Invocation::new_sync(function_id, payload, self.causal_context(idempotency_key)),
                super::ids::WorkerId::new("agent").expect("valid static worker id"),
                super::types::FunctionRevision(0),
                super::types::CatalogRevision(0),
                error,
            );
        }
        let mut context = self.causal_context(idempotency_key);
        if let Some(parent) = parent_invocation_id {
            context = context.with_parent_invocation(parent);
        }
        let invocation = Invocation::new_sync(function_id.clone(), payload.clone(), context);
        if let Err(error) = reject_agent_blocked_function(&function_id) {
            let (worker_id, revision) = self
                .handle
                .inspect_function(&function_id, Some(&self.actor_context()))
                .await
                .map(|function| (function.owner_worker, function.revision))
                .unwrap_or_else(|_| {
                    (
                        super::ids::WorkerId::new(function_id.namespace()).unwrap_or_else(|_| {
                            super::ids::WorkerId::new("agent").expect("valid static worker id")
                        }),
                        super::types::FunctionRevision(0),
                    )
                });
            return self
                .handle
                .record_policy_stopped_invocation(invocation, worker_id, revision, error)
                .await;
        }
        if let Ok(function) = self.inspect(&function_id).await {
            if let Err(error) = preflight_agent_invocation(&function, &invocation) {
                return self
                    .handle
                    .record_policy_stopped_invocation(
                        invocation,
                        function.owner_worker,
                        function.revision,
                        error,
                    )
                    .await;
            }
            if function.required_authority.approval_required
                && function.risk_level >= RiskLevel::High
            {
                let approval = self
                    .handle
                    .request_approval(EngineApprovalRequest {
                        function_id: function_id.clone(),
                        payload,
                        causal_context: invocation.causal_context.clone(),
                        delivery_mode: invocation.delivery_mode,
                    })
                    .await;
                let details = match approval {
                    Ok(record) => serde_json::json!({
                        "code": "APPROVAL_REQUIRED",
                        "approvalId": record.approval_id,
                        "status": record.status,
                        "functionId": function_id.as_str(),
                        "traceId": record.trace_id.as_str(),
                    }),
                    Err(error) => serde_json::json!({
                        "code": "APPROVAL_REQUEST_FAILED",
                        "functionId": function_id.as_str(),
                        "error": error.to_string(),
                    }),
                };
                let error = EngineError::DomainFailure {
                    domain: "approval".to_owned(),
                    code: "APPROVAL_REQUIRED".to_owned(),
                    message: format!(
                        "approval required before agent invocation of {}",
                        invocation.function_id
                    ),
                    details: Some(details),
                };
                return self
                    .handle
                    .record_policy_stopped_invocation(
                        invocation,
                        function.owner_worker,
                        function.revision,
                        error,
                    )
                    .await;
            }
        }
        self.handle.invoke(invocation).await
    }

    /// Dispatch a manual trigger.
    pub async fn dispatch_manual(
        &self,
        trigger_id: TriggerId,
        payload: Value,
        idempotency_key: Option<String>,
    ) -> InvocationResult {
        let mut request = TriggerDispatchRequest::new(
            trigger_id,
            payload,
            self.actor_id.clone(),
            ActorKind::Agent,
        );
        request.authority_scopes = self.authority_scopes.clone();
        request.trace_id = Some(TraceId::generate());
        request.session_id = self.session_id.clone();
        request.workspace_id = self.workspace_id.clone();
        request.idempotency_key = idempotency_key;
        EngineTriggerRuntime::dispatch(&self.handle, request).await
    }

    fn actor_context(&self) -> ActorContext {
        let mut actor = ActorContext::new(
            self.actor_id.clone(),
            ActorKind::Agent,
            self.authority_grant_id.clone(),
        );
        actor.authority_scopes = self.authority_scopes.clone();
        actor.session_id = self.session_id.clone();
        actor.workspace_id = self.workspace_id.clone();
        actor
    }

    fn causal_context(&self, idempotency_key: Option<String>) -> CausalContext {
        let mut context = CausalContext::new(
            self.actor_id.clone(),
            ActorKind::Agent,
            self.authority_grant_id.clone(),
            TraceId::generate(),
        );
        for scope in &self.authority_scopes {
            context = context.with_scope(scope.clone());
        }
        if let Some(session_id) = &self.session_id {
            context = context.with_session_id(session_id.clone());
        }
        if let Some(workspace_id) = &self.workspace_id {
            context = context.with_workspace_id(workspace_id.clone());
        }
        if let Some(key) = idempotency_key {
            context = context.with_idempotency_key(key);
        }
        context
    }
}

fn preflight_agent_invocation(
    function: &FunctionDefinition,
    invocation: &Invocation,
) -> Result<()> {
    policy::validate_invocation(function, invocation)?;
    if let Some(schema) = &function.request_schema {
        schema::validate_payload(&function.id, "request", schema, &invocation.payload)?;
    }
    Ok(())
}

fn reject_noncanonical_namespace(function_id: &FunctionId) -> Result<()> {
    let namespace = function_id.namespace();
    if namespace == "rpc" {
        return Err(EngineError::PolicyViolation(format!(
            "agent capability client refuses non-canonical namespace {namespace}"
        )));
    }
    Ok(())
}

fn is_agent_blocked_function(function_id: &FunctionId) -> bool {
    function_id.namespace() == "approval"
}

fn reject_agent_blocked_function(function_id: &FunctionId) -> Result<()> {
    if is_agent_blocked_function(function_id) {
        return Err(EngineError::PolicyViolation(
            "approval primitives are owned by user/client approval flow; agents must stop when an engine invocation returns APPROVAL_REQUIRED"
                .to_owned(),
        ));
    }
    Ok(())
}
