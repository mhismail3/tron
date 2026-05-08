//! Central context manager.
//!
//! [`ContextManager`] orchestrates all context-related operations:
//! message tracking, token estimation, pre-turn validation,
//! compaction, tool result processing, model switching, and system
//! prompt management.

use std::sync::Arc;

use crate::core::events::ActivatedRuleInfo;
use crate::core::messages::Message;

use super::compaction_engine::{CompactionDeps, CompactionEngine};
use super::constants::{
    CHARS_PER_TOKEN, TOOL_RESULT_MAX_CHARS, TOOL_RESULT_MIN_TOKENS, Thresholds,
};
use super::context_snapshot_builder::{ContextSnapshotBuilder, SnapshotDeps};
use super::local_policy;
use super::message_store::MessageStore;
use super::rules_index::RulesIndex;
use super::rules_tracker::RulesTracker;
use super::summarizer::Summarizer;
use super::token_estimator;
use super::types::{
    CompactionPreview, CompactionResult, ContextManagerConfig, ContextSnapshot,
    DetailedContextSnapshot, ExportedState, ExtractedData, PreTurnValidation, ProcessedToolResult,
    SessionMemoryEntry, ToolSummary,
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
    /// Lightweight skill index content (auto-generated listing of available skills).
    skill_index_content: Option<String>,
    /// Workspace memory content.
    memory_content: Option<String>,
    /// Session-scoped memory entries.
    session_memories: Vec<SessionMemoryEntry>,
    /// Callback for when compaction is needed.
    on_compaction_needed: Option<Box<dyn Fn() + Send + Sync>>,
    /// Rules tracker for dynamic scoped-rule activation.
    rules_tracker: RulesTracker,
    /// Latest extracted data from compaction (for checkpoint payloads).
    last_extracted_data: Option<super::types::ExtractedData>,
    /// Server origin (e.g. "localhost:9847") for environment token estimation.
    server_origin: Option<String>,
    /// Volatile token estimate: active skill content (set per-turn by prompt handler).
    volatile_skill_context_tokens: u64,
    /// Volatile token estimate: skill deactivation notice.
    volatile_skill_removal_tokens: u64,
    /// Volatile token estimate: background job results.
    volatile_job_results_tokens: u64,
    /// Profile-resolved context policy for this session/process.
    context_policy: local_policy::ContextPolicy,
    /// H15 invariant tracking: monotonic counter bumped by `begin_turn()` at
    /// the start of each turn-entry path (currently only
    /// `turn_runner::execute_turn`). `set_volatile_tokens` records the
    /// generation it ran under; `get_snapshot` + `get_detailed_snapshot`
    /// `debug_assert!` that the volatile estimate was refreshed during the
    /// current generation. Catches regressions where a new turn-entry path
    /// forgets to call `set_volatile_tokens` before reading a snapshot —
    /// the bug that H15 was filed against.
    turn_generation: u64,
    /// Generation during which `set_volatile_tokens` was last invoked.
    /// Starts at `None` (never refreshed) so the first snapshot check fires
    /// unless the turn loop has already refreshed.
    volatile_refreshed_at_generation: Option<u64>,
}

impl ContextManager {
    /// Create a new context manager with the given configuration.
    pub fn new(mut config: ContextManagerConfig) -> Self {
        // Default working_directory to $HOME/Workspace/ rather than /tmp
        if config.working_directory.is_none() {
            let home = crate::core::paths::home_dir();
            config.working_directory = Some(format!("{home}/Workspace"));
        }

        let system_prompt = config.system_prompt.clone().unwrap_or_else(|| {
            panic!("ContextManagerConfig.system_prompt must be resolved from the active profile")
        });
        let context_policy = config.context_policy.clone();

        // Filter tool definitions for token estimation accuracy. Local models
        // only receive the profile-selected local tool policy at turn time, so
        // the estimator should count only those.
        if context_policy.is_local()
            && let Some(local_tools) = context_policy.tool_filter()
        {
            config
                .tools
                .retain(|t| local_tools.iter().any(|name| name == &t.name));
        }

        let rules_content = config.rules_content.clone();

        Self {
            config,
            messages: MessageStore::new(),
            api_context_tokens: None,
            system_prompt,
            rules_content,
            dynamic_rules_content: None,
            skill_index_content: None,
            memory_content: None,
            session_memories: Vec::new(),
            on_compaction_needed: None,
            rules_tracker: RulesTracker::new(),
            last_extracted_data: None,
            server_origin: None,
            volatile_skill_context_tokens: 0,
            volatile_skill_removal_tokens: 0,
            volatile_job_results_tokens: 0,
            context_policy,
            turn_generation: 0,
            volatile_refreshed_at_generation: None,
        }
    }

    // ── H15: per-turn volatile-token refresh invariant ───────────────────

    /// Bump the turn generation counter.
    ///
    /// INVARIANT: every turn-entry path MUST call `begin_turn()` before any
    /// context-shape computation, followed by `set_volatile_tokens(..)` once
    /// the runtime's current volatile estimates are available. Snapshot
    /// readers (`get_snapshot`, `get_detailed_snapshot`) `debug_assert!` that
    /// the refresh happened during the current generation. Today the only
    /// turn-entry path is `turn_runner::execute_turn`, which calls this via
    /// `build_turn_context`. Any new entry path must do the same.
    pub fn begin_turn(&mut self) {
        self.turn_generation = self.turn_generation.saturating_add(1);
        // Do NOT touch volatile_refreshed_at_generation here — the caller is
        // contractually required to call `set_volatile_tokens` next.
    }

    /// Current turn generation. Exposed for tests; production callers should
    /// use `begin_turn()` to advance it.
    #[must_use]
    pub fn turn_generation(&self) -> u64 {
        self.turn_generation
    }

    /// `true` iff `set_volatile_tokens` has been called during the current
    /// turn generation. Used by the debug_assert in snapshot readers.
    #[must_use]
    pub fn volatile_tokens_fresh_for_current_turn(&self) -> bool {
        self.volatile_refreshed_at_generation == Some(self.turn_generation)
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

    /// Get a shared `Arc<[Message]>` snapshot (amortized zero-copy for repeated calls).
    pub fn get_messages_arc(&mut self) -> Arc<[Message]> {
        self.messages.as_arc()
    }

    /// Borrow the message slice (zero-copy).
    #[must_use]
    pub fn messages_slice(&self) -> &[Message] {
        self.messages.as_slice()
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
        let before = self.rules_tracker.activated_scoped_rules_count();
        if !self.rules_tracker.touch_path(relative_path) {
            return vec![];
        }
        // Rebuild dynamic content after new activations
        let content = self
            .rules_tracker
            .build_dynamic_rules_content()
            .map(String::from);
        self.dynamic_rules_content = content;

        // Return ONLY newly activated rules (not cumulative)
        self.rules_tracker
            .activated_rules()
            .into_iter()
            .skip(before)
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
    ///
    /// INVARIANT: for local models, `volatile_job_results_tokens` is excluded
    /// because job-result context is stripped at turn time. This mirrors the
    /// guard in `ManagerSnapshotDeps::get_volatile_job_results_tokens`, so
    /// `get_current_tokens` and the `DetailedContextSnapshot` total agree.
    #[must_use]
    pub fn get_current_tokens(&self) -> u64 {
        if let Some(api_tokens) = self.api_context_tokens {
            return api_tokens;
        }
        let job_results = if self.context_policy().strip_job_results() {
            0
        } else {
            self.volatile_job_results_tokens
        };
        self.estimate_system_prompt_tokens()
            + self.estimate_tools_tokens()
            + self.estimate_rules_tokens()
            + self.estimate_memory_tokens()
            + self.estimate_skill_index_tokens()
            + self.volatile_skill_context_tokens
            + self.volatile_skill_removal_tokens
            + job_results
            + self.estimate_environment_tokens()
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
    /// Whether this is a local (Ollama) model session.
    ///
    /// Local models strip the skill index and job results at turn time,
    /// but keep manually-activated skill content.
    pub fn is_local_model(&self) -> bool {
        self.context_policy.is_local()
    }

    fn context_policy(&self) -> &local_policy::ContextPolicy {
        &self.context_policy
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
    /// Return the names of all registered tools.
    pub fn tool_names(&self) -> Vec<String> {
        self.config.tools.iter().map(|t| t.name.clone()).collect()
    }

    /// Set skill index content for token estimation.
    pub fn set_skill_index_content(&mut self, content: Option<String>) {
        self.skill_index_content = content;
    }

    #[must_use]
    /// Estimate skill index token count.
    ///
    /// Returns 0 when the active context policy strips the skill index.
    pub fn estimate_skill_index_tokens(&self) -> u64 {
        if self.context_policy().strip_skill_index() {
            return 0;
        }
        u64::from(token_estimator::estimate_rules_tokens(
            self.skill_index_content.as_deref(),
        ))
    }

    #[must_use]
    /// Estimate token count for all loaded rules (static + dynamic).
    ///
    /// If the active context policy truncates static rules, cap the estimate
    /// to match what `build_turn_context` sends.
    pub fn estimate_rules_tokens(&self) -> u64 {
        let static_rules = if self.context_policy().rules_truncation().is_some() {
            // Truncated by the active profile's local context policy at turn
            // time. Cap the estimate to match what the model actually
            // receives.
            let capped = self.rules_content.as_ref().map(|r| {
                let budget = self
                    .context_policy()
                    .rules_estimation_chars()
                    .unwrap_or(r.len());
                let len = r.len().min(budget);
                len as u64 / u64::from(CHARS_PER_TOKEN)
            });
            capped.unwrap_or(0)
        } else {
            u64::from(token_estimator::estimate_rules_tokens(
                self.rules_content.as_deref(),
            ))
        };
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

    #[must_use]
    /// Estimate memory tokens (workspace memory + session memories).
    ///
    /// Returns 0 when the active context policy strips memory.
    pub fn estimate_memory_tokens(&self) -> u64 {
        if self.context_policy().strip_memory() {
            return 0;
        }
        let base = u64::from(token_estimator::estimate_rules_tokens(
            self.memory_content.as_deref(),
        ));
        let session: u64 = self.session_memories.iter().map(|m| m.tokens).sum();
        base + session
    }

    #[must_use]
    /// Estimate environment metadata tokens (working directory + server origin).
    pub fn estimate_environment_tokens(&self) -> u64 {
        let wd = self
            .config
            .working_directory
            .as_ref()
            .map_or(0, |wd| (wd.len() + 30) as u64 / CHARS_PER_TOKEN as u64);
        let origin = self
            .server_origin
            .as_ref()
            .map_or(0, |o| (o.len() + 10) as u64 / CHARS_PER_TOKEN as u64);
        wd + origin
    }

    /// Set server origin for environment token estimation.
    pub fn set_server_origin(&mut self, origin: Option<String>) {
        self.server_origin = origin;
    }

    /// Set volatile token estimates (called per-turn by the prompt handler).
    ///
    /// For local models, `job_results` is forced to 0 because the job-result
    /// context is stripped at turn time. Callers in the turn runner already
    /// pass 0; this guard ensures the invariant holds even if a future caller
    /// forgets to check.
    ///
    /// H15: records the current turn generation. Paired with `begin_turn()`
    /// and the `debug_assert` in `get_snapshot` / `get_detailed_snapshot`, a
    /// missed refresh on a new turn-entry path panics in debug builds and
    /// proceeds with stale estimates (logged once) in release.
    pub fn set_volatile_tokens(
        &mut self,
        skill_context: u64,
        skill_removal: u64,
        job_results: u64,
    ) {
        self.volatile_skill_context_tokens = skill_context;
        self.volatile_skill_removal_tokens = skill_removal;
        // Defensive coercion: local models strip job_results at turn time,
        // so tracking a non-zero estimate here would inflate compaction
        // triggers. Caller-passed values are silently ignored for local.
        self.volatile_job_results_tokens = if self.context_policy().strip_job_results() {
            0
        } else {
            job_results
        };
        self.volatile_refreshed_at_generation = Some(self.turn_generation);
    }

    // ── Snapshot & validation ───────────────────────────────────────────

    #[must_use]
    /// Build a context snapshot with token breakdown.
    ///
    /// H15: `debug_assert!`s that volatile tokens were refreshed this turn
    /// (unless the generation is 0, i.e. we're outside the turn loop — engine
    /// status queries, tests, etc.). See `begin_turn()` / `set_volatile_tokens`.
    pub fn get_snapshot(&self) -> ContextSnapshot {
        self.assert_volatile_fresh_for_snapshot("get_snapshot");
        let deps = ManagerSnapshotDeps { manager: self };
        let builder = ContextSnapshotBuilder::new(deps);
        builder.build()
    }

    #[must_use]
    /// Build a detailed snapshot including per-message breakdown.
    ///
    /// H15: see `get_snapshot` — same invariant check applies.
    pub fn get_detailed_snapshot(&self) -> DetailedContextSnapshot {
        self.assert_volatile_fresh_for_snapshot("get_detailed_snapshot");
        let deps = ManagerSnapshotDeps { manager: self };
        let builder = ContextSnapshotBuilder::new(deps);
        builder.build_detailed()
    }

    /// H15 invariant check: inside an active turn (generation > 0), the
    /// snapshot readers require `set_volatile_tokens` to have run during
    /// the current generation. Outside a turn (generation 0), snapshots
    /// are accepted as-is — capability context queries, resume reconstructors,
    /// and tests construct a ContextManager and take snapshots without
    /// ever entering the turn loop, and forcing them to set dummy
    /// volatile values would be pure noise.
    fn assert_volatile_fresh_for_snapshot(&self, caller: &'static str) {
        if self.turn_generation == 0 {
            return;
        }
        if !self.volatile_tokens_fresh_for_current_turn() {
            debug_assert!(
                false,
                "volatile tokens not refreshed for turn generation {} before {} — missing \
                 set_volatile_tokens on a turn-entry path? Recorded generation: {:?}",
                self.turn_generation, caller, self.volatile_refreshed_at_generation
            );
            tracing::warn!(
                generation = self.turn_generation,
                recorded = ?self.volatile_refreshed_at_generation,
                caller,
                "H15: volatile tokens stale for current turn; snapshot may under/over-estimate"
            );
        }
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

        // Store extracted data for checkpoint payloads
        if let Some(ref data) = result.extracted_data {
            self.last_extracted_data = Some(data.clone());
        }

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
        if self.should_compact()
            && let Some(cb) = &self.on_compaction_needed
        {
            cb();
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
            let prefix = crate::core::text::truncate_str(content, body_budget);
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

    // ── Context construction ────────────────────────────────────────────

    /// Build the stable portion of a [`Context`] from managed state.
    ///
    /// Includes: `system_prompt`, `working_directory`, `rules_content`,
    /// `memory_content`, `dynamic_rules_context`. Callers fill in external
    /// fields (`messages`, `tools`, `skill_context`,
    /// `job_results_context`, `hook_context`, `server_origin`).
    #[must_use]
    pub fn build_base_context(&self) -> crate::core::messages::Context {
        crate::core::messages::Context {
            system_prompt: Some(self.get_system_prompt().to_owned()),
            messages: Arc::default(),
            tools: None,
            working_directory: Some(self.get_working_directory().to_owned()),
            rules_content: self.get_rules_content().map(String::from),
            memory_content: self.get_full_memory_content(),
            skill_index_context: None,
            skill_activation_context: None,
            skill_context: None,
            skill_removal_context: None,
            job_results_context: None,
            dynamic_rules_context: self.get_dynamic_rules_content().map(String::from),
            hook_context: None,
            server_origin: None,
        }
    }

    // ── Extracted data (for memory snapshots) ──────────────────────────

    /// Get the latest extracted data from compaction, or a default.
    #[must_use]
    pub fn get_latest_extracted_data(&self) -> ExtractedData {
        self.last_extracted_data.clone().unwrap_or_default()
    }

    /// Store extracted data from compaction for checkpoint payloads.
    pub fn set_extracted_data(&mut self, data: ExtractedData) {
        self.last_extracted_data = Some(data);
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
    fn estimate_skill_index_tokens(&self) -> u64 {
        self.manager.estimate_skill_index_tokens()
    }
    fn estimate_memory_tokens(&self) -> u64 {
        self.manager.estimate_memory_tokens()
    }
    fn estimate_environment_tokens(&self) -> u64 {
        self.manager.estimate_environment_tokens()
    }
    fn get_volatile_skill_context_tokens(&self) -> u64 {
        self.manager.volatile_skill_context_tokens
    }
    fn get_volatile_skill_removal_tokens(&self) -> u64 {
        self.manager.volatile_skill_removal_tokens
    }
    fn get_volatile_job_results_tokens(&self) -> u64 {
        if self.manager.context_policy().strip_job_results() {
            0
        } else {
            self.manager.volatile_job_results_tokens
        }
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
    fn get_tool_summaries(&self) -> Vec<ToolSummary> {
        self.manager
            .config
            .tools
            .iter()
            .map(|t| ToolSummary {
                name: t.name.clone(),
                description: crate::core::text::first_sentence(&t.description).to_owned(),
            })
            .collect()
    }
    fn is_local_model(&self) -> bool {
        self.manager.is_local_model()
    }
}

// =============================================================================
// Compaction deps adapter
// =============================================================================

/// Adapts context manager state for the compaction engine.
///
/// Uses interior mutability (`parking_lot::Mutex`) so `CompactionEngine` can
/// modify messages during compaction. `parking_lot::Mutex` is used instead of
/// `std::sync::Mutex` to avoid lock poisoning on panic.
struct ManagerCompactionDeps {
    messages: parking_lot::Mutex<Vec<Message>>,
    current_tokens: u64,
    context_limit: u64,
    system_prompt_tokens: u64,
    tools_tokens: u64,
}

impl ManagerCompactionDeps {
    fn from_manager(manager: &ContextManager) -> Self {
        Self {
            messages: parking_lot::Mutex::new(manager.messages_slice().to_vec()),
            current_tokens: manager.get_current_tokens(),
            context_limit: manager.get_context_limit(),
            system_prompt_tokens: manager.estimate_system_prompt_tokens(),
            tools_tokens: manager.estimate_tools_tokens(),
        }
    }
}

impl CompactionDeps for ManagerCompactionDeps {
    fn get_messages(&self) -> Vec<Message> {
        self.messages.lock().clone()
    }
    fn set_messages(&self, messages: Vec<Message>) {
        *self.messages.lock() = messages;
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

#[cfg(test)]
#[path = "context_manager_tests.rs"]
mod tests;
