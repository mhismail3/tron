//! One-release target-union agent-delivery compatibility.
//!
//! Older authenticated clients may still address a new task, visible session,
//! or named mailbox directly. The v2 model contract never projects this path;
//! all first-class reusable-agent coordination uses stable agent handles.

use serde_json::{Value, json};

use super::{Invocation, MAX_CAUSAL_DEPTH, WorkerRuntime};
use crate::domains::session::event_store::{
    AgentDeliveryBoundary, AgentDeliveryIntent, AgentDeliverySourceKind, AgentDeliveryTarget,
    AgentDeliveryWakePolicy, AgentMailboxScope, NewAgentDelivery, NewAgentTaskDelivery,
};

impl WorkerRuntime {
    /// One-release compatibility implementation for the removed target-union
    /// contract. The registered v2 model contract never projects these fields;
    /// retaining this path lets authenticated older clients drain safely.
    pub(super) async fn legacy_agent_send(&self, invocation: &Invocation) -> Result<Value, String> {
        let source_session_id = invocation
            .causal_context
            .session_id
            .as_deref()
            .ok_or_else(|| "agent_send requires an engine-derived source session".to_owned())?;
        let source = self
            .event_store
            .get_session(source_session_id)
            .map_err(|error| error.to_string())?
            .ok_or_else(|| format!("source session '{source_session_id}' was not found"))?;
        if source.is_worker_session() || source.ended_at.is_some() {
            return Err("agent_send requires an active visible source task".to_owned());
        }
        if invocation
            .causal_context
            .workspace_id
            .as_deref()
            .is_some_and(|workspace_id| workspace_id != source.workspace_id)
        {
            return Err("engine workspace provenance does not match the source task".to_owned());
        }
        let target = invocation
            .payload
            .get("target")
            .and_then(Value::as_object)
            .ok_or_else(|| "agent_send target is required".to_owned())?;
        let target_kind = target
            .get("kind")
            .and_then(Value::as_str)
            .ok_or_else(|| "agent_send target.kind is required".to_owned())?;
        let content = invocation
            .payload
            .get("content")
            .and_then(Value::as_str)
            .ok_or_else(|| "agent_send content is required".to_owned())?
            .to_owned();
        let intent = match invocation
            .payload
            .get("intent")
            .and_then(Value::as_str)
            .unwrap_or("information")
        {
            "information" => AgentDeliveryIntent::Information,
            "request" => AgentDeliveryIntent::Request,
            other => return Err(format!("unsupported agent_send intent '{other}'")),
        };
        let requested_wake = match invocation
            .payload
            .get("wakePolicy")
            .and_then(Value::as_str)
            .unwrap_or("passive")
        {
            "passive" => AgentDeliveryWakePolicy::Passive,
            "wake" => AgentDeliveryWakePolicy::Wake,
            other => return Err(format!("unsupported agent_send wakePolicy '{other}'")),
        };
        let boundary = match invocation
            .payload
            .get("boundary")
            .and_then(Value::as_str)
            .unwrap_or("next_turn")
        {
            "next_turn" => AgentDeliveryBoundary::NextTurn,
            "next_run" => AgentDeliveryBoundary::NextRun,
            other => return Err(format!("unsupported agent_send boundary '{other}'")),
        };
        let expires_at = invocation
            .payload
            .get("expiresAt")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
        let causal_depth = invocation
            .causal_context
            .trigger_depth()
            .saturating_add(u32::from(requested_wake == AgentDeliveryWakePolicy::Wake));
        let wake_policy = if causal_depth > MAX_CAUSAL_DEPTH {
            AgentDeliveryWakePolicy::Passive
        } else {
            requested_wake
        };
        let source_invocation_id = Some(invocation.id.as_str().to_owned());
        let source_trace_id = Some(invocation.causal_context.trace_id.as_str().to_owned());
        let source_root_invocation_id = invocation
            .causal_context
            .origin_worker_invocation_id()
            .map(ToOwned::to_owned);
        let idempotency_key = format!("agent-send:{}", invocation.id.as_str());

        let (delivery, target_session_id, created_session) = match target_kind {
            "new_task" => {
                let requested_title = target
                    .get("title")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(ToOwned::to_owned)
                    .unwrap_or_else(|| {
                        let source_label = source
                            .title
                            .as_deref()
                            .filter(|title| !title.trim().is_empty())
                            .unwrap_or("current task");
                        format!("Task from {source_label}")
                    });
                let title =
                    crate::shared::foundation::text::truncate_str(requested_title.trim(), 120)
                        .to_owned();
                let model = target
                    .get("model")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(ToOwned::to_owned);
                if let Some(model) = model.as_deref() {
                    if !crate::domains::model::routing::catalog::is_model_supported(model) {
                        return Err(format!("agent_send new task model '{model}' is unknown"));
                    }
                    if crate::domains::model::routing::catalog::is_model_retired(model) {
                        return Err(format!("agent_send new task model '{model}' is retired"));
                    }
                }
                let working_directory = target
                    .get("workingDirectory")
                    .and_then(Value::as_str)
                    .map(crate::shared::foundation::paths::normalize_working_directory)
                    .transpose()?
                    .map(|path| path.display().to_string());
                let result = self
                    .event_store
                    .create_agent_task_with_delivery(&NewAgentTaskDelivery {
                        idempotency_key,
                        source_session_id: source_session_id.to_owned(),
                        title,
                        model,
                        working_directory,
                        intent,
                        wake_policy,
                        boundary,
                        content,
                        expires_at,
                        source_invocation_id,
                        source_trace_id,
                        source_root_invocation_id,
                        causal_depth,
                    })
                    .map_err(|error| error.to_string())?;
                let session_id = result.session.session.id.clone();
                if result.created {
                    crate::domains::session::lifecycle::project_created_session(
                        &self.orchestrator,
                        self.host.clone(),
                        &session_id,
                        &result.session.session.latest_model,
                        &result.session.session.working_directory,
                        result.session.session.title.clone(),
                    );
                }
                (result.delivery, Some(session_id), result.created)
            }
            "session" => {
                let session_id = target
                    .get("sessionId")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .ok_or_else(|| "agent_send session target requires sessionId".to_owned())?
                    .to_owned();
                let originating_run_id = self.orchestrator.active_run_id(source_session_id);
                let delivery = self
                    .orchestrator
                    .with_stable_active_run(&session_id, |active_run_id| {
                        let active_run_id = active_run_id.map(ToOwned::to_owned);
                        self.event_store.create_agent_delivery(&NewAgentDelivery {
                            idempotency_key,
                            source_kind: AgentDeliverySourceKind::AgentMessage,
                            intent: Some(intent),
                            source_session_id: Some(source_session_id.to_owned()),
                            source_workspace_id: source.workspace_id.clone(),
                            source_invocation_id,
                            source_trace_id,
                            source_root_invocation_id,
                            causal_depth,
                            target: AgentDeliveryTarget::Session {
                                session_id: session_id.clone(),
                            },
                            wake_policy,
                            boundary,
                            originating_run_id,
                            arrived_during_run_id: active_run_id.clone(),
                            defer_until_run_id: (boundary == AgentDeliveryBoundary::NextRun)
                                .then_some(active_run_id)
                                .flatten(),
                            result_invocation_id: None,
                            content,
                            not_before: None,
                            expires_at,
                        })
                    })
                    .map_err(|error| error.to_string())?;
                (delivery, Some(session_id), false)
            }
            "mailbox" => {
                if requested_wake == AgentDeliveryWakePolicy::Wake {
                    return Err("mailbox deliveries cannot wake an agent session".to_owned());
                }
                let scope = match target
                    .get("scope")
                    .and_then(Value::as_str)
                    .unwrap_or("workspace")
                {
                    "workspace" => AgentMailboxScope::Workspace,
                    "profile" => AgentMailboxScope::Profile,
                    other => return Err(format!("unsupported mailbox scope '{other}'")),
                };
                let name = target
                    .get("name")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .ok_or_else(|| "agent_send mailbox target requires name".to_owned())?
                    .to_owned();
                let delivery = self
                    .event_store
                    .create_agent_delivery(&NewAgentDelivery {
                        idempotency_key,
                        source_kind: AgentDeliverySourceKind::AgentMessage,
                        intent: Some(intent),
                        source_session_id: Some(source_session_id.to_owned()),
                        source_workspace_id: source.workspace_id.clone(),
                        source_invocation_id,
                        source_trace_id,
                        source_root_invocation_id,
                        causal_depth,
                        target: AgentDeliveryTarget::Mailbox {
                            scope,
                            workspace_id: (scope == AgentMailboxScope::Workspace)
                                .then(|| source.workspace_id.clone()),
                            name,
                        },
                        wake_policy: AgentDeliveryWakePolicy::Passive,
                        boundary: AgentDeliveryBoundary::NextTurn,
                        originating_run_id: self.orchestrator.active_run_id(source_session_id),
                        arrived_during_run_id: None,
                        defer_until_run_id: None,
                        result_invocation_id: None,
                        content,
                        not_before: None,
                        expires_at,
                    })
                    .map_err(|error| error.to_string())?;
                (delivery, None, false)
            }
            other => return Err(format!("unsupported agent_send target kind '{other}'")),
        };

        if wake_policy == AgentDeliveryWakePolicy::Wake
            && let Some(session_id) = target_session_id.as_deref()
        {
            self.request_agent_delivery_wake(session_id, causal_depth)
                .await;
        }
        Ok(json!({
            "deliveryId":delivery.delivery_id,
            "targetSessionId":target_session_id,
            "createdSession":created_session,
            "wakePolicy":if wake_policy == AgentDeliveryWakePolicy::Wake {"wake"} else {"passive"},
            "boundary":if boundary == AgentDeliveryBoundary::NextRun {"next_run"} else {"next_turn"},
            "wakeSuppressedByCausalDepth":requested_wake == AgentDeliveryWakePolicy::Wake
                && wake_policy == AgentDeliveryWakePolicy::Passive,
        }))
    }
}
