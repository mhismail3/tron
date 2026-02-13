//! Central context manager.
//!
//! [`ContextManager`] orchestrates all context-related operations:
//! message tracking, token estimation, pre-turn validation,
//! compaction, tool result processing, model switching, and system
//! prompt management.

use tron_core::messages::Message;

use crate::compaction_engine::{CompactionDeps, CompactionEngine};
use crate::constants::{CHARS_PER_TOKEN, Thresholds, TOOL_RESULT_MAX_CHARS, TOOL_RESULT_MIN_TOKENS};
use crate::context_snapshot_builder::{ContextSnapshotBuilder, SnapshotDeps};
use crate::message_store::MessageStore;
use crate::summarizer::Summarizer;
use crate::system_prompts;
use crate::token_estimator;
use crate::types::{
    CompactionPreview, CompactionResult, ContextManagerConfig, ContextSnapshot,
    DetailedContextSnapshot, ExportedState, PreTurnValidation, ProcessedToolResult,
    SessionMemoryEntry,
};

// =============================================================================
// ContextManager
// =============================================================================

/// Central orchestrator for context window management.
pub struct ContextManager {
    config: ContextManagerConfig,
    messages: MessageStore,
    /// API-reported token count (ground truth when available).
    api_context_tokens: Option<u64>,
    /// Static system prompt (raw, not provider-adapted).
    system_prompt: String,
    /// Rules content (AGENTS.md / CLAUDE.md merged).
    rules_content: Option<String>,
    /// Dynamic scoped rules (path-activated).
    dynamic_rules_content: Option<String>,
    /// Workspace memory content.
    memory_content: Option<String>,
    /// Session-scoped memory entries.
    session_memories: Vec<SessionMemoryEntry>,
    /// Callback for when compaction is needed.
    on_compaction_needed: Option<Box<dyn Fn() + Send + Sync>>,
}

impl ContextManager {
    /// Create a new context manager with the given configuration.
    pub fn new(config: ContextManagerConfig) -> Self {
        let system_prompt = config
            .system_prompt
            .clone()
            .unwrap_or_else(|| system_prompts::TRON_CORE_PROMPT.to_owned());
        let rules_content = config.rules_content.clone();

        Self {
            config,
            messages: MessageStore::new(),
            api_context_tokens: None,
            system_prompt,
            rules_content,
            dynamic_rules_content: None,
            memory_content: None,
            session_memories: Vec::new(),
            on_compaction_needed: None,
        }
    }

    // ── Message management ──────────────────────────────────────────────

    /// Append a message to the conversation.
    pub fn add_message(&mut self, message: Message) {
        self.messages.add(message);
    }

    /// Replace all messages in the conversation.
    ///
    /// Clears API-reported tokens since the message set changed.
    pub fn set_messages(&mut self, messages: Vec<Message>) {
        self.messages.set(messages);
        self.api_context_tokens = None;
    }

    /// Get a defensive copy of all messages.
    #[must_use]
    pub fn get_messages(&self) -> Vec<Message> {
        self.messages.as_slice().to_vec()
    }

    /// Remove all messages from the conversation.
    ///
    /// Clears API-reported tokens since the message set changed.
    pub fn clear_messages(&mut self) {
        self.messages.clear();
        self.api_context_tokens = None;
    }

    #[must_use]
    /// Get the number of messages.
    pub fn message_count(&self) -> usize {
        self.messages.len()
    }

    // ── System prompt & rules ───────────────────────────────────────────

    #[must_use]
    /// Get the raw system prompt.
    pub fn get_system_prompt(&self) -> &str {
        &self.system_prompt
    }

    /// Set the static rules content.
    pub fn set_rules_content(&mut self, content: Option<String>) {
        self.rules_content = content;
    }

    /// Set the dynamic (path-scoped) rules content.
    pub fn set_dynamic_rules_content(&mut self, content: Option<String>) {
        self.dynamic_rules_content = content;
    }

    /// Set the workspace memory content.
    pub fn set_memory_content(&mut self, content: Option<String>) {
        self.memory_content = content;
    }

    #[must_use]
    /// Get the static rules content.
    pub fn get_rules_content(&self) -> Option<&str> {
        self.rules_content.as_deref()
    }

    #[must_use]
    /// Get the dynamic (path-scoped) rules content.
    pub fn get_dynamic_rules_content(&self) -> Option<&str> {
        self.dynamic_rules_content.as_deref()
    }

    #[must_use]
    /// Get the merged memory content (workspace + session memories).
    pub fn get_full_memory_content(&self) -> Option<String> {
        let base = self.memory_content.as_deref().unwrap_or("");
        if self.session_memories.is_empty() {
            if base.is_empty() {
                return None;
            }
            return Some(base.to_owned());
        }

        let session_section: String = self
            .session_memories
            .iter()
            .map(|m| format!("## {}\n{}", m.title, m.content))
            .collect::<Vec<_>>()
            .join("\n\n");

        if base.is_empty() {
            Some(session_section)
        } else {
            Some(format!("{base}\n\n{session_section}"))
        }
    }

    // ── Session memory ──────────────────────────────────────────────────

    /// Add a session-scoped memory entry.
    pub fn add_session_memory(&mut self, title: String, content: String) {
        #[allow(clippy::cast_possible_truncation)]
        let tokens = content.len().div_ceil(CHARS_PER_TOKEN as usize) as u64;
        self.session_memories.push(SessionMemoryEntry {
            title,
            content,
            tokens,
        });
    }

    #[must_use]
    /// Get all session memory entries.
    pub fn get_session_memories(&self) -> &[SessionMemoryEntry] {
        &self.session_memories
    }

    /// Remove all session memory entries.
    pub fn clear_session_memories(&mut self) {
        self.session_memories.clear();
    }

    // ── Token tracking ──────────────────────────────────────────────────

    /// Get current total token count.
    ///
    /// Uses API-reported tokens if available; otherwise sums component estimates.
    #[must_use]
    pub fn get_current_tokens(&self) -> u64 {
        if let Some(api_tokens) = self.api_context_tokens {
            return api_tokens;
        }
        self.estimate_system_prompt_tokens()
            + self.estimate_tools_tokens()
            + self.estimate_rules_tokens()
            + self.get_messages_tokens()
    }

    /// Set API-reported token count (ground truth from model tokenizer).
    pub fn set_api_context_tokens(&mut self, tokens: u64) {
        self.api_context_tokens = Some(tokens);
    }

    #[must_use]
    /// Get the API-reported token count, if set.
    pub fn get_api_context_tokens(&self) -> Option<u64> {
        self.api_context_tokens
    }

    #[must_use]
    /// Get the model's context limit in tokens.
    pub fn get_context_limit(&self) -> u64 {
        self.config.compaction.context_limit
    }

    #[must_use]
    /// Get the current model identifier.
    pub fn get_model(&self) -> &str {
        &self.config.model
    }

    // ── Token estimation ────────────────────────────────────────────────

    #[must_use]
    /// Estimate system prompt token count.
    pub fn estimate_system_prompt_tokens(&self) -> u64 {
        u64::from(token_estimator::estimate_system_prompt_tokens(&self.system_prompt, None))
    }

    #[must_use]
    /// Estimate tool definitions token count.
    pub fn estimate_tools_tokens(&self) -> u64 {
        u64::from(token_estimator::estimate_tools_tokens(&self.config.tools))
    }

    #[must_use]
    /// Estimate combined static + dynamic rules token count.
    pub fn estimate_rules_tokens(&self) -> u64 {
        let static_rules =
            u64::from(token_estimator::estimate_rules_tokens(self.rules_content.as_deref()));
        let dynamic_rules =
            u64::from(token_estimator::estimate_rules_tokens(self.dynamic_rules_content.as_deref()));
        static_rules + dynamic_rules
    }

    #[must_use]
    /// Get total message tokens from the message store cache.
    pub fn get_messages_tokens(&self) -> u64 {
        u64::from(self.messages.get_tokens())
    }

    #[must_use]
    /// Estimate tokens for a single message.
    pub fn get_message_tokens(&self, msg: &Message) -> u64 {
        u64::from(token_estimator::estimate_message_tokens(msg))
    }

    // ── Snapshot & validation ───────────────────────────────────────────

    #[must_use]
    /// Build a context snapshot with token breakdown.
    pub fn get_snapshot(&self) -> ContextSnapshot {
        let deps = ManagerSnapshotDeps { manager: self };
        let builder = ContextSnapshotBuilder::new(deps);
        builder.build()
    }

    #[must_use]
    /// Build a detailed snapshot including per-message breakdown.
    pub fn get_detailed_snapshot(&self) -> DetailedContextSnapshot {
        let deps = ManagerSnapshotDeps { manager: self };
        let builder = ContextSnapshotBuilder::new(deps);
        builder.build_detailed()
    }

    /// Check if a new turn can be accepted.
    #[must_use]
    pub fn can_accept_turn(&self, estimated_response_tokens: u64) -> PreTurnValidation {
        let current = self.get_current_tokens();
        let limit = self.get_context_limit();
        let estimated_after = current + estimated_response_tokens;

        #[allow(clippy::cast_precision_loss)]
        let ratio = if limit > 0 {
            current as f64 / limit as f64
        } else {
            0.0
        };

        PreTurnValidation {
            can_proceed: ratio < Thresholds::CRITICAL,
            needs_compaction: ratio >= Thresholds::ALERT,
            would_exceed_limit: estimated_after > limit,
            current_tokens: current,
            estimated_after_turn: estimated_after,
            context_limit: limit,
        }
    }

    // ── Compaction ──────────────────────────────────────────────────────

    /// Check if compaction is recommended.
    #[must_use]
    pub fn should_compact(&self) -> bool {
        let limit = self.get_context_limit();
        if limit == 0 {
            return false;
        }
        #[allow(clippy::cast_precision_loss)]
        let ratio = self.get_current_tokens() as f64 / limit as f64;
        ratio >= self.config.compaction.threshold
    }

    /// Preview compaction without modifying state.
    pub async fn preview_compaction(
        &self,
        summarizer: &dyn Summarizer,
    ) -> Result<CompactionPreview, Box<dyn std::error::Error + Send + Sync>> {
        let deps = ManagerCompactionDeps::from_manager(self);
        let engine = CompactionEngine::new(
            self.config.compaction.threshold,
            self.config.compaction.preserve_recent_turns,
            deps,
        );
        engine.preview(summarizer).await
    }

    /// Execute compaction.
    pub async fn execute_compaction(
        &mut self,
        summarizer: &dyn Summarizer,
        edited_summary: Option<&str>,
    ) -> Result<CompactionResult, Box<dyn std::error::Error + Send + Sync>> {
        let deps = ManagerCompactionDeps::from_manager(self);
        let engine = CompactionEngine::new(
            self.config.compaction.threshold,
            self.config.compaction.preserve_recent_turns,
            deps,
        );
        let result = engine.execute(summarizer, edited_summary).await?;

        // Apply the compacted messages back
        let new_messages = engine.deps.get_messages();
        self.messages.set(new_messages);

        // Clear API tokens since they're now stale
        self.api_context_tokens = None;

        Ok(result)
    }

    /// Register a callback for when compaction is needed.
    pub fn on_compaction_needed(&mut self, callback: impl Fn() + Send + Sync + 'static) {
        self.on_compaction_needed = Some(Box::new(callback));
    }

    /// Check and trigger compaction callback if needed.
    pub fn trigger_compaction_if_needed(&self) {
        if self.should_compact() {
            if let Some(cb) = &self.on_compaction_needed {
                cb();
            }
        }
    }

    // ── Tool result processing ──────────────────────────────────────────

    /// Process a tool result, truncating if necessary.
    #[must_use]
    pub fn process_tool_result(
        &self,
        tool_call_id: &str,
        content: &str,
    ) -> ProcessedToolResult {
        let max_size = self.get_max_tool_result_size();

        if content.len() <= max_size {
            ProcessedToolResult {
                tool_call_id: tool_call_id.to_owned(),
                content: content.to_owned(),
                truncated: false,
                original_size: None,
            }
        } else {
            let truncated_content = format!(
                "{}...\n[Truncated: {} chars total, showing first {}]",
                &content[..max_size.saturating_sub(100)],
                content.len(),
                max_size.saturating_sub(100),
            );
            ProcessedToolResult {
                tool_call_id: tool_call_id.to_owned(),
                content: truncated_content,
                truncated: true,
                original_size: Some(content.len()),
            }
        }
    }

    /// Get maximum tool result size based on remaining context.
    ///
    /// Reserves 8000 tokens for the model response and 10% safety margin,
    /// then converts the available tokens to chars (4 chars per token).
    #[must_use]
    pub fn get_max_tool_result_size(&self) -> usize {
        let limit = self.get_context_limit();
        let current = self.get_current_tokens();
        let remaining = limit.saturating_sub(current);

        // Reserve tokens for model response + safety margin
        let response_reserve: u64 = 8_000;
        let safety_margin: u64 = remaining / 10;

        let available_tokens = remaining
            .saturating_sub(response_reserve)
            .saturating_sub(safety_margin)
            .max(u64::from(TOOL_RESULT_MIN_TOKENS));

        #[allow(clippy::cast_possible_truncation)]
        let budget = (available_tokens as usize) * (CHARS_PER_TOKEN as usize);
        budget.min(TOOL_RESULT_MAX_CHARS)
    }

    // ── Model switching ─────────────────────────────────────────────────

    /// Switch to a different model and context limit.
    pub fn switch_model(&mut self, new_model: String, context_limit: u64) {
        self.config.model = new_model;
        self.config.compaction.context_limit = context_limit;
        self.api_context_tokens = None;
    }

    // ── Export ───────────────────────────────────────────────────────────

    #[must_use]
    /// Export the full context state for persistence.
    pub fn export_state(&self) -> ExportedState {
        ExportedState {
            model: self.config.model.clone(),
            system_prompt: self.system_prompt.clone(),
            tools: self.config.tools.clone(),
            messages: self.get_messages(),
        }
    }
}

// =============================================================================
// Snapshot deps adapter
// =============================================================================

/// Adapts `&ContextManager` to [`SnapshotDeps`].
struct ManagerSnapshotDeps<'a> {
    manager: &'a ContextManager,
}

impl SnapshotDeps for ManagerSnapshotDeps<'_> {
    fn get_current_tokens(&self) -> u64 {
        self.manager.get_current_tokens()
    }
    fn get_context_limit(&self) -> u64 {
        self.manager.get_context_limit()
    }
    fn get_messages(&self) -> Vec<Message> {
        self.manager.get_messages()
    }
    fn estimate_system_prompt_tokens(&self) -> u64 {
        self.manager.estimate_system_prompt_tokens()
    }
    fn estimate_tools_tokens(&self) -> u64 {
        self.manager.estimate_tools_tokens()
    }
    fn estimate_rules_tokens(&self) -> u64 {
        self.manager.estimate_rules_tokens()
    }
    fn get_messages_tokens(&self) -> u64 {
        self.manager.get_messages_tokens()
    }
    fn get_message_tokens(&self, msg: &Message) -> u64 {
        self.manager.get_message_tokens(msg)
    }
    fn get_system_prompt(&self) -> String {
        self.manager.get_system_prompt().to_owned()
    }
    fn get_tool_clarification(&self) -> Option<String> {
        None
    }
    fn get_tool_names(&self) -> Vec<String> {
        self.manager
            .config
            .tools
            .iter()
            .map(|t| t.name.clone())
            .collect()
    }
}

// =============================================================================
// Compaction deps adapter
// =============================================================================

/// Adapts context manager state for the compaction engine.
///
/// Uses interior mutability (`std::sync::Mutex`) so `CompactionEngine` can
/// modify messages during compaction.
struct ManagerCompactionDeps {
    messages: std::sync::Mutex<Vec<Message>>,
    current_tokens: u64,
    context_limit: u64,
    system_prompt_tokens: u64,
    tools_tokens: u64,
}

impl ManagerCompactionDeps {
    fn from_manager(manager: &ContextManager) -> Self {
        Self {
            messages: std::sync::Mutex::new(manager.get_messages()),
            current_tokens: manager.get_current_tokens(),
            context_limit: manager.get_context_limit(),
            system_prompt_tokens: manager.estimate_system_prompt_tokens(),
            tools_tokens: manager.estimate_tools_tokens(),
        }
    }
}

impl CompactionDeps for ManagerCompactionDeps {
    fn get_messages(&self) -> Vec<Message> {
        self.messages.lock().unwrap().clone()
    }
    fn set_messages(&self, messages: Vec<Message>) {
        *self.messages.lock().unwrap() = messages;
    }
    fn get_current_tokens(&self) -> u64 {
        self.current_tokens
    }
    fn get_context_limit(&self) -> u64 {
        self.context_limit
    }
    fn estimate_system_prompt_tokens(&self) -> u64 {
        self.system_prompt_tokens
    }
    fn estimate_tools_tokens(&self) -> u64 {
        self.tools_tokens
    }
    fn get_message_tokens(&self, msg: &Message) -> u64 {
        u64::from(token_estimator::estimate_message_tokens(msg))
    }
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::CompactionConfig;

    fn test_config() -> ContextManagerConfig {
        ContextManagerConfig {
            model: "claude-sonnet-4-5-20250929".into(),
            system_prompt: Some("You are helpful.".into()),
            working_directory: Some("/tmp".into()),
            tools: Vec::new(),
            rules_content: None,
            compaction: CompactionConfig {
                threshold: 0.70,
                preserve_recent_turns: 2,
                context_limit: 100_000,
            },
        }
    }

    // -- construction --

    #[test]
    fn new_context_manager() {
        let cm = ContextManager::new(test_config());
        assert_eq!(cm.get_model(), "claude-sonnet-4-5-20250929");
        assert_eq!(cm.get_system_prompt(), "You are helpful.");
        assert_eq!(cm.message_count(), 0);
        assert_eq!(cm.get_context_limit(), 100_000);
    }

    #[test]
    fn default_system_prompt() {
        let config = ContextManagerConfig {
            system_prompt: None,
            ..test_config()
        };
        let cm = ContextManager::new(config);
        assert!(!cm.get_system_prompt().is_empty());
    }

    // -- message management --

    #[test]
    fn add_and_get_messages() {
        let mut cm = ContextManager::new(test_config());
        cm.add_message(Message::user("Hello"));
        cm.add_message(Message::assistant("Hi"));
        assert_eq!(cm.message_count(), 2);

        let msgs = cm.get_messages();
        assert_eq!(msgs.len(), 2);
    }

    #[test]
    fn set_messages_replaces() {
        let mut cm = ContextManager::new(test_config());
        cm.add_message(Message::user("old"));
        cm.set_messages(vec![Message::user("new1"), Message::user("new2")]);
        assert_eq!(cm.message_count(), 2);
    }

    #[test]
    fn set_messages_clears_api_tokens() {
        let mut cm = ContextManager::new(test_config());
        cm.set_api_context_tokens(50_000);
        assert!(cm.get_api_context_tokens().is_some());
        cm.set_messages(vec![Message::user("new")]);
        assert!(cm.get_api_context_tokens().is_none());
    }

    #[test]
    fn clear_messages() {
        let mut cm = ContextManager::new(test_config());
        cm.add_message(Message::user("msg"));
        cm.clear_messages();
        assert_eq!(cm.message_count(), 0);
    }

    #[test]
    fn clear_messages_clears_api_tokens() {
        let mut cm = ContextManager::new(test_config());
        cm.set_api_context_tokens(50_000);
        assert!(cm.get_api_context_tokens().is_some());
        cm.clear_messages();
        assert!(cm.get_api_context_tokens().is_none());
    }

    // -- rules & memory --

    #[test]
    fn set_and_get_rules() {
        let mut cm = ContextManager::new(test_config());
        assert!(cm.get_rules_content().is_none());

        cm.set_rules_content(Some("# Rules".into()));
        assert_eq!(cm.get_rules_content(), Some("# Rules"));
    }

    #[test]
    fn dynamic_rules() {
        let mut cm = ContextManager::new(test_config());
        cm.set_dynamic_rules_content(Some("dynamic".into()));
        assert_eq!(cm.get_dynamic_rules_content(), Some("dynamic"));
    }

    #[test]
    fn memory_content_base_only() {
        let mut cm = ContextManager::new(test_config());
        cm.set_memory_content(Some("base memory".into()));
        assert_eq!(cm.get_full_memory_content(), Some("base memory".into()));
    }

    #[test]
    fn memory_content_with_session() {
        let mut cm = ContextManager::new(test_config());
        cm.set_memory_content(Some("base".into()));
        cm.add_session_memory("Topic".into(), "Detail".into());

        let full = cm.get_full_memory_content().unwrap();
        assert!(full.contains("base"));
        assert!(full.contains("## Topic"));
        assert!(full.contains("Detail"));
    }

    #[test]
    fn memory_content_session_only() {
        let mut cm = ContextManager::new(test_config());
        cm.add_session_memory("Title".into(), "Content".into());
        let full = cm.get_full_memory_content().unwrap();
        assert!(full.contains("## Title"));
    }

    #[test]
    fn memory_content_none() {
        let cm = ContextManager::new(test_config());
        assert!(cm.get_full_memory_content().is_none());
    }

    #[test]
    fn session_memory_cleared() {
        let mut cm = ContextManager::new(test_config());
        cm.add_session_memory("t".into(), "c".into());
        assert_eq!(cm.get_session_memories().len(), 1);
        cm.clear_session_memories();
        assert!(cm.get_session_memories().is_empty());
    }

    // -- token tracking --

    #[test]
    fn tokens_estimated_by_default() {
        let mut cm = ContextManager::new(test_config());
        cm.add_message(Message::user("Hello world"));
        let tokens = cm.get_current_tokens();
        assert!(tokens > 0);
    }

    #[test]
    fn api_tokens_override_estimate() {
        let mut cm = ContextManager::new(test_config());
        cm.add_message(Message::user("Hello"));
        cm.set_api_context_tokens(42_000);
        assert_eq!(cm.get_current_tokens(), 42_000);
        assert_eq!(cm.get_api_context_tokens(), Some(42_000));
    }

    // -- snapshot --

    #[test]
    fn get_snapshot() {
        let mut cm = ContextManager::new(test_config());
        cm.add_message(Message::user("Test"));
        let snap = cm.get_snapshot();
        assert_eq!(snap.context_limit, 100_000);
        assert!(snap.current_tokens > 0);
        assert!(snap.usage_percent >= 0.0);
    }

    #[test]
    fn get_detailed_snapshot() {
        let mut cm = ContextManager::new(test_config());
        cm.add_message(Message::user("Hello"));
        cm.add_message(Message::assistant("Hi"));
        let detailed = cm.get_detailed_snapshot();
        assert_eq!(detailed.messages.len(), 2);
        assert_eq!(detailed.messages[0].role, "user");
    }

    // -- validation --

    #[test]
    fn can_accept_turn_normal() {
        let cm = ContextManager::new(test_config());
        let v = cm.can_accept_turn(1_000);
        assert!(v.can_proceed);
        assert!(!v.needs_compaction);
    }

    #[test]
    fn can_accept_turn_near_limit() {
        let mut cm = ContextManager::new(test_config());
        cm.set_api_context_tokens(90_000);
        let v = cm.can_accept_turn(15_000);
        assert!(!v.can_proceed); // 90% >= critical (85%)
        assert!(v.needs_compaction);
        assert!(v.would_exceed_limit); // 90_000 + 15_000 > 100_000
    }

    // -- compaction --

    #[test]
    fn should_compact_below_threshold() {
        let cm = ContextManager::new(test_config());
        assert!(!cm.should_compact());
    }

    #[test]
    fn should_compact_above_threshold() {
        let mut cm = ContextManager::new(test_config());
        cm.set_api_context_tokens(80_000); // 80% >= 70%
        assert!(cm.should_compact());
    }

    #[test]
    fn trigger_compaction_callback() {
        let mut cm = ContextManager::new(test_config());
        cm.set_api_context_tokens(80_000);

        let called = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let called_clone = called.clone();
        cm.on_compaction_needed(move || {
            called_clone.store(true, std::sync::atomic::Ordering::SeqCst);
        });

        cm.trigger_compaction_if_needed();
        assert!(called.load(std::sync::atomic::Ordering::SeqCst));
    }

    // -- tool result processing --

    #[test]
    fn process_small_tool_result() {
        let cm = ContextManager::new(test_config());
        let result = cm.process_tool_result("tc-1", "small output");
        assert!(!result.truncated);
        assert_eq!(result.content, "small output");
        assert!(result.original_size.is_none());
    }

    #[test]
    fn process_large_tool_result() {
        let cm = ContextManager::new(test_config());
        let large = "x".repeat(TOOL_RESULT_MAX_CHARS + 1000);
        let result = cm.process_tool_result("tc-1", &large);
        assert!(result.truncated);
        assert!(result.original_size.is_some());
        assert!(result.content.len() < large.len());
    }

    #[test]
    fn tool_result_budget_reserves_for_response() {
        let mut cm = ContextManager::new(test_config());
        // 50k tokens used of 100k limit → 50k remaining
        cm.set_api_context_tokens(50_000);
        let max_size = cm.get_max_tool_result_size();

        // remaining=50k, reserve=8k, margin=5k → available=37k tokens → 148k chars
        // But capped at TOOL_RESULT_MAX_CHARS (100k)
        assert_eq!(max_size, TOOL_RESULT_MAX_CHARS);
    }

    #[test]
    fn tool_result_budget_near_limit() {
        let mut cm = ContextManager::new(test_config());
        // 95k tokens used of 100k limit → 5k remaining
        cm.set_api_context_tokens(95_000);
        let max_size = cm.get_max_tool_result_size();

        // remaining=5k, reserve=8k → saturating_sub yields 0 before margin
        // Falls back to TOOL_RESULT_MIN_TOKENS (2500) * 4 = 10000 chars
        assert_eq!(max_size, (TOOL_RESULT_MIN_TOKENS as usize) * (CHARS_PER_TOKEN as usize));
    }

    // -- model switching --

    #[test]
    fn switch_model() {
        let mut cm = ContextManager::new(test_config());
        cm.set_api_context_tokens(50_000);
        cm.switch_model("claude-opus-4-6".into(), 200_000);
        assert_eq!(cm.get_model(), "claude-opus-4-6");
        assert_eq!(cm.get_context_limit(), 200_000);
        // API tokens cleared on model switch
        assert!(cm.get_api_context_tokens().is_none());
    }

    // -- export --

    #[test]
    fn export_state() {
        let mut cm = ContextManager::new(test_config());
        cm.add_message(Message::user("msg"));
        let exported = cm.export_state();
        assert_eq!(exported.model, "claude-sonnet-4-5-20250929");
        assert_eq!(exported.messages.len(), 1);
        assert_eq!(exported.system_prompt, "You are helpful.");
    }

    // -- rules token estimation --

    #[test]
    fn rules_tokens_both_static_and_dynamic() {
        let mut cm = ContextManager::new(test_config());
        cm.set_rules_content(Some("static rules".into()));
        cm.set_dynamic_rules_content(Some("dynamic rules".into()));
        let tokens = cm.estimate_rules_tokens();
        assert!(tokens > 0);
    }
}
