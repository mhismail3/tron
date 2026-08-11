//! Process-local dispatcher and lifecycle integration.

use std::sync::Arc;
use std::time::Duration;

use dashmap::DashSet;
use tokio::task::JoinSet;
use tokio_util::sync::CancellationToken;

use crate::domains::agent::coordination::CoordinationService;
use crate::domains::agent::r#loop::{Orchestrator, SessionManager};
use crate::domains::model::responder::ModelResponderFactory;
use crate::domains::registration::composition::DomainRegistrationContext;
use crate::domains::session::event_store::EventStore;
use crate::domains::settings::SettingsRuntime;

const MAX_DISPATCH_PER_TICK: usize = 128;

/// Shared Agent Execution supervisor.
pub(crate) struct AgentExecutionService {
    pub(super) coordination: CoordinationService,
    pub(super) event_store: Arc<EventStore>,
    pub(super) orchestrator: Arc<Orchestrator>,
    pub(super) session_manager: Arc<SessionManager>,
    pub(super) responder_factory: Option<Arc<dyn ModelResponderFactory>>,
    pub(super) settings_runtime: Arc<SettingsRuntime>,
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) origin: String,
    pub(super) shutdown_coordinator:
        Option<Arc<crate::app::lifecycle::shutdown::ShutdownCoordinator>>,
    notify: Arc<tokio::sync::Notify>,
    inflight_agents: DashSet<String>,
}

impl AgentExecutionService {
    pub(crate) fn from_registration(deps: &DomainRegistrationContext) -> Arc<Self> {
        Arc::new(Self {
            coordination: CoordinationService::new(Arc::clone(&deps.event_store)),
            event_store: Arc::clone(&deps.event_store),
            orchestrator: Arc::clone(&deps.orchestrator),
            session_manager: Arc::clone(&deps.session_manager),
            responder_factory: deps.responder_factory.clone(),
            settings_runtime: Arc::clone(&deps.settings_runtime),
            engine_host: deps.engine_host.clone(),
            origin: deps.origin.clone(),
            shutdown_coordinator: deps.shutdown_coordinator.clone(),
            notify: Arc::new(tokio::sync::Notify::new()),
            inflight_agents: DashSet::new(),
        })
    }

    /// Fast-path a durable admission. The one-second reconciliation tick is
    /// authoritative if a notification is lost or the process restarts.
    pub(crate) fn notify(&self) {
        self.notify.notify_one();
    }

    /// Abort process-local provider/tool work after canonical storage has
    /// terminalized an agent's assignment. Storage remains authoritative if
    /// this best-effort signal races shutdown.
    pub(crate) fn interrupt_agent(&self, agent_id: &str) -> Result<bool, String> {
        let Some(agent) = self
            .event_store
            .core_agent_record(agent_id)
            .map_err(|error| error.to_string())?
        else {
            return Ok(false);
        };
        self.orchestrator
            .abort(&agent.transcript_session_id)
            .map_err(|error| error.to_string())
    }

    /// Recover and supervise assignments and wakes until server shutdown.
    pub(crate) async fn activate(self: Arc<Self>, cancellation: CancellationToken) {
        match self.event_store.recover_core_agent_execution() {
            Ok(recovery) => {
                if recovery.interrupted_attempts > 0 || recovery.recovered_wake_leases > 0 {
                    tracing::info!(
                        component = "agent.execution",
                        agent_event = "recovered",
                        interrupted_attempts = recovery.interrupted_attempts,
                        recovered_wake_leases = recovery.recovered_wake_leases,
                        "core Agent Execution recovered process-local custody"
                    );
                }
            }
            Err(error) => {
                tracing::error!(
                    component = "agent.execution",
                    error = %error,
                    "core Agent Execution recovery failed; dispatcher will keep reconciling"
                );
            }
        }

        let mut ticker = tokio::time::interval(Duration::from_secs(1));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut runs = JoinSet::new();
        loop {
            let maintain = tokio::select! {
                () = cancellation.cancelled() => break,
                _ = ticker.tick() => true,
                () = self.notify.notified() => true,
                Some(_) = runs.join_next(), if !runs.is_empty() => false,
            };
            if maintain {
                self.dispatch_assignments(&mut runs);
                self.dispatch_idle_wakes(&mut runs);
            }
        }
        for agent_id in self
            .inflight_agents
            .iter()
            .map(|entry| entry.key().clone())
            .collect::<Vec<_>>()
        {
            let _ = self.interrupt_agent(&agent_id);
        }
        runs.abort_all();
        while runs.join_next().await.is_some() {}
        self.inflight_agents.clear();
    }

    fn dispatch_assignments(self: &Arc<Self>, runs: &mut JoinSet<()>) {
        let Some(_) = self.responder_factory.as_ref() else {
            return;
        };
        let candidates = match self
            .event_store
            .core_execution_candidates(MAX_DISPATCH_PER_TICK)
        {
            Ok(candidates) => candidates,
            Err(error) => {
                tracing::warn!(error = %error, "core assignment scan will retry");
                return;
            }
        };
        for candidate in candidates {
            if self
                .orchestrator
                .has_pending_or_active_run(&candidate.agent.transcript_session_id)
                || !self
                    .inflight_agents
                    .insert(candidate.agent.agent_id.clone())
            {
                continue;
            }
            let service = Arc::clone(self);
            runs.spawn(async move {
                let agent_id = candidate.agent.agent_id.clone();
                if let Err(error) = service.drive_assignment(candidate).await {
                    tracing::error!(agent_id, error = %error, "core assignment driver failed");
                }
                let _ = service.inflight_agents.remove(&agent_id);
                service.notify();
            });
        }
    }

    fn dispatch_idle_wakes(self: &Arc<Self>, runs: &mut JoinSet<()>) {
        let Some(_) = self.responder_factory.as_ref() else {
            return;
        };
        let wakes = match self.coordination.pending_wakes(MAX_DISPATCH_PER_TICK) {
            Ok(wakes) => wakes,
            Err(error) => {
                tracing::warn!(error = %error, "core wake scan will retry");
                return;
            }
        };
        for wake in wakes {
            // Result/wait wakes become durable semantic messages immediately,
            // allowing an already-running assignment to consume them at its
            // next provider boundary without interruption.
            let message_id = match self.ensure_wake_message(&wake) {
                Ok(message_id) => message_id,
                Err(error) => {
                    tracing::warn!(wake_id = wake.wake_id, error = %error, "core wake message repair will retry");
                    continue;
                }
            };
            if let Err(error) = self
                .event_store
                .bind_core_wake_message(&wake.wake_id, &message_id)
            {
                tracing::warn!(wake_id = wake.wake_id, error = %error, "core wake message repair will retry");
                continue;
            }
            if let Some(assignment_id) = wake.target_assignment_id.as_deref()
                && self
                    .event_store
                    .core_assignment_record(assignment_id)
                    .ok()
                    .flatten()
                    .is_some_and(|assignment| {
                        matches!(
                            assignment.status,
                            crate::domains::agent::coordination::AssignmentStatus::Queued
                                | crate::domains::agent::coordination::AssignmentStatus::Running
                                | crate::domains::agent::coordination::AssignmentStatus::Waiting
                        )
                    })
            {
                // The FIFO assignment owner consumes this wake. If it is
                // already active, provider-boundary materialization does so;
                // otherwise the assignment scan starts/resumes it.
                continue;
            }
            let Some(agent) = self
                .event_store
                .core_agent_record(&wake.target_agent_id)
                .ok()
                .flatten()
            else {
                continue;
            };
            if self
                .orchestrator
                .has_pending_or_active_run(&agent.transcript_session_id)
                || !self.inflight_agents.insert(agent.agent_id.clone())
            {
                continue;
            }
            let service = Arc::clone(self);
            runs.spawn(async move {
                let agent_id = agent.agent_id.clone();
                if let Err(error) = service.drive_idle_wake(agent, wake).await {
                    tracing::warn!(agent_id, error = %error, "core auxiliary wake will retry");
                }
                let _ = service.inflight_agents.remove(&agent_id);
                service.notify();
            });
        }
    }
}
