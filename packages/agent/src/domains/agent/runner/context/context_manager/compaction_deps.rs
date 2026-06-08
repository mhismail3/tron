use crate::shared::protocol::messages::Message;

use super::super::compaction_engine::CompactionDeps;
use super::super::token_estimator;
use super::ContextManager;

/// Projects context manager state for the compaction engine.
///
/// Uses interior mutability (`parking_lot::Mutex`) so `CompactionEngine` can
/// modify messages during compaction. `parking_lot::Mutex` is used instead of
/// `std::sync::Mutex` to avoid lock poisoning on panic.
pub(super) struct ManagerCompactionDeps {
    pub(super) messages: parking_lot::Mutex<Vec<Message>>,
    pub(super) current_tokens: u64,
    pub(super) context_limit: u64,
    pub(super) system_prompt_tokens: u64,
    pub(super) capabilities_tokens: u64,
}

impl ManagerCompactionDeps {
    pub(super) fn from_manager(manager: &ContextManager) -> Self {
        Self {
            messages: parking_lot::Mutex::new(manager.messages_slice().to_vec()),
            current_tokens: manager.get_current_tokens(),
            context_limit: manager.get_context_limit(),
            system_prompt_tokens: manager.estimate_system_prompt_tokens(),
            capabilities_tokens: manager.estimate_capabilities_tokens(),
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

    fn estimate_capabilities_tokens(&self) -> u64 {
        self.capabilities_tokens
    }

    fn get_message_tokens(&self, msg: &Message) -> u64 {
        u64::from(token_estimator::estimate_message_tokens(msg))
    }
}
