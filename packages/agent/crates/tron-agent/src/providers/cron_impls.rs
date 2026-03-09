//! Cron scheduler trait implementations.
//!
//! Provides real implementations of `tron_cron` callback traits:
//! - [`CronAgentTurnExecutor`] — Isolated agent session execution
//! - [`CronPushNotifier`] — APNS push notifications
//! - [`CronEventBroadcaster`] — WebSocket event broadcasting
//! - [`CronSystemEventInjector`] — Session event injection

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use tron_cron::errors::CronError;
use tron_cron::types::{CronJob, CronRun};
use tron_events::ConnectionPool;
use tron_server::platform::apns::{ApnsNotification, ApnsService};
use tron_server::rpc::types::RpcEvent;
use tron_server::websocket::broadcast::BroadcastManager;
// ── Agent Turn Execution ──────────────────────────────────────────────

/// Maximum output size stored on a [`tron_cron::AgentTurnResult`].
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
    event_store: Arc<tron_events::EventStore>,
    session_manager: Arc<tron_runtime::orchestrator::session_manager::SessionManager>,
    provider_factory: Arc<dyn tron_llm::provider::ProviderFactory>,
    tool_factory: Arc<dyn Fn() -> tron_tools::registry::ToolRegistry + Send + Sync>,
    origin: String,
    subagent_manager: Option<Arc<tron_runtime::orchestrator::subagent_manager::SubagentManager>>,
    embedding_controller: Option<Arc<tokio::sync::Mutex<tron_embeddings::EmbeddingController>>>,
}

impl CronAgentTurnExecutor {
    /// Create a new agent turn executor.
    pub fn new(
        event_store: Arc<tron_events::EventStore>,
        session_manager: Arc<tron_runtime::orchestrator::session_manager::SessionManager>,
        provider_factory: Arc<dyn tron_llm::provider::ProviderFactory>,
        tool_factory: Arc<dyn Fn() -> tron_tools::registry::ToolRegistry + Send + Sync>,
        origin: String,
        subagent_manager: Option<
            Arc<tron_runtime::orchestrator::subagent_manager::SubagentManager>,
        >,
        embedding_controller: Option<Arc<tokio::sync::Mutex<tron_embeddings::EmbeddingController>>>,
    ) -> Self {
        Self {
            event_store,
            session_manager,
            provider_factory,
            tool_factory,
            origin,
            subagent_manager,
            embedding_controller,
        }
    }

    /// Extract output text from the agent's last assistant message.
    fn extract_output(agent: &tron_runtime::agent::tron_agent::TronAgent) -> (String, bool) {
        let messages = agent.context_manager().get_messages();
        let text = messages
            .iter()
            .rev()
            .find_map(|m| {
                if let tron_core::messages::Message::Assistant { content, .. } = m {
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
impl tron_cron::AgentTurnExecutor for CronAgentTurnExecutor {
    async fn execute(
        &self,
        prompt: &str,
        model: Option<&str>,
        workspace_id: Option<&str>,
        system_prompt: Option<&str>,
        tool_restrictions: Option<&tron_cron::ToolRestrictions>,
        cancel: tokio_util::sync::CancellationToken,
    ) -> Result<tron_cron::AgentTurnResult, CronError> {
        // Resolve model (fall back to settings default)
        let settings =
            tron_settings::loader::load_settings_from_path(&tron_settings::loader::settings_path())
                .unwrap_or_default();
        let model = model.unwrap_or(&settings.server.default_model);

        // Resolve workspace path
        let workspace_path = workspace_id
            .and_then(|wid| {
                self.event_store.pool().get().ok().and_then(|conn| {
                    tron_events::sqlite::repositories::workspace::WorkspaceRepo::get_by_id(
                        &conn, wid,
                    )
                    .ok()
                    .flatten()
                    .map(|ws| ws.path)
                })
            })
            .or_else(|| std::env::var("HOME").ok())
            .unwrap_or_else(|| "/tmp".into());

        // 1. Create provider
        let provider = self
            .provider_factory
            .create_for_model(model)
            .await
            .map_err(|e| CronError::Execution(format!("create provider: {e}")))?;

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
        let agent_config = tron_runtime::AgentConfig {
            model: model.to_owned(),
            system_prompt: system_prompt.map(String::from),
            max_turns: 25,
            enable_thinking: true,
            working_directory: Some(workspace_path.clone()),
            server_origin: Some(self.origin.clone()),
            workspace_id: workspace_id.map(String::from),
            ..tron_runtime::AgentConfig::default()
        };

        // 4. Create tools
        let tools = (self.tool_factory)();

        // 5. Build denied tools list: user restrictions + always-denied interactive tools
        let tool_names: Vec<String> = tools.names();
        let mut denied_tools = tool_restrictions
            .map(|r| r.resolve_denied_tools(&tool_names))
            .unwrap_or_default();
        for always_denied in ["AskUserQuestion", "RenderAppUI"] {
            if !denied_tools.iter().any(|t| t == always_denied) {
                denied_tools.push(always_denied.into());
            }
        }

        // 6. Create agent via factory
        let mut agent = tron_runtime::AgentFactory::create_agent(
            agent_config,
            session_id.clone(),
            tron_runtime::CreateAgentOpts {
                provider,
                tools,
                guardrails: None,
                hooks: None,
                is_subagent: false,
                denied_tools,
                subagent_depth: 0,
                subagent_max_depth: 0,
                rules_content: None,
                initial_messages: vec![],
                memory_content: None,
                rules_index: None,
                pre_activated_rules: vec![],
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
            .append(&tron_events::AppendOptions {
                session_id: &session_id,
                event_type: tron_events::EventType::MessageUser,
                payload: serde_json::json!({"content": prompt}),
                parent_id: None,
            })
            .map_err(|e| CronError::Execution(format!("persist user message: {e}")))?;

        // 9. Run agent with timeout
        let broadcast = Arc::new(tron_runtime::EventEmitter::new());
        let run_ctx = tron_runtime::RunContext::default();

        let result = tokio::select! {
            r = tron_runtime::run_agent(
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

        // 13. Write memory ledger entry (fail-silent — never blocks the result)
        let _ = write_cron_ledger(
            &session_id,
            &workspace_path,
            &self.event_store,
            &self.session_manager,
            &self.subagent_manager,
            &self.embedding_controller,
        )
        .await;

        Ok(tron_cron::AgentTurnResult {
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
    session_manager: Arc<tron_runtime::orchestrator::session_manager::SessionManager>,
    session_id: String,
}

impl Drop for SessionGuard {
    fn drop(&mut self) {
        self.session_manager.invalidate_session(&self.session_id);
    }
}

/// Write a memory ledger entry for a completed cron session.
/// Returns `true` if written, `false` if skipped/failed (never errors).
#[allow(clippy::ref_option)]
async fn write_cron_ledger(
    session_id: &str,
    workspace_path: &str,
    event_store: &Arc<tron_events::EventStore>,
    session_manager: &Arc<tron_runtime::orchestrator::session_manager::SessionManager>,
    subagent_manager: &Option<Arc<tron_runtime::orchestrator::subagent_manager::SubagentManager>>,
    embedding_controller: &Option<Arc<tokio::sync::Mutex<tron_embeddings::EmbeddingController>>>,
) -> bool {
    let deps = tron_server::rpc::handlers::memory::LedgerWriteDeps {
        event_store: event_store.clone(),
        session_manager: session_manager.clone(),
        subagent_manager: subagent_manager.clone(),
        embedding_controller: embedding_controller.clone(),
        shutdown_coordinator: None,
    };
    let result = tron_server::rpc::handlers::memory::execute_ledger_write(
        session_id,
        workspace_path,
        &deps,
        "cron",
    )
    .await;
    if result.written {
        tracing::debug!(
            session_id,
            title = ?result.title,
            "cron session ledger entry written"
        );
    } else {
        tracing::debug!(
            session_id,
            reason = ?result.reason,
            "cron session ledger write skipped"
        );
    }
    result.written
}

// ── Push Notifications ──────────────────────────────────────────────

/// Sends APNS push notifications for cron job results.
pub struct CronPushNotifier {
    apns: Arc<ApnsService>,
    pool: ConnectionPool,
}

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
            tron_events::sqlite::repositories::device_token::DeviceTokenRepo::get_all_active(&conn)
                .map_err(|e| CronError::Execution(format!("query device tokens: {e}")))?;
        Ok(tokens.into_iter().map(|t| t.device_token).collect())
    }
}

#[async_trait]
impl tron_cron::PushNotifier for CronPushNotifier {
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
impl tron_cron::EventBroadcaster for CronEventBroadcaster {
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
    event_store: Arc<tron_events::EventStore>,
}

impl CronSystemEventInjector {
    /// Create a new injector.
    pub fn new(event_store: Arc<tron_events::EventStore>) -> Self {
        Self { event_store }
    }
}

#[async_trait]
impl tron_cron::SystemEventInjector for CronSystemEventInjector {
    async fn inject(&self, session_id: &str, message: &str) -> Result<(), CronError> {
        let payload = serde_json::json!({
            "source": "cron",
            "content": message,
        });

        let _ = self
            .event_store
            .append(&tron_events::AppendOptions {
                session_id,
                event_type: tron_events::EventType::MessageSystem,
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

    fn make_test_store_and_manager() -> (
        Arc<tron_events::EventStore>,
        Arc<tron_runtime::orchestrator::session_manager::SessionManager>,
    ) {
        let pool = tron_events::new_in_memory(&tron_events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron_events::run_migrations(&conn).unwrap();
        }
        let store = Arc::new(tron_events::EventStore::new(pool));
        let mgr = Arc::new(
            tron_runtime::orchestrator::session_manager::SessionManager::new(store.clone()),
        );
        (store, mgr)
    }

    #[tokio::test]
    async fn write_cron_ledger_no_subagent_manager() {
        let (store, mgr) = make_test_store_and_manager();
        let sid = mgr.create_session("mock", "/tmp", Some("test")).unwrap();
        // Append a user message so compute_cycle_messages finds something
        let _ = store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: serde_json::json!({"content": "hello"}),
            parent_id: None,
        });
        mgr.invalidate_session(&sid);

        let result = write_cron_ledger(&sid, "/tmp", &store, &mgr, &None, &None).await;
        assert!(!result, "should skip when subagent_manager is None");
    }

    #[tokio::test]
    async fn write_cron_ledger_no_session_events() {
        let (store, mgr) = make_test_store_and_manager();
        let sid = mgr.create_session("mock", "/tmp", Some("empty")).unwrap();
        mgr.invalidate_session(&sid);

        let result = write_cron_ledger(&sid, "/tmp", &store, &mgr, &None, &None).await;
        assert!(!result, "should skip for session with no messages");
    }

    #[tokio::test]
    async fn write_cron_ledger_no_embedding_controller() {
        let (store, mgr) = make_test_store_and_manager();
        let result = write_cron_ledger(
            "nonexistent",
            "/tmp",
            &store,
            &mgr,
            &None,
            &None::<Arc<tokio::sync::Mutex<tron_embeddings::EmbeddingController>>>,
        )
        .await;
        // Must not panic — gracefully returns false
        assert!(!result);
    }

    // ── Mock LLM that returns valid ledger JSON ──

    use async_trait::async_trait;
    use futures::stream;
    use tron_core::content::AssistantContent;
    use tron_core::events::{AssistantMessage, StreamEvent};
    use tron_core::messages::TokenUsage;
    use tron_llm::models::types::Provider as ProviderKind;
    use tron_llm::provider::{
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
            _c: &tron_core::messages::Context,
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

    fn make_subagent_manager_with_mock_llm(
        store: &Arc<tron_events::EventStore>,
        mgr: &Arc<tron_runtime::orchestrator::session_manager::SessionManager>,
    ) -> Arc<tron_runtime::orchestrator::subagent_manager::SubagentManager> {
        let broadcast = Arc::new(tron_runtime::EventEmitter::new());
        let manager = tron_runtime::orchestrator::subagent_manager::SubagentManager::new(
            mgr.clone(),
            store.clone(),
            broadcast,
            Arc::new(LedgerMockProviderFactory),
            None,
            None,
        );
        manager.set_tool_factory(Arc::new(tron_tools::registry::ToolRegistry::new));
        Arc::new(manager)
    }

    /// Seed a session with a user + assistant message cycle for ledger generation.
    fn seed_session_with_messages(
        store: &tron_events::EventStore,
        mgr: &tron_runtime::orchestrator::session_manager::SessionManager,
    ) -> String {
        let sid = mgr
            .create_session("mock", "/tmp", Some("cron test"))
            .unwrap();
        let _ = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: serde_json::json!({"content": "Hello from cron"}),
                parent_id: None,
            })
            .unwrap();
        // Assistant text must be >= 500 chars to pass cron no-op filter
        let long_response = "x".repeat(600);
        let _ = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": [{"type": "text", "text": long_response}],
                    "turn": 1,
                    "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
                }),
                parent_id: None,
            })
            .unwrap();
        mgr.invalidate_session(&sid);
        sid
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn write_cron_ledger_source_is_cron() {
        let (store, mgr) = make_test_store_and_manager();
        let sid = seed_session_with_messages(&store, &mgr);
        let subagent = make_subagent_manager_with_mock_llm(&store, &mgr);

        let deps = tron_server::rpc::handlers::memory::LedgerWriteDeps {
            event_store: store.clone(),
            session_manager: mgr.clone(),
            subagent_manager: Some(subagent),
            embedding_controller: None,
            shutdown_coordinator: None,
        };
        let lw =
            tron_server::rpc::handlers::memory::execute_ledger_write(&sid, "/tmp", &deps, "cron")
                .await;
        assert!(
            lw.written,
            "ledger write should succeed: reason={:?}",
            lw.reason
        );

        // Verify the persisted memory.ledger event has source: "cron"
        let events = store
            .get_events_by_type(&sid, &["memory.ledger"], Some(10))
            .unwrap();
        assert_eq!(events.len(), 1, "should have exactly 1 ledger event");
        let payload: serde_json::Value = serde_json::from_str(&events[0].payload).unwrap();
        assert_eq!(payload["source"], "cron");
    }
}
