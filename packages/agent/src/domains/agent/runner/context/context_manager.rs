//! Primitive context manager.
//!
//! The manager owns only loop infrastructure: message history, the audited soul
//! prompt, provider-visible capability schemas for accounting, environment
//! metadata, token estimates, and compaction state.

use std::sync::Arc;

use crate::shared::messages::Message;

use super::compaction_engine::{CompactionDeps, CompactionEngine};
use super::constants::{
    CAPABILITY_RESULT_MAX_CHARS, CAPABILITY_RESULT_MIN_TOKENS, CHARS_PER_TOKEN, Thresholds,
};
use super::context_snapshot_builder::ContextSnapshotBuilder;
use super::message_store::MessageStore;
use super::summarizer::Summarizer;
use super::token_estimator;
use super::types::{
    CompactionPreview, CompactionResult, ContextManagerConfig, ContextSnapshot,
    DetailedContextSnapshot, ExportedState, ExtractedData, PreTurnValidation,
    ProcessedCapabilityResult,
};

mod compaction_deps;
mod snapshot_deps;

use compaction_deps::ManagerCompactionDeps;
use snapshot_deps::ManagerSnapshotDeps;

pub struct ContextManager {
    pub(super) config: ContextManagerConfig,
    messages: MessageStore,
    api_context_tokens: Option<u64>,
    system_prompt: String,
    last_extracted_data: Option<ExtractedData>,
    server_origin: Option<String>,
    turn_generation: u64,
    turn_shape_refreshed_at_generation: Option<u64>,
}

impl ContextManager {
    pub fn new(mut config: ContextManagerConfig) -> Self {
        if config.working_directory.is_none() {
            let home = crate::shared::paths::home_dir();
            config.working_directory = Some(format!("{home}/Workspace"));
        }

        let system_prompt = config.system_prompt.clone().unwrap_or_else(|| {
            panic!("ContextManagerConfig.system_prompt must be resolved before construction")
        });

        Self {
            config,
            messages: MessageStore::new(),
            api_context_tokens: None,
            system_prompt,
            last_extracted_data: None,
            server_origin: None,
            turn_generation: 0,
            turn_shape_refreshed_at_generation: None,
        }
    }

    pub fn begin_turn(&mut self) {
        self.turn_generation = self.turn_generation.saturating_add(1);
    }

    #[must_use]
    pub fn turn_generation(&self) -> u64 {
        self.turn_generation
    }

    #[must_use]
    pub fn volatile_tokens_fresh_for_current_turn(&self) -> bool {
        self.turn_shape_refreshed_at_generation == Some(self.turn_generation)
    }

    pub fn add_message(&mut self, message: Message) {
        self.messages.add(message);
    }

    pub fn set_messages(&mut self, messages: Vec<Message>) {
        self.messages.set(messages);
        self.api_context_tokens = None;
    }

    #[must_use]
    pub fn get_messages(&self) -> Vec<Message> {
        self.messages.as_slice().to_vec()
    }

    pub fn get_messages_arc(&mut self) -> Arc<[Message]> {
        self.messages.as_arc()
    }

    #[must_use]
    pub fn messages_slice(&self) -> &[Message] {
        self.messages.as_slice()
    }

    pub fn clear_messages(&mut self) {
        self.messages.clear();
        self.api_context_tokens = None;
    }

    #[must_use]
    pub fn message_count(&self) -> usize {
        self.messages.len()
    }

    #[must_use]
    pub fn get_system_prompt(&self) -> &str {
        &self.system_prompt
    }

    #[must_use]
    pub fn get_current_tokens(&self) -> u64 {
        if let Some(api_tokens) = self.api_context_tokens {
            return api_tokens;
        }
        self.estimate_system_prompt_tokens()
            + self.estimate_capabilities_tokens()
            + self.estimate_environment_tokens()
            + self.get_messages_tokens()
    }

    pub fn set_api_context_tokens(&mut self, tokens: u64) {
        self.api_context_tokens = Some(tokens);
    }

    #[must_use]
    pub fn get_api_context_tokens(&self) -> Option<u64> {
        self.api_context_tokens
    }

    #[must_use]
    pub fn get_context_limit(&self) -> u64 {
        self.config.compaction.context_limit
    }

    #[must_use]
    pub fn get_model(&self) -> &str {
        &self.config.model
    }

    #[must_use]
    pub fn get_working_directory(&self) -> &str {
        self.config.working_directory.as_deref().unwrap_or("/tmp")
    }

    #[must_use]
    pub fn estimate_system_prompt_tokens(&self) -> u64 {
        u64::from(token_estimator::estimate_system_prompt_tokens(
            &self.system_prompt,
            None,
        ))
    }

    #[must_use]
    pub fn estimate_capabilities_tokens(&self) -> u64 {
        u64::from(token_estimator::estimate_capabilities_tokens(
            &self.config.capabilities,
        ))
    }

    #[must_use]
    pub fn model_capability_names(&self) -> Vec<String> {
        self.config
            .capabilities
            .iter()
            .map(|capability| capability.name.clone())
            .collect()
    }

    #[must_use]
    pub fn get_messages_tokens(&self) -> u64 {
        u64::from(self.messages.get_tokens())
    }

    #[must_use]
    pub fn get_message_tokens(&self, msg: &Message) -> u64 {
        u64::from(token_estimator::estimate_message_tokens(msg))
    }

    #[must_use]
    pub fn estimate_environment_tokens(&self) -> u64 {
        let wd = self
            .config
            .working_directory
            .as_ref()
            .map_or(0, |wd| (wd.len() + 30) as u64 / CHARS_PER_TOKEN as u64);
        let origin = self.server_origin.as_ref().map_or(0, |origin| {
            (origin.len() + 10) as u64 / CHARS_PER_TOKEN as u64
        });
        wd + origin
    }

    pub fn set_server_origin(&mut self, origin: Option<String>) {
        self.server_origin = origin;
    }

    pub fn set_volatile_tokens(&mut self, _a: u64, _b: u64, _c: u64) {
        self.turn_shape_refreshed_at_generation = Some(self.turn_generation);
    }

    #[must_use]
    pub fn get_snapshot(&self) -> ContextSnapshot {
        self.assert_turn_shape_refreshed("get_snapshot");
        ContextSnapshotBuilder::new(ManagerSnapshotDeps { manager: self }).build()
    }

    #[must_use]
    pub fn get_detailed_snapshot(&self) -> DetailedContextSnapshot {
        self.assert_turn_shape_refreshed("get_detailed_snapshot");
        ContextSnapshotBuilder::new(ManagerSnapshotDeps { manager: self }).build_detailed()
    }

    fn assert_turn_shape_refreshed(&self, caller: &'static str) {
        if self.turn_generation == 0 {
            return;
        }
        if !self.volatile_tokens_fresh_for_current_turn() {
            debug_assert!(
                false,
                "turn context shape not refreshed for generation {} before {}",
                self.turn_generation, caller
            );
            tracing::warn!(
                generation = self.turn_generation,
                recorded = ?self.turn_shape_refreshed_at_generation,
                caller,
                "turn context shape was stale for current turn"
            );
        }
    }

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

    #[must_use]
    pub fn has_summarizable_compaction_window(&self) -> bool {
        let deps = ManagerCompactionDeps::from_manager(self);
        let engine = CompactionEngine::new(
            self.config.compaction.threshold,
            self.config.compaction.preserve_recent_turns,
            deps,
        );
        engine.has_summarizable_messages()
    }

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
        self.messages.set(engine.deps.get_messages());
        if let Some(ref data) = result.extracted_data {
            self.last_extracted_data = Some(data.clone());
        }
        self.api_context_tokens = None;
        Ok(result)
    }

    #[must_use]
    pub fn process_capability_result(
        &self,
        invocation_id: &str,
        content: &str,
    ) -> ProcessedCapabilityResult {
        let max_size = self.get_max_capability_result_size();
        if content.len() <= max_size {
            ProcessedCapabilityResult {
                invocation_id: invocation_id.to_owned(),
                content: content.to_owned(),
                truncated: false,
                original_size: None,
            }
        } else {
            let body_budget = max_size.saturating_sub(100);
            let prefix = crate::shared::text::truncate_str(content, body_budget);
            ProcessedCapabilityResult {
                invocation_id: invocation_id.to_owned(),
                content: format!(
                    "{prefix}...\n[Truncated: {} chars total, showing first {}]",
                    content.len(),
                    prefix.len()
                ),
                truncated: true,
                original_size: Some(content.len()),
            }
        }
    }

    #[must_use]
    pub fn get_max_capability_result_size(&self) -> usize {
        let limit = self.get_context_limit();
        let current = self.get_current_tokens();
        let remaining = limit.saturating_sub(current);
        let response_reserve: u64 = 8_000;
        let margin: u64 = remaining / 10;
        let available_tokens = remaining
            .saturating_sub(response_reserve)
            .saturating_sub(margin)
            .max(u64::from(CAPABILITY_RESULT_MIN_TOKENS));

        #[allow(clippy::cast_possible_truncation)]
        let budget = (available_tokens as usize) * (CHARS_PER_TOKEN as usize);
        budget.min(CAPABILITY_RESULT_MAX_CHARS)
    }

    pub fn switch_model(&mut self, new_model: String, context_limit: u64) {
        self.config.model = new_model;
        self.config.compaction.context_limit = context_limit;
        self.api_context_tokens = None;
    }

    #[must_use]
    pub fn build_base_context(&self) -> crate::shared::messages::Context {
        crate::shared::messages::Context {
            system_prompt: Some(self.get_system_prompt().to_owned()),
            messages: Arc::default(),
            capabilities: None,
            working_directory: Some(self.get_working_directory().to_owned()),
            agent_state_context: None,
            server_origin: None,
        }
    }

    #[must_use]
    pub fn get_latest_extracted_data(&self) -> ExtractedData {
        self.last_extracted_data.clone().unwrap_or_default()
    }

    pub fn set_extracted_data(&mut self, data: ExtractedData) {
        self.last_extracted_data = Some(data);
    }

    #[must_use]
    pub fn export_state(&self) -> ExportedState {
        ExportedState {
            model: self.config.model.clone(),
            system_prompt: self.system_prompt.clone(),
            capabilities: self.config.capabilities.clone(),
            messages: self.get_messages(),
        }
    }
}

#[cfg(test)]
#[path = "context_manager_tests.rs"]
mod tests;
