use crate::shared::messages::Message;

use super::super::context_snapshot_builder::SnapshotDeps;
use super::super::types::CapabilitySummary;
use super::ContextManager;

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

    fn estimate_environment_tokens(&self) -> u64 {
        self.manager.estimate_environment_tokens()
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
            .map(|capability| CapabilitySummary {
                name: capability.name.clone(),
                description: crate::shared::text::first_sentence(&capability.description)
                    .to_owned(),
            })
            .collect()
    }
}
