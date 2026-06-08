//! Context snapshot builder for the primitive loop.

use crate::shared::protocol::content::AssistantContent;
use crate::shared::protocol::messages::Message;

use super::token_estimator::estimate_message_tokens;
use super::types::{
    CapabilityInvocationDraftInfo, CapabilitySummary, ContextSnapshot, DetailedContextSnapshot,
    DetailedMessageInfo, ThresholdLevel, TokenBreakdown,
};

pub trait SnapshotDeps: Send + Sync {
    fn get_current_tokens(&self) -> u64;
    fn get_context_limit(&self) -> u64;
    fn get_messages(&self) -> Vec<Message>;
    fn estimate_system_prompt_tokens(&self) -> u64;
    fn estimate_capabilities_tokens(&self) -> u64;
    fn estimate_environment_tokens(&self) -> u64;
    fn get_messages_tokens(&self) -> u64;
    fn get_message_tokens(&self, msg: &Message) -> u64;
    fn get_system_prompt(&self) -> String;
    fn get_capability_clarification(&self) -> Option<String>;
    fn get_capability_summaries(&self) -> Vec<CapabilitySummary>;
}

pub struct ContextSnapshotBuilder<D: SnapshotDeps> {
    deps: D,
}

impl<D: SnapshotDeps> ContextSnapshotBuilder<D> {
    pub fn new(deps: D) -> Self {
        Self { deps }
    }

    #[must_use]
    pub fn build(&self) -> ContextSnapshot {
        let current_tokens = self.deps.get_current_tokens();
        let context_limit = self.deps.get_context_limit();
        #[allow(clippy::cast_precision_loss)]
        let usage_percent = if context_limit > 0 {
            current_tokens as f64 / context_limit as f64
        } else {
            0.0
        };
        let component_total = self.deps.estimate_system_prompt_tokens()
            + self.deps.estimate_capabilities_tokens()
            + self.deps.estimate_environment_tokens()
            + self.deps.get_messages_tokens();

        ContextSnapshot {
            current_tokens,
            context_limit,
            usage_percent,
            threshold_level: ThresholdLevel::from_ratio(usage_percent),
            breakdown: TokenBreakdown {
                system_prompt: self.deps.estimate_system_prompt_tokens(),
                capabilities: self.deps.estimate_capabilities_tokens(),
                environment: self.deps.estimate_environment_tokens(),
                messages: self.deps.get_messages_tokens(),
                provider_adjustment: current_tokens.saturating_sub(component_total),
            },
        }
    }

    #[must_use]
    pub fn build_detailed(&self) -> DetailedContextSnapshot {
        let snapshot = self.build();
        let messages = self.deps.get_messages();
        let detailed_messages = messages
            .iter()
            .enumerate()
            .map(|(index, msg)| build_message_info(msg, index, self.deps.get_message_tokens(msg)))
            .collect();

        DetailedContextSnapshot {
            snapshot,
            messages: detailed_messages,
            system_prompt_content: self.deps.get_system_prompt(),
            capability_clarification_content: self.deps.get_capability_clarification(),
            capabilities_content: self.deps.get_capability_summaries(),
        }
    }
}

fn build_message_info(msg: &Message, index: usize, tokens: u64) -> DetailedMessageInfo {
    match msg {
        Message::User { content, .. } => {
            let text = match content {
                crate::shared::protocol::messages::UserMessageContent::Text(t) => t.clone(),
                crate::shared::protocol::messages::UserMessageContent::Blocks(blocks) => blocks
                    .iter()
                    .filter_map(|b| b.as_text())
                    .collect::<Vec<_>>()
                    .join("\n"),
            };
            DetailedMessageInfo {
                index,
                role: "user".into(),
                tokens,
                summary: summarize_content(&text, 100),
                content: text,
                event_id: None,
                capability_invocations: None,
                invocation_id: None,
                is_error: None,
            }
        }
        Message::Assistant { content, .. } => {
            let mut text_parts = Vec::new();
            let mut capability_invocations = Vec::new();
            for block in content {
                match block {
                    AssistantContent::Text { text } => text_parts.push(text.clone()),
                    AssistantContent::CapabilityInvocation {
                        id,
                        name,
                        arguments,
                        ..
                    } => {
                        capability_invocations.push(CapabilityInvocationDraftInfo {
                            id: id.clone(),
                            name: name.clone(),
                            tokens: u64::from(estimate_message_tokens(msg)),
                            arguments: serde_json::to_string(arguments).unwrap_or_default(),
                        });
                    }
                    AssistantContent::Thinking { .. } => {}
                }
            }
            let full_text = text_parts.join("\n");
            DetailedMessageInfo {
                index,
                role: "assistant".into(),
                tokens,
                summary: summarize_content(&full_text, 100),
                content: full_text,
                event_id: None,
                capability_invocations: if capability_invocations.is_empty() {
                    None
                } else {
                    Some(capability_invocations)
                },
                invocation_id: None,
                is_error: None,
            }
        }
        Message::CapabilityResult {
            invocation_id,
            content,
            is_error,
        } => {
            let text = match content {
                crate::shared::protocol::messages::CapabilityResultMessageContent::Text(t) => {
                    t.clone()
                }
                crate::shared::protocol::messages::CapabilityResultMessageContent::Blocks(
                    blocks,
                ) => blocks
                    .iter()
                    .filter_map(|b| match b {
                        crate::shared::protocol::content::CapabilityResultContent::Text {
                            text,
                        } => Some(text.as_str()),
                        crate::shared::protocol::content::CapabilityResultContent::Image {
                            ..
                        } => None,
                    })
                    .collect::<Vec<_>>()
                    .join("\n"),
            };
            DetailedMessageInfo {
                index,
                role: "capability_result".into(),
                tokens,
                summary: summarize_content(&text, 100),
                content: text,
                event_id: None,
                capability_invocations: None,
                invocation_id: Some(invocation_id.clone()),
                is_error: *is_error,
            }
        }
    }
}

fn summarize_content(text: &str, max_len: usize) -> String {
    crate::shared::foundation::text::truncate_with_suffix(text, max_len, "...")
}

#[cfg(test)]
mod tests {
    use super::*;

    struct MockDeps {
        current_tokens: u64,
        context_limit: u64,
        messages: Vec<Message>,
    }

    impl Default for MockDeps {
        fn default() -> Self {
            Self {
                current_tokens: 50_000,
                context_limit: 100_000,
                messages: vec![Message::user("Hello"), Message::assistant("Hi there")],
            }
        }
    }

    impl SnapshotDeps for MockDeps {
        fn get_current_tokens(&self) -> u64 {
            self.current_tokens
        }
        fn get_context_limit(&self) -> u64 {
            self.context_limit
        }
        fn get_messages(&self) -> Vec<Message> {
            self.messages.clone()
        }
        fn estimate_system_prompt_tokens(&self) -> u64 {
            2_000
        }
        fn estimate_capabilities_tokens(&self) -> u64 {
            1_000
        }
        fn estimate_environment_tokens(&self) -> u64 {
            100
        }
        fn get_messages_tokens(&self) -> u64 {
            5_000
        }
        fn get_message_tokens(&self, _msg: &Message) -> u64 {
            100
        }
        fn get_system_prompt(&self) -> String {
            "soul".into()
        }
        fn get_capability_clarification(&self) -> Option<String> {
            None
        }
        fn get_capability_summaries(&self) -> Vec<CapabilitySummary> {
            vec![CapabilitySummary {
                name: "execute".into(),
                description: "Primitive host operation.".into(),
            }]
        }
    }

    #[test]
    fn build_basic_snapshot() {
        let builder = ContextSnapshotBuilder::new(MockDeps::default());
        let snap = builder.build();
        assert_eq!(snap.current_tokens, 50_000);
        assert_eq!(snap.context_limit, 100_000);
        assert_eq!(snap.threshold_level, ThresholdLevel::Warning);
        assert_eq!(snap.breakdown.provider_adjustment, 41_900);
    }

    #[test]
    fn build_detailed_snapshot() {
        let builder = ContextSnapshotBuilder::new(MockDeps::default());
        let snap = builder.build_detailed();
        assert_eq!(snap.messages.len(), 2);
        assert_eq!(snap.system_prompt_content, "soul");
        assert_eq!(snap.capabilities_content[0].name, "execute");
    }
}
