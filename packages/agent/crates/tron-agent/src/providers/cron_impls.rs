//! Cron scheduler trait implementations.
//!
//! Provides real implementations of `tron_cron` callback traits:
//! - [`CronAgentTurnExecutor`] — Isolated agent session execution
//! - [`CronPushNotifier`] — APNS push notifications
//! - [`CronEventBroadcaster`] — WebSocket event broadcasting
//! - [`CronSystemEventInjector`] — Session event injection
//! - [`CronDelegateImpl`] — ManageAutomations tool delegate

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use tron_cron::errors::CronError;
use tron_cron::types::{CronJob, CronRun};
use tron_events::ConnectionPool;
use tron_server::platform::apns::{ApnsNotification, ApnsService};
use tron_server::rpc::types::RpcEvent;
use tron_server::websocket::broadcast::BroadcastManager;
use tron_tools::errors::ToolError;

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
}

impl CronAgentTurnExecutor {
    /// Create a new agent turn executor.
    pub fn new(
        event_store: Arc<tron_events::EventStore>,
        session_manager: Arc<tron_runtime::orchestrator::session_manager::SessionManager>,
        provider_factory: Arc<dyn tron_llm::provider::ProviderFactory>,
        tool_factory: Arc<dyn Fn() -> tron_tools::registry::ToolRegistry + Send + Sync>,
        origin: String,
    ) -> Self {
        Self {
            event_store,
            session_manager,
            provider_factory,
            tool_factory,
            origin,
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
                    if text.is_empty() {
                        None
                    } else {
                        Some(text)
                    }
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
        cancel: tokio_util::sync::CancellationToken,
    ) -> Result<tron_cron::AgentTurnResult, CronError> {
        // Resolve model (fall back to settings default)
        let settings = tron_settings::loader::load_settings_from_path(
            &tron_settings::loader::settings_path(),
        )
        .unwrap_or_default();
        let model = model.unwrap_or(&settings.server.default_model);

        // Resolve workspace path
        let workspace_path = workspace_id
            .and_then(|wid| {
                self.event_store
                    .pool()
                    .get()
                    .ok()
                    .and_then(|conn| {
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
            working_directory: Some(workspace_path),
            server_origin: Some(self.origin.clone()),
            workspace_id: workspace_id.map(String::from),
            ..tron_runtime::AgentConfig::default()
        };

        // 4. Create tools
        let tools = (self.tool_factory)();

        // 5. Create agent via factory
        let mut agent = tron_runtime::AgentFactory::create_agent(
            agent_config,
            session_id.clone(),
            tron_runtime::CreateAgentOpts {
                provider,
                tools,
                guardrails: None,
                hooks: None,
                is_subagent: false,
                denied_tools: vec![
                    // Deny interactive tools that don't make sense for background runs
                    "AskUserQuestion".into(),
                    "RenderAppUI".into(),
                ],
                subagent_depth: 0,
                subagent_max_depth: 0,
                rules_content: None,
                initial_messages: vec![],
                memory_content: None,
                rules_index: None,
                pre_activated_rules: vec![],
            },
        );

        // 6. Wire abort token + persister
        agent.set_abort_token(cancel.clone());

        let active = self
            .session_manager
            .resume_session(&session_id)
            .map_err(|e| CronError::Execution(format!("resume session: {e}")))?;
        agent.set_persister(Some(active.context.persister.clone()));

        // 7. Persist the user message event
        let _ = self
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &session_id,
                event_type: tron_events::EventType::MessageUser,
                payload: serde_json::json!({"content": prompt}),
                parent_id: None,
            })
            .map_err(|e| CronError::Execution(format!("persist user message: {e}")))?;

        // 8. Run agent with timeout
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
            _ = tokio::time::sleep(std::time::Duration::from_secs(DEFAULT_TURN_TIMEOUT_SECS)) => {
                return Err(CronError::TimedOut);
            }
        };

        // 9. Check for agent errors
        if let Some(ref error) = result.error {
            return Err(CronError::Execution(format!("agent error: {error}")));
        }

        // 10. Extract output
        let (output, output_truncated) = Self::extract_output(&agent);

        // 11. Flush persister
        if let Ok(active) = self.session_manager.resume_session(&session_id) {
            let _ = active.context.persister.flush().await;
        }

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
            timestamp: chrono::Utc::now()
                .to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
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
            timestamp: chrono::Utc::now()
                .to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
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

// ── ManageAutomations Tool Delegate ─────────────────────────────────

/// Implements `CronDelegate` for the `ManageAutomations` tool.
///
/// Routes tool actions to the same `CronScheduler` + config/store functions
/// used by the RPC handlers, ensuring identical behavior.
pub struct CronDelegateImpl {
    scheduler: Arc<tron_cron::CronScheduler>,
}

impl CronDelegateImpl {
    pub fn new(scheduler: Arc<tron_cron::CronScheduler>) -> Self {
        Self { scheduler }
    }

    fn err(msg: impl Into<String>) -> ToolError {
        ToolError::Internal {
            message: msg.into(),
        }
    }

    fn not_found(msg: impl Into<String>) -> ToolError {
        ToolError::Internal {
            message: msg.into(),
        }
    }

    fn runtime_state_json(rs: &tron_cron::JobRuntimeState) -> Value {
        json!({
            "jobId": rs.job_id,
            "nextRunAt": rs.next_run_at,
            "lastRunAt": rs.last_run_at,
            "consecutiveFailures": rs.consecutive_failures,
            "runningSince": rs.running_since,
        })
    }

    async fn handle_list(&self, params: &Value) -> Result<Value, ToolError> {
        let jobs = self.scheduler.jobs();

        let enabled_filter = params.get("enabled").and_then(|v| v.as_bool());
        let tag_filter = params
            .get("tags")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect::<Vec<_>>()
            });
        let workspace_filter = params.get("workspaceId").and_then(|v| v.as_str());

        let filtered: Vec<_> = jobs
            .values()
            .filter(|j| {
                if let Some(enabled) = enabled_filter {
                    if j.enabled != enabled {
                        return false;
                    }
                }
                if let Some(ref tags) = tag_filter {
                    if !tags.iter().any(|t| j.tags.contains(t)) {
                        return false;
                    }
                }
                if let Some(ws) = workspace_filter {
                    if j.workspace_id.as_deref() != Some(ws) {
                        return false;
                    }
                }
                true
            })
            .collect();

        let runtime_states: Vec<_> = filtered
            .iter()
            .filter_map(|j| self.scheduler.get_runtime_state(&j.id))
            .map(|rs| Self::runtime_state_json(&rs))
            .collect();

        Ok(json!({
            "jobs": serde_json::to_value(&filtered).map_err(|e| Self::err(e.to_string()))?,
            "runtimeState": runtime_states,
        }))
    }

    async fn handle_get(&self, params: &Value) -> Result<Value, ToolError> {
        let job_id = params
            .get("jobId")
            .and_then(|v| v.as_str())
            .ok_or_else(|| Self::err("Missing required parameter: jobId"))?;

        let jobs = self.scheduler.jobs();
        let job = jobs
            .get(job_id)
            .ok_or_else(|| Self::not_found(format!("Job not found: {job_id}")))?;

        let runtime_state = self.scheduler.get_runtime_state(job_id);
        let (recent_runs, _total) =
            tron_cron::store::get_runs(self.scheduler.pool(), Some(job_id), None, 10, 0)
                .map_err(|e| Self::err(e.to_string()))?;

        Ok(json!({
            "job": serde_json::to_value(job).map_err(|e| Self::err(e.to_string()))?,
            "runtimeState": runtime_state.map(|rs| Self::runtime_state_json(&rs)),
            "recentRuns": serde_json::to_value(&recent_runs).map_err(|e| Self::err(e.to_string()))?,
        }))
    }

    async fn handle_create(&self, params: &Value) -> Result<Value, ToolError> {
        let name = params
            .get("name")
            .and_then(|v| v.as_str())
            .ok_or_else(|| Self::err("Missing required parameter: name"))?;

        let schedule: tron_cron::types::Schedule = serde_json::from_value(
            params
                .get("schedule")
                .cloned()
                .ok_or_else(|| Self::err("Missing required parameter: schedule"))?,
        )
        .map_err(|e| Self::err(format!("Invalid schedule: {e}")))?;

        let payload: tron_cron::types::Payload = serde_json::from_value(
            params
                .get("payload")
                .cloned()
                .ok_or_else(|| Self::err("Missing required parameter: payload"))?,
        )
        .map_err(|e| Self::err(format!("Invalid payload: {e}")))?;

        let delivery: Vec<tron_cron::types::Delivery> = params
            .get("delivery")
            .map(|v| serde_json::from_value(v.clone()))
            .transpose()
            .map_err(|e| Self::err(format!("Invalid delivery: {e}")))?
            .unwrap_or_default();

        let now = chrono::Utc::now();
        let job = tron_cron::CronJob {
            id: format!("cron_{}", uuid::Uuid::now_v7()),
            name: name.to_owned(),
            description: params
                .get("description")
                .and_then(|v| v.as_str())
                .map(String::from),
            enabled: params
                .get("enabled")
                .and_then(|v| v.as_bool())
                .unwrap_or(true),
            schedule,
            payload,
            delivery,
            overlap_policy: params
                .get("overlapPolicy")
                .map(|v| serde_json::from_value(v.clone()))
                .transpose()
                .map_err(|e| Self::err(format!("Invalid overlapPolicy: {e}")))?
                .unwrap_or_default(),
            misfire_policy: params
                .get("misfirePolicy")
                .map(|v| serde_json::from_value(v.clone()))
                .transpose()
                .map_err(|e| Self::err(format!("Invalid misfirePolicy: {e}")))?
                .unwrap_or_default(),
            max_retries: params
                .get("maxRetries")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as u32,
            auto_disable_after: params
                .get("autoDisableAfter")
                .and_then(|v| v.as_u64())
                .unwrap_or(0) as u32,
            stuck_timeout_secs: params
                .get("stuckTimeoutSecs")
                .and_then(|v| v.as_u64())
                .unwrap_or(7200),
            tags: params
                .get("tags")
                .and_then(|v| v.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default(),
            workspace_id: params
                .get("workspaceId")
                .and_then(|v| v.as_str())
                .map(String::from),
            created_at: now,
            updated_at: now,
        };

        tron_cron::config::validate_job(&job)
            .map_err(|e| Self::err(format!("Validation error: {e}")))?;

        let _guard = self.scheduler.config_lock().lock().await;

        if tron_cron::store::name_exists(self.scheduler.pool(), &job.name, None)
            .map_err(|e| Self::err(e.to_string()))?
        {
            return Err(Self::err(format!(
                "Job with name '{}' already exists",
                job.name
            )));
        }

        let mut config = tron_cron::config::load_config(self.scheduler.config_path(), self.scheduler.backup_path())
            .map_err(|e| Self::err(e.to_string()))?;

        config.jobs.push(job.clone());

        tron_cron::config::save_config(self.scheduler.config_path(), self.scheduler.backup_path(), &config)
            .map_err(|e| Self::err(e.to_string()))?;

        tron_cron::store::upsert_job(self.scheduler.pool(), &job)
            .map_err(|e| Self::err(e.to_string()))?;

        let next = tron_cron::schedule::compute_next_run(&job.schedule, now);
        let _ = tron_cron::store::update_next_run_at(self.scheduler.pool(), &job.id, next);

        self.scheduler.reload_job(job.clone());
        self.scheduler
            .update_runtime(tron_cron::JobRuntimeState {
                job_id: job.id.clone(),
                next_run_at: next,
                last_run_at: None,
                consecutive_failures: 0,
                running_since: None,
            });

        drop(_guard);
        self.scheduler.reschedule_notify().notify_one();

        Ok(json!({
            "job": serde_json::to_value(&job).map_err(|e| Self::err(e.to_string()))?,
        }))
    }

    async fn handle_update(&self, params: &Value) -> Result<Value, ToolError> {
        let job_id = params
            .get("jobId")
            .and_then(|v| v.as_str())
            .ok_or_else(|| Self::err("Missing required parameter: jobId"))?
            .to_owned();

        let _guard = self.scheduler.config_lock().lock().await;

        let mut config = tron_cron::config::load_config(self.scheduler.config_path(), self.scheduler.backup_path())
            .map_err(|e| Self::err(e.to_string()))?;

        let job = config
            .jobs
            .iter_mut()
            .find(|j| j.id == job_id)
            .ok_or_else(|| Self::not_found(format!("Job not found: {job_id}")))?;

        if let Some(name) = params.get("name").and_then(|v| v.as_str()) {
            if tron_cron::store::name_exists(self.scheduler.pool(), name, Some(&job_id))
                .map_err(|e| Self::err(e.to_string()))?
            {
                return Err(Self::err(format!(
                    "Job with name '{name}' already exists"
                )));
            }
            job.name = name.to_owned();
        }
        if let Some(desc) = params.get("description") {
            job.description = desc.as_str().map(String::from);
        }
        if let Some(enabled) = params.get("enabled").and_then(|v| v.as_bool()) {
            job.enabled = enabled;
        }
        if let Some(sched_val) = params.get("schedule") {
            job.schedule = serde_json::from_value(sched_val.clone())
                .map_err(|e| Self::err(format!("Invalid schedule: {e}")))?;
        }
        if let Some(payload_val) = params.get("payload") {
            job.payload = serde_json::from_value(payload_val.clone())
                .map_err(|e| Self::err(format!("Invalid payload: {e}")))?;
        }
        if let Some(delivery_val) = params.get("delivery") {
            job.delivery = serde_json::from_value(delivery_val.clone())
                .map_err(|e| Self::err(format!("Invalid delivery: {e}")))?;
        }
        if let Some(v) = params.get("overlapPolicy") {
            job.overlap_policy = serde_json::from_value(v.clone())
                .map_err(|e| Self::err(format!("Invalid overlapPolicy: {e}")))?;
        }
        if let Some(v) = params.get("misfirePolicy") {
            job.misfire_policy = serde_json::from_value(v.clone())
                .map_err(|e| Self::err(format!("Invalid misfirePolicy: {e}")))?;
        }
        if let Some(v) = params.get("maxRetries").and_then(|v| v.as_u64()) {
            job.max_retries = v as u32;
        }
        if let Some(v) = params.get("autoDisableAfter").and_then(|v| v.as_u64()) {
            job.auto_disable_after = v as u32;
        }
        if let Some(v) = params.get("stuckTimeoutSecs").and_then(|v| v.as_u64()) {
            job.stuck_timeout_secs = v;
        }
        if let Some(tags) = params.get("tags").and_then(|v| v.as_array()) {
            job.tags = tags
                .iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect();
        }
        if let Some(ws) = params.get("workspaceId") {
            job.workspace_id = ws.as_str().map(String::from);
        }

        job.updated_at = chrono::Utc::now();

        tron_cron::config::validate_job(job)
            .map_err(|e| Self::err(format!("Validation error: {e}")))?;

        let updated_job = job.clone();

        tron_cron::config::save_config(self.scheduler.config_path(), self.scheduler.backup_path(), &config)
            .map_err(|e| Self::err(e.to_string()))?;

        tron_cron::store::upsert_job(self.scheduler.pool(), &updated_job)
            .map_err(|e| Self::err(e.to_string()))?;

        let now = chrono::Utc::now();
        let next = tron_cron::schedule::compute_next_run(&updated_job.schedule, now);
        let _ = tron_cron::store::update_next_run_at(self.scheduler.pool(), &updated_job.id, next);

        self.scheduler.reload_job(updated_job.clone());
        if let Some(mut rs) = self.scheduler.get_runtime_state(&updated_job.id) {
            rs.next_run_at = next;
            self.scheduler.update_runtime(rs);
        }

        drop(_guard);
        self.scheduler.reschedule_notify().notify_one();

        Ok(json!({
            "job": serde_json::to_value(&updated_job).map_err(|e| Self::err(e.to_string()))?,
        }))
    }

    async fn handle_delete(&self, params: &Value) -> Result<Value, ToolError> {
        let job_id = params
            .get("jobId")
            .and_then(|v| v.as_str())
            .ok_or_else(|| Self::err("Missing required parameter: jobId"))?
            .to_owned();

        let _guard = self.scheduler.config_lock().lock().await;

        let mut config = tron_cron::config::load_config(self.scheduler.config_path(), self.scheduler.backup_path())
            .map_err(|e| Self::err(e.to_string()))?;

        let before_len = config.jobs.len();
        config.jobs.retain(|j| j.id != job_id);
        if config.jobs.len() == before_len {
            return Err(Self::not_found(format!("Job not found: {job_id}")));
        }

        tron_cron::config::save_config(self.scheduler.config_path(), self.scheduler.backup_path(), &config)
            .map_err(|e| Self::err(e.to_string()))?;

        let _ = tron_cron::store::delete_job(self.scheduler.pool(), &job_id)
            .map_err(|e| Self::err(e.to_string()))?;

        self.scheduler.remove_job(&job_id);

        drop(_guard);
        self.scheduler.reschedule_notify().notify_one();

        Ok(json!({ "deleted": true }))
    }

    async fn handle_trigger(&self, params: &Value) -> Result<Value, ToolError> {
        let job_id = params
            .get("jobId")
            .and_then(|v| v.as_str())
            .ok_or_else(|| Self::err("Missing required parameter: jobId"))?
            .to_owned();

        let jobs = self.scheduler.jobs();
        if !jobs.contains_key(&job_id) {
            return Err(Self::not_found(format!("Job not found: {job_id}")));
        }

        let now = chrono::Utc::now();
        let _ = tron_cron::store::update_next_run_at(self.scheduler.pool(), &job_id, Some(now));

        if let Some(mut rs) = self.scheduler.get_runtime_state(&job_id) {
            rs.next_run_at = Some(now);
            self.scheduler.update_runtime(rs);
        }

        self.scheduler.reschedule_notify().notify_one();

        Ok(json!({
            "triggered": true,
            "jobId": job_id,
        }))
    }

    async fn handle_status(&self) -> Result<Value, ToolError> {
        Ok(json!({
            "running": true,
            "jobCount": self.scheduler.job_count(),
            "activeRuns": self.scheduler.active_run_count(),
            "nextWakeup": self.scheduler.next_wakeup(),
            "executionLimit": 10,
        }))
    }

    async fn handle_get_runs(&self, params: &Value) -> Result<Value, ToolError> {
        let job_id = params
            .get("jobId")
            .and_then(|v| v.as_str())
            .ok_or_else(|| Self::err("Missing required parameter: jobId"))?;

        let limit = params
            .get("limit")
            .and_then(|v| v.as_u64())
            .unwrap_or(20) as u32;

        let offset = params
            .get("offset")
            .and_then(|v| v.as_u64())
            .unwrap_or(0) as u32;

        let status_filter = params.get("status").and_then(|v| v.as_str());

        let (runs, total) = tron_cron::store::get_runs(
            self.scheduler.pool(),
            Some(job_id),
            status_filter,
            limit,
            offset,
        )
        .map_err(|e| Self::err(e.to_string()))?;

        Ok(json!({
            "runs": serde_json::to_value(&runs).map_err(|e| Self::err(e.to_string()))?,
            "total": total,
        }))
    }
}

#[async_trait]
impl tron_tools::traits::CronDelegate for CronDelegateImpl {
    async fn execute_action(&self, action: &str, params: Value) -> Result<Value, ToolError> {
        match action {
            "list" => self.handle_list(&params).await,
            "get" => self.handle_get(&params).await,
            "create" => self.handle_create(&params).await,
            "update" => self.handle_update(&params).await,
            "delete" => self.handle_delete(&params).await,
            "trigger" => self.handle_trigger(&params).await,
            "status" => self.handle_status().await,
            "get_runs" => self.handle_get_runs(&params).await,
            other => Err(ToolError::Internal {
                message: format!("Unknown action: {other}"),
            }),
        }
    }
}
