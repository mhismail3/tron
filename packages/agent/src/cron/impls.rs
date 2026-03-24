//! Cron scheduler trait implementations.
//!
//! Provides real implementations of `tron_cron` callback traits:
//! - [`CronAgentTurnExecutor`] — Isolated agent session execution
//! - [`CronPushNotifier`] — APNS push notifications
//! - [`CronEventBroadcaster`] — WebSocket event broadcasting
//! - [`CronSystemEventInjector`] — Session event injection

#[cfg(feature = "apns")]
use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use crate::cron::errors::CronError;
use crate::cron::types::{CronJob, CronRun};
#[cfg(feature = "apns")]
use crate::events::ConnectionPool;
#[cfg(feature = "apns")]
use crate::server::platform::apns::{ApnsNotification, ApnsService};
use crate::server::rpc::types::RpcEvent;
use crate::server::websocket::broadcast::BroadcastManager;
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
    tool_factory: Arc<dyn Fn() -> crate::tools::registry::ToolRegistry + Send + Sync>,
    origin: String,
    subagent_manager: Option<Arc<crate::runtime::orchestrator::subagent_manager::SubagentManager>>,
}

impl CronAgentTurnExecutor {
    /// Create a new agent turn executor.
    pub fn new(
        event_store: Arc<crate::events::EventStore>,
        session_manager: Arc<crate::runtime::orchestrator::session_manager::SessionManager>,
        provider_factory: Arc<dyn crate::llm::provider::ProviderFactory>,
        tool_factory: Arc<dyn Fn() -> crate::tools::registry::ToolRegistry + Send + Sync>,
        origin: String,
        subagent_manager: Option<
            Arc<crate::runtime::orchestrator::subagent_manager::SubagentManager>,
        >,
    ) -> Self {
        Self {
            event_store,
            session_manager,
            provider_factory,
            tool_factory,
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
        // Resolve model (fall back to settings default)
        let settings =
            crate::settings::loader::load_settings_from_path(&crate::settings::loader::settings_path())
                .unwrap_or_default();
        let model = model.unwrap_or(&settings.server.default_model);

        // Resolve workspace path
        let workspace_path = workspace_id
            .and_then(|wid| {
                self.event_store.pool().get().ok().and_then(|conn| {
                    crate::events::sqlite::repositories::workspace::WorkspaceRepo::get_by_id(
                        &conn, wid,
                    )
                    .ok()
                    .flatten()
                    .map(|ws| ws.path)
                })
            })
            .or_else(|| {
                let home = crate::core::paths::home_dir();
                let cron_dir = format!("{home}/.tron/memory/cron");
                let _ = std::fs::create_dir_all(&cron_dir);
                Some(cron_dir)
            })
            .unwrap_or_else(|| "/tmp".into());

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
            .create_session(model, &workspace_path, Some(&title))
            .map_err(|e| CronError::Execution(format!("create session: {e}")))?;

        let _ = self.event_store.update_source(&session_id, "cron");

        // Ensure session is always cleaned up, even on error/panic
        let _session_guard = SessionGuard {
            session_manager: self.session_manager.clone(),
            session_id: session_id.clone(),
        };

        // 3. Build agent config
        let agent_config = crate::runtime::AgentConfig {
            model: model.to_owned(),
            system_prompt: system_prompt.map(String::from),
            max_turns: 100,
            enable_thinking: true,
            working_directory: Some(workspace_path.clone()),
            server_origin: Some(self.origin.clone()),
            workspace_id: workspace_id.map(String::from),
            ..crate::runtime::AgentConfig::default()
        };

        // 4. Create tools
        let tools = (self.tool_factory)();

        // 5. Build denied tools list from user restrictions
        let tool_names: Vec<String> = tools.names();
        let denied_tools = tool_restrictions
            .map(|r| r.resolve_denied_tools(&tool_names))
            .unwrap_or_default();
        // Interactive tools (AskUserQuestion, etc.)
        // are removed automatically by AgentFactory when is_unattended=true.

        // 6. Create agent via factory
        let mut agent = crate::runtime::AgentFactory::create_agent(
            agent_config,
            session_id.clone(),
            crate::runtime::CreateAgentOpts {
                provider,
                tools,
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
                compaction_trigger_config: crate::runtime::context::types::CompactionTriggerConfig::default(),
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
            })
            .map_err(|e| CronError::Execution(format!("persist user message: {e}")))?;

        // 9. Run agent with timeout
        let broadcast = Arc::new(crate::runtime::EventEmitter::new());
        let run_ctx = crate::runtime::RunContext::default();

        let result = tokio::select! {
            r = crate::runtime::run_agent(
                &mut agent,
                prompt,
                run_ctx,
                &None,
                &broadcast,
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
            let _ = active.context.persister.flush().await;
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

/// Sends APNS push notifications for cron job results.
#[cfg(feature = "apns")]
pub struct CronPushNotifier {
    apns: Arc<ApnsService>,
    pool: ConnectionPool,
}

#[cfg(feature = "apns")]
impl CronPushNotifier {
    /// Create a new notifier with APNS service and DB pool for device tokens.
    pub fn new(apns: Arc<ApnsService>, pool: ConnectionPool) -> Self {
        Self { apns, pool }
    }

    fn active_tokens(&self) -> Result<Vec<String>, CronError> {
        let conn = self
            .pool
            .get()
            .map_err(|e| CronError::Execution(format!("DB connection: {e}")))?;
        let tokens =
            crate::events::sqlite::repositories::device_token::DeviceTokenRepo::get_all_active(&conn)
                .map_err(|e| CronError::Execution(format!("query device tokens: {e}")))?;
        Ok(tokens.into_iter().map(|t| t.device_token).collect())
    }
}

#[cfg(feature = "apns")]
#[async_trait]
impl crate::cron::executor::PushNotifier for CronPushNotifier {
    async fn notify(&self, title: &str, body: &str) -> Result<(), CronError> {
        let tokens = self.active_tokens()?;
        if tokens.is_empty() {
            tracing::debug!("cron push: no active device tokens");
            return Ok(());
        }

        let notification = ApnsNotification {
            title: title.to_owned(),
            body: body.to_owned(),
            data: HashMap::new(),
            priority: "normal".to_owned(),
            sound: Some("default".to_owned()),
            badge: None,
            thread_id: Some("cron".to_owned()),
        };

        let results = self.apns.send_to_many(&tokens, &notification).await;
        let failed = results.iter().filter(|r| !r.success).count();
        if failed > 0 {
            tracing::warn!(
                total = results.len(),
                failed,
                "cron push: some notifications failed"
            );
        }
        Ok(())
    }
}

// ── WebSocket Broadcasting ──────────────────────────────────────────

/// Broadcasts cron events to all connected WebSocket clients.
pub struct CronEventBroadcaster {
    broadcast: Arc<BroadcastManager>,
}

impl CronEventBroadcaster {
    /// Create a new broadcaster.
    pub fn new(broadcast: Arc<BroadcastManager>) -> Self {
        Self { broadcast }
    }
}

#[async_trait]
impl crate::cron::executor::EventBroadcaster for CronEventBroadcaster {
    async fn broadcast_cron_result(&self, job: &CronJob, run: &CronRun) {
        let event = RpcEvent {
            event_type: "cron.runComplete".to_owned(),
            session_id: None,
            timestamp: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            data: Some(serde_json::json!({
                "jobId": job.id,
                "jobName": job.name,
                "runId": run.id,
                "status": serde_json::to_value(&run.status).unwrap_or_default(),
                "durationMs": run.duration_ms,
                "error": run.error,
            })),
            run_id: Some(run.id.clone()),
        };
        self.broadcast.broadcast_all(&event).await;
    }

    async fn broadcast_cron_event(&self, event_type: &str, payload: serde_json::Value) {
        let event = RpcEvent {
            event_type: event_type.to_owned(),
            session_id: None,
            timestamp: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            data: Some(payload),
            run_id: None,
        };
        self.broadcast.broadcast_all(&event).await;
    }
}

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
        let pool = crate::events::new_in_memory(&crate::events::ConnectionConfig::default()).unwrap();
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

    // ── Provider retry tests ──────────────────────────────────────────

    use async_trait::async_trait;
    use futures::stream;
    use crate::core::content::AssistantContent;
    use crate::core::events::{AssistantMessage, StreamEvent};
    use crate::core::messages::TokenUsage;
    use crate::llm::models::types::Provider as ProviderKind;
    use crate::llm::provider::{
        Provider, ProviderError, ProviderFactory, ProviderStreamOptions, StreamEventStream,
    };

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

    struct LedgerMockProviderFactory;
    #[async_trait]
    impl ProviderFactory for LedgerMockProviderFactory {
        async fn create_for_model(&self, _model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
            Ok(Arc::new(LedgerMockProvider))
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
            let remaining = self.failures_remaining.fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
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
            Arc::new(crate::tools::registry::ToolRegistry::new),
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
            Arc::new(crate::tools::registry::ToolRegistry::new),
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
            Arc::new(crate::tools::registry::ToolRegistry::new),
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
