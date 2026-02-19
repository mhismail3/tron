//! Central context manager.
//!
//! [`ContextManager`] orchestrates all context-related operations:
//! message tracking, token estimation, pre-turn validation,
//! compaction, tool result processing, model switching, and system
//! prompt management.

use tron_core::events::ActivatedRuleInfo;
use tron_core::messages::Message;

use super::compaction_engine::{CompactionDeps, CompactionEngine};
use super::constants::{
    CHARS_PER_TOKEN, TOOL_RESULT_MAX_CHARS, TOOL_RESULT_MIN_TOKENS, Thresholds,
};
use super::context_snapshot_builder::{ContextSnapshotBuilder, SnapshotDeps};
use super::message_store::MessageStore;
use super::rules_index::RulesIndex;
use super::rules_tracker::RulesTracker;
use super::summarizer::Summarizer;
use super::system_prompts;
use super::token_estimator;
use super::types::{
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
    /// Rules tracker for dynamic scoped-rule activation.
    rules_tracker: RulesTracker,
}

impl ContextManager {
    /// Create a new context manager with the given configuration.
    pub fn new(mut config: ContextManagerConfig) -> Self {
        // Default working_directory to $HOME/Workspace/ rather than /tmp
        if config.working_directory.is_none() {
            if let Ok(home) = std::env::var("HOME") {
                config.working_directory = Some(format!("{home}/Workspace"));
            }
        }

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
            rules_tracker: RulesTracker::new(),
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

    // ── Dynamic rules activation ───────────────────────────────────────

    /// Set the rules index for dynamic path-scoped activation.
    pub fn set_rules_index(&mut self, index: RulesIndex) {
        self.rules_tracker.set_rules_index(index);
    }

    /// Record a file path touch and activate matching scoped rules.
    ///
    /// Returns info about newly activated rules (empty if no new activations).
    pub fn touch_file_path(&mut self, relative_path: &str) -> Vec<ActivatedRuleInfo> {
        if !self.rules_tracker.touch_path(relative_path) {
            return vec![];
        }
        // Rebuild dynamic content after new activations
        let content = self
            .rules_tracker
            .build_dynamic_rules_content()
            .map(String::from);
        self.dynamic_rules_content = content;

        // Return all activated rules (caller decides which are "new" based on batch)
        self.rules_tracker
            .activated_rules()
            .iter()
            .map(|r| ActivatedRuleInfo {
                relative_path: r.relative_path.clone(),
                scope_dir: r.scope_dir.clone(),
            })
            .collect()
    }

    /// Clear dynamic rules state (for compaction boundary).
    pub fn clear_dynamic_rules(&mut self) {
        self.rules_tracker.clear_dynamic_state();
        self.dynamic_rules_content = None;
    }

    /// Pre-activate a rule by its relative path (for session reconstruction).
    pub fn pre_activate_rule(&mut self, rule_relative_path: &str) -> bool {
        self.rules_tracker.pre_activate(rule_relative_path)
    }

    /// Rebuild `dynamic_rules_content` from current tracker state.
    ///
    /// Call after `pre_activate_rule()` batch to update the content field.
    pub fn finalize_rule_activations(&mut self) {
        if let Some(content) = self.rules_tracker.build_dynamic_rules_content() {
            self.dynamic_rules_content = Some(content.to_owned());
        }
    }

    /// Get a reference to the rules tracker.
    #[must_use]
    pub fn rules_tracker(&self) -> &RulesTracker {
        &self.rules_tracker
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

    #[must_use]
    /// Get the working directory (for file operations and tool context).
    pub fn get_working_directory(&self) -> &str {
        self.config.working_directory.as_deref().unwrap_or("/tmp")
    }

    // ── Token estimation ────────────────────────────────────────────────

    #[must_use]
    /// Estimate system prompt token count.
    pub fn estimate_system_prompt_tokens(&self) -> u64 {
        u64::from(token_estimator::estimate_system_prompt_tokens(
            &self.system_prompt,
            None,
        ))
    }

    #[must_use]
    /// Estimate tool definitions token count.
    pub fn estimate_tools_tokens(&self) -> u64 {
        u64::from(token_estimator::estimate_tools_tokens(&self.config.tools))
    }

    #[must_use]
    /// Estimate combined static + dynamic rules token count.
    pub fn estimate_rules_tokens(&self) -> u64 {
        let static_rules = u64::from(token_estimator::estimate_rules_tokens(
            self.rules_content.as_deref(),
        ));
        let dynamic_rules = u64::from(token_estimator::estimate_rules_tokens(
            self.dynamic_rules_content.as_deref(),
        ));
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
    pub fn can_accept_turn(&self) -> PreTurnValidation {
        let current = self.get_current_tokens();
        let limit = self.get_context_limit();

        #[allow(clippy::cast_precision_loss)]
        let ratio = if limit > 0 {
            current as f64 / limit as f64
        } else {
            0.0
        };

        PreTurnValidation {
            can_proceed: ratio < Thresholds::CRITICAL,
            needs_compaction: ratio >= self.config.compaction.threshold,
            current_tokens: current,
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
            self.config.compaction.preserve_ratio,
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
            self.config.compaction.preserve_ratio,
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
    pub fn process_tool_result(&self, tool_call_id: &str, content: &str) -> ProcessedToolResult {
        let max_size = self.get_max_tool_result_size();

        if content.len() <= max_size {
            ProcessedToolResult {
                tool_call_id: tool_call_id.to_owned(),
                content: content.to_owned(),
                truncated: false,
                original_size: None,
            }
        } else {
            let body_budget = max_size.saturating_sub(100);
            let prefix = tron_core::text::truncate_str(content, body_budget);
            let truncated_content = format!(
                "{prefix}...\n[Truncated: {} chars total, showing first {}]",
                content.len(),
                prefix.len(),
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
    ///
    /// Clears API tokens and triggers compaction callback if the new limit
    /// is smaller and current usage exceeds the threshold.
    pub fn switch_model(&mut self, new_model: String, context_limit: u64) {
        self.config.model = new_model;
        self.config.compaction.context_limit = context_limit;
        self.api_context_tokens = None;
        self.trigger_compaction_if_needed();
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
    use crate::context::types::CompactionConfig;

    fn test_config() -> ContextManagerConfig {
        ContextManagerConfig {
            model: "claude-sonnet-4-5-20250929".into(),
            system_prompt: Some("You are helpful.".into()),
            working_directory: Some("/tmp".into()),
            tools: Vec::new(),
            rules_content: None,
            compaction: CompactionConfig {
                threshold: 0.70,
                preserve_ratio: 0.20,
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
    fn working_directory_defaults_to_home_workspace_when_none() {
        let config = ContextManagerConfig {
            working_directory: None,
            ..test_config()
        };
        let cm = ContextManager::new(config);
        let wd = cm.get_working_directory();
        let home = std::env::var("HOME").unwrap();
        assert_eq!(wd, format!("{home}/Workspace"));
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

    // -- dynamic rules integration --

    fn make_discovered(
        scope_dir: &str,
        relative_path: &str,
        is_global: bool,
        content: &str,
    ) -> crate::context::rules_discovery::DiscoveredRulesFile {
        crate::context::rules_discovery::DiscoveredRulesFile {
            path: std::path::PathBuf::from(format!("/project/{relative_path}")),
            relative_path: relative_path.to_owned(),
            content: content.to_owned(),
            scope_dir: scope_dir.to_owned(),
            is_global,
            is_standalone: false,
            size_bytes: content.len() as u64,
            modified_at: std::time::SystemTime::UNIX_EPOCH,
        }
    }

    #[test]
    fn touch_file_path_without_index_returns_empty() {
        let mut cm = ContextManager::new(test_config());
        let result = cm.touch_file_path("src/foo.rs");
        assert!(result.is_empty());
    }

    #[test]
    fn touch_file_path_activates_matching_rule() {
        let mut cm = ContextManager::new(test_config());
        let scoped = make_discovered(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            false,
            "# Context rules",
        );
        cm.set_rules_index(RulesIndex::new(vec![scoped]));

        let result = cm.touch_file_path("src/context/loader.rs");
        assert!(!result.is_empty());
        assert_eq!(result[0].scope_dir, "src/context");
    }

    #[test]
    fn touch_file_path_updates_dynamic_rules_content() {
        let mut cm = ContextManager::new(test_config());
        let scoped = make_discovered(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            false,
            "# Context rules",
        );
        cm.set_rules_index(RulesIndex::new(vec![scoped]));

        assert!(cm.get_dynamic_rules_content().is_none());
        let _ = cm.touch_file_path("src/context/loader.rs");
        assert!(cm.get_dynamic_rules_content().is_some());
        assert!(
            cm.get_dynamic_rules_content()
                .unwrap()
                .contains("# Context rules")
        );
    }

    #[test]
    fn touch_file_path_idempotent_for_same_scope() {
        let mut cm = ContextManager::new(test_config());
        let scoped = make_discovered(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            false,
            "# Rules",
        );
        cm.set_rules_index(RulesIndex::new(vec![scoped]));

        let r1 = cm.touch_file_path("src/context/a.rs");
        let r2 = cm.touch_file_path("src/context/b.rs");
        assert!(!r1.is_empty());
        assert!(r2.is_empty()); // Same scope, no new activation
    }

    #[test]
    fn clear_dynamic_rules_resets_content_and_tracker() {
        let mut cm = ContextManager::new(test_config());
        let scoped = make_discovered(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            false,
            "# Rules",
        );
        cm.set_rules_index(RulesIndex::new(vec![scoped]));
        let _ = cm.touch_file_path("src/context/loader.rs");
        assert!(cm.get_dynamic_rules_content().is_some());

        cm.clear_dynamic_rules();
        assert!(cm.get_dynamic_rules_content().is_none());
        assert_eq!(cm.rules_tracker().activated_scoped_rules_count(), 0);
    }

    #[test]
    fn clear_dynamic_rules_allows_reactivation() {
        let mut cm = ContextManager::new(test_config());
        let scoped = make_discovered(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            false,
            "# Rules",
        );
        cm.set_rules_index(RulesIndex::new(vec![scoped]));
        let _ = cm.touch_file_path("src/context/loader.rs");

        cm.clear_dynamic_rules();

        // Should activate again
        let result = cm.touch_file_path("src/context/loader.rs");
        assert!(!result.is_empty());
    }

    #[test]
    fn pre_activate_rule_sets_content() {
        let mut cm = ContextManager::new(test_config());
        let scoped = make_discovered(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            false,
            "# Context rules",
        );
        cm.set_rules_index(RulesIndex::new(vec![scoped]));

        assert!(cm.pre_activate_rule("src/context/.claude/CLAUDE.md"));
        cm.finalize_rule_activations();
        assert!(
            cm.get_dynamic_rules_content()
                .unwrap()
                .contains("# Context rules")
        );
    }

    #[test]
    fn pre_activate_rule_unknown_returns_false() {
        let mut cm = ContextManager::new(test_config());
        let scoped = make_discovered(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            false,
            "# Rules",
        );
        cm.set_rules_index(RulesIndex::new(vec![scoped]));

        assert!(!cm.pre_activate_rule("nonexistent/.claude/CLAUDE.md"));
    }

    #[test]
    fn set_rules_index_enables_activation() {
        let mut cm = ContextManager::new(test_config());
        // No index → no activation
        assert!(cm.touch_file_path("src/context/loader.rs").is_empty());

        // Set index → activation works
        let scoped = make_discovered(
            "src/context",
            "src/context/.claude/CLAUDE.md",
            false,
            "# Rules",
        );
        cm.set_rules_index(RulesIndex::new(vec![scoped]));
        assert!(!cm.touch_file_path("src/context/loader.rs").is_empty());
    }

    #[test]
    fn rules_tracker_accessible_via_getter() {
        let cm = ContextManager::new(test_config());
        assert_eq!(cm.rules_tracker().activated_scoped_rules_count(), 0);
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
        let v = cm.can_accept_turn();
        assert!(v.can_proceed);
        assert!(!v.needs_compaction);
    }

    #[test]
    fn can_accept_turn_at_alert() {
        let mut cm = ContextManager::new(test_config());
        cm.set_api_context_tokens(70_000); // 70% = threshold
        let v = cm.can_accept_turn();
        assert!(v.can_proceed);
        assert!(v.needs_compaction);
    }

    #[test]
    fn can_accept_turn_at_critical() {
        let mut cm = ContextManager::new(test_config());
        cm.set_api_context_tokens(85_000); // 85% = critical
        let v = cm.can_accept_turn();
        assert!(!v.can_proceed);
        assert!(v.needs_compaction);
    }

    #[test]
    fn can_accept_turn_at_exceeded() {
        let mut cm = ContextManager::new(test_config());
        cm.set_api_context_tokens(95_000); // 95% = exceeded
        let v = cm.can_accept_turn();
        assert!(!v.can_proceed);
        assert!(v.needs_compaction);
    }

    #[test]
    fn can_accept_turn_zero_limit() {
        let config = ContextManagerConfig {
            compaction: CompactionConfig {
                context_limit: 0,
                ..CompactionConfig::default()
            },
            ..test_config()
        };
        let cm = ContextManager::new(config);
        let v = cm.can_accept_turn();
        assert!(v.can_proceed); // ratio=0.0 < critical
        assert!(!v.needs_compaction); // ratio=0.0 < threshold
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
        assert_eq!(
            max_size,
            (TOOL_RESULT_MIN_TOKENS as usize) * (CHARS_PER_TOKEN as usize)
        );
    }

    // -- compaction config --

    #[test]
    fn compaction_config_default_ratio() {
        let config = CompactionConfig::default();
        assert!((config.preserve_ratio - 0.20).abs() < f64::EPSILON);
    }

    // -- model switching --

    #[test]
    fn switch_model_updates_limit() {
        let mut cm = ContextManager::new(test_config());
        cm.switch_model("claude-opus-4-6".into(), 128_000);
        assert_eq!(cm.get_context_limit(), 128_000);
    }

    #[test]
    fn switch_model_clears_api_tokens() {
        let mut cm = ContextManager::new(test_config());
        cm.set_api_context_tokens(50_000);
        cm.switch_model("claude-opus-4-6".into(), 200_000);
        assert_eq!(cm.get_model(), "claude-opus-4-6");
        assert_eq!(cm.get_context_limit(), 200_000);
        assert!(cm.get_api_context_tokens().is_none());
    }

    #[test]
    fn switch_model_triggers_callback() {
        let mut cm = ContextManager::new(test_config());
        // Set tokens at 150k — will be above threshold for 128k model
        cm.set_api_context_tokens(150_000);

        let called = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let called_clone = called.clone();
        cm.on_compaction_needed(move || {
            called_clone.store(true, std::sync::atomic::Ordering::SeqCst);
        });

        // Switch to 128k limit → 150/128 = 1.17 > 0.70 threshold
        // Note: api_context_tokens is cleared, so estimation is used.
        // Force high token count by setting tokens before switch, then clearing API
        // Actually, switch_model clears api_context_tokens, so we need actual messages.
        // Simpler: just set api_tokens high, switch to small limit — callback fires
        // before api_tokens is cleared? No — switch_model clears first, then calls trigger.
        // So we need enough estimated tokens from messages + system prompt.
        // Let's use a different approach: context_limit=100k, tokens already high from estimation
        drop(cm);

        // Better: use a manager where estimate is high
        let mut cm2 = ContextManager::new(test_config());
        let called2 = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let called2_clone = called2.clone();
        cm2.on_compaction_needed(move || {
            called2_clone.store(true, std::sync::atomic::Ordering::SeqCst);
        });

        // Add enough messages to get estimated tokens high
        for _ in 0..500 {
            cm2.add_message(Message::user("x".repeat(400)));
            cm2.add_message(Message::assistant("y".repeat(400)));
        }

        // Current estimated tokens should be substantial. Switch to small limit.
        let tokens = cm2.get_current_tokens();
        assert!(tokens > 10_000, "need substantial tokens, got {tokens}");
        cm2.switch_model("small-model".into(), 1_000);
        // tokens/1000 should be >> 0.70
        assert!(called2.load(std::sync::atomic::Ordering::SeqCst));
    }

    #[test]
    fn switch_model_no_callback_under_threshold() {
        let mut cm = ContextManager::new(test_config());
        let called = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let called_clone = called.clone();
        cm.on_compaction_needed(move || {
            called_clone.store(true, std::sync::atomic::Ordering::SeqCst);
        });

        // Low token usage, switch to larger model — should not fire
        cm.switch_model("claude-opus-4-6".into(), 500_000);
        assert!(!called.load(std::sync::atomic::Ordering::SeqCst));
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
