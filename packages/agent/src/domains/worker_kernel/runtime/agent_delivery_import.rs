//! Worker-outbox signal projection into durable Agent Delivery state.
//!
//! Terminal and worker-declared effect parsing lives here so the coordinator
//! remains focused on mailbox/wait tools, wake admission, and import ordering.

use serde::Deserialize;
use serde_json::Value;

use super::agent_deliveries::ImportFailure;
use super::*;
use crate::domains::session::event_store::{
    AgentDeliveryBoundary, AgentDeliveryIntent, AgentDeliverySourceKind, AgentDeliveryTarget,
    AgentDeliveryWakePolicy, AgentMailboxScope, EventStoreError, NewAgentDelivery,
    WorkerTerminalEvidence,
};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TerminalSignal {
    invocation_id: String,
    worker_id: String,
    status: String,
    evidence: Value,
    origin_session_id: Option<String>,
    trace_id: String,
    root_invocation_id: Option<String>,
    causal_depth: u32,
    automatic_delivery_eligible: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DeliveryEffectSignal {
    invocation_id: String,
    worker_id: String,
    origin_session_id: Option<String>,
    trace_id: String,
    root_invocation_id: Option<String>,
    causal_depth: u32,
    deduplication_key: String,
    target: DeliveryEffectTarget,
    content: String,
    intent: String,
    wake_policy: String,
    boundary: String,
    expires_at: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case", tag = "kind", deny_unknown_fields)]
enum DeliveryEffectTarget {
    Session {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    Mailbox {
        scope: String,
        name: String,
    },
}

impl WorkerRuntime {
    pub(super) async fn import_terminal_signal(
        &self,
        row: &AgentDeliveryOutboxRecord,
    ) -> Result<(), ImportFailure> {
        let signal =
            serde_json::from_value::<TerminalSignal>(row.payload.clone()).map_err(|error| {
                ImportFailure::Permanent(format!("malformed terminal signal: {error}"))
            })?;
        if signal.invocation_id != row.invocation_id || signal.worker_id != row.worker_id {
            return Err(ImportFailure::Permanent(
                "terminal signal identity does not match its outbox envelope".to_owned(),
            ));
        }
        let evidence = serde_json::to_string(&signal.evidence)
            .map_err(|error| ImportFailure::Permanent(error.to_string()))?;
        self.event_store
            .reconcile_agent_waits(&[WorkerTerminalEvidence {
                invocation_id: signal.invocation_id.clone(),
                status: signal.status.clone(),
                evidence: evidence.clone(),
            }])
            .map_err(classify_event_store_error)?;

        if !signal.automatic_delivery_eligible {
            return Ok(());
        }
        let origin_session_id = signal.origin_session_id.ok_or_else(|| {
            ImportFailure::Permanent(
                "automatic worker delivery has no originating session".to_owned(),
            )
        })?;
        let session = self
            .event_store
            .get_session(&origin_session_id)
            .map_err(classify_event_store_error)?
            .ok_or_else(|| {
                ImportFailure::Permanent(format!(
                    "automatic worker delivery target session '{origin_session_id}' was deleted"
                ))
            })?;
        if session.is_worker_session() {
            return Err(ImportFailure::Permanent(
                "automatic worker delivery cannot target a worker audit session".to_owned(),
            ));
        }
        let content = serde_json::to_string(&json!({
            "kind":"worker_result",
            "invocationId":signal.invocation_id,
            "workerId":signal.worker_id,
            "status":signal.status,
            "evidence":signal.evidence,
        }))
        .map_err(|error| ImportFailure::Permanent(error.to_string()))?;
        self.orchestrator
            .with_stable_active_run(&origin_session_id, |active_run_id| {
                self.event_store.create_agent_delivery(&NewAgentDelivery {
                    idempotency_key: format!("worker-terminal:{}", row.invocation_id),
                    source_kind: AgentDeliverySourceKind::WorkerResult,
                    intent: Some(AgentDeliveryIntent::Information),
                    source_session_id: Some(origin_session_id.clone()),
                    source_workspace_id: session.workspace_id,
                    source_invocation_id: Some(signal.invocation_id.clone()),
                    source_trace_id: Some(signal.trace_id),
                    source_root_invocation_id: signal.root_invocation_id,
                    causal_depth: signal.causal_depth,
                    target: AgentDeliveryTarget::Session {
                        session_id: origin_session_id.clone(),
                    },
                    wake_policy: AgentDeliveryWakePolicy::Passive,
                    boundary: AgentDeliveryBoundary::NextTurn,
                    originating_run_id: None,
                    arrived_during_run_id: active_run_id.map(ToOwned::to_owned),
                    defer_until_run_id: None,
                    result_invocation_id: (signal.status == "completed")
                        .then_some(signal.invocation_id),
                    content,
                    not_before: None,
                    expires_at: None,
                })
            })
            .map_err(classify_event_store_error)?;
        Ok(())
    }

    pub(super) async fn import_delivery_effect(
        &self,
        row: &AgentDeliveryOutboxRecord,
    ) -> Result<(), ImportFailure> {
        let signal = serde_json::from_value::<DeliveryEffectSignal>(row.payload.clone()).map_err(
            |error| ImportFailure::Permanent(format!("malformed delivery effect: {error}")),
        )?;
        if signal.invocation_id != row.invocation_id || signal.worker_id != row.worker_id {
            return Err(ImportFailure::Permanent(
                "delivery effect identity does not match its outbox envelope".to_owned(),
            ));
        }
        if row.deduplication_key
            != format!(
                "effect:{}:{}",
                signal.invocation_id, signal.deduplication_key
            )
        {
            return Err(ImportFailure::Permanent(
                "delivery effect deduplication key does not match its outbox envelope".to_owned(),
            ));
        }

        let source_session = if let Some(session_id) = signal.origin_session_id.as_deref() {
            Some(
                self.event_store
                    .get_session(session_id)
                    .map_err(classify_event_store_error)?
                    .ok_or_else(|| {
                        ImportFailure::Permanent(format!(
                            "delivery effect source session '{session_id}' was deleted"
                        ))
                    })?,
            )
        } else {
            None
        };
        let (target, target_session_id, source_workspace_id) = match signal.target {
            DeliveryEffectTarget::Session { session_id } => {
                let source = source_session.as_ref().ok_or_else(|| {
                    ImportFailure::Permanent(
                        "a worker without an origin session may not target an agent session"
                            .to_owned(),
                    )
                })?;
                (
                    AgentDeliveryTarget::Session {
                        session_id: session_id.clone(),
                    },
                    Some(session_id),
                    source.workspace_id.clone(),
                )
            }
            DeliveryEffectTarget::Mailbox { scope, name } => match scope.as_str() {
                "workspace" => {
                    let source = source_session.as_ref().ok_or_else(|| {
                        ImportFailure::Permanent(
                            "a worker without an origin session may not target a workspace mailbox"
                                .to_owned(),
                        )
                    })?;
                    (
                        AgentDeliveryTarget::Mailbox {
                            scope: AgentMailboxScope::Workspace,
                            workspace_id: Some(source.workspace_id.clone()),
                            name,
                        },
                        None,
                        source.workspace_id.clone(),
                    )
                }
                "profile" => (
                    AgentDeliveryTarget::Mailbox {
                        scope: AgentMailboxScope::Profile,
                        workspace_id: None,
                        name,
                    },
                    None,
                    source_session
                        .as_ref()
                        .map(|source| source.workspace_id.clone())
                        .unwrap_or_else(|| "profile-global".to_owned()),
                ),
                other => {
                    return Err(ImportFailure::Permanent(format!(
                        "unsupported delivery effect mailbox scope '{other}'"
                    )));
                }
            },
        };
        let intent = match signal.intent.as_str() {
            "information" => AgentDeliveryIntent::Information,
            "request" => AgentDeliveryIntent::Request,
            other => {
                return Err(ImportFailure::Permanent(format!(
                    "unsupported delivery effect intent '{other}'"
                )));
            }
        };
        let requested_wake = match signal.wake_policy.as_str() {
            "passive" => AgentDeliveryWakePolicy::Passive,
            "wake" => AgentDeliveryWakePolicy::Wake,
            other => {
                return Err(ImportFailure::Permanent(format!(
                    "unsupported delivery effect wake policy '{other}'"
                )));
            }
        };
        if target_session_id.is_none() && requested_wake == AgentDeliveryWakePolicy::Wake {
            return Err(ImportFailure::Permanent(
                "a logical mailbox delivery may not wake an agent session".to_owned(),
            ));
        }
        let boundary = match signal.boundary.as_str() {
            "next_turn" => AgentDeliveryBoundary::NextTurn,
            "next_run" => AgentDeliveryBoundary::NextRun,
            other => {
                return Err(ImportFailure::Permanent(format!(
                    "unsupported delivery effect boundary '{other}'"
                )));
            }
        };
        let causal_depth = signal.causal_depth.saturating_add(1);
        let wake_policy = if causal_depth > MAX_CAUSAL_DEPTH {
            AgentDeliveryWakePolicy::Passive
        } else {
            requested_wake
        };
        let source_active_run = signal
            .origin_session_id
            .as_deref()
            .and_then(|session_id| self.orchestrator.active_run_id(session_id));
        let create_delivery = |active_target_run: Option<&str>| {
            let active_target_run = active_target_run.map(ToOwned::to_owned);
            self.event_store.create_agent_delivery(&NewAgentDelivery {
                idempotency_key: row.deduplication_key.clone(),
                source_kind: AgentDeliverySourceKind::WorkerResult,
                intent: Some(intent),
                source_session_id: signal.origin_session_id,
                source_workspace_id,
                source_invocation_id: Some(signal.invocation_id.clone()),
                source_trace_id: Some(signal.trace_id),
                source_root_invocation_id: signal.root_invocation_id,
                causal_depth,
                target,
                wake_policy,
                boundary,
                originating_run_id: source_active_run,
                arrived_during_run_id: active_target_run.clone(),
                defer_until_run_id: (boundary == AgentDeliveryBoundary::NextRun)
                    .then_some(active_target_run)
                    .flatten(),
                result_invocation_id: Some(signal.invocation_id),
                content: signal.content,
                not_before: None,
                expires_at: signal.expires_at,
            })
        };
        let delivery = if let Some(session_id) = target_session_id.as_deref() {
            self.orchestrator
                .with_stable_active_run(session_id, create_delivery)
        } else {
            create_delivery(None)
        }
        .map_err(classify_event_store_error)?;
        if delivery.wake_policy == AgentDeliveryWakePolicy::Wake
            && let Some(session_id) = delivery.target_session_id.as_deref()
        {
            self.request_agent_delivery_wake(session_id, delivery.causal_depth)
                .await;
        }
        Ok(())
    }
}

fn classify_event_store_error(error: EventStoreError) -> ImportFailure {
    if error.is_busy() || matches!(error, EventStoreError::Pool(_)) {
        ImportFailure::Transient(error.to_string())
    } else {
        ImportFailure::Permanent(error.to_string())
    }
}
