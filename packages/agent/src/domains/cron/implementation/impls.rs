//! Cron scheduler trait implementations.
//!
//! Provides real implementations of `tron_cron` callback traits:
//! - [`CronAgentTurnExecutor`] — Isolated agent session execution
//! - [`CronSystemEventInjector`] — Session event injection
//!
//! Server transport callbacks for cron live in `domains::cron::callbacks`.

use std::sync::Arc;

use crate::domains::cron::errors::CronError;
use crate::domains::model::presets::{
    ModelPreset, ModelRoutingPolicy, observe_local_model_availability, resolve_model_route,
};
use async_trait::async_trait;
// ── Agent Turn Execution ──────────────────────────────────────────────

/// Maximum output size stored on a [`crate::domains::cron::AgentTurnResult`].
/// Full output is always available via the session's event history.
const MAX_OUTPUT_CHARS: usize = 4096;

/// Default agent turn timeout (30 minutes).
const DEFAULT_TURN_TIMEOUT_SECS: u64 = 1800;

/// Executes isolated agent sessions for cron `agentTurn` payloads.
///
/// Creates a fresh session, runs a single agent turn (multi-turn within
/// the agent loop), extracts the final assistant text, then ends the session.
/// The session persists in the event store for auditability.
pub struct CronAgentTurnExecutor {
    event_store: Arc<crate::domains::session::event_store::EventStore>,
    session_manager:
        Arc<crate::domains::agent::runner::orchestrator::session_manager::SessionManager>,
    provider_factory: Arc<dyn crate::domains::model::providers::provider::ProviderFactory>,
    engine_host: crate::engine::EngineHostHandle,
    profile_runtime: Arc<crate::domains::agent::runner::ProfileRuntime>,
    origin: String,
    subagent_manager:
        Option<Arc<crate::domains::agent::runner::orchestrator::subagent_manager::SubagentManager>>,
}

impl CronAgentTurnExecutor {
    /// Create a new agent turn executor.
    pub fn new(
        event_store: Arc<crate::domains::session::event_store::EventStore>,
        session_manager: Arc<
            crate::domains::agent::runner::orchestrator::session_manager::SessionManager,
        >,
        provider_factory: Arc<dyn crate::domains::model::providers::provider::ProviderFactory>,
        engine_host: crate::engine::EngineHostHandle,
        profile_runtime: Arc<crate::domains::agent::runner::ProfileRuntime>,
        origin: String,
        subagent_manager: Option<
            Arc<crate::domains::agent::runner::orchestrator::subagent_manager::SubagentManager>,
        >,
    ) -> Self {
        Self {
            event_store,
            session_manager,
            provider_factory,
            engine_host,
            profile_runtime,
            origin,
            subagent_manager,
        }
    }

    /// Extract output text from the agent's last assistant message.
    fn extract_output(
        agent: &crate::domains::agent::runner::agent::tron_agent::TronAgent,
    ) -> (String, bool) {
        let messages = agent.context_manager().get_messages();
        let text = messages
            .iter()
            .rev()
            .find_map(|m| {
                if let crate::shared::messages::Message::Assistant { content, .. } = m {
                    let text: String = content
                        .iter()
                        .filter_map(|c| c.as_text())
                        .collect::<Vec<_>>()
                        .join("");
                    if text.is_empty() { None } else { Some(text) }
                } else {
                    None
                }
            })
            .unwrap_or_default();

        let truncated = text.len() > MAX_OUTPUT_CHARS;
        let output = if truncated {
            text.chars().take(MAX_OUTPUT_CHARS).collect()
        } else {
            text
        };
        (output, truncated)
    }
}

#[async_trait]
impl crate::domains::cron::executor::AgentTurnExecutor for CronAgentTurnExecutor {
    async fn execute(
        &self,
        prompt: &str,
        model: Option<&str>,
        model_preset: Option<ModelPreset>,
        workspace_id: Option<&str>,
        system_prompt: Option<&str>,
        _capability_restrictions: Option<&crate::domains::cron::CapabilityRestrictions>,
        cancel: tokio_util::sync::CancellationToken,
    ) -> Result<crate::domains::cron::AgentTurnResult, CronError> {
        // Resolve model and profile from the current compiled profile runtime.
        let current = self.profile_runtime.current();
        let mut routing_policy = ModelRoutingPolicy::from_settings(&current.settings)
            .with_profile_name(current.profile_name());
        if matches!(model_preset, Some(ModelPreset::LocalWhenPossible)) {
            routing_policy = routing_policy.with_local(observe_local_model_availability().await);
        }
        let model_route = resolve_model_route(
            model,
            model_preset,
            &routing_policy,
            &routing_policy.default_model,
        );
        let selected_model = model_route
            .selected_model
            .clone()
            .unwrap_or_else(|| routing_policy.default_model.clone());
        let session_plan = self
            .profile_runtime
            .plan_session(crate::domains::agent::runner::SessionPlanRequest {
                requested_profile: None,
                model: selected_model.clone(),
                source: Some("automation".into()),
                entrypoint: None,
            })
            .map_err(|error| CronError::Execution(format!("profile planning failed: {error}")))?;

        // Resolve workspace path
        let workspace_path = if let Some(wid) = workspace_id {
            let conn = self.event_store.pool().get().map_err(|e| {
                CronError::Execution(format!("pool error resolving workspace: {e}"))
            })?;
            let ws = crate::domains::session::event_store::sqlite::repositories::workspace::WorkspaceRepo::get_by_id(
                &conn, wid,
            )
            .map_err(|e| CronError::Execution(format!("workspace lookup failed: {e}")))?
            .ok_or_else(|| CronError::Execution(format!("workspace not found: {wid}")))?;
            ws.path
        } else {
            let automations_dir = crate::shared::paths::automations_dir();
            std::fs::create_dir_all(&automations_dir)?;
            automations_dir.to_string_lossy().into_owned()
        };

        // 1. Create provider (with retry for transient errors)
        let provider = {
            let mut attempt = 0u32;
            loop {
                match self
                    .provider_factory
                    .create_for_model(&selected_model)
                    .await
                {
                    Ok(p) => break p,
                    Err(e) if attempt < 3 && e.is_retryable() => {
                        attempt += 1;
                        let delay = std::time::Duration::from_secs(2u64.pow(attempt).min(30));
                        tracing::warn!(
                            attempt,
                            error = %e,
                            "transient error creating provider, retrying in {}s",
                            delay.as_secs()
                        );
                        tokio::time::sleep(delay).await;
                    }
                    Err(e) => return Err(CronError::Execution(format!("create provider: {e}"))),
                }
            }
        };

        // 2. Create session
        let title = format!("Cron: {}", prompt.chars().take(80).collect::<String>());
        let session_id = self
            .session_manager
            .create_session(&selected_model, &workspace_path, Some(&title), None)
            .map_err(|e| CronError::Execution(format!("create session: {e}")))?;

        let _ = self
            .event_store
            .update_source(&session_id, "cron")
            .map_err(|e| CronError::Execution(format!("update session source: {e}")))?;

        // Ensure session is always cleaned up, even on error/panic
        let _session_guard = SessionGuard {
            session_manager: self.session_manager.clone(),
            session_id: session_id.clone(),
        };

        // 3. Build agent config
        let agent_config = crate::domains::agent::runner::AgentConfig {
            model: selected_model,
            system_prompt: system_prompt.map(String::from).or_else(|| {
                session_plan
                    .prompt
                    .as_ref()
                    .map(|prompt| prompt.content.clone())
            }),
            max_turns: 100,
            enable_thinking: true,
            working_directory: Some(workspace_path.clone()),
            server_origin: Some(self.origin.clone()),
            workspace_id: workspace_id.map(String::from),
            ..crate::domains::agent::runner::AgentConfig::default()
        };

        // 6. Create agent via factory
        let mut agent = crate::domains::agent::runner::AgentFactory::create_agent(
            agent_config,
            session_id.clone(),
            crate::domains::agent::runner::CreateAgentOpts {
                provider,
                initial_messages: vec![],
                initial_turn_count: 0,
                compaction_trigger_config:
                    crate::domains::agent::runner::context::types::CompactionTriggerConfig::default(
                    ),
                engine_host: Some(self.engine_host.clone()),
            },
        );

        // 7. Wire abort token + persister
        agent.set_abort_token(cancel.clone());

        let active = self
            .session_manager
            .resume_session(&session_id)
            .map_err(|e| CronError::Execution(format!("resume session: {e}")))?;
        agent.set_persister(Some(active.context.persister.clone()));

        // 8. Persist the user message event
        let _ = self
            .event_store
            .append(&crate::domains::session::event_store::AppendOptions {
                session_id: &session_id,
                event_type: crate::domains::session::event_store::EventType::MessageUser,
                payload: serde_json::json!({"content": prompt}),
                parent_id: None,
                sequence: None,
            })
            .map_err(|e| CronError::Execution(format!("persist user message: {e}")))?;

        // 9. Run agent with timeout
        let broadcast = Arc::new(crate::domains::agent::runner::EventEmitter::new());
        let run_ctx = crate::domains::agent::runner::RunContext {
            profile_name: Some(session_plan.profile_name.clone()),
            resolved_profile: Some(session_plan.resolved_profile.clone()),
            ..crate::domains::agent::runner::RunContext::default()
        };

        let result = tokio::select! {
            r = crate::domains::agent::runner::run_agent(
                &mut agent,
                prompt,
                run_ctx,
                &None,
                &broadcast,
                None,
            ) => r,
            () = cancel.cancelled() => {
                return Err(CronError::Cancelled("agent turn cancelled".into()));
            }
            () = tokio::time::sleep(std::time::Duration::from_secs(DEFAULT_TURN_TIMEOUT_SECS)) => {
                return Err(CronError::TimedOut);
            }
        };

        // 10. Check for agent errors
        if let Some(ref error) = result.error {
            return Err(CronError::Execution(format!("agent error: {error}")));
        }

        // 11. Extract output
        let (output, output_truncated) = Self::extract_output(&agent);

        // 12. Flush persister then invalidate cached session state.
        //     Invalidation forces compute_cycle_messages() to reconstruct from
        //     persisted events instead of returning the stale empty snapshot
        //     cached at create_session() time (before the agent ran).
        if let Ok(active) = self.session_manager.resume_session(&session_id) {
            if let Err(e) = active.context.persister.flush().await {
                tracing::error!(session_id = %session_id, error = %e, "failed to flush persister for cron session");
            }
        }
        self.session_manager.invalidate_session(&session_id);

        Ok(crate::domains::cron::AgentTurnResult {
            session_id,
            output,
            output_truncated,
            model_routing: Some(model_route),
        })
    }
}

/// RAII guard that ends the session when dropped.
///
/// Ensures sessions are cleaned up even if the executor panics or returns
/// early due to errors. Uses `try_end_session` which is sync-safe.
struct SessionGuard {
    session_manager:
        Arc<crate::domains::agent::runner::orchestrator::session_manager::SessionManager>,
    session_id: String,
}

impl Drop for SessionGuard {
    fn drop(&mut self) {
        self.session_manager.invalidate_session(&self.session_id);
    }
}

// ── Push Notifications ──────────────────────────────────────────────

// ── System Event Injection ──────────────────────────────────────────

/// Injects system events into existing sessions.
pub struct CronSystemEventInjector {
    event_store: Arc<crate::domains::session::event_store::EventStore>,
}

impl CronSystemEventInjector {
    /// Create a new injector.
    pub fn new(event_store: Arc<crate::domains::session::event_store::EventStore>) -> Self {
        Self { event_store }
    }
}

#[async_trait]
impl crate::domains::cron::executor::SystemEventInjector for CronSystemEventInjector {
    async fn inject(&self, session_id: &str, message: &str) -> Result<(), CronError> {
        let payload = serde_json::json!({
            "source": "cron",
            "content": message,
        });

        let _ = self
            .event_store
            .append(&crate::domains::session::event_store::AppendOptions {
                session_id,
                event_type: crate::domains::session::event_store::EventType::MessageSystem,
                payload,
                parent_id: None,
                sequence: None,
            })
            .map_err(|e| CronError::Execution(format!("inject system event: {e}")))?;

        Ok(())
    }

    async fn session_exists(&self, session_id: &str) -> bool {
        self.event_store
            .get_session(session_id)
            .ok()
            .flatten()
            .is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::cron::executor::AgentTurnExecutor;

    fn make_test_store_and_manager() -> (
        Arc<crate::domains::session::event_store::EventStore>,
        Arc<crate::domains::agent::runner::orchestrator::session_manager::SessionManager>,
    ) {
        let pool = crate::domains::session::event_store::new_in_memory(
            &crate::domains::session::event_store::ConnectionConfig::default(),
        )
        .unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = crate::domains::session::event_store::run_migrations(&conn).unwrap();
        }
        let store = Arc::new(crate::domains::session::event_store::EventStore::new(pool));
        let mgr = Arc::new(
            crate::domains::agent::runner::orchestrator::session_manager::SessionManager::new(
                store.clone(),
            ),
        );
        (store, mgr)
    }

    fn make_profile_runtime() -> Arc<crate::domains::agent::runner::ProfileRuntime> {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        crate::shared::constitution::ensure_tron_home_at(&home).unwrap();
        let _keep_home_alive = Box::leak(Box::new(dir));
        Arc::new(crate::domains::agent::runner::ProfileRuntime::load(home).unwrap())
    }

    // ── Provider retry tests ──────────────────────────────────────────

    use crate::domains::model::providers::models::types::Provider as ProviderKind;
    use crate::domains::model::providers::provider::{
        Provider, ProviderError, ProviderFactory, ProviderStreamOptions, StreamEventStream,
    };
    use crate::shared::content::AssistantContent;
    use crate::shared::events::{AssistantMessage, StreamEvent};
    use crate::shared::messages::TokenUsage;
    use async_trait::async_trait;
    use futures::stream;

    const LEDGER_JSON: &str = r#"{"title":"Cron test session","entryType":"research","input":"test prompt","actions":["executed cron task"]}"#;

    struct LedgerMockProvider;
    #[async_trait]
    impl Provider for LedgerMockProvider {
        fn provider_type(&self) -> ProviderKind {
            ProviderKind::Anthropic
        }
        fn model(&self) -> &'static str {
            "mock-ledger"
        }
        async fn stream(
            &self,
            _c: &crate::shared::messages::Context,
            _o: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            let s = stream::iter(vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::TextDelta {
                    delta: LEDGER_JSON.into(),
                }),
                Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text(LEDGER_JSON)],
                        token_usage: Some(TokenUsage {
                            input_tokens: 10,
                            output_tokens: 5,
                            ..Default::default()
                        }),
                    },
                    stop_reason: "end_turn".into(),
                }),
            ]);
            Ok(Box::pin(s))
        }
    }

    /// Mock factory that fails N times with a retryable error, then succeeds.
    struct RetryMockProviderFactory {
        failures_remaining: std::sync::atomic::AtomicU32,
        retryable: bool,
    }

    impl RetryMockProviderFactory {
        fn new(failures: u32, retryable: bool) -> Self {
            Self {
                failures_remaining: std::sync::atomic::AtomicU32::new(failures),
                retryable,
            }
        }
    }

    #[async_trait]
    impl ProviderFactory for RetryMockProviderFactory {
        async fn create_for_model(&self, _model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
            let remaining = self
                .failures_remaining
                .fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
            if remaining > 0 {
                if self.retryable {
                    Err(ProviderError::Api {
                        status: 503,
                        message: "transient OAuth failure".into(),
                        code: None,
                        retryable: true,
                    })
                } else {
                    Err(ProviderError::Auth {
                        message: "permanent auth failure".into(),
                    })
                }
            } else {
                Ok(Arc::new(LedgerMockProvider))
            }
        }
    }

    #[tokio::test]
    async fn cron_retries_transient_provider_error() {
        // Fails twice with retryable error, succeeds on 3rd attempt
        let (store, mgr) = make_test_store_and_manager();
        let factory: Arc<dyn ProviderFactory> = Arc::new(RetryMockProviderFactory::new(2, true));
        let executor = CronAgentTurnExecutor::new(
            store.clone(),
            mgr.clone(),
            factory,
            crate::engine::EngineHostHandle::new_in_memory().unwrap(),
            make_profile_runtime(),
            "http://localhost:0".into(),
            None,
        );

        // The execute call will retry provider creation. It will succeed on 3rd attempt,
        // but then fail at the agent run stage (no real LLM). We just verify it gets past
        // provider creation.
        let result = executor
            .execute(
                "test prompt",
                Some("mock-ledger"),
                None,
                None,
                None,
                None,
                tokio_util::sync::CancellationToken::new(),
            )
            .await;
        // Should get past provider creation (error will be from agent run, not "create provider")
        match result {
            Err(CronError::Execution(msg)) => {
                assert!(
                    !msg.starts_with("create provider:"),
                    "should have retried past provider creation, got: {msg}"
                );
            }
            Ok(_) => {} // Unexpected but not a test failure
            Err(e) => {
                // Any non-provider error is fine — means retry worked
                assert!(
                    !e.to_string().contains("create provider"),
                    "should have retried past provider creation, got: {e}"
                );
            }
        }
    }

    #[tokio::test]
    async fn cron_fails_immediately_on_permanent_error() {
        let (store, mgr) = make_test_store_and_manager();
        let factory: Arc<dyn ProviderFactory> = Arc::new(RetryMockProviderFactory::new(1, false));
        let executor = CronAgentTurnExecutor::new(
            store.clone(),
            mgr.clone(),
            factory,
            crate::engine::EngineHostHandle::new_in_memory().unwrap(),
            make_profile_runtime(),
            "http://localhost:0".into(),
            None,
        );

        let result = executor
            .execute(
                "test prompt",
                Some("mock-ledger"),
                None,
                None,
                None,
                None,
                tokio_util::sync::CancellationToken::new(),
            )
            .await;
        // Should fail immediately with provider error, not retry
        match result {
            Err(CronError::Execution(msg)) => {
                assert!(
                    msg.starts_with("create provider:"),
                    "should fail at provider creation: {msg}"
                );
            }
            Ok(_) => panic!("expected Execution error from provider, got Ok"),
            Err(e) => panic!("expected Execution error from provider, got: {e}"),
        }
    }

    #[tokio::test]
    async fn cron_fails_after_max_retries() {
        let (store, mgr) = make_test_store_and_manager();
        // Always fail with retryable error — should exhaust 3 retries then fail
        let factory: Arc<dyn ProviderFactory> = Arc::new(RetryMockProviderFactory::new(100, true));
        let executor = CronAgentTurnExecutor::new(
            store.clone(),
            mgr.clone(),
            factory,
            crate::engine::EngineHostHandle::new_in_memory().unwrap(),
            make_profile_runtime(),
            "http://localhost:0".into(),
            None,
        );

        let result = executor
            .execute(
                "test prompt",
                Some("mock-ledger"),
                None,
                None,
                None,
                None,
                tokio_util::sync::CancellationToken::new(),
            )
            .await;
        match result {
            Err(CronError::Execution(msg)) => {
                assert!(
                    msg.starts_with("create provider:"),
                    "should fail at provider creation after retries: {msg}"
                );
            }
            Ok(_) => panic!("expected Execution error after retries, got Ok"),
            Err(e) => panic!("expected Execution error after retries, got: {e}"),
        }
    }
}
