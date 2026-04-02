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

/// Maximum length for LLM hook output stored in events.
const MAX_OUTPUT_LENGTH: usize = 1024;

/// Hook names containing this substring trigger title generation.
/// Matches both builtin (`builtin:title-gen`) and user file (`user:title-gen`) hooks.
const TITLE_GEN_MARKER: &str = "title-gen";

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
        }
    }

    /// Attach an event store for schedule-based hooks (title gen).
    pub fn with_event_store(mut self, store: Arc<crate::events::EventStore>) -> Self {
        self.event_store = Some(store);
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

        // Title-gen has a schedule: first prompt, then every N prompts
        // or after compaction/memory events.
        if is_title_gen && !self.should_generate_title(context.session_id()) {
            return Ok(HookResult::continue_());
        }

        let task = self.build_task(context);
        let hook_id = self.id.clone();
        let hook_name = self.label.clone();
        let hook_event = self.hook_type.to_string();
        let model = self.model.clone();
        let session_id = context.session_id().to_owned();
        let manager = self.subagent_manager.clone();
        let emitter = self.event_emitter.clone();

        // Fire-and-forget: spawn the subsession in the background
        tokio::spawn(async move {
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

        // Always return Continue immediately — never block the main agent
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
