//! Agent handlers: prompt, abort, getState.

use std::collections::HashSet;
use std::fmt::Write;
use std::sync::Arc;

use async_trait::async_trait;
use serde_json::Value;
use tracing::{info, instrument, warn};
use tron_events::EventType;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::{self, RpcError};
use crate::rpc::handlers::require_string_param;
use crate::rpc::registry::MethodHandler;

/// Extract skill/spell names from a JSON array.
///
/// iOS sends objects `[{name: "skill-name", source: "global"}]` while
/// desktop may send plain strings `["skill-name"]`. This handles both.
fn extract_skills(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| {
                    v.get("name")
                        .and_then(|n| n.as_str())
                        .or_else(|| v.as_str())
                        .map(String::from)
                })
                .collect()
        })
        .unwrap_or_default()
}

// =============================================================================
// Subagent results — reconstruction from event store
// =============================================================================

/// Query unconsumed subagent results from the event store.
///
/// Returns `(event_id, payload_json)` pairs for `notification.subagent_result`
/// events that have no matching `subagent.results_consumed` event referencing
/// their ID. Works identically for live sessions and session resume.
fn get_pending_subagent_results(
    event_store: &tron_events::EventStore,
    session_id: &str,
) -> Vec<(String, Value)> {
    let notifications = event_store
        .get_events_by_type(session_id, &["notification.subagent_result"], None)
        .unwrap_or_default();

    if notifications.is_empty() {
        return vec![];
    }

    // Build set of consumed notification event IDs
    let consumed_events = event_store
        .get_events_by_type(session_id, &["subagent.results_consumed"], None)
        .unwrap_or_default();

    let mut consumed_ids: HashSet<String> = HashSet::new();
    for event in &consumed_events {
        if let Ok(payload) = serde_json::from_str::<Value>(&event.payload) {
            if let Some(ids) = payload.get("consumedEventIds").and_then(|v| v.as_array()) {
                for id in ids {
                    if let Some(s) = id.as_str() {
                        let _ = consumed_ids.insert(s.to_owned());
                    }
                }
            }
        }
    }

    // Filter unconsumed notifications
    notifications
        .into_iter()
        .filter(|e| !consumed_ids.contains(&e.id))
        .filter_map(|e| {
            serde_json::from_str::<Value>(&e.payload)
                .ok()
                .map(|p| (e.id, p))
        })
        .collect()
}

/// Format pending subagent results into markdown context string.
fn format_subagent_results(results: &[(String, Value)]) -> Option<String> {
    if results.is_empty() {
        return None;
    }

    let mut ctx = String::from("# Completed Sub-Agent Results\n\n");
    ctx.push_str(
        "The following sub-agent(s) have completed since your last turn. \
         Review their results and incorporate them into your response.\n\n",
    );

    for (_event_id, payload) in results {
        let success = payload
            .get("success")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let icon = if success { "+" } else { "x" };
        let subagent_id = payload
            .get("subagentSessionId")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let task = payload
            .get("task")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let total_turns = payload
            .get("totalTurns")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let duration = payload.get("duration").and_then(Value::as_i64).unwrap_or(0);

        writeln!(ctx, "## [{icon}] Sub-Agent: `{subagent_id}`\n").unwrap();
        writeln!(ctx, "**Task**: {task}").unwrap();
        writeln!(
            ctx,
            "**Status**: {}",
            if success { "Completed" } else { "Failed" }
        )
        .unwrap();
        writeln!(ctx, "**Turns**: {total_turns}").unwrap();
        #[allow(clippy::cast_precision_loss)]
        let duration_secs = duration as f64 / 1000.0;
        writeln!(ctx, "**Duration**: {duration_secs:.1}s").unwrap();

        if let Some(output) = payload.get("output").and_then(Value::as_str) {
            if !output.is_empty() {
                let truncated = if output.len() > 2000 {
                    format!("{}\n\n... [Output truncated]", &output[..2000])
                } else {
                    output.to_string()
                };
                write!(ctx, "\n**Output**:\n```\n{truncated}\n```\n").unwrap();
            }
        }
        ctx.push_str("\n---\n\n");
    }
    Some(ctx)
}

// =============================================================================
// RuntimeMemoryDeps — implements MemoryManagerDeps for the prompt handler
// =============================================================================

/// Runtime implementation of `MemoryManagerDeps` for the auto-ledger pipeline.
///
/// Created inside the spawned task after `run_agent()` completes. Captures
/// references to provider, event store, session manager, and broadcast.
struct RuntimeMemoryDeps {
    subagent_manager: Option<Arc<tron_runtime::orchestrator::subagent_manager::SubagentManager>>,
    event_store: Arc<tron_events::EventStore>,
    session_manager: Arc<tron_runtime::orchestrator::session_manager::SessionManager>,
    broadcast: Arc<tron_runtime::EventEmitter>,
    session_id: String,
    workspace_id: String,
    embedding_controller: Option<Arc<tokio::sync::Mutex<tron_embeddings::EmbeddingController>>>,
    shutdown_coordinator: Option<Arc<crate::shutdown::ShutdownCoordinator>>,
    ledger_enabled: bool,
}

#[async_trait]
impl tron_events::memory::manager::MemoryManagerDeps for RuntimeMemoryDeps {
    async fn execute_compaction(&self) -> Result<(), tron_events::memory::errors::MemoryError> {
        use tron_runtime::agent::compaction_handler::SubagentManagerSpawner;

        // Build a context manager from the session (same approach as CompactHandler)
        let state = self
            .session_manager
            .resume_session(&self.session_id)
            .map_err(|e| tron_events::memory::errors::MemoryError::Compaction(e.to_string()))?;

        if state.state.messages.is_empty() {
            return Ok(());
        }

        let context_limit = tron_llm::tokens::get_context_limit(&state.state.model);
        let tools = Vec::new(); // Tool defs not needed for compaction summary
        let mut cm = tron_runtime::context::context_manager::ContextManager::new(
            tron_runtime::context::types::ContextManagerConfig {
                model: state.state.model.clone(),
                system_prompt: None,
                working_directory: state.state.working_directory.clone(),
                tools,
                rules_content: None,
                compaction: tron_runtime::context::types::CompactionConfig {
                    context_limit,
                    ..Default::default()
                },
            },
        );
        for msg in &state.state.messages {
            cm.add_message(msg.clone());
        }

        // Execute compaction via subsession (LLM) or keyword fallback
        let result = if let Some(ref manager) = self.subagent_manager {
            let spawner = SubagentManagerSpawner {
                manager: manager.clone(),
                parent_session_id: self.session_id.clone(),
                working_directory: state.state.working_directory.clone().unwrap_or_default(),
                system_prompt: tron_runtime::context::system_prompts::COMPACTION_SUMMARIZER_PROMPT
                    .to_string(),
                model: None, // Use session's model
            };
            let summarizer = tron_runtime::context::llm_summarizer::LlmSummarizer::new(spawner);
            cm.execute_compaction(&summarizer, None).await
        } else {
            let summarizer = tron_runtime::context::summarizer::KeywordSummarizer;
            cm.execute_compaction(&summarizer, None).await
        };

        let result = result
            .map_err(|e| tron_events::memory::errors::MemoryError::Compaction(e.to_string()))?;

        // Persist compact.summary event
        let _ = self.event_store.append(&tron_events::AppendOptions {
            session_id: &self.session_id,
            event_type: tron_events::EventType::CompactSummary,
            payload: serde_json::json!({
                "summary": result.summary,
                "tokensBefore": result.tokens_before,
                "tokensAfter": result.tokens_after,
                "compressionRatio": result.compression_ratio,
            }),
            parent_id: None,
        });

        // Broadcast compaction complete
        let _ = self
            .broadcast
            .emit(tron_core::events::TronEvent::CompactionComplete {
                base: tron_core::events::BaseEvent::now(&self.session_id),
                success: result.success,
                tokens_before: result.tokens_before,
                tokens_after: result.tokens_after,
                compression_ratio: result.compression_ratio,
                reason: Some(tron_core::events::CompactionReason::ThresholdExceeded),
                summary: Some(result.summary),
                estimated_context_tokens: None,
            });

        // Invalidate cached session
        self.session_manager.invalidate_session(&self.session_id);

        Ok(())
    }

    async fn write_ledger_entry(
        &self,
        _opts: &tron_events::memory::types::LedgerWriteOpts,
    ) -> tron_events::memory::types::LedgerWriteResult {
        // Delegate to the shared pipeline (same codepath as manual UpdateLedgerHandler).
        let deps = crate::rpc::handlers::memory::LedgerWriteDeps {
            event_store: self.event_store.clone(),
            session_manager: self.session_manager.clone(),
            subagent_manager: self.subagent_manager.clone(),
            embedding_controller: self.embedding_controller.clone(),
            shutdown_coordinator: self.shutdown_coordinator.clone(),
        };
        crate::rpc::handlers::memory::execute_ledger_write(
            &self.session_id,
            &self.workspace_id,
            &deps,
            "auto",
        )
        .await
    }

    fn is_ledger_enabled(&self) -> bool {
        self.ledger_enabled
    }

    fn emit_memory_updating(&self, _session_id: &str) {
        let _ = self
            .broadcast
            .emit(tron_core::events::TronEvent::MemoryUpdating {
                base: tron_core::events::BaseEvent::now(&self.session_id),
            });
    }

    fn emit_memory_updated(
        &self,
        _session_id: &str,
        title: Option<&str>,
        entry_type: Option<&str>,
        event_id: Option<&str>,
    ) {
        let _ = self
            .broadcast
            .emit(tron_core::events::TronEvent::MemoryUpdated {
                base: tron_core::events::BaseEvent::now(&self.session_id),
                title: title.map(String::from),
                entry_type: entry_type.map(String::from),
                event_id: event_id.map(String::from),
            });
    }

    fn on_memory_written(&self, _payload: &serde_json::Value, _title: &str) {
        // No-op
    }

    fn session_id(&self) -> &str {
        &self.session_id
    }

    fn workspace_id(&self) -> Option<&str> {
        Some(&self.workspace_id)
    }
}

/// Gather recent event types and Bash tool call commands since the last compact.boundary.
///
/// Returns `(event_types, bash_commands)` for the compaction trigger's progress-signal check.
fn gather_recent_events(
    event_store: &tron_events::EventStore,
    session_id: &str,
) -> (Vec<String>, Vec<String>) {
    // Find last compact.boundary event
    let boundary = event_store
        .get_events_by_type(session_id, &["compact.boundary"], Some(1))
        .ok()
        .and_then(|rows| rows.into_iter().last());

    // Get events after boundary (or all events if no boundary)
    let events = if let Some(ref b) = boundary {
        event_store
            .get_events_since(session_id, b.sequence)
            .unwrap_or_default()
    } else {
        event_store
            .get_events_by_session(
                session_id,
                &tron_events::sqlite::repositories::event::ListEventsOptions::default(),
            )
            .unwrap_or_default()
    };

    let mut event_types = Vec::new();
    let mut bash_commands = Vec::new();

    for event in &events {
        event_types.push(event.event_type.clone());

        if event.event_type == "tool.call" && event.tool_name.as_deref() == Some("Bash") {
            if let Ok(payload) = serde_json::from_str::<serde_json::Value>(&event.payload) {
                if let Some(cmd) = payload
                    .get("arguments")
                    .and_then(|a| a.get("command"))
                    .and_then(|c| c.as_str())
                {
                    bash_commands.push(cmd.to_string());
                }
            }
        }
    }

    (event_types, bash_commands)
}

/// Submit a prompt to the agent for a session.
pub struct PromptHandler;

#[async_trait]
impl MethodHandler for PromptHandler {
    #[instrument(skip(self, ctx), fields(method = "agent.prompt", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let prompt = require_string_param(params.as_ref(), "prompt")?;

        crate::rpc::validation::validate_string_param(
            &prompt,
            "prompt",
            crate::rpc::validation::MAX_PROMPT_LENGTH,
        )?;

        // Extract optional extra params (iOS sends these)
        let reasoning_level = params
            .as_ref()
            .and_then(|p| p.get("reasoningLevel"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let images = params
            .as_ref()
            .and_then(|p| p.get("images"))
            .and_then(|v| v.as_array())
            .cloned();
        let attachments = params
            .as_ref()
            .and_then(|p| p.get("attachments"))
            .and_then(|v| v.as_array())
            .cloned();
        let skills = {
            let v = extract_skills(params.as_ref().and_then(|p| p.get("skills")));
            if v.is_empty() { None } else { Some(v) }
        };
        let spells = {
            let v = extract_skills(params.as_ref().and_then(|p| p.get("spells")));
            if v.is_empty() { None } else { Some(v) }
        };

        // Verify the session exists and get its details
        let session = ctx
            .session_manager
            .get_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;

        let run_id = uuid::Uuid::now_v7().to_string();

        // Register the run with the orchestrator (tracks CancellationToken).
        // If the session already has an active run, this returns an error.
        let cancel_token = ctx
            .orchestrator
            .start_run(&session_id, &run_id)
            .map_err(|e| RpcError::Custom {
                code: e.category().to_uppercase(),
                message: e.to_string(),
                details: None,
            })?;

        // If agent deps are configured, spawn background execution
        if let Some(deps) = &ctx.agent_deps {
            let orchestrator = ctx.orchestrator.clone();
            let session_manager = ctx.session_manager.clone();
            let broadcast = orchestrator.broadcast().clone();
            let provider_factory = deps.provider_factory.clone();
            let tool_factory = deps.tool_factory.clone();
            let guardrails = deps.guardrails.clone();
            let hooks = deps.hooks.clone();
            let health_tracker = ctx.health_tracker.clone();
            let session_id_clone = session_id.clone();
            let run_id_clone = run_id.clone();
            let model = session.latest_model.clone();
            let working_dir = session.working_directory.clone();

            let event_store = ctx.event_store.clone();
            let embedding_controller = ctx.embedding_controller.clone();
            let skill_registry = ctx.skill_registry.clone();
            let subagent_manager = ctx.subagent_manager.clone();
            let shutdown_coordinator = ctx.shutdown_coordinator.clone();
            let shutdown_coordinator_for_register = ctx.shutdown_coordinator.clone();
            let prompt_clone = prompt.clone();
            let reasoning_level_clone = reasoning_level.clone();
            let images_clone = images.clone();
            let attachments_clone = attachments.clone();
            let skills_clone = skills.clone();
            let spells_clone = spells.clone();

            let handle = tokio::spawn(async move {
                use tron_runtime::orchestrator::agent_factory::{AgentFactory, CreateAgentOpts};
                use tron_runtime::orchestrator::agent_runner::run_agent;
                use tron_runtime::types::{AgentConfig, RunContext};

                // Grab settings once — consistent snapshot for the entire run
                let settings = tron_settings::get_settings();

                // 1. Resume session to get reconstructed state + persister
                let (state, persister) = match session_manager.resume_session(&session_id_clone) {
                    Ok(active) => (active.state.clone(), active.context.persister.clone()),
                    Err(e) => {
                        warn!(session_id = %session_id_clone, error = %e, "failed to resume session, starting fresh");
                        let fresh_state =
                            tron_runtime::orchestrator::session_reconstructor::ReconstructedState {
                                model: model.clone(),
                                working_directory: Some(working_dir.clone()),
                                ..Default::default()
                            };
                        let fresh_persister = std::sync::Arc::new(
                            tron_runtime::orchestrator::event_persister::EventPersister::new(
                                event_store.clone(),
                                session_id_clone.clone(),
                            ),
                        );
                        (fresh_state, fresh_persister)
                    }
                };

                // 2. Load project rules via ContextLoader
                let project_rules = {
                    let wd = std::path::Path::new(&working_dir);
                    let mut loader = tron_runtime::context::loader::ContextLoader::new(
                        tron_runtime::context::loader::ContextLoaderConfig {
                            project_root: wd.to_path_buf(),
                            discover_standalone_files: settings
                                .context
                                .rules
                                .discover_standalone_files,
                            ..Default::default()
                        },
                    );
                    loader.load(wd).ok().and_then(|ctx| {
                        if ctx.merged.is_empty() {
                            None
                        } else {
                            Some(ctx.merged)
                        }
                    })
                };

                // 3. Load global rules (~/.tron/CLAUDE.md)
                let home_dir = std::env::var("HOME").ok().map(std::path::PathBuf::from);
                let global_rules = home_dir
                    .as_deref()
                    .and_then(tron_runtime::context::loader::load_global_rules);

                // 4. Merge rules (global first, then project)
                let combined_rules =
                    tron_runtime::context::loader::merge_rules(global_rules, project_rules);

                // 4b. Discover scoped rules for dynamic path-based activation
                let rules_index = {
                    let wd_path = std::path::Path::new(&working_dir);
                    let config = tron_runtime::context::rules_discovery::RulesDiscoveryConfig {
                        project_root: wd_path.to_path_buf(),
                        discover_standalone_files: settings
                            .context
                            .rules
                            .discover_standalone_files,
                        exclude_root_level: true,
                        ..Default::default()
                    };
                    let discovered =
                        tron_runtime::context::rules_discovery::discover_rules_files(&config);
                    if discovered.is_empty() {
                        None
                    } else {
                        Some(tron_runtime::context::rules_index::RulesIndex::new(
                            discovered,
                        ))
                    }
                };

                // 4c. Reconstruct prior rule activations on session resume
                let is_resumed = !state.messages.is_empty();
                let pre_activated_rules = if is_resumed {
                    let events = event_store
                        .get_events_by_type(
                            &session_id_clone,
                            &[
                                "rules.activated",
                                "compact.boundary",
                                "compact.summary",
                                "context.cleared",
                            ],
                            None,
                        )
                        .unwrap_or_default();
                    let boundary_types = ["compact.boundary", "compact.summary", "context.cleared"];
                    let mut activated: Vec<String> = Vec::new();
                    for event in &events {
                        if boundary_types.contains(&event.event_type.as_str()) {
                            activated.clear();
                        } else if event.event_type == "rules.activated" {
                            if let Ok(payload) =
                                serde_json::from_str::<serde_json::Value>(&event.payload)
                            {
                                if let Some(rules) = payload.get("rules").and_then(|r| r.as_array())
                                {
                                    for rule in rules {
                                        if let Some(p) =
                                            rule.get("relativePath").and_then(|v| v.as_str())
                                        {
                                            if !activated.contains(&p.to_owned()) {
                                                activated.push(p.to_owned());
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    activated
                } else {
                    vec![]
                };

                // 5. Load workspace memory from ledger entries
                // (rules.loaded / memory.loaded events are emitted optimistically
                // at session.create time so iOS shows pills immediately)
                let memory = {
                    let auto_inject = &settings.context.memory.auto_inject;

                    if auto_inject.enabled {
                        if let Some(ref ec) = embedding_controller {
                            let ctrl = ec.lock().await;
                            let workspace_id = event_store
                                .get_workspace_by_path(&working_dir)
                                .ok()
                                .flatten()
                                .map(|ws| ws.id);
                            workspace_id.and_then(|ws_id| {
                                let count = auto_inject.count.clamp(1, 10);
                                ctrl.load_workspace_memory(&event_store, &ws_id, count)
                                    .map(|wm| wm.content)
                            })
                        } else {
                            None
                        }
                    } else {
                        None
                    }
                };

                // 6. Get messages from reconstructed state
                let messages = state.messages.clone();

                let working_dir_for_memory = working_dir.clone();
                let model_for_error = model.clone();

                // Create a fresh provider for the session's current model.
                // This is the key fix: model switches now take effect because
                // we create the provider here (not at startup).
                let provider = match provider_factory.create_for_model(&model).await {
                    Ok(p) => p,
                    Err(e) => {
                        warn!(
                            model = %model,
                            error = %e,
                            "failed to create provider for model"
                        );
                        let _ = broadcast.emit(tron_core::events::TronEvent::Error {
                            base: tron_core::events::BaseEvent::now(&session_id_clone),
                            error: e.to_string(),
                            context: None,
                            code: None,
                            provider: None,
                            category: Some(e.category().to_owned()),
                            suggestion: None,
                            retryable: Some(e.is_retryable()),
                            status_code: None,
                            error_type: Some(e.category().to_owned()),
                            model: Some(model_for_error),
                        });
                        orchestrator.complete_run(&session_id_clone);
                        return;
                    }
                };

                let cs = &settings.context.compactor;

                let config = AgentConfig {
                    model: model.clone(),
                    working_directory: Some(working_dir),
                    enable_thinking: true,
                    max_turns: settings.agent.max_turns,
                    compaction: tron_runtime::context::types::CompactionConfig {
                        threshold: cs.compaction_threshold,
                        preserve_ratio: cs.preserve_ratio,
                        context_limit: tron_llm::tokens::get_context_limit(&model),
                    },
                    retry: Some(tron_core::retry::RetryConfig {
                        max_retries: settings.retry.max_retries,
                        base_delay_ms: settings.retry.base_delay_ms,
                        max_delay_ms: settings.retry.max_delay_ms,
                        jitter_factor: settings.retry.jitter_factor,
                    }),
                    health_tracker: Some(health_tracker),
                    ..AgentConfig::default()
                };

                let provider_type_str = provider.provider_type().as_str().to_string();
                let tools = tool_factory();
                let mut agent = AgentFactory::create_agent(
                    config,
                    session_id_clone.clone(),
                    CreateAgentOpts {
                        provider,
                        tools,
                        guardrails,
                        hooks: hooks.clone(),
                        is_subagent: false,
                        denied_tools: vec![],
                        subagent_depth: 0,
                        subagent_max_depth: settings.agent.subagent_max_depth,
                        rules_content: combined_rules,
                        initial_messages: messages,
                        memory_content: memory,
                        rules_index,
                        pre_activated_rules,
                    },
                );

                agent.set_abort_token(cancel_token);

                // 7a. Attach the session's persister — events are written during turn execution
                agent.set_persister(Some(persister.clone()));

                // 7b. Persist message.user event BEFORE agent runs (matches TS server)
                let _ = event_store.append(&tron_events::AppendOptions {
                    session_id: &session_id_clone,
                    event_type: tron_events::EventType::MessageUser,
                    payload: serde_json::json!({"content": prompt_clone}),
                    parent_id: None,
                });

                // Build user content override for multimodal messages (images + attachments)
                let user_content_override = {
                    let has_images = images_clone.as_ref().is_some_and(|v| !v.is_empty());
                    let has_attachments = attachments_clone.as_ref().is_some_and(|v| !v.is_empty());
                    if !has_images && !has_attachments {
                        None
                    } else {
                        let mut blocks = vec![tron_core::content::UserContent::Text {
                            text: prompt.clone(),
                        }];
                        // Add images
                        if let Some(imgs) = &images_clone {
                            for img in imgs {
                                if let (Some(data), Some(media_type)) = (
                                    img.get("data").and_then(|v| v.as_str()),
                                    img.get("mediaType")
                                        .or_else(|| img.get("mimeType"))
                                        .and_then(|v| v.as_str()),
                                ) {
                                    blocks.push(tron_core::content::UserContent::Image {
                                        data: data.to_string(),
                                        mime_type: media_type.to_string(),
                                    });
                                }
                            }
                        }
                        // Add attachments (documents or images based on MIME type)
                        if let Some(atts) = &attachments_clone {
                            for att in atts {
                                if let (Some(data), Some(mime)) = (
                                    att.get("data").and_then(|v| v.as_str()),
                                    att.get("mimeType").and_then(|v| v.as_str()),
                                ) {
                                    let file_name = att
                                        .get("fileName")
                                        .and_then(|v| v.as_str())
                                        .map(String::from);
                                    if mime.starts_with("image/") {
                                        blocks.push(tron_core::content::UserContent::Image {
                                            data: data.to_string(),
                                            mime_type: mime.to_string(),
                                        });
                                    } else {
                                        blocks.push(tron_core::content::UserContent::Document {
                                            data: data.to_string(),
                                            mime_type: mime.to_string(),
                                            file_name,
                                        });
                                    }
                                }
                            }
                        }
                        // Strip images if model doesn't support them
                        if !tron_llm::model_supports_images(&model) {
                            blocks.retain(|b| !matches!(b, tron_core::content::UserContent::Image { .. }));
                        }

                        if blocks.len() > 1 {
                            Some(tron_core::messages::UserMessageContent::Blocks(blocks))
                        } else {
                            None
                        }
                    }
                };

                // Subagent results (from event store — works for both live and resumed sessions)
                let subagent_results_context = {
                    let pending = get_pending_subagent_results(&event_store, &session_id_clone);
                    if pending.is_empty() {
                        None
                    } else {
                        let event_ids: Vec<String> =
                            pending.iter().map(|(id, _)| id.clone()).collect();
                        let formatted = format_subagent_results(&pending);
                        // Persist consumption marker
                        if formatted.is_some() {
                            let _ = event_store.append(&tron_events::AppendOptions {
                                session_id: &session_id_clone,
                                event_type: EventType::SubagentResultsConsumed,
                                payload: serde_json::json!({
                                    "consumedEventIds": event_ids,
                                    "count": pending.len(),
                                }),
                                parent_id: None,
                            });
                        }
                        formatted
                    }
                };

                // Build RunContext with iOS params
                let run_context = RunContext {
                    reasoning_level: reasoning_level_clone
                        .and_then(|s| tron_runtime::types::ReasoningLevel::from_str_loose(&s)),
                    skill_context: {
                        // Merge skills + spells, deduplicate
                        let mut all_names = skills_clone.unwrap_or_default();
                        if let Some(spell_names) = spells_clone {
                            for name in spell_names {
                                if !all_names.contains(&name) {
                                    all_names.push(name);
                                }
                            }
                        }
                        if all_names.is_empty() {
                            None
                        } else {
                            let registry = skill_registry.read();
                            let name_refs: Vec<&str> =
                                all_names.iter().map(String::as_str).collect();
                            let (found, _not_found) = registry.get_many(&name_refs);
                            if found.is_empty() {
                                None
                            } else {
                                // Persist skill.added events (deduplicate against existing)
                                let existing = event_store
                                    .get_events_by_type(&session_id_clone, &["skill.added"], None)
                                    .unwrap_or_default();
                                let existing_names: std::collections::HashSet<String> = existing
                                    .iter()
                                    .filter_map(|e| {
                                        serde_json::from_str::<serde_json::Value>(&e.payload)
                                            .ok()
                                            .and_then(|p| {
                                                p.get("skillName")
                                                    .and_then(|n| n.as_str())
                                                    .map(String::from)
                                            })
                                    })
                                    .collect();
                                for skill in &found {
                                    if !existing_names.contains(&skill.name) {
                                        let _ = event_store.append(&tron_events::AppendOptions {
                                            session_id: &session_id_clone,
                                            event_type: tron_events::EventType::SkillAdded,
                                            payload: serde_json::json!({
                                                "skillName": skill.name,
                                                "source": skill.source.to_string(),
                                                "addedVia": "mention",
                                                "tokens": skill.content.len() as u64 / 4,
                                            }),
                                            parent_id: None,
                                        });
                                    }
                                }

                                let ctx = tron_skills::injector::build_skill_context(&found);
                                if ctx.is_empty() { None } else { Some(ctx) }
                            }
                        }
                    },
                    subagent_results: subagent_results_context,
                    user_content_override,
                    ..Default::default()
                };

                let result = run_agent(&mut agent, &prompt, run_context, &hooks, &broadcast).await;

                // 8. Flush persister to ensure all inline-persisted events are written
                let _ = persister.flush().await;

                // 8a. Persist notification.interrupted if the run was interrupted
                if result.interrupted {
                    if let Err(e) = persister
                        .append(
                            &session_id_clone,
                            tron_events::EventType::NotificationInterrupted,
                            serde_json::json!({
                                "timestamp": chrono::Utc::now().to_rfc3339(),
                                "turn": result.turns_executed,
                            }),
                        )
                        .await
                    {
                        tracing::error!(session_id = %session_id_clone, error = %e,
                            "failed to persist notification.interrupted");
                    }
                    let _ = persister.flush().await;
                }

                // 8b. Emit agent.error if the run failed (iOS ErrorPlugin listens for this)
                if let Some(ref error_msg) = result.error {
                    let parsed = tron_core::errors::parse::parse_error(error_msg);
                    let _ = broadcast.emit(tron_core::events::TronEvent::Error {
                        base: tron_core::events::BaseEvent::now(&session_id_clone),
                        error: error_msg.clone(),
                        context: None,
                        code: None,
                        provider: Some(provider_type_str.clone()),
                        category: Some(parsed.category.to_string()),
                        suggestion: parsed.suggestion,
                        retryable: Some(parsed.is_retryable),
                        status_code: None,
                        error_type: Some(parsed.category.to_string()),
                        model: Some(model_for_error.clone()),
                    });
                }

                // 9. Auto-ledger + auto-compaction pipeline (fail-silent)
                {
                    let session_model = session_manager
                        .get_session(&session_id_clone)
                        .ok()
                        .flatten()
                        .map(|s| s.latest_model.clone())
                        .unwrap_or_default();
                    let context_limit = tron_llm::tokens::get_context_limit(&session_model);
                    let last_context_window = result.last_context_window_tokens.unwrap_or(0);
                    #[allow(clippy::cast_precision_loss)] // token counts never exceed 2^52
                    let token_ratio = if context_limit > 0 {
                        last_context_window as f64 / context_limit as f64
                    } else {
                        0.0
                    };

                    // Resolve workspace path → ID for embedding storage
                    let resolved_workspace_id = event_store
                        .get_workspace_by_path(&working_dir_for_memory)
                        .ok()
                        .flatten()
                        .map_or_else(|| working_dir_for_memory.clone(), |ws| ws.id);

                    let memory_deps = RuntimeMemoryDeps {
                        subagent_manager: subagent_manager.clone(),
                        event_store: event_store.clone(),
                        session_manager: session_manager.clone(),
                        broadcast: broadcast.clone(),
                        session_id: session_id_clone.clone(),
                        workspace_id: resolved_workspace_id,
                        embedding_controller: embedding_controller.clone(),
                        shutdown_coordinator: shutdown_coordinator.clone(),
                        ledger_enabled: settings.context.memory.ledger.enabled,
                    };

                    let (recent_event_types, recent_tool_calls) =
                        gather_recent_events(&event_store, &session_id_clone);

                    let cs_for_trigger = &settings.context.compactor;
                    let trigger_config =
                        tron_events::memory::types::CompactionTriggerConfig::from(cs_for_trigger);
                    let mut trigger =
                        tron_events::memory::trigger::CompactionTrigger::new(trigger_config);
                    if cs_for_trigger.force_always.unwrap_or(false) {
                        trigger.set_force_always(true);
                    }
                    let mut memory_manager =
                        tron_events::memory::manager::MemoryManager::new(memory_deps, trigger);

                    memory_manager
                        .on_cycle_complete(tron_events::memory::types::CycleInfo {
                            model: session_model,
                            working_directory: working_dir_for_memory,
                            current_token_ratio: token_ratio,
                            recent_event_types,
                            recent_tool_calls,
                        })
                        .await;
                }

                // 10. Invalidate cached session so next resume reconstructs from events
                session_manager.invalidate_session(&session_id_clone);

                // 11. Emit session_updated — iOS uses this to refresh the stat line
                if let Ok(Some(updated_session)) = session_manager.get_session(&session_id_clone) {
                    // Get message previews for last_user_prompt / last_assistant_response
                    let preview = event_store
                        .get_session_message_previews(&[session_id_clone.as_str()])
                        .ok()
                        .and_then(|mut map| map.remove(&session_id_clone));

                    let _ = broadcast.emit(tron_core::events::TronEvent::SessionUpdated {
                        base: tron_core::events::BaseEvent::now(&session_id_clone),
                        title: updated_session.title.clone(),
                        model: updated_session.latest_model.clone(),
                        message_count: updated_session.message_count,
                        input_tokens: updated_session.total_input_tokens,
                        output_tokens: updated_session.total_output_tokens,
                        last_turn_input_tokens: updated_session.last_turn_input_tokens,
                        cache_read_tokens: updated_session.total_cache_read_tokens,
                        cache_creation_tokens: updated_session.total_cache_creation_tokens,
                        cost: updated_session.total_cost,
                        last_activity: updated_session.last_activity_at.clone(),
                        is_active: false,
                        last_user_prompt: preview.as_ref().and_then(|p| p.last_user_prompt.clone()),
                        last_assistant_response: preview
                            .as_ref()
                            .and_then(|p| p.last_assistant_response.clone()),
                        parent_session_id: updated_session.parent_session_id.clone(),
                    });
                }

                info!(
                    session_id = %session_id_clone,
                    run_id = %run_id_clone,
                    stop_reason = ?result.stop_reason,
                    turns = result.turns_executed,
                    "prompt run completed"
                );
                orchestrator.complete_run(&session_id_clone);
            });
            if let Some(ref coord) = shutdown_coordinator_for_register {
                coord.register_task(handle);
            }
        }

        Ok(serde_json::json!({
            "acknowledged": true,
            "runId": run_id,
        }))
    }
}

/// Abort a running agent in a session.
pub struct AbortHandler;

#[async_trait]
impl MethodHandler for AbortHandler {
    #[instrument(skip(self, ctx), fields(method = "agent.abort", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        let aborted = ctx
            .orchestrator
            .abort(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        Ok(serde_json::json!({ "aborted": aborted }))
    }
}

/// Get the current agent state for a session.
pub struct GetAgentStateHandler;

#[async_trait]
impl MethodHandler for GetAgentStateHandler {
    #[instrument(skip(self, ctx), fields(method = "agent.getState", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        let is_running = ctx.orchestrator.has_active_run(&session_id);
        let run_id = ctx.orchestrator.get_run_id(&session_id);

        // Try to get session metadata for model/turn/message info
        let (
            model,
            current_turn,
            message_count,
            total_input,
            total_output,
            cache_read,
            cache_creation,
        ) = if let Ok(Some(session)) = ctx.session_manager.get_session(&session_id) {
            let model = session.latest_model.clone();
            let input = session.total_input_tokens;
            let output = session.total_output_tokens;
            let turn = session.turn_count;
            let msg = session.message_count;
            let cr = session.total_cache_read_tokens;
            let cc = session.total_cache_creation_tokens;
            (model, turn, msg, input, output, cr, cc)
        } else {
            (String::new(), 0, 0, 0, 0, 0, 0)
        };

        // Get tool names from the tool factory (if configured)
        let tool_names: Vec<String> = ctx
            .agent_deps
            .as_ref()
            .map(|deps| (deps.tool_factory)().names())
            .unwrap_or_default();

        // Check if session was interrupted (last turn didn't complete)
        let was_interrupted = if is_running {
            false
        } else {
            ctx.event_store
                .was_session_interrupted(&session_id)
                .unwrap_or(false)
        };

        Ok(serde_json::json!({
            "sessionId": session_id,
            "isRunning": is_running,
            "currentTurn": current_turn,
            "messageCount": message_count,
            "model": model,
            "runId": run_id,
            "tokenUsage": {
                "input": total_input,
                "output": total_output,
                "cacheReadTokens": cache_read,
                "cacheCreationTokens": cache_creation,
            },
            "tools": tool_names,
            "wasInterrupted": was_interrupted,
            // Resume-related fields — iOS uses these to show in-progress turn content
            // when reconnecting to a running session. Null when not running.
            "currentTurnText": null,
            "currentTurnToolCalls": null,
            "contentSequence": null,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::context::AgentDeps;
    use crate::rpc::handlers::test_helpers::{FixedProviderFactory, make_test_context};
    use futures::stream;
    use serde_json::json;
    use std::sync::Arc;
    use tron_core::content::AssistantContent;
    use tron_core::events::{AssistantMessage, StreamEvent};
    use tron_core::messages::TokenUsage;
    use tron_llm::models::types::Provider as ProviderType;
    use tron_llm::provider::{Provider, ProviderError, ProviderStreamOptions, StreamEventStream};
    use tron_tools::registry::ToolRegistry;

    // ── extract_skills tests ──

    #[test]
    fn skills_extracted_from_object_format() {
        let params = json!({"skills": [{"name": "my-skill", "source": "global"}]});
        let skills = extract_skills(params.get("skills"));
        assert_eq!(skills, vec!["my-skill"]);
    }

    #[test]
    fn skills_extracted_from_string_format() {
        let params = json!({"skills": ["my-skill"]});
        let skills = extract_skills(params.get("skills"));
        assert_eq!(skills, vec!["my-skill"]);
    }

    #[test]
    fn skills_extracted_mixed_format() {
        let params = json!({"skills": [{"name": "a", "source": "global"}, "b"]});
        let skills = extract_skills(params.get("skills"));
        assert_eq!(skills, vec!["a", "b"]);
    }

    #[test]
    fn skills_extracted_empty_array() {
        let params = json!({"skills": []});
        let skills = extract_skills(params.get("skills"));
        assert!(skills.is_empty());
    }

    #[test]
    fn skills_extracted_none() {
        let skills = extract_skills(None);
        assert!(skills.is_empty());
    }

    /// A mock provider that returns a single text response.
    struct TextProvider {
        text: String,
    }
    impl TextProvider {
        fn new(text: &str) -> Self {
            Self {
                text: text.to_owned(),
            }
        }
    }
    #[async_trait]
    impl Provider for TextProvider {
        fn provider_type(&self) -> ProviderType {
            ProviderType::Anthropic
        }
        fn model(&self) -> &str {
            "mock"
        }
        async fn stream(
            &self,
            _c: &tron_core::messages::Context,
            _o: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            let text = self.text.clone();
            let events = vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::TextDelta {
                    delta: text.clone(),
                }),
                Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text(&text)],
                        token_usage: Some(TokenUsage {
                            input_tokens: 10,
                            output_tokens: 5,
                            ..Default::default()
                        }),
                    },
                    stop_reason: "end_turn".into(),
                }),
            ];
            Ok(Box::pin(stream::iter(events)))
        }
    }

    fn make_text_context(text: &str) -> RpcContext {
        let mut ctx = make_test_context();
        ctx.agent_deps = Some(AgentDeps {
            provider_factory: Arc::new(FixedProviderFactory(Arc::new(TextProvider::new(text)))),
            tool_factory: Arc::new(ToolRegistry::new),
            guardrails: None,
            hooks: None,
        });
        ctx
    }

    /// A mock provider that yields partial text then sleeps, allowing cancellation.
    struct SlowProvider;
    #[async_trait]
    impl Provider for SlowProvider {
        fn provider_type(&self) -> ProviderType {
            ProviderType::Anthropic
        }
        fn model(&self) -> &str {
            "mock"
        }
        async fn stream(
            &self,
            _c: &tron_core::messages::Context,
            _o: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            let s = async_stream::stream! {
                yield Ok(StreamEvent::Start);
                yield Ok(StreamEvent::TextDelta { delta: "partial text".into() });
                tokio::time::sleep(tokio::time::Duration::from_secs(30)).await;
                yield Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text("partial text")],
                        token_usage: Some(TokenUsage {
                            input_tokens: 10,
                            output_tokens: 3,
                            ..Default::default()
                        }),
                    },
                    stop_reason: "end_turn".into(),
                });
            };
            Ok(Box::pin(s))
        }
    }

    fn make_slow_context() -> RpcContext {
        let mut ctx = make_test_context();
        ctx.agent_deps = Some(AgentDeps {
            provider_factory: Arc::new(FixedProviderFactory(Arc::new(SlowProvider))),
            tool_factory: Arc::new(ToolRegistry::new),
            guardrails: None,
            hooks: None,
        });
        ctx
    }

    #[tokio::test]
    async fn prompt_returns_acknowledged() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hello"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);
        assert!(result["runId"].is_string());
    }

    #[tokio::test]
    async fn prompt_generates_unique_run_ids() {
        let ctx = make_test_context();
        let sid1 = ctx
            .session_manager
            .create_session("m", "/tmp/1", Some("t1"))
            .unwrap();
        let sid2 = ctx
            .session_manager
            .create_session("m", "/tmp/2", Some("t2"))
            .unwrap();

        let r1 = PromptHandler
            .handle(Some(json!({"sessionId": sid1, "prompt": "hi"})), &ctx)
            .await
            .unwrap();
        let r2 = PromptHandler
            .handle(Some(json!({"sessionId": sid2, "prompt": "hi"})), &ctx)
            .await
            .unwrap();
        assert_ne!(r1["runId"], r2["runId"]);
    }

    #[tokio::test]
    async fn prompt_missing_session_id() {
        let ctx = make_test_context();
        let err = PromptHandler
            .handle(Some(json!({"prompt": "hi"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn prompt_missing_prompt() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();
        let err = PromptHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn prompt_session_not_found() {
        let ctx = make_test_context();
        let err = PromptHandler
            .handle(
                Some(json!({"sessionId": "nonexistent", "prompt": "hi"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    #[tokio::test]
    async fn prompt_rejects_busy_session() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        // First prompt succeeds
        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hello"})), &ctx)
            .await
            .unwrap();

        // Second prompt should fail (session busy)
        let err = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "hello again"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_BUSY");
    }

    #[tokio::test]
    async fn abort_active_returns_true() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        // Start a run so there's something to abort
        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        let result = AbortHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["aborted"], true);
    }

    #[tokio::test]
    async fn abort_inactive_returns_false() {
        let ctx = make_test_context();
        let result = AbortHandler
            .handle(Some(json!({"sessionId": "unknown"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["aborted"], false);
    }

    #[tokio::test]
    async fn abort_missing_param() {
        let ctx = make_test_context();
        let err = AbortHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn get_state_returns_is_running() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["isRunning"], false);
    }

    #[tokio::test]
    async fn get_state_returns_model() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["model"], "claude-opus-4-6");
    }

    #[tokio::test]
    async fn get_state_returns_message_count() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["messageCount"], 0);
    }

    #[tokio::test]
    async fn get_state_returns_current_turn() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["currentTurn"], 0);
    }

    #[tokio::test]
    async fn get_state_busy_session_is_running() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        // Start a run
        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["isRunning"], true);
        assert!(result["runId"].is_string());
    }

    #[tokio::test]
    async fn get_state_returns_token_usage() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["tokenUsage"].is_object());
        assert!(result["tokenUsage"]["input"].is_number());
        assert!(result["tokenUsage"]["output"].is_number());
    }

    #[tokio::test]
    async fn get_state_returns_tools_array() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["tools"].is_array());
    }

    #[tokio::test]
    async fn get_state_returns_was_interrupted() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["wasInterrupted"], false);
    }

    #[tokio::test]
    async fn get_state_returns_cache_read_tokens() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["tokenUsage"]["cacheReadTokens"].is_number());
    }

    #[tokio::test]
    async fn get_state_returns_cache_creation_tokens() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["tokenUsage"]["cacheCreationTokens"].is_number());
    }

    #[tokio::test]
    async fn get_state_cache_tokens_default_zero() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["tokenUsage"]["cacheReadTokens"], 0);
        assert_eq!(result["tokenUsage"]["cacheCreationTokens"], 0);
    }

    #[tokio::test]
    async fn get_state_token_usage_field_names() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        // iOS expects "input"/"output" not "inputTokens"/"outputTokens"
        assert!(result["tokenUsage"].get("input").is_some());
        assert!(result["tokenUsage"].get("output").is_some());
        assert!(result["tokenUsage"].get("inputTokens").is_none());
        assert!(result["tokenUsage"].get("outputTokens").is_none());
    }

    #[tokio::test]
    async fn get_state_unknown_session() {
        let ctx = make_test_context();
        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": "unknown"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["isRunning"], false);
        assert!(result["runId"].is_null());
    }

    #[tokio::test]
    async fn get_state_interrupted_when_no_turn_end() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        // Persist an assistant message without a following stream.turn_end
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({"content": [{"type": "text", "text": "hello"}], "turn": 1}),
            parent_id: None,
        });

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["wasInterrupted"], true);
    }

    #[tokio::test]
    async fn get_state_not_interrupted_when_turn_end_follows() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        // Persist an assistant message followed by stream.turn_end
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({"content": [{"type": "text", "text": "hello"}], "turn": 1}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::StreamTurnEnd,
            payload: json!({"turn": 1}),
            parent_id: None,
        });

        let result = GetAgentStateHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["wasInterrupted"], false);
    }

    // ── Extra prompt params ──

    #[tokio::test]
    async fn prompt_accepts_reasoning_level() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();
        let result = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "hi", "reasoningLevel": "high"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);
    }

    #[tokio::test]
    async fn prompt_accepts_images() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();
        let result = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "hi", "images": [{"data": "base64..."}]})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);
    }

    #[tokio::test]
    async fn prompt_accepts_attachments() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();
        let result = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "hi", "attachments": [{"path": "/tmp/f.txt"}]})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);
    }

    #[tokio::test]
    async fn prompt_accepts_skills_and_spells() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();
        let result = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "hi", "skills": ["web-search"], "spells": ["auto-commit"]})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);
    }

    // ── Phase 3: iOS prompt parameters with agent execution ──

    #[tokio::test]
    async fn prompt_with_images_creates_multimodal_message() {
        let ctx = make_text_context("Analyzed image.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "What's in this image?",
                    "images": [{"data": "iVBOR...", "mediaType": "image/png"}]
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_with_reasoning_level_runs_successfully() {
        let ctx = make_text_context("Thought deeply.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "Think about this",
                    "reasoningLevel": "high"
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_accepts_xhigh_reasoning_level() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();
        let result = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "hi", "reasoningLevel": "xhigh"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);
    }

    #[tokio::test]
    async fn prompt_accepts_max_reasoning_level() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();
        let result = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "hi", "reasoningLevel": "max"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);
    }

    #[tokio::test]
    async fn prompt_with_xhigh_reasoning_runs_successfully() {
        let ctx = make_text_context("Deep reasoning.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "Think very hard",
                    "reasoningLevel": "xhigh"
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_with_skills_runs_successfully() {
        let ctx = make_text_context("Using skills.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "Search the web",
                    "skills": ["web-search", "code-review"]
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_empty_images_no_multimodal() {
        let ctx = make_text_context("Plain text.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "hello",
                    "images": []
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    // ── Phase 14: Prompt execution chain tests ──

    #[tokio::test]
    async fn prompt_spawns_background_task() {
        let ctx = make_text_context("Hello!");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", Some("t"))
            .unwrap();

        let result = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        // Wait for background task to complete
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;

        // Run should be completed (not busy anymore)
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_without_agent_deps_stays_busy() {
        // No agent_deps → run is registered but never completed
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        // Still busy (no background task to complete it)
        assert!(ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_complete_run_on_success() {
        let ctx = make_text_context("Done.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "work"})), &ctx)
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_complete_run_on_error() {
        // Use an error provider
        struct ErrorProvider;
        #[async_trait]
        impl Provider for ErrorProvider {
            fn provider_type(&self) -> ProviderType {
                ProviderType::Anthropic
            }
            fn model(&self) -> &str {
                "mock"
            }
            async fn stream(
                &self,
                _c: &tron_core::messages::Context,
                _o: &ProviderStreamOptions,
            ) -> Result<StreamEventStream, ProviderError> {
                Err(ProviderError::Auth {
                    message: "expired".into(),
                })
            }
        }

        let mut ctx = make_test_context();
        ctx.agent_deps = Some(AgentDeps {
            provider_factory: Arc::new(FixedProviderFactory(Arc::new(ErrorProvider))),
            tool_factory: Arc::new(ToolRegistry::new),
            guardrails: None,
            hooks: None,
        });

        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        // Even on error, orchestrator should be freed
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    // ── Fix 3: agent.error emission tests ──

    #[tokio::test]
    async fn prompt_error_emits_agent_error_event() {
        struct ErrorProvider;
        #[async_trait]
        impl Provider for ErrorProvider {
            fn provider_type(&self) -> ProviderType {
                ProviderType::Anthropic
            }
            fn model(&self) -> &str {
                "mock"
            }
            async fn stream(
                &self,
                _c: &tron_core::messages::Context,
                _o: &ProviderStreamOptions,
            ) -> Result<StreamEventStream, ProviderError> {
                Err(ProviderError::Auth {
                    message: "authentication_error: invalid key".into(),
                })
            }
        }

        let mut ctx = make_test_context();
        ctx.agent_deps = Some(AgentDeps {
            provider_factory: Arc::new(FixedProviderFactory(Arc::new(ErrorProvider))),
            tool_factory: Arc::new(ToolRegistry::new),
            guardrails: None,
            hooks: None,
        });

        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();
        let mut rx = ctx.orchestrator.subscribe();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;

        let mut found_error = false;
        while let Ok(event) = rx.try_recv() {
            if let tron_core::events::TronEvent::Error {
                error,
                provider,
                category,
                retryable,
                model,
                ..
            } = &event
            {
                assert!(error.contains("authentication_error"));
                assert_eq!(provider.as_deref(), Some("anthropic"));
                assert_eq!(category.as_deref(), Some("authentication"));
                assert_eq!(*retryable, Some(false));
                assert!(model.is_some());
                found_error = true;
            }
        }
        assert!(found_error, "expected TronEvent::Error in broadcast");
    }

    #[tokio::test]
    async fn prompt_error_agent_error_has_rate_limit_category() {
        struct RateLimitProvider;
        #[async_trait]
        impl Provider for RateLimitProvider {
            fn provider_type(&self) -> ProviderType {
                ProviderType::Anthropic
            }
            fn model(&self) -> &str {
                "mock"
            }
            async fn stream(
                &self,
                _c: &tron_core::messages::Context,
                _o: &ProviderStreamOptions,
            ) -> Result<StreamEventStream, ProviderError> {
                Err(ProviderError::RateLimited {
                    message: "429 Too Many Requests".into(),
                    retry_after_ms: 0,
                })
            }
        }

        let mut ctx = make_test_context();
        ctx.agent_deps = Some(AgentDeps {
            provider_factory: Arc::new(FixedProviderFactory(Arc::new(RateLimitProvider))),
            tool_factory: Arc::new(ToolRegistry::new),
            guardrails: None,
            hooks: None,
        });

        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();
        let mut rx = ctx.orchestrator.subscribe();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        // With retry enabled (default: 1 retry, 1000ms base delay), the error
        // propagates after retry exhaustion. Wait long enough for that.
        tokio::time::sleep(std::time::Duration::from_millis(4000)).await;

        let mut found_error = false;
        while let Ok(event) = rx.try_recv() {
            if let tron_core::events::TronEvent::Error {
                category,
                retryable,
                ..
            } = &event
            {
                assert_eq!(category.as_deref(), Some("rate_limit"));
                assert_eq!(*retryable, Some(true));
                found_error = true;
            }
        }
        assert!(
            found_error,
            "expected TronEvent::Error with rate_limit category"
        );
    }

    #[tokio::test]
    async fn prompt_success_no_agent_error() {
        let ctx = make_text_context("Hello!");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();
        let mut rx = ctx.orchestrator.subscribe();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;

        while let Ok(event) = rx.try_recv() {
            assert!(
                !matches!(&event, tron_core::events::TronEvent::Error { .. }),
                "no TronEvent::Error expected on success"
            );
        }
    }

    #[tokio::test]
    async fn prompt_forwards_events_to_broadcast() {
        let ctx = make_text_context("Hello events!");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let mut rx = ctx.orchestrator.subscribe();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;

        // Collect events
        let mut event_types = vec![];
        while let Ok(event) = rx.try_recv() {
            event_types.push(event.event_type().to_owned());
        }

        // Should have agent lifecycle events forwarded through broadcast
        assert!(
            event_types.contains(&"agent_end".to_owned()),
            "expected agent_end in {event_types:?}"
        );
        assert!(
            event_types.contains(&"agent_ready".to_owned()),
            "expected agent_ready in {event_types:?}"
        );
    }

    #[tokio::test]
    async fn prompt_event_ordering() {
        let ctx = make_text_context("Ordered!");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let mut rx = ctx.orchestrator.subscribe();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;

        let mut event_types = vec![];
        while let Ok(event) = rx.try_recv() {
            event_types.push(event.event_type().to_owned());
        }

        // agent_end MUST come before agent_ready (iOS dependency)
        let end_pos = event_types.iter().position(|t| t == "agent_end");
        let ready_pos = event_types.iter().position(|t| t == "agent_ready");
        assert!(end_pos.is_some(), "agent_end must exist in {event_types:?}");
        assert!(
            ready_pos.is_some(),
            "agent_ready must exist in {event_types:?}"
        );
        assert!(
            end_pos.unwrap() < ready_pos.unwrap(),
            "agent_end ({}) must come before agent_ready ({})",
            end_pos.unwrap(),
            ready_pos.unwrap()
        );
    }

    #[tokio::test]
    async fn prompt_sequential_after_complete() {
        let ctx = make_text_context("Hello!");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        // First prompt
        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "first"})), &ctx)
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));

        // Second prompt should work after first completes
        let result = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "second"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);
    }

    #[tokio::test]
    async fn prompt_concurrent_reject() {
        let ctx = make_text_context("Hello!");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        // First prompt
        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "first"})), &ctx)
            .await
            .unwrap();

        // Second prompt immediately should still fail (background task likely still running)
        let err = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "second"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_BUSY");
    }

    // ── Phase 17: Context loading tests ──

    #[tokio::test]
    async fn prompt_loads_rules_from_working_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let claude_dir = tmp.path().join(".claude");
        std::fs::create_dir_all(&claude_dir).unwrap();
        std::fs::write(claude_dir.join("AGENTS.md"), "# Project Rules\nBe helpful.").unwrap();

        let ctx = make_text_context("Done.");
        let sid = ctx
            .session_manager
            .create_session("mock", tmp.path().to_str().unwrap(), None)
            .unwrap();

        let result = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_no_rules_still_works() {
        let tmp = tempfile::tempdir().unwrap();

        let ctx = make_text_context("Done.");
        let sid = ctx
            .session_manager
            .create_session("mock", tmp.path().to_str().unwrap(), None)
            .unwrap();

        let result = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_restores_messages_from_session() {
        let ctx = make_text_context("Response.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        // Store message events in the session
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"text": "hello"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "hi there"}],
                "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
            }),
            parent_id: None,
        });

        // Prompt should succeed with history loaded
        let result = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "follow up"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_empty_session_no_messages() {
        let ctx = make_text_context("Hello.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "first message"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_nonexistent_working_dir_ok() {
        let ctx = make_text_context("Done.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/nonexistent/path/for/test", None)
            .unwrap();

        let result = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    // ── Fix 4+6: skill/spell loading tests ──

    fn register_test_skill(ctx: &RpcContext, name: &str, content: &str) {
        let mut registry = ctx.skill_registry.write();
        registry.insert(tron_skills::types::SkillMetadata {
            name: name.to_string(),
            display_name: name.to_string(),
            description: format!("{name} skill"),
            content: content.to_string(),
            frontmatter: tron_skills::types::SkillFrontmatter::default(),
            source: tron_skills::types::SkillSource::Global,
            path: String::new(),
            skill_md_path: String::new(),
            additional_files: Vec::new(),
            last_modified: 0,
        });
    }

    #[tokio::test]
    async fn prompt_with_registered_skill_loads_content() {
        let ctx = make_text_context("Done.");
        register_test_skill(&ctx, "web-search", "Search the web using Bing API.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "search", "skills": ["web-search"]})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_with_unknown_skill_still_works() {
        let ctx = make_text_context("Done.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "hi", "skills": ["nonexistent"]})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_with_spells_runs_successfully() {
        let ctx = make_text_context("Done.");
        register_test_skill(&ctx, "auto-commit", "Auto commit changes.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({"sessionId": sid, "prompt": "commit", "spells": ["auto-commit"]})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_with_skills_and_spells_merges() {
        let ctx = make_text_context("Done.");
        register_test_skill(&ctx, "web-search", "Search the web.");
        register_test_skill(&ctx, "auto-commit", "Auto commit.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "do both",
                    "skills": ["web-search"],
                    "spells": ["auto-commit"]
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_with_duplicate_skill_and_spell_deduplicates() {
        let ctx = make_text_context("Done.");
        register_test_skill(&ctx, "web-search", "Search the web.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "search",
                    "skills": ["web-search"],
                    "spells": ["web-search"]
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    // ── Fix 5: attachment tests ──

    #[tokio::test]
    async fn prompt_with_pdf_attachment_runs_successfully() {
        let ctx = make_text_context("Received your PDF.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "summarize this",
                    "attachments": [{
                        "data": "cGRm",
                        "mimeType": "application/pdf",
                        "fileName": "report.pdf"
                    }]
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_with_image_attachment_uses_image_block() {
        let ctx = make_text_context("Nice image.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "describe this",
                    "attachments": [{
                        "data": "iVBOR",
                        "mimeType": "image/png"
                    }]
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_with_text_attachment_uses_document_block() {
        let ctx = make_text_context("Read your text.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "review this",
                    "attachments": [{
                        "data": "aGVsbG8=",
                        "mimeType": "text/plain",
                        "fileName": "readme.txt"
                    }]
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_with_mixed_images_and_attachments() {
        let ctx = make_text_context("Got both.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "look at these",
                    "images": [{"data": "abc", "mediaType": "image/jpeg"}],
                    "attachments": [{"data": "cGRm", "mimeType": "application/pdf", "fileName": "doc.pdf"}]
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    #[tokio::test]
    async fn prompt_attachment_without_data_skipped() {
        let ctx = make_text_context("No attachment data.");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let result = PromptHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "prompt": "handle this",
                    "attachments": [{"mimeType": "text/plain", "fileName": "empty.txt"}]
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["acknowledged"], true);

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(!ctx.orchestrator.has_active_run(&sid));
    }

    // ── Fix 2: gather_recent_events tests ──

    #[tokio::test]
    async fn gather_recent_events_returns_event_types() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"text": "hello"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({"content": []}),
            parent_id: None,
        });

        let (types, _calls) = super::gather_recent_events(&ctx.event_store, &sid);
        assert!(types.contains(&"message.user".to_string()));
        assert!(types.contains(&"message.assistant".to_string()));
    }

    #[tokio::test]
    async fn gather_recent_events_since_boundary() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        // Events before boundary
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"text": "old"}),
            parent_id: None,
        });
        // Boundary
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::CompactBoundary,
            payload: json!({"range": {"from": "a", "to": "b"}, "originalTokens": 100, "compactedTokens": 10}),
            parent_id: None,
        });
        // Events after boundary
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({"content": []}),
            parent_id: None,
        });

        let (types, _calls) = super::gather_recent_events(&ctx.event_store, &sid);
        // Should only have events after boundary
        assert!(!types.contains(&"message.user".to_string()));
        assert!(types.contains(&"message.assistant".to_string()));
    }

    #[tokio::test]
    async fn gather_recent_events_no_boundary_returns_all() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"text": "hi"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({"content": []}),
            parent_id: None,
        });

        let (types, _calls) = super::gather_recent_events(&ctx.event_store, &sid);
        // session.created + message.user + message.assistant = 3
        assert!(
            types.len() >= 2,
            "expected at least 2 events, got {}",
            types.len()
        );
        assert!(types.contains(&"message.user".to_string()));
        assert!(types.contains(&"message.assistant".to_string()));
    }

    #[tokio::test]
    async fn gather_recent_tool_calls_extracts_bash() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::ToolCall,
            payload: json!({"toolCallId": "tc-1", "name": "Bash", "arguments": {"command": "ls -la"}, "turn": 1}),
            parent_id: None,
        });

        let (types, calls) = super::gather_recent_events(&ctx.event_store, &sid);
        assert!(types.contains(&"tool.call".to_string()));
        assert_eq!(calls, vec!["ls -la".to_string()]);
    }

    #[tokio::test]
    async fn gather_recent_tool_calls_skips_non_bash() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", None)
            .unwrap();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::ToolCall,
            payload: json!({"toolCallId": "tc-1", "name": "Read", "arguments": {"path": "/tmp"}, "turn": 1}),
            parent_id: None,
        });

        let (_types, calls) = super::gather_recent_events(&ctx.event_store, &sid);
        assert!(calls.is_empty());
    }

    #[tokio::test]
    async fn prompt_persists_token_record_in_assistant_events() {
        let ctx = make_text_context("Hello!");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["message.assistant"], None)
            .unwrap();
        assert!(
            !events.is_empty(),
            "expected at least one message.assistant event"
        );
        let payload: Value = serde_json::from_str(&events[0].payload).unwrap();
        assert!(
            payload["tokenRecord"]["source"]["rawInputTokens"].is_number(),
            "tokenRecord.source.rawInputTokens should be a number, got: {}",
            payload["tokenRecord"]
        );
    }

    // ── Interrupted session persistence tests ──

    #[tokio::test]
    async fn interrupted_run_persists_notification_event() {
        let ctx = make_slow_context();
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hello"})), &ctx)
            .await
            .unwrap();

        // Wait for the stream to start yielding
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;

        // Abort the session
        let _ = AbortHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        // Wait for the background task to finish
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["notification.interrupted"], None)
            .unwrap();
        assert_eq!(
            events.len(),
            1,
            "expected one notification.interrupted event"
        );

        let payload: Value = serde_json::from_str(&events[0].payload).unwrap();
        assert!(payload.get("timestamp").is_some());
        assert!(payload.get("turn").is_some());
    }

    #[tokio::test]
    async fn interrupted_run_persists_partial_assistant_message() {
        let ctx = make_slow_context();
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hello"})), &ctx)
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(100)).await;

        let _ = AbortHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(500)).await;

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["message.assistant"], None)
            .unwrap();
        assert_eq!(events.len(), 1, "expected one message.assistant event");

        let payload: Value = serde_json::from_str(&events[0].payload).unwrap();
        assert_eq!(payload["stopReason"], "interrupted");
        assert_eq!(payload["interrupted"], true);
        let content = payload["content"].as_array().unwrap();
        assert!(!content.is_empty(), "content should contain partial text");
    }

    #[tokio::test]
    async fn normal_run_does_not_persist_interrupted_notification() {
        let ctx = make_text_context("hello world");
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp", None)
            .unwrap();

        let _ = PromptHandler
            .handle(Some(json!({"sessionId": sid, "prompt": "hi"})), &ctx)
            .await
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(300)).await;

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["notification.interrupted"], None)
            .unwrap();
        assert_eq!(
            events.len(),
            0,
            "normal run should not have notification.interrupted"
        );
    }

    // ── get_pending_subagent_results tests ──

    fn make_event_store() -> Arc<tron_events::EventStore> {
        let pool = tron_events::new_in_memory(&tron_events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron_events::run_migrations(&conn).unwrap();
        }
        Arc::new(tron_events::EventStore::new(pool))
    }

    #[test]
    fn get_pending_no_notifications_returns_empty() {
        let store = make_event_store();
        let sid = store
            .create_session("mock", "/tmp", None, None, None)
            .unwrap()
            .session
            .id;

        let results = get_pending_subagent_results(&store, &sid);
        assert!(results.is_empty());
    }

    #[test]
    fn get_pending_with_notification_returns_it() {
        let store = make_event_store();
        let sid = store
            .create_session("mock", "/tmp", None, None, None)
            .unwrap()
            .session
            .id;

        let _ = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::NotificationSubagentResult,
                payload: json!({
                    "parentSessionId": sid,
                    "subagentSessionId": "child-1",
                    "task": "research",
                    "resultSummary": "done",
                    "success": true,
                    "totalTurns": 3,
                    "duration": 5000,
                    "tokenUsage": {},
                    "completedAt": "2026-01-01T00:00:00Z",
                    "output": "result text"
                }),
                parent_id: None,
            })
            .unwrap();

        let results = get_pending_subagent_results(&store, &sid);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].1["task"], "research");
    }

    #[test]
    fn get_pending_skips_consumed() {
        let store = make_event_store();
        let sid = store
            .create_session("mock", "/tmp", None, None, None)
            .unwrap()
            .session
            .id;

        let notification = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::NotificationSubagentResult,
                payload: json!({
                    "parentSessionId": sid,
                    "subagentSessionId": "child-1",
                    "task": "research",
                    "resultSummary": "done",
                    "success": true,
                    "totalTurns": 3,
                    "duration": 5000,
                    "tokenUsage": {},
                    "completedAt": "2026-01-01T00:00:00Z",
                    "output": "result text"
                }),
                parent_id: None,
            })
            .unwrap();

        // Mark it as consumed
        let _ = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::SubagentResultsConsumed,
                payload: json!({
                    "consumedEventIds": [notification.id],
                    "count": 1
                }),
                parent_id: None,
            })
            .unwrap();

        let results = get_pending_subagent_results(&store, &sid);
        assert!(results.is_empty());
    }

    #[test]
    fn get_pending_partial_consumed() {
        let store = make_event_store();
        let sid = store
            .create_session("mock", "/tmp", None, None, None)
            .unwrap()
            .session
            .id;

        let n1 = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::NotificationSubagentResult,
                payload: json!({
                    "parentSessionId": sid,
                    "subagentSessionId": "child-1",
                    "task": "task-1",
                    "resultSummary": "done",
                    "success": true,
                    "totalTurns": 1,
                    "duration": 1000,
                    "tokenUsage": {},
                    "completedAt": "2026-01-01T00:00:00Z"
                }),
                parent_id: None,
            })
            .unwrap();

        let _n2 = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::NotificationSubagentResult,
                payload: json!({
                    "parentSessionId": sid,
                    "subagentSessionId": "child-2",
                    "task": "task-2",
                    "resultSummary": "done",
                    "success": true,
                    "totalTurns": 2,
                    "duration": 2000,
                    "tokenUsage": {},
                    "completedAt": "2026-01-01T00:00:00Z"
                }),
                parent_id: None,
            })
            .unwrap();

        // Consume only n1
        let _ = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::SubagentResultsConsumed,
                payload: json!({
                    "consumedEventIds": [n1.id],
                    "count": 1
                }),
                parent_id: None,
            })
            .unwrap();

        let results = get_pending_subagent_results(&store, &sid);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].1["task"], "task-2");
    }

    #[test]
    fn get_pending_multiple_consumption_events() {
        let store = make_event_store();
        let sid = store
            .create_session("mock", "/tmp", None, None, None)
            .unwrap()
            .session
            .id;

        // Three notifications
        let n1 = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::NotificationSubagentResult,
                payload: json!({
                    "parentSessionId": sid,
                    "subagentSessionId": "child-1",
                    "task": "task-1",
                    "resultSummary": "done",
                    "success": true,
                    "totalTurns": 1,
                    "duration": 1000,
                    "tokenUsage": {},
                    "completedAt": "2026-01-01T00:00:00Z"
                }),
                parent_id: None,
            })
            .unwrap();

        let n2 = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::NotificationSubagentResult,
                payload: json!({
                    "parentSessionId": sid,
                    "subagentSessionId": "child-2",
                    "task": "task-2",
                    "resultSummary": "done",
                    "success": true,
                    "totalTurns": 2,
                    "duration": 2000,
                    "tokenUsage": {},
                    "completedAt": "2026-01-01T00:00:00Z"
                }),
                parent_id: None,
            })
            .unwrap();

        let _n3 = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::NotificationSubagentResult,
                payload: json!({
                    "parentSessionId": sid,
                    "subagentSessionId": "child-3",
                    "task": "task-3",
                    "resultSummary": "done",
                    "success": true,
                    "totalTurns": 3,
                    "duration": 3000,
                    "tokenUsage": {},
                    "completedAt": "2026-01-01T00:00:00Z"
                }),
                parent_id: None,
            })
            .unwrap();

        // Two separate consumption events: first consumes n1, second consumes n2
        let _ = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::SubagentResultsConsumed,
                payload: json!({
                    "consumedEventIds": [n1.id],
                    "count": 1
                }),
                parent_id: None,
            })
            .unwrap();

        let _ = store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: EventType::SubagentResultsConsumed,
                payload: json!({
                    "consumedEventIds": [n2.id],
                    "count": 1
                }),
                parent_id: None,
            })
            .unwrap();

        // Only n3 should remain (union of consumed IDs across both events)
        let results = get_pending_subagent_results(&store, &sid);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].1["task"], "task-3");
    }

    // ── format_subagent_results tests ──

    #[test]
    fn format_subagent_results_empty_returns_none() {
        assert!(format_subagent_results(&[]).is_none());
    }

    #[test]
    fn format_subagent_results_success() {
        let results = vec![(
            "evt-1".to_string(),
            json!({
                "subagentSessionId": "child-1",
                "task": "research task",
                "success": true,
                "totalTurns": 3,
                "duration": 5000,
                "output": "Found the answer."
            }),
        )];
        let formatted = format_subagent_results(&results).unwrap();
        assert!(formatted.contains("Completed Sub-Agent Results"));
        assert!(formatted.contains("research task"));
        assert!(formatted.contains("Completed"));
        assert!(formatted.contains("Found the answer."));
        assert!(formatted.contains("[+]"));
    }

    #[test]
    fn format_subagent_results_failure() {
        let results = vec![(
            "evt-1".to_string(),
            json!({
                "subagentSessionId": "child-1",
                "task": "failing task",
                "success": false,
                "totalTurns": 1,
                "duration": 500,
                "output": "Auth error"
            }),
        )];
        let formatted = format_subagent_results(&results).unwrap();
        assert!(formatted.contains("Failed"));
        assert!(formatted.contains("[x]"));
    }

    #[test]
    fn format_subagent_results_truncates_long_output() {
        let long_output = "x".repeat(3000);
        let results = vec![(
            "evt-1".to_string(),
            json!({
                "subagentSessionId": "child-1",
                "task": "task",
                "success": true,
                "totalTurns": 1,
                "duration": 100,
                "output": long_output
            }),
        )];
        let formatted = format_subagent_results(&results).unwrap();
        assert!(formatted.contains("[Output truncated]"));
        assert!(formatted.len() < long_output.len());
    }

    #[test]
    fn format_subagent_results_multiple() {
        let results = vec![
            (
                "evt-1".to_string(),
                json!({
                    "subagentSessionId": "child-1",
                    "task": "task-1",
                    "success": true,
                    "totalTurns": 1,
                    "duration": 100,
                    "output": "out-1"
                }),
            ),
            (
                "evt-2".to_string(),
                json!({
                    "subagentSessionId": "child-2",
                    "task": "task-2",
                    "success": false,
                    "totalTurns": 2,
                    "duration": 200,
                    "output": "out-2"
                }),
            ),
        ];
        let formatted = format_subagent_results(&results).unwrap();
        assert!(formatted.contains("task-1"));
        assert!(formatted.contains("task-2"));
        assert!(formatted.contains("out-1"));
        assert!(formatted.contains("out-2"));
    }
}
