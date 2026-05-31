use crate::shared::messages::Message;

use super::super::context_snapshot_builder::SnapshotDeps;
use super::super::types::CapabilitySummary;
use super::ContextManager;

/// Projects `&ContextManager` into [`SnapshotDeps`].
pub(super) struct ManagerSnapshotDeps<'a> {
    pub(super) manager: &'a ContextManager,
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

    fn estimate_capabilities_tokens(&self) -> u64 {
        self.manager.estimate_capabilities_tokens()
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

    fn get_capability_clarification(&self) -> Option<String> {
        None
    }

    fn get_capability_summaries(&self) -> Vec<CapabilitySummary> {
        self.manager
            .config
            .capabilities
            .iter()
            .map(|t| CapabilitySummary {
                name: t.name.clone(),
                description: crate::shared::text::first_sentence(&t.description).to_owned(),
            })
            .collect()
    }

    fn is_local_model(&self) -> bool {
        self.manager.is_local_model()
    }
}
