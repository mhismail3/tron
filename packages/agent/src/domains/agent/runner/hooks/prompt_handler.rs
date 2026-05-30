//! LLM prompt-based hook handler.
//!
//! Executes user-defined prompts as async LLM subsessions. Always runs
//! in background mode and returns `Continue` immediately — the subsession
//! completes asynchronously, persists a [`LlmHookResult`] event to the
//! event store (for schedule tracking), and broadcasts it to real-time
//! subscribers.
//!
//! For the built-in title generation hook, also emits a
//! [`SessionUpdated`](crate::shared::events::TronEvent::SessionUpdated)
//! event with the generated title.

use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use tracing::{debug, warn};

use crate::shared::events::BaseEvent;

use super::errors::HookError;
use super::handler::HookHandler;
use super::types::{HookContext, HookExecutionMode, HookResult, HookType};

/// Maximum length for generated titles.
const MAX_TITLE_LENGTH: usize = 80;

/// Maximum length for generated branch names.
const MAX_BRANCH_NAME_LENGTH: usize = 50;

/// Maximum length for LLM hook output stored in events.
const MAX_OUTPUT_LENGTH: usize = 1024;

/// Hook names containing this substring trigger title generation.
/// Matches both builtin (`builtin:title-gen`) and user file (`user:title-gen`) hooks.
const TITLE_GEN_MARKER: &str = "title-gen";

/// Hook names containing this substring trigger branch name generation.
const BRANCH_NAME_GEN_MARKER: &str = "branch-name-gen";

/// Hook names containing this substring trigger prompt suggestion generation.
const SUGGEST_PROMPTS_MARKER: &str = "suggest-prompts";

/// LLM prompt-based hook handler.
///
/// Spawns a lightweight subsession with the user's prompt, then emits
/// the result as an [`LlmHookResult`] event. Always async, never blocks.
pub struct PromptHookHandler {
    id: String,
    name: String,
    label: String,
    hook_type: HookType,
    prompt_template: String,
    enabled: bool,
    priority: i32,
    model: String,
    subagent_manager:
        Arc<crate::domains::agent::runner::orchestrator::subagent_manager::SubagentManager>,
    event_emitter: Arc<crate::domains::agent::runner::agent::event_emitter::EventEmitter>,
    /// Optional event store for schedule-based hooks (e.g., title gen).
    event_store: Option<Arc<crate::domains::session::event_store::EventStore>>,
    /// Optional worktree coordinator for branch rename operations.
    worktree_coordinator: Option<Arc<crate::domains::worktree::WorktreeCoordinator>>,
    /// Shared abort tracker for cancelling stale subsessions across prompts.
    abort_tracker: Option<Arc<super::abort_tracker::HookAbortTracker>>,
}

/// How many user prompts between automatic title regeneration.
const TITLE_REGEN_INTERVAL: usize = 6;

impl PromptHookHandler {
    /// Construct a new `PromptHookHandler` from its configuration parameters.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: String,
        name: String,
        label: String,
        hook_type: HookType,
        prompt_template: String,
        enabled: bool,
        priority: i32,
        model: String,
        subagent_manager: Arc<
            crate::domains::agent::runner::orchestrator::subagent_manager::SubagentManager,
        >,
        event_emitter: Arc<crate::domains::agent::runner::agent::event_emitter::EventEmitter>,
    ) -> Self {
        Self {
            id,
            name,
            label,
            hook_type,
            prompt_template,
            enabled,
            priority,
            model,
            subagent_manager,
            event_emitter,
            event_store: None,
            worktree_coordinator: None,
            abort_tracker: None,
        }
    }

    /// Attach an event store for schedule-based hooks (title gen).
    pub fn with_event_store(
        mut self,
        store: Arc<crate::domains::session::event_store::EventStore>,
    ) -> Self {
        self.event_store = Some(store);
        self
    }

    /// Attach a worktree coordinator for branch rename operations.
    pub fn with_worktree_coordinator(
        mut self,
        coord: Arc<crate::domains::worktree::WorktreeCoordinator>,
    ) -> Self {
        self.worktree_coordinator = Some(coord);
        self
    }

    /// Attach a shared abort tracker for cancelling stale subsessions.
    pub fn with_abort_tracker(
        mut self,
        tracker: Arc<super::abort_tracker::HookAbortTracker>,
    ) -> Self {
        self.abort_tracker = Some(tracker);
        self
    }

    /// Check whether the title-gen hook should fire for this session.
    fn should_generate_title(&self, session_id: &str) -> bool {
        let Some(store) = &self.event_store else {
            return true; // No store → can't check, fire anyway
        };
        should_generate_title_with_store(store, session_id)
    }

    /// Build the task string from the prompt template and hook context.
    fn build_task(&self, context: &HookContext) -> String {
        let context_json = serde_json::to_string_pretty(context).unwrap_or_default();
        // Truncate context for very long messages (e.g., UserPromptSubmit with 10KB prompt)
        let truncated_context = if context_json.len() > 500 {
            format!("{}...(truncated)", &context_json[..500])
        } else {
            context_json
        };

        format!(
            "{}\n\n---\nEvent context:\n{}",
            self.prompt_template, truncated_context
        )
    }

    /// Clean up a generated title: trim, strip quotes, truncate.
    fn clean_title(raw: &str) -> Option<String> {
        let cleaned = raw
            .trim()
            .trim_matches('"')
            .trim_matches('\'')
            .trim()
            .replace('\n', " ");

        if cleaned.is_empty() {
            return None;
        }

        let truncated = if cleaned.len() > MAX_TITLE_LENGTH {
            format!("{}...", &cleaned[..MAX_TITLE_LENGTH - 3])
        } else {
            cleaned
        };

        Some(truncated)
    }

    /// Clean up a generated branch name: trim, lowercase, validate 3-word format.
    ///
    /// Returns `None` if the output can't be parsed into a valid 3-word branch name.
    fn clean_branch_name(raw: &str) -> Option<String> {
        let cleaned = raw
            .trim()
            .trim_matches('"')
            .trim_matches('\'')
            .trim()
            .to_lowercase();

        if cleaned.is_empty() {
            return None;
        }

        // Replace any non-alphanumeric chars with hyphens
        let normalized: String = cleaned
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || c == '-' {
                    c
                } else {
                    '-'
                }
            })
            .collect();

        // Collapse multiple hyphens and strip leading/trailing
        let collapsed = normalized
            .split('-')
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>();

        // Require at least 3 segments (take first 3)
        if collapsed.len() < 3 {
            return None;
        }

        let result = collapsed[..3].join("-");

        if result.is_empty() {
            return None;
        }

        let truncated = if result.len() > MAX_BRANCH_NAME_LENGTH {
            result[..MAX_BRANCH_NAME_LENGTH].to_string()
        } else {
            result
        };

        Some(truncated)
    }

    /// Parse raw LLM output into structured suggestions.
    /// Each non-empty line under 80 chars becomes a suggestion, max 5.
    fn parse_suggestions(output: &str) -> Vec<String> {
        output
            .lines()
            .map(|line| line.trim())
            .filter(|line| !line.is_empty() && line.len() < 80)
            .take(5)
            .map(String::from)
            .collect()
    }

    /// Truncate output for event storage.
    fn truncate_output(output: &str) -> Option<String> {
        let trimmed = output.trim();
        if trimmed.is_empty() {
            return None;
        }
        if trimmed.len() > MAX_OUTPUT_LENGTH {
            Some(format!("{}...", &trimmed[..MAX_OUTPUT_LENGTH - 3]))
        } else {
            Some(trimmed.to_string())
        }
    }
}

#[async_trait]
impl HookHandler for PromptHookHandler {
    fn name(&self) -> &str {
        &self.name
    }

    fn hook_type(&self) -> HookType {
        self.hook_type
    }

    fn priority(&self) -> i32 {
        self.priority
    }

    fn execution_mode(&self) -> HookExecutionMode {
        HookExecutionMode::Background
    }

    fn bypass_forced_blocking(&self) -> bool {
        true
    }

    fn description(&self) -> Option<&str> {
        Some(&self.label)
    }

    fn should_handle(&self, _context: &HookContext) -> bool {
        self.enabled && !self.prompt_template.is_empty()
    }

    async fn handle(&self, context: &HookContext) -> Result<HookResult, HookError> {
        use crate::domains::agent::runner::orchestrator::subagent_manager::SubsessionConfig;

        let is_title_gen = self.id.contains(TITLE_GEN_MARKER);
        let is_branch_name_gen = self.id.contains(BRANCH_NAME_GEN_MARKER);
        let is_suggest_prompts = self.id.contains(SUGGEST_PROMPTS_MARKER);

        // Title-gen has a schedule: first prompt, then every N prompts
        // or after compaction/memory events.
        if is_title_gen && !self.should_generate_title(context.session_id()) {
            debug!(id = %self.id, "[prompt_hook] skipping (schedule says not yet)");
            return Ok(HookResult::continue_());
        }

        // Suggest-prompts: skip if no conversation context available.
        if is_suggest_prompts {
            if let HookContext::Stop {
                last_user_prompt, ..
            } = context
            {
                if last_user_prompt.is_none() {
                    debug!(id = %self.id, "[prompt_hook] skipping suggest-prompts (no user prompt)");
                    return Ok(HookResult::continue_());
                }
            }
        }

        debug!(id = %self.id, session_id = %context.session_id(), "[prompt_hook] spawning background subsession");

        let task = self.build_task(context);
        let hook_id = self.id.clone();
        let hook_name = self.label.clone();
        let hook_event = self.hook_type.to_string();
        let model = self.model.clone();
        let session_id = context.session_id().to_owned();
        let process_id = if is_title_gen {
            "hooks.titleGen"
        } else if is_branch_name_gen {
            "hooks.branchName"
        } else if is_suggest_prompts {
            "hooks.suggestPrompts"
        } else {
            "hooks.suggestPrompts"
        }
        .to_string();
        let manager = self.subagent_manager.clone();
        let emitter = self.event_emitter.clone();
        let coordinator = self.worktree_coordinator.clone();
        let event_store = self.event_store.clone();
        let abort_key = format!("{}:{}", session_id, hook_id);

        // Fire-and-forget: spawn the subsession in the background
        let join_handle = tokio::spawn(async move {
            debug!(hook_id = %hook_id, "[prompt_hook] background task started, calling spawn_subsession");
            let start = Instant::now();

            let result = manager
                .spawn_subsession(SubsessionConfig {
                    process_id: Some(process_id),
                    parent_session_id: session_id.clone(),
                    task,
                    model: Some(model.clone()),
                    system_prompt: "You are a helpful assistant performing a quick task. Be concise and follow the instruction exactly.".to_string(),
                    working_directory: "/tmp".into(),
                    inherit_capabilities: false,
                    max_turns: 1,
                    max_depth: 0,
                    reasoning_level: None,
                    spawn_type: crate::domains::agent::runner::orchestrator::subagent_manager::SpawnType::Hook,
                    ..SubsessionConfig::default()
                })
                .await;

            let duration_ms = start.elapsed().as_millis() as u64;
            debug!(hook_id = %hook_id, duration_ms = duration_ms, "[prompt_hook] subsession completed");

            match result {
                Ok(output) => {
                    let output_text = Self::truncate_output(&output.output);

                    // For title generation, persist to DB and emit SessionUpdated
                    if is_title_gen {
                        if let Some(title) = output_text.as_ref().and_then(|t| Self::clean_title(t))
                        {
                            // Respect pre-set titles (e.g., quick chat sessions titled "Chat")
                            let has_existing_title = event_store
                                .as_ref()
                                .and_then(|store| store.get_session(&session_id).ok().flatten())
                                .and_then(|s| s.title)
                                .is_some();
                            if has_existing_title {
                                debug!(session_id = %session_id, "skipping title-gen: session already has a title");
                            } else {
                                if let Some(store) = &event_store {
                                    if let Err(e) =
                                        store.update_session_title(&session_id, Some(&title))
                                    {
                                        warn!(session_id = %session_id, error = %e, "failed to persist hook-generated title");
                                    }
                                }
                                debug!(title = %title, "LLM hook generated session title");
                                let _ = emitter.emit(
                                    crate::shared::events::TronEvent::SessionUpdated {
                                        base: BaseEvent::now(&session_id),
                                        title: Some(title),
                                        model: None,
                                        message_count: None,
                                        input_tokens: None,
                                        output_tokens: None,
                                        last_turn_input_tokens: None,
                                        cache_read_tokens: None,
                                        cache_creation_tokens: None,
                                        cost: None,
                                        last_activity: chrono::Utc::now().to_rfc3339(),
                                        is_active: true,
                                        last_user_prompt: None,
                                        last_assistant_response: None,
                                        parent_session_id: None,
                                        activity_lines: None,
                                    },
                                );
                            }
                        }
                    }

                    // For branch name generation, rename the branch
                    if is_branch_name_gen {
                        if let (Some(name), Some(coord)) = (
                            output_text
                                .as_ref()
                                .and_then(|t| Self::clean_branch_name(t)),
                            &coordinator,
                        ) {
                            let new_branch = format!("{}{}", coord.config().branch_prefix, name);
                            match coord.rename_branch(&session_id, &new_branch).await {
                                Ok(()) => {
                                    debug!(session_id = %session_id, new_branch = %new_branch, "branch renamed by hook");
                                }
                                Err(e) => {
                                    warn!(session_id = %session_id, error = %e, "branch rename failed");
                                }
                            }
                        }
                    }

                    // Extract token usage from subsession output
                    let (input_tokens, output_tokens) = output
                        .token_usage
                        .as_ref()
                        .map(|u| {
                            let inp = u.get("inputTokens").and_then(|v| v.as_u64()).unwrap_or(0);
                            let out = u.get("outputTokens").and_then(|v| v.as_u64()).unwrap_or(0);
                            (inp, out)
                        })
                        .unwrap_or((0, 0));

                    // Parse structured suggestions for suggest-prompts hooks
                    let suggestions = if is_suggest_prompts {
                        output_text
                            .as_ref()
                            .map(|text| Self::parse_suggestions(text))
                    } else {
                        None
                    };

                    // Persist to EventStore so should_generate_title() can
                    // find this result on subsequent prompts.
                    if let Some(store) = &event_store {
                        let mut payload = serde_json::json!({
                            "hookName": hook_name,
                            "hookId": hook_id,
                            "hookEvent": hook_event,
                            "output": output_text,
                            "durationMs": duration_ms,
                            "model": model,
                            "inputTokens": input_tokens,
                            "outputTokens": output_tokens,
                            "success": true,
                            "timestamp": chrono::Utc::now().to_rfc3339(),
                        });
                        if let Some(ref s) = suggestions {
                            payload["suggestions"] = serde_json::json!(s);
                        }
                        if let Err(e) =
                            store.append(&crate::domains::session::event_store::AppendOptions {
                                session_id: &session_id,
                                event_type:
                                    crate::domains::session::event_store::EventType::LlmHookResult,
                                payload,
                                parent_id: None,
                                sequence: None,
                            })
                        {
                            warn!(hook_id = %hook_id, error = %e, "failed to persist hook.llm_result event");
                        }
                    }

                    // Broadcast to real-time subscribers (WebSocket/iOS)
                    let _ = emitter.emit(crate::shared::events::TronEvent::LlmHookResult {
                        base: BaseEvent::now(&session_id),
                        hook_name,
                        hook_id,
                        hook_event,
                        output: output_text,
                        duration_ms,
                        model,
                        input_tokens,
                        output_tokens,
                        success: true,
                        error: None,
                        suggestions,
                    });
                }
                Err(e) => {
                    warn!(
                        hook_id = %hook_id,
                        error = %e,
                        "LLM hook subsession failed"
                    );

                    // Persist error result so schedule advances and avoids
                    // infinite retries on persistent LLM failures.
                    if let Some(store) = &event_store {
                        let payload = serde_json::json!({
                            "hookName": hook_name,
                            "hookId": hook_id,
                            "hookEvent": hook_event,
                            "durationMs": duration_ms,
                            "model": model,
                            "inputTokens": 0,
                            "outputTokens": 0,
                            "success": false,
                            "error": e.to_string(),
                            "timestamp": chrono::Utc::now().to_rfc3339(),
                        });
                        if let Err(persist_err) =
                            store.append(&crate::domains::session::event_store::AppendOptions {
                                session_id: &session_id,
                                event_type:
                                    crate::domains::session::event_store::EventType::LlmHookResult,
                                payload,
                                parent_id: None,
                                sequence: None,
                            })
                        {
                            warn!(hook_id = %hook_id, error = %persist_err, "failed to persist hook.llm_result error event");
                        }
                    }

                    let _ = emitter.emit(crate::shared::events::TronEvent::LlmHookResult {
                        base: BaseEvent::now(&session_id),
                        hook_name,
                        hook_id,
                        hook_event,
                        output: None,
                        duration_ms,
                        model,
                        input_tokens: 0,
                        output_tokens: 0,
                        success: false,
                        error: Some(e.to_string()),
                        suggestions: None,
                    });
                }
            }
        });

        // Register this subsession's handle, aborting any previous one for the same key.
        if let Some(ref tracker) = self.abort_tracker {
            if tracker.replace(&abort_key, join_handle.abort_handle()) {
                debug!(id = %self.id, "[prompt_hook] aborted previous stale subsession");
            }
        }

        debug!(id = %self.id, "[prompt_hook] handle() returning Continue (subsession running in background)");
        Ok(HookResult::continue_())
    }
}

/// Check whether the title-gen hook should fire for this session.
///
/// Schedule:
/// 1. First prompt → always fire
/// 2. Then fire when: 6+ prompts since last title gen, OR a
///    compaction/memory event occurred since last title gen
/// 3. Whichever comes first, then reset
fn should_generate_title_with_store(
    store: &crate::domains::session::event_store::EventStore,
    session_id: &str,
) -> bool {
    // Count user messages in this session
    let user_msgs = store
        .get_events_by_type(session_id, &["message.user"], None)
        .unwrap_or_default();

    // First prompt → always fire
    if user_msgs.len() <= 1 {
        return true;
    }

    // Find the last title-gen event
    let title_events = store
        .get_events_by_type(session_id, &["hook.llm_result"], None)
        .unwrap_or_default();

    let last_title_gen = title_events
        .iter()
        .rev()
        .find(|e| e.payload.contains("title-gen"));

    let Some(last_gen) = last_title_gen else {
        return true; // No previous title gen → fire
    };

    let last_gen_seq = last_gen.sequence;

    // Count user messages since last title gen
    let msgs_since = user_msgs
        .iter()
        .filter(|e| e.sequence > last_gen_seq)
        .count();

    if msgs_since >= TITLE_REGEN_INTERVAL {
        return true;
    }

    // Check for compaction or memory events since last title gen
    let trigger_events = store
        .get_events_by_type(session_id, &["compact.summary", "memory.retained"], None)
        .unwrap_or_default();

    trigger_events.iter().any(|e| e.sequence > last_gen_seq)
}

#[cfg(test)]
#[path = "prompt_handler/tests.rs"]
mod tests;
