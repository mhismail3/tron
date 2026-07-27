//! Primitive context manager.
//!
//! The manager owns only loop infrastructure: message history, the minimal
//! behavioral seed, provider-visible tool schemas for accounting, environment
//! metadata, token estimates, and compaction state.

use std::sync::Arc;

use crate::shared::protocol::messages::Message;
use crate::shared::protocol::model_tools::ModelTool;

use super::compaction_engine::{CompactionDeps, CompactionEngine};
use super::constants::CHARS_PER_TOKEN;
use super::message_store::{MessageAuditSource, MessageStore};
use super::summarizer::Summarizer;
use super::token_estimator;
use super::types::{CompactionResult, ContextManagerConfig};

mod compaction_deps;

use compaction_deps::ManagerCompactionDeps;

pub struct ContextManager {
    pub(super) config: ContextManagerConfig,
    messages: MessageStore,
    api_context_tokens: Option<u64>,
    system_prompt: String,
    server_origin: Option<String>,
    tools: Vec<ModelTool>,
}

pub(crate) struct CompactionCheckpoint {
    messages: Vec<Message>,
    api_context_tokens: Option<u64>,
}

impl ContextManager {
    pub fn new(mut config: ContextManagerConfig) -> Self {
        if config.working_directory.is_none() {
            let home = crate::shared::foundation::paths::home_dir();
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
            server_origin: None,
            tools: Vec::new(),
        }
    }

    pub fn add_message(&mut self, message: Message) {
        self.messages.add(message);
    }

    /// Add one message with request-inspection provenance.
    pub fn add_message_with_source(&mut self, message: Message, source: MessageAuditSource) {
        self.messages.add_with_source(message, source);
    }

    pub fn set_messages(&mut self, messages: Vec<Message>) {
        self.messages.set(messages);
        self.api_context_tokens = None;
    }

    /// Install reconstructed messages with their durable event sidecars.
    pub fn set_messages_with_sources(
        &mut self,
        messages: Vec<Message>,
        sources: Vec<MessageAuditSource>,
    ) {
        self.messages.set_with_sources(messages, sources);
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

    /// Return message provenance aligned with [`Self::messages_slice`].
    #[must_use]
    pub fn message_audit_sources(&self) -> &[MessageAuditSource] {
        self.messages.audit_sources()
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
            + self.estimate_tools_tokens()
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
    pub fn estimate_tools_tokens(&self) -> u64 {
        u64::from(token_estimator::estimate_tools_tokens(&self.tools))
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

    /// Replace the live provider tool surface used for token accounting.
    pub fn set_tools(&mut self, tools: Vec<ModelTool>) {
        if self.tools != tools {
            self.tools = tools;
            self.api_context_tokens = None;
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

    pub async fn execute_compaction(
        &mut self,
        summarizer: &dyn Summarizer,
        edited_summary: Option<&str>,
        summary_context: &super::summarizer::SummaryContext,
    ) -> Result<CompactionResult, Box<dyn std::error::Error + Send + Sync>> {
        let deps = ManagerCompactionDeps::from_manager(self);
        let engine = CompactionEngine::new(
            self.config.compaction.threshold,
            self.config.compaction.preserve_recent_turns,
            deps,
        );
        let result = engine
            .execute(summarizer, edited_summary, summary_context)
            .await?;
        self.messages.set(engine.deps.get_messages());
        self.api_context_tokens = None;
        Ok(result)
    }

    pub(crate) fn compaction_checkpoint(&self) -> CompactionCheckpoint {
        CompactionCheckpoint {
            messages: self.get_messages(),
            api_context_tokens: self.api_context_tokens,
        }
    }

    pub(crate) fn restore_compaction_checkpoint(&mut self, checkpoint: CompactionCheckpoint) {
        self.messages.set(checkpoint.messages);
        self.api_context_tokens = checkpoint.api_context_tokens;
    }

    #[must_use]
    pub fn build_base_context(&self) -> crate::shared::protocol::messages::Context {
        crate::shared::protocol::messages::Context {
            system_prompt: Some(self.get_system_prompt().to_owned()),
            messages: Arc::default(),
            tools: None,
            working_directory: Some(self.get_working_directory().to_owned()),
            server_origin: None,
        }
    }
}

#[cfg(test)]
mod tests;
