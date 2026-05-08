//! Cron scheduler trait implementations.
//!
//! Provides real implementations of `tron_cron` callback traits:
//! - [`CronAgentTurnExecutor`] — Isolated agent session execution
//! - [`CronSystemEventInjector`] — Session event injection
//!
//! Server transport callbacks for cron live in `server::domains::cron::callbacks`.

use std::sync::Arc;

use crate::cron::errors::CronError;
use async_trait::async_trait;
// ── Agent Turn Execution ──────────────────────────────────────────────

/// Maximum output size stored on a [`crate::cron::AgentTurnResult`].
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
    event_store: Arc<crate::events::EventStore>,
    session_manager: Arc<crate::runtime::orchestrator::session_manager::SessionManager>,
    provider_factory: Arc<dyn crate::llm::provider::ProviderFactory>,
    engine_host: crate::engine::EngineHostHandle,
    profile_runtime: Arc<crate::runtime::ProfileRuntime>,
    origin: String,
    subagent_manager: Option<Arc<crate::runtime::orchestrator::subagent_manager::SubagentManager>>,
}

impl CronAgentTurnExecutor {
    /// Create a new agent turn executor.
    pub fn new(
        event_store: Arc<crate::events::EventStore>,
        session_manager: Arc<crate::runtime::orchestrator::session_manager::SessionManager>,
        provider_factory: Arc<dyn crate::llm::provider::ProviderFactory>,
        engine_host: crate::engine::EngineHostHandle,
        profile_runtime: Arc<crate::runtime::ProfileRuntime>,
        origin: String,
        subagent_manager: Option<
            Arc<crate::runtime::orchestrator::subagent_manager::SubagentManager>,
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
    fn extract_output(agent: &crate::runtime::agent::tron_agent::TronAgent) -> (String, bool) {
        let messages = agent.context_manager().get_messages();
        let text = messages
            .iter()
            .rev()
            .find_map(|m| {
                if let crate::core::messages::Message::Assistant { content, .. } = m {
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
impl crate::cron::executor::AgentTurnExecutor for CronAgentTurnExecutor {
    async fn execute(
        &self,
        prompt: &str,
        model: Option<&str>,
        workspace_id: Option<&str>,
        system_prompt: Option<&str>,
        tool_restrictions: Option<&crate::cron::ToolRestrictions>,
        cancel: tokio_util::sync::CancellationToken,
    ) -> Result<crate::cron::AgentTurnResult, CronError> {
        // Resolve model and profile from the current compiled profile runtime.
        let current = self.profile_runtime.current();
        let model = model.unwrap_or(&current.settings.server.default_model);
        let session_plan = self
            .profile_runtime
            .plan_session(crate::runtime::SessionPlanRequest {
                requested_profile: None,
                model: model.to_owned(),
                source: Some("automation".into()),
                entrypoint: None,
            })
            .map_err(|error| CronError::Execution(format!("profile planning failed: {error}")))?;

        // Resolve workspace path
        let workspace_path = if let Some(wid) = workspace_id {
            let conn = self.event_store.pool().get().map_err(|e| {
                CronError::Execution(format!("pool error resolving workspace: {e}"))
            })?;
            let ws = crate::events::sqlite::repositories::workspace::WorkspaceRepo::get_by_id(
                &conn, wid,
            )
            .map_err(|e| CronError::Execution(format!("workspace lookup failed: {e}")))?
            .ok_or_else(|| CronError::Execution(format!("workspace not found: {wid}")))?;
            ws.path
        } else {
            let automations_dir = crate::core::paths::automations_dir();
            std::fs::create_dir_all(&automations_dir)?;
            automations_dir.to_string_lossy().into_owned()
        };

        // 1. Create provider (with retry for transient errors)
        let provider = {
            let mut attempt = 0u32;
            loop {
                match self.provider_factory.create_for_model(model).await {
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
            .create_session(model, &workspace_path, Some(&title), None)
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
        let agent_config = crate::runtime::AgentConfig {
            model: model.to_owned(),
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
            ..crate::runtime::AgentConfig::default()
        };

        // 4. Build denied tools list from user restrictions using the live tool catalog.
        let tool_names = match crate::tools::capability_surface::list_model_tool_names(
            &self.engine_host,
            &session_id,
            workspace_id,
        )
        .await
        {
            Ok(names) => names,
            Err(error) => {
                tracing::warn!(error = %error, "failed to read live tool catalog for cron restrictions");
                Vec::new()
            }
        };
        let denied_tools = tool_restrictions
            .map(|r| r.to_denied_list(&tool_names))
            .unwrap_or_default();
        // Interactive tools (AskUserQuestion, etc.)
        // are removed automatically by AgentFactory when is_unattended=true.

        // 6. Create agent via factory
        let mut agent = crate::runtime::AgentFactory::create_agent(
            agent_config,
            session_id.clone(),
            crate::runtime::CreateAgentOpts {
                provider,
                context_policy: session_plan.runtime_context_policy(),
                tool_policy: session_plan.tool_policy.clone(),
                guardrails: None,
                hooks: None,
                is_unattended: true,
                denied_tools,
                subagent_depth: 0,
                subagent_max_depth: 0,
                rules_content: None,
                initial_messages: vec![],
                memory_content: None,
                rules_index: None,
                pre_activated_rules: vec![],
                subagent_manager: self.subagent_manager.clone(),
                compaction_trigger_config:
                    crate::runtime::context::types::CompactionTriggerConfig::default(),
                process_manager: None,
                job_manager: None,
                output_buffer_registry: None,
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
            .append(&crate::events::AppendOptions {
                session_id: &session_id,
                event_type: crate::events::EventType::MessageUser,
                payload: serde_json::json!({"content": prompt}),
                parent_id: None,
                sequence: None,
            })
            .map_err(|e| CronError::Execution(format!("persist user message: {e}")))?;

        // 9. Run agent with timeout
        let broadcast = Arc::new(crate::runtime::EventEmitter::new());
        let run_ctx = crate::runtime::RunContext {
            profile_name: Some(session_plan.profile_name.clone()),
            resolved_profile: Some(session_plan.resolved_profile.clone()),
            ..crate::runtime::RunContext::default()
        };

        let result = tokio::select! {
            r = crate::runtime::run_agent(
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

        Ok(crate::cron::AgentTurnResult {
            session_id,
            output,
            output_truncated,
        })
    }
}

/// RAII guard that ends the session when dropped.
///
/// Ensures sessions are cleaned up even if the executor panics or returns
/// early due to errors. Uses `try_end_session` which is sync-safe.
struct SessionGuard {
    session_manager: Arc<crate::runtime::orchestrator::session_manager::SessionManager>,
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
    event_store: Arc<crate::events::EventStore>,
}

impl CronSystemEventInjector {
    /// Create a new injector.
    pub fn new(event_store: Arc<crate::events::EventStore>) -> Self {
        Self { event_store }
    }
}

#[async_trait]
impl crate::cron::executor::SystemEventInjector for CronSystemEventInjector {
    async fn inject(&self, session_id: &str, message: &str) -> Result<(), CronError> {
        let payload = serde_json::json!({
            "source": "cron",
            "content": message,
        });

        let _ = self
            .event_store
            .append(&crate::events::AppendOptions {
                session_id,
                event_type: crate::events::EventType::MessageSystem,
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
    use crate::cron::executor::AgentTurnExecutor;

    fn make_test_store_and_manager() -> (
        Arc<crate::events::EventStore>,
        Arc<crate::runtime::orchestrator::session_manager::SessionManager>,
    ) {
        let pool =
            crate::events::new_in_memory(&crate::events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = crate::events::run_migrations(&conn).unwrap();
        }
        let store = Arc::new(crate::events::EventStore::new(pool));
        let mgr = Arc::new(
            crate::runtime::orchestrator::session_manager::SessionManager::new(store.clone()),
        );
        (store, mgr)
    }

    fn make_profile_runtime() -> Arc<crate::runtime::ProfileRuntime> {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        crate::core::constitution::ensure_tron_home_at(&home).unwrap();
        let _keep_home_alive = Box::leak(Box::new(dir));
        Arc::new(crate::runtime::ProfileRuntime::load(home).unwrap())
    }

    // ── Provider retry tests ──────────────────────────────────────────

    use crate::core::content::AssistantContent;
    use crate::core::events::{AssistantMessage, StreamEvent};
    use crate::core::messages::TokenUsage;
    use crate::llm::models::types::Provider as ProviderKind;
    use crate::llm::provider::{
        Provider, ProviderError, ProviderFactory, ProviderStreamOptions, StreamEventStream,
    };
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
            _c: &crate::core::messages::Context,
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
