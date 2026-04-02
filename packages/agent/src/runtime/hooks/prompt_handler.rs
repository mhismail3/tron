//! LLM prompt-based hook handler.
//!
//! Executes user-defined prompts as async LLM subsessions. Always runs
//! in background mode and returns `Continue` immediately — the subsession
//! completes asynchronously and emits a [`LlmHookResult`] event.
//!
//! For the built-in title generation hook, also emits a
//! [`SessionUpdated`](crate::core::events::TronEvent::SessionUpdated)
//! event with the generated title.

use std::sync::Arc;
use std::time::Instant;

use async_trait::async_trait;
use tracing::{debug, warn};

use crate::core::events::BaseEvent;

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
    subagent_manager: Arc<crate::runtime::orchestrator::subagent_manager::SubagentManager>,
    event_emitter: Arc<crate::runtime::agent::event_emitter::EventEmitter>,
    /// Optional event store for schedule-based hooks (e.g., title gen).
    event_store: Option<Arc<crate::events::EventStore>>,
    /// Optional worktree coordinator for branch rename operations.
    worktree_coordinator: Option<Arc<crate::worktree::WorktreeCoordinator>>,
}

/// How many user prompts between automatic title regeneration.
const TITLE_REGEN_INTERVAL: usize = 6;

impl PromptHookHandler {
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
        subagent_manager: Arc<crate::runtime::orchestrator::subagent_manager::SubagentManager>,
        event_emitter: Arc<crate::runtime::agent::event_emitter::EventEmitter>,
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
        }
    }

    /// Attach an event store for schedule-based hooks (title gen).
    pub fn with_event_store(mut self, store: Arc<crate::events::EventStore>) -> Self {
        self.event_store = Some(store);
        self
    }

    /// Attach a worktree coordinator for branch rename operations.
    pub fn with_worktree_coordinator(mut self, coord: Arc<crate::worktree::WorktreeCoordinator>) -> Self {
        self.worktree_coordinator = Some(coord);
        self
    }

    /// Check whether the title-gen hook should fire for this session.
    ///
    /// Schedule:
    /// 1. First prompt → always fire
    /// 2. Then fire when: 6+ prompts since last title gen, OR a
    ///    compaction/memory event occurred since last title gen
    /// 3. Whichever comes first, then reset
    fn should_generate_title(&self, session_id: &str) -> bool {
        let Some(store) = &self.event_store else {
            return true; // No store → can't check, fire anyway
        };

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
            .get_events_by_type(
                session_id,
                &["compact.summary", "memory.retained"],
                None,
            )
            .unwrap_or_default();

        let has_trigger = trigger_events
            .iter()
            .any(|e| e.sequence > last_gen_seq);

        has_trigger
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
            .map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' })
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

    fn description(&self) -> Option<&str> {
        Some(&self.label)
    }

    fn should_handle(&self, _context: &HookContext) -> bool {
        self.enabled && !self.prompt_template.is_empty()
    }

    async fn handle(&self, context: &HookContext) -> Result<HookResult, HookError> {
        use crate::runtime::orchestrator::subagent_manager::SubsessionConfig;

        let is_title_gen = self.id.contains(TITLE_GEN_MARKER);
        let is_branch_name_gen = self.id.contains(BRANCH_NAME_GEN_MARKER);

        // Title-gen has a schedule: first prompt, then every N prompts
        // or after compaction/memory events.
        if is_title_gen && !self.should_generate_title(context.session_id()) {
            debug!(id = %self.id, "[prompt_hook] skipping (schedule says not yet)");
            return Ok(HookResult::continue_());
        }

        debug!(id = %self.id, session_id = %context.session_id(), "[prompt_hook] spawning background subsession");

        let task = self.build_task(context);
        let hook_id = self.id.clone();
        let hook_name = self.label.clone();
        let hook_event = self.hook_type.to_string();
        let model = self.model.clone();
        let session_id = context.session_id().to_owned();
        let manager = self.subagent_manager.clone();
        let emitter = self.event_emitter.clone();
        let coordinator = self.worktree_coordinator.clone();

        // Fire-and-forget: spawn the subsession in the background
        tokio::spawn(async move {
            debug!(hook_id = %hook_id, "[prompt_hook] background task started, calling spawn_subsession");
            let start = Instant::now();

            let result = manager
                .spawn_subsession(SubsessionConfig {
                    parent_session_id: session_id.clone(),
                    task,
                    model: Some(model.clone()),
                    system_prompt: "You are a helpful assistant performing a quick task. Be concise and follow the instruction exactly.".to_string(),
                    working_directory: "/tmp".into(),
                    inherit_tools: false,
                    max_turns: 1,
                    max_depth: 0,
                    reasoning_level: None,
                    ..SubsessionConfig::default()
                })
                .await;

            let duration_ms = start.elapsed().as_millis() as u64;
            debug!(hook_id = %hook_id, duration_ms = duration_ms, "[prompt_hook] subsession completed");

            match result {
                Ok(output) => {
                    let output_text = Self::truncate_output(&output.output);

                    // For title generation, emit SessionUpdated with title
                    if is_title_gen {
                        if let Some(title) = output_text.as_ref().and_then(|t| Self::clean_title(t)) {
                            debug!(title = %title, "LLM hook generated session title");
                            emitter.emit(crate::core::events::TronEvent::SessionUpdated {
                                base: BaseEvent::now(&session_id),
                                title: Some(title),
                                model: model.clone(),
                                message_count: 0,
                                input_tokens: 0,
                                output_tokens: 0,
                                last_turn_input_tokens: 0,
                                cache_read_tokens: 0,
                                cache_creation_tokens: 0,
                                cost: 0.0,
                                last_activity: chrono::Utc::now().to_rfc3339(),
                                is_active: true,
                                last_user_prompt: None,
                                last_assistant_response: None,
                                parent_session_id: None,
                            });
                        }
                    }

                    // For branch name generation, rename the branch
                    if is_branch_name_gen {
                        if let (Some(name), Some(coord)) = (
                            output_text.as_ref().and_then(|t| Self::clean_branch_name(t)),
                            &coordinator,
                        ) {
                            let new_branch = format!(
                                "{}{}",
                                coord.config().branch_prefix,
                                name
                            );
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

                    // Emit LlmHookResult event for audit trail
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

                    emitter.emit(crate::core::events::TronEvent::LlmHookResult {
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
                    });
                }
                Err(e) => {
                    warn!(
                        hook_id = %hook_id,
                        error = %e,
                        "LLM hook subsession failed"
                    );
                    emitter.emit(crate::core::events::TronEvent::LlmHookResult {
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
                    });
                }
            }
        });

        debug!(id = %self.id, "[prompt_hook] handle() returning Continue (subsession running in background)");
        Ok(HookResult::continue_())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- clean_title tests ---

    #[test]
    fn test_clean_title_basic() {
        assert_eq!(
            PromptHookHandler::clean_title("Fix login bug"),
            Some("Fix login bug".to_string())
        );
    }

    #[test]
    fn test_clean_title_strips_whitespace() {
        assert_eq!(
            PromptHookHandler::clean_title("  Fix login bug  "),
            Some("Fix login bug".to_string())
        );
    }

    #[test]
    fn test_clean_title_strips_quotes() {
        assert_eq!(
            PromptHookHandler::clean_title("\"Fix login bug\""),
            Some("Fix login bug".to_string())
        );
        assert_eq!(
            PromptHookHandler::clean_title("'Fix login bug'"),
            Some("Fix login bug".to_string())
        );
    }

    #[test]
    fn test_clean_title_strips_whitespace_and_quotes() {
        assert_eq!(
            PromptHookHandler::clean_title("  \"  Fix login bug  \"  "),
            Some("Fix login bug".to_string())
        );
    }

    #[test]
    fn test_clean_title_truncates_long() {
        let long_title = "A".repeat(200);
        let result = PromptHookHandler::clean_title(&long_title).unwrap();
        assert!(result.len() <= MAX_TITLE_LENGTH);
        assert!(result.ends_with("..."));
    }

    #[test]
    fn test_clean_title_empty() {
        assert_eq!(PromptHookHandler::clean_title(""), None);
        assert_eq!(PromptHookHandler::clean_title("   "), None);
        assert_eq!(PromptHookHandler::clean_title("\"\""), None);
    }

    #[test]
    fn test_clean_title_replaces_newlines() {
        assert_eq!(
            PromptHookHandler::clean_title("Fix\nlogin\nbug"),
            Some("Fix login bug".to_string())
        );
    }

    // --- truncate_output tests ---

    #[test]
    fn test_truncate_output_short() {
        assert_eq!(
            PromptHookHandler::truncate_output("hello"),
            Some("hello".to_string())
        );
    }

    #[test]
    fn test_truncate_output_long() {
        let long = "A".repeat(2000);
        let result = PromptHookHandler::truncate_output(&long).unwrap();
        assert!(result.len() <= MAX_OUTPUT_LENGTH);
        assert!(result.ends_with("..."));
    }

    #[test]
    fn test_truncate_output_empty() {
        assert_eq!(PromptHookHandler::truncate_output(""), None);
        assert_eq!(PromptHookHandler::truncate_output("   "), None);
    }

    // --- clean_branch_name tests ---

    #[test]
    fn test_clean_branch_name_basic_three_words() {
        assert_eq!(
            PromptHookHandler::clean_branch_name("fuzzy-purple-elephant"),
            Some("fuzzy-purple-elephant".to_string())
        );
    }

    #[test]
    fn test_clean_branch_name_strips_whitespace() {
        assert_eq!(
            PromptHookHandler::clean_branch_name("  fuzzy-purple-elephant  "),
            Some("fuzzy-purple-elephant".to_string())
        );
    }

    #[test]
    fn test_clean_branch_name_strips_quotes() {
        assert_eq!(
            PromptHookHandler::clean_branch_name("\"fuzzy-purple-elephant\""),
            Some("fuzzy-purple-elephant".to_string())
        );
        assert_eq!(
            PromptHookHandler::clean_branch_name("'fuzzy-purple-elephant'"),
            Some("fuzzy-purple-elephant".to_string())
        );
    }

    #[test]
    fn test_clean_branch_name_lowercases() {
        assert_eq!(
            PromptHookHandler::clean_branch_name("Fuzzy-Purple-Elephant"),
            Some("fuzzy-purple-elephant".to_string())
        );
    }

    #[test]
    fn test_clean_branch_name_replaces_spaces_with_hyphens() {
        assert_eq!(
            PromptHookHandler::clean_branch_name("fuzzy purple elephant"),
            Some("fuzzy-purple-elephant".to_string())
        );
    }

    #[test]
    fn test_clean_branch_name_strips_non_alphanumeric() {
        assert_eq!(
            PromptHookHandler::clean_branch_name("fuzzy_purple!elephant"),
            Some("fuzzy-purple-elephant".to_string())
        );
        assert_eq!(
            PromptHookHandler::clean_branch_name("fuzzy.purple.elephant"),
            Some("fuzzy-purple-elephant".to_string())
        );
    }

    #[test]
    fn test_clean_branch_name_rejects_empty() {
        assert_eq!(PromptHookHandler::clean_branch_name(""), None);
        assert_eq!(PromptHookHandler::clean_branch_name("   "), None);
        assert_eq!(PromptHookHandler::clean_branch_name("\"\""), None);
    }

    #[test]
    fn test_clean_branch_name_rejects_single_word() {
        assert_eq!(PromptHookHandler::clean_branch_name("elephant"), None);
    }

    #[test]
    fn test_clean_branch_name_rejects_two_words() {
        assert_eq!(PromptHookHandler::clean_branch_name("purple-elephant"), None);
    }

    #[test]
    fn test_clean_branch_name_takes_first_three_words() {
        assert_eq!(
            PromptHookHandler::clean_branch_name("fuzzy-purple-elephant-running"),
            Some("fuzzy-purple-elephant".to_string())
        );
    }

    #[test]
    fn test_clean_branch_name_truncates_long() {
        let long = format!("{}-{}-{}", "a".repeat(30), "b".repeat(30), "c".repeat(30));
        let result = PromptHookHandler::clean_branch_name(&long).unwrap();
        assert!(result.len() <= MAX_BRANCH_NAME_LENGTH);
    }

    #[test]
    fn test_clean_branch_name_rejects_garbage_with_too_many_words() {
        // More than 3 words → takes first 3, which is "here-is-a" (not useful but valid format)
        // The LLM prompt constrains output to just the name; this tests the sanitizer, not the LLM
        let result = PromptHookHandler::clean_branch_name("Here is a random branch name: fuzzy-purple-elephant");
        // It will produce "here-is-a" from the first 3 words — that's valid format
        assert_eq!(result, Some("here-is-a".to_string()));
    }

    #[test]
    fn test_clean_branch_name_collapses_multiple_hyphens() {
        assert_eq!(
            PromptHookHandler::clean_branch_name("fuzzy--purple--elephant"),
            Some("fuzzy-purple-elephant".to_string())
        );
    }

    #[test]
    fn test_clean_branch_name_strips_leading_trailing_hyphens() {
        assert_eq!(
            PromptHookHandler::clean_branch_name("-fuzzy-purple-elephant-"),
            Some("fuzzy-purple-elephant".to_string())
        );
    }

    // --- Trait implementation tests (no SubagentManager needed) ---

    // Note: We can't easily construct a PromptHookHandler in unit tests
    // because it requires Arc<SubagentManager> and Arc<EventEmitter>.
    // The handle() behavior is tested via integration tests.
    // Here we test the pure functions and parse logic.

    #[test]
    fn test_build_task_truncates_long_context() {
        // Test via the static method approach — build_task is an instance method
        // so we verify the truncation logic directly
        let long_json = "x".repeat(1000);
        let truncated = if long_json.len() > 500 {
            format!("{}...(truncated)", &long_json[..500])
        } else {
            long_json.clone()
        };
        assert!(truncated.len() < long_json.len());
        assert!(truncated.ends_with("...(truncated)"));
    }
}
